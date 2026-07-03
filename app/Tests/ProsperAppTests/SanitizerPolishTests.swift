import XCTest

@testable import ProsperApp

/// Polish-round pins for the sanitizer false-reject fixes: each test encodes a
/// realistic completion that used to be killed (or trimmed) wrongly, plus the
/// garbage case the guard still must catch.
final class SanitizerPolishTests: XCTestCase {

    // MARK: - cutImmediateRepeat: deliberate reduplication survives

    func testVeryVeryReduplicationSurvives() {
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("very very good"), "very very good")
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("много много благодаря"), "много много благодаря")
    }

    func testStutterLoopStillCut() {
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("je je."), "je")
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("the the plan"), "the")
    }

    // MARK: - trimDanglingTail: possessive apostrophe is not a dangling opener

    func testPluralPossessiveApostropheKept() {
        XCTAssertEqual(CoreBridge.trimDanglingTail("the players' "), "the players'")
        XCTAssertEqual(CoreBridge.trimDanglingTail("the teams\" "), "the teams\"")
    }

    func testDanglingOpenerStillStripped() {
        XCTAssertEqual(CoreBridge.trimDanglingTail("she said ("), "she said")
        // Quote after whitespace is a genuine unclosed opener.
        XCTAssertEqual(CoreBridge.trimDanglingTail("she said \""), "she said")
    }

    // MARK: - junk markers: code operators pass, markdown emphasis rejected

    func testCodeOperatorsSurviveMidString() {
        XCTAssertNotNil(CoreBridge.sanitizeCompletion("a || b) { return }", before: "if ("))
        XCTAssertNotNil(CoreBridge.sanitizeCompletion("cout << endl;", before: "std::"))
    }

    func testMarkdownEmphasisStillRejectedMidString() {
        XCTAssertNil(CoreBridge.sanitizeCompletion("some **bold** claim", before: "and then "))
    }

    // MARK: - mid-word capital guard: scoped to unfinished fragments

    func testCapitalAfterCompleteWordAllowed() throws {
        // Model omitted the leading space on a proper noun after a finished word;
        // applyWordBoundary adds the space downstream — must not be rejected.
        // The guard keys off the bundled lexicon, which only loads inside the app
        // bundle — skip (not fail) where it is unavailable.
        try XCTSkipUnless(
            Lexicon.shared.isKnownWord("and"), "bundled lexicon not loaded in this environment")
        XCTAssertNotNil(CoreBridge.sanitizeCompletion("Docker containers", before: "we deploy with and"))
    }

    func testCapitalGluedOntoFragmentStillRejected() {
        // Mid-word glue: unfinished Cyrillic fragment + fresh capitalized start.
        XCTAssertNil(CoreBridge.sanitizeCompletion("Мнение по въпроса", before: "той иска"))
    }

    // MARK: - echoesWritingSample: verbatim-lift guard, not a phrase ban

    func testShortStockPhraseInsideSampleAllowed() {
        let samples = ["thanks for your email, I will get back to you shortly"]
        XCTAssertFalse(CoreBridge.echoesWritingSample("thanks for", samples: samples))
        XCTAssertFalse(CoreBridge.echoesWritingSample("поздрави", samples: ["поздрави, Венци — хубав ден и до скоро"]))
    }

    func testVerbatimSampleLiftStillRejected() {
        let samples = ["thanks for your email, I will get back to you shortly"]
        XCTAssertTrue(CoreBridge.echoesWritingSample(
            "thanks for your email, I will get back to you shortly", samples: samples))
    }

    func testInstructionHeaderEchoStillRejected() {
        XCTAssertTrue(CoreBridge.echoesWritingSample(
            "Examples of how the user usually writes", samples: ["anything"]))
    }
}

