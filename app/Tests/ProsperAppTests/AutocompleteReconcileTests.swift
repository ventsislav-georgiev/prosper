import XCTest
@testable import ProsperApp

/// Covers `AutocompleteEngine.reconcile` (P0.2): a background-refresh completion
/// was computed as a continuation of `anchor`; by the time it arrives the user
/// may have typed forward, deleted, or jumped the caret. The reconciler trims a
/// forward-typed prefix (keeping the ghost alive) and reschedules on any genuine
/// divergence instead of dropping every drifted response.
final class AutocompleteReconcileTests: XCTestCase {
    typealias Outcome = AutocompleteEngine.ReconcileOutcome

    // (a) Live text unchanged since the request → show as-is.
    func testExactMatchShowsUnchanged() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " fox jumps", anchor: "the quick brown", live: "the quick brown"),
            .show(" fox jumps")
        )
    }

    // (b) User typed forward INTO the suggestion → trim consumed delta, show remainder.
    func testForwardTypeTrimsDelta() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " fox jumps", anchor: "the quick brown", live: "the quick brown f"),
            .show("ox jumps")
        )
    }

    func testForwardTypeMultipleCharsTrims() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: "ox jumps", anchor: "the quick brown f", live: "the quick brown fox"),
            .show(" jumps")
        )
    }

    // (b) Forward typing that consumes the ENTIRE suggestion → nothing left → reschedule.
    func testForwardTypeConsumingAllReschedules() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " fox", anchor: "the quick brown", live: "the quick brown fox"),
            .reschedule
        )
    }

    // (b-divergent) Forward typing that does NOT match the suggestion → reschedule
    // (user typed something other than what was predicted).
    func testForwardTypeDivergentReschedules() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " fox jumps", anchor: "the quick brown", live: "the quick brown c"),
            .reschedule
        )
    }

    // (c) Backspace / deletion (anchor extends live) → reschedule.
    func testDeletionReschedules() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " fox jumps", anchor: "the quick brown", live: "the quick brow"),
            .reschedule
        )
    }

    // (d) Multi-char paste in the middle / caret jump → reschedule.
    func testPasteReschedules() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " fox jumps", anchor: "the quick brown", live: "PASTED the quick brown"),
            .reschedule
        )
    }

    func testCaretBackReschedules() {
        // Live no longer has anchor as a prefix (caret moved earlier in the field).
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " fox", anchor: "the quick brown", live: "the quick"),
            .reschedule
        )
    }

    // NBSP tolerance: hosts store the space we typed/injected as NBSP
    // (contenteditable editors; the A2 nonBreakingSpace knob). Space KIND alone
    // is never a divergence — live Telegram: every Tab after the first accept
    // swallowed forever because "…е\u{00A0}" ≠ "…е ".
    func testNBSPInLiveMatchesSpaceAnchor() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(
                suggestion: "по-лесно.", anchor: "ще ни е ", live: "ще ни е\u{00A0}"),
            .show("по-лесно.")
        )
    }

    func testNBSPForwardTypeTrimsDelta() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(
                suggestion: " fox jumps", anchor: "the quick brown", live: "the quick brown\u{00A0}f"),
            .show("ox jumps") // delta " f" (NBSP≡space) consumed the suggestion's " f"
        )
    }

    // type-through composition: anchor must be `lastRenderedBefore` (the post-
    // type-through text the visible ghost is glued to), so a refresh reconciles
    // against the advanced anchor without double-trimming.
    func testTypeThroughThenRefreshComposition() {
        // After type-through advanced the ghost: anchor="...brown fo", suggestion="x jumps".
        // A refresh response for the same continuation arrives; user typed one more char.
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: "x jumps", anchor: "the quick brown fo", live: "the quick brown fox"),
            .show(" jumps")
        )
    }

    // Script switch mid-type (Cyrillic anchor, Latin live) → no prefix match → reschedule.
    func testScriptSwitchReschedules() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " свят", anchor: "здравей", live: "hello"),
            .reschedule
        )
    }

    // Grapheme safety: a multi-scalar emoji typed forward must trim as one unit.
    func testEmojiGraphemeTrim() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: "👨‍👩‍👧 family", anchor: "the ", live: "the 👨‍👩‍👧"),
            .show(" family")
        )
    }

    // Empty anchor (defensive: textBefore is guarded non-empty upstream, but the
    // pure fn must not crash or mis-trim). live extends "" by the whole text; the
    // suggestion does not start with that text → reschedule.
    func testEmptyAnchorReschedules() {
        XCTAssertEqual(
            AutocompleteEngine.reconcile(suggestion: " fox", anchor: "", live: "the quick"),
            .reschedule
        )
    }

    // MARK: - Hot-path budget

    // reconcile() runs once per completion response and once per accept. It must
    // stay trivial on realistic inputs (long field text + a sentence-length ghost).
    // Budget: < 25µs average. Generous vs. measured (~1µs) to avoid CI flake while
    // still catching an accidental O(n²) regression.
    func testReconcilePerformanceBudget() {
        let anchor = String(repeating: "lorem ipsum dolor sit amet ", count: 8) // ~216 chars
        let live = anchor + "th"
        let suggestion = "the next several words the user would plausibly type next"
        let iterations = 20_000
        let start = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for _ in 0..<iterations {
            if case .reschedule = AutocompleteEngine.reconcile(suggestion: suggestion, anchor: anchor, live: live) {
                sink += 1
            }
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
        let avgUs = Double(elapsedNs) / Double(iterations) / 1000.0
        XCTAssertLessThan(avgUs, 25.0, "reconcile avg \(avgUs)µs exceeds 25µs hot-path budget")
        _ = sink
    }
}

