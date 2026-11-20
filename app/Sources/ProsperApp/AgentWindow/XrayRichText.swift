import SwiftUI

/// #1760: a card snippet's inline Markdown as styled runs, built once when the card's data is parsed (never in a body).
/// Order (clean after parse): transcript tags folded to Markdown or dropped, line-start block marks made compact,
/// Foundation's inline-only parse (entities decoded there), THEN every run cleaned with OutsideText's rule (unseen
/// scalars dropped, combining marks capped across run joins), then the whole cut at `max` characters.
/// Reuse note: AttributedString(markdown:, .inlineOnlyPreservingWhitespace) over TextViewer's MarkdownRenderer, which
/// lays out a whole document into an NSAttributedString for TextKit; a one-line snippet needs neither.
enum XrayRich {
    struct Run: Equatable, Sendable {
        struct Style: OptionSet, Equatable, Sendable {
            let rawValue: UInt8
            static let bold = Style(rawValue: 1), italic = Style(rawValue: 2), code = Style(rawValue: 4)
            static let strike = Style(rawValue: 8), link = Style(rawValue: 16), hit = Style(rawValue: 32)
        }
        var text: String
        var style: Style = []
    }

    /// Rows count the work, not time: one per runs(_:) call. shortcut: unsynchronised (a test counter), atomics if read live.
    nonisolated(unsafe) static var parses = 0
    /// The ones run on the main thread (a cache-hit open must add none).
    nonisolated(unsafe) static var mainParses = 0

    /// Private-use marks around the ref inside a sentence; OutsideText drops private use, so a cleaned part never holds one.
    static let hitOpen: Unicode.Scalar = "\u{E000}", hitClose: Unicode.Scalar = "\u{E001}"

    /// A sentence's parts (each already cleaned at parse) as one parse, the ref's part flagged `hit`.
    static func runs(before: String, hit: String, after: String, max: Int) -> [Run] {
        hit.isEmpty ? runs(before + after, max: max)
            : runs(before + String(hitOpen) + hit + String(hitClose) + after, max: max)
    }

