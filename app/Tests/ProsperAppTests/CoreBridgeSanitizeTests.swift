import XCTest
@testable import ProsperApp

/// Covers `CoreBridge.sanitizeCompletion` and `dropLeadingOverlap`: cleaning raw
/// model output into a usable inline continuation, with emphasis on stripping the
/// leading echo where the model re-emits text the user already typed. A single
/// boundary space left after stripping is intentional and preserved.
final class CoreBridgeSanitizeTests: XCTestCase {

    func testStripsLeadingEchoOfTail() {
        // Model re-emits the last word, then continues; boundary space preserved.
        let out = CoreBridge.sanitizeCompletion("fox jumps over", before: "the quick brown fox")
        XCTAssertEqual(out, " jumps over")
    }

    func testStripsEchoWithStrayLeadingSpace() {
        // Model prefixes the echo with a stray space.
        let out = CoreBridge.sanitizeCompletion(" brown fox", before: "the quick brown")
        XCTAssertEqual(out, " fox")
    }

    func testStripsFullLineRestatementBeyond80Chars() {
        let before = String(repeating: "word ", count: 30) + "tail" // ~154 chars
        let out = CoreBridge.sanitizeCompletion("tail end here", before: before)
        XCTAssertEqual(out, " end here")
    }

    func testNoOverlapLeavesContinuationIntact() {
        let out = CoreBridge.sanitizeCompletion("dog.", before: "the quick brown fox jumps over the lazy ")
        XCTAssertEqual(out, "dog.")
    }

    func testStripsSurroundingQuotes() {
        let out = CoreBridge.sanitizeCompletion("\"hello\"", before: "say ")
        XCTAssertEqual(out, "hello")
    }

    func testStripsCodeFence() {
        let out = CoreBridge.sanitizeCompletion("```\nb }\n```", before: "func f() { return a + ")
        XCTAssertEqual(out, "b }")
    }

    func testEmptyAfterCleaningReturnsNil() {
        XCTAssertNil(CoreBridge.sanitizeCompletion("   \n  ", before: "anything"))
    }

    func testDropLeadingOverlapStripsEcho() {
        let stripped = CoreBridge.dropLeadingOverlap("abcXYZ", tail: Array("abcabc"))
        XCTAssertEqual(stripped, "XYZ")
    }

    func testDropLeadingOverlapLongestFirst() {
        // tail ends with "abab"; the maximal 4-char run is stripped, not the 2-char.
        let stripped = CoreBridge.dropLeadingOverlap("ababZ", tail: Array("xabab"))
        XCTAssertEqual(stripped, "Z")
    }

    func testDropLeadingOverlapNoMatchReturnsNil() {
        XCTAssertNil(CoreBridge.dropLeadingOverlap("zzz", tail: Array("abc")))
    }

    // MARK: - Regurgitation guard (echoesRecentWord)

    func testSuppressesMidWordRegurgitation() {
        // "website d" + "website" would glue into "dwebsite" — drop it entirely.
        XCTAssertNil(CoreBridge.sanitizeCompletion("website", before: "website d"))
    }

    func testSuppressesMidWordRegurgitationWithLeadingSpace() {
        // Same echo, even if the model prefixes a space.
        XCTAssertNil(CoreBridge.sanitizeCompletion(" website", before: "website d"))
    }

    func testSuppressesImmediateWordRepeat() {
        // Non-contiguous repeat of the last word (overlap stripping doesn't catch
        // it because of the trailing space): "my website " + "website".
        XCTAssertNil(CoreBridge.sanitizeCompletion("website", before: "my website "))
    }

    func testKeepsValidMidWordRemainder() {
        // Genuine mid-word completion (web|site) must survive.
        XCTAssertEqual(CoreBridge.sanitizeCompletion("site", before: "web"), "site")
    }

