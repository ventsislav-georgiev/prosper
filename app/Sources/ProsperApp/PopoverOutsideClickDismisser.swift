// #149: the one outside-click dismisser shared by the Stats, Mixer and Calendar
// menu-bar popovers.
//
// `.transient` covers clicks that activate another app, but as an accessory
// (LSUIElement) app we don't reliably receive the dismissing event for clicks on
// the desktop / a non-activating spot — so a global monitor closes it explicitly.
// The old copies assumed a global monitor never sees clicks on our own windows;
// on macOS 27 it does, and a click INSIDE the popover closed it. So the rule is now
// geometric, not routing-based: close only when the click lands outside the
// popover's window frame.

import AppKit

@MainActor
final class PopoverOutsideClickDismisser {
    private let popover: NSPopover
    /// Extra veto checked at click time (Calendar: pinned popovers stay open).
    private let canDismiss: () -> Bool
    private var monitor: Any?

    init(popover: NSPopover, canDismiss: @escaping () -> Bool = { true }) {
        self.popover = popover
        self.canDismiss = canDismiss
    }

    /// Arm while shown, drop when closed (no idle event tap when nothing is open).
    func setArmed(_ armed: Bool) {
        if armed {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.canDismiss() else { return }
                    // A global monitor's event carries no `window`, so its
                    // `locationInWindow` is not a usable screen point; the cursor
                    // position read now is, in the same bottom-left screen space
                    // as `NSWindow.frame`.
                    let frame = self.popover.contentViewController?.view.window?.frame
                    if Self.shouldDismiss(click: NSEvent.mouseLocation, popoverFrame: frame) {
                        self.popover.performClose(nil)
                    }
                }
            }
        } else if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// Pure decision. A point on the frame edge counts as inside (closed rect —
    /// unlike `NSPointInRect`, which excludes the max edges); no frame means the
    /// popover isn't on screen, so dismiss.
    nonisolated static func shouldDismiss(click: NSPoint, popoverFrame: NSRect?) -> Bool {
        guard let f = popoverFrame else { return true }
        let inside = (f.minX...f.maxX).contains(click.x) && (f.minY...f.maxY).contains(click.y)
        return !inside
    }
}
