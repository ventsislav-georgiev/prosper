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
}
