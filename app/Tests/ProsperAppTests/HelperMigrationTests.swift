import XCTest
@testable import ProsperHelperProtocol

/// The legacy-label migration (`.lidhelper` → `.helper`) must NEVER leave an
/// upgrading lid-sleep user worse off (override silently dead, no recovery). These
/// pin the exact invariants a review pass caught bugs in: don't mark migrated until
/// a successful re-pin, keep the cache truthful, and surface the modal on re-approval.
final class HelperMigrationTests: XCTestCase {
    typealias R = HelperMigration.RegisterResult

    func testNeverEnabledJustCompletes() {
        // No legacy override → nothing to re-pin; migration is done in one shot.
        let p = HelperMigration.plan(wasEnabled: false, result: nil)
        XCTAssertTrue(p.markMigrated)
        XCTAssertFalse(p.showApprovalModal)
        XCTAssertNil(p.cacheEnabled, "no re-pin attempted → don't touch the cache")
    }

    func testEnabledRePinSucceeds() {
        let p = HelperMigration.plan(wasEnabled: true, result: .enabled)
        XCTAssertTrue(p.markMigrated)
        XCTAssertFalse(p.showApprovalModal)
        XCTAssertEqual(p.cacheEnabled, true, "successful re-pin must restore the residency flag")
    }

    func testEnabledNeedsApprovalGuidesUser() {
        let p = HelperMigration.plan(wasEnabled: true, result: .needsApproval)
        XCTAssertTrue(p.markMigrated, "approval pending is a terminal state — don't loop the migration")
        XCTAssertTrue(p.showApprovalModal, "new label needs re-approval → guide the user, don't fail silently")
        XCTAssertEqual(p.cacheEnabled, false)
    }

    func testFailedRePinRetriesNextLaunch() {
        let p = HelperMigration.plan(wasEnabled: true, result: .failed)
        XCTAssertFalse(p.markMigrated, "a failed re-pin must NOT consume the one-shot flag — retry next launch")
        XCTAssertFalse(p.showApprovalModal)
        XCTAssertNil(p.cacheEnabled, "don't claim disabled on a transient register failure")
    }

    func testEnabledButNoResultRetries() {
        // Defensive: wasEnabled but the result is missing → treat as failed, retry.
        let p = HelperMigration.plan(wasEnabled: true, result: nil)
        XCTAssertFalse(p.markMigrated)
    }
}
