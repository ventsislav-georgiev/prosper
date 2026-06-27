import AppKit
import ApplicationServices

/// Private AX→CGWindowID bridge (HIServices) — the public AX API exposes no window
/// id. Resolved once via dlsym rather than a hard `@_silgen_name` link: if Apple
/// ever drops the symbol this degrades to nil (AX-only movement detection) instead
/// of aborting app launch on a missing dynamic symbol.
private typealias AXGetWindowFn =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let axGetWindow: AXGetWindowFn? = {
    // RTLD_DEFAULT searches all loaded images (ApplicationServices is already linked).
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
    else { return nil }
    return unsafeBitCast(sym, to: AXGetWindowFn.self)
}()

/// Built-in window-management actions, applied to a window via the Accessibility
/// API (same permission as autocomplete). The half/maximize/center cases are bound
/// to rebindable global shortcuts in `ShortcutAction`; the quarter cases exist for
/// drag-to-corner snapping (`DragSnapController`) and share the same geometry path.
enum WindowAction {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case maximize
    case center
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    /// Half-screen snaps that cycle their size on repeat presses (keyboard only).
    var isDirectionalHalf: Bool {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return true
        default: return false
        }
    }
}

@MainActor
enum WindowManager {

    // Repeat-press cycle state. Pressing the same directional snap again on the
    // same window steps the fraction of the screen it occupies along this
    // sequence; a different action, a different window, or a non-directional
    // action resets it back to a half.
    private static var lastAction: WindowAction?
    private static var lastWindow: AXUIElement?
    private static var cycleStep = 1            // 1 → 2 → 3 → 1 …
    /// Fraction of the visible dimension for each step: a half, then a half of
    /// that half (a quarter), then back to a half.
    private static let cycleFractions: [CGFloat] = [1.0 / 2.0, 1.0 / 4.0]

    // MARK: - Keyboard entry point

    /// Moves/resizes the frontmost window for `action`. No-op when there is no
    /// focused window or it doesn't expose position/size (some AX-opaque apps).
    static func perform(_ action: WindowAction) {
        guard let win = focusedWindowElement(),
              let current = axFrame(win) else { return }
        let v = visibleFrameAX(for: current)

        // Advance (or reset) the repeat-press cycle before computing the size.
        // Only repeat presses of the same action on the same window advance it;
        // switching windows starts over at a half.
        if action.isDirectionalHalf {
            let sameWindow = lastWindow.map { CFEqual($0, win) } ?? false
            cycleStep = (action == lastAction && sameWindow) ? (cycleStep % cycleFractions.count) + 1 : 1
        }
        lastAction = action
        lastWindow = win
        let frac = cycleFractions[(cycleStep - 1) % cycleFractions.count]

        let target = targetFrame(for: action, visible: v, current: current, fraction: frac)
        setFrame(win, target, within: v)
    }

    // MARK: - Drag-snap entry point

    /// Snaps an arbitrary window (not necessarily frontmost) to `action` on a
    /// specific screen. Used by `DragSnapController` on drop; the geometry comes
    /// from the same `targetFrame` the live footprint preview uses, so the window
    /// lands exactly where the preview showed it. Resets the keyboard cycle so a
    /// later keyboard snap starts fresh.
    static func snap(_ win: AXUIElement, to action: WindowAction, onScreen screen: NSScreen) {
        guard let current = axFrame(win) else { return }
        let v = visibleFrameAX(for: screen)
        let target = targetFrame(for: action, visible: v, current: current)
        setFrame(win, target, within: v)
        lastAction = nil
        lastWindow = nil
    }

    // MARK: - Pure geometry (single source of truth)

