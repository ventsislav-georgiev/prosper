import XCTest
@testable import ProsperApp

/// Covers the WS4 mirror-fallback decision logic as pure functions:
///
/// - `AutocompleteEngine.hasUsableCaret` — distinguishes a real caret rect from the
///   degenerate `(0,0,0,0)` rect that signals "this app hid its caret geometry".
/// - `AutocompleteEngine.shouldUseMirror` — the 4b gate: show the mirror bubble only
///   when text mirroring is opted-in for the app AND there is no usable caret but a
///   usable field rect exists. Every other combination preserves today's behavior.
///
/// The decision reads `AppOverrideResolver.textMirroring`, so these tests drive the
/// synchronous override cache (`AppOverrideCache`) directly, mirroring
/// `AppOverrideResolverTests`, and clear it afterward so the process-wide singleton
/// can't bleed across tests.
@MainActor
final class AutocompleteMirrorDecisionTests: XCTestCase {

    private let mirrorId = "com.example.prosper.mirror-test-app"
    private let realCaret = CGRect(x: 100, y: 200, width: 1, height: 18)
    private let degenerateCaret = CGRect(x: 0, y: 0, width: 0, height: 0)
    private let field = CGRect(x: 50, y: 180, width: 300, height: 40)

    override func tearDown() {
        AppOverrideCache.shared.replace(with: [])
        super.tearDown()
    }

    // MARK: - hasUsableCaret

    func testRealCaretIsUsable() {
        XCTAssertTrue(AutocompleteEngine.hasUsableCaret(realCaret))
    }

    func testZeroWidthCaretWithRealOriginIsUsable() {
        // Telegram-style caret: real origin, zero width — still placeable.
        XCTAssertTrue(AutocompleteEngine.hasUsableCaret(CGRect(x: 10, y: 20, width: 0, height: 16)))
    }

    func testDegenerateCaretIsNotUsable() {
        XCTAssertFalse(AutocompleteEngine.hasUsableCaret(degenerateCaret))
    }

    func testNilCaretIsNotUsable() {
        XCTAssertFalse(AutocompleteEngine.hasUsableCaret(nil))
    }

    // MARK: - shouldUseMirror

    func testMirrorWhenOptedInAndNoCaretButFieldExists() {
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: mirrorId, textMirroring: true)
        ])
        XCTAssertTrue(
            AutocompleteEngine.shouldUseMirror(caret: nil, field: field, bundleId: mirrorId)
        )
        XCTAssertTrue(
            AutocompleteEngine.shouldUseMirror(caret: degenerateCaret, field: field, bundleId: mirrorId)
        )
    }

    func testNoMirrorWhenRealCaretExists() {
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: mirrorId, textMirroring: true)
        ])
        // A usable caret means the inline ghost handles it — never mirror.
        XCTAssertFalse(
            AutocompleteEngine.shouldUseMirror(caret: realCaret, field: field, bundleId: mirrorId)
        )
    }

    func testNoMirrorWhenFieldMissingOrDegenerate() {
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: mirrorId, textMirroring: true)
        ])
        XCTAssertFalse(
            AutocompleteEngine.shouldUseMirror(caret: nil, field: nil, bundleId: mirrorId)
        )
        XCTAssertFalse(
            AutocompleteEngine.shouldUseMirror(
                caret: nil, field: CGRect(x: 0, y: 0, width: 1, height: 1), bundleId: mirrorId
            )
        )
    }

    func testNoMirrorWhenNotOptedIn() {
        // No override (and the test id is in no seed) -> textMirroring resolves nil.
        AppOverrideCache.shared.replace(with: [])
        XCTAssertFalse(
            AutocompleteEngine.shouldUseMirror(caret: nil, field: field, bundleId: mirrorId)
        )
        // Explicit opt-out also suppresses the mirror.
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: mirrorId, textMirroring: false)
        ])
        XCTAssertFalse(
            AutocompleteEngine.shouldUseMirror(caret: nil, field: field, bundleId: mirrorId)
        )
    }
}
