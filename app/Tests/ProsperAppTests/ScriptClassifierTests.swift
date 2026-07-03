import XCTest
@testable import ProsperApp

/// B1 guided-decoding classifier. Pure logic: which token pieces are allowed under a
/// target script, and how a run of user text picks its target. The logit-mask itself
/// and its perceived-quality impact are live-tuning concerns, not unit ones.
final class ScriptClassifierTests: XCTestCase {

    func testTargetDetection() {
        XCTAssertEqual(ScriptClassifier.target(for: "как си днес"), .cyrillic)
        XCTAssertEqual(ScriptClassifier.target(for: "how are you"), .latin)
        // Mixed: Cyrillic present anywhere wins (the dominant script we anchor on).
        XCTAssertEqual(ScriptClassifier.target(for: "hello как"), .cyrillic)
        // No letters to anchor on → no constraint.
        XCTAssertEqual(ScriptClassifier.target(for: "12:45 — !!!"), .unconstrained)
    }

    func testCyrillicTargetAllowsCyrillicAndLatinBlocksOther() {
        let t = ScriptClassifier.Target.cyrillic
        XCTAssertTrue(ScriptClassifier.isAllowed("тебя", target: t))
        XCTAssertTrue(ScriptClassifier.isAllowed("▁добре", target: t)) // SentencePiece space marker
        XCTAssertTrue(ScriptClassifier.isAllowed("iPhone", target: t)) // Latin loanword allowed
        XCTAssertTrue(ScriptClassifier.isAllowed(", ", target: t))     // neutral
        XCTAssertFalse(ScriptClassifier.isAllowed("नमस्ते", target: t)) // Devanagari blocked
        XCTAssertFalse(ScriptClassifier.isAllowed("γειά", target: t))   // Greek blocked
    }

    func testLatinTargetBlocksCyrillic() {
        let t = ScriptClassifier.Target.latin
        XCTAssertTrue(ScriptClassifier.isAllowed("hello", target: t))
        XCTAssertTrue(ScriptClassifier.isAllowed("café", target: t)) // Latin-1 accented
        XCTAssertTrue(ScriptClassifier.isAllowed("42.", target: t))  // neutral
        XCTAssertFalse(ScriptClassifier.isAllowed("привет", target: t))
    }

    func testUnconstrainedAllowsEverything() {
        XCTAssertTrue(ScriptClassifier.isAllowed("привет", target: .unconstrained))
        XCTAssertTrue(ScriptClassifier.isAllowed("नमस्ते", target: .unconstrained))
    }

    func testSpecialAndNeutralTokensNeverBlocked() {
        // eos/turn markers carry Latin letters → allowed under any target (must be,
        // or the model could never stop).
        XCTAssertTrue(ScriptClassifier.isAllowed("<eos>", target: .cyrillic))
        XCTAssertTrue(ScriptClassifier.isAllowed("<end_of_turn>", target: .cyrillic))
    }
}