    static func runs(_ text: String, max: Int) -> [Run] {
        parses += 1
        if Thread.isMainThread { mainParses += 1 }
        var raw: [Run] = []
        var inHit = false
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let l = compact(String(line)) else { continue }
            if n > 0, !raw.isEmpty { raw.append(Run(text: "\n")) }   // ours, not outside data
            let opts = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                               interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                               failurePolicy: .returnPartiallyParsedIfPossible)
            let a = (try? AttributedString(markdown: untag(l), options: opts)) ?? AttributedString(l)
            for r in a.runs {
                var st: Run.Style = []
                if let i = r.inlinePresentationIntent {
                    if i.contains(.stronglyEmphasized) { st.insert(.bold) }
                    if i.contains(.emphasized) { st.insert(.italic) }
                    if i.contains(.code) { st.insert(.code) }
                    if i.contains(.strikethrough) { st.insert(.strike) }
                }
                if r.link != nil { st.insert(.link) }
                // split at the hit marks: the ref keeps its highlight whatever Markdown wraps it
                var cur = String.UnicodeScalarView()
                for u in String(a[r.range].characters).unicodeScalars {
                    if u == hitOpen || u == hitClose {
                        raw.append(Run(text: String(cur), style: inHit ? st.union(.hit) : st))
                        cur = String.UnicodeScalarView()
                        inHit = u == hitOpen
                    } else {
                        cur.append(u)
                    }
                }
                raw.append(Run(text: String(cur), style: inHit ? st.union(.hit) : st))
            }
        }
        return clean(raw, max: max)
    }

    /// OutsideText's rule over the produced runs: unseen scalars dropped (the "\n" between lines kept: ours), marks
    /// capped per base across run joins, empty runs gone, equal neighbours merged, then cut at `max` characters.
    static func clean(_ runs: [Run], max: Int) -> [Run] {
        var out: [Run] = [], marks = 0, left = Swift.max(1, max)
        for r in runs {
            var v = String.UnicodeScalarView()
            for u in r.text.unicodeScalars {
                if r.text == "\n" { v.append(u); marks = 0; continue }
                if OutsideText.isUnseen(u) { continue }
                let c = u.properties.generalCategory
                marks = c == .nonspacingMark || c == .enclosingMark ? marks + 1 : 0
                if marks <= OutsideText.maxMarks { v.append(u) }
            }
            var t = String(v)
            guard !t.isEmpty, left > 0 else { continue }
            if t.count > left { t = String(t.prefix(Swift.max(0, left - 1))) + "\u{2026}" }
            left -= t.count
            if let last = out.last, last.style == r.style, t != "\n", last.text != "\n" {
                out[out.count - 1].text += t
            } else {
                out.append(Run(text: t, style: r.style))
            }
        }
        while out.last?.text == "\n" { out.removeLast() }
        return out
    }

    /// One line of a block made compact: a fence line gone (nil), a heading's or quote's marks dropped, a list
    /// marker a bullet. The rest of the line stays for the inline parse.
    static func compact(_ line: String) -> String? {
        let t = line.drop { $0 == " " }
        if t.hasPrefix("```") || t.hasPrefix("~~~") { return nil }
        if let h = t.firstIndex(where: { $0 != "#" }), h != t.startIndex, t.distance(from: t.startIndex, to: h) <= 6, t[h] == " " {
            return String(t[t.index(after: h)...])
        }
        for q in ["> ", "- ", "* ", "+ "] where t.hasPrefix(q) {
            return (q == "> " ? "" : "\u{2022} ") + t.dropFirst(2)
        }
        return String(line)
    }

    /// Transcript HTML-ish tags (<summary>, <details>, <b>, ...) outside backtick code: an inline style's tag becomes
    /// its Markdown mark, any other tag goes. A "<" that does not open a tag stays a "<".
    static func untag(_ s: String) -> String {
        let marks: [String: String] = ["b": "**", "strong": "**", "i": "*", "em": "*", "code": "`", "s": "~~",
                                       "del": "~~", "strike": "~~", "br": " "]
        var out = "", code = false, i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "`" { code.toggle() }
            if c == "<", !code, let close = s[i...].prefix(64).firstIndex(of: ">") {
                let inner = s[s.index(after: i)..<close]
                let name = inner.drop { $0 == "/" }.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                if let f = name.first, f.isLetter,
                   inner.dropFirst(inner.hasPrefix("/") ? 1 : 0).dropFirst(name.count).first.map({ $0 == " " || $0 == "/" }) ?? true {
                    out += marks[name.lowercased()] ?? ""
                    i = s.index(after: close)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    /// The runs' text, lowercased once, for the card's filter (no parse per keystroke).
    static func fold(_ runs: [Run]) -> String { runs.map(\.text).joined().lowercased() }

    /// The runs drawn at `size`: bold, italic, code in the mono face on a faint chip, links blue and underlined (never
    /// opened: outside data), strikethrough, the ref semibold blue, and each case-insensitive `match` of the filter on
    /// a highlight (with bold, not by colour alone).
    @MainActor static func attributed(_ runs: [Run], size: CGFloat, match: String = "") -> AttributedString {
        var out = AttributedString()
        for r in runs {
            var parts: [(Substring, Bool)] = []
            var from = r.text.startIndex
            while !match.isEmpty, from < r.text.endIndex,
                  let m = r.text.range(of: match, options: .caseInsensitive, range: from..<r.text.endIndex), !m.isEmpty {
                parts += [(r.text[from..<m.lowerBound], false), (r.text[m], true)]
                from = m.upperBound
            }
            parts.append((r.text[from...], false))
            for (t, hit) in parts where !t.isEmpty {
                var a = AttributedString(String(t))
                let bold = r.style.contains(.bold) || r.style.contains(.hit) || hit
                var f = r.style.contains(.code) ? Neon.font(size * 0.92, weight: bold ? .semibold : .regular, design: .monospaced)
                    : Neon.font(size, weight: bold ? .semibold : .regular)
                if r.style.contains(.italic) { f = f.italic() }
                a.font = f
                a.foregroundColor = r.style.contains(.hit) || r.style.contains(.link) ? Neon.blue : Neon.textPrimary
                if r.style.contains(.code) { a.backgroundColor = Neon.textSecondary.opacity(0.14) }
                if hit { a.backgroundColor = Neon.blue.opacity(0.24) }
                if r.style.contains(.strike) { a.strikethroughStyle = .single }
                if r.style.contains(.link) { a.underlineStyle = .single }
                out += a
            }
        }
        return out
    }
}
