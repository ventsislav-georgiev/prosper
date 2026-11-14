import AppKit
import SwiftUI

// #1118 (design #1105 D5, rider R5): Foundation's Markdown parser (full syntax) converted once into
// one attributed string for the viewer's TextKit 1 view, off the main thread. A document is
// untrusted input: nothing is fetched or run, raw HTML stays its literal characters, every link goes
// through LinkPolicy and every image through ImagePolicy. One flat pass over the parsed runs: a
// block's nesting is read from its PresentationIntent in a loop, so nothing here recurses by depth.

enum MarkdownRenderer {
    /// The theme, read on the main thread and carried to the render as plain values.
    struct Style: Sendable, Equatable {
        struct RGBA: Sendable, Equatable {
            var r, g, b, a: CGFloat
            var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        }
        var scale: CGFloat
        var text, secondary, accent, card, stroke: RGBA

        @MainActor static var current: Style {
            func rgba(_ c: Color) -> RGBA {
                let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
                return RGBA(r: n.redComponent, g: n.greenComponent, b: n.blueComponent, a: n.alphaComponent)
            }
            return Style(scale: ThemeRuntime.scale, text: rgba(Neon.textPrimary), secondary: rgba(Neon.textSecondary),
                         accent: rgba(Neon.blue), card: rgba(Neon.card), stroke: rgba(Neon.stroke))
        }
    }

    /// What the text view shows. Built on one thread and never mutated after; handed to the main
    /// thread once, hence @unchecked.
    struct Output: @unchecked Sendable {
        let text: NSAttributedString
        /// Heading slug to character index, for "#fragment" links (D6).
        let anchors: [String: Int]
        /// A one-line banner when a Markdown file is shown as its source, or a cap drew some of it as
        /// plain text, and why.
        let note: String?
        let style: Style
    }

    /// D1: a larger Markdown file is shown as source (parsing runs about 0.85 s per MiB).
    static let maxSourceBytes = 1 << 20
    /// R5: the nesting a line's prefix can open (nestingBound); above it the file is shown as source.
    static let maxNesting = 128
    /// Indents and quote bars drawn at most this deep; deeper blocks draw at this depth.
    static let maxShownDepth = 8
    /// Wider tables are drawn as rows of " | "-joined cells, not as an NSTextTable, with the note.
    static let maxTableColumns = 64
    /// Table cells drawn as NSTextTable cells per document; from the row that passes it on, rows are
    /// " | "-joined text. Round 2: TextKit 1 lays tables out on the main thread at about 11 µs a cell.
    static let maxTableCells = 50_000
    /// Links drawn as links per document; later ones are their plain text. #1155: a link costs what any
    /// styled run costs; TextKit 1 lays a paragraph out whole, superlinear in its runs (8,000 links in
    /// one paragraph 0.14 s, 16,000 0.64 s, 32,000 3.8 s, debug build), so the cap is the 8,000 step.
    static let maxLinks = 8_000
    /// Runs with inline styling (emphasis, code, links) per document; later runs take their block's
    /// plain style. Round 2: 524,000 alternating italic runs took 5 s to lay out.
    static let maxStyledRuns = 50_000
    /// #1211: styled runs (and images) in one paragraph, up to its line end; later ones in it take the block's plain
    /// style. TextKit 1 lays a paragraph out whole: 16,000 emphasis runs in one took 0.11 s on main, linear so far; longer
    /// ones were not measured (64 MiB). The longest paragraph in this repository's Markdown has 39.
    static let maxStyledRunsPerParagraph = 10_000
    /// Local images decoded per document; later ones show their alt text.
    static let maxImages = 64
    /// #1187: the parser and the pass below cost 12 to 17 µs per attributed run, linear in the runs, and
    /// 1 MiB holds over 500,000 runs (7.4 s on the Mac measured, 17.6 s on CI). Above this markupCount the
    /// file is shown as source; just under it a render takes about 2.5 s on that Mac. Not lower: 50,000
    /// styled runs (maxStyledRuns) take 100,000 delimiters.
    static let maxMarkup = 150_000
    static let tooLargeNote = "Over 1 MiB: shown as source"
    static let tooDeepNote = "Nested too deeply: shown as source"
    static let tooMuchMarkupNote = "Too much markup: shown as source"
    static let unparsedNote = "Not readable as Markdown: shown as source"
    /// Round 3: the note when a cap drew part of the file as plain text; `kinds` in order, e.g. ["links"].
    nonisolated static func trimmedNote(_ kinds: [String]) -> String { "Too many \(kinds.joined(separator: ", ")): the rest shown as plain text" }

