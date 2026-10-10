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

    /// #197: screen frames of our status items whose clicks the macOS 27 session
    /// owns (empty below 27 — nothing changes there).
    private let systemOwnedFrames: () -> [NSRect]

    init(popover: NSPopover, canDismiss: @escaping () -> Bool = { true },
         systemOwnedFrames: @escaping () -> [NSRect] = { [] }) {
        self.popover = popover
        self.canDismiss = canDismiss
        self.systemOwnedFrames = systemOwnedFrames
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
        guard canDismiss(),
              !ExpandedInterfacePolicy.systemOwnsClick(p, itemFrames: systemOwnedFrames())
        else { return }
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

// #197: macOS 27 drives status-item popovers through an expanded-interface
// session (NSStatusItem.h:27-37): the system calls didBegin on the item's click
// or keyboard navigation and didEnd when it closes it (our item clicked again,
// another status menu opening, navigation away). That replaces target/action
// toggling and with it the ClickStamp reopen race. Below 27 nothing is installed
// and the #149 path above runs unchanged.

/// Pure decisions of the 27 path, testable without a status item.
enum ExpandedInterfacePolicy {
    /// didEnd: hide only the popover that belongs to the ending item (Stats: the
    /// system may begin B before ending A), and never a pinned one (Calendar).
    static func hidesOnEnd(pinned: Bool, showingThisItem: Bool) -> Bool {
        showingThisItem && !pinned
    }

    /// A click on one of our own status items belongs to the session — closing
    /// on it here would end the session and let the same click begin a new one.
    /// Closed rect, like `shouldDismiss`'s frame rule.
    static func systemOwnsClick(_ p: NSPoint, itemFrames: [NSRect]) -> Bool {
        itemFrames.contains { ($0.minX...$0.maxX).contains(p.x) && ($0.minY...$0.maxY).contains(p.y) }
    }
}

/// Routes an item's session to `begin`/`end`. Holds itself as the weak
/// `expandedInterfaceDelegate` of every item it is installed on — the owner
/// must keep it alive.
@MainActor
final class ExpandedInterfaceBridge: NSObject {
    private let begin: (NSStatusItem) -> Void
    private let end: (NSStatusItem) -> Void
    private let items = NSHashTable<NSStatusItem>.weakObjects()

    init(begin: @escaping (NSStatusItem) -> Void, end: @escaping (NSStatusItem) -> Void) {
        self.begin = begin
        self.end = end
    }

    /// true on macOS 27: the system now opens/closes, so the caller must NOT also
    /// wire button target/action. false below 27: wire target/action as before.
    // #197: the session API is macOS 27 SDK only; Xcode 26 (Swift 6.2/6.3) builds get the < 27 path everywhere.
    func install(on item: NSStatusItem) -> Bool {
        #if compiler(>=6.4)
        guard #available(macOS 27, *) else { return false }
        item.expandedInterfaceDelegate = self
        items.add(item)
        return true
        #else
        return false
        #endif
    }

    /// We closed (Escape, transient, outside click, an action in the popover) or
    /// pinned: tell the menu bar. It answers with didEnd, so `end` must be
    /// idempotent. `only`: just that item's session (Stats — another item's may
    /// be about to begin). No-op below 27 or with no live session.
    func cancelSessions(only item: NSStatusItem? = nil) {
        #if compiler(>=6.4)
        guard #available(macOS 27, *) else { return }
        for i in item.map({ [$0] }) ?? items.allObjects { i.expandedInterfaceSession?.cancel() }
        #else
        _ = item
        #endif
    }

    /// Our items' frames, for the dismisser to leave their clicks to the system.
    var itemFrames: [NSRect] { items.allObjects.compactMap { $0.button?.window?.frame } }
}

#if compiler(>=6.4)
@available(macOS 27, *)
extension ExpandedInterfaceBridge: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin _: NSStatusItemExpandedInterfaceSession) {
        begin(statusItem)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated _: Bool) {
        end(statusItem)
    }
}
#endif
