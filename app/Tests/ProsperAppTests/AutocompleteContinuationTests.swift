import AppKit
import XCTest
@testable import ProsperApp

/// Acceptance criteria for what inline autocomplete actually INSERTS, exercised
/// deterministically (no model, no AX) by running raw model output through the
/// real post-generation pipeline the engine uses:
///
///   sanitizeCompletion(raw, before, after)  ->  applyWordBoundary(before, _)
///
/// These encode the real-world cases that bit us: completing in the middle of a
/// word, completing at the end of a word the user hasn't spaced yet, the model
/// repeating/echoing what's already typed, and punctuation/number boundaries.
/// The live model is non-deterministic — the e2e suite asserts only invariants —
/// so the exact-string contract lives here, where the inputs are fixed.
@MainActor
final class AutocompleteContinuationTests: XCTestCase {

    private var savedSpell: SpellOracle?
    private var savedLexicon: Lexicon?

    override func setUp() {
        super.setUp()
        savedSpell = SpellOracle.current
        SpellOracle.current = .fake() // verdicts must not follow the Mac's dictionaries (#1310)
        savedLexicon = Lexicon.shared
        Lexicon.store(.bundledFromSources) // the shipped lexicon, not xctest's empty one (#1679)
    }

    override func tearDown() {
        if let savedSpell { SpellOracle.current = savedSpell }
        if let savedLexicon { Lexicon.store(savedLexicon) }
        super.tearDown()
    }

    /// What the engine would insert for `raw`, or nil when the pipeline suppresses
    /// it (sanitize rejected an echo, or the mid-word garbage guard fired).
    private func inserted(before: String, raw: String, after: String = "") -> String? {
        guard let s = CoreBridge.sanitizeCompletion(raw, before: before, after: after),
              !s.isEmpty else { return nil }
        let spaced = AutocompleteEngine.applyWordBoundary(before: before, suggestion: s)
        if AutocompleteEngine.startsNewWordAgainstUnfinishedFragment(before: before, spaced: spaced) {
            return nil
        }
        return spaced
    }

    /// The visible field text after insertion (caret splits before/after).
    private func field(before: String, raw: String, after: String = "") -> String {
        before + (inserted(before: before, raw: raw, after: after) ?? "") + after
    }

    // MARK: - End of a word the user hasn't spaced yet (the "brownfox" bug)

    func testNewWordAfterCompleteWordGetsSpaced() {
        XCTAssertEqual(field(before: "the quick brown", raw: "fox jumps"),
                       "the quick brown fox jumps")
    }

    func testNewWordWhenModelAlreadySpacedStaysSingleSpaced() {
        XCTAssertEqual(field(before: "the quick brown", raw: " fox jumps"),
                       "the quick brown fox jumps")
    }

    func testTrailingSpacePlusModelSpaceDoesNotDouble() {
        XCTAssertEqual(field(before: "the quick brown ", raw: " fox"),
                       "the quick brown fox")
    }

    // MARK: - Middle of a word (continuations)

    func testMidWordContinuationNoSpace() {
        XCTAssertEqual(field(before: "the quick brow", raw: "n fox"),
                       "the quick brown fox")
    }

    func testMidWordWholeWordRepeatLowercaseDeduped() {
        // Model re-emits the whole word it was meant to continue.
        XCTAssertEqual(field(before: "visit my websit", raw: "website here"),
                       "visit my website here")
    }

    func testMidWordContinuationFromBareFragment() {
        XCTAssertEqual(field(before: "I am goin", raw: "going to the store"),
                       "I am going to the store")
    }

    // MARK: - Middle of a word (garbage that must be suppressed)

    func testMidWordNewWordAgainstUnfinishedFragmentSuppressed() {
        // "wri" is not a word; the model abandoned it and started "recording".
        // Inserting " recording" would orphan the fragment as "wri recording".
        XCTAssertNil(inserted(before: "I'll be wri", raw: " recording soon"))
    }

    func testMidWordCaseMismatchedRepeatNotGarbled() {
        // "websit" + "Website" must never surface as "websit Website here".
        let f = field(before: "visit my websit", raw: "Website here")
        XCTAssertFalse(f.contains("websit Website"),
                       "orphaned fragment + new word: \(f)")
    }

