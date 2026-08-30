import XCTest
@testable import ProsperApp

final class FanReclaimRecoveryTests: XCTestCase {
    func testReclaimRestoresOnlySafeSuccessfulManualIntent() {
        XCTAssertFalse(FanReclaimRecovery.shouldReengage(manualFraction: 0.19))
        XCTAssertTrue(FanReclaimRecovery.shouldReengage(manualFraction: 0.20))
        XCTAssertTrue(FanReclaimRecovery.shouldReengage(manualFraction: 0.75))
        XCTAssertFalse(FanReclaimRecovery.shouldReengage(manualFraction: 0.75, reengaged: false))
        XCTAssertFalse(FanReclaimRecovery.shouldReengage(manualIntent: false, manualFraction: 0.75))
    }
}
