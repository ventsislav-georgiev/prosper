import XCTest
@testable import ProsperApp

// #149: clicks on our own windows (popover, its menus) keep the popover open;
// clicks on another app close it; unknown owner falls back to the frame check.
final class PopoverOutsideClickDismisserTests: XCTestCase {
    private let frame = NSRect(x: 100, y: 200, width: 300, height: 400)
    private let me: pid_t = 100
    private let inside = NSPoint(x: 250, y: 400)
    private let outside = NSPoint(x: 50, y: 400)

    private func dismiss(_ owner: pid_t?, _ click: NSPoint, _ f: NSRect?) -> Bool {
        PopoverOutsideClickDismisser.shouldDismiss(ownerPID: owner, ourPID: me, click: click, popoverFrame: f)
    }

    // Owner unknown → frame rule.
    func testInsideKeepsOpen() { XCTAssertFalse(dismiss(nil, inside, frame)) }

    func testOutsideCloses() {
        XCTAssertTrue(dismiss(nil, outside, frame))
        XCTAssertTrue(dismiss(nil, NSPoint(x: 250, y: 601), frame))
    }

    func testNilFrameCloses() { XCTAssertTrue(dismiss(nil, inside, nil)) }

    func testEdgesCountAsInside() {
        for p in [NSPoint(x: 100, y: 200), NSPoint(x: 400, y: 600), NSPoint(x: 400, y: 300), NSPoint(x: 250, y: 600)] {
            XCTAssertFalse(dismiss(nil, p, frame), "\(p)")
        }
    }

    // Owner known → pid rule wins over the frame.
    func testOwnWindowInsideFrameKeepsOpen() { XCTAssertFalse(dismiss(me, inside, frame)) }

    func testOwnMenuOutsideFrameKeepsOpen() {
        XCTAssertFalse(dismiss(me, outside, frame))
        XCTAssertFalse(dismiss(me, outside, nil))
    }

    func testForeignWindowInsideFrameCloses() { XCTAssertTrue(dismiss(200, inside, frame)) }
}

// #149: recognising the status-item click the monitor already closed on.
final class PopoverDismissSameClickTests: XCTestCase {
    private typealias S = PopoverOutsideClickDismisser.ClickStamp
    private func same(_ a: S?, _ b: S?) -> Bool { PopoverOutsideClickDismisser.isSameClick(a, b) }

    func testEqualStampIsSame() { XCTAssertTrue(same(S(time: 10, number: 1), S(time: 10, number: 1))) }

    func testNilEitherSideIsNotSame() {
        XCTAssertFalse(same(nil, S(time: 10, number: 1)))
        XCTAssertFalse(same(S(time: 10, number: 1), nil))
        XCTAssertFalse(same(nil, nil))
    }

    func testWithinToleranceIsSame() { XCTAssertTrue(same(S(time: 10, number: 1), S(time: 10.004, number: 2))) }

    func testFiftyMsApartDifferentNumberIsNotSame() {
        XCTAssertFalse(same(S(time: 10, number: 1), S(time: 10.05, number: 2)))
    }

    // Mouse-up action event: later timestamp, same event number as the down.
    func testMouseUpOfSameClickMatchesByNumber() {
        XCTAssertTrue(same(S(time: 10, number: 7), S(time: 10.12, number: 7)))
    }
}

// #415: the button (target/action) path recognises the click the popover closed
// on even when AppKit's transient close beat the monitor to it. Named to match the
// PopoverDismissSameClickTests filter.
@MainActor
final class ButtonPathPopoverDismissSameClickTests: XCTestCase {
    private typealias S = PopoverOutsideClickDismisser.ClickStamp
    private func closed(_ close: (stamp: S?, at: TimeInterval)?, _ event: S?) -> Bool {
        PopoverOutsideClickDismisser.closedByThisClick(close: close, event: event)
    }

