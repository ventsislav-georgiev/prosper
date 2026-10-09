import XCTest
@testable import ProsperApp

final class FullDiskAccessProbeTests: XCTestCase {
    func testDeniedMeansNoAccess() {
        XCTAssertFalse(PermissionsManager.fullDiskAccessDecision([.denied, .readable]))
    }

    func testMissingProbeFallsThroughToReadable() {
        XCTAssertTrue(PermissionsManager.fullDiskAccessDecision([.missing, .readable]))
    }

    func testAllMissingMeansNoAccess() {
        XCTAssertFalse(PermissionsManager.fullDiskAccessDecision([.missing, .missing]))
    }
}
