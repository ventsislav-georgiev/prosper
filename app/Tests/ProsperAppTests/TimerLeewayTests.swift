import XCTest
@testable import ProsperApp

/// #1003 (QA #19 on #193): the repeating extension timers' leeway, 10 % capped at 1 s.
/// QA's "uncapped" mutant survived: no test read the value.
final class TimerLeewayTests: XCTestCase {
    func testRepeatLeewayIsTenPercentCappedAtOneSecond() {
        XCTAssertEqual(TimerScheduler.repeatLeeway(0.05), .milliseconds(5))
        XCTAssertEqual(TimerScheduler.repeatLeeway(5), .milliseconds(500))
        XCTAssertEqual(TimerScheduler.repeatLeeway(10), .milliseconds(1000))
        XCTAssertEqual(TimerScheduler.repeatLeeway(3600), .milliseconds(1000))
    }

    /// A corrupt store's NaN or negative interval lands on the 0.05 s floor, never in Int().
    func testRepeatLeewayOfAnUnusableIntervalIsTheFloor() {
        XCTAssertEqual(TimerScheduler.repeatLeeway(.nan), .milliseconds(5))
        XCTAssertEqual(TimerScheduler.repeatLeeway(-1), .milliseconds(5))
    }
}