    private func mouse(_ type: NSEvent.EventType, _ n: Int, at t: TimeInterval) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: t,
                           windowNumber: 0, context: nil, eventNumber: n, clickCount: 1, pressure: 1)!
    }

    func testPureRows() {
        XCTAssertFalse(closed(nil, S(time: 10, number: 1)), "no close")
        XCTAssertFalse(closed((S(time: 10, number: 1), 10), nil), "no event")
        XCTAssertTrue(closed((S(time: 10, number: 9), 10), S(time: 10.5, number: 9)), "number beats the window")
        XCTAssertTrue(closed((nil, 10), S(time: 10.1, number: 12)), "inside the window")
        XCTAssertFalse(closed((nil, 0), S(time: 0.4, number: 12)), "the window is open-ended at 0.4 s")
        XCTAssertTrue(closed((nil, 10), S(time: 9.98, number: 12)), "earlier than the close, inside the window")
        XCTAssertFalse(closed((nil, 10), S(time: 9.5, number: 12)), "long before the close")
        XCTAssertFalse(closed((nil, 10), S(time: 11, number: 12)), "long after the close")
    }

    // (i) transient close on the mouse-down, action on its mouse-up.
    func testMouseUpOfTheClosingClickIsRecognisedOnce() {
        let d = PopoverOutsideClickDismisser(popover: NSPopover())
        d.noteClosed(stamp: S(time: 10, number: 9), at: 10)
        let up = mouse(.leftMouseUp, 9, at: 10.2)
        XCTAssertTrue(d.dismissed(by: up))
        XCTAssertFalse(d.dismissed(by: up), "consumed: the next click reopens")
    }

    // (ii) close with no mouse event, a click right after.
    func testClickInsideTheWindowIsRecognised() {
        let d = PopoverOutsideClickDismisser(popover: NSPopover())
        d.noteClosed(stamp: nil, at: 10)
        XCTAssertTrue(d.dismissed(by: mouse(.leftMouseDown, 20, at: 10.1)))
    }

    // (iii) a later click is a genuine reopen.
    func testClickAfterTheWindowReopens() {
        let d = PopoverOutsideClickDismisser(popover: NSPopover())
        d.noteClosed(stamp: nil, at: 10)
        XCTAssertFalse(d.dismissed(by: mouse(.leftMouseDown, 20, at: 11)))
    }

    // (iv) the production hook: armed to disarmed with the popover not shown is a
    // close. The one row in this file that arms: a listen-only mouse-down monitor,
    // removed by the setArmed(false) below.
    func testDisarmTransitionRecordsTheClose() {
        let d = PopoverOutsideClickDismisser(popover: NSPopover())
        d.setArmed(true)
        d.setArmed(false)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(d.dismissed(by: mouse(.leftMouseDown, 20, at: now)))
    }

    // A disarm with no monitor (init, nothing closing) records nothing.
    func testDisarmWithoutMonitorRecordsNothing() {
        let d = PopoverOutsideClickDismisser(popover: NSPopover())
        d.setArmed(false)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(d.dismissed(by: mouse(.leftMouseDown, 20, at: now)))
    }

    // (v) the monitor's stamp still recognises its click on its own.
    func testMonitorStampStillRecognised() {
        let d = PopoverOutsideClickDismisser(popover: NSPopover())
        let e = mouse(.leftMouseDown, 9, at: 10)
        d.handleClick(e, at: NSPoint(x: -100_000, y: -100_000))
        XCTAssertTrue(d.dismissed(by: e))
    }
}

// #213: the stamp lifecycle and the Stats per-module reopen skip.
@MainActor
final class PopoverDismissStampTests: XCTestCase {
    // Far off every screen: no window there, popover not shown → the monitor closes.
    private let far = NSPoint(x: -100_000, y: -100_000)

