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
        let reply = await StatsPopupView.raceFanTimeout(5) { .engaged }
        XCTAssertEqual(reply, .engaged)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
