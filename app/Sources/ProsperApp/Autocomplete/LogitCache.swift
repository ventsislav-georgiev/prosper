// UNUSED by default: part of the MLX inline fallback path — the llama.cpp
// engine (LlamaInlineEngine, default-on) does not use this. Kept compiling
// for the inlineEngineLlama=false / PROSPER_INLINE_ENGINE=mlx escape hatch.
import Foundation

/// B5 (SC) — a bounded LRU cache of next-token logit distributions keyed by the exact
/// token sequence that produced them, so a repeated context can skip a forward pass
/// (the reference app's `SC_Entry.normalizedLogits`). The reference implementation stores Float16; Swift's array
/// story for Float16 is uneven, so this keeps `[Float]` — the halved memory is a
/// live-tuning refinement, not a correctness point.
///
/// The cache primitive is complete and tested. Realizing the actual forward-pass
/// SKIP needs a custom decode loop that consults this BEFORE the model eval (a
/// `TokenIterator` fork), which is deferred — the `LogitProcessor` seam only sees
/// logits AFTER the forward pass, so it can't save one. Kept ready so that fork, when
/// it lands, has its store.
final class LogitCache {
    private let maxEntries: Int
    private var store: [String: [Float]] = [:]
    private var lru: [String] = [] // oldest first

    init(maxEntries: Int = 512) { self.maxEntries = max(1, maxEntries) }

    private func key(_ tokens: [Int]) -> String { tokens.map(String.init).joined(separator: ",") }

    /// The cached distribution for `tokens`, marking it most-recently-used.
    func get(_ tokens: [Int]) -> [Float]? {
        let k = key(tokens)
        guard let v = store[k] else { return nil }
        if let i = lru.firstIndex(of: k) { lru.remove(at: i); lru.append(k) }
        return v
    }

    /// Cache `logits` for `tokens`, evicting the least-recently-used over capacity.
    func put(_ tokens: [Int], logits: [Float]) {
        let k = key(tokens)
        if store[k] == nil, store.count >= maxEntries, let oldest = lru.first {
            lru.removeFirst()
            store[oldest] = nil
        }
        store[k] = logits
        if let i = lru.firstIndex(of: k) { lru.remove(at: i) }
        lru.append(k)
    }

    var count: Int { store.count }
    func clear() { store.removeAll(); lru.removeAll() }
}