    private func click(_ n: Int) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 10,
                           windowNumber: 0, context: nil, eventNumber: n, clickCount: 1, pressure: 1)!
    }

    func testStampIsConsumedOnce() {
        let d = PopoverOutsideClickDismisser(popover: NSPopover())
        let e = click(5)
        d.handleClick(e, at: far)
        XCTAssertTrue(d.dismissed(by: e))
        XCTAssertFalse(d.dismissed(by: e), "second toggle click must reopen")
    }

    func testPinnedVetoLeavesNoStamp() {
        let d = PopoverOutsideClickDismisser(popover: NSPopover()) { false }
        let e = click(6)
        d.handleClick(e, at: far)
        XCTAssertFalse(d.dismissed(by: e))
    }

    func testStatsSkipsReopenOnlyForTheDismissedModule() {
        XCTAssertTrue(StatsController.skipsReopen(dismissedByClick: true, open: .cpu, clicked: .cpu))
        XCTAssertFalse(StatsController.skipsReopen(dismissedByClick: true, open: .cpu, clicked: .memory))
        XCTAssertFalse(StatsController.skipsReopen(dismissedByClick: false, open: .cpu, clicked: .cpu))
    }
}

// #197: the macOS 27 expanded-interface session decisions.
@MainActor
final class ExpandedInterfacePolicyTests: XCTestCase {
    private typealias P = ExpandedInterfacePolicy
    private let item = NSRect(x: 1000, y: 1100, width: 40, height: 24)

    func testEndHidesOnlyTheShownUnpinnedItem() {
        XCTAssertTrue(P.hidesOnEnd(pinned: false, showingThisItem: true))
        XCTAssertFalse(P.hidesOnEnd(pinned: false, showingThisItem: false), "Stats: B already began, A's end keeps B")
    }

    func testPinnedSurvivesEnd() {
        XCTAssertFalse(P.hidesOnEnd(pinned: true, showingThisItem: true))
    }

    func testClickOnOwnItemBelongsToTheSystem() {
        XCTAssertTrue(P.systemOwnsClick(NSPoint(x: 1020, y: 1110), itemFrames: [item]))
        XCTAssertTrue(P.systemOwnsClick(NSPoint(x: 1040, y: 1124), itemFrames: [.zero, item]), "edge is inside")
    }

    func testOtherClicksStayWithTheDismisser() {
        XCTAssertFalse(P.systemOwnsClick(NSPoint(x: 999, y: 1110), itemFrames: [item]))
        XCTAssertFalse(P.systemOwnsClick(NSPoint(x: 1020, y: 1110), itemFrames: []), "< 27: no frames")
    }

