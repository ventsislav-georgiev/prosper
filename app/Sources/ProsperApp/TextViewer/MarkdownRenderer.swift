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
    /// Wider tables are drawn as rows of " | "-joined cells, not as an NSTextTable.
    static let maxTableColumns = 64
    /// Table cells drawn as NSTextTable cells per document; from the row that passes it on, rows are
    /// " | "-joined text. Round 2: TextKit 1 lays tables out on the main thread at about 11 µs a cell.
    static let maxTableCells = 50_000
    /// Links drawn as links per document; later ones are their plain text. Round 2: 150,000 rendered
    /// links did not lay out in 120 s (8,000 bare links take 0.04 s), and TextKit 1 lays out on main.
    static let maxLinks = 2_000
    /// Runs with inline styling (emphasis, code, links) per document; later runs take their block's
    /// plain style. Round 2: 524,000 alternating italic runs took 5 s to lay out.
    static let maxStyledRuns = 50_000
    /// Local images decoded per document; later ones show their alt text.
    static let maxImages = 64
    static let tooLargeNote = "Over 1 MiB: shown as source"
    static let tooDeepNote = "Nested too deeply: shown as source"
    static let unparsedNote = "Not readable as Markdown: shown as source"
    /// Round 3: the note when a cap drew part of the file as plain text; `kinds` in order, e.g. ["links"].
    nonisolated static func trimmedNote(_ kinds: [String]) -> String { "Too many \(kinds.joined(separator: ", ")): the rest shown as plain text" }

    /// Plain text (D5) and the source fallback: one monospaced run, no parsing.
    nonisolated static func plain(_ text: String, style: Style, note: String? = nil) -> Output {
        let font = NSFont.monospacedSystemFont(ofSize: 13 * style.scale, weight: .regular)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: style.text.color])
        return Output(text: s, anchors: [:], note: note, style: style)
    }

    /// Parses and converts `source`, the Markdown document at `document`. Off the main thread; stops
    /// early when its task is cancelled (a newer load supersedes it).
    nonisolated static func render(_ source: String, document: URL, style: Style, loader: @escaping TextViewerImageLoader) -> Output {
        guard source.utf8.count <= maxSourceBytes else { return plain(source, style: style, note: tooLargeNote) }
        guard nestingBound(source) <= maxNesting else { return plain(source, style: style, note: tooDeepNote) }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible, languageCode: nil)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return plain(source, style: style, note: unparsedNote)
        }
        let c = Converter(style: style, document: document, loader: loader)
        for run in parsed.runs {
            if Task.isCancelled { break }
            c.add(String(parsed[run.range].characters), block: run.presentationIntent,
                  inline: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL)
        }
        return c.finish()
    }

    /// An upper bound on the container nesting any line can reach: every block quote or list level
    /// open on a line costs a marker in its prefix or at least two columns of indent (the one space a
    /// ">" consumes, and the space or tab after a list marker, are part of the marker). Lazy lines
    /// only continue what an earlier line opened. One pass over the bytes, no parse.
    nonisolated static func nestingBound(_ s: String) -> Int {
        enum State { case prefix, quote, bullet, digits, delimiter, text }
        var bound = 0, markers = 0, columns = 0
        var state = State.prefix
        for b in s.utf8 {
            if b == 0x0A || b == 0x0D {
                if state == .bullet || state == .delimiter { markers += 1 }
                bound = max(bound, markers + columns / 2)
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
        return max(bound, markers + columns / 2)
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
    var lastItem: Int?
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

    func add(_ text: String, block: PresentationIntent?, inline: InlinePresentationIntent, link: URL?, image: URL?) {
        var text = text
        var inline = inline
        var link = link
        if !inline.subtracting([.lineBreak, .softBreak]).isEmpty || link != nil {
            styledRuns += 1
            if styledRuns > R.maxStyledRuns {
                trim("styles")
                inline = inline.intersection([.lineBreak, .softBreak])
                link = nil
            }
        }
        let id = block?.components.first?.identity ?? -1   // raw HTML blocks carry no intent
        if id != blockID { text = start(block?.components ?? [], id: id, text: text) }
        if heading != nil { heading?.text += text }
        if let image { return addImage(alt: text, src: image) }
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
        var item: (id: Int, ordinal: Int, ordered: Bool)?
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
            case .listItem(let ordinal): item = (c.identity, ordinal, ordered)
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
            if table.columns.count <= R.maxTableColumns { tableCells += table.columns.count }
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
        ps.paragraphSpacing = code || column >= 0 ? 0 : (item != nil ? 3 : 8) * scale
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
        if let item, item.id != lastItem {
            lastItem = item.id
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marker = "☑"; text.removeFirst(4) }
            else { marker = item.ordered ? "\(item.ordinal)." : ["•", "◦", "▪"][max(0, depth - 1) % 3] }
            ps.firstLineHeadIndent = max(0, indent - unit)
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

    private func attributes(_ inline: InlinePresentationIntent, link: URL?) -> [NSAttributedString.Key: Any] {
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
    /// shows "[image: alt]", and a remote one keeps its link (D6) without ever being loaded.
    private func addImage(alt: String, src: URL) {
        let local = ImagePolicy.isLocal(src)
        if local, images < R.maxImages {
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
                out.append(s)
                lineStart = false
                return
            }
        }
        var a = attributes([], link: local ? nil : src)
        a[.foregroundColor] = style.secondary.color
        emit("[image: \(alt)]", a)
    }

    private func emit(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
        guard let last = text.last else { return }
        out.append(NSAttributedString(string: text, attributes: attrs))
        lineStart = last == "\n"
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
