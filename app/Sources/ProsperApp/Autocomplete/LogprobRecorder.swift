import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Records the average per-token log-probability of a decode (B2 n-best ranking).
/// Plugs into `TokenIterator` as a `LogitProcessor`: it snapshots `logSoftmax` of the
/// logits it is shown, then on `didSample` looks up the chosen token's logprob and
/// accumulates. `averageLogprob` is the mean over the generated tokens — the score
/// used to rank competing candidates (higher = more model-preferred).
///
/// Per-token `.item()` forces a GPU sync, so this is only used on the opt-in n-best
/// path, never the default single-candidate decode.
///
/// `@unchecked Sendable`: it is created on the `MLXEngine` actor, handed into a single
/// `container.perform` closure, mutated only inside that closure's serialized decode
/// loop, and read back after the closure returns — never touched concurrently.
final class LogprobRecorder: LogitProcessor, @unchecked Sendable {
    private var sumLogprob: Float = 0
    private var count = 0
    private var lastLogprobs: MLXArray?

    func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        lastLogprobs = logSoftmax(logits, axis: -1)
        return logits
    }

    func didSample(token: MLXArray) {
        guard let lp = lastLogprobs else { return }
        let id = token.item(Int.self)
        // lp is [1, vocab]; gather the sampled token's logprob.
        sumLogprob += lp[0, id].item(Float.self)
        count += 1
    }

    var averageLogprob: Float {
        count > 0 ? sumLogprob / Float(count) : -Float.greatestFiniteMagnitude
    }
}

/// Chains two `LogitProcessor`s (mask first, then record) so a guided n-best decode
/// can both constrain script AND score candidates. `process` composes; the lifecycle
/// hooks fan out to both.
final class CompositeLogitProcessor: LogitProcessor {
    private var first: LogitProcessor
    private var second: LogitProcessor

    init(_ first: LogitProcessor, _ second: LogitProcessor) {
        self.first = first
        self.second = second
    }

    func prompt(_ prompt: MLXArray) {
        first.prompt(prompt)
        second.prompt(prompt)
    }

    func process(logits: MLXArray) -> MLXArray {
        second.process(logits: first.process(logits: logits))
    }

    func didSample(token: MLXArray) {
        first.didSample(token: token)
        second.didSample(token: token)
    }
}