/// Covers `AutocompleteEngine.nextDebounce` (P1.1): EMA tracking, the 0.6×
/// multiplier, [min,max] clamp, and the 1s sample cap that keeps a cold model
/// load from pinning the debounce at max for the whole session.
final class AutocompleteDebounceTests: XCTestCase {

    func testStartsNearDefault() {
        // First sample at the seed EMA (0.12) with a ~120ms latency stays snappy.
        let (ema, interval) = AutocompleteEngine.nextDebounce(ema: 0.12, elapsed: 0.12)
        XCTAssertEqual(ema, 0.12, accuracy: 0.001)
        // 0.12 * 0.6 = 0.072, above debounceMin (0.06) → not clamped.
        XCTAssertEqual(interval, 0.072, accuracy: 0.001)
    }

    func testFastModelClampsToMin() {
        // Repeated fast (20ms) responses drive the interval to the floor.
        var ema = 0.12
        var interval = 0.12
        for _ in 0..<50 { (ema, interval) = AutocompleteEngine.nextDebounce(ema: ema, elapsed: 0.02) }
        XCTAssertEqual(interval, 0.06, accuracy: 0.001) // debounceMin
    }

    func testSlowModelRaisesInterval() {
        // A steady 500ms model wants 0.5*0.6 = 0.3, but the interval is capped at
        // debounceMax (0.25) so a slow model still can't stall the ghost past that.
        var ema = 0.12
        var interval = 0.12
        for _ in 0..<50 { (ema, interval) = AutocompleteEngine.nextDebounce(ema: ema, elapsed: 0.5) }
        XCTAssertEqual(interval, 0.25, accuracy: 0.01)
    }

    func testColdLoadSampleDoesNotPinAtMax() {
        // One 5s cold-load-inflated sample must not stick the debounce at max.
        let (ema, interval) = AutocompleteEngine.nextDebounce(ema: 0.12, elapsed: 5.0)
        // Sample capped at 1.0 → EMA = 0.12*0.7 + 1.0*0.3 = 0.384 → interval 0.2304.
        XCTAssertEqual(ema, 0.384, accuracy: 0.001)
        XCTAssertLessThan(interval, AutocompleteEngine.debounceMax)
        XCTAssertEqual(interval, 0.2304, accuracy: 0.001)
    }

    func testThrottleFiresDuringContinuousTyping() {
        // A continuous burst: a keystroke every 150ms for 2s (no pause).
        let keystrokes = stride(from: 0.0, through: 2.0, by: 0.15).map { $0 }
        // Old behavior: the debounce EMA grew toward the old 0.6s cap, which is LONGER
        // than the 150ms inter-keystroke gap, so a pure trailing debounce (no maxWait)
        // resets every keystroke and fires only ONCE, after the burst ends.
        let old = AutocompleteEngine.plannedFires(keystrokes: keystrokes, debounce: 0.6, maxWait: .infinity)
        XCTAssertEqual(old.count, 1, "grown trailing debounce should fire once, on pause")
        XCTAssertGreaterThan(old[0], 2.0, "…and only after the last keystroke")

        // New behavior (maxWait 0.22): the ghost updates WHILE typing — a fire roughly
        // every maxWait across the 2s burst, not just at the end.
        let new = AutocompleteEngine.plannedFires(keystrokes: keystrokes, debounce: 0.10, maxWait: 0.22)
        XCTAssertGreaterThanOrEqual(new.count, 7, "should fire repeatedly during the burst")
        XCTAssertLessThan(new[1], 1.0, "and start firing early, not only after the pause")
    }

