import Foundation
import os.log

/// Bundled English lexicon backing the non-LLM completion-candidate pipeline.
///
/// Three classic, well-understood prediction techniques, no model involved:
///   1. **Prefix completion** — given the partial word under the cursor ("d"),
///      list dictionary words that start with it, ranked by corpus frequency
///      ("download", "design", "down", …). Implemented as binary search over a
///      sorted word array (a Trie's memory cost without the Trie).
///   2. **Bigram next-word** — given the last completed word ("website"), list
///      the words that most often follow it in the corpus ("design", "development",
///      "uses", …). Implemented as a head-word → ranked-next-words map.
///   3. **Typo correction** — `SymSpell` over the same frequency map.
///
/// Crucially, intersecting (1) and (2) is what makes a small LLM produce a *good*
/// completion for "website d": words that both start with "d" *and* commonly
/// follow "website" → "download"/"design". These candidates are fed to the model
/// as hints (see `CompletionCandidates` / `CoreBridge`); the model always runs,
/// the lexicon just steers it away from regurgitation and toward plausible words.
///
/// Data files (bundled under `Contents/Resources/lexicon`, loaded via
/// `Bundle.main` — see scripts/bundle.sh):
///   * `frequency_dictionary_en_82_765.txt`     — "word count" per line.
///   * `frequency_bigramdictionary_en_243_342.txt` — "word1 word2 count" per line.
/// Source: SymSpell's reference dictionaries (MIT).
///
/// The shared instance loads asynchronously off the main thread; until it is
/// ready, `CompletionCandidates` falls back to the OS lexicon only.
final class Lexicon: @unchecked Sendable {
    /// lowercased word → corpus frequency. Also the membership set.
    let frequency: [String: Int]
    /// All known words, lowercased, sorted ascending — for prefix range scans.
    private let sortedWords: [String]
    /// head word → next words, already ordered most-frequent-first (bounded).
    private let bigrams: [String: [String]]
    /// Shared spelling corrector built from `frequency`.
    let symSpell: SymSpell

    private static let log = Logger(subsystem: "com.prosper.app", category: "Lexicon")

    // MARK: Init

    /// Build from in-memory data. Used directly by tests; the bundle loader calls
    /// this after parsing the dictionary files.
    init(frequency: [String: Int], bigrams: [String: [String]]) {
        self.frequency = frequency
        self.sortedWords = frequency.keys.sorted()
        self.bigrams = bigrams
        self.symSpell = SymSpell(frequency: frequency)
    }

    /// Empty lexicon — every query returns nothing. Used as the not-yet-loaded
    /// and bundle-missing fallback so callers never have to nil-check.
    static let empty = Lexicon(frequency: [:], bigrams: [:])

    // MARK: Queries

    /// Dictionary words beginning with `prefix` (case-insensitive), most-frequent
    /// first, capped at `limit`. Words equal to the prefix are excluded — there is
    /// nothing left to complete. Returns [] for an empty prefix.
    func prefixCompletions(_ prefix: String, limit: Int = 8) -> [String] {
        let p = prefix.lowercased()
        guard !p.isEmpty, !sortedWords.isEmpty else { return [] }
        var lo = lowerBound(p)
        var matches: [String] = []
        // Bound the scan: a 1-char prefix can span thousands of words. We only
        // need the top `limit` by frequency, so collect a capped window then sort.
        var scanned = 0
        while lo < sortedWords.count, scanned < 4000 {
            let w = sortedWords[lo]
            guard w.hasPrefix(p) else { break }
            if w != p { matches.append(w) }
            lo += 1; scanned += 1
        }
        return matches
            .sorted {
                let fa = frequency[$0] ?? 0, fb = frequency[$1] ?? 0
                return fa != fb ? fa > fb : $0 < $1
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Words that most commonly follow `head` in the corpus, most-frequent first,
    /// capped at `limit`. Returns [] if `head` is unknown.
    func nextWords(after head: String, limit: Int = 8) -> [String] {
        guard let next = bigrams[head.lowercased()] else { return [] }
        return limit < next.count ? Array(next.prefix(limit)) : next
    }

    func isKnownWord(_ word: String) -> Bool { frequency[word.lowercased()] != nil }

    /// Index of the first word ≥ `p` (standard lower-bound binary search).
    private func lowerBound(_ p: String) -> Int {
        var lo = 0, hi = sortedWords.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedWords[mid] < p { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Bundle loading

    /// Loads the bundled dictionaries asynchronously and installs them as the
    /// shared lexicon. Cheap to call repeatedly; only the first triggers a load.
    static func warmUp() {
        sharedLock.lock(); let already = didStartLoad; didStartLoad = true; sharedLock.unlock()
        guard !already else { return }
        Task.detached(priority: .utility) {
            let start = Date()
            let lex = loadFromBundle()
            store(lex)
            log.info("Lexicon loaded: \(lex.frequency.count) words, \(lex.bigrams.count) bigram heads in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }
    }

    /// The shared lexicon. `.empty` until `warmUp()`'s load finishes.
    static var shared: Lexicon {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return _shared
    }

    /// Sync setter for `_shared`. Kept as a non-async function so `NSLock.lock()`
    /// (unavailable from async contexts) can be used from the detached loader.
    private static func store(_ lex: Lexicon) {
        sharedLock.lock(); _shared = lex; sharedLock.unlock()
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var _shared: Lexicon = .empty
    nonisolated(unsafe) private static var didStartLoad = false

    /// Parse the bundled dictionary files into a `Lexicon`. Returns `.empty` if the
    /// files are missing (app then degrades to OS-lexicon candidates only).
    static func loadFromBundle(maxNextPerHead: Int = 8) -> Lexicon {
        guard let unigramURL = Bundle.main.url(
            forResource: "frequency_dictionary_en_82_765", withExtension: "txt", subdirectory: "lexicon")
        else {
            log.warning("Bundled unigram dictionary not found; completion candidates limited to OS lexicon.")
            return .empty
        }

        var frequency: [String: Int] = [:]
        if let text = try? String(contentsOf: unigramURL, encoding: .utf8) {
            frequency.reserveCapacity(90_000)
            text.enumerateLines { line, _ in
                // "word count"
                guard let sp = line.firstIndex(of: " ") else { return }
                let word = line[..<sp].lowercased()
                let count = Int(line[line.index(after: sp)...].trimmingCharacters(in: .whitespaces)) ?? 0
                guard !word.isEmpty else { return }
                frequency[word] = count
            }
        }

        var bigrams: [String: [(String, Int)]] = [:]
        if let bigramURL = Bundle.main.url(
            forResource: "frequency_bigramdictionary_en_243_342", withExtension: "txt", subdirectory: "lexicon"),
           let text = try? String(contentsOf: bigramURL, encoding: .utf8) {
            text.enumerateLines { line, _ in
                // "word1 word2 count"
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3 else { return }
                let head = parts[0].lowercased()
                let next = String(parts[1]).lowercased()
                let count = Int(parts[2]) ?? 0
                bigrams[head, default: []].append((next, count))
            }
        }
        // Trim each head's next-words to the top `maxNextPerHead` by count.
        var trimmed: [String: [String]] = [:]
        trimmed.reserveCapacity(bigrams.count)
        for (head, pairs) in bigrams {
            trimmed[head] = pairs
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .prefix(maxNextPerHead)
                .map { $0.0 }
        }

        return Lexicon(frequency: frequency, bigrams: trimmed)
    }
}