    /// Where a window should land for `action` inside the visible frame `v`, given
    /// its `current` frame. All rects are in the AX top-left global space. `fraction`
    /// only affects the directional halves (the keyboard cycle); other actions ignore
    /// it. This is the ONE place snap rects are computed — keyboard, drop, and the
    /// drag footprint preview all call it, so the preview can never disagree with the
    /// final placement.
    static func targetFrame(for action: WindowAction, visible v: CGRect,
                            current: CGRect, fraction: CGFloat = 0.5) -> CGRect {
        let halfW = (v.width / 2).rounded()
        let halfH = (v.height / 2).rounded()
        switch action {
        case .leftHalf:
            let w = (v.width * fraction).rounded()
            return CGRect(x: v.minX, y: v.minY, width: w, height: v.height)
        case .rightHalf:
            let w = (v.width * fraction).rounded()
            return CGRect(x: v.maxX - w, y: v.minY, width: w, height: v.height)
        case .topHalf:
            let h = (v.height * fraction).rounded()
            return CGRect(x: v.minX, y: v.minY, width: v.width, height: h)
        case .bottomHalf:
            let h = (v.height * fraction).rounded()
            return CGRect(x: v.minX, y: v.maxY - h, width: v.width, height: h)
        case .maximize:
            return v
        case .center:
            let w = min(current.width, v.width)
            let h = min(current.height, v.height)
            return CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
        case .topLeftQuarter:
            return CGRect(x: v.minX, y: v.minY, width: halfW, height: halfH)
        case .topRightQuarter:
            return CGRect(x: v.maxX - halfW, y: v.minY, width: halfW, height: halfH)
        case .bottomLeftQuarter:
            return CGRect(x: v.minX, y: v.maxY - halfH, width: halfW, height: halfH)
        case .bottomRightQuarter:
            return CGRect(x: v.maxX - halfW, y: v.maxY - halfH, width: halfW, height: halfH)
        }
    }

    // MARK: - Layout zone geometry (drag-into-zone window layouts)

    /// AX top-left rect a normalized zone (0…1 over the visible frame) maps to
    /// inside `v`, with `gap` breathing room. Gap model: shrink the visible frame
    /// by gap/2 on every side, place the zone in it, then inset the placed rect by
    /// gap/2. Net result — equal-fraction zones get EQUAL pixel widths (±1px from
    /// independent rounding), the gap between adjacent windows is `gap`, and the
    /// margin to the screen edge is also `gap`. The older "outer full gap, interior
    /// half" model made outer windows 0.5·gap narrower; that was a model artifact,
    /// not rounding, so it isn't fixable by sharing integer edges.
    static func targetFrame(zone normRect: CGRect, visible v: CGRect, gap: CGFloat) -> CGRect {
        let half = max(0, gap) / 2
        let vp = v.insetBy(dx: half, dy: half)
        let raw = CGRect(x: vp.minX + normRect.minX * vp.width,
                         y: vp.minY + normRect.minY * vp.height,
                         width: normRect.width * vp.width,
                         height: normRect.height * vp.height)
        // Clamp the inset per-axis so a zone narrower/shorter than the gap doesn't
        // invert (negative size → a 1px sliver shoved to an arbitrary x). For normal
        // zones (gap ≪ zone) this is a no-op; only degenerate thin zones degrade — to
        // a small centered rect rather than an off-position sliver.
        let hx = min(half, max(0, raw.width) / 2)
        let hy = min(half, max(0, raw.height) / 2)
        let placed = raw.insetBy(dx: hx, dy: hy)
        // ponytail: independent per-rect rounding can drift adjacent equal zones by
        // ≤1px; a shared integer-edge table would kill even that, not worth it.
        return CGRect(x: placed.minX.rounded(), y: placed.minY.rounded(),
                      width: max(1, placed.width.rounded()),
                      height: max(1, placed.height.rounded()))
    }

    /// All zone target rects for a layout. The overlay tiles AND the drop placement
    /// both come from here, so the preview is exactly where the window lands.
    static func targetFrames(layout zones: [LayoutZone], visible v: CGRect, gap: CGFloat) -> [CGRect] {
        zones.map { targetFrame(zone: $0.rect, visible: v, gap: gap) }
    }

    /// Snap a window into a layout zone (normalized AX rect) on a screen — the
    /// layout-mode analogue of `snap(_:to:onScreen:)`. When `moveOnly` is set
    /// (Quick Positions), the window keeps its current size and only its origin
    /// moves to the zone anchor, clamped to the visible frame.
    static func snap(_ win: AXUIElement, toZone normRect: CGRect, onScreen screen: NSScreen,
                     gap: CGFloat, moveOnly: Bool = false) {
        let v = visibleFrameAX(for: screen)
        let zoneRect = targetFrame(zone: normRect, visible: v, gap: gap)
        var target = zoneRect
        if moveOnly, let current = axFrame(win) {
            target = CGRect(origin: moveOnlyOrigin(zoneOrigin: zoneRect.origin,
                                                   size: current.size, visible: v),
                            size: current.size)
        }
        setFrame(win, target, within: v)
        lastAction = nil
        lastWindow = nil
    }