    /// #1236: the longest paragraph the plain render shows, in UTF-16 units. TextKit 1 lays a paragraph out whole on
    /// the main thread at every show (#1180: 1 Mi units 0.17 s and 42 MiB held, linear); past it the text is cut.
    static let maxParagraphUnits = 1 << 20
    /// #1236: the note when the plain render cut the text; `cap` with a comma every three digits in every locale.
    nonisolated static func cutNote(_ cap: Int) -> String {
        let n = cap.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return "The rest of the file is not shown: a line is longer than \(n) characters"
    }

    /// Plain text (D5) and the source fallback: one monospaced run, no parsing. #1236: a text with a paragraph longer
    /// than `maxParagraphUnits` is shown up to that paragraph's cap (paragraphCut) and nothing after, with cutNote
    /// after any note already given; any other text is shown whole, as before.
    nonisolated static func plain(_ text: String, style: Style, note: String? = nil,
                                  maxParagraphUnits cap: Int = maxParagraphUnits) -> Output {
        let font = NSFont.monospacedSystemFont(ofSize: 13 * style.scale, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.text.color]
        guard let cut = paragraphCut(text, cap: cap) else {
            return Output(text: NSAttributedString(string: text, attributes: attrs), anchors: [:], note: note, style: style)
        }
        let shown = NSAttributedString(string: String(text[..<cut]), attributes: attrs)
        return Output(text: shown, anchors: [:], note: [cutNote(cap), note].compactMap { $0 }.joined(separator: " \u{00B7} "), style: style)
    }

    /// #1236: where the shown text ends when a paragraph holds more than `cap` UTF-16 units: in the first such paragraph,
    /// at its cap, moved back to the start of the character that straddles it; nil when there is none. Paragraphs end
    /// where NSString's paragraphRange (and so TextKit 1) ends them: "\n", "\r" (and so "\r\n") and U+2029; U+2028 and
    /// U+0085 end a line, not a paragraph, which is laid out whole with them. One pass over the UTF-16 units, no
    /// allocation; a text of at most `cap` UTF-8 bytes has at most `cap` units and is not scanned.
    nonisolated static func paragraphCut(_ text: String, cap: Int) -> String.Index? {
        let cap = max(cap, 0)
        guard text.utf8.count > cap else { return nil }
        let units = text.utf16
        var run = 0, i = units.startIndex, start = units.startIndex
        while i < units.endIndex {
            switch units[i] {
            case 0x0A, 0x0D, 0x2029:
                run = 0
                start = units.index(after: i)
            default:
                if run == cap { return characterStart(text, at: i, floor: start) }
                run += 1
            }
            units.formIndex(after: &i)
        }
        return nil
    }

    /// The start of the character (grapheme) holding the unit at `i`, looked for at most 256 UTF-16 units back and never
    /// before `floor`, a paragraph start. A longer character (a run of combining marks) is cut at the scalar at `i`: the
    /// walk is over a window of at most 512 units, so it cannot run long on any text.
    private nonisolated static func characterStart(_ text: String, at i: String.Index, floor: String.Index) -> String.Index {
        let units = text.utf16, scalars = text.unicodeScalars, reach = 256
        var at = i
        if at.samePosition(in: scalars) == nil, at > floor { units.formIndex(before: &at) }   // the low half of a pair
        var from = units.index(at, offsetBy: -reach, limitedBy: floor) ?? floor
        if from.samePosition(in: scalars) == nil, from < at { units.formIndex(after: &from) }
        var to = units.index(at, offsetBy: reach, limitedBy: units.endIndex) ?? units.endIndex
        if to.samePosition(in: scalars) == nil, to > at { units.formIndex(before: &to) }
        // The window's graphemes read the scalars after `at` too: a mark after it joins the character before it.
        let limit = units.distance(from: from, to: at)
        var best = 0, offset = 0
        for c in String(scalars[from..<to]) {
            if offset > limit { break }
            best = offset
            offset += c.utf16.count
        }
        if best == 0, from != floor { return at }   // no boundary in reach: a scalar boundary instead
        return flagStart(text, units.index(from, offsetBy: best), floor: floor)
    }

    /// The most indicators counted back from a cut (N1236-b); 2,048 flags.
    static let maxIndicatorRun = 4_096

