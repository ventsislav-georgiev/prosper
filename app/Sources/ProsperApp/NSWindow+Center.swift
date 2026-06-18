import AppKit

extension NSWindow {

    /// Centers the window on the *true* geometric center of its screen's visible
    /// frame (both axes).
    ///
    /// `NSWindow.center()` deliberately places the window ABOVE center — AppKit
    /// biases it toward the top third ("slightly more space below than above") so
    /// document windows don't crowd the menu bar. For modal dialogs and panels
    /// that reads as misaligned. This positions the window so its midpoint matches
    /// the visible frame's midpoint exactly, then pins it inside the visible area.
    func centerOnScreen() {
        let screen = self.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            center()
            return
        }
        let size = frame.size
        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        // Keep fully on-screen if the window is taller/wider than the visible area.
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        setFrameOrigin(origin)
    }
}
