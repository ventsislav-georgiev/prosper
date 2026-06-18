import Foundation

/// SymSpell-style spelling corrector (Symmetric Delete algorithm, Wolf Garbe).
///
/// Why this and not a Trie/edit-distance scan: SymSpell precomputes, for every
/// dictionary word, the set of strings obtained by deleting one character. At
/// query time it only has to delete characters from the *query* and look those
/// up in the precomputed index — no per-word distance scan. For a maxEditDistance
/// of 1 this catches all single-character substitutions, insertions, deletions
/// and adjacent transpositions, which covers the overwhelming majority of real
/// typing slips, in O(query length) lookups.
///
/// It is used as one of several candidate sources for inline completion: when the
/// word fragment under the cursor looks misspelled (e.g. "downlaod"), SymSpell
/// proposes the corrected word ("download") so the LLM can complete sensibly
/// instead of regurgitating the typo. See `CompletionCandidates`.
///
/// The index is built once off the main thread at startup from the bundled
/// frequency dictionary (see `Lexicon`). Tests construct it directly from a small
/// word→frequency map, so it has no dependency on `Bundle.main`.
struct SymSpell {
    /// Maps a delete-variant string → the dictionary words that produce it.
    /// Bounded per key to keep memory predictable on large dictionaries.
    private let deletes: [String: [String]]
    /// word → frequency (higher = more common). Also the membership set.
    private let frequency: [String: Int]
    private let maxEditDistance: Int
    private let maxDictWordLength: Int

    /// Build the symmetric-delete index from a word→frequency map.
    /// - Parameters:
    ///   - frequency: lowercased word → corpus count.
    ///   - maxEditDistance: edit distance to tolerate (only 1 is supported well;
    ///     higher distances are accepted but the delete index stays at distance 1
    ///     so recall degrades — kept simple on purpose).
    ///   - maxPerDelete: cap on words stored per delete key (keeps a hot key like
    ///     "" or single letters from ballooning). Highest-frequency words win.
    init(frequency: [String: Int], maxEditDistance: Int = 1, maxPerDelete: Int = 16) {
        self.frequency = frequency
        self.maxEditDistance = max(1, maxEditDistance)
        self.maxDictWordLength = frequency.keys.map(\.count).max() ?? 0

        // Accumulate delete-variant → words, then trim each bucket to the most
        // frequent `maxPerDelete` entries.
        var acc: [String: [String]] = [:]
        for word in frequency.keys {
            // Skip absurdly long tokens; they add deletes but never match a typed
            // fragment.
            guard word.count <= 24 else { continue }
            for d in Self.deleteVariants(of: word, distance: self.maxEditDistance) {
                acc[d, default: []].append(word)
            }
        }
        if acc.count > 0 {
            for (k, words) in acc where words.count > maxPerDelete {
                acc[k] = Array(words.sorted { (frequency[$0] ?? 0) > (frequency[$1] ?? 0) }
                    .prefix(maxPerDelete))
            }
        }
        self.deletes = acc
    }

    /// Returns corrected words for `term`, most-frequent first, edit distance ≤
    /// `maxEditDistance`. The term itself is included when it is a real word.
    /// Returns at most `limit` suggestions.
    func lookup(_ term: String, limit: Int = 5) -> [String] {
        let term = term.lowercased()
        guard !term.isEmpty, term.count <= maxDictWordLength + maxEditDistance else { return [] }

        var candidates = Set<String>()
        // Distance 0: the term is itself a dictionary word.
        if frequency[term] != nil { candidates.insert(term) }
        // The term equals some word's delete variant (that word has one extra
        // char → a deletion typo by the user).
        if let ws = deletes[term] { candidates.formUnion(ws) }
        // Delete one char from the term and match both real words (the term had an
        // extra char) and other words' delete variants (substitution/transposition).
        for d in Self.deleteVariants(of: term, distance: maxEditDistance) {
            if frequency[d] != nil { candidates.insert(d) }
            if let ws = deletes[d] { candidates.formUnion(ws) }
        }

        return candidates
            .filter { Self.editDistance($0, term) <= maxEditDistance }
            .sorted {
                let fa = frequency[$0] ?? 0, fb = frequency[$1] ?? 0
                return fa != fb ? fa > fb : $0 < $1
            }
            .prefix(limit)
            .map { $0 }
    }

    /// True when `term` is already a known dictionary word (no correction needed).
    func isKnownWord(_ term: String) -> Bool { frequency[term.lowercased()] != nil }

    // MARK: - Internals

    /// All strings obtained by deleting up to `distance` characters from `s`
    /// (distance 1 in practice). Deterministic, deduplicated.
    static func deleteVariants(of s: String, distance: Int) -> Set<String> {
        guard distance > 0, s.count > 1 else { return [] }
        let chars = Array(s)
        var out = Set<String>()
        for i in chars.indices {
            var copy = chars
            copy.remove(at: i)
            out.insert(String(copy))
        }
        if distance > 1 {
            for v in out { out.formUnion(deleteVariants(of: v, distance: distance - 1)) }
        }
        return out
    }

    /// Damerau-Levenshtein (optimal string alignment) distance, in which an
    /// adjacent transposition counts as a single edit — so a slip like
    /// "downlaod" → "download" is distance 1, matching SymSpell's intent. Small
    /// strings; iterative three-row DP.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prevPrev = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    v = min(v, prevPrev[j - 2] + 1) // adjacent transposition
                }
                cur[j] = v
            }
            // rotate rows
            let tmp = prevPrev
            prevPrev = prev
            prev = cur
            cur = tmp
            for k in cur.indices { cur[k] = 0 }
        }
        return prev[b.count]
    }
}
