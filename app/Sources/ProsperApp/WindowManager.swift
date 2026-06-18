import AppKit
import ApplicationServices

/// Built-in window-management actions, applied to the frontmost app's focused
/// window via the Accessibility API (same permission as autocomplete). Bound to
/// rebindable global shortcuts in `ShortcutAction` and registered in AppDelegate.
enum WindowAction {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case maximize
    case center

    /// Half-screen snaps that cycle their size on repeat presses.
    var isDirectionalHalf: Bool {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return true
        case .maximize, .center: return false
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

    /// Moves/resizes the frontmost window for `action`. No-op when there is no
    /// focused window or it doesn't expose position/size (some AX-opaque apps).
    static func perform(_ action: WindowAction) {
        guard let win = focusedWindowElement(),
              let pos = axPoint(win, kAXPositionAttribute),
              let size = axSize(win, kAXSizeAttribute) else { return }
        let current = CGRect(origin: pos, size: size)
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

        let target: CGRect
        switch action {
        case .leftHalf:
            let w = (v.width * frac).rounded()
            target = CGRect(x: v.minX, y: v.minY, width: w, height: v.height)
        case .rightHalf:
            let w = (v.width * frac).rounded()
            target = CGRect(x: v.maxX - w, y: v.minY, width: w, height: v.height)
        case .topHalf:
            let h = (v.height * frac).rounded()
            target = CGRect(x: v.minX, y: v.minY, width: v.width, height: h)
        case .bottomHalf:
            let h = (v.height * frac).rounded()
            target = CGRect(x: v.minX, y: v.maxY - h, width: v.width, height: h)
        case .maximize:
            target = v
        case .center:
            // Keep the window's size, clamped to the visible area, and centre it.
            let w = min(current.width, v.width)
            let h = min(current.height, v.height)
            target = CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
        }
        setFrame(win, target, within: v)
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
    private static func setFrame(_ win: AXUIElement, _ rect: CGRect, within v: CGRect) {
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

    /// Visible frame (Dock/menu-bar excluded) of the screen the window sits on, in
    /// the AX top-left global space. Picks the screen containing the window centre,
    /// else the largest overlap, else main.
    private static func visibleFrameAX(for winRectAX: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func toAX(_ r: CGRect) -> CGRect {
            CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height,
                   width: r.width, height: r.height)
        }
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
}
