import XCTest

@testable import ProsperApp

/// Tests the pure prompt-prefix KV-cache reuse plan that drives `generateInline`.
/// These verify the index arithmetic (how much of the cache to keep vs. trim)
/// without needing a loaded model — the part most likely to corrupt a reused
/// cache if it were wrong.
final class InlinePrefillPlanTests: XCTestCase {

    private func plan(_ previous: [Int], _ current: [Int]) -> MLXEngine.InlinePrefillPlan {
        MLXEngine.inlinePrefillPlan(previous: previous, current: current)
    }

    // First call: nothing cached → prefill everything, trim nothing.
    func testEmptyPreviousPrefillsAll() {
        XCTAssertEqual(plan([], [1, 2, 3]), .init(commonPrefix: 0, trim: 0))
    }

    // Append-only growth (the common typing case): the new prompt extends the old
    // one → keep the whole shared prefix, prefill only the appended tail.
    func testAppendKeepsWholePrefix() {
        XCTAssertEqual(plan([1, 2, 3], [1, 2, 3, 4, 5]), .init(commonPrefix: 3, trim: 0))
    }

    // The previous prompt also carried no extra tail (cache held exactly the
    // prefix): still keep all 3, trim none.
    func testAppendSingleToken() {
        XCTAssertEqual(plan([1, 2, 3], [1, 2, 3, 4]), .init(commonPrefix: 3, trim: 0))
    }

    // Divergence mid-prompt (e.g. the candidate-hint block changed): keep the
    // shared head, trim the cached divergent tail, prefill the new tail.
    func testDivergenceTrimsTail() {
        XCTAssertEqual(plan([1, 2, 3, 9, 9], [1, 2, 3, 4, 5]), .init(commonPrefix: 3, trim: 2))
    }

    // Identical prompt: never reuse the entire thing — re-prefill the final token
    // so decoding has something to run from. Trim the one duplicated token.
    func testIdenticalReprimesFinalToken() {
        XCTAssertEqual(plan([1, 2, 3], [1, 2, 3]), .init(commonPrefix: 2, trim: 1))
    }

    // Completely different prompt (e.g. focus moved to another field): keep
    // nothing, trim the whole prior cache.
    func testFullDivergenceTrimsAll() {
        XCTAssertEqual(plan([7, 8, 9], [1, 2, 3]), .init(commonPrefix: 0, trim: 3))
    }

    // The new prompt is a strict prefix of the cached one (user deleted the tail):
    // keep all of the new prompt except the last token, trim the rest of the cache.
    func testShrunkPromptTrimsExcess() {
        XCTAssertEqual(plan([1, 2, 3, 4, 5], [1, 2, 3]), .init(commonPrefix: 2, trim: 3))
    }

    // Single-token prompt: nothing to reuse, prefill the lone token.
    func testSingleTokenPrompt() {
        XCTAssertEqual(plan([1, 2], [5]), .init(commonPrefix: 0, trim: 2))
    }
}