    // The dismisser consults the frames: a click on our item neither closes nor stamps.
    func testDismisserLeavesOwnItemClickAlone() {
        let p = NSPoint(x: -100_000, y: -100_000)   // off-screen → would close
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 10,
                                   windowNumber: 0, context: nil, eventNumber: 9, clickCount: 1, pressure: 1)!
        let d = PopoverOutsideClickDismisser(popover: NSPopover(),
                                             systemOwnedFrames: { _ in [NSRect(origin: p, size: NSSize(width: 1, height: 1))] })
        d.handleClick(e, at: p)
        XCTAssertFalse(d.dismissed(by: e))
    }

    // Below 27 the bridge installs nothing; on 27 it owns the item's delegate.
    // A private bar, not the system one (QA OQ-6): its item has a button and a
    // window like a real one, but never lands in the operator's menu bar.
    func testInstallMatchesTheOS() {
        let bar = NSStatusBar()
        let item = bar.statusItem(withLength: 10)
        defer { bar.removeStatusItem(item) }
        let bridge = ExpandedInterfaceBridge(begin: { _ in }, end: { _ in })
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            XCTAssertTrue(bridge.install(on: item))
            XCTAssertTrue(item.expandedInterfaceDelegate === bridge)
            XCTAssertNil(item.expandedInterfaceSession)
            bridge.cancelSessions()   // no live session: a no-op, must not trap
            XCTAssertEqual(bridge.itemFrames.count, 1, "the installed item is tracked and has a frame")
        } else {
            XCTAssertFalse(bridge.install(on: item))
        }
        #else
        XCTAssertFalse(bridge.install(on: item))
        #endif
    }

    // #414: a begin right after the same item's session ended is the click that
    // closed it, not a reopen.
    func testReopenOfSameClickWindow() {
        XCTAssertFalse(P.isReopenOfSameClick(endedAt: nil, now: 10))
        XCTAssertTrue(P.isReopenOfSameClick(endedAt: 10, now: 10.1))
        XCTAssertFalse(P.isReopenOfSameClick(endedAt: 10, now: 10.4), "the window is open-ended at 0.4 s")
        XCTAssertFalse(P.isReopenOfSameClick(endedAt: 10, now: 11))
    }

    /// A bridge on an injected clock counting its forwards, and a private-bar item.
    @MainActor private final class Rig {
        let bar = NSStatusBar()
        var t: TimeInterval = 100
        var begun: [NSStatusItem] = [], ended = 0, cancelled = 0
        lazy var bridge = ExpandedInterfaceBridge(begin: { [unowned self] in begun.append($0) },
                                                  end: { [unowned self] _ in ended += 1 },
                                                  now: { [unowned self] in t })
        func item() -> NSStatusItem { bar.statusItem(withLength: 10) }
        func beginAfter(_ dt: TimeInterval, _ item: NSStatusItem) {
            t += dt
            bridge.sessionDidBegin(item) { cancelled += 1 }
        }
    }

    // (i) the system ended the session on the click, then began a new one.
    func testBeginRightAfterEndIsRefused() {
        let r = Rig(), a = r.item()
        defer { r.bar.removeStatusItem(a) }
        r.bridge.sessionDidEnd(a)
        r.beginAfter(0.1, a)
        XCTAssertTrue(r.begun.isEmpty)
        XCTAssertEqual(r.cancelled, 1, "the refused session is cancelled, not left live")
        XCTAssertEqual(r.ended, 1)
    }

    // (ii) a later click is a genuine reopen.
    func testBeginLongAfterEndOpens() {
        let r = Rig(), a = r.item()
        defer { r.bar.removeStatusItem(a) }
        r.bridge.sessionDidEnd(a)
        r.beginAfter(1, a)
        XCTAssertEqual(r.begun.count, 1)
        XCTAssertEqual(r.cancelled, 0)
    }

    // (iii) transient/monitor closed first: our cancel is the end that counts.
    func testBeginRightAfterOurCancelIsRefused() {
        let r = Rig(), a = r.item()
        defer { r.bar.removeStatusItem(a) }
        r.bridge.cancelSessions(only: a)
        r.beginAfter(0.1, a)
        XCTAssertTrue(r.begun.isEmpty)
        XCTAssertEqual(r.cancelled, 1)
    }

    // (iv) Stats A → B: A's end never refuses B.
    func testEndOfOneItemDoesNotRefuseAnother() {
        let r = Rig(), a = r.item(), b = r.item()
        defer { r.bar.removeStatusItem(a); r.bar.removeStatusItem(b) }
        r.bridge.sessionDidEnd(a)
        r.beginAfter(0.1, b)
        XCTAssertEqual(r.begun.count, 1)
        XCTAssertTrue(r.begun.first === b)
        XCTAssertEqual(r.cancelled, 0)
    }

    // (v) after a refused begin the window closes again.
    func testRefusalDoesNotStick() {
        let r = Rig(), a = r.item()
        defer { r.bar.removeStatusItem(a) }
        r.bridge.sessionDidEnd(a)
        r.beginAfter(0.1, a)
        r.bridge.sessionDidEnd(a)   // the system's answer to the cancel
        r.beginAfter(1, a)
        XCTAssertEqual(r.begun.count, 1)
        XCTAssertTrue(r.begun.first === a)
        XCTAssertEqual(r.cancelled, 1)
    }
}

// #430: the second click on the open item's icon closes on macOS 27. Named to match
// the PopoverOutsideClickDismisserTests filter.
@MainActor
final class OpenItemPopoverOutsideClickDismisserTests: XCTestCase {
    private let item = NSRect(x: 1000, y: 1100, width: 40, height: 24)

