import XCTest
@testable import ProsperApp

/// #249: the popup's engage watchdog must resolve at its ceiling even while the engage
/// itself is stuck in a non-cancellable wait (SMAppService IPC, the approval prompt).
final class FanTimeoutRaceTests: XCTestCase {
    func testCeilingFiresWhileOpNeverReturns() async {
        let done = expectation(description: "timeout resolved")
        let start = Date()
        Task {
            let reply = await StatsPopupView.raceFanTimeout(0.2) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never resumes
                return .engaged
            }
            XCTAssertEqual(reply, .unavailable)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testFastOpWinsBeforeCeiling() async {
        let start = Date()
        let released = expectation(description: "no late release")
        released.isInverted = true
        let reply = await StatsPopupView.raceFanTimeout(5, { .engaged }, lateEngaged: { released.fulfill() })
        XCTAssertEqual(reply, .engaged)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        await fulfillment(of: [released], timeout: 0.3)
    }

    /// #255: the abandoned engage succeeds after the ceiling fired. The popup still gets
    /// `.unavailable` (manual stays off) and the late engage is released.
    func testLateEngageAfterCeilingIsReleased() async {
        let released = expectation(description: "late engage released")
        let reply = await StatsPopupView.raceFanTimeout(0.1, {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return .engaged
        }, lateEngaged: { released.fulfill() })
        XCTAssertEqual(reply, .unavailable)
        await fulfillment(of: [released], timeout: 2)
    }

    /// #255: only the newest engage, with manual still off, may release.
    func testShouldReleaseLateEngage() {
        XCTAssertFalse(StatsPopupView.shouldReleaseLateEngage(generation: 1, current: 2, lastFailed: 1, manualOn: false))
        XCTAssertTrue(StatsPopupView.shouldReleaseLateEngage(generation: 2, current: 2, lastFailed: 1, manualOn: false))
        XCTAssertFalse(StatsPopupView.shouldReleaseLateEngage(generation: 2, current: 2, lastFailed: 1, manualOn: true))
    }

    /// #263 ordering A: N timed out, N+1 failed, then N lands late. N+1 owns nothing,
    /// so N is released (unless manual came on since).
    func testLateEngageAfterNewerEngageFailedIsReleased() {
        XCTAssertTrue(StatsPopupView.shouldReleaseLateEngage(generation: 1, current: 2, lastFailed: 2, manualOn: false))
        XCTAssertFalse(StatsPopupView.shouldReleaseLateEngage(generation: 1, current: 2, lastFailed: 2, manualOn: true))
    }

    /// #263 ordering B, step 1: N lands late while N+1 is still in flight — held for N+1.
    /// Step 2 (N+1 fails → release) is FanReclaimRecoveryTests.testFailedFirstEngageReleasesTheHeldPin.
    func testLateEngageWhileNewerEngageInFlightIsHeld() {
        XCTAssertFalse(StatsPopupView.shouldReleaseLateEngage(generation: 1, current: 2, lastFailed: 1, manualOn: false))
        XCTAssertFalse(StatsPopupView.shouldReleaseLateEngage(generation: 1, current: 3, lastFailed: 2, manualOn: false))
    }

    /// A late failure has nothing engaged to release.
    func testLateFailureAfterCeilingIsNotReleased() async {
        let released = expectation(description: "no release")
        released.isInverted = true
        let reply = await StatsPopupView.raceFanTimeout(0.1, {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .refused
        }, lateEngaged: { released.fulfill() })
        XCTAssertEqual(reply, .unavailable)
        await fulfillment(of: [released], timeout: 0.6)
    }
}