    /// moveOnly drop origin: pin the zone anchor inside the visible frame. A window
    /// WIDER/TALLER than the visible frame clamps to the top-left edge (`v.minX`/
    /// `v.minY`) — the outer `max(v.minX, …)` wins when `v.maxX - width < v.minX`.
    static func moveOnlyOrigin(zoneOrigin: CGPoint, size: CGSize, visible v: CGRect) -> CGPoint {
        CGPoint(x: min(max(v.minX, zoneOrigin.x), max(v.minX, v.maxX - size.width)),
                y: min(max(v.minY, zoneOrigin.y), max(v.minY, v.maxY - size.height)))
    }

    // MARK: - AX plumbing

    /// The Accessibility element for the frontmost app's focused window, or nil.
    private static func focusedWindowElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let win = ref, CFGetTypeID(win) == AXUIElementGetTypeID()
        else { return nil }
        return (win as! AXUIElement)
    }

    /// The window element under the current cursor (not just the frontmost one),
    /// plus its owning pid. Walks up from the hit element to the enclosing
    /// `AXWindow`. Used by drag-snap to grab whatever window the user is dragging.
    /// Cursor is read in the AX top-left global space via a synthetic CGEvent.
    static func windowUnderCursor() -> (element: AXUIElement, pid: pid_t)? {
        let loc = CGEvent(source: nil)?.location ?? .zero  // top-left global coords
        let sys = AXUIElementCreateSystemWide()
        // These calls run synchronously on the main thread. Cap how long a hung or
        // slow target app can block us: the default AX timeout is ~6s (a beachball),
        // and a drag hit-test is best-effort — bail fast and skip the snap instead.
        AXUIElementSetMessagingTimeout(sys, Self.axTimeout)
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(loc.x), Float(loc.y), &hitRef) == .success,
              let hit = hitRef else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)

        // Walk up the parent chain to the enclosing window.
        var current: AXUIElement? = hit
        var hops = 0
        while let el = current, hops < 16 {
            hops += 1
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == (kAXWindowRole as String) {
                AXUIElementSetMessagingTimeout(el, Self.axTimeout)  // bound later frame reads/writes
                return (el, pid)
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                break
            }
            current = (parent as! AXUIElement)
        }
        // Fallback: some elements expose their window directly.
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &winRef) == .success,
           let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() {
            let win = (w as! AXUIElement)
            AXUIElementSetMessagingTimeout(win, Self.axTimeout)
            return (win, pid)
        }
        return nil
    }

    /// Upper bound on a single synchronous AX message during a drag. Short on
    /// purpose: a snap is best-effort and main-thread-blocking, so a slow app
    /// should fail the snap, never freeze the UI.
    private static let axTimeout: Float = 0.25

    /// True when the window will accept a size change (skips fixed-size dialogs).
    static func isResizable(_ win: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(win, kAXSizeAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// The window's current frame in the AX top-left global space, or nil.
    static func axFrame(_ win: AXUIElement) -> CGRect? {
        guard let pos = axPoint(win, kAXPositionAttribute),
              let size = axSize(win, kAXSizeAttribute) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// The CoreGraphics window id for an AX window element, or nil. Uses the
    /// long-standing private `_AXUIElementGetWindow` (the only reliable AX→CGWindowID
    /// bridge; matching by pid+bounds is ambiguous). App is notarized/independently
    /// distributed (not Mac App Store), so the private symbol is acceptable.
    static func windowID(_ win: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindow else { return nil }
        var wid = CGWindowID(0)
        return fn(win, &wid) == .success ? wid : nil
    }

    /// The window's frame straight from the window server (top-left global space),
    /// or nil. Unlike `axFrame`, this reflects the live on-screen position even for
    /// apps that don't push AXPosition updates during a user drag (e.g. Telegram /
    /// Qt) — the window server owns the geometry, so it's authoritative for movement.
    static func serverFrame(of wid: CGWindowID) -> CGRect? {
        guard let arr = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid)
                as? [[String: Any]],
              let bounds = arr.first?[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as! CFDictionary)
    }

    /// Topmost normal (layer 0) on-screen window whose server bounds contain the
    /// cursor, from the window server — no AX involved. This is the fallback for apps
    /// whose AX tree is dormant at content pixels (Qt/Telegram), where the AX hit-test
    /// (`windowUnderCursor`) returns nil. Returns the CGWindowID, owning pid, and the
    /// server frame; the AX element (for moving the window) is resolved separately via
    /// `axWindow(pid:windowID:)`.
    static func serverWindowUnderCursor() -> (windowID: CGWindowID, pid: pid_t, bounds: CGRect)? {
        let loc = CGEvent(source: nil)?.location ?? .zero        // top-left global
        guard let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return nil }
        return pickWindow(infos: arr, cursor: loc)
    }

    /// Pure selection over a CGWindowList snapshot: the first (front-most — the list
    /// is ordered front-to-back) normal window (layer 0) whose bounds contain the
    /// cursor. Split out from the CGWindowList call so the layer filter, hit test, and
    /// front-to-back ordering are unit-testable without live windows.
    static func pickWindow(infos: [[String: Any]], cursor: CGPoint)
        -> (windowID: CGWindowID, pid: pid_t, bounds: CGRect)? {
        for w in infos {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let bDict = w[kCGWindowBounds as String],
                  let b = CGRect(dictionaryRepresentation: bDict as! CFDictionary),
                  b.contains(cursor),
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return (wid, pid, b)
        }
        return nil
    }

    /// The AX window element for a CGWindowID under app `pid`, or nil. Enumerates the
    /// app's windows and matches by id; falls back to the app's first window if the id
    /// match fails. Used to recover a movable element when AX hit-testing can't (Qt) —
    /// the app-level window list is exposed even when content-pixel hit-tests are not.
    static func axWindow(pid: pid_t, windowID wid: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement], !wins.isEmpty else { return nil }
        // Prefer the exact id match. Fall back to the sole window only when there's no
        // ambiguity — never grab an arbitrary window on a multi-window app, since
        // moving the wrong window is worse than the drag doing nothing.
        guard let match = wins.first(where: { windowID($0) == wid })
                ?? (wins.count == 1 ? wins.first : nil) else { return nil }
        AXUIElementSetMessagingTimeout(match, axTimeout)
        return match
    }

    /// Window under the cursor for drag-snap: the AX element (needed to move/resize
    /// it), its pid, and CGWindowID. Tries the AX hit-test first (precise, handles
    /// child/sheet windows); when that returns nil — apps with a dormant AX tree like
    /// Qt/Telegram expose nothing at a content pixel — it falls back to the window
    /// server to find the window, then resolves the AX element by id. nil only when
    /// neither path yields a movable window.
    ///
    /// Cost tier: runs ONCE per drag (at drag-start), never on the per-event hot path.
    /// The common path is just the AX hit-test + one `windowID` read; the fallback
    /// adds a full-window-list snapshot + the app's window enumeration, paid only for
    /// apps whose AX tree is dormant.
    static func draggableWindowUnderCursor() -> (element: AXUIElement, pid: pid_t, windowID: CGWindowID?)? {
        if let (el, pid) = windowUnderCursor() {
            return (el, pid, windowID(el))
        }
        guard let s = serverWindowUnderCursor(),
              let el = axWindow(pid: s.pid, windowID: s.windowID) else { return nil }
        return (el, s.pid, s.windowID)
    }

    private static func axPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = copyAXValue(el, attr) else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &out) ? out : nil
    }

    private static func axSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = copyAXValue(el, attr) else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(v, .cgSize, &out) ? out : nil
    }

    private static func copyAXValue(_ el: AXUIElement, _ attr: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    /// Sets a window's frame. Size → position → size again: moving across displays
    /// can re-clamp the size, and some apps ignore a resize until placed.
    ///
    /// `v` is the visible frame the window should stay inside. After applying the
    /// frame we read the window's *actual* size back: an app that refuses to
    /// shrink below a minimum keeps a larger size than requested, which — for a
    /// right- or bottom-anchored target — would push the window off the right/
    /// bottom edge. We re-anchor the origin so the window stays on screen.
    ///
    /// `AXEnhancedUserInterface` is disabled around the writes: when it is on
    /// (VoiceOver, or Prosper's own caret unlock for Chrome/Electron) AppKit
    /// animates and offsets AX-driven moves, so the window lands in the wrong
    /// place. We restore its prior value afterward — the caret unlock re-applies
    /// itself on the next keystroke, so this is invisible to autocomplete.
    private static func setFrame(_ win: AXUIElement, _ rect: CGRect, within v: CGRect) {
        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        withEnhancedUIDisabled(pid: pid) {
            var pos = rect.origin
            var sz = rect.size
            guard let posVal = AXValueCreate(.cgPoint, &pos),
                  let sizeVal = AXValueCreate(.cgSize, &sz) else { return }
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)

            guard let actual = axSize(win, kAXSizeAttribute) else { return }
            var origin = rect.origin
            if origin.x + actual.width > v.maxX { origin.x = max(v.minX, v.maxX - actual.width) }
            if origin.y + actual.height > v.maxY { origin.y = max(v.minY, v.maxY - actual.height) }
            guard origin != rect.origin else { return }
            var clamped = origin
            if let clampedVal = AXValueCreate(.cgPoint, &clamped) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, clampedVal)
            }
        }
    }

    /// Runs `body` with the app's `AXEnhancedUserInterface` forced off, restoring
    /// it only if it was on to begin with (so apps that never had it stay untouched).
    private static func withEnhancedUIDisabled(pid: pid_t, _ body: () -> Void) {
        guard pid > 0 else { body(); return }
        let app = AXUIElementCreateApplication(pid)
        var priorRef: CFTypeRef?
        let priorOn = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &priorRef) == .success
            && (priorRef as? Bool == true)
        if priorOn {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        body()
        if priorOn {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    // MARK: - Screen geometry / coordinate spaces

    /// Visible frame (Dock/menu-bar excluded) of the screen the window sits on, in
    /// the AX top-left global space. Picks the screen containing the window centre,
    /// else the largest overlap, else main.
    private static func visibleFrameAX(for winRectAX: CGRect) -> CGRect {
        let center = CGPoint(x: winRectAX.midX, y: winRectAX.midY)
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let fAX = toAX(screen.frame)
            if fAX.contains(center) { best = screen; break }
            let overlap = fAX.intersection(winRectAX)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea { bestArea = area; best = screen }
        }
        let screen = best ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return winRectAX }
        return toAX(screen.visibleFrame)
    }

    /// Visible frame of a specific screen, in the AX top-left global space.
    static func visibleFrameAX(for screen: NSScreen) -> CGRect {
        toAX(screen.visibleFrame)
    }

    /// Stable per-display id (`CGDirectDisplayID`) for caching tile geometry across
    /// drag events. `NSScreen.hashValue` is the default object hash and AppKit may
    /// vend a fresh `NSScreen` for the same physical display between event ticks, so
    /// it is neither stable nor collision-free; the screen number is. 0 if missing.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The screen whose full frame contains the AX-space point (top-left coords), or
    /// nil when the point is on no screen. Returns nil (not a fallback to main) on
    /// purpose: the caller classifies snap zones against the returned screen's frame,
    /// and falling back to the wrong screen for a point in the dead gap between
    /// mismatched displays would snap the window to a screen the cursor isn't on.
    static func screenContaining(axPoint p: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens where toAX(screen.frame).contains(p) {
            return screen
        }
        return nil
    }

    /// Flip an AppKit (bottom-left) rect into the AX top-left global space.
    /// Anchored to `NSScreen.screens.first` (the primary/menu-bar screen) — NOT
    /// `.main` (the key-window screen, which moves). The AX global space is anchored
    /// to the primary's top-left for ALL screens, so the primary height is the only
    /// one that matters; secondary displays extend into ±Y and round-trip exactly.
    /// Do NOT "fix" this to `.main` — it would break every multi-monitor placement.
    static func toAX(_ r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height,
                      width: r.width, height: r.height)
    }

    /// Flip an AX top-left rect back into the AppKit bottom-left global space — for
    /// placing AppKit overlay windows (the footprint) over an AX-computed target.
    static func axToAppKit(_ r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height,
                      width: r.width, height: r.height)
    }
}
