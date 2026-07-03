import Foundation
import MLX
import MLXLMCommon

/// Decode-time script constraint (B1): masks the logits of every vocabulary token
/// whose text piece is out-of-script for the target, so the model can only emit
/// in-script (or script-neutral / Latin) tokens. This is the guided-decoding
/// mechanism the recovered Cotypist source uses, in its pragmatic Prosper form —
/// see `ScriptClassifier` for the (deliberately coarse) allow rule and its limits.
///
/// Plugged into `MLXLMCommon.TokenIterator` via its
/// `init(input:model:cache:processor:sampler:…)` seam, so no custom decode loop is
/// needed. The mask is a per-(target, vocabSize) `[Float]` (`0` allowed, large
/// negative blocked) built once from the tokenizer and cached process-wide; building
/// it enumerates the whole vocabulary, so it is paid once per script, not per token.
///
/// GATED + LIVE-TUNED: opt-in via `Preferences.guidedScriptDecoding` (default off).
/// It has no effect until enabled, and its *quality* impact can only be judged from
/// live model runs against the corpus — the mask application is correct by
/// construction (an additive bias on the pre-sample logits) but whether it improves
/// perceived completions is a tuning question, not a unit-test one.
final class RequiredScriptLogitProcessor: LogitProcessor {

    private let target: ScriptClassifier.Target
    /// Token-id → text piece. A closure so this file stays agnostic of which
    /// `Tokenizer` protocol the MLX model context vends (two are in scope).
    private let convertIdToToken: (Int) -> String?
    private var bias: MLXArray?

    /// Process-wide cache of the blocked-token bias, keyed by target + vocab size
    /// (different models have different vocabularies). Guarded by a lock because,
    /// although the compute gate serializes evals, the key type is small and the
    /// lock keeps the cache correct if that ever changes.
    private static let cacheLock = NSLock()
    // Guarded by `cacheLock` on every access; the unsafe marker only silences the
    // Swift-6 global-mutable-state diagnostic, the lock provides the actual safety.
    nonisolated(unsafe) private static var cache: [String: MLXArray] = [:]

    init(target: ScriptClassifier.Target, convertIdToToken: @escaping (Int) -> String?) {
        self.target = target
        self.convertIdToToken = convertIdToToken
    }

    func prompt(_ prompt: MLXArray) {}
    func didSample(token: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        guard target != .unconstrained else { return logits }
        let vocab = logits.dim(-1)
        let mask = bias ?? Self.mask(target: target, vocabSize: vocab, convertIdToToken: convertIdToToken)
        bias = mask
        // Additive bias broadcasts [vocab] against the [1, vocab] logits row.
        return logits + mask
    }

    /// Builds (or returns cached) the additive bias for `target` over a `vocabSize`
    /// vocabulary. Enumerates every token id, classifies its piece, and sets a large
    /// negative bias on out-of-script tokens.
    private static func mask(target: ScriptClassifier.Target, vocabSize: Int, convertIdToToken: (Int) -> String?) -> MLXArray {
        let key = "\(target)-\(vocabSize)"
        cacheLock.lock()
        if let cached = cache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        var values = [Float](repeating: 0, count: vocabSize)
        for id in 0..<vocabSize {
            guard let piece = convertIdToToken(id) else { continue }
            if !ScriptClassifier.isAllowed(piece, target: target) {
                values[id] = -1e9
            }
        }
        let array = MLXArray(values)
        cacheLock.lock()
        cache[key] = array
        cacheLock.unlock()
        return array
    }
}
