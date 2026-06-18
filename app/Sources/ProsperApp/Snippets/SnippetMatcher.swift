import Foundation

/// The outcome of testing the current trigger buffer against the known keywords.
struct SnippetMatchResult: Equatable {
    /// The snippet name (`SnippetHit.id`) whose trigger fired.
    let id: String
    /// Number of trailing characters of the buffer that form the keyword itself
    /// (the count the expander must backspace, excluding any consumed delimiter).
    let keywordLength: Int
    /// True when a trailing delimiter character was also consumed (word-boundary
    /// mode): the expander backspaces `keywordLength + 1`.
    let consumedDelimiter: Bool
}

/// Pure abbreviation matcher. Decides whether the tail of the typed buffer
/// completes a known snippet trigger.
enum SnippetMatcher {

    /// Returns the longest eligible keyword that fired at the end of `buffer`.
    ///
    /// - `keywords`: effective triggers (collection affixes already applied),
    ///   paired with the snippet name.
    /// - `wordBoundaryMode`: when true, a keyword fires only once followed by a
    ///   trailing whitespace delimiter, and only when preceded by a word boundary
    ///   (Alfred bare-keyword style). When false (default), a keyword fires the
    ///   instant the buffer ends with it (Raycast symbol-keyword style).
    static func match(buffer: String,
                      keywords: [(trigger: String, id: String)],
                      wordBoundaryMode: Bool) -> SnippetMatchResult? {
        guard !buffer.isEmpty, !keywords.isEmpty else { return nil }

        if wordBoundaryMode {
            return matchWordBoundary(buffer: buffer, keywords: keywords)
        }
        return matchImmediate(buffer: buffer, keywords: keywords)
    }

    // MARK: - Immediate suffix match (default)

    private static func matchImmediate(buffer: String,
                                       keywords: [(trigger: String, id: String)]) -> SnippetMatchResult? {
        var best: SnippetMatchResult?
        for (trigger, id) in keywords where !trigger.isEmpty && buffer.hasSuffix(trigger) {
            let len = trigger.count
            if best == nil || len > best!.keywordLength {
                best = SnippetMatchResult(id: id, keywordLength: len, consumedDelimiter: false)
            }
        }
        return best
    }

    // MARK: - Word-boundary match

    private static func matchWordBoundary(buffer: String,
                                          keywords: [(trigger: String, id: String)]) -> SnippetMatchResult? {
        // Must end with exactly the delimiter we are about to consume.
        guard let last = buffer.last, isDelimiter(last) else { return nil }
        // Strip the single trailing delimiter; everything before it is the candidate.
        let body = String(buffer.dropLast())
        guard !body.isEmpty else { return nil }

        var best: SnippetMatchResult?
        for (trigger, id) in keywords where !trigger.isEmpty && body.hasSuffix(trigger) {
            // The character before the keyword must be a boundary (or start).
            let beforeIndex = body.index(body.endIndex, offsetBy: -trigger.count)
            let precededByBoundary = beforeIndex == body.startIndex
                || isBoundary(body[body.index(before: beforeIndex)])
            guard precededByBoundary else { continue }
            let len = trigger.count
            if best == nil || len > best!.keywordLength {
                best = SnippetMatchResult(id: id, keywordLength: len, consumedDelimiter: true)
            }
        }
        return best
    }

    private static func isDelimiter(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    /// A boundary is anything that is not a word character (letters/digits/`_`).
    private static func isBoundary(_ c: Character) -> Bool {
        !(c.isLetter || c.isNumber || c == "_")
    }
}