    func testCompleteButUnspacedWordStillGetsItsSpace() {
        // Counterpart to the suppression: "brown" IS a word, so the user just
        // hasn't hit space — the new word is wanted, spaced.
        XCTAssertEqual(field(before: "the quick brown", raw: "fox"),
                       "the quick brown fox")
    }

    // MARK: - Echo / restatement (model repeats already-typed text)

    func testWholeRestatementStripped() {
        XCTAssertEqual(
            field(before: "Dear team, thank you for", raw: "Dear team, thank you for your patience"),
            "Dear team, thank you for your patience")
    }

    func testLastWordEchoWithStraySpaceStripped() {
        XCTAssertEqual(field(before: "the quick", raw: " quick brown"),
                       "the quick brown")
    }

    func testInteriorEchoRejected() {
        // Starts fresh then lifts a phrase already written -> show nothing.
        XCTAssertNil(inserted(before: "thanks for the report. I will",
                              raw: "review thanks for the report again"))
    }

    // MARK: - Punctuation / numbers

    func testSentenceStartAfterPeriodSpaced() {
        XCTAssertEqual(field(before: "I am done.", raw: "The next thing"),
                       "I am done. The next thing")
    }

    func testDomainAfterPeriodStaysGlued() {
        XCTAssertEqual(field(before: "visit example.", raw: "com today"),
                       "visit example.com today")
    }

    func testDecimalStaysGlued() {
        XCTAssertEqual(field(before: "pi is 3.", raw: "14159"), "pi is 3.14159")
    }

    // MARK: - Mid-line (text after the caret)

    func testMidlineDoesNotDuplicateTextAfterCaret() {
        // Caret between "brown " and "jumps"; model tries to complete into the
        // text that already follows — the trailing overlap is dropped.
        let f = field(before: "the quick brown ", raw: "fox jumps over", after: "jumps over the dog")
        XCTAssertFalse(f.contains("jumps over jumps over"), "duplicated after-text: \(f)")
    }

    // MARK: - Word-by-word (Tab) accept spacing

    func testFirstWordAcceptCarriesItsTrailingSpace() {
        // Tab accepts one word; the separator must travel WITH the accepted word so
        // the next word doesn't glue ("fox" then "jumps" -> "fox jumps", not
        // "foxjumps"). The remainder must not start with a leftover space.
        let (head, tail) = AutocompleteEngine.splitFirstWord("fox jumps over")
        XCTAssertEqual(head, "fox ")
        XCTAssertEqual(tail, "jumps over")
    }

    func testFirstWordAcceptKeepsLeadingSpaceWithHead() {
        // A space-led suggestion (new word after an unspaced word) keeps that
        // leading space on the first accept so the boundary survives.
        let (head, tail) = AutocompleteEngine.splitFirstWord(" fox jumps")
        XCTAssertEqual(head, " fox ")
        XCTAssertEqual(tail, "jumps")
    }

    func testFirstWordAcceptOfSingleWordLeavesNoRemainder() {
        let (head, tail) = AutocompleteEngine.splitFirstWord("done")
        XCTAssertEqual(head, "done")
        XCTAssertEqual(tail, "")
    }

    // MARK: - Spell-oracle seam (#1310)

    /// The fake marks the English word "brown" misspelled: the insertion is
    /// suppressed, the red the five rows above showed on a Mac whose checker
    /// rejected it. Proves the misspelled check asks the oracle.
    func testOracleMisspellingOfAnEnglishWordReproducesTheSuppression() {
        SpellOracle.current = .fake(words: SpellOracle.fakeEnglishWords.subtracting(["brown"]))
        XCTAssertTrue(AutocompleteEngine.lastWordLooksMisspelled("the quick brown"))
        XCTAssertTrue(inserted(before: "the quick brown", raw: "fox jumps") == nil)
    }