/// Outgoing-message contract: never answer the user's own question, and start
/// new sentences with a capital (live reports 2026-07-03).
final class OutgoingMessageContractTests: XCTestCase {
    func testAnswerToOwnQuestionRejected() {
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "I'm doing fine, thanks", before: "Hey, how are you doing? "))
        XCTAssertEqual(CoreBridge.lastRejectReason, "answersOwnQuestion")
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "Yes, of course", before: "Can you send the file? "))
    }

    func testSenderContinuationAfterQuestionAllowed() {
        XCTAssertNotNil(CoreBridge.sanitizeCompletion(
            "I hope this message finds you well", before: "Hey, how are you doing? "))
        XCTAssertNotNil(CoreBridge.sanitizeCompletion(
            "Let me know when you have a minute", before: "Hey, how are you doing? "))
    }

    func testNoQuestionMeansNoAnswerGuard() {
        XCTAssertNotNil(CoreBridge.sanitizeCompletion(
            "I'm heading out for lunch", before: "Quick update. "))
    }

    func testNewSentenceCapitalized() {
        XCTAssertEqual(
            CoreBridge.capitalizeNewSentence(
                "the fence was low", before: "The quick brown fox jumps over the lazy dog. "),
            "The fence was low")
        XCTAssertEqual(
            CoreBridge.capitalizeNewSentence(
                " утре ще дойда", before: "Готово е. "),
            " Утре ще дойда")
    }

    func testGluedContinuationAfterPeriodNotCapitalized() {
        // Domain/decimal glue: no whitespace after the terminator and none
        // opening the completion — not a new sentence.
        XCTAssertEqual(
            CoreBridge.capitalizeNewSentence("com today", before: "visit example."),
            "com today")
        XCTAssertEqual(
            CoreBridge.capitalizeNewSentence(" the next thing", before: "I am done."),
            " The next thing")
    }

    func testMidSentenceAndEllipsisLeftAlone() {
        XCTAssertEqual(
            CoreBridge.capitalizeNewSentence("the fence", before: "jumps over "),
            "the fence")
        XCTAssertEqual(
            CoreBridge.capitalizeNewSentence("maybe tomorrow", before: "I was thinking... "),
            "maybe tomorrow")
        XCTAssertEqual(
            CoreBridge.capitalizeNewSentence("Already capital", before: "Done. "),
            "Already capital")
    }
}

/// Russian-word gate on mid-word continuations: a glued fragment must be judged
/// as part of the word it completes, not as a standalone token (live report
/// 2026-07-03: Telegram "прахосму" + "качка" — "качка" alone is Russian-only,
/// joined "прахосмукачка" is plain Bulgarian).
@MainActor
final class RussianGateFragmentTests: XCTestCase {
    private func requireDictionaries() throws {
        let langs = NSSpellChecker.shared.availableLanguages
        try XCTSkipUnless(
            langs.contains("bg") && langs.contains("ru"),
            "bg/ru spellcheck dictionaries unavailable — gate fails open here")
    }

    func testGluedFragmentJudgedAsJoinedWord() throws {
        try requireDictionaries()
        XCTAssertFalse(CoreBridge.containsRussianOnlyCyrillicWord(
            "качка", before: "дали може днес да пуснем прахосму"))
        XCTAssertFalse(CoreBridge.containsRussianOnlyCyrillicWord(
            "качката и мопа", before: "дали може днес да пуснем прахосму"))
    }

    func testStandaloneRussianWordStillRejected() throws {
        try requireDictionaries()
        XCTAssertTrue(CoreBridge.containsRussianOnlyCyrillicWord(
            "качка", before: "дали може днес да пуснем "))
        XCTAssertTrue(CoreBridge.containsRussianOnlyCyrillicWord(
            " завтра ще дойда", before: "дали може днес да пуснем прахосму"))
    }
}

