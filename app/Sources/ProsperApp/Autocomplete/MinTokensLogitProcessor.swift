// UNUSED by default: part of the MLX inline fallback path — the llama.cpp
// engine (LlamaInlineEngine, default-on) does not use this. Kept compiling
// for the inlineEngineLlama=false / PROSPER_INLINE_ENGINE=mlx escape hatch.
import Foundation
import MLX
import MLXLMCommon

/// Bans a token set (EOS / `<end_of_turn>`) for the first `minTokens` decoded
/// tokens. Used on the PREFILL path: with the user's unfinished text seeded into
/// the model turn, a chat-tuned model frequently emits `<end_of_turn>` as the
/// very first token — it reads the prefill as a complete answer — so every
/// ladder rung returns empty. Masking the end tokens for a few steps forces a
/// real continuation head; after `minTokens` the model may stop normally.
/// (the reference app survives the same failure mode through beam alternatives; this is
/// the single-path stopgap until the threshold beam lands — Phase B.)
final class MinTokensLogitProcessor: LogitProcessor {

    private let bannedIds: [Int]
    private let minTokens: Int
    private var produced = 0
    private var bias: MLXArray?

    init(bannedIds: [Int], minTokens: Int) {
        self.bannedIds = bannedIds
        self.minTokens = minTokens
    }

    func prompt(_ prompt: MLXArray) { produced = 0 }
    func didSample(token: MLXArray) { produced += 1 }

    func process(logits: MLXArray) -> MLXArray {
        guard produced < minTokens, !bannedIds.isEmpty else { return logits }
        let vocab = logits.dim(-1)
        // Built lazily once per generation, in the logits dtype so the add does
        // not promote the whole row to Float32 (same as its sibling processors).
        let mask: MLXArray
        if let bias, bias.dim(-1) == vocab {
            mask = bias
        } else {
            var values = [Float](repeating: 0, count: vocab)
            for id in bannedIds where id >= 0 && id < vocab { values[id] = -1e9 }
            mask = MLXArray(values).asType(logits.dtype)
            bias = mask
        }
        return logits + mask
    }
}
