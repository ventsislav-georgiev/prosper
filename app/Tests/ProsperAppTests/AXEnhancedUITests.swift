import XCTest
@testable import ProsperApp

/// Covers the WS4 `AXEnhancedUI` cache + feedback logic that is testable without a
/// live AX-trusted app: the nil/no-pid early-out of `enableIfNeeded`, and the
/// scoping of the `recordCaretOutcome` "enhanced UI helped" signal to apps we
/// actually tried to unlock. The AX attribute writes themselves require a real
/// running application and are exercised manually, not in unit tests.
@MainActor
final class AXEnhancedUITests: XCTestCase {

    private let unenabledId = "com.example.prosper.never-enabled-app"

    override func setUp() {
        super.setUp()
        AXEnhancedUI.resetForTesting()
    }

    override func tearDown() {
        AXEnhancedUI.resetForTesting()
        // Clear any feedback flag this suite may have written.
        var helped = Preferences.enhancedUIHelped
        helped.removeValue(forKey: unenabledId)
        Preferences.enhancedUIHelped = helped
        super.tearDown()
    }

    /// A nil application can't be unlocked — `enableIfNeeded` returns false and
    /// never touches AX.
    func testEnableIfNeededNoOpForNilApp() {
        XCTAssertFalse(AXEnhancedUI.enableIfNeeded(for: nil))
    }

    /// `recordCaretOutcome` only records for bundle ids we previously tried to
    /// unlock (`enabledBundleIds`). With a clean cache, recording a success for an
    /// app we never enabled must NOT write the "helped" flag — the signal stays
    /// scoped to the opt-in set.
    func testRecordCaretOutcomeIgnoresUnenabledApp() {
        AXEnhancedUI.resetForTesting()
        var helped = Preferences.enhancedUIHelped
        helped.removeValue(forKey: unenabledId)
        Preferences.enhancedUIHelped = helped

        AXEnhancedUI.recordCaretOutcome(bundleId: unenabledId, caretResolved: true)
        XCTAssertNil(Preferences.enhancedUIHelped[unenabledId])
    }

    /// A nil bundle id is always a no-op (no crash, no write).
    func testRecordCaretOutcomeNilBundleIsNoOp() {
        AXEnhancedUI.recordCaretOutcome(bundleId: nil, caretResolved: true)
        // Nothing to assert beyond not crashing; the nil key can't be stored.
    }
}
