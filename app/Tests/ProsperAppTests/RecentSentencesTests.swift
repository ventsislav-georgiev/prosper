import XCTest

@testable import ProsperApp

/// Recall priority (3328f11), edge + budget coverage on top of the contract
/// tests in AutocompleteReconcileTests.swift (RecentSentencesTests).
@MainActor
final class RecentSentencesEdgeTests: XCTestCase {
    private var recall: RecentSentences { RecentSentences.shared }

    override func setUp() async throws {
        recall.reset()
    }

    func testPrefixMatchIsCaseInsensitiveRemainderKeepsCasing() {
        recall.ingest(before: "Please CC Maria on the Thread. ")
        XCTAssertEqual(
            recall.continuation(for: "please cc"),
            " Maria on the Thread.")
    }

    func testRewriteBumpsDuplicateToNewest() {
        recall.ingest(before: "the plan is to wait a week. the plan is to ship tomorrow. ")
        recall.ingest(before: "the plan is to wait a week. ")  // rewritten → newest
        XCTAssertEqual(recall.continuation(for: "the plan"), " is to wait a week.")
    }

    func testCyrillicSentenceRoundTrips() {
        recall.ingest(before: "Утре ще изпратя доклада следобед. ")
        XCTAssertEqual(
            recall.continuation(for: "Утре ще"),
            " изпратя доклада следобед.")
    }

    func testCapEvictsOldest() {
        // 210 distinct sentences; the first 10 must be evicted (cap 200).
        for i in 0..<210 {
            recall.ingest(before: "unique sentence number \(i) padded out. ")
        }
        XCTAssertNil(recall.continuation(for: "unique sentence number 5 p"))
        XCTAssertNotNil(recall.continuation(for: "unique sentence number 209"))
    }

    func testCurrentFragmentTakesTextAfterLastTerminator() {
        XCTAssertEqual(
            RecentSentences.currentFragment(of: "Done. Now typing this"),
            "Now typing this")
        XCTAssertEqual(RecentSentences.currentFragment(of: "ends here."), "")
    }

    /// Hot-path budget: `ingest` + `continuation` run per keystroke on the
    /// engine path (pre-LLM). At a full 200-entry buffer and a 600-char window
    /// they must stay far under a keystroke frame. Generous ceiling — guards
    /// superlinear regressions, not micro-jitter.
    func testPerKeystrokeLookupBudget() {
        for i in 0..<200 {
            recall.ingest(before: "warm entry number \(i) with enough words here. ")
        }
        let before = String(
            repeating: "Sentence body with several words inside. ", count: 14)
            + "warm entry number 1"
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<1_000 {
                recall.ingest(before: before)
                _ = recall.continuation(for: before)
            }
        }
        // 1k keystroke-equivalents; < 250ms total (≪ 1ms per keystroke, real
        // measured cost is far lower).
        XCTAssertLessThan(elapsed, .milliseconds(250), "recall path regressed: \(elapsed)")
    }
}
