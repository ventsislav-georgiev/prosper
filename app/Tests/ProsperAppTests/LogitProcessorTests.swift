import MLX
import XCTest

@testable import ProsperApp

/// B1/B2/B5 decode-seam processors (17ff980, 5e3f90e, 1c52143). These pin the
/// MLXArray paths the pure-logic tests (NgramModelTests, ScriptClassifierTests)
/// can't reach: the sparse indexed add, the scalar logprob math, the vocab mask,
/// and the composite's ordering contract.
final class LogitProcessorTests: XCTestCase {

    // MARK: - NgramBiasLogitProcessor (B5)

    func testNgramBiasAddsSparseDeltaOnlyAtBiasedToken() {
        var m = NgramModel(maxOrder: 2, strength: 2.0)
        m.train([1, 3])
        let expected = m.biases(context: [1])
        XCTAssertNotNil(expected[3])

        let proc = NgramBiasLogitProcessor(model: m, promptTail: [0, 1])
        let out = proc.process(logits: MLX.zeros([1, 8]))
        XCTAssertEqual(out.dim(-1), 8)
        XCTAssertEqual(out[0, 3].item(Float.self), expected[3]!, accuracy: 1e-4)
        for i in [0, 1, 2, 4, 5, 6, 7] {
            XCTAssertEqual(out[0, i].item(Float.self), 0, accuracy: 1e-6, "token \(i) touched")
        }
    }

    func testNgramBiasNoOpWhenContextHasNoBiases() {
        var m = NgramModel(maxOrder: 2, strength: 2.0)
        m.train([1, 3])
        // didSample rolls the context window off the trained context.
        let proc = NgramBiasLogitProcessor(model: m, promptTail: [1])
        proc.didSample(token: MLXArray(Int32(5)))
        let out = proc.process(logits: MLX.zeros([1, 8]))
        for i in 0..<8 {
            XCTAssertEqual(out[0, i].item(Float.self), 0, accuracy: 1e-6)
        }
    }

    // MARK: - LogprobRecorder (B2)

    func testAverageLogprobIsLogitsMinusLogSumExp() {
        let rec = LogprobRecorder()
        let row: [Float] = [1, 2, 3, 4]
        _ = rec.process(logits: MLXArray(row).reshaped([1, 4]))
        rec.didSample(token: MLXArray(Int32(2)))

        let lse = log(row.reduce(Float(0)) { $0 + exp($1) })
        XCTAssertEqual(rec.averageLogprob, row[2] - lse, accuracy: 1e-3)
    }

    func testAverageLogprobAveragesAcrossTokensAndStartsAtFloor() {
        let rec = LogprobRecorder()
        XCTAssertEqual(rec.averageLogprob, -Float.greatestFiniteMagnitude)

        // Uniform row: every token's logprob is -log(4).
        let uniform = MLXArray([Float](repeating: 0, count: 4)).reshaped([1, 4])
        for id in [0, 3] {
            _ = rec.process(logits: uniform)
            rec.didSample(token: MLXArray(Int32(id)))
        }
        XCTAssertEqual(rec.averageLogprob, -log(Float(4)), accuracy: 1e-3)
    }

    // MARK: - CompositeLogitProcessor ordering

    /// The recorder is composed AFTER the bias stages (MLXEngine wiring), so it
    /// must score the post-constraint distribution — including in-place sparse
    /// writes made by an earlier stage on the same logits row.
    func testCompositeRecorderScoresPostBiasDistribution() {
        var m = NgramModel(maxOrder: 2, strength: 5.0)
        m.train([1, 3])
        let bias = m.biases(context: [1])[3]!

        let rec = LogprobRecorder()
        let composite = CompositeLogitProcessor(
            NgramBiasLogitProcessor(model: m, promptTail: [1]), rec)
        _ = composite.process(logits: MLX.zeros([1, 4]))
        composite.didSample(token: MLXArray(Int32(3)))

        // Post-bias row is [0, 0, 0, bias] reordered → logprob(3) = bias - lse.
        let lse = log(3 * exp(Float(0)) + exp(bias))
        XCTAssertEqual(rec.averageLogprob, bias - lse, accuracy: 1e-3)
    }

    // MARK: - RequiredScriptLogitProcessor (B1)

    func testCyrillicTargetBlocksOnlyForeignScriptLetters() {
        // Vocab size 5 keys the process-wide mask cache uniquely for this test.
        let pieces: [Int: String] = [
            0: "hello",  // Latin — always allowed (loanwords)
            1: "мир",    // Cyrillic — allowed
            2: " .!",    // neutral — allowed
            3: "▁на",    // SentencePiece marker + Cyrillic — allowed
            4: "क",      // Devanagari — blocked
        ]
        let proc = RequiredScriptLogitProcessor(target: .cyrillic) { pieces[$0] }
        let out = proc.process(logits: MLX.zeros([1, 5]))
        for i in 0...3 {
            XCTAssertEqual(out[0, i].item(Float.self), 0, accuracy: 1e-6, "piece \(i) blocked")
        }
        XCTAssertLessThan(out[0, 4].item(Float.self), -1e8)
    }

    func testLatinTargetBlocksCyrillic() {
        // Vocab size 6 → distinct cache key from the test above.
        let pieces: [Int: String] = [
            0: "hello", 1: "мир", 2: "123", 3: "world", 4: "к", 5: "?",
        ]
        let proc = RequiredScriptLogitProcessor(target: .latin) { pieces[$0] }
        let out = proc.process(logits: MLX.zeros([1, 6]))
        XCTAssertLessThan(out[0, 1].item(Float.self), -1e8)
        XCTAssertLessThan(out[0, 4].item(Float.self), -1e8)
        for i in [0, 2, 3, 5] {
            XCTAssertEqual(out[0, i].item(Float.self), 0, accuracy: 1e-6)
        }
    }
}