    func testNeverExceedsMax() {
        // Even sustained capped samples can't push past debounceMax (0.6).
        var ema = 5.0 // start absurdly high
        var interval = 0.6
        for _ in 0..<50 { (ema, interval) = AutocompleteEngine.nextDebounce(ema: ema, elapsed: 1.0) }
        XCTAssertLessThanOrEqual(interval, AutocompleteEngine.debounceMax)
    }
}

/// Stale-read guard for type-through re-anchoring: a fresh AX caret rect is
/// only trusted when it moved WITH the keystroke (see `caretMovedWithKey`).
final class CaretMovedWithKeyTests: XCTestCase {
    private let old = CGRect(x: 100, y: 50, width: 2, height: 16)

    func testNoBaselineAlwaysAccepts() {
        let fresh = CGRect(x: 90, y: 50, width: 2, height: 16)
        XCTAssertTrue(AutocompleteEngine.caretMovedWithKey(from: nil, to: fresh, shift: 4))
    }

    func testStalePreKeyReadRejectedForwardSpace() {
        // App hasn't inserted the space yet: caret unchanged (± jitter) — the
        // "glued after pressing space" report. Must be rejected.
        let fresh = CGRect(x: 100.5, y: 50, width: 2, height: 16)
        XCTAssertFalse(AutocompleteEngine.caretMovedWithKey(from: old, to: fresh, shift: 4))
    }

    func testRealAdvanceAccepted() {
        let fresh = CGRect(x: 104, y: 50, width: 2, height: 16)
        XCTAssertTrue(AutocompleteEngine.caretMovedWithKey(from: old, to: fresh, shift: 4))
    }

    func testDriftCorrectionStillAccepted() {
        // Our width estimate overshoots (shift 6, real advance 3): the read
        // still moved well past the 40% threshold — accept so drift heals.
        let fresh = CGRect(x: 103, y: 50, width: 2, height: 16)
        XCTAssertTrue(AutocompleteEngine.caretMovedWithKey(from: old, to: fresh, shift: 6))
    }

    func testLineWrapAcceptedDespiteLeftJump() {
        // Wrap: x jumps far left, y moves a line — legitimate.
        let fresh = CGRect(x: 10, y: 70, width: 2, height: 16)
        XCTAssertTrue(AutocompleteEngine.caretMovedWithKey(from: old, to: fresh, shift: 4))
    }

    func testFarVerticalJumpRejectedAsDegenerate() {
        // A keystroke can wrap a line or two; a read 20 lines away is a
        // degenerate AX rect (live: ghost parked ~330px below the text).
        let fresh = CGRect(x: 0, y: 380, width: 2, height: 16)
        XCTAssertFalse(AutocompleteEngine.caretMovedWithKey(from: old, to: fresh, shift: -4))
        // …but a genuine wrap (~1 line) is still accepted.
        let wrap = CGRect(x: 10, y: 70, width: 2, height: 16)
        XCTAssertTrue(AutocompleteEngine.caretMovedWithKey(from: old, to: wrap, shift: 4))
    }

    func testDeleteRequiresLeftMovement() {
        // Reverse shift (regrow on backspace): stale unchanged read rejected,
        // real leftward move accepted.
        let stale = CGRect(x: 100, y: 50, width: 2, height: 16)
        XCTAssertFalse(AutocompleteEngine.caretMovedWithKey(from: old, to: stale, shift: -4))
        let moved = CGRect(x: 96, y: 50, width: 2, height: 16)
        XCTAssertTrue(AutocompleteEngine.caretMovedWithKey(from: old, to: moved, shift: -4))
    }
}

/// Per-letter typo-fix split (reference-style display + minimal retype).
final class TypoFixSplitTests: XCTestCase {
    func testTransposition() {
        let s = AutocompleteEngine.typoFixSplit(original: "teh", fix: "the")
        XCTAssertEqual(s.strike, "eh"); XCTAssertEqual(s.replacement, "he")
        XCTAssertEqual(s.replaceLength, 2)
    }

    func testMidWordInsertion() {
        let s = AutocompleteEngine.typoFixSplit(original: "qustion", fix: "question")
        XCTAssertEqual(s.strike, "stion"); XCTAssertEqual(s.replacement, "estion")
        XCTAssertEqual(s.replaceLength, 5)
    }

    func testSingleWrongLetter() {
        let s = AutocompleteEngine.typoFixSplit(original: "helo", fix: "hello")
        XCTAssertEqual(s.strike, "o"); XCTAssertEqual(s.replacement, "lo")
        XCTAssertEqual(s.replaceLength, 1)
    }

    func testPureTailDeletionKeepsNonEmptyReplacement() {
        let s = AutocompleteEngine.typoFixSplit(original: "cattt", fix: "cat")
        XCTAssertEqual(s.strike, "ttt"); XCTAssertEqual(s.replacement, "t")
        XCTAssertEqual(s.replaceLength, 3)
    }

