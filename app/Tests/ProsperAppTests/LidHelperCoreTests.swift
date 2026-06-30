import XCTest
@testable import ProsperHelperProtocol

/// Covers the safety-critical daemon logic without root/launchd: the override is
/// reset when the last client drops (crash safety), idle-exit fires only when no
/// client remains, and `setOverride` tracks state only on a successful apply.
final class LidHelperCoreTests: XCTestCase {

    /// Records every `apply(_:)` call and lets a test force success/failure.
    private final class Spy {
        var calls: [Bool] = []
        var result = true
        var idleExits = 0
        func apply(_ on: Bool) -> Bool { calls.append(on); return result }
        func onIdle() { idleExits += 1 }
    }

    private func make(_ spy: Spy) -> LidHelperCore {
        LidHelperCore(apply: spy.apply, onIdle: spy.onIdle)
    }

    func testLastCloseWhileOnResetsOverride() {
        let spy = Spy()
        let core = make(spy)
        core.connectionOpened()
        XCTAssertTrue(core.setOverride(true))
        XCTAssertTrue(core.overrideOn)

        XCTAssertTrue(core.connectionClosed())          // last client → arm idle
        XCTAssertFalse(core.overrideOn)                 // override cleared
        XCTAssertEqual(spy.calls, [true, false])        // applied on, then off
    }

    func testLastCloseWhileOffDoesNotApply() {
        let spy = Spy()
        let core = make(spy)
        core.connectionOpened()
        XCTAssertTrue(core.connectionClosed())          // arm idle
        XCTAssertEqual(spy.calls, [])                   // never touched pmset
    }

    func testNonLastCloseKeepsOverride() {
        let spy = Spy()
        let core = make(spy)
        core.connectionOpened()
        core.connectionOpened()
        _ = core.setOverride(true)

        XCTAssertFalse(core.connectionClosed())         // one client remains
        XCTAssertTrue(core.overrideOn)                  // override held
        XCTAssertEqual(core.connections, 1)
        XCTAssertEqual(spy.calls, [true])               // no reset yet
    }

    func testFailedApplyDoesNotTrackState() {
        let spy = Spy()
        spy.result = false
        let core = make(spy)
        core.connectionOpened()
        XCTAssertFalse(core.setOverride(true))          // pmset failed
        XCTAssertFalse(core.overrideOn)                 // not claimed as held

        _ = core.connectionClosed()
        XCTAssertEqual(spy.calls, [true])               // no spurious reset(false)
    }

    func testReclaimAtStartupForcesOff() {
        let spy = Spy()
        let core = make(spy)
        core.reclaimAtStartup()
        XCTAssertEqual(spy.calls, [false])              // forced disablesleep=0
        XCTAssertFalse(core.overrideOn)

        // A client that still wants it on re-applies cleanly afterwards.
        core.connectionOpened()
        XCTAssertTrue(core.setOverride(true))
        XCTAssertTrue(core.overrideOn)
        XCTAssertEqual(spy.calls, [false, true])
    }

    func testIdleFiresOnlyWhenNoClients() {
        let spy = Spy()
        let core = make(spy)
        core.connectionOpened()
        core.idleFired()
        XCTAssertEqual(spy.idleExits, 0)                // client present → stay alive

        _ = core.connectionClosed()
        core.idleFired()
        XCTAssertEqual(spy.idleExits, 1)                // no clients → exit
    }

    func testConnectionCountNeverGoesNegative() {
        let spy = Spy()
        let core = make(spy)
        XCTAssertTrue(core.connectionClosed())          // spurious close, count was 0
        XCTAssertEqual(core.connections, 0)
    }

    // MARK: - remote-session hold (OR'd with the lid override at the pmset layer)

    func testRemoteHoldKeepsSleepDisabledWithoutLidOverride() {
        let spy = Spy()
        let core = make(spy)
        XCTAssertTrue(core.setRemoteHold(true))
        XCTAssertTrue(core.remoteHoldOn)
        XCTAssertFalse(core.overrideOn)
        XCTAssertEqual(spy.calls, [true])               // remote alone disables sleep
    }

    func testRemoteHoldSurvivesConnectionClose() {
        let spy = Spy()
        let core = make(spy)
        _ = core.setRemoteHold(true)                    // [true]
        core.connectionOpened()
        _ = core.setOverride(true)                      // still true (OR), [true,true]

        XCTAssertTrue(core.connectionClosed())          // last lid client drops
        XCTAssertFalse(core.overrideOn)                 // lid override cleared
        XCTAssertTrue(core.remoteHoldOn)                // remote hold untouched
        // connectionClosed re-applies OR(false, true)=true, not false → Mac stays awake.
        XCTAssertEqual(spy.calls, [true, true, true])
        XCTAssertEqual(spy.calls.last, true)
    }

    func testReleasingOneSourceKeepsOtherHeld() {
        let spy = Spy()
        let core = make(spy)
        core.connectionOpened()
        _ = core.setOverride(true)                      // [true]
        _ = core.setRemoteHold(true)                    // OR still true, [true,true]
        _ = core.setRemoteHold(false)                   // lid still holds → OR true, [..,true]
        XCTAssertTrue(core.overrideOn)
        XCTAssertFalse(core.remoteHoldOn)
        XCTAssertEqual(spy.calls.last, true)            // never re-enabled sleep
    }

