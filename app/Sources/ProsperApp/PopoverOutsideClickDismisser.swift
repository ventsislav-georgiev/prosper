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
import os

/// #414: which closer wins the status-item click race, for the next beta's logs.
private let popoverLog = Logger(subsystem: "eu.illegible.prosper", category: "popover")

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
    /// #415: when the popover last closed and on which click (stamp nil for Escape
    /// and other non-mouse closes). The status button's action fires on mouse-up;
    /// when AppKit's transient close beats the monitor to the mouse-down, the
    /// monitor is removed before it stamps, so this is the only record of the click.
    private var lastClose: (stamp: ClickStamp?, at: TimeInterval)?

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
    /// owns (empty below 27 — nothing changes there). Given the click (#978: the
    /// host is read only for a click inside a frame).
    private let systemOwnedFrames: (NSPoint) -> [NSRect]

    init(popover: NSPopover, canDismiss: @escaping () -> Bool = { true },
         systemOwnedFrames: @escaping (NSPoint) -> [NSRect] = { _ in [] }) {
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
            // #415: armed to disarmed with the popover gone is a close (every
            // popoverDidClose lands here through updateOutsideClickMonitor). Not a
            // pin toggle with the popover still shown, not an init-time disarm.
            // Same clock as NSEvent.timestamp.
            if !popover.isShown {
                noteClosed(stamp: ClickStamp(NSApp?.currentEvent), at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    /// #415: setArmed(false)'s record of the close; internal so tests pass explicit values.
    func noteClosed(stamp: ClickStamp?, at: TimeInterval) { lastClose = (stamp, at) }

    /// The monitor's body; internal so tests can drive a click without an event tap.
    func handleClick(_ event: NSEvent, at p: NSPoint) {
        guard canDismiss() else { return }
        // Read once: on 27 the frames cost an Accessibility read of the host (#978).
        let owned = systemOwnedFrames(p)
        guard !ExpandedInterfacePolicy.systemOwnsClick(p, itemFrames: owned) else { return }
        let frame = popover.contentViewController?.view.window?.frame
        if Self.shouldDismiss(ownerPID: Self.ownerPID(at: p), ourPID: getpid(),
                              click: p, popoverFrame: frame) {
            let n = owned.count
            popoverLog.debug("dismisser closes at (\(p.x, privacy: .public), \(p.y, privacy: .public)), item frames \(n, privacy: .public)")
            lastDismissClick = ClickStamp(event)
            popover.performClose(nil)
        }
    }

    /// #149/#415: true when the popover closed on `event`, whoever closed it (the
    /// monitor's stamp, or the recorded close for AppKit's transient close) — the
    /// status item's own toggle click; the caller must then NOT reopen. Consumes
    /// both records so the next genuine click opens normally.
    func dismissed(by event: NSEvent?) -> Bool {
        defer { lastDismissClick = nil; lastClose = nil }
        let click = ClickStamp(event)
        return Self.isSameClick(lastDismissClick, click) || Self.closedByThisClick(close: lastClose, event: click)
    }

    /// Pure. #415: the close was this click when its stamp is the same click, or
    /// when the click lands within `window` of the close on either side: on a busy
    /// main thread a fast tap's mouse-up carries a hardware timestamp earlier than
    /// the close's own clock read.
    nonisolated static func closedByThisClick(close: (stamp: ClickStamp?, at: TimeInterval)?, event: ClickStamp?,
                                              window: TimeInterval = ExpandedInterfacePolicy.sameClickWindow) -> Bool {
        guard let close, let event else { return false }
        if isSameClick(close.stamp, event) { return true }
        return abs(event.time - close.at) < window
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
        ownerPID(windowNumber: NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)) {
            CGWindowListCopyWindowInfo([.optionIncludingWindow], $0) as? [[String: Any]]
        }
    }

    /// #980: `ownerPID(at:)`'s decision. `info` is the window-list read, called (synchronously, on
    /// the caller's thread) only for a window number > 0. The first entry's owner pid; no bounds
    /// or layer rule (the topmost window is the system's pick). Outside data: a window number or
    /// pid that does not fit gives nil, never a trap.
    nonisolated static func ownerPID(windowNumber n: Int, info: (CGWindowID) -> [[String: Any]]?) -> pid_t? {
        guard n > 0, let id = CGWindowID(exactly: n),
              let pid = info(id)?.first?[kCGWindowOwnerPID as String] as? Int
        else { return nil }
        return pid_t(exactly: pid)
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
// or keyboard navigation and didEnd when it closes it (another status menu
// opening, navigation away — not our item clicked again, #430). That replaces target/action
// toggling and with it the ClickStamp reopen race. Below 27 nothing is installed
// and the #149 path above runs unchanged.

/// Pure decisions of the 27 path, testable without a status item.
enum ExpandedInterfacePolicy {
    /// didEnd: hide only the popover that belongs to the ending item (Stats: the
    /// system may begin B before ending A), and never a pinned one (Calendar).
    static func hidesOnEnd(pinned: Bool, showingThisItem: Bool) -> Bool {
        showingThisItem && !pinned
    }

    /// A click inside `itemFrames` (from `systemOwnedFrames`) belongs to the system,
    /// which begins that item's session. Closed rect, like `shouldDismiss`'s frame rule.
    static func systemOwnsClick(_ p: NSPoint, itemFrames: [NSRect]) -> Bool {
        itemFrames.contains { ($0.minX...$0.maxX).contains(p.x) && ($0.minY...$0.maxY).contains(p.y) }
    }

    /// #430: the frames `systemOwnsClick` leaves to the system — items with no live
    /// session (a click there begins one: Stats B while A is open). Not the item whose
    /// session is live: macOS 27 does not end it on that click (AppKit's
    /// _beginExpandedInterfaceSession: returns early while a session exists, and the
    /// session's own click monitor, NSStatusItemCancelOnClickMonitor, is off), so the
    /// dismisser closes the popover; a begin the same click sends after that is
    /// dropped by AppKit's dismiss timestamp or refused by `isReopenOfSameClick`.
    ///
    /// #978: the client frames are the buttons' window frames: one per item, on one display,
    /// holding the last laid-out position while the host overflows or drops the item.
    /// #1032: so when the host is readable and complete (`hostSlots`: our slots in the AX
    /// top-left space, nil when unreadable or partial), the frames are the host's slots of
    /// THIS bridge's non-live items (`sameItem`) on every display, converted to the click's
    /// Cocoa space with `screens` (Cocoa frames, primary first). Every other slot of ours (the
    /// main icon, extensions, another owner's items, the live item) stays the dismisser's.
    /// Otherwise every client frame, as before #978. With `click`, the host is read only for
    /// a click inside a client frame or on a menu bar not left of every possible match
    /// (`leftOfEveryMatch`): elsewhere the answer is the same without it.
    @MainActor
    static func systemOwnedFrames(_ items: [(frame: NSRect, sessionLive: Bool)], click: NSPoint? = nil,
                                  screens: [CGRect] = [], hostSlots: () -> [CGRect]? = { nil }) -> [NSRect] {
        let frames = items.filter { !$0.sessionLive }.map(\.frame)
        guard !frames.isEmpty,
              click.map({ systemOwnsClick($0, itemFrames: frames)
                  || (onMenuBar($0, screens: screens) && !leftOfEveryMatch($0, frames: frames, screens: screens)) }) ?? true,
              let slots = hostSlots(), let laid = cocoaSlots(slots, screens: screens) else { return frames }
        return laid.filter { s in frames.contains { sameItem($0, s, screens: screens) } }
    }

    /// #1032: AX slots in the Cocoa space, nil when there is no primary screen to flip
    /// against. Host values are outside data: a non-finite or empty slot, or one not
    /// wholly on a screen, is skipped.
    @MainActor
    static func cocoaSlots(_ slots: [CGRect], screens: [CGRect]) -> [CGRect]? {
        guard let h = screens.first?.height, h.isFinite, h > 0 else { return nil }
        return slots.compactMap { s in
            guard [s.minX, s.minY, s.width, s.height].allSatisfy(\.isFinite), s.width > 0, s.height > 0 else { return nil }
            let c = WindowManager.toAX(s, primaryHeight: h)   // the flip is its own inverse: AX -> Cocoa
            return screens.contains { $0.contains(c) } ? c : nil
        }
    }

    /// The screen holding `r`'s center (closed rect). Comparisons, not ranges: a NaN edge
    /// would trap a range.
    static func screen(of r: CGRect, in screens: [CGRect]) -> CGRect? {
        screens.first { $0.minX <= r.midX && r.midX <= $0.maxX && $0.minY <= r.midY && r.midY <= $0.maxY }
    }

    /// #1032: is `p` on a screen's menu bar (its top 48 pt, isBarItem's tallest slot)?
    static func onMenuBar(_ p: NSPoint, screens: [CGRect]) -> Bool {
        screens.contains { $0.minX <= p.x && p.x <= $0.maxX && p.y <= $0.maxY && p.y >= $0.maxY - 48 }
    }

    /// #1032 round 3: is `p` farther from its screen's right edge than every frame's left edge (on the frame's
    /// own screen) plus 3 pt? A slot `sameItem` matches starts under 3 pt off that and extends right, so `p`
    /// lands in none and the host read can be skipped. false (read) for a frame on no screen, a non-finite
    /// distance, a point on no screen, or overlapping screens (the slot's screen is then not surely `p`'s).
    static func leftOfEveryMatch(_ p: NSPoint, frames: [NSRect], screens: [CGRect]) -> Bool {
        var reach = -CGFloat.infinity
        for f in frames {
            guard let cs = screen(of: f, in: screens), (cs.maxX - f.minX).isFinite else { return false }
            if cs.maxX - f.minX > reach { reach = cs.maxX - f.minX }
        }
        let overlap = screens.contains { a in screens.contains { b in
            a != b && a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY } }
        let mine = screens.filter { $0.minX <= p.x && p.x <= $0.maxX && $0.minY <= p.y && p.y <= $0.maxY }
        return !overlap && !mine.isEmpty && mine.allSatisfy { $0.maxX - p.x > reach + 3 }
    }

    /// #1032: is host `slot` the item whose client frame is `client`? On the client frame's
    /// own display: within 3 pt of its x (#978). The host lays the same items right-aligned
    /// on every bar, so on another display: the same distance from that display's right edge
    /// (on the own display that distance is the x test). A frame on no screen: x alone.
    // shortcut: unverified on a live two-display bar (no identifier the tree shows the host carries);
    // if the bars differ, match our slots by order per display (left.txt).
    static func sameItem(_ client: CGRect, _ slot: CGRect, screens: [CGRect]) -> Bool {
        guard let cs = screen(of: client, in: screens), let ss = screen(of: slot, in: screens) else {
            return abs(client.minX - slot.minX) < 3
        }
        return abs((cs.maxX - client.minX) - (ss.maxX - slot.minX)) < 3
    }

    /// #1032: the log line for a host read that came back partial or ran past `deadline`
    /// (its slots are then not used, or used late), nil for a whole read in time. Counts, plus the first
    /// failed read's raw AXError and the literal attribute name (round 3).
    static func hostReadNote(complete: Bool, elapsed: TimeInterval, deadline: TimeInterval, count: Int,
                             firstError: MenuBarAX.ReadError? = nil) -> String? {
        let late = !(elapsed < deadline)
        guard !complete || late else { return nil }
        let error = firstError.map { ", first error \($0.code) on \($0.attribute)" } ?? ""
        return "host read \(late ? "past the deadline" : "partial") after \(String(format: "%.3f", elapsed)) s, \(count) items read\(error)"
    }

    /// #978: `pid`'s slots in a host layout (MenuBarAX.layout). nil for an empty one:
    /// the bar always holds the agent's own items (clock, Control Center), so empty is
    /// a failed read, not "none of ours laid out". #1032: nil for a partial read too.
    static func ownSlots(in laid: [MenuBarAX.Laid], pid: pid_t, complete: Bool) -> [CGRect]? {
        guard complete, !laid.isEmpty else { return nil }
        return laid.filter { $0.pid == pid }.map(\.frame)
    }

    /// #414/#415: how soon after a close a new open counts as the click that closed
    /// it. Serves both paths: the macOS 27 session's begin after the item's end, and
    /// the target/action button click after the popover's close. Long enough to
    /// cover the begin or the mouse-up landing after the transient/monitor close;
    /// the cost is that a double-click on the open icon stays closed on the session
    /// path (the button path consumes the record on the first click; its second reopens).
    // ponytail: time window only. Two swallowed cases: a keyboard return to the
    // same item within 0.4 s, and a fast A, B, A Stats switch on the session path
    // (the second A begin lands inside the window of A's own end). One reopen case
    // on the button path: a press held longer than 0.4 s whose action event carries
    // no matching event number falls back to time and reopens (the stamp taken from
    // NSApp.currentEvent at close covers the normal case, where the mouse-down is
    // current). If any shows up, compare NSEvent.mouseLocation against the item
    // frame at close and open.
    static let sameClickWindow: TimeInterval = 0.4

    /// #414: a begin this soon after the same item's session ended is the second
    /// half of the click that just closed it (the session is modelled on menu
    /// tracking: a click on the live item closes, never reopens).
    static func isReopenOfSameClick(endedAt: TimeInterval?, now: TimeInterval,
                                    window: TimeInterval = sameClickWindow) -> Bool {
        guard let endedAt else { return false }
        return now - endedAt < window
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
    /// #414: when each item's session last ended or was cancelled by us.
    private let endedAt = NSMapTable<NSStatusItem, NSNumber>.weakToStrongObjects()
    private let now: () -> TimeInterval
    /// #978: the host's slots for our items (see `systemOwnedFrames`); the controllers
    /// pass `liveHostSlots`, tests a fake. Default: unreadable.
    private let hostSlots: () -> [CGRect]?
    /// Test seam: client frames and live flags fed instead of the installed items'
    /// (nil reads the items), so no test needs a real status item.
    private let clientFrames: (() -> [(frame: NSRect, sessionLive: Bool)])?
    /// #1032: the screens' Cocoa frames, primary first; read on main at each click.
    private let screens: @MainActor () -> [CGRect]

    init(begin: @escaping (NSStatusItem) -> Void, end: @escaping (NSStatusItem) -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         hostSlots: @escaping () -> [CGRect]? = { nil },
         clientFrames: (() -> [(frame: NSRect, sessionLive: Bool)])? = nil,
         screens: @escaping @MainActor () -> [CGRect] = { NSScreen.screens.map(\.frame) }) {
        self.begin = begin
        self.end = end
        self.now = now
        self.hostSlots = hostSlots
        self.clientFrames = clientFrames
        self.screens = screens
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
    /// be about to begin). Cancels nothing below 27 or with no live session, but
    /// always stamps the end time the same-click guard reads.
    func cancelSessions(only item: NSStatusItem? = nil) {
        let targets = item.map { [$0] } ?? items.allObjects
        // #414: stamped whether or not a session is live — this is when we gave it up.
        for i in targets { stampEnd(i) }
        #if compiler(>=6.4)
        guard #available(macOS 27, *) else { return }
        for i in targets {
            popoverLog.debug("session cancel, live \(i.expandedInterfaceSession != nil, privacy: .public)")
            i.expandedInterfaceSession?.cancel()
        }
        #endif
    }

    private func stampEnd(_ item: NSStatusItem) { endedAt.setObject(NSNumber(value: now()), forKey: item) }

    /// didBegin's body. A begin right after this item's session ended is the click
    /// that just closed it: refuse the new session instead of reopening.
    func sessionDidBegin(_ item: NSStatusItem, cancelSession: () -> Void) {
        if ExpandedInterfacePolicy.isReopenOfSameClick(endedAt: endedAt.object(forKey: item)?.doubleValue,
                                                       now: now()) {
            popoverLog.debug("session begin refused as the same click")
            cancelSession()
            return
        }
        popoverLog.debug("session begin forwarded")
        Self.hostReadNoted = false
        begin(item)
    }

    /// didEnd's body.
    func sessionDidEnd(_ item: NSStatusItem) {
        stampEnd(item)
        popoverLog.debug("session end")
        end(item)
    }

    /// Our items' frames, for the dismisser to leave their clicks to the system —
    /// all but the item with a live session (#430).
    var itemFrames: [NSRect] { itemFrames(at: nil) }

    /// The same for a click at `click` (#978: the host is read only when it is inside one).
    func itemFrames(at click: NSPoint?) -> [NSRect] {
        ExpandedInterfacePolicy.systemOwnedFrames(clientFrames?() ?? items.allObjects.compactMap { i in
            i.button?.window.map { (frame: $0.frame, sessionLive: Self.hasLiveSession(i)) }
        }, click: click, screens: screens(), hostSlots: hostSlots)
    }

    /// #1032: the host read's total budget. It runs on main inside the click handler, and
    /// each element read may take 0.25 s. Unmeasured against a healthy read (left.txt).
    static let hostReadDeadline: TimeInterval = 0.25
    /// #1032: the partial/late note was logged since the last forwarded begin (one per open).
    private static var hostReadNoted = false

    /// #978: our slots in MenuBarAgent's live layout; nil without Accessibility, without
    /// the agent (below 27), on a failed or partial read (#1032), or past `hostReadDeadline`.
    static func liveHostSlots() -> [CGRect]? {
        let start = ProcessInfo.processInfo.systemUptime
        guard let read = MenuBarAX.layoutRead(deadline: hostReadDeadline) else { return nil }
        if !hostReadNoted, let note = ExpandedInterfacePolicy.hostReadNote(
            complete: read.complete, elapsed: ProcessInfo.processInfo.systemUptime - start,
            deadline: hostReadDeadline, count: read.laid.count, firstError: read.firstError) {
            hostReadNoted = true
            popoverLog.notice("\(note, privacy: .public)")
        }
        return ExpandedInterfacePolicy.ownSlots(in: read.laid, pid: getpid(), complete: read.complete)
    }

    private static func hasLiveSession(_ item: NSStatusItem) -> Bool {
        #if compiler(>=6.4)
        if #available(macOS 27, *) { return item.expandedInterfaceSession != nil }
        #endif
        return false
    }
}

#if compiler(>=6.4)
@available(macOS 27, *)
extension ExpandedInterfaceBridge: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        sessionDidBegin(statusItem) { session.cancel() }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated _: Bool) {
        sessionDidEnd(statusItem)
    }
}
#endif
