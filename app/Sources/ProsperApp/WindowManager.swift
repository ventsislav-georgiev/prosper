import AppKit
import ApplicationServices

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
