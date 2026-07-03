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
