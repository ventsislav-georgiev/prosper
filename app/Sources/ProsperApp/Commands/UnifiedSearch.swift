import Foundation

/// One ranked result in the universal launcher list. The launcher no longer
/// runs apps / quicklinks / bookmarks as an exclusive priority chain (first
/// non-empty source wins) — that let a stray fuzzy app match shadow an exact
/// bookmark, so "pods" and "pods)" returned different things. Instead every
/// source is scored on ONE ladder (`SearchScore`) and merged, Alfred-style.
struct SearchHit: Sendable, Equatable {
    enum Kind: Int, Sendable, Equatable {
        // Lower rawValue wins an exact score tie → apps feel primary in a launcher.
        // Extension commands rank last on a tie so a real app/link/bookmark target
        // isn't shadowed by a same-scored command, but an exact name match (score
        // 900) still floats a command to the top of its own results.
        case app = 0, quicklink = 1, bookmark = 2, command = 3
    }
    let kind: Kind
    let title: String
    let subtitle: String
    let score: Int
    var appURL: URL? = nil          // app rows: Enter launches
    var openTarget: String? = nil   // quicklink/bookmark rows: Enter opens the target
    var quicklink: QuicklinkHit? = nil // backing link for edit/delete on quicklink rows
    // Extension-command rows (kind == .command): how Enter activates the command.
    var commandID: String? = nil       // the command to invoke / lock into
    var commandIcon: String? = nil     // SF Symbol for the row
    var commandLaunchesWindow: Bool = false // opens its own window on Enter (vs enter mode)
}

/// Pure, source-agnostic relevance scorer. Same ladder for apps, quicklinks and
/// bookmarks so a real match in any source outranks a fuzzy match in another.
///
/// Token semantics: the query is split on whitespace and ALL tokens must appear
/// in the match text (AND), mirroring the bookmarks matcher — so "kubernetes
/// prod" finds a bookmark titled "Prod Kubernetes". Fuzzy subsequence is kept
/// only as the lowest tier and only for a single-token query, so it can never
/// outrank a substring hit.
enum SearchScore {
    /// `q` and `matchText` must be lowercased; `tokens` is `q` split on spaces.
    /// `tieLen` is the DISPLAY length used for the tie-break (shorter = closer),
    /// kept separate from `matchText` so a bookmark scored over its long
    /// title+url+folder haystack still tie-breaks on its title length.
    /// Returns nil when nothing matches.
    static func score(q: String, tokens: [String], matchText: String,
                      tieLen: Int, isAlias: Bool = false) -> Int? {
        if isAlias { return 1000 }
        guard !tokens.isEmpty else { return nil }
        // Tie-break penalty stays strictly within one 100-pt tier so a real
        // substring hit on a long title can never sink below a weaker hit on a
        // short one (page titles run 100–200 chars; an unclamped subtract leaks
        // across tiers). Shorter still wins inside a tier.
        let tie = min(max(tieLen, 0), 99)
        for t in tokens where !matchText.contains(t) {
            // Fuzzy subsequence is the lowest tier and only for a single token of
            // ≥2 chars — a 1-char query would make almost everything a subsequence
            // match (sort-the-world on the hot path) for no real signal.
            if tokens.count == 1, t.count >= 2, AppIndex.isSubsequence(t, of: matchText) {
                return 200 - tie
            }
            return nil
        }
        let base: Int
        if matchText == q { base = 900 }
        else if matchText.hasPrefix(q) { base = 800 }
        else if wordPrefix(matchText, q) { base = 700 }
        else if matchText.contains(q) { base = 600 }
        else { base = 500 } // all tokens present but scattered (multi-word query)
        return base - tie
    }

    /// True if any whitespace-separated word of `text` starts with `q`. Scans in
    /// place (no `split` array allocation) since this is called per candidate on
    /// the per-keystroke hot path.
    private static func wordPrefix(_ text: String, _ q: String) -> Bool {
        guard !q.isEmpty else { return false }
        var atWordStart = true
        var i = text.startIndex
        while i < text.endIndex {
            if atWordStart, text[i...].hasPrefix(q) { return true }
            atWordStart = text[i] == " "
            i = text.index(after: i)
        }
        return false
    }

    /// Merge-sort comparator: higher score, then apps before links before
    /// bookmarks on a tie, then shorter title, then alphabetical (stable).
    static func before(_ a: SearchHit, _ b: SearchHit) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        if a.title.count != b.title.count { return a.title.count < b.title.count }
        return a.title < b.title
    }
}