    /// N1236-b: regional indicators pair into flags by parity from their run's start, which can lie before the window
    /// characterStart reads, so a cut found there can fall between a flag's halves. When the scalar at `cut` is an
    /// indicator, the run before it is counted back (never before `floor`, at most maxIndicatorRun scalars, one checked
    /// step each) and an odd count moves the cut back one indicator. A longer run keeps the cut: a flag may split there.
    private nonisolated static func flagStart(_ text: String, _ cut: String.Index, floor: String.Index) -> String.Index {
        let scalars = text.unicodeScalars
        func isIndicator(_ i: String.Index) -> Bool { (0x1F1E6...0x1F1FF).contains(scalars[i].value) }
        guard cut < scalars.endIndex, cut.samePosition(in: scalars) != nil, isIndicator(cut) else { return cut }
        var back = cut, run = 0
        while back > floor, run <= maxIndicatorRun {
            let prev = scalars.index(before: back)
            guard isIndicator(prev) else { break }
            (back, run) = (prev, run + 1)
        }
        guard run <= maxIndicatorRun, run % 2 == 1 else { return cut }
        return scalars.index(before: cut)
    }

    /// Parses and converts `source`, the Markdown document at `document`. Off the main thread; stops
    /// early when its task is cancelled (a newer load supersedes it).
    nonisolated static func render(_ source: String, document: URL, style: Style, loader: @escaping TextViewerImageLoader) -> Output {
        guard source.utf8.count <= maxSourceBytes else { return plain(source, style: style, note: tooLargeNote) }
        guard nestingBound(source) <= maxNesting else { return plain(source, style: style, note: tooDeepNote) }
        guard markupCount(source) <= maxMarkup else { return plain(source, style: style, note: tooMuchMarkupNote) }
        let options = parsingOptions(for: source)
        // #1222: with positions on, the parser reads the text its columns are counted in (positionSource). #1229: every
        // file's leading BOMs dropped, so two or more draw as one does, with or without positions.
        let text = options.appliesSourcePositionAttributes ? positionSource(source) : withoutLeadingBOMs(source)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return plain(source, style: style, note: unparsedNote)
        }
        // #1213: the parser drops an image inside a link and keeps its alt text as the link text. With source positions
        // on, that run's range is the image's own source, which is parsed alone to recover the image.
        let map = options.appliesSourcePositionAttributes ? SourceMap(text) : nil
        let budget = source.utf8.count
        var sliceParses = 0, sliceBytes = 0
        let c = Converter(style: style, document: document, loader: loader)
        for run in parsed.runs {
            if Task.isCancelled { break }
            var image = run.imageURL, badge = false
            let shown = String(parsed[run.range].characters)
            if let map, run.link != nil, image == nil, let pos = run.markdownSourcePosition,
               let slice = map.slice(line: pos.startLine, column: pos.startColumn, toLine: pos.endLine, column: pos.endColumn),
               slice.starts(with: [UInt8(ascii: "!"), UInt8(ascii: "[")]) {
                badge = true
                // Capped and counted: at most maxImages slice parses, together at most the source's own bytes; past
                // either the form is marked without a parse.
                if sliceParses < maxImages, slice.count <= budget - sliceBytes {
                    sliceParses += 1
                    sliceBytes += slice.count
                    switch linkedImage(String(decoding: slice, as: UTF8.self), shown: shown, options: options) {
                    case .image(let url): image = url
                    case .mark: break
                    case .text: badge = false   // #1222: literal "![" link text: drawn as before #1213
                    }
                }
            }
            c.add(shown, block: run.presentationIntent,
                  inline: run.inlinePresentationIntent ?? [], link: run.link, image: image, badge: badge)
        }
        return c.finish()
    }

    /// The parse options for `source`: the system parser, full syntax. #1213: source positions (about 20% more parse
    /// time) only when the source holds the bytes "[![", where an image inside a link can start; other files parse
    /// exactly as before.
    nonisolated static func parsingOptions(for source: String) -> AttributedString.MarkdownParsingOptions {
        var options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible, languageCode: nil)
        options.appliesSourcePositionAttributes = source.utf8.firstRange(of: "[![".utf8) != nil
        return options
    }

    /// #1222: the text the parser's source positions are counted in. The parser reads a NUL as U+FFFD (three bytes) and
    /// skips a leading BOM yet adds its three bytes to the later lines of the block that started on line 1 (#1222
    /// report); with both written out here its columns are this text's bytes. It draws the same characters either way.
    /// A lazy continuation line still shifts: that form falls back (not a form, or the mark).
    nonisolated static func positionSource(_ s: String) -> String {
        var t = withoutLeadingBOMs(s)
        if t.utf8.contains(0) { t = String(String.UnicodeScalarView(t.unicodeScalars.map { $0 == "\u{0}" ? "\u{FFFD}" : $0 })) }
        return t
    }

    /// #1229: `s` without its leading BOMs (only those before any other character). The parser skips the first itself,
    /// yet a second keeps line 1 from opening a block ("# T" stays a paragraph), a third is drawn, and with positions the later
    /// lines of the first block stay 3 bytes off (#1229 report). No count is kept: drop(while:) stops at the first other scalar or the end.
    nonisolated static func withoutLeadingBOMs(_ s: String) -> String {
        s.unicodeScalars.first == "\u{FEFF}" ? String(s.unicodeScalars.drop(while: { $0 == "\u{FEFF}" })) : s
    }

    /// What a link run's source slice that starts "![" holds, parsed alone.
    enum LinkedImage: Equatable {
        /// Exactly one run, with an image: drawn.
        case image(URL)
        /// An image the outer parse dropped but not exactly one image run (text around it, two images, a reference
        /// whose definition is elsewhere), or a slice the parser refuses: "[image: text]".
        case mark
        /// #1222: no image, and the slice reads as the run's own text: the link text is literally "![...": drawn as before.
        case text
    }

    /// #1213: the image of an image inside a link, from its source slice parsed alone. `shown` is the outer run's text: a
    /// reference image reads differently alone ("![x]" against the outer "x"), so only literal text is `.text`.
    nonisolated static func linkedImage(_ slice: String, shown: String, options: AttributedString.MarkdownParsingOptions) -> LinkedImage {
        guard let parsed = try? AttributedString(markdown: slice, options: options) else { return .mark }
        var runs = parsed.runs.makeIterator()
        if let first = runs.next(), runs.next() == nil, let url = first.imageURL { return .image(url) }
        if !parsed.runs.contains(where: { $0.imageURL != nil }), String(parsed.characters) == shown { return .text }
        return .mark
    }

    /// #1213: the source's UTF-8 bytes and where each line starts, to turn a parser's source position (1-based line and
    /// byte column, end inclusive) into bytes. A line ends at "\n", "\r\n" or a lone "\r", as the parser's lines do.
    /// Positions are checked against the table: one that does not fit is no slice.
    struct SourceMap {
        let bytes: [UInt8]
        let starts: [Int]

        init(_ source: String) {
            bytes = Array(source.utf8)
            var starts = [0]
            var i = 0
            while i < bytes.count {
                let b = bytes[i]
                i += 1
                if b == 0x0A || (b == 0x0D && (i == bytes.count || bytes[i] != 0x0A)) { starts.append(i) }
            }
            self.starts = starts
        }

        /// The bytes from (line, column) to (toLine, column) inclusive, or nil when either does not lie on its line.
        func slice(line: Int, column: Int, toLine: Int, column endColumn: Int) -> ArraySlice<UInt8>? {
            guard let a = offset(line, column), let b = offset(toLine, endColumn), a <= b else { return nil }
            return bytes[a...b]
        }

        private func offset(_ line: Int, _ column: Int) -> Int? {
            guard line >= 1, line <= starts.count, column >= 1 else { return nil }
            let start = starts[line - 1]
            let end = line < starts.count ? starts[line] : bytes.count
            guard column <= end - start else { return nil }   // so start + column - 1 < end <= bytes.count
            return start + column - 1
        }
    }

    /// An upper bound on the container nesting any line can reach: every block quote or list level
    /// open on a line costs a marker in its prefix or at least two columns of indent (the one space a
    /// ">" consumes, and the space or tab after a list marker, are part of the marker). Lazy lines
    /// only continue what an earlier line opened. #1163: indent only continues containers an earlier
    /// line opened, so it counts at most the bound so far (a blank or code line of spaces opens
    /// nothing); markers count in full. One pass over the bytes, no parse.
    nonisolated static func nestingBound(_ s: String) -> Int {
        enum State { case prefix, quote, bullet, digits, delimiter, text }
        var bound = 0, markers = 0, columns = 0
        var state = State.prefix
        for b in s.utf8 {
            if b == 0x0A || b == 0x0D {
                if state == .bullet || state == .delimiter { markers += 1 }
                bound = max(bound, markers + min(columns / 2, bound))
                (markers, columns, state) = (0, 0, .prefix)
                continue
            }
            switch state {
            case .text: continue
            case .quote:
                state = .prefix
                if b == 0x20 { continue }
                fallthrough
            case .prefix:
                switch b {
                case 0x20: columns += 1
                case 0x09: columns += 4
                case UInt8(ascii: ">"): markers += 1; state = .quote
                case UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "+"): state = .bullet
                case UInt8(ascii: "0")...UInt8(ascii: "9"): state = .digits
                default: state = .text
                }
            case .bullet, .delimiter:
                guard b == 0x20 || b == 0x09 else { state = .text; continue }
                markers += 1
                state = .prefix
            case .digits:
                if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { continue }
                state = b == UInt8(ascii: ".") || b == UInt8(ascii: ")") ? .delimiter : .text
            }
        }
        if state == .bullet || state == .delimiter { markers += 1 }
        return max(bound, markers + min(columns / 2, bound))
    }

    /// #1187: the attributed runs a parse can make, estimated without parsing: two for each line with
    /// text (its text and the break after it), one for each emphasis, strikethrough, code or link
    /// delimiter, two for a "<" (a tag or autolink, and the text after it), and one for each table pipe
    /// between two cells (a line's first and last pipe open no cell). Quote and list markers open a block,
    /// counted with its line. #1211 (F1187-1), #1213: a bare autolink (a link run and the text after it) counts two:
    /// two for each ":" followed by "/" (a scheme's "://"), two for a "." after a "w" or "W" and two for the first "." after an
    /// "@" in one word, each "." only when a non-blank byte follows it. Other dots and colons ("a.b", "1.2.3", "x:y")
    /// count nothing: the parser links none of them. F1213-1: two for each "&" followed by "#" or an ASCII letter (an
    /// entity can spell an e-mail's "@" or "." and the parser still links it); "& ", "&&", "&=" count nothing. At least the
    /// parser's run count on every shape measured (#1213 probe). One pass over the bytes.
    nonisolated static func markupCount(_ s: String) -> Int {
        var n = 0, text = false, pipe = false, dot = false, at = false
        var prev: UInt8 = 0x20
        for b in s.utf8 {
            defer { prev = b }
            switch b {
            case 0x0A, 0x0D: (text, pipe, dot, at) = (false, false, false, false)   // a pipe that ends its line opens no cell
            case 0x20, 0x09: (dot, at) = (false, false)
            default:
                if !text {
                    (n, text) = (n + 2, true)
                    if b == UInt8(ascii: "|") { continue }   // nor does one that starts it
                }
                if pipe { (n, pipe) = (n + 1, false) }
                if dot { (n, dot) = (n + 2, false) }
                switch b {
                case UInt8(ascii: "|"): pipe = true
                case UInt8(ascii: "@"): at = true
                case UInt8(ascii: "."):
                    if prev == UInt8(ascii: "w") || prev == UInt8(ascii: "W") { dot = true } else if at { (dot, at) = (true, false) }
                case UInt8(ascii: "/"): if prev == UInt8(ascii: ":") { n += 2 }
                case UInt8(ascii: "<"): n += 2
                case UInt8(ascii: "#"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
                    if prev == UInt8(ascii: "&") { n += 2 }   // F1213-1: an entity
                case UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "`"),
                     UInt8(ascii: "["), UInt8(ascii: "]"): n += 1
                default: break
                }
            }
        }
        return n
    }

    /// GitHub's heading anchor: lowercased, spaces to hyphens, other punctuation dropped.
    nonisolated static func slug(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in s.lowercased().unicodeScalars {
            if c == " " { out.append("-") } else if c == "-" || c == "_" || CharacterSet.alphanumerics.contains(c) { out.append(c) }
        }
        return String(out)
    }
}

