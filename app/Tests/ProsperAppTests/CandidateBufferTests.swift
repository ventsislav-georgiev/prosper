import XCTest
@testable import ProsperApp

/// B2 candidate buffer: ranking by avg-logprob and instant prefix-match swap.
final class CandidateBufferTests: XCTestCase {

    private func buf(_ anchor: String, _ cs: [(String, Float)]) -> CandidateBuffer {
        CandidateBuffer(anchorBefore: anchor,
                        candidates: cs.map { .init(text: $0.0, avgLogprob: $0.1) })
    }

    func testRanksBestFirst() {
        let b = buf("I am ", [(" tired", -2.0), (" going home", -0.5), (" here", -1.0)])
        XCTAssertEqual(b.best, " going home")
    }

    func testNoDivergenceReturnsBest() {
        let b = buf("see you ", [("tomorrow", -0.3), ("soon", -0.9)])
        XCTAssertEqual(b.bestMatching(currentBefore: "see you "), "tomorrow")
    }

    func testSwapsToAlternateOnDivergingKeystroke() {
        // Shown best is "tomorrow"; user types "s", which is the head of "soon".
        let b = buf("see you ", [("tomorrow", -0.3), ("soon", -0.9)])
        XCTAssertEqual(b.bestMatching(currentBefore: "see you s"), "oon")
    }

    func testConsumesTypedPrefixOfShownBest() {
        let b = buf("see you ", [("tomorrow", -0.3), ("soon", -0.9)])
        XCTAssertEqual(b.bestMatching(currentBefore: "see you tom"), "orrow")
    }

    func testReturnsNilWhenNothingMatches() {
        let b = buf("see you ", [("tomorrow", -0.3), ("soon", -0.9)])
        XCTAssertNil(b.bestMatching(currentBefore: "see you x"))
    }

    func testReturnsNilOnUnrelatedContext() {
        let b = buf("see you ", [("tomorrow", -0.3)])
        XCTAssertNil(b.bestMatching(currentBefore: "different text"))
    }
}
