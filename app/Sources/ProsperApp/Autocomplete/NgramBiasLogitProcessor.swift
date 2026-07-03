import Foundation
import MLX
import MLXLMCommon

/// B5 (NB) — applies an `NgramModel`'s next-token biases to the decoder's logits via
/// the `TokenIterator` `LogitProcessor` seam. Unlike SC (which would need to skip the
/// forward pass and so is deferred), a logit bias fits the seam exactly: it nudges the
/// post-eval logits before sampling.
///
/// It tracks the rolling generation context (`prompt` seeds it from the prompt tail,
/// `didSample` appends), queries `model.biases(context:)`, and adds those sparse
/// deltas to the matching logit positions. Gated + experimental: only on the opt-in
/// path; the per-token cost is O(k) in the biased-token count (sparse indexed add),
/// and skipped entirely when the context has no biases.
///
/// `@unchecked Sendable`: created on the `MLXEngine` actor, used only inside one
/// serialized `container.perform` decode loop.
final class NgramBiasLogitProcessor: LogitProcessor, @unchecked Sendable {

    private let model: NgramModel
    private var context: [Int]
    private let window: Int

    init(model: NgramModel, promptTail: [Int]) {
        self.model = model
        self.window = max(1, model.maxOrder - 1)
        self.context = Array(promptTail.suffix(window))
    }

    func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        let biases = model.biases(context: context)
        guard !biases.isEmpty else { return logits }
        // Sparse indexed add — only the biased token positions are touched (O(k)),
        // never a vocab-wide (256k for Gemma) host allocation + copy per token. Same
        // gather/scatter-write idiom mlx-swift-lm uses for repetition/presence
        // penalties (Evaluate.swift). `logits` is the `[1, vocab]` last-position row.
        let vocab = logits.dim(-1)
        var idx: [Int32] = []
        var val: [Float] = []
        idx.reserveCapacity(biases.count)
        val.reserveCapacity(biases.count)
        for (tok, v) in biases where tok >= 0 && tok < vocab {
            idx.append(Int32(tok)); val.append(v)
        }
        guard !idx.isEmpty else { return logits }
        let indices = MLXArray(idx)
        // Match the logits dtype (Float16/BFloat16 on device) so the assignment back
        // into the slice doesn't fight a Float32 RHS.
        let deltas = MLXArray(val).asType(logits.dtype)
        logits[0..., indices] = logits[0..., indices] + deltas
        return logits
    }

    func didSample(token: MLXArray) {
        context.append(token.item(Int.self))
        if context.count > window { context.removeFirst(context.count - window) }
    }
}
