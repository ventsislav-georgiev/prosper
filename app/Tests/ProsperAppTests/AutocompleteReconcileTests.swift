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
        // 0.12 * 0.6 = 0.072 → clamped up to debounceMin (0.08).
        XCTAssertEqual(interval, 0.08, accuracy: 0.001)
    }

    func testFastModelClampsToMin() {
        // Repeated fast (20ms) responses drive the interval to the floor.
        var ema = 0.12
        var interval = 0.12
        for _ in 0..<50 { (ema, interval) = AutocompleteEngine.nextDebounce(ema: ema, elapsed: 0.02) }
        XCTAssertEqual(interval, 0.08, accuracy: 0.001) // debounceMin
    }

    func testSlowModelRaisesInterval() {
        // A steady 500ms model debounces longer (0.5*0.6 = 0.3) so we stop spamming it.
        var ema = 0.12
        var interval = 0.12
        for _ in 0..<50 { (ema, interval) = AutocompleteEngine.nextDebounce(ema: ema, elapsed: 0.5) }
        XCTAssertEqual(interval, 0.3, accuracy: 0.01)
    }

    func testColdLoadSampleDoesNotPinAtMax() {
        // One 5s cold-load-inflated sample must not stick the debounce at max.
        let (ema, interval) = AutocompleteEngine.nextDebounce(ema: 0.12, elapsed: 5.0)
        // Sample capped at 1.0 → EMA = 0.12*0.7 + 1.0*0.3 = 0.384 → interval 0.2304.
        XCTAssertEqual(ema, 0.384, accuracy: 0.001)
        XCTAssertLessThan(interval, AutocompleteEngine.debounceMax)
        XCTAssertEqual(interval, 0.2304, accuracy: 0.001)
    }

    func testNeverExceedsMax() {
        // Even sustained capped samples can't push past debounceMax (0.6).
        var ema = 5.0 // start absurdly high
        var interval = 0.6
        for _ in 0..<50 { (ema, interval) = AutocompleteEngine.nextDebounce(ema: ema, elapsed: 1.0) }
        XCTAssertLessThanOrEqual(interval, AutocompleteEngine.debounceMax)
    }
}
