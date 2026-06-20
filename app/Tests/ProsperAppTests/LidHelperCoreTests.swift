import XCTest
@testable import LidHelperProtocol

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
