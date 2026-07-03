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

    // MARK: - Punctuation-insensitive echo (BG live-echo regression)

    func testEchoesEarlierSpanIgnoresPunctuationDifferences() {
        // Model echo differs from the typed text only by a comma — must still reject.
        XCTAssertTrue(CoreBridge.echoesEarlierSpan(
            "Здравей как си днес", before: "Здравей, как си днес? Аз съм "))
    }

    func testEchoesAnywhereIgnoresPunctuationDifferences() {
        XCTAssertTrue(CoreBridge.echoesAnywhere(
            "ще прегледам доклада утре сутрин", before: "Прегледах доклада, утре сутрин ще пиша"))
    }

    // MARK: - Render-time live-echo guard (stale-AX duplicate ghost)

    func testEchoesLiveContextRejectsFullTailEcho() {
        // AX lagged: request-time `before` missed "как си", the model produced
        // exactly those words — at render time they ARE the live text's tail.
        XCTAssertTrue(CoreBridge.echoesLiveContext("как си", liveBefore: "Здравей, как си"))
    }

    func testEchoesLiveContextRejectsRestatement() {
        XCTAssertTrue(CoreBridge.echoesLiveContext(
            "Здравей как си днес", liveBefore: "Здравей, как си днес? "))
    }

    func testEchoesLiveContextKeepsGenuineContinuation() {
        XCTAssertFalse(CoreBridge.echoesLiveContext(
            "добре, а ти как прекара деня", liveBefore: "Здравей, как си? Аз съм "))
    }

    func testEchoesAnywhereIgnoresPhraseReuseFromDistantText() {
        // A 3-word phrase written far earlier in a long document must NOT
        // suppress a legitimate continuation that reuses it — only the recent
        // tail (what the model actually saw as context) counts as echo source.
        let distant = "the quarterly revenue report shows strong growth. "
        let filler = String(repeating: "Later we discussed unrelated planning topics in detail. ", count: 20)
        XCTAssertFalse(CoreBridge.echoesAnywhere(
            "update the quarterly revenue report with new numbers",
            before: distant + filler + "As a next step we should "))
        // Same phrase inside the recent tail IS an echo.
        XCTAssertTrue(CoreBridge.echoesAnywhere(
            "update the quarterly revenue report with new numbers",
            before: filler + distant + "As a next step we should "))
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

    func testTrimsEdgeMarkdownMarkersKeepsWords() {
        // "**tato" — model emitting markdown emphasis at the edge; the word
        // itself is salvageable, so the marker is trimmed rather than rejected.
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion("**tato", before: "kupih si edin lap"),
            "tato"
        )
        // Leading-space completions keep their space after edge trimming.
        XCTAssertEqual(
            CoreBridge.sanitizeCompletion(" until Friday", before: "I will be away"),
            " until Friday"
        )
    }

    func testRejectsInteriorMarkdownEmphasis() {
        // Interior markers are real markdown the trim can't salvage — reject so
        // the retry ladder rewrites it.
        XCTAssertNil(
            CoreBridge.sanitizeCompletion("this is **very** important", before: "note that ")
        )
    }

    func testRejectsMixedScriptWord() {
        // A single word blending Cyrillic and Latin letters is sampling garbage
        // ("овrição") — too short for mismatchedScript's ≥8-letter drift
        // threshold, so the dedicated mixed-word guard must catch it.
        XCTAssertTrue(CoreBridge.mixesScriptsWithinWord("овrição"))
        let before = "Ще отсъствам от офиса до "
        XCTAssertNil(CoreBridge.sanitizeCompletion("овrição", before: before))
    }

    func testMixedScriptGuardAllowsPureLatinLoanwordAndHyphenCompound() {
        // Pure-Latin loanword and hyphenated compound both keep each letter-run
        // single-script — never rejected.
        XCTAssertFalse(CoreBridge.mixesScriptsWithinWord("купих си iPhone"))
        XCTAssertFalse(CoreBridge.mixesScriptsWithinWord("IT-специалист в отдела"))
    }

    func testRejectsGluedCapitalMidWord() {
        // Live report: mid-word, the model started a fresh capitalized sentence
        // glued onto the unfinished word ("иска" + "Мнение…"). Never a valid
        // continuation of a lowercase fragment.
        XCTAssertNil(CoreBridge.sanitizeCompletion("Мнение за това", before: "иска"))
        XCTAssertNil(CoreBridge.sanitizeCompletion("Note that this", before: "I wi"))
        // Lowercase word-finish stays allowed…
        XCTAssertNotNil(CoreBridge.sanitizeCompletion("ll check tomorrow", before: "I wi"))
        // …a new word after its separating space may be capitalized…
        XCTAssertNotNil(CoreBridge.sanitizeCompletion(" Иван ще дойде", before: "утре с"))
        // …and after a boundary (trailing space) a capital start is fine.
        XCTAssertNotNil(CoreBridge.sanitizeCompletion("Понеделник е добре", before: "до "))
    }

    func testRejectsMixedScriptWordBeyondLatinCyrillic() {
        // Observed live: "могամ" — a Bulgarian word with 2 Armenian letters glued
        // in. Under containsForeignScript's ≥3-letter threshold, so the per-word
        // mix guard must catch it via script buckets, not just Latin/Cyrillic.
        XCTAssertTrue(CoreBridge.mixesScriptsWithinWord("могամ ли?"))
        XCTAssertNil(CoreBridge.sanitizeCompletion("могամ ли?", before: "искам да те по"))
    }

    func testBulgarianCyrillicRejectsRussianMarkerLetters() {
        // ы/э/ё do not exist in Bulgarian; with the Bulgarian pin active a
        // suggestion containing one is Russian drift (live: "запустить тестовый
        // сценарий" on 3 chars of context). Same script, so mismatchedScript is
        // blind — the marker guard must reject, and only when the pin is on.
        let before = "как "
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "запустить тестовый сценарий", before: before, bulgarianCyrillic: true))
        XCTAssertNotNil(CoreBridge.sanitizeCompletion(
            "запустить тестовый сценарий", before: before, bulgarianCyrillic: false))
        // Clean Bulgarian passes with the pin on (ь is legitimate Bulgarian).
        XCTAssertNotNil(CoreBridge.sanitizeCompletion(
            "ти върви денят с кьорав късмет", before: before, bulgarianCyrillic: true))
    }

    func testBulgarianCyrillicPinHelpers() {
        // The pin must hold from the FIRST Cyrillic keystroke (detector is blind
        // there) — that is where the Russian free-fall was observed.
        XCTAssertTrue(CoreBridge.isCyrillicScript("к"))
        XCTAssertTrue(CoreBridge.isCyrillicScript("как ти върви"))
        XCTAssertFalse(CoreBridge.isCyrillicScript("kak ti"))
        XCTAssertFalse(CoreBridge.isCyrillicScript("купих си iPhone 15 Pro Max ot Amazon"))
    }

    func testEchoesScreenContextRejectsQuotedScreenLine() {
        // Live BG failure: with conversation OCR in the prompt the model "continued"
        // by quoting a message visible on screen ("1. чекиран на твое име").
        let screen = """
        имаме 3 варианта
        1. чекиран на твое име и всичко в него
        2. двамата сме с ръчни
        """
        XCTAssertTrue(CoreBridge.echoesScreenContext("1. чекиран на твое име", screen: screen))
        // Short natural overlaps (a name, "не знам") stay under the ≥12 gate.
        XCTAssertFalse(CoreBridge.echoesScreenContext("не знам", screen: screen))
        // Fresh text is never rejected, and absent screen context is a no-op.
        XCTAssertFalse(CoreBridge.echoesScreenContext("утре ще ти пиша пак", screen: screen))
        XCTAssertFalse(CoreBridge.echoesScreenContext("1. чекиран на твое име", screen: nil))
    }

    func testFillGapRejectsAfterTextEcho() {
        // Regress fill-gap find (gap01): `after` starts with its separator space,
        // so a suggestion echoing the after-text verbatim never aligned with the
        // raw head and shipped whole. The trimmed-head match must eat it entirely.
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "was caused by the deploy.",
            before: "I checked the logs and the ",
            after: " was caused by the deploy."
        ))
        // Partial trailing echo still trims at the word boundary, keeping the head.
        XCTAssertEqual(CoreBridge.sanitizeCompletion(
            "outage was caused by the deploy.",
            before: "I checked the logs and the ",
            after: " was caused by the deploy."
        ), "outage")
        // No overlap → untouched.
        XCTAssertEqual(CoreBridge.sanitizeCompletion(
            "outage happened",
            before: "I checked the logs and the ",
            after: " was caused by the deploy."
        ), "outage happened")
    }

    func testFillGapRejectsAfterTextNearEcho() {
        // Regress find round 2: a one-word variant defeats the exact-overlap trim
        // ("…the deployment" vs after's "…the deploy.") — the near-echo guard
        // rejects when the first 3 words duplicate the after-head.
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "was caused by the deployment",
            before: "I checked the logs and the ",
            after: " was caused by the deploy."
        ))
        // Genuine gap fill sharing fewer than 3 leading words survives.
        XCTAssertEqual(CoreBridge.sanitizeCompletion(
            "outage was severe",
            before: "I checked the logs and the ",
            after: " was caused by the deploy."
        ), "outage was severe")
    }

    func testEchoesAfterHead() {
        XCTAssertTrue(CoreBridge.echoesAfterHead("Was caused, by them", afterHead: " was caused by the deploy."))
        XCTAssertFalse(CoreBridge.echoesAfterHead("was caused", afterHead: " was caused by the deploy."))
        XCTAssertFalse(CoreBridge.echoesAfterHead("outage was caused", afterHead: " was caused by the deploy."))
        XCTAssertFalse(CoreBridge.echoesAfterHead("", afterHead: "anything at all here"))
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

    // MARK: - Russian-only word gate (Cyrillic sister-language leak)

    @MainActor
    func testRussianOnlyWordGate() throws {
        let available = NSSpellChecker.shared.availableLanguages
        try XCTSkipUnless(available.contains("bg") && available.contains("ru"),
                          "bg/ru dictionaries not installed on this runner")
        // Confidently-Russian words (bg flags, ru accepts) → rejected.
        XCTAssertTrue(CoreBridge.containsRussianOnlyCyrillicWord("в пятница"))
        XCTAssertTrue(CoreBridge.containsRussianOnlyCyrillicWord("сегодня вечером"))
        XCTAssertTrue(CoreBridge.containsRussianOnlyCyrillicWord("човекът, который дойде"))
        // Bulgarian words → pass.
        XCTAssertFalse(CoreBridge.containsRussianOnlyCyrillicWord("днес и утре"))
        XCTAssertFalse(CoreBridge.containsRussianOnlyCyrillicWord("среща в офиса"))
        // bg-dictionary gap flagged by BOTH dicts (conjunction rule) → pass.
        XCTAssertFalse(CoreBridge.containsRussianOnlyCyrillicWord("в петък"))
        // Latin text never scanned.
        XCTAssertFalse(CoreBridge.containsRussianOnlyCyrillicWord("see you on friday"))
    }

    func testInputSourceLanguagesFeedOsList() {
        // Union list must at least resolve without crashing and dedupe names;
        // exact contents are machine-dependent.
        let list = CoreBridge.osLanguagesList()
        XCTAssertFalse(list.isEmpty)
        let names = list.components(separatedBy: ", ")
        XCTAssertEqual(names.count, Set(names).count)
    }
}