    /// Only the 2-arg misspelled check says "misspelled": the suppression is its
    /// doing, whatever the other questions answer.
    func testMisspelledVerdictComesFromTheOracle() {
        var spell = SpellOracle.fake()
        spell.isMisspelled = { $0 == "brown" }
        SpellOracle.current = spell
        XCTAssertTrue(AutocompleteEngine.lastWordLooksMisspelled("the quick brown"))
        XCTAssertFalse(AutocompleteEngine.lastWordLooksMisspelled("the quick fox"))
    }

    /// A finished word counts as complete only if the oracle offers a longer
    /// word for it: with no completions the fragment guard suppresses, with one
    /// made-up completion it inserts.
    func testCompletablePrefixComesFromTheOracle() {
        Lexicon.store(.empty) // a lexicon-known word never reaches the oracle (row below); tearDown restores
        var spell = SpellOracle.fake()
        spell.completions = { _, _ in [] }
        SpellOracle.current = spell
        XCTAssertFalse(AutocompleteEngine.lastWordIsCompletablePrefix("the quick brown"))
        XCTAssertTrue(inserted(before: "the quick brown", raw: "fox jumps") == nil)
        spell.completions = { fragment, _ in fragment == "brown" ? ["brownqz"] : [] }
        SpellOracle.current = spell
        XCTAssertTrue(AutocompleteEngine.lastWordIsCompletablePrefix("the quick brown"))
        XCTAssertEqual(inserted(before: "the quick brown", raw: "fox jumps"), " fox jumps")
    }

    /// #1679 counterpart: with the real lexicon "brown" is a known word, so the
    /// fragment guard lets the spaced word through even when the oracle offers
    /// no completion at all.
    func testLexiconKnownWordNeedsNoOracleCompletion() {
        var spell = SpellOracle.fake()
        spell.completions = { _, _ in [] }
        SpellOracle.current = spell
        XCTAssertEqual(inserted(before: "the quick brown", raw: "fox jumps"), " fox jumps")
    }

    /// Production default: the seam starts as the live checker, and the live
    /// closures make the same NSSpellChecker calls the guards made at TIP.
    func testLiveOracleIsTheDefaultAndMakesTheOriginalCalls() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Autocomplete")
        let engine = try String(contentsOf: src.appendingPathComponent("AutocompleteEngine.swift"), encoding: .utf8)
        let candidates = try String(contentsOf: src.appendingPathComponent("CompletionCandidates.swift"), encoding: .utf8)
        XCTAssertTrue(engine.contains("static var current = SpellOracle.live\n"))
        for call in [
            "NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location != NSNotFound",
            "NSSpellChecker.shared.automaticallyIdentifiesLanguages = $0",
            "of: word, startingAt: 0, language: language, wrap: false,\n                inSpellDocumentWithTag: 0, wordCount: nil",
            "forWordRange: range, in: word, language: nil, inSpellDocumentWithTag: 0",
            "forPartialWordRange: range, in: fragment, language: language,\n                inSpellDocumentWithTag: 0",
            "spell.setAutoIdentify(false)",
            "spell.setAutoIdentify(true)",
            "SpellOracle.current.completions(frag, nil)",
            "spell.completions(fragment, \"bg\")",
        ] {
            XCTAssertTrue(engine.contains(call), call)
        }
        // Every checker call in the engine sits in `live`: one per closure (six).
        XCTAssertEqual(engine.components(separatedBy: "NSSpellChecker.shared.").count - 1, 6)
        XCTAssertFalse(candidates.contains("NSSpellChecker.shared"))
        XCTAssertTrue(candidates.contains("SpellOracle.current.guesses(fragment)"))
    }

    // MARK: - Invariants over every case above

    func testNoDoubleSpaceAtInsertionJoinEver() {
        let cases: [(String, String, String)] = [
            ("the quick brown", "fox", ""),
            ("the quick brown ", " fox", ""),
            ("the quick ", " brown fox", ""),
            ("I am done.", "The next", ""),
            ("hello", " world", ""),
        ]
        for (b, raw, after) in cases {
            let f = field(before: b, raw: raw, after: after)
            XCTAssertFalse(f.contains("  "), "double space for before=\"\(b)\" raw=\"\(raw)\" -> \"\(f)\"")
        }
    }
}