    func testKeepsShortRepeatedWord() {
        // Short words (< 3 chars) repeat legitimately; do not suppress.
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion("to the store", before: "I want to go "),
            "to the store"
        )
    }

    func testDoesNotSuppressUnrelatedContinuation() {
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion("shortly.", before: "I'll get back to you"),
            "shortly."
        )
    }

    // MARK: - Regurgitation guard (echoesEarlierSpan / head restatement)

    func testSuppressesHeadRestatement() {
        // Instruct model restates the document opening instead of continuing.
        let before = "Dear team, thank you for your hard work this quarter. " +
            "I wanted to share a few thoughts about where we are headed and what happens after "
        XCTAssertNil(CoreBridge.sanitizeCompletion("Dear team, thank", before: before))
    }

    func testSuppressesMiddleSpanRestatement() {
        let before = "The migration runs at midnight and the backup completes before "
        XCTAssertNil(CoreBridge.sanitizeCompletion("the backup completes", before: before))
    }

    func testKeepsGenuineContinuationSharingShortPhrase() {
        // "and so" is < 12 chars; echoesEarlierSpan must not reject. (The tail-echo
        // guard does strip the repeated "and so ", leaving "we begin." — that is
        // correct dedup, and crucially the result is non-nil, not suppressed.)
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion("and so we begin.", before: "We planned and so "),
            "we begin."
        )
    }

    func testEchoesEarlierSpanRequiresTwoWords() {
        XCTAssertFalse(CoreBridge.echoesEarlierSpan("internationalization", before: "internationalization is hard"))
    }

    func testEchoesEarlierSpanDetectsLongLeadingSpan() {
        XCTAssertTrue(CoreBridge.echoesEarlierSpan("happens after the meeting", before: "what happens after the storm"))
    }

    // MARK: - Regurgitation guard #3 (echoesAnywhere / interior echo)

    func testSuppressesInteriorEcho() {
        // Starts fresh, then lifts a phrase the user already wrote.
        let before = "Thanks for the detailed report. I will "
        XCTAssertNil(CoreBridge.sanitizeCompletion("review thanks for the detailed report", before: before))
    }

    func testKeepsContinuationWithoutInteriorEcho() {
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion("get back to you tomorrow", before: "Thanks for the report. I will "),
            "get back to you tomorrow"
        )
    }

    func testEchoesAnywhereIgnoresShortWindows() {
        // 3-word window under 12 chars must not reject.
        XCTAssertFalse(CoreBridge.echoesAnywhere("so we go on", before: "and so we went"))
    }

    // MARK: - Internal loop guard (cutImmediateRepeat)

    func testCutsStutteredWord() {
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("over the the lazy dog"), "over the")
    }

    func testCutsRepeatedBigram() {
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("jumps in the in the morning"), "jumps in the")
    }

    func testKeepsCleanSuggestionAndLeadingSpace() {
        XCTAssertEqual(CoreBridge.cutImmediateRepeat(" fox jumps high"), " fox jumps high")
    }

    // MARK: - Gap fill: never re-emit text after the caret (dropTrailingOverlap)

    func testGapFillDropsEchoOfAfterText() {
        // Model filled the gap AND re-typed the upcoming text.
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion("world, how are you", before: "hello ", after: " how are you"),
            "world,"
        )
    }

    func testGapFillWhollyEchoingAfterIsRejected() {
        XCTAssertNil(
            CoreBridge.sanitizeCompletion("how are you", before: "hello, ", after: "how are you doing")
        )
    }

    func testGapFillDoesNotShaveSharedFinalLetter() {
        // Bare shared letter at a non-boundary must not cut the final word.
        XCTAssertEqual(CoreBridge.dropTrailingOverlap("dog", afterHead: "great"), "dog")
    }

    // MARK: - Language guard (mismatchedScript / dominantLanguageName)

    func testRejectsEnglishContinuationOfBulgarianText() {
        let before = "Здравей, как си днес? Аз съм добре и искам да "
        XCTAssertNil(CoreBridge.sanitizeCompletion("go to the store later", before: before))
        XCTAssertTrue(CoreBridge.mismatchedScript("the weather is nice", before: before))
    }

    func testKeepsBulgarianContinuationOfBulgarianText() {
        let before = "Здравей, как си днес? Аз съм добре и искам да "
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion("отида до магазина", before: before),
            "отида до магазина"
        )
    }

    func testKeepsShortForeignProperNoun() {
        // A brand name in Latin inside Cyrillic text is legitimate.
        let before = "Купих си нов "
        XCTAssertFalse(CoreBridge.mismatchedScript("iPhone", before: before))
    }

    func testEnglishToEnglishIsNotMismatch() {
        XCTAssertFalse(CoreBridge.mismatchedScript("continue the text", before: "please do "))
    }

    func testLatinicaBulgarianIsNotBlocked() {
        // Bulgarian typed with Latin letters: same script on both sides, so the
        // script guard must never reject; sanitize keeps it intact.
        let before = "iskam da prodyljim da poddyrjame da pishem bylgarski na "
        XCTAssertFalse(CoreBridge.mismatchedScript("latinica i zanapred", before: before))
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion("latinica i zanapred", before: before),
            "latinica i zanapred"
        )
    }

    func testDominantLanguageNameDetectsBulgarian() {
        let name = CoreBridge.dominantLanguageName(of: "Здравей, как си днес? Аз съм добре.")
        XCTAssertEqual(name, "Bulgarian")
    }

    func testDominantLanguageNameNilOnTinyInput() {
        XCTAssertNil(CoreBridge.dominantLanguageName(of: "hi"))
    }

    // MARK: - Streaming word cap (MLXEngine.wordCapped)

    func testWordCapStopsAfterTargetWords() {
        // maxWords = 1 keeps the first word + its trailing space, drops the rest.
        XCTAssertEqual(MLXEngine.wordCapped("quick brown fox", maxWords: 1), "quick ")
    }

    func testWordCapThreeWords() {
        XCTAssertEqual(MLXEngine.wordCapped("one two three four", maxWords: 3), "one two three ")
    }

    func testWordCapReturnsNilUnderCap() {
        XCTAssertNil(MLXEngine.wordCapped("one two", maxWords: 3))
    }

    func testWordCapDisabledWhenZero() {
        XCTAssertNil(MLXEngine.wordCapped("anything goes here", maxWords: 0))
    }

    func testWordCapCountsMidWordContinuationAsFirstWord() {
        // A continuation with no leading space ("site there") counts "site" as word 1.
        XCTAssertEqual(MLXEngine.wordCapped("site there", maxWords: 1), "site ")
    }

    // MARK: - Prompt-scaffold echo guard

    func testPromptInstructionLeakIsRejected() {
        // The exact Safari leak: single-word context, model parroted the prompt.
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "Continue this text. Output only the continuation:", before: "Ventsislav"))
    }

    func testNudgeLeakIsRejected() {
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "You must output a continuation", before: "Hello"))
    }

    func testGapFillScaffoldLeakIsRejected() {
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "Fill the gap at the cursor", before: "Hello", after: " world"))
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "Before cursor: Hello", before: "Hello"))
    }

    func testScaffoldGuardCaseInsensitive() {
        XCTAssertTrue(CoreBridge.echoesPromptScaffold("CONTINUE THIS TEXT now"))
        XCTAssertTrue(CoreBridge.echoesPromptScaffold("the After Cursor part"))
    }

    func testNormalContinuationNotFlaggedAsScaffold() {
        XCTAssertFalse(CoreBridge.echoesPromptScaffold("Georgiev"))
        XCTAssertFalse(CoreBridge.echoesPromptScaffold(" is continuing the email"))
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion(" Georgiev", before: "Ventsislav"),
            " Georgiev"
        )
    }
}