    // #430: macOS 27 sends nothing usable for a click on the item whose session is
    // live, so that click is the dismisser's; another item's click still begins its
    // own session (Stats A open, B clicked).
    func testOpenItemClickIsTheDismissersOtherItemsStayTheSystems() {
        let other = NSRect(x: 1100, y: 1100, width: 40, height: 24)
        let owned = ExpandedInterfacePolicy.systemOwnedFrames([(item, sessionLive: true), (other, sessionLive: false)])
        XCTAssertFalse(ExpandedInterfacePolicy.systemOwnsClick(NSPoint(x: 1020, y: 1110), itemFrames: owned), "second click on the open item")
        XCTAssertTrue(ExpandedInterfacePolicy.systemOwnsClick(NSPoint(x: 1120, y: 1110), itemFrames: owned), "a different module still opens")
        XCTAssertEqual(ExpandedInterfacePolicy.systemOwnedFrames([(item, sessionLive: false)]), [item], "no session: the click begins one")
    }

    // #430 through the dismisser: a click on the open item closes and stamps. The
    // begin that click may send next is refused by testBeginRightAfterOurCancelIsRefused's rule.
    func testDismisserClosesOnTheOpenItemsClick() {
        let p = NSPoint(x: -100_000, y: -100_000)   // off-screen → would close
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 10,
                                   windowNumber: 0, context: nil, eventNumber: 9, clickCount: 1, pressure: 1)!
        let open = NSRect(origin: p, size: NSSize(width: 1, height: 1))
        let d = PopoverOutsideClickDismisser(popover: NSPopover(),
                                             systemOwnedFrames: { _ in ExpandedInterfacePolicy.systemOwnedFrames([(open, sessionLive: true)]) })
        d.handleClick(e, at: p)
        XCTAssertTrue(d.dismissed(by: e))
    }
}

// #978: on macOS 27 the item frames are the buttons' client window frames, which keep
// the last laid-out position while the host overflows or drops the item. Fed through the
// bridge's seams: no status item, no Accessibility read. Named to match the
// PopoverOutsideClickDismisserTests filter.
@MainActor
final class StaleFramePopoverOutsideClickDismisserTests: XCTestCase {
    private typealias Frames = [(frame: NSRect, sessionLive: Bool)]
    // Off every screen: no window there and the popover not shown, so the dismisser
    // closes unless an item frame takes the click.
    private let p = NSPoint(x: -100_000, y: -100_000)
    /// The client frame around `p` (Cocoa, bottom-left).
    private var client: NSRect { NSRect(x: p.x - 10, y: p.y - 10, width: 40, height: 24) }
    /// A host slot (AX, top-left: only x is comparable) `dx` right of the client frame.
    private func slot(_ dx: CGFloat) -> CGRect { CGRect(x: client.minX + dx, y: 0, width: 40, height: 24) }

    private func bridge(_ frames: Frames, slots: [CGRect]?) -> ExpandedInterfaceBridge {
        ExpandedInterfaceBridge(begin: { _ in }, end: { _ in }, hostSlots: { slots }, clientFrames: { frames })
    }

