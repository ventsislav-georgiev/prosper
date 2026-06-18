import AppKit

/// Resolves dynamic placeholders inside a rich-text (RTF) snippet while keeping
/// its formatting, and produces the pasteboard payloads the expander injects.
///
/// Placeholder tokens are replaced in place on the attributed string (so each
/// resolved value inherits the formatting at the token's location). `{cursor}` is
/// stripped and its final caret position reported as an offset counted back from
/// the end of the inserted text.
enum RichSnippet {

    struct Resolved {
        let rtfData: Data
        let plain: String
        /// Number of characters to move the caret left after pasting (0 = leave at
        /// end). Mirrors the plain-text path's `leftArrows`.
        let cursorOffsetFromEnd: Int
    }

    /// The plain-text projection of an RTF document string (its visible text with
    /// placeholder tokens intact). Used to discover `{…}` tokens, which are
    /// brace-escaped in the RTF source itself. Falls back to the raw string when
    /// the body isn't valid RTF (e.g. a snippet toggled "rich" before editing).
    static func plainText(rtf: String) -> String {
        guard let data = rtf.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
        else { return rtf }
        return attributed.string
    }

    /// `rtf` is the stored RTF document (as a String). Returns nil only if the
    /// result can't be re-encoded. A body that isn't valid RTF is treated as plain
    /// text (so a snippet flagged rich but not yet formatted still expands).
    static func resolve(rtf: String, context: PlaceholderContext) -> Resolved? {
        let attributed: NSMutableAttributedString
        if let data = rtf.data(using: .utf8),
           let decoded = try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil) {
            attributed = decoded
        } else {
            attributed = NSMutableAttributedString(
                string: rtf, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        }

        let tokenPattern = try? NSRegularExpression(pattern: "\\{[^{}]*\\}")
        guard let regex = tokenPattern else { return nil }

        let full = attributed.string as NSString
        let matches = regex.matches(in: attributed.string, range: NSRange(location: 0, length: full.length))

        // A unique marker stands in for {cursor}. We process matches right-to-left
        // (so each original range stays valid until used), replacing {cursor} with
        // the marker. As tokens to its LEFT are then resolved — changing the text
        // length before it — the marker travels with the surrounding text, so its
        // FINAL location is correct even when earlier placeholders resize. We then
        // locate and strip it. (Computing the caret from the original index would be
        // wrong whenever a preceding placeholder changes length.)
        let marker = "\u{FFFC}PROSPER-CURSOR-\(UUID().uuidString)\u{FFFC}"
        var hasCursor = false

        for match in matches.reversed() {
            let range = match.range
            let token = full.substring(with: range)
            let inner = token.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces).lowercased()
            // Inherit the formatting at the token's location (clamped to a valid
            // index; empty document → no attributes).
            let attrs: [NSAttributedString.Key: Any]
            if attributed.length > 0 {
                attrs = attributed.attributes(at: min(range.location, attributed.length - 1),
                                              effectiveRange: nil)
            } else {
                attrs = [:]
            }
            if inner == "cursor" {
                // Only the first {cursor} marks the caret; later ones are dropped.
                let replacement = hasCursor ? "" : marker
                hasCursor = true
                attributed.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attrs))
                continue
            }
            let value = PlaceholderEngine.render(token, context).text
            attributed.replaceCharacters(in: range, with: NSAttributedString(string: value, attributes: attrs))
        }

        var cursorOffsetFromEnd = 0
        if hasCursor {
            let resolvedString = attributed.string as NSString
            let markerRange = resolvedString.range(of: marker)
            if markerRange.location != NSNotFound {
                attributed.replaceCharacters(in: markerRange, with: "")
                cursorOffsetFromEnd = max(0, attributed.length - markerRange.location)
            }
        }

        let plain = attributed.string

        guard let rtfData = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else { return nil }

        return Resolved(rtfData: rtfData, plain: plain, cursorOffsetFromEnd: cursorOffsetFromEnd)
    }
}
