import Foundation

/// B5 (NB) — a small back-off n-gram model over token ids, trained in the background
/// from the user's accepted text. It biases the decoder's logits toward the tokens
/// the user actually tends to type next in a given short context.
///
/// This is the "right" personalization the plan calls for: a logit *bias* over the
/// existing vocabulary, not few-shot prompt text. Prosper cut prompt personalization
/// because writing-samples leaked verbatim vocabulary into unrelated completions; an
/// n-gram bias can only nudge probabilities of tokens the model already considers, so
/// it cannot inject a stale phrase the way prompt few-shot did.
///
/// Pure and deterministic: `train` ingests token-id sequences, `biases(context:)`
/// returns a sparse `{tokenId: logitDelta}` map for the current context using the
/// longest matching suffix (back-off), scaled by `strength`. Constants
/// (`maxOrder`, `strength`) are unrecovered from Cotypist and meant to be tuned live.
struct NgramModel: Equatable {

    /// Highest context order kept (a 3-gram model looks at up to the last 2 tokens).
    let maxOrder: Int
    /// Logit-delta scale applied to the normalized next-token log-probabilities.
    let strength: Float

    /// context-key ("t1,t2") → (nextTokenId → count).
    private var counts: [String: [Int: Int]] = [:]

    init(maxOrder: Int = 3, strength: Float = 2.0) {
        self.maxOrder = max(1, maxOrder)
        self.strength = strength
    }

    private static func key(_ ctx: ArraySlice<Int>) -> String {
        ctx.map(String.init).joined(separator: ",")
    }

    /// Ingest one token-id sequence, tallying every order-1…maxOrder context → next.
    mutating func train(_ tokens: [Int]) {
        guard tokens.count >= 2 else { return }
        for i in 1..<tokens.count {
            let next = tokens[i]
            let maxCtx = min(maxOrder - 1, i)
            for order in 1...max(1, maxCtx) where order <= i {
                let ctx = tokens[(i - order)..<i]
                counts[Self.key(ctx), default: [:]][next, default: 0] += 1
            }
        }
    }

    /// Sparse logit biases for the current `context` (recent token ids), using the
    /// LONGEST matching suffix that has counts (back-off). Empty when unseen. Each
    /// bias = `strength * log(count / total)` — a smooth nudge, never a hard force.
    func biases(context: [Int]) -> [Int: Float] {
        guard !context.isEmpty else { return [:] }
        let hi = min(maxOrder - 1, context.count)
        guard hi >= 1 else { return [:] }
        // Longest suffix first (most specific), back off to shorter.
        for order in stride(from: hi, through: 1, by: -1) {
            let ctx = context.suffix(order)[...]
            guard let dist = counts[Self.key(ctx)], !dist.isEmpty else { continue }
            let total = Float(dist.values.reduce(0, +))
            var out: [Int: Float] = [:]
            for (tok, c) in dist {
                out[tok] = strength * log(Float(c) / total)
            }
            return out
        }
        return [:]
    }

    var isEmpty: Bool { counts.isEmpty }
}
