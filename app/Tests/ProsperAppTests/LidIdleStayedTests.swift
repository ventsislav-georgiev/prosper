import XCTest
@testable import ProsperHelperProtocol

/// #981 N981-a: the idle timer's stay step (fan trip latch set, daemon stays).
/// Clears only an ORPHANED remote hold (no client), never exits. Fakes only: the
/// recorded sleep seam, no real setting.
final class LidIdleStayedTests: XCTestCase {

    private final class Spy {
        var calls: [Bool] = []
        var idleExits = 0
        func apply(_ on: Bool) -> Bool { calls.append(on); return true }
        func onIdle() { idleExits += 1 }
    }

    private func make(_ spy: Spy) -> LidHelperCore {
        LidHelperCore(apply: spy.apply, onIdle: spy.onIdle)
    }

    private let tok = NSObject()

    func testNoClientOrphanedHoldIsClearedWithoutExit() {
        let spy = Spy()
        let core = make(spy)
        _ = core.promoteRemoteHold()                    // [true]
        core.idleStayed()
        XCTAssertFalse(core.remoteHoldOn)
        XCTAssertFalse(core.remoteHoldSticky)
        XCTAssertEqual(spy.calls, [true, false])
        XCTAssertEqual(spy.idleExits, 0)                // staying: never exits
    }

    func testConnectedClientKeepsItsHold() {
        let spy = Spy()
        let core = make(spy)
        core.connectionOpened(ObjectIdentifier(tok))    // connected in the window
        _ = core.setRemoteHold(true)                    // [true]
        core.idleStayed()
        XCTAssertTrue(core.remoteHoldOn)
        XCTAssertEqual(spy.calls, [true])
        XCTAssertEqual(spy.idleExits, 0)
    }

    func testNoClientNoHoldRecordsNothing() {
        let spy = Spy()
        let core = make(spy)
        core.idleStayed()
        XCTAssertEqual(spy.calls, [])
        XCTAssertEqual(spy.idleExits, 0)
    }

    func testIdleFiredAfterStayStillExitsOnce() {
        let spy = Spy()
        let core = make(spy)
        _ = core.setRemoteHold(true)                    // [true]
        core.idleStayed()                               // [true, false]
        XCTAssertEqual(spy.idleExits, 0)
        core.idleFired()
        XCTAssertEqual(spy.idleExits, 1)
        XCTAssertEqual(spy.calls, [true, false])        // nothing left to clear
    }
}