/// Latinica-detector marker gating: bare `q` counts only in all-lowercase words,
/// so English tech prose with acronyms never gets steered into the latinica path.
final class LatinicaMarkerGatingTests: XCTestCase {
    func testAcronymsAndProperNounsDoNotTriggerLatinica() {
        XCTAssertFalse(CoreBridge.looksLikeTransliteratedBulgarian(
            "we store the metadata in SQL and the FAQ covers the QA flow"))
        XCTAssertFalse(CoreBridge.looksLikeTransliteratedBulgarian(
            "the Iraq report mentions Qatar exports"))
    }

    func testLowercaseBareQStillTriggersLatinica() {
        XCTAssertTrue(CoreBridge.looksLikeTransliteratedBulgarian("kak q karash dneska"))
        XCTAssertTrue(CoreBridge.looksLikeTransliteratedBulgarian("vashiq proekt e gotov"))
    }

    func testShtMarkerStillTriggersLatinica() {
        XCTAssertTrue(CoreBridge.looksLikeTransliteratedBulgarian("shte doida utre"))
    }
}

/// RecentSentences session-vocabulary lookup (feeds the suspicious-token gate).
@MainActor
final class RecentSentencesVocabularyTests: XCTestCase {
    override func setUp() async throws { RecentSentences.shared.reset() }

    func testHasRecentWordFindsCommittedToken() {
        RecentSentences.shared.ingest(before: "we renamed the dto mapper yesterday. ")
        XCTAssertTrue(RecentSentences.shared.hasRecentWord("dto"))
        XCTAssertTrue(RecentSentences.shared.hasRecentWord("DTO"))
        XCTAssertFalse(RecentSentences.shared.hasRecentWord("impl"))
    }

    func testHasRecentWordIsWordBounded() {
        RecentSentences.shared.ingest(before: "the detour took an hour extra. ")
        XCTAssertFalse(RecentSentences.shared.hasRecentWord("dto"))
    }

    // MARK: - Bundle scoping: private text never ghosts in another app

    func testRecallIsBundleScoped() {
        RecentSentences.shared.ingest(
            before: "the merger closes on friday, keep it quiet. ",
            bundleId: "com.private.chat")
        XCTAssertNotNil(RecentSentences.shared.continuation(
            for: "the merger", bundleId: "com.private.chat"))
        XCTAssertNil(RecentSentences.shared.continuation(
            for: "the merger", bundleId: "com.work.mail"))
        XCTAssertNil(RecentSentences.shared.continuation(for: "the merger"))
        // hasRecentWord stays cross-app: containment reveals no content.
        XCTAssertTrue(RecentSentences.shared.hasRecentWord("merger"))
    }

    func testSameSentenceInTwoAppsRecallsInBoth() {
        RecentSentences.shared.ingest(before: "see you at the standup tomorrow. ", bundleId: "a")
        RecentSentences.shared.ingest(before: "see you at the standup tomorrow. ", bundleId: "b")
        XCTAssertNotNil(RecentSentences.shared.continuation(for: "see you at", bundleId: "a"))
        XCTAssertNotNil(RecentSentences.shared.continuation(for: "see you at", bundleId: "b"))
    }
}

/// Per-guard reject telemetry: a rejected completion must name its killer guard
/// (bench starvation cases were undiagnosable from a bare `return nil`).
final class SanitizerRejectReasonTests: XCTestCase {
    func testMarkdownRejectRecordsReason() {
        XCTAssertNil(CoreBridge.sanitizeCompletion("some **bold** claim", before: "and then "))
        XCTAssertEqual(CoreBridge.lastRejectReason, "markdown")
    }

    func testRussianMarkerRecordsReason() {
        XCTAssertNil(CoreBridge.sanitizeCompletion(
            "запустить тестовый прогон", before: "утре ще", bulgarianCyrillic: true))
        XCTAssertEqual(CoreBridge.lastRejectReason, "russianMarker")
    }

    func testAcceptedCompletionClearsReason() {
        XCTAssertNotNil(CoreBridge.sanitizeCompletion("brown fox", before: "the quick "))
        XCTAssertNil(CoreBridge.lastRejectReason)
    }
}