    func testWhollyDifferentWordStrikesAll() {
        let s = AutocompleteEngine.typoFixSplit(original: "xyz", fix: "abc")
        XCTAssertEqual(s.strike, "xyz"); XCTAssertEqual(s.replacement, "abc")
        XCTAssertEqual(s.replaceLength, 3)
    }
}

/// Session recall of recently written sentences (retype-priority source).
@MainActor
final class RecentSentencesTests: XCTestCase {
    override func setUp() async throws { RecentSentences.shared.reset() }

    func testRetypedSentenceCompletesFromRecall() {
        RecentSentences.shared.ingest(before: "the quick brown fox jumps over the lazy dog. ")
        let cont = RecentSentences.shared.continuation(for: "irrelevant. the qui")
        XCTAssertEqual(cont, "ck brown fox jumps over the lazy dog.")
    }

    func testUnfinishedTailIsNotStored() {
        RecentSentences.shared.ingest(before: "complete sentence here. partial tail without end")
        XCTAssertNil(RecentSentences.shared.continuation(for: "partial tail w"))
        XCTAssertNotNil(RecentSentences.shared.continuation(for: "complete sen"))
    }

    func testCaseInsensitivePrefixKeepsStoredCasing() {
        RecentSentences.shared.ingest(before: "The meeting moved to Friday.\n")
        XCTAssertEqual(RecentSentences.shared.continuation(for: "the meet"), "ing moved to Friday.")
    }

    func testShortFragmentsAndShortSentencesIgnored() {
        RecentSentences.shared.ingest(before: "ok done. yes. the quick brown fox jumps over it. ")
        XCTAssertNil(RecentSentences.shared.continuation(for: "ok"), "fragment under 4 chars")
        XCTAssertNil(RecentSentences.shared.continuation(for: "yes."), "short sentences not stored")
    }

    func testNewestMatchWins() {
        RecentSentences.shared.ingest(before: "the plan is to ship tomorrow. the plan is to wait a week. ")
        XCTAssertEqual(RecentSentences.shared.continuation(for: "the plan"), " is to wait a week.")
    }

    func testExactSentenceGivesNoRemainder() {
        RecentSentences.shared.ingest(before: "we should talk soon. ")
        XCTAssertNil(RecentSentences.shared.continuation(for: "we should talk soon"))
    }
}

/// Typo-tolerant conversion: a new-word suggestion that is a close edit of the
/// broken trailing token becomes an inline correction, not junk to endorse/hide.
@MainActor
final class TypoFixFromSuggestionTests: XCTestCase {
    func testFxConvertsToFox() {
        let c = AutocompleteEngine.typoFixFromSuggestion(
            before: "the quick brown fx", spaced: " fox jumps over the lazy dog")
        XCTAssertEqual(c?.fixWord, "fox")
        XCTAssertEqual(c?.strike, "x")
        XCTAssertEqual(c?.replacement, "ox")
        XCTAssertEqual(c?.replaceLength, 1)
        XCTAssertEqual(c?.continuation, " jumps over the lazy dog")
    }

    func testTtConvertsToTest() {
        let c = AutocompleteEngine.typoFixFromSuggestion(
            before: "Please find the attached tt", spaced: " test file")
        XCTAssertEqual(c?.fixWord, "test")
        XCTAssertEqual(c?.strike, "t")
        XCTAssertEqual(c?.replacement, "est")
        XCTAssertEqual(c?.continuation, " file")
    }

    func testUnrelatedWordDoesNotConvert() {
        XCTAssertNil(AutocompleteEngine.typoFixFromSuggestion(
            before: "the quick brown fx", spaced: " dog barks"))
    }

    func testCompleteWordDoesNotConvert() {
        // Trailing token is a real word — model starting a new word is normal.
        XCTAssertNil(AutocompleteEngine.typoFixFromSuggestion(
            before: "the quick brown fox", spaced: " jumps over"))
    }

    func testNonSpacedSuggestionDoesNotConvert() {
        XCTAssertNil(AutocompleteEngine.typoFixFromSuggestion(
            before: "the quick brown f", spaced: "ox jumps"))
    }

    func testEditDistance() {
        XCTAssertEqual(AutocompleteEngine.editDistance("fx", "fox"), 1)
        XCTAssertEqual(AutocompleteEngine.editDistance("tt", "test"), 2)
        XCTAssertEqual(AutocompleteEngine.editDistance("same", "same"), 0)
        XCTAssertEqual(AutocompleteEngine.editDistance("", "abc"), 3)
    }
}
