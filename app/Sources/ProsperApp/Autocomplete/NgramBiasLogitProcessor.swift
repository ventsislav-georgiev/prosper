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
/// path, and the per-token dense bias build is O(vocab) — acceptable for tuning, and
/// skipped entirely when the context has no biases.
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
        let vocab = logits.dim(-1)
        var delta = [Float](repeating: 0, count: vocab)
        for (tok, v) in biases where tok >= 0 && tok < vocab { delta[tok] = v }
        return logits + MLXArray(delta)
    }

    func didSample(token: MLXArray) {
        context.append(token.item(Int.self))
        if context.count > window { context.removeFirst(context.count - window) }
    }
}
