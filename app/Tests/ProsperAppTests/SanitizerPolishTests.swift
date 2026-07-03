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
}
