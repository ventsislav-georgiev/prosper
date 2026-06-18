import XCTest
@testable import ProsperApp

/// Covers `AutocompleteEngine.applyWordBoundary`: a model completion that starts
/// a new word must not glue onto a finished word the user typed without a
/// trailing space ("brown" + "fox" -> "brown fox"), while genuine mid-word
/// continuations and already-separated completions are left untouched.
@MainActor
final class AutocompleteWordBoundaryTests: XCTestCase {

    func testNewWordAfterCompleteWordGetsSpace() {
        // "brown" is a complete word, "fox..." is a new word -> insert a space.
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "the quick brown", suggestion: "fox jumps"),
            " fox jumps"
        )
    }

    func testMidWordContinuationKeepsNoSpace() {
        // "brow" is an incomplete fragment -> the completion continues it.
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "the quick brow", suggestion: "n fox"),
            "n fox"
        )
    }

    func testTrailingSpaceLeavesCompletionUnchanged() {
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "the quick brown ", suggestion: "fox"),
            "fox"
        )
    }

    func testCompletionStartingWithSpaceUnchanged() {
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "the quick brown", suggestion: " fox"),
            " fox"
        )
    }

    func testCompletionStartingWithPunctuationUnchanged() {
        // A clause-continuing punctuation must stay flush ("done" + "." -> "done.").
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "I am done", suggestion: "."),
            "."
        )
    }

    func testTrailingSpacePlusLeadingSpaceDropsDuplicate() {
        // Field already has a space and the model also prefixed one -> avoid "  ".
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "the quick brown ", suggestion: " fox"),
            "fox"
        )
    }

    func testEmptyInputsAreSafe() {
        XCTAssertEqual(AutocompleteEngine.applyWordBoundary(before: "", suggestion: "fox"), "fox")
        XCTAssertEqual(AutocompleteEngine.applyWordBoundary(before: "brown", suggestion: ""), "")
    }

    func testSentenceStartAfterPeriodGetsSpace() {
        // New sentence flush against the period -> insert the space.
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "the lazy fox.", suggestion: "The dog"),
            " The dog"
        )
    }

    func testLowercaseAfterPeriodStaysGlued() {
        // Domains / file extensions continue the token, no space.
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "visit example.", suggestion: "com"),
            "com"
        )
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "open main.", suggestion: "swift"),
            "swift"
        )
    }

    func testNumberAfterPunctuationStaysGlued() {
        // Decimals and thousands separators must survive.
        XCTAssertEqual(AutocompleteEngine.applyWordBoundary(before: "pi is 3.", suggestion: "14"), "14")
        XCTAssertEqual(AutocompleteEngine.applyWordBoundary(before: "about 1,", suggestion: "000"), "000")
    }

    // MARK: - Ghost line-center resolution (ghostLineCenterY)

    func testAppKitQuirkCenterPreferredWhenInsideField() {
        // AppKit-corrected center (minY - h/2) lands inside the field -> use it.
        let caret = CGRect(x: 100, y: 200, width: 0, height: 20) // corrected: 190
        let field = CGRect(x: 50, y: 150, width: 400, height: 45) // 150...195
        XCTAssertEqual(AutocompleteEngine.ghostLineCenterY(caret: caret, field: field), 190)
    }

    func testTrueBoxCenterUsedWhenAppKitCorrectionFallsOutside() {
        // Chromium/web form: caret IS the glyph box. Corrected center (145) falls
        // below the field; the true center (165) is inside -> use it.
        let caret = CGRect(x: 100, y: 155, width: 0, height: 20)
        let field = CGRect(x: 50, y: 150, width: 400, height: 45)
        XCTAssertEqual(AutocompleteEngine.ghostLineCenterY(caret: caret, field: field), 165)
    }

    func testGarbageCaretClampsToFieldCenter() {
        // Caret reported nowhere near the field -> clamp to its vertical center.
        let caret = CGRect(x: 100, y: 300, width: 0, height: 20)
        let field = CGRect(x: 50, y: 150, width: 400, height: 45)
        XCTAssertEqual(AutocompleteEngine.ghostLineCenterY(caret: caret, field: field), 172.5)
    }

    func testNoFieldKeepsAppKitCorrection() {
        let caret = CGRect(x: 100, y: 200, width: 0, height: 20)
        XCTAssertEqual(AutocompleteEngine.ghostLineCenterY(caret: caret, field: nil), 190)
    }

    func testWordAfterClausePunctuationGetsSpace() {
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "wait,", suggestion: "and then"),
            " and then"
        )
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "note:", suggestion: "we should"),
            " we should"
        )
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "really?", suggestion: "Then"),
            " Then"
        )
        XCTAssertEqual(
            AutocompleteEngine.applyWordBoundary(before: "(see docs)", suggestion: "and"),
            " and"
        )
    }
}
