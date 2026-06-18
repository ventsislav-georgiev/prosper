import Foundation

/// Non-LLM completion candidates derived from the text around the cursor.
///
/// This is the glue that turns the bundled `Lexicon` (prefix completion, bigram
/// next-word, SymSpell typo correction) plus the OS lexicon into a small ranked
/// list of plausible words, which `CoreBridge` injects into the LLM prompt as
/// hints. The LLM always runs — these candidates only steer it.
///
/// Two situations, detected from `before`:
///   * **Mid-word** — `before` ends with a word character ("website d"). There is
///     a `fragment` ("d") under the cursor. Candidates are words that start with
///     the fragment, ranked so that words which *also* commonly follow the
///     preceding word ("website") come first → "download"/"design" beat a generic
///     high-frequency "do".
///   * **At a boundary** — `before` ends with a separator ("website "). There is no
///     fragment; candidates are the words that most often follow the last word
///     (pure bigram next-word prediction).
///
/// Pure and deterministic given its inputs, so it is unit-tested directly with a
/// small hand-built `Lexicon` and no `Bundle.main`.
struct CompletionCandidates {
    /// Partial word under the cursor, lowercased. Empty when at a boundary.
    let fragment: String
    /// Last completed word before the fragment, lowercased. nil if none.
    let headWord: String?
    /// True when `before` ends on a separator (predict the *next* word).
    let atBoundary: Bool
    /// Ranked, deduplicated candidate words (full words, lowercased).
    let words: [String]

    var isEmpty: Bool { words.isEmpty }

    /// Derive candidates from the text surrounding the cursor.
    /// - Parameters:
    ///   - before: text up to the cursor.
    ///   - after: text after the cursor (used only to suppress candidates when the
    ///     word is already finished to the right).
    ///   - lexicon: bundled lexicon (use `Lexicon.empty` when unavailable).
    ///   - osCompletions: prefix completions from the OS lexicon (NSSpellChecker),
    ///     already full words; pass [] when unavailable.
    ///   - limit: max candidates returned.
    static func derive(
        before: String,
        after: String = "",
        lexicon: Lexicon,
        osCompletions: [String] = [],
        limit: Int = 6
    ) -> CompletionCandidates {
        let fragment = trailingWord(before)
        let head = headWord(before, droppingFragment: fragment)
        let atBoundary = fragment.isEmpty

        // If the cursor sits in the middle of an existing word (after-text starts
        // with a word char), there is nothing to complete — bail to avoid gluing.
        let afterStartsMidWord = after.first.map { $0.isLetter || $0.isNumber } ?? false
        if afterStartsMidWord {
            return CompletionCandidates(fragment: fragment, headWord: head, atBoundary: atBoundary, words: [])
        }

        var ranked: [String] = []

        if !atBoundary {
            // Context-aware first: next-words of `head` that start with the fragment.
            if let head, !head.isEmpty {
                let bigramPrefix = lexicon.nextWords(after: head, limit: 16)
                    .filter { $0.hasPrefix(fragment) && $0 != fragment }
                ranked += bigramPrefix
            }
            // OS lexicon completions for the fragment (already full words).
            ranked += osCompletions.map { $0.lowercased() }.filter { $0.hasPrefix(fragment) && $0 != fragment }
            // Frequency-ranked dictionary prefix completions.
            ranked += lexicon.prefixCompletions(fragment, limit: limit + 4)
            // Typo correction: only when the fragment isn't itself a known word and
            // the correction isn't merely a prefix-extension (those are covered above).
            if !lexicon.isKnownWord(fragment) {
                ranked += lexicon.symSpell.lookup(fragment, limit: 3)
                    .filter { !$0.hasPrefix(fragment) }
            }
        } else if let head, !head.isEmpty {
            // Boundary: pure next-word prediction.
            ranked += lexicon.nextWords(after: head, limit: limit + 2)
        }

        let cleaned = dedupe(ranked, excluding: [fragment, head ?? ""], limit: limit)
        return CompletionCandidates(fragment: fragment, headWord: head, atBoundary: atBoundary, words: cleaned)
    }

    // MARK: - Helpers

    /// Trailing run of word characters in `s` (the partial word under the cursor),
    /// lowercased. Empty if `s` ends on a separator or is empty.
    static func trailingWord(_ s: String) -> String {
        var out: [Character] = []
        for ch in s.reversed() {
            if ch.isLetter || ch.isNumber { out.append(ch) } else { break }
        }
        return String(out.reversed()).lowercased()
    }

    /// The last complete word preceding `fragment` in `before`, lowercased.
    static func headWord(_ before: String, droppingFragment fragment: String) -> String? {
        var s = Substring(before)
        if !fragment.isEmpty { s = s.dropLast(fragment.count) }
        // Skip the separators between the head word and the fragment.
        let trimmed = s.reversed().drop { !($0.isLetter || $0.isNumber) }
        var out: [Character] = []
        for ch in trimmed {
            if ch.isLetter || ch.isNumber { out.append(ch) } else { break }
        }
        let head = String(out.reversed()).lowercased()
        return head.isEmpty ? nil : head
    }

    /// Deduplicate preserving order, drop the excluded words and empties, cap.
    static func dedupe(_ words: [String], excluding: [String], limit: Int) -> [String] {
        let block = Set(excluding.filter { !$0.isEmpty })
        var seen = Set<String>()
        var out: [String] = []
        for w in words where !w.isEmpty && !block.contains(w) && !seen.contains(w) {
            seen.insert(w)
            out.append(w)
            if out.count >= limit { break }
        }
        return out
    }
}