    /// true when the dismisser took a click at `at` (closed and stamped it).
    private func closes(_ b: ExpandedInterfaceBridge, at q: NSPoint? = nil) -> Bool {
        let d = PopoverOutsideClickDismisser(popover: NSPopover(), systemOwnedFrames: { b.itemFrames(at: $0) })
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 10,
                                   windowNumber: 0, context: nil, eventNumber: 9, clickCount: 1, pressure: 1)!
        d.handleClick(e, at: q ?? p)
        return d.dismissed(by: e)
    }

    // QA #65 F: the stale frame lies over another app's item; that click is an outside click.
    func testStaleFrameOverAnotherItemIsTheDismissers() {
        XCTAssertTrue(closes(bridge([(client, false)], slots: [slot(200)])), "overflowed: the host lays it out elsewhere")
        XCTAssertTrue(closes(bridge([(client, false)], slots: [])), "dropped: no slot of ours")
        XCTAssertTrue(closes(bridge([(client, false)], slots: [slot(3)])), "the match is under 3 pt")
    }

    // A laid-out item keeps its frame: its click still begins its session (Stats B while A is open).
    func testLaidOutOwnItemStaysTheSystems() {
        XCTAssertFalse(closes(bridge([(client, false)], slots: [slot(200), slot(2)])))
        XCTAssertEqual(bridge([(client, false)], slots: [slot(-2)]).itemFrames, [client], "the client frame is kept")
    }

    // No Accessibility or no agent: nothing says a frame is stale, the parent's rule stands.
    func testUnreadableHostKeepsTheClientFrames() {
        XCTAssertFalse(closes(bridge([(client, false)], slots: nil)))
    }

    // Below 27 nothing is installed; with only the live item there is nothing to check.
    // Either way the frames stay empty and the host is never read.
    func testNoCandidateFramesNeverReadsTheHost() {
        var reads = 0
        let cases: [Frames] = [[], [(client, true)]]
        for frames in cases {
            let b = ExpandedInterfaceBridge(begin: { _ in }, end: { _ in },
                                            hostSlots: { reads += 1; return [] }, clientFrames: { frames })
            XCTAssertTrue(b.itemFrames.isEmpty)
        }
        let noItems = ExpandedInterfaceBridge(begin: { _ in }, end: { _ in }, hostSlots: { reads += 1; return [] })
        XCTAssertTrue(noItems.itemFrames.isEmpty, "no installed item, as below 27")
        XCTAssertEqual(reads, 0)
    }

    // The frames (an Accessibility read on 27) are read once per click, never for a pinned popover.
    func testDismisserReadsTheFramesOncePerClick() {
        var reads = 0
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 10,
                                   windowNumber: 0, context: nil, eventNumber: 9, clickCount: 1, pressure: 1)!
        let d = PopoverOutsideClickDismisser(popover: NSPopover(), systemOwnedFrames: { _ in reads += 1; return [] })
        d.handleClick(e, at: p)
        XCTAssertTrue(d.dismissed(by: e))
        XCTAssertEqual(reads, 1)
        let pinned = PopoverOutsideClickDismisser(popover: NSPopover(), canDismiss: { false },
                                                  systemOwnedFrames: { _ in reads += 1; return [] })
        pinned.handleClick(e, at: p)
        XCTAssertEqual(reads, 1, "a pinned popover reads nothing")
    }

    // r2: the host is read only for a click inside a client frame, once.
    func testHostIsReadOnlyForAClickInsideAClientFrame() {
        var reads = 0
        let stale = slot(200), laid = slot(0)
        let b = ExpandedInterfaceBridge(begin: { _ in }, end: { _ in },
                                        hostSlots: { reads += 1; return [stale] }, clientFrames: { [(self.client, false)] })
        XCTAssertTrue(closes(b, at: NSPoint(x: p.x - 500, y: p.y)), "outside every client frame: the dismisser's")
        XCTAssertEqual(reads, 0, "outside every client frame: no host read")
        XCTAssertTrue(closes(b, at: p), "inside a stale frame: the dismisser's")
        XCTAssertEqual(reads, 1)
        let c = ExpandedInterfaceBridge(begin: { _ in }, end: { _ in },
                                        hostSlots: { reads += 1; return [laid] }, clientFrames: { [(self.client, false)] })
        XCTAssertFalse(closes(c, at: p), "inside a laid-out frame: the system's")
        XCTAssertEqual(reads, 2)
    }

    // r2: our slots in a host layout; an empty layout is a failed read.
    func testOwnSlotsInAHostLayout() {
        typealias L = MenuBarAX.Laid
        let me: pid_t = 100, agent: pid_t = 50, other: pid_t = 200
        let a = CGRect(x: 10, y: 0, width: 30, height: 24), b = CGRect(x: 50, y: 0, width: 30, height: 24)
        let c = CGRect(x: 90, y: 0, width: 30, height: 24), d = CGRect(x: 130, y: 0, width: 30, height: 24)
        XCTAssertTrue(ExpandedInterfacePolicy.ownSlots(in: [], pid: me) == nil, "empty: a failed read")
        XCTAssertEqual(ExpandedInterfacePolicy.ownSlots(in: [L(frame: a, pid: agent), L(frame: b, pid: other)], pid: me), [],
                       "ours all overflowed or dropped")
        XCTAssertEqual(ExpandedInterfacePolicy.ownSlots(in: [L(frame: a, pid: agent), L(frame: b, pid: me),
                                                             L(frame: c, pid: other), L(frame: d, pid: me)], pid: me),
                       [b, d])
    }
}