/// One render's state. Used on the one thread that renders.
private final class Converter {
    typealias R = MarkdownRenderer
    let style: R.Style
    let document: URL
    let loader: TextViewerImageLoader
    let out = NSMutableAttributedString()
    let body: NSFont
    let mono: NSFont
    let scale: CGFloat
    let unit: CGFloat
    let maxPixelSize: Int

    var blockID: Int?
    var lineStart = true
    var lastAttrs: [NSAttributedString.Key: Any] = [:]
    var para = NSParagraphStyle()
    var cont = NSParagraphStyle()   // the same block after a hard break: no marker indent
    var blockFont: NSFont
    var blockColor: NSColor
    var openItems: Set<Int> = []   // the list items of the last block
    var lastWideRow: [Int]?
    var quoteBlocks: [Int: NSTextBlock] = [:]
    var codeBlocks: [Int: NSTextBlock] = [:]
    var tables: [Int: NSTextTable] = [:]
    var tableCells = 0, lastRow = -1
    var heading: (start: Int, text: String)?
    var anchors: [String: Int] = [:]
    var slugCounts: [String: Int] = [:]
    var images = 0
    var links = 0, styledRuns = 0
    var paragraphRuns = 0   // styled runs since the last line end (emit resets it)
    var fonts: [FontKey: NSFont] = [:]   // a run's font per block font and the inline bits that change it
    var trimmed: [String] = []   // the caps that drew something as plain text, in first-hit order

