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
                                             systemOwnedFrames: { [NSRect(origin: p, size: NSSize(width: 1, height: 1))] })
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