    func testReclaimAtStartupClearsRemoteHold() {
        let spy = Spy()
        let core = make(spy)
        _ = core.setRemoteHold(true)
        core.reclaimAtStartup()
        XCTAssertFalse(core.remoteHoldOn)
        XCTAssertFalse(core.overrideOn)
        XCTAssertEqual(spy.calls.last, false)
    }

    // MARK: - sticky remote hold (remote-wake promote → persist until explicit sleep)

    func testPromoteRemoteHoldIsStickyAndSurvivesSoftRelease() {
        let spy = Spy()
        let core = make(spy)
        XCTAssertTrue(core.promoteRemoteHold())         // [true]
        XCTAssertTrue(core.remoteHoldOn)
        XCTAssertTrue(core.remoteHoldSticky)

        // Heartbeat soft release (session idle / TTL lapse) must NOT drop a sticky hold.
        XCTAssertTrue(core.setRemoteHold(false))        // ignored, no pmset call
        XCTAssertTrue(core.remoteHoldOn)
        XCTAssertTrue(core.remoteHoldSticky)
        XCTAssertEqual(spy.calls, [true])               // sleep never re-enabled
    }

    func testClearRemoteHoldReleasesStickyHold() {
        let spy = Spy()
        let core = make(spy)
        _ = core.promoteRemoteHold()                    // [true]
        XCTAssertTrue(core.clearRemoteHold())           // lid open → hard release, [true,false]
        XCTAssertFalse(core.remoteHoldOn)
        XCTAssertFalse(core.remoteHoldSticky)
        XCTAssertEqual(spy.calls, [true, false])
    }

    func testClearRemoteHoldKeepsLidOverride() {
        let spy = Spy()
        let core = make(spy)
        core.connectionOpened()
        _ = core.setOverride(true)                      // [true]
        _ = core.promoteRemoteHold()                    // OR still true, [true,true]
        XCTAssertTrue(core.clearRemoteHold())           // lid override keeps OR true, [..,true]
        XCTAssertTrue(core.overrideOn)
        XCTAssertFalse(core.remoteHoldOn)
        XCTAssertFalse(core.remoteHoldSticky)
        XCTAssertEqual(spy.calls.last, true)            // sleep never re-enabled
    }

    func testReclaimClearsStickyHold() {
        let spy = Spy()
        let core = make(spy)
        _ = core.promoteRemoteHold()
        core.reclaimAtStartup()                         // explicit sleep path
        XCTAssertFalse(core.remoteHoldSticky)
        XCTAssertFalse(core.remoteHoldOn)
        XCTAssertEqual(spy.calls.last, false)
    }

    func testStickyClearedThenNormalSoftReleaseWorksAgain() {
        let spy = Spy()
        let core = make(spy)
        _ = core.promoteRemoteHold()                    // [true] sticky
        _ = core.clearRemoteHold()                      // [true,false] sticky cleared
        // A fresh transient hold (lid closed again, session active) is now soft-releasable.
        XCTAssertTrue(core.setRemoteHold(true))         // [..,true]
        XCTAssertFalse(core.remoteHoldSticky)
        XCTAssertTrue(core.setRemoteHold(false))        // honored now, [..,false]
        XCTAssertFalse(core.remoteHoldOn)
        XCTAssertEqual(spy.calls, [true, false, true, false])
    }

    func testIdleExitClearsOrphanedRemoteHold() {
        let spy = Spy()
        let core = make(spy)
        _ = core.promoteRemoteHold()                    // sticky, [true]
        // Remote wake toggled off (daemon no longer resident), no clients → idle fires.
        core.idleFired()
        XCTAssertEqual(spy.idleExits, 1)                // still exits
        XCTAssertFalse(core.remoteHoldOn)               // but NOT orphaned awake
        XCTAssertFalse(core.remoteHoldSticky)
        XCTAssertEqual(spy.calls, [true, false])        // pmset reset before exit
    }

    func testIdleExitWithoutHoldDoesNotTouchPmset() {
        let spy = Spy()
        let core = make(spy)
        core.idleFired()                                // nothing held → no spurious pmset call
        XCTAssertEqual(spy.idleExits, 1)
        XCTAssertEqual(spy.calls, [])
    }

    /// Hot-path budget: the daemon serializes every connection/method event
    /// through the core, so a transition must be effectively free — no allocation,
    /// no locking. 1M open+set+close cycles under 500ms is ~500ns/cycle, a
    /// regression guard (an accidental per-call alloc or lock lands 10-100x over),
    /// not a micro-benchmark. Measured on a DEBUG build (no optimization); release
    /// is several times faster, and the real op (XPC + pmset) dwarfs this anyway.
    func testTransitionThroughputUnderBudget() {
        // No-op apply: measure the core's transitions, not a recording spy whose
        // array growth would dominate the timing.
        let core = LidHelperCore(apply: { _ in true }, onIdle: {})
        let iterations = 1_000_000
        let start = DispatchTime.now()
        for _ in 0..<iterations {
            core.connectionOpened()
            _ = core.setOverride(true)
            _ = core.connectionClosed()
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(ms, 500, "core transitions too slow: \(ms)ms for \(iterations) cycles")
    }
}