    init(style: R.Style, document: URL, loader: @escaping TextViewerImageLoader) {
        self.style = style
        self.document = document
        self.loader = loader
        let s = style.scale.isFinite && style.scale > 0 ? style.scale : 1
        let font = NSFont.systemFont(ofSize: 15 * s)
        scale = s
        body = font
        mono = NSFont.monospacedSystemFont(ofSize: 13 * s, weight: .regular)
        unit = 22 * s
        blockFont = font
        blockColor = style.text.color
        // The thumbnail's long side: the column at a 2x backing.
        maxPixelSize = Int(min(16384, TextViewerTextView.columnWidth * s * 2))
    }

    /// `badge` (#1213): the run is an image inside a link, `link` is the outer link and `image` its image if the slice
    /// parse found one; with no image it is marked "[image: text]". Past a cap that drops the link it is plain text.
    /// #1222: a link whose text is literally "![..." with no image never gets the badge.
    func add(_ text: String, block: PresentationIntent?, inline: InlinePresentationIntent, link: URL?, image: URL?,
             badge: Bool = false) {
        var text = text
        var inline = inline
        var link = link
        var image = image
        var badge = badge
        if !inline.subtracting([.lineBreak, .softBreak]).isEmpty || link != nil {
            styledRuns += 1
            if styledRuns > R.maxStyledRuns {
                trim("styles")
                inline = inline.intersection([.lineBreak, .softBreak])
                link = nil
                if badge { (image, badge) = (nil, false) }
            }
        }
        let id = block?.components.first?.identity ?? -1   // raw HTML blocks carry no intent
        if id != blockID { text = start(block?.components ?? [], id: id, text: text) }
        // #1211: counted after start(), whose "\n" between blocks ends the last paragraph; a wide row's " | " does not
        if !inline.subtracting([.lineBreak, .softBreak]).isEmpty || link != nil || image != nil {
            paragraphRuns += 1
            if paragraphRuns > R.maxStyledRunsPerParagraph {
                trim("styles in one paragraph")
                (inline, link, image, badge) = (inline.intersection([.lineBreak, .softBreak]), nil, nil, false)   // an image shows its alt text
            }
        }
        if heading != nil { heading?.text += text }
        if image != nil || badge { return addImage(alt: text, src: image, link: link) }
        let attrs = attributes(inline, link: link)
        if inline.contains(.lineBreak) {   // a hard break: a newline, the rest of the block without the marker indent
            emit("\n", attrs)
            para = cont
            return
        }
        emit(text, attrs)
    }

