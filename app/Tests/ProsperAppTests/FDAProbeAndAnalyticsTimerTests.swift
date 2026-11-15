import XCTest
@testable import ProsperApp

final class FDAProbeAndAnalyticsTimerTests: XCTestCase {
    /// Counts calls; fakes only, the real probes read TCC-protected directories.
    private final class Probe {
        var calls = 0
        let result: PermissionsManager.FDAProbeResult
        init(_ r: PermissionsManager.FDAProbeResult) { result = r }
        var fn: () -> PermissionsManager.FDAProbeResult { { [self] in calls += 1; return result } }
    }

    func testFirstProbeDecidesAndSecondIsNeverCalled() {
        for first in [PermissionsManager.FDAProbeResult.readable, .denied] {
            let a = Probe(first), b = Probe(.readable)
            let got = PermissionsManager.fullDiskAccessDecision(lazy: [a.fn, b.fn])
            XCTAssertEqual(got, first == .readable)
            XCTAssertEqual(a.calls, 1)
            XCTAssertEqual(b.calls, 0)
        }
    }

    func testMissingFirstProbeLetsTheSecondDecide() {
        for second in [PermissionsManager.FDAProbeResult.readable, .denied, .missing] {
            let a = Probe(.missing), b = Probe(second)
            let got = PermissionsManager.fullDiskAccessDecision(lazy: [a.fn, b.fn])
            XCTAssertEqual(got, second == .readable)
            XCTAssertEqual(a.calls, 1)
            XCTAssertEqual(b.calls, 1)
        }
    }

    @MainActor
    func testAnalyticsTimerIsHourlyWithThreeSixtySecondTolerance() {
        let t = AnalyticsService.makeTimer { }
        defer { t.invalidate() }
        XCTAssertEqual(t.timeInterval, 3600)
        XCTAssertEqual(t.tolerance, 360)
        XCTAssertTrue(t.isValid && t.fireDate > Date(), "built, not fired")
    }
}
