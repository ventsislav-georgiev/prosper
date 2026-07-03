import XCTest
@testable import ProsperApp

/// B5 (NB) — back-off n-gram bias model over token ids.
final class NgramModelTests: XCTestCase {

    func testEmptyModelYieldsNoBias() {
        let m = NgramModel(maxOrder: 3, strength: 2.0)
        XCTAssertTrue(m.isEmpty)
        XCTAssertTrue(m.biases(context: [1, 2, 3]).isEmpty)
    }

    func testUnseenContextYieldsNoBias() {
        var m = NgramModel(maxOrder: 3, strength: 2.0)
        m.train([1, 2, 3])
        XCTAssertTrue(m.biases(context: [99]).isEmpty)
    }

    func testSingleNextIsDeterministicZeroDelta() {
        // One observed continuation: log(1/1) = 0 → nudge is zero but the token is present.
        var m = NgramModel(maxOrder: 2, strength: 2.0)
        m.train([5, 6])
        let b = m.biases(context: [5])
        XCTAssertEqual(Set(b.keys), [6])
        XCTAssertEqual(b[6]!, 0.0, accuracy: 1e-6)
    }

    func testMoreFrequentNextGetsHigherBias() {
        var m = NgramModel(maxOrder: 2, strength: 1.0)
        // After token 1: token 2 thrice, token 3 once.
        m.train([1, 2, 1, 2, 1, 2, 1, 3])
        let b = m.biases(context: [1])
        XCTAssertNotNil(b[2]); XCTAssertNotNil(b[3])
        XCTAssertGreaterThan(b[2]!, b[3]!)  // 2 is more likely → less-negative logprob
    }

    func testLongestSuffixWins() {
        var m = NgramModel(maxOrder: 3, strength: 1.0)
        // Bigram ctx [9] → 7; trigram ctx [8,9] → 6. Query [8,9] must prefer the trigram.
        m.train([9, 7, 9, 7])
        m.train([8, 9, 6])
        let b = m.biases(context: [8, 9])
        XCTAssertEqual(Set(b.keys), [6])  // longest match, not the [9]->7 backoff
    }

    func testBacksOffWhenLongContextUnseen() {
        var m = NgramModel(maxOrder: 3, strength: 1.0)
        m.train([9, 7, 9, 7])          // only [9]->7 known
        let b = m.biases(context: [42, 9])  // [42,9] unseen → back off to [9]
        XCTAssertEqual(Set(b.keys), [7])
    }

    /// Hot-path budget: `biases(context:)` runs once per decoded token while NB is on,
    /// so it must stay cheap relative to a ~20–40ms/token forward pass. Train a
    /// realistically-sized model and assert a large batch of lookups is well under a
    /// single token's budget. Generous ceiling — it guards against an accidental
    /// O(vocab) or superlinear regression, not micro-jitter.
    func testBiasesLookupIsCheap() {
        var m = NgramModel(maxOrder: 3, strength: 2.0)
        // ~5k short accepted "sentences" over a 2k-token vocab.
        for s in 0..<5000 {
            let a = s % 2000, b = (s * 7) % 2000, c = (s * 13) % 2000
            m.train([a, b, c, (s * 17) % 2000])
        }
        let ctx = [7, 13]
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10_000 { _ = m.biases(context: ctx) }
        }
        // 10k lookups << one token's decode time; < 50ms total is a safe ceiling.
        XCTAssertLessThan(elapsed, .milliseconds(50), "biases() regressed: \(elapsed)")
    }

    func testStrengthScalesLinearly() {
        var weak = NgramModel(maxOrder: 2, strength: 1.0)
        var strong = NgramModel(maxOrder: 2, strength: 3.0)
        let seq = [1, 2, 1, 2, 1, 3]
        weak.train(seq); strong.train(seq)
        let bw = weak.biases(context: [1])[2]!
        let bs = strong.biases(context: [1])[2]!
        XCTAssertEqual(bs, bw * 3, accuracy: 1e-5)
    }
}