    func finish() -> R.Output {
        finishHeading()
        return R.Output(text: out, anchors: anchors, note: trimmed.isEmpty ? nil : R.trimmedNote(trimmed), style: style)
    }

    func trim(_ kind: String) { if !trimmed.contains(kind) { trimmed.append(kind) } }

    /// A new block: end the previous paragraph, then read the nesting from the intent (outermost
    /// first) into a paragraph style. Returns the block's first text (a task item loses its "[ ] ").
    private func start(_ comps: [PresentationIntent.IntentType], id: Int, text: String) -> String {
        finishHeading()
        var quotes = 0, lists = 0, level = 0
        var ordered = false, code = false, rule = false, headerRow = false
        var items: [(id: Int, ordinal: Int, ordered: Bool, depth: Int)] = []   // outermost first
        var table: (id: Int, columns: [PresentationIntent.TableColumn])?
        var row = -1, rowID = -1, column = -1
        var blocks: [NSTextBlock] = []
        for c in comps.reversed() {
            switch c.kind {
            case .blockQuote:
                quotes += 1
                if quotes <= R.maxShownDepth { blocks.append(quoteBlock(c.identity)) }
            case .orderedList: lists += 1; ordered = true
            case .unorderedList: lists += 1; ordered = false
            case .listItem(let ordinal): items.append((c.identity, ordinal, ordered, min(lists, R.maxShownDepth)))
            case .header(let l): level = l
            case .codeBlock: code = true; blocks.append(codeBlock(c.identity))
            case .thematicBreak: rule = true
            case .table(let columns): table = (c.identity, columns)
            case .tableHeaderRow: (row, rowID, headerRow) = (0, c.identity, true)
            case .tableRow(let r): (row, rowID) = (r, c.identity)
            case .tableCell(let col): column = col
            default: break
            }
        }
        // A wide table's cells of one row share a line.
        var wideRow: [Int]?
        if let table, column >= 0, rowID != lastRow {   // a row's cells count once, at its first cell
            lastRow = rowID
            if table.columns.count <= R.maxTableColumns { tableCells += table.columns.count } else { trim("table columns") }
            if tableCells > R.maxTableCells { trim("table cells") }
        }
        if let table, column >= 0, table.columns.count > R.maxTableColumns || tableCells > R.maxTableCells {
            wideRow = [table.id, rowID]
        }
        if blockID != nil, !lineStart { emit(wideRow != nil && wideRow == lastWideRow ? " | " : "\n", lastAttrs) }
        blockID = id
        lastWideRow = wideRow

        let ps = NSMutableParagraphStyle()
        let depth = min(lists, R.maxShownDepth)
        let indent = CGFloat(depth) * unit
        ps.headIndent = indent
        ps.firstLineHeadIndent = indent
        ps.tabStops = [NSTextTab(textAlignment: .left, location: indent, options: [:])]
        ps.paragraphSpacing = code || column >= 0 ? 0 : (items.isEmpty ? 8 : 3) * scale
        ps.paragraphSpacingBefore = level > 0 ? 8 * scale : 0
        var font = body
        let headingSizes: [CGFloat] = [20, 18, 16]   // MarkdownBlocksView's; 15 below level 3
        if level > 0 { font = NSFont.systemFont(ofSize: headingSizes[safe: level - 1, or: 15] * scale, weight: .bold) }
        if code || id == -1 { font = mono }
        if headerRow { font = NSFont.boldSystemFont(ofSize: body.pointSize) }
        if let table, column >= 0, wideRow == nil, table.columns.indices.contains(column), row >= 0 {
            blocks.append(cell(table: table.id, columns: table.columns.count, row: row, column: column, header: headerRow))
            ps.alignment = switch table.columns[column].alignment {
            case .center: .center
            case .right: .right
            default: .left
            }
        }
        if rule { blocks.append(ruleBlock()) }
        ps.textBlocks = blocks
        blockFont = font
        blockColor = quotes > 0 ? style.secondary.color : style.text.color

        var text = rule ? "\u{00A0}" : text   // a rule is drawn by its block's border, not the "⸻" glyph
        var marker: String?
        // #1163: every item this block opens gets its marker ("1. - x" opens two), outermost first, each at
        // its own depth. The new ones are the innermost: an item open on the last block keeps its parents.
        let fresh = items.filter { !openItems.contains($0.id) }
        // N1163-m: every block inside an item carries the item (raw HTML too: testEveryBlockInsideAnItemCarriesTheItem),
        // so a block with no items has left every list and the next item is fresh either way.
        openItems = Set(items.map(\.id))
        if let first = fresh.first {
            var marks = fresh.map { $0.ordered ? "\($0.ordinal)." : ["•", "◦", "▪"][max(0, $0.depth - 1) % 3] }
            if text.hasPrefix("[ ] ") { marks[marks.count - 1] = "☐"; text.removeFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marks[marks.count - 1] = "☑"; text.removeFirst(4) }
            var m = "", prev = 0
            for (f, mark) in zip(fresh, marks) { m += (m.isEmpty ? "" : f.depth == prev ? " " : "\t") + mark; prev = f.depth }   // past the shown depth they share a stop
            marker = m
            ps.firstLineHeadIndent = CGFloat(max(0, first.depth - 1)) * unit
            ps.tabStops = stride(from: first.depth, through: depth, by: 1).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * unit, options: [:]) }
        }
        para = ps.copy() as! NSParagraphStyle
        let c = ps.mutableCopy() as! NSMutableParagraphStyle
        c.firstLineHeadIndent = indent
        cont = c
        if let marker {
            emit(marker + "\t", [.font: body, .foregroundColor: style.secondary.color, .paragraphStyle: para])
        }
        if level > 0 { heading = (out.length, "") }
        return text
    }

    /// #1211: deriving a run's font cost 30% of a render of emphasis runs (8 us a run); it depends only on these.
    struct FontKey: Hashable { let font: NSFont, inline: InlinePresentationIntent.RawValue }

    private func runFont(_ inline: InlinePresentationIntent) -> NSFont {
        let key = FontKey(font: blockFont, inline: inline.intersection([.code, .inlineHTML, .blockHTML, .stronglyEmphasized, .emphasized]).rawValue)
        if let f = fonts[key] { return f }
        var font = blockFont
        if inline.contains(.code) || inline.contains(.inlineHTML) || inline.contains(.blockHTML), font != mono {
            font = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
        }
        var traits = font.fontDescriptor.symbolicTraits
        if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if inline.contains(.emphasized) { traits.insert(.italic) }
        if traits != font.fontDescriptor.symbolicTraits {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        }
        fonts[key] = font
        return font
    }

    private func attributes(_ inline: InlinePresentationIntent, link: URL?) -> [NSAttributedString.Key: Any] {
        let font = runFont(inline)
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: blockColor, .paragraphStyle: para]
        if inline.contains(.strikethrough) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if inline.contains(.code) { a[.backgroundColor] = style.card.color }
        if let link {
            let action = LinkPolicy.action(link, document: document)
            if action != .none, links >= R.maxLinks { trim("links") }
            if action != .none, links < R.maxLinks {   // anything else stays plain text: no link attribute at all (D6)
                links += 1
                a[.link] = link
                let tip: String = switch action {   // D6: the full target, before any click
                case .open(let u): u.absoluteString
                case .view(let u), .reveal(let u): u.path
                case .scroll(let s): "#" + s
                case .none: ""
                }
                a[.toolTip] = tip
                a[.foregroundColor] = style.accent.color
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        return a
    }

    /// D7: a local image through the loader (inside the tree, capped); anything else, or a refusal,
    /// shows "[image: alt]", and a remote one keeps its link (D6) without ever being loaded. #1213: `link` is the
    /// outer link of an image inside a link, kept on the picture or on the mark instead of the image's own; no `src`
    /// is a form whose image was not recovered: the mark only.
    private func addImage(alt: String, src: URL?, link: URL? = nil) {
        let local = src.map(ImagePolicy.isLocal) ?? false
        if let src, local, images < R.maxImages {
            images += 1
            if let cg = loader(src, document, maxPixelSize) {
                var size = NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
                let column = TextViewerTextView.columnWidth * scale
                if size.width > column { size = NSSize(width: column, height: size.height * column / size.width) }
                let attachment = NSTextAttachment()
                attachment.image = NSImage(cgImage: cg, size: size)
                attachment.bounds = CGRect(origin: .zero, size: size)
                let s = NSMutableAttributedString(attachment: attachment)
                s.addAttributes([.paragraphStyle: para, .toolTip: alt], range: NSRange(location: 0, length: s.length))
                if let link {   // through LinkPolicy and maxLinks like any link; its tooltip is the target (D6)
                    let a = attributes([], link: link)
                    if let l = a[.link], let tip = a[.toolTip] {
                        s.addAttributes([.link: l, .toolTip: tip], range: NSRange(location: 0, length: s.length))
                    }
                }
                out.append(s)
                lineStart = false
                return
            }
        }
        var a = attributes([], link: link ?? (local ? nil : src))
        a[.foregroundColor] = style.secondary.color
        emit("[image: \(alt)]", a)
    }

    private func emit(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
        guard let last = text.last else { return }
        out.append(NSAttributedString(string: text, attributes: attrs))
        lineStart = last == "\n"
        if lineStart { paragraphRuns = 0 }
        lastAttrs = attrs
    }

    private func finishHeading() {
        guard let h = heading else { return }
        heading = nil
        let base = R.slug(h.text)
        let seen = slugCounts[base, default: 0]   // at most one per heading of a source capped at 1 MiB
        slugCounts[base] = seen + 1
        let slug = seen == 0 ? base : "\(base)-\(seen)"
        if anchors[slug] == nil { anchors[slug] = h.start }
    }

    private func quoteBlock(_ id: Int) -> NSTextBlock {
        if let b = quoteBlocks[id] { return b }
        let b = NSTextBlock()
        b.setWidth(3 * scale, type: .absoluteValueType, for: .border, edge: .minX)
        b.setBorderColor(style.accent.color.withAlphaComponent(0.5), for: .minX)
        b.setWidth(10 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
        quoteBlocks[id] = b
        return b
    }

    private func codeBlock(_ id: Int) -> NSTextBlock {
        if let b = codeBlocks[id] { return b }
        let b = NSTextBlock()
        b.backgroundColor = style.card.color
        b.setWidth(8 * scale, type: .absoluteValueType, for: .padding)
        b.setWidth(6 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        codeBlocks[id] = b
        return b
    }

    private func cell(table id: Int, columns: Int, row: Int, column: Int, header: Bool) -> NSTextTableBlock {
        let table: NSTextTable
        if let t = tables[id] { table = t } else {
            table = NSTextTable()
            table.numberOfColumns = columns
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setWidth(6 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
            tables[id] = table
        }
        let b = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        b.setWidth(1, type: .absoluteValueType, for: .border)
        b.setBorderColor(style.stroke.color)
        b.setWidth(5 * scale, type: .absoluteValueType, for: .padding)
        if header { b.backgroundColor = style.card.color }
        return b
    }

    private func ruleBlock() -> NSTextBlock {
        let b = NSTextBlock()
        b.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        b.setBorderColor(style.stroke.color, for: .maxY)
        b.setWidth(6 * scale, type: .absoluteValueType, for: .margin, edge: .minY)
        b.setWidth(6 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        return b
    }
}

private extension Array {
    subscript(safe i: Int, or fallback: Element) -> Element { indices.contains(i) ? self[i] : fallback }
}
