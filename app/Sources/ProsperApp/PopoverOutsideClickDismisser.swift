// #149: the one outside-click dismisser shared by the Stats, Mixer and Calendar
// menu-bar popovers.
//
// `.transient` covers clicks that activate another app, but as an accessory
// (LSUIElement) app we don't reliably receive the dismissing event for clicks on
// the desktop / a non-activating spot — so a global monitor closes it explicitly.
// The old copies assumed a global monitor never sees clicks on our own windows;
// on macOS 27 it does, and a click INSIDE the popover closed it. So the old rule —
// "only clicks on OTHER apps dismiss" — is now restored by asking who owns the
// window under the click, not by trusting event routing. That also covers the
// menus/pickers opened from inside a popover, which can sit outside its frame.

import AppKit

@MainActor
final class PopoverOutsideClickDismisser {
    private let popover: NSPopover
    /// Extra veto checked at click time (Calendar: pinned popovers stay open).
    private let canDismiss: () -> Bool
    private var monitor: Any?
    /// #149: the click that made the monitor close the popover. On macOS 27 every
    /// menu-bar point — our own status items included — resolves to a WindowServer
    /// window (pid 180), so a click on the status item is FOREIGN here: the monitor
    /// closes, then the button action sees `isShown == false` and reopens. The
    /// toggle action asks `dismissed(by:)` to recognise that same click and stay
    /// closed. Do not drop this as redundant with the pid rule — it exists because
    /// of it.
    private var lastDismissClick: ClickStamp?

    /// Identity of one physical click: its time (seconds since boot) and the
    /// mouse-event number, which a mouse-up shares with its mouse-down.
    struct ClickStamp: Equatable {
        let time: TimeInterval
        let number: Int

        /// nil for non-mouse events — `eventNumber` raises on those.
        init?(_ e: NSEvent?) {
            guard let e, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                          .otherMouseDown, .otherMouseUp].contains(e.type) else { return nil }
            self.init(time: e.timestamp, number: e.eventNumber)
        }
        init(time: TimeInterval, number: Int) { self.time = time; self.number = number }
    }

    init(popover: NSPopover, canDismiss: @escaping () -> Bool = { true }) {
        self.popover = popover
        self.canDismiss = canDismiss
    }

    /// Arm while shown, drop when closed (no idle event tap when nothing is open).
    func setArmed(_ armed: Bool) {
        if armed {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // The click's own position, not the cursor's when the handler runs.
                // A global monitor's event has no `window`, and then
                // `locationInWindow` is already in screen coordinates (documented);
                // with a window it is window-relative and needs converting.
                let p = event.window?.convertPoint(toScreen: event.locationInWindow)
                    ?? event.locationInWindow
                MainActor.assumeIsolated { self?.handleClick(event, at: p) }
            }
        } else if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// The monitor's body; internal so tests can drive a click without an event tap.
    func handleClick(_ event: NSEvent, at p: NSPoint) {
        guard canDismiss() else { return }
        let frame = popover.contentViewController?.view.window?.frame
        if Self.shouldDismiss(ownerPID: Self.ownerPID(at: p), ourPID: getpid(),
                              click: p, popoverFrame: frame) {
            lastDismissClick = ClickStamp(event)
            popover.performClose(nil)
        }
    }

    /// #149: true when `event` is the click the monitor just closed the popover
    /// on — the status item's own toggle click; the caller must then NOT reopen.
    /// Consumes the stamp so the next genuine click opens normally.
    func dismissed(by event: NSEvent?) -> Bool {
        defer { lastDismissClick = nil }
        return Self.isSameClick(lastDismissClick, ClickStamp(event))
    }

    /// Pure. Same click when the mouse-event numbers match — the status button
    /// fires its action on mouse-UP (default NSButton mask), whose timestamp is a
    /// human press-length after the mouse-down the monitor saw, but whose
    /// `eventNumber` is the down's — or when the timestamps agree within
    /// `tolerance` (the monitor's copy and the delivered event are distinct objects).
    nonisolated static func isSameClick(_ a: ClickStamp?, _ b: ClickStamp?,
                                        tolerance: TimeInterval = 0.005) -> Bool {
        guard let a, let b else { return false }
        return a.number == b.number || abs(a.time - b.time) <= tolerance
    }

    /// #149: pid of the topmost on-screen window at `p` (screen coords), nil when
    /// nothing resolves. Pid, not `NSApp.windows`: menu/picker windows may not be
    /// listed there, and a nil from `NSApp.window(withWindowNumber:)` would fail
    /// OPEN on exactly the menu case. The owner pid is not gated by Screen
    /// Recording (window names are; we don't read them).
    private static func ownerPID(at p: NSPoint) -> pid_t? {
        let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        guard n > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(n))
                as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? Int
        else { return nil }
        return pid_t(pid)
    }

    /// Pure decision. Our own window under the click (popover, its menus,
    /// pickers) → keep; another app's window → dismiss whatever the frame says.
    /// Owner unknown → frame rule: a point on the edge counts as inside (closed
    /// rect — unlike `NSPointInRect`, which excludes the max edges); no frame
    /// means the popover isn't on screen, so dismiss.
    nonisolated static func shouldDismiss(ownerPID: pid_t?, ourPID: pid_t,
                                          click: NSPoint, popoverFrame: NSRect?) -> Bool {
        if let ownerPID { return ownerPID != ourPID }
        guard let f = popoverFrame else { return true }
        let inside = (f.minX...f.maxX).contains(click.x) && (f.minY...f.maxY).contains(click.y)
        return !inside
    }
}
