import AppKit
import Darwin
import XCTest
@testable import ProsperApp

/// #1118 (design #1105 D5, section 3 N1 to N4, rider R5): the Markdown renderer. Recorders only:
/// the image loader is a fake that records each request; nothing is read, fetched or opened.
final class MarkdownRendererTests: XCTestCase {

    typealias R = MarkdownRenderer
    static let style = R.Style(scale: 1, text: .init(r: 0, g: 0, b: 0, a: 1), secondary: .init(r: 0.5, g: 0.5, b: 0.5, a: 1),
                               accent: .init(r: 0, g: 0, b: 1, a: 1), card: .init(r: 0.9, g: 0.9, b: 0.9, a: 1),
                               stroke: .init(r: 0.8, g: 0.8, b: 0.8, a: 1))
    static let document = URL(fileURLWithPath: "/Users/example/docs/README.md")

    /// Every construct of the design's table 1.2 (the fixture is a literal: see report T2).
    static let everyConstruct = #"""
    # Title

    ## Second

    ### Third

    Plain *italic* **bold** ~~gone~~ `inline` text.
    Line one\
    line two

    - one
      - two
        - three

    3. third
    4. fourth

    - [ ] todo
    - [x] done

    > quote
    > > nested

    ```swift
    let x = 1
    ```

    | Lft | Ctr | Rgt |
    |:----|:---:|----:|
    | aa1 | bb2 | cc3 |

    ---

    <script>alert(1)</script>

    Inline <b>html</b> here.

    [web](https://example.com) [doc](other.md) [js](javascript:alert(1)) [frag](#title) [mail](mailto:a@example.com) [smb](smb://h/s)

    ![local](pic.png) ![remote](https://example.com/r.png)
    """#

    /// Records each image request; draws nothing (returns nil) unless `image` is set.
    final class Loader: @unchecked Sendable {
        let lock = NSLock()
        private var seen: [String] = []
        private var pixels: [Int] = []
        var image: CGImage?
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
        /// The maxPixelSize each request was handed (R886-3).
        var sizes: [Int] { lock.lock(); defer { lock.unlock() }; return pixels }
        var load: TextViewerImageLoader {
            { [self] src, _, size in lock.lock(); seen.append(src.absoluteString); pixels.append(size); lock.unlock(); return image }
        }
    }

    private func render(_ md: String, _ loader: Loader = Loader()) -> R.Output {
        R.render(md, document: Self.document, style: Self.style, loader: loader.load)
    }

    private func at(_ out: R.Output, _ word: String, file: StaticString = #filePath, line: UInt = #line) -> [NSAttributedString.Key: Any] {
        let r = (out.text.string as NSString).range(of: word)
        guard r.location != NSNotFound else { XCTFail("no \(word) in \(out.text.string)", file: file, line: line); return [:] }
        return out.text.attributes(at: r.location, effectiveRange: nil)
    }

    private func para(_ out: R.Output, _ word: String) -> NSParagraphStyle? { at(out, word)[.paragraphStyle] as? NSParagraphStyle }

    /// Whether the character at `index` is drawn in an NSTextTable cell (false outside the text).
    private func inTable(_ out: R.Output, at index: Int) -> Bool {
        guard index >= 0, index < out.text.length else { return false }
        let ps = out.text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        return ps?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true
    }
    private func font(_ out: R.Output, _ word: String) -> NSFont? { at(out, word)[.font] as? NSFont }

    /// The parser's shapes this renderer relies on (report T3, T4), pinned so an OS update that
    /// changes them shows here first.
    func testParserFacts() throws {
        let opts = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                           failurePolicy: .returnPartiallyParsedIfPossible, languageCode: nil)
        let two = try AttributedString(markdown: "a\n\nb", options: opts)
        XCTAssertEqual(String(two.characters), "ab", "T3: no newline between blocks")
        let big = try AttributedString(markdown: "9223372036854775807. x", options: opts)
        XCTAssertFalse(big.runs.contains { run in
            run.presentationIntent?.components.contains { if case .orderedList = $0.kind { true } else { false } } == true
        }, "T4: a 19-digit start is no list")
        let task = try AttributedString(markdown: "- [ ] t", options: opts)
        XCTAssertEqual(String(task.characters), "[ ] t", "a task item is literal text")
        let html = try AttributedString(markdown: "<script>x</script>", options: opts)
        XCTAssertEqual(String(html.characters), "<script>x</script>\n")
        XCTAssertTrue(html.runs.allSatisfy { $0.presentationIntent == nil }, "a raw HTML block has no block intent")
        let inline = try AttributedString(markdown: "<i>x</i>", options: opts)
        XCTAssertEqual(String(inline.characters), "<i>x</i>", "a tag with text after it on its line is inline HTML")
        // #1163 R886-5 (left.txt): an image inside a link is dropped: one run, its alt text with the link
        // and no image. If an OS update starts keeping the image, this fails and the renderer can draw it.
        let linked = try AttributedString(markdown: "[![alt](p.png)](https://example.com/)", options: opts)
        XCTAssertEqual(linked.runs.count, 1)
        XCTAssertEqual(String(linked.characters), "alt")
        XCTAssertEqual(linked.runs.first?.link, URL(string: "https://example.com/"))
        XCTAssertTrue(linked.runs.first?.imageURL == nil, "the image inside a link is dropped by the parser")
        // #1213: with source positions on, that run's range (1-based line and UTF-8 byte column, end inclusive) is the
        // image's own source; a non-ASCII byte before it moves the columns by its bytes, not its characters.
        var pos = opts
        pos.appliesSourcePositionAttributes = true
        let badge = try AttributedString(markdown: "[![alt](p.png)](#top)", options: pos)
        XCTAssertEqual(badge.runs.count, 1)
        XCTAssertTrue(badge.runs.first?.imageURL == nil)
        let p = try XCTUnwrap(badge.runs.first?.markdownSourcePosition)
        XCTAssertEqual([p.startLine, p.startColumn, p.endLine, p.endColumn], [1, 2, 1, 14], "\"![alt](p.png)\"")
        let wide = try AttributedString(markdown: "\u{E9} [![a](p.png)](#top)", options: pos)
        let w = try XCTUnwrap(wide.runs.first { $0.link != nil }?.markdownSourcePosition)
        XCTAssertEqual([w.startLine, w.startColumn, w.endLine, w.endColumn], [1, 5, 1, 15], "byte columns")
    }

    func testEveryConstruct() throws {
        let loader = Loader()
        let out = render(Self.everyConstruct, loader)
        let s = out.text.string
        XCTAssertNil(out.note)
        XCTAssertTrue(s.hasPrefix("Title\nSecond\nThird\n"), s)
        XCTAssertEqual(font(out, "Title")?.pointSize, 20)
        XCTAssertEqual(font(out, "Second")?.pointSize, 18)
        XCTAssertEqual(font(out, "Third")?.pointSize, 16)
        XCTAssertTrue(font(out, "Title")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertEqual(font(out, "Plain")?.pointSize, 15)
        XCTAssertTrue(font(out, "italic")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        XCTAssertTrue(font(out, "bold")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertNotNil(at(out, "gone")[.strikethroughStyle])
        XCTAssertTrue(font(out, "inline")?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertNotNil(at(out, "inline")[.backgroundColor])
        XCTAssertTrue(s.contains("Line one\nline two"), "a hard break is a newline")
        // Nested lists: a marker per depth, the indent grows with it.
        XCTAssertTrue(s.contains("•\tone\n◦\ttwo\n▪\tthree\n"), s)
        let indents = ["\tone", "\ttwo", "\tthree"].map { para(out, $0)?.headIndent ?? -1 }
        XCTAssertEqual(indents, [22, 44, 66])
        XCTAssertTrue(s.contains("3.\tthird\n4.\tfourth\n"), "an ordered list keeps its start")
        XCTAssertTrue(s.contains("☐\ttodo\n☑\tdone\n"))
        // Quotes: one block per level.
        XCTAssertEqual(para(out, "quote")?.textBlocks.count, 1)
        XCTAssertEqual(para(out, "nested")?.textBlocks.count, 2)
        // Code: monospaced in its own block.
        XCTAssertTrue(font(out, "let x")?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertEqual(para(out, "let x")?.textBlocks.count, 1)
        // The table: one NSTextTable of 3 columns, aligned left, center, right; the header is row 0.
        let cells = ["Lft", "Ctr", "Rgt", "aa1", "bb2", "cc3"].map { para(out, $0)?.textBlocks.last as? NSTextTableBlock }
        XCTAssertEqual(cells.compactMap { $0 }.count, 6)
        XCTAssertEqual(Set(cells.compactMap { $0.map { ObjectIdentifier($0.table) } }).count, 1)
        XCTAssertEqual(cells.first??.table.numberOfColumns, 3)
        XCTAssertEqual(cells.map { $0?.startingRow ?? -1 }, [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(cells.map { $0?.startingColumn ?? -1 }, [0, 1, 2, 0, 1, 2])
        XCTAssertEqual(["aa1", "bb2", "cc3"].map { para(out, $0)?.alignment }, [.left, .center, .right])
        // The rule: a no-break space whose block draws the line.
        XCTAssertEqual(para(out, "\u{00A0}")?.textBlocks.count, 1)
        XCTAssertFalse(s.contains("⸻"))
        // N4: raw HTML is its literal characters.
        XCTAssertTrue(s.contains("<script>alert(1)</script>"))
        XCTAssertTrue(s.contains("Inline <b>html</b> here."))
        XCTAssertTrue(font(out, "<script>")?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        // Anchors for "#fragment" links.
        XCTAssertEqual(out.anchors["title"], 0)
        XCTAssertEqual(out.anchors["second"], 6)
        XCTAssertEqual(out.anchors["third"], 13)
        // D7: only the local image reaches the loader; the remote one is its alt text.
        XCTAssertEqual(loader.requests, ["pic.png"])
        XCTAssertTrue(s.contains("[image: local]"), "the fake loader drew nothing")
        XCTAssertTrue(s.contains("[image: remote]"))
    }

    /// D6, N3: every link attribute in the output is one the policy acts on, with its full target
    /// as a tooltip; every other link is plain text.
    func testEveryLinkPassesPolicy() throws {
        let out = render(Self.everyConstruct)
        var links: [String: String] = [:]
        out.text.enumerateAttribute(.link, in: NSRange(location: 0, length: out.text.length)) { value, range, _ in
            guard let value else { return }
            let url = value as? URL
            XCTAssertNotNil(url, "\(value)")
            if let url { XCTAssertNotEqual(LinkPolicy.action(url, document: Self.document), .none, url.absoluteString) }
            let tip = out.text.attribute(.toolTip, at: range.location, effectiveRange: nil) as? String
            links[(out.text.string as NSString).substring(with: range)] = tip
        }
        XCTAssertEqual(links, ["web": "https://example.com", "doc": "/Users/example/docs/other.md", "frag": "#title",
                               "mail": "mailto:a@example.com", "[image: remote]": "https://example.com/r.png"])
        XCTAssertTrue(out.text.string.contains("web doc js frag mail smb"), "refused links stay as their text")
    }

    /// N1, N2: a remote image is never requested, by any spelling; local ones are.
    func testRemoteImageNeverLoaded() {
        let loader = Loader()
        let md = "![a](https://example.com/a.png) ![b](//example.com/b.png) ![c](file://example.com/c.png) "
            + "![d](data:image/png;base64,AAAA) ![e](HTTP://example.com/e.png) ![f](local.png) ![g](file:///Users/example/docs/g.png)"
        let out = render(md, loader)
        XCTAssertEqual(loader.requests, ["local.png", "file:///Users/example/docs/g.png"])
        for alt in ["a", "b", "c", "d", "e"] { XCTAssertTrue(out.text.string.contains("[image: \(alt)]"), alt) }
    }

    /// A drawn image becomes an attachment no wider than the column.
    func testLocalImageIsAnAttachment() throws {
        let loader = Loader()
        let png = try pngData(width: 4000, height: 100)
        loader.image = ImagePolicy.decode(png, maxPixelSize: 4000)
        let out = render("![wide](wide.png)", loader)
        let att = try XCTUnwrap(out.text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertLessThanOrEqual(att.bounds.width, TextViewerTextView.columnWidth + 0.5)
        XCTAssertEqual(out.text.attribute(.toolTip, at: 0, effectiveRange: nil) as? String, "wide")
    }

    func testRawHTMLIsLiteralText() {
        let md = "<img src=\"https://example.com/x.png\">\n\n<a href=\"javascript:alert(1)\">x</a> <iframe src=\"https://example.com\"></iframe>\n"
        let out = render(md)
        XCTAssertTrue(out.text.string.contains("<img src=\"https://example.com/x.png\">"))
        XCTAssertTrue(out.text.string.contains("<a href=\"javascript:alert(1)\">x</a>"))
        XCTAssertTrue(out.text.string.contains("<iframe"))
        var linked = false
        out.text.enumerateAttribute(.link, in: NSRange(location: 0, length: out.text.length)) { v, _, _ in if v != nil { linked = true } }
        XCTAssertFalse(linked, "no HTML becomes a link")
        XCTAssertTrue(out.text.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
    }

    /// R5: a source nested past 128 is shown as source, before the parser sees it.
    func testDepthCap() {
        let quote = String(repeating: "> ", count: 200) + "deep"
        XCTAssertEqual(render(quote).note, R.tooDeepNote)
        XCTAssertEqual(render(quote).text.string, quote)
        let list = (0..<200).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
        XCTAssertEqual(render(list).note, R.tooDeepNote)
        let shallow = String(repeating: "> ", count: 120) + "ok"
        XCTAssertNil(render(shallow).note, "120 levels written \"> > \" are under the cap")
        XCTAssertEqual(R.nestingBound(shallow), 120)
        XCTAssertGreaterThanOrEqual(R.nestingBound("1. 2. 3. x"), 3, "an upper bound: never under the real depth")
        XCTAssertGreaterThanOrEqual(R.nestingBound("- - -"), 3)
        XCTAssertGreaterThanOrEqual(R.nestingBound(" > >\t> x\n"), 3)
        XCTAssertEqual(R.nestingBound("plain - text > x"), 0)
    }

    /// D1: over 1 MiB of Markdown is shown as source.
    func testSizeCap() {
        let big = String(repeating: "a", count: R.maxSourceBytes + 1)
        let out = render(big)
        // #1236: one line one unit over the paragraph cap too: shown as source and cut at the cap.
        XCTAssertEqual(out.note, R.cutNote(R.maxParagraphUnits) + " \u{00B7} " + R.tooLargeNote)
        XCTAssertEqual(out.text.length, R.maxParagraphUnits)
        XCTAssertNil(render(String(repeating: "a", count: 1000)).note)
    }

    /// A table wider than 64 columns is rows of " | "-joined cells, not an NSTextTable.
    func testWideTableIsJoinedText() {
        func table(_ n: Int) -> String {
            let row = { (p: String) in "|" + (0..<n).map { " \(p)\($0) |" }.joined() }
            return [row("h"), "|" + String(repeating: "---|", count: n), row("c")].joined(separator: "\n")
        }
        func hasTable(_ out: R.Output) -> Bool {
            var found = false
            out.text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.text.length)) { v, _, _ in
                if (v as? NSParagraphStyle)?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true { found = true }
            }
            return found
        }
        let at = render(table(64))
        XCTAssertTrue(hasTable(at))
        XCTAssertTrue(at.note == nil, "64 columns is a table: no note")
        let wide = render(table(65))
        XCTAssertFalse(hasTable(wide))
        XCTAssertEqual(wide.note, "Too many table columns: the rest shown as plain text", "R886-9: the wide table says why")
        XCTAssertTrue(wide.text.string.contains("h0 | h1 | h2"), wide.text.string.prefix(80).description)
        XCTAssertTrue(wide.text.string.contains("\nc0 | c1"))
    }

    /// At most 64 images are requested per document; the rest show their alt text.
    func testImageCountCap() {
        let loader = Loader()
        let out = render((0..<70).map { "![i\($0)](p\($0).png)" }.joined(separator: " "), loader)
        XCTAssertEqual(loader.requests.count, R.maxImages)
        XCTAssertEqual(loader.requests.last, "p63.png")
        XCTAssertTrue(out.text.string.contains("[image: i69]"))
    }

    /// T4: list starts. Nine digits is a list; nineteen is text; no crash either way.
    func testHugeListStart() {
        XCTAssertTrue(render("999999999. x").text.string.hasPrefix("999999999.\tx"))
        XCTAssertEqual(render("9223372036854775807. x").text.string, "9223372036854775807. x")
    }

    func testSlugs() {
        XCTAssertEqual(R.slug("Install Guide!"), "install-guide")
        let out = render("# A\n\n# A\n\n# A")
        XCTAssertEqual(Set(out.anchors.keys), ["a", "a-1", "a-2"])
    }

    // MARK: #1163 (QA 886): the depth check, the nested markers, an image inside a link, the cap edges.

    /// R886-4: indent only continues what earlier lines opened. A blank line of 258 spaces and a code
    /// line of 65 tabs open nothing; real nesting past the cap is still refused.
    func testDepthCountsOnlyRealNesting() {
        let blank = "a\n" + String(repeating: " ", count: 258) + "\nb"
        XCTAssertEqual(R.nestingBound(blank), 0)
        let blankOut = render(blank)
        XCTAssertTrue(blankOut.note == nil, "a blank line of spaces is no nesting")
        XCTAssertEqual(blankOut.text.string, "a\nb")
        let tabs = "# T\n\n" + String(repeating: "\t", count: 65) + "code"
        XCTAssertEqual(R.nestingBound(tabs), 0)
        let code = render(tabs)
        XCTAssertTrue(code.note == nil, "an indented code line is no nesting")
        XCTAssertTrue(code.text.string.hasPrefix("T\n"), code.text.string.prefix(8).description)
        XCTAssertTrue(font(code, "code")?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        // Indent counts up to what the earlier lines opened, and markers in full.
        XCTAssertEqual(R.nestingBound("- - - x\n" + String(repeating: " ", count: 258) + "y"), 3)
        XCTAssertEqual(R.nestingBound("- a\n  - b\n    - c"), 3)
        XCTAssertEqual(R.nestingBound("      > x"), 1, "indent before the first line's marker continues nothing")
        XCTAssertEqual(R.nestingBound(Self.listByIndent(127) + "\n" + String(repeating: " ", count: 258)), 127)
        // Real nesting past the cap: still refused, with or without a wide blank line after it.
        let deep = Self.listByIndent(129) + "\n" + String(repeating: " ", count: 258) + "\nz"
        XCTAssertEqual(R.nestingBound(deep), 129)
        XCTAssertEqual(render(deep).note, R.tooDeepNote)
    }

    /// R886-5: "1. - x" draws both markers, each at its own depth; later blocks draw only the items they open.
    func testNestedItemsOnOneLineDrawEveryMarker() {
        let out = render("1. - x")
        XCTAssertEqual(out.text.string, "1.\t◦\tx")
        let ps = para(out, "1.")
        XCTAssertEqual(ps?.firstLineHeadIndent, 0)
        XCTAssertEqual(ps?.headIndent, 44)
        XCTAssertEqual(ps?.tabStops.map(\.location), [22, 44])
        XCTAssertEqual(render("1. - x\n   - y\n2. z").text.string, "1.\t◦\tx\n◦\ty\n2.\tz")
        XCTAssertEqual(render("- - [ ] t").text.string, "•\t☐\tt", "the task box is the innermost item's")
        XCTAssertEqual(render("- - - - - - - - - x").text.string, "•\t◦\t▪\t•\t◦\t▪\t•\t◦ ◦\tx", "past depth 8 markers share the last stop")
        // A raw HTML block inside an item (it carries the item: N1163-m): the item's next block draws no marker again.
        let html = render("- a\n\n  <div>x</div>\n\n  b").text.string
        XCTAssertTrue(html.hasPrefix("•\ta\n"), html)
        XCTAssertTrue(html.hasSuffix("\nb"), html)
        XCTAssertFalse(html.contains("•\tb"), html)
    }

    /// A loader that draws an 8 x 8 picture for every request.
    private func drawingLoader() throws -> Loader {
        let loader = Loader()
        loader.image = ImagePolicy.decode(try pngData(width: 8, height: 8), maxPixelSize: 8)
        return loader
    }

    private func linkString(_ out: R.Output, at i: Int) -> String? {
        guard i >= 0, i < out.text.length else { return nil }
        return (out.text.attribute(.link, at: i, effectiveRange: nil) as? URL)?.absoluteString
    }

    /// #1213 (R886-5, was the known fault): an image inside a link. The parser drops the image (testParserFacts); its
    /// source slice parsed alone gives it back. A local image is drawn and keeps the outer link; a remote one is never
    /// loaded: "[image: alt]" in the secondary colour, linked to the outer target, not to the image.
    func testImageInsideLink() throws {
        let loader = try drawingLoader()
        let out = render("[![alt](p.png)](#top)", loader)
        XCTAssertEqual(loader.requests, ["p.png"], "asked once, with the image's own source")
        XCTAssertEqual(out.text.string, "\u{FFFC}")
        XCTAssertTrue(out.text.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        XCTAssertEqual(linkString(out, at: 0), "#top", "the outer link on the picture")
        XCTAssertEqual(out.text.attribute(.toolTip, at: 0, effectiveRange: nil) as? String, "#top", "D6: the target")

        let remoteLoader = try drawingLoader()
        let remote = render("[![badge](https://example.com/b.svg)](https://example.com/home)", remoteLoader)
        XCTAssertEqual(remoteLoader.requests, [], "a remote image is never requested")
        XCTAssertEqual(remote.text.string, "[image: badge]")
        XCTAssertEqual(linkString(remote, at: 0), "https://example.com/home")
        let color = (remote.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        XCTAssertEqual(color?.redComponent ?? -1, 0.5, accuracy: 0.01, "the secondary colour")

        let refused = Loader()   // a local image the loader refuses: the mark, with the outer link
        let mark = render("[![alt](p.png)](#top)", refused)
        XCTAssertEqual(refused.requests, ["p.png"])
        XCTAssertEqual(mark.text.string, "[image: alt]")
        XCTAssertEqual(linkString(mark, at: 0), "#top")

        let empty = try drawingLoader()   // left.txt: an empty alt gives the parser no run at all; it stays lost
        XCTAssertEqual(render("[![](p.png)](#top)", empty).text.string, "")
        XCTAssertEqual(empty.requests, [])
    }

    /// #1213: anything but exactly one image in the slice is marked "[image: text]" with the outer link, not loaded;
    /// text BEFORE the image starts the slice with that text, so the run is drawn as before. Plain links and images in
    /// the same file are drawn as before.
    func testImageInsideLinkFallbacks() throws {
        let cases: [(String, String)] = [
            ("[![a](p.png) and text](#top)", "[image: a and text]"),   // text after the image
            ("[![a](p.png)![b](q.png)](#top)", "[image: ab]"),         // two images
            ("[![alt][r]](#top)\n\n[r]: p.png", "[image: alt]"),       // a reference image: no definition in the slice
        ]
        for (md, shown) in cases {
            let loader = try drawingLoader()
            let out = render(md, loader)
            XCTAssertEqual(out.text.string, shown, md)
            XCTAssertEqual(loader.requests, [], md)
            XCTAssertEqual(linkString(out, at: 0), "#top", md)
        }
        let before = render("[x ![a](p.png)](#top)")
        XCTAssertEqual(before.text.string, "x a", "text before the image: drawn as before (left.txt)")
        XCTAssertEqual(linkString(before, at: 0), "#top")
        let loader = try drawingLoader()
        let mixed = render("[![a](p.png)](#top) [b](#top) ![c](q.png)", loader)
        XCTAssertEqual(loader.requests, ["p.png", "q.png"])
        XCTAssertEqual(mixed.text.string, "\u{FFFC} b \u{FFFC}")
        XCTAssertEqual(linkString(mixed, at: 2), "#top", "the plain link")
        XCTAssertEqual(mixed.text.attribute(.toolTip, at: 4, effectiveRange: nil) as? String, "c", "the plain image")
        XCTAssertTrue(linkString(mixed, at: 4) == nil)
    }

    /// #1213: two forms in one paragraph; non-ASCII bytes before a form on its line; CRLF and lone CR line ends: the byte
    /// range of each is right, so each local image is asked for once.
    func testImageInsideLinkByteRange() throws {
        let loader = try drawingLoader()
        let two = render("[![a](p.png)](#top) and [![b](https://example.com/b.svg)](#top)", loader)
        XCTAssertEqual(loader.requests, ["p.png"])
        XCTAssertEqual(two.text.string, "\u{FFFC} and [image: b]")
        XCTAssertEqual(linkString(two, at: two.text.length - 1), "#top")
        let wide = try drawingLoader()
        let w = render("\u{E9} \u{E4} [![\u{FC}](p.png)](#top) \u{F6} [![b](q.png)](#top)\nx\u{1F600} [![c](r.png)](#top)", wide)
        XCTAssertEqual(wide.requests, ["p.png", "q.png", "r.png"], w.text.string)
        let crlf = try drawingLoader()
        _ = render("one\r\n\r\n\u{E9} [![a](p.png)](#top)\r\nnext [![b](q.png)](#top)\rlast [![c](r.png)](#top)\r\n", crlf)
        XCTAssertEqual(crlf.requests, ["p.png", "q.png", "r.png"])
    }

    /// #1213: inside a list item, a quote, a quote's second line and a list in a quote the parser's columns are right
    /// (the part 2 ticket): the picture, asked once.
    func testImageInsideLinkInContainers() throws {
        for (name, md, src) in [("list", "- [![a](p.png)](#top)", "p.png"), ("quote", "> [![a](q.png)](#top)", "q.png"),
                                ("quote line 2", "> x\n> [![a](r.png)](#top)", "r.png"),
                                ("nested", "> - y\n>   [![a](s.png)](#top)", "s.png")] {
            let loader = try drawingLoader()
            let out = render(md, loader)
            XCTAssertEqual(loader.requests, [src], name)
            print("MR1213b container \(name): \(loader.requests.isEmpty ? "as before" : "drawn") \(out.text.string.debugDescription)")
        }
    }

    /// #1213: the slice parses are capped at maxImages per document, remote ones included; past the cap a form is
    /// marked without a parse. The image counts toward maxImages and toward the per-paragraph bound like any image.
    func testImageInsideLinkCaps() throws {
        let remote = (0..<R.maxImages).map { "[![r\($0)](https://example.com/\($0).svg)](#top)" }.joined(separator: " ")
        let loader = try drawingLoader()
        let out = render(remote + " [![last](p.png)](#top)", loader)
        XCTAssertEqual(loader.requests, [], "the form past the slice-parse cap is not parsed, so not loaded")
        XCTAssertTrue(out.text.string.hasSuffix(" [image: last]"), String(out.text.string.suffix(40)))
        XCTAssertEqual(linkString(out, at: out.text.length - 1), "#top")

        let images = (0..<R.maxImages).map { "![i\($0)](p\($0).png)" }.joined(separator: " ")
        let full = Loader()
        let shown = render(images + " [![last](q.png)](#top)", full)
        XCTAssertEqual(full.requests.count, R.maxImages)
        XCTAssertEqual(full.requests.last, "p63.png", "the form's image is past maxImages: not requested")
        XCTAssertTrue(shown.text.string.hasSuffix(" [image: last]"))
        XCTAssertEqual(linkString(shown, at: shown.text.length - 1), "#top")

        autoreleasepool {   // run p + 1 of a paragraph: its text, plain, not requested
            let p = R.maxStyledRunsPerParagraph
            let bound = Loader()
            let md = (0..<p).map { "*e\($0)*" }.joined(separator: " ") + " [![over](p.png)](#top)"
            let o = render(md, bound)
            XCTAssertEqual(bound.requests, [])
            XCTAssertTrue(o.text.string.hasSuffix(" over"), String(o.text.string.suffix(20)))
            XCTAssertTrue(linkString(o, at: o.text.length - 1) == nil)
        }
    }

    /// #1213: the gate. Source positions only for a source holding the bytes "[!["; every other option as before.
    func testSourcePositionsOnlyForTheForm() {
        for md in [Self.everyConstruct, "", "[a](#top) ![b](p.png) [ ![c](q.png)](#top)", "[!x", "![[a]](p.png)"] {
            XCTAssertFalse(R.parsingOptions(for: md).appliesSourcePositionAttributes, md)
        }
        for md in ["[![a](p.png)](#top)", "x[![", "\u{E9}[![\u{301}"] {
            XCTAssertTrue(R.parsingOptions(for: md).appliesSourcePositionAttributes, md)
        }
        let o = R.parsingOptions(for: "[![")
        XCTAssertFalse(o.allowsExtendedAttributes)
        XCTAssertTrue(o.interpretedSyntax == .full)
        XCTAssertTrue(o.failurePolicy == .returnPartiallyParsedIfPossible)
        XCTAssertTrue(o.languageCode == nil)
    }

    /// #1213: the line table and the bounds check. The parser cannot be made to report a position off its source, so
    /// the row calls the map directly: every position that does not lie on its line is no slice, nothing traps.
    func testSourceMapChecksPositions() {
        let m = R.SourceMap("ab\ncd\r\nef\rg")
        XCTAssertEqual(m.starts, [0, 3, 7, 10])
        func s(_ l: Int, _ c: Int, _ el: Int, _ ec: Int) -> String? {
            m.slice(line: l, column: c, toLine: el, column: ec).map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(s(1, 1, 1, 2), "ab")
        XCTAssertEqual(s(2, 1, 2, 2), "cd")
        XCTAssertEqual(s(1, 2, 3, 1), "b\ncd\r\ne")
        XCTAssertEqual(s(4, 1, 4, 1), "g")
        XCTAssertEqual(s(1, 3, 1, 3), "\n", "a line's end byte is on it")
        for bad in [(0, 1, 1, 1), (1, 0, 1, 1), (1, 1, 1, 4), (5, 1, 5, 1), (4, 2, 4, 2), (1, 2, 1, 1), (2, 1, 1, 1),
                    (Int.max, 1, 1, 1), (1, Int.max, 1, Int.max), (Int.min, Int.min, Int.min, Int.min), (1, 1, Int.max, Int.max),
                    (-1, -1, -1, -1), (Int.max, Int.max, Int.max, Int.max), (1, Int.max - 1, 1, Int.max), (1, -5, 1, 2),
                    (2, Int.min, 2, 1), (4, 1, 4, Int.min), (Int.min, 1, 4, 1), (1, 1, -1, 1), (3, 3, 3, 4)] {
            XCTAssertTrue(s(bad.0, bad.1, bad.2, bad.3) == nil, "\(bad)")
        }
        let empty = R.SourceMap("")
        XCTAssertTrue(empty.slice(line: 1, column: 1, toLine: 1, column: 1) == nil)
        let ends = R.SourceMap("a\n")
        XCTAssertEqual(ends.starts, [0, 2])
        XCTAssertTrue(ends.slice(line: 2, column: 1, toLine: 2, column: 1) == nil, "the empty last line holds nothing")
        let nul = R.SourceMap(R.positionSource("\u{0}\n\u{0}"))   // #1222: a NUL is three bytes in the table
        XCTAssertEqual(nul.starts, [0, 4])
        XCTAssertEqual(nul.bytes.count, 7)
        XCTAssertTrue(nul.slice(line: 2, column: 1, toLine: 2, column: 4) == nil)
    }

    /// #1222 (R1213b-1): the parser's columns after a NUL, after a leading BOM and on a lazy continuation line, as a literal
    /// table from the real parser (the #1222 report's probe). With positionSource the NUL and BOM shapes slice exactly the
    /// image's source; a second leading BOM and the lazy lines still shift and stay a fallback.
    func testParserColumnShifts() throws {
        var opts = R.parsingOptions(for: "[![")
        XCTAssertTrue(opts.appliesSourcePositionAttributes)
        opts.appliesSourcePositionAttributes = true
        func pos(_ md: String) throws -> [Int] {
            let p = try AttributedString(markdown: md, options: opts)
            let q = try XCTUnwrap(p.runs.first { $0.link != nil }?.markdownSourcePosition, md.debugDescription)
            return [q.startLine, q.startColumn, q.endLine, q.endColumn]
        }
        let form = "[![a](p.png)](#top)"
        // (source, the parser's position as given, its position in positionSource's text; nil = still shifted)
        let table: [(String, [Int], [Int]?)] = [
            (form, [1, 2, 1, 12], [1, 2, 1, 12]),
            ("\u{0}" + form, [1, 5, 1, 15], [1, 5, 1, 15]),                     // +2 per NUL earlier on the line
            ("\u{0}\u{0}" + form, [1, 8, 1, 18], [1, 8, 1, 18]),
            ("[![a\u{0}b](p.png)](#top)", [1, 2, 1, 16], [1, 2, 1, 16]),       // the end moves too
            ("\u{0}\n" + form, [2, 2, 2, 12], [2, 2, 2, 12]),                   // a NUL on an earlier line: no shift
            ("\u{0}\r\n\u{0}" + form, [2, 5, 2, 15], [2, 5, 2, 15]),
            ("\u{FEFF}" + form, [1, 5, 1, 15], [1, 2, 1, 12]),                  // line 1 counts the BOM
            ("\u{FEFF}x\n" + form, [2, 5, 2, 15], [2, 2, 2, 12]),               // a later line of the same block: +3
            ("\u{FEFF}x\ny\n" + form, [3, 5, 3, 15], [3, 2, 3, 12]),
            ("\u{FEFF}x\r" + form, [2, 5, 2, 15], [2, 2, 2, 12]),
            ("\u{FEFF}> x\n> " + form, [2, 7, 2, 17], [2, 4, 2, 14]),
            ("\u{FEFF}# h\n" + form, [2, 2, 2, 12], [2, 2, 2, 12]),             // a block that starts on line 2: true
            ("\u{FEFF}x\n\ny\n" + form, [4, 2, 4, 12], [4, 2, 4, 12]),
            ("\u{FEFF}\u{0}" + form, [1, 8, 1, 18], [1, 5, 1, 15]),
            ("\u{FEFF}x\n\u{0}" + form, [2, 8, 2, 18], [2, 5, 2, 15]),
            ("x\u{FEFF}" + form, [1, 6, 1, 16], [1, 6, 1, 16]),                 // a BOM later in the text is text
            ("\u{FEFF}\u{FEFF}x\n" + form, [2, 5, 2, 15], [2, 2, 2, 12]),      // #1229: every leading BOM dropped
            ("> x\n" + form, [2, 4, 2, 14], nil),                               // lazy: + the first line's prefix
            ("> > x\n" + form, [2, 6, 2, 16], nil),
            ("- x\n" + form, [2, 4, 2, 14], nil),
        ]
        for (md, raw, fixed) in table {
            XCTAssertEqual(try pos(md), raw, md.debugDescription)
            let text = R.positionSource(md)
            let p = try pos(text)
            let m = R.SourceMap(text)
            let slice = m.slice(line: p[0], column: p[1], toLine: p[2], column: p[3]).map { String(decoding: $0, as: UTF8.self) }
            if let fixed {
                XCTAssertEqual(p, fixed, md.debugDescription)
                XCTAssertTrue(slice?.hasPrefix("![a") == true && slice?.hasSuffix("](p.png)") == true, "\(md.debugDescription): \(slice ?? "nil")")
            } else {
                XCTAssertFalse(slice?.hasPrefix("![") == true, "\(md.debugDescription): still shifted, not a form")
            }
            let plain = R.parsingOptions(for: "")
            XCTAssertEqual(String(try AttributedString(markdown: text, options: opts).characters),
                           String(try AttributedString(markdown: md, options: plain).characters), "the same text drawn")
        }
        XCTAssertEqual(R.positionSource("\u{FEFF}a\u{0}b"), "a\u{FFFD}b")
        XCTAssertEqual(R.positionSource("\u{FEFF}\u{FEFF}"), "", "#1229: every leading BOM")
        XCTAssertEqual(R.positionSource("a\u{FEFF}"), "a\u{FEFF}")
        XCTAssertEqual(R.positionSource(""), "")
    }

    /// #1222: a picture inside a link after a NUL or a leading BOM is drawn; a doubled BOM and a lazy line fall back to
    /// the link text, never a trap.
    func testImageInsideLinkAfterNulAndBom() throws {
        let form = "[![a](p.png)](#top)"
        for md in ["\u{0}" + form, "\u{0}\u{0}" + form, "[![a\u{0}b](p.png)](#top)", "\u{0}\r\n\u{0}" + form,
                   "\u{FEFF}" + form, "\u{FEFF}x\n" + form, "\u{FEFF}x\ny\n" + form, "\u{FEFF}> x\n> " + form,
                   "\u{FEFF}x\n\u{0}" + form, "\u{FEFF}\u{0}" + form, "\u{FEFF}\u{FEFF}x\n" + form] {
            let loader = try drawingLoader()
            let out = render(md, loader)
            XCTAssertEqual(loader.requests, ["p.png"], md.debugDescription)
            XCTAssertTrue(out.text.string.hasSuffix("\u{FFFC}"), "\(md.debugDescription): \(out.text.string.debugDescription)")
            XCTAssertEqual(linkString(out, at: out.text.length - 1), "#top", md.debugDescription)
        }
        let nulLoader = try drawingLoader()
        XCTAssertEqual(render("\u{0}" + form, nulLoader).text.string, "\u{FFFD}\u{FFFC}", "the NUL drawn as the parser draws it")
        for md in ["> x\n" + form, "- x\n" + form] {
            let loader = try drawingLoader()
            let out = render(md, loader)
            XCTAssertEqual(loader.requests, [], md.debugDescription)
            XCTAssertTrue(out.text.string.hasSuffix("a"), "\(md.debugDescription): as before #1213, the alt as link text")
            XCTAssertEqual(linkString(out, at: out.text.length - 1), "#top", md.debugDescription)
        }
    }

    /// #1229 (N1222-a): two or more leading BOMs draw as one does, with or without an image inside a link; a BOM after
    /// any other character stays text.
    func testLeadingBOMsDrawAsOne() throws {
        let form = "[![a](p.png)](#top)", b = "\u{FEFF}"
        let one = render(b + "# Title")
        XCTAssertEqual(font(one, "Title")?.pointSize, 20, "one leading BOM: a heading, as before")
        for md in [b + b + "# Title", b + b + b + "# Title"] {
            let out = render(md)
            XCTAssertEqual(out.text.string, one.text.string, md.debugDescription)
            XCTAssertEqual(font(out, "Title")?.pointSize, 20, "\(md.debugDescription): a heading without the form too")
        }
        for md in [b + "# Title " + form, b + b + "# Title " + form, b + b + b + "# Title " + form] {
            let loader = try drawingLoader()
            let out = render(md, loader)
            XCTAssertEqual(font(out, "Title")?.pointSize, 20, "\(md.debugDescription): a heading with the form")
            XCTAssertEqual(loader.requests, ["p.png"], md.debugDescription)
            XCTAssertEqual(linkString(out, at: out.text.length - 1), "#top", md.debugDescription)
        }
        let plainOne = render(b + "plain words")
        for md in [b + b + "plain words", b + b + b + "plain words"] {
            let out = render(md)
            XCTAssertEqual(out.text.string, plainOne.text.string, md.debugDescription)
            XCTAssertEqual(font(out, "plain")?.pointSize, 15, md.debugDescription)
        }
        let loader = try drawingLoader()
        let three = render(b + b + b + "x\n" + form, loader)
        XCTAssertEqual(loader.requests, ["p.png"], "three BOMs, the form on line 2")
        XCTAssertTrue(three.text.string.hasSuffix("\u{FFFC}"), three.text.string.debugDescription)
        for md in ["x\u{FEFF}y", b + "x\u{FEFF}y", b + b + "x\u{FEFF}y " + form] {
            XCTAssertTrue(render(md).text.string.contains("x\u{FEFF}y"), "\(md.debugDescription): a BOM after text is text")
        }
        for (s, want) in [("", ""), (b, ""), (b + b + "a" + b, "a" + b), ("a" + b, "a" + b), (" " + b + "a", " " + b + "a"),
                          (String(repeating: b, count: 100_000), ""), (String(repeating: b, count: 100_000) + "a", "a")] {
            XCTAssertEqual(R.withoutLeadingBOMs(s), want, "\(s.unicodeScalars.count) scalars")
        }
    }

    /// #1222 (R1213-1): a link whose text is literally "![..." with no image is drawn as before #1213 (its text, linked);
    /// a slice that does hold an image the outer parse dropped keeps the mark (testImageInsideLinkFallbacks).
    func testImageInsideLinkLiteralText() throws {
        for (md, shown) in [("[![x]](#top)", "![x]"), ("[![x&amp;]](#top)", "![x&]"), ("[![x] y](#top)", "![x] y"),
                            ("[\\![x]](#top)", "![x]")] {
            let loader = try drawingLoader()
            let out = render(md, loader)
            XCTAssertEqual(out.text.string, shown, md)
            XCTAssertEqual(loader.requests, [], md)
            XCTAssertEqual(linkString(out, at: 0), "#top", md)
            XCTAssertEqual(out.text.attribute(.toolTip, at: 0, effectiveRange: nil) as? String, "#top", md)
        }
        let ref = render("[![x]](#top)\n\n[x]: p.png")   // a shortcut reference image: the outer parse dropped it
        XCTAssertEqual(ref.text.string, "[image: x]")
        XCTAssertEqual(linkString(ref, at: 0), "#top")
        let o = R.parsingOptions(for: "[![")
        XCTAssertEqual(R.linkedImage("![x]", shown: "![x]", options: o), .text)
        XCTAssertEqual(R.linkedImage("![x]", shown: "x", options: o), .mark, "a reference: reads differently alone")
        XCTAssertEqual(R.linkedImage("![alt][r]", shown: "alt", options: o), .mark)
        XCTAssertEqual(R.linkedImage("![a](p.png) and text", shown: "a and text", options: o), .mark, "holds an image")
        XCTAssertEqual(R.linkedImage("![a](p.png)![b](q.png)", shown: "ab", options: o), .mark)
        if case .image(let u) = R.linkedImage("![a](p.png)", shown: "a", options: o) { XCTAssertEqual(u.absoluteString, "p.png") } else { XCTFail("one image run") }
    }

    /// #1222 (Q1, QA 957): the outer link of a picture goes through the link policy like any link: a refused target
    /// leaves the picture with no link and its alt as the tooltip, and a remote image's mark with no link at all (never
    /// the image's own URL). The target is a literal that is never opened.
    func testImageInsideRefusedLink() throws {
        let loader = try drawingLoader()
        let out = render("[![alt](p.png)](javascript:x)", loader)
        XCTAssertEqual(loader.requests, ["p.png"])
        XCTAssertEqual(out.text.string, "\u{FFFC}")
        XCTAssertTrue(out.text.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        XCTAssertTrue(out.text.attribute(.link, at: 0, effectiveRange: nil) == nil, "a refused outer link is not kept")
        XCTAssertEqual(out.text.attribute(.toolTip, at: 0, effectiveRange: nil) as? String, "alt")

        let remoteLoader = try drawingLoader()
        let remote = render("[![badge](https://example.com/b.svg)](javascript:x)", remoteLoader)
        XCTAssertEqual(remoteLoader.requests, [])
        XCTAssertEqual(remote.text.string, "[image: badge]")
        var links = 0
        remote.text.enumerateAttribute(.link, in: NSRange(location: 0, length: remote.text.length)) { v, _, _ in if v != nil { links += 1 } }
        XCTAssertEqual(links, 0, "no link at all, not the image's own URL")
        XCTAssertTrue(remote.text.attribute(.toolTip, at: 0, effectiveRange: nil) == nil)
    }

    /// R886-3: exactly 1 MiB is parsed; one byte more, or 1 MiB of characters over 1 MiB of bytes, is source.
    func testSizeCapBoundary() {
        let atCap = String(repeating: "a", count: R.maxSourceBytes)
        let start = Date()
        let at = render(atCap)
        Self.fact("size cap boundary: 1 MiB paragraph rendered in \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        XCTAssertTrue(at.note == nil, "exactly 1 MiB is parsed")
        XCTAssertEqual(at.text.length, R.maxSourceBytes)
        XCTAssertTrue(font(at, "aaaa")?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false, "body text, not source")
        let over = render(atCap + "a")
        XCTAssertEqual(over.note, R.cutNote(R.maxParagraphUnits) + " \u{00B7} " + R.tooLargeNote, "#1236: and one unit over the paragraph cap")
        XCTAssertEqual(over.text.length, R.maxParagraphUnits)
        let bytesOver = render(String(atCap.dropLast()) + "é")
        XCTAssertEqual(bytesOver.note, R.tooLargeNote, "the cap counts UTF-8 bytes, not characters")
    }

    /// R886-3: quote bars and list indents are drawn 8 deep at most; deeper blocks draw at depth 8.
    func testShownDepthEdges() {
        let q8 = render("> > > > > > > > eight")
        XCTAssertEqual(para(q8, "eight")?.textBlocks.count, 8)
        let q9 = render("> > > > > > > > > nine")
        XCTAssertEqual(q9.text.string, "nine")
        XCTAssertEqual(para(q9, "nine")?.textBlocks.count, 8)
        let list = render("- l1\n  - l2\n    - l3\n      - l4\n        - l5\n          - l6\n            - l7\n              - l8\n                - l9")
        XCTAssertEqual(list.text.string, "•\tl1\n◦\tl2\n▪\tl3\n•\tl4\n◦\tl5\n▪\tl6\n•\tl7\n◦\tl8\n◦\tl9")
        XCTAssertEqual(para(list, "\tl7")?.headIndent, 154)
        XCTAssertEqual(para(list, "\tl8")?.headIndent, 176)
        XCTAssertEqual(para(list, "\tl9")?.headIndent, 176)
    }

    /// R886-3: table cells are counted per row times its columns: 4 columns x 12,500 rows is the cap.
    func testTableCellCapCountsColumnsPerRow() {
        let head = "|h|i|j|k|\n|-|-|-|-|\n"
        let start = Date()
        let at = render(head + String(repeating: "|a|b|c|d|\n", count: 12_498) + "|w|x|y|z|")
        Self.fact("table cell cap, 4 columns: 50,000 cells rendered in \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        XCTAssertTrue(at.note == nil, "50,000 cells: nothing trimmed")
        XCTAssertTrue(at.text.string.hasSuffix("\nw\nx\ny\nz"), String(at.text.string.suffix(12)))
        XCTAssertTrue(inTable(at, at: at.text.length - 1), "cell 50,000 is a table cell")
        let over = render(head + String(repeating: "|a|b|c|d|\n", count: 12_499) + "|w|x|y|z|")
        XCTAssertTrue(over.text.string.hasSuffix("\nd\nw | x | y | z"), String(over.text.string.suffix(16)))
        XCTAssertFalse(inTable(over, at: over.text.length - 1), "the row past 50,000 cells is joined text")
        XCTAssertTrue(inTable(over, at: over.text.length - 15), "the row before it is still a table")
        XCTAssertEqual(over.note, "Too many table cells: the rest shown as plain text")
    }

    /// R886-3: the thumbnail size handed to the loader is the column (760) at a 2x backing, capped at 16,384.
    func testImageSizeHandedToTheLoader() {
        func sizes(scale: CGFloat) -> [Int] {
            var style = Self.style
            style.scale = scale
            let loader = Loader()
            _ = R.render("![a](a.png)", document: Self.document, style: style, loader: loader.load)
            return loader.sizes
        }
        XCTAssertEqual(sizes(scale: 1), [1520])
        XCTAssertEqual(sizes(scale: 2), [3040])
        XCTAssertEqual(sizes(scale: 20), [16384], "760 x 20 x 2 = 30,400 is capped")
        XCTAssertEqual(sizes(scale: 0), [1520], "a scale that is not positive draws at 1")
        XCTAssertEqual(sizes(scale: .nan), [1520])
    }

    /// R886-3: a list or quote marker that ends its line counts toward the bound, at the end of a line
    /// and at the end of the source.
    func testMarkerEndingItsLineCounts() {
        XCTAssertEqual(R.nestingBound("- -\nx"), 2)
        XCTAssertEqual(R.nestingBound("1.\nx"), 1)
        XCTAssertEqual(R.nestingBound("1)\r\nx"), 1)
        XCTAssertEqual(R.nestingBound(">\nx"), 1)
        XCTAssertEqual(R.nestingBound("- -"), 2)
        XCTAssertEqual(R.nestingBound("2."), 1)
        XCTAssertEqual(R.nestingBound("-x\n12\n"), 0, "no space after the marker: text")
        XCTAssertTrue(render(String(repeating: "- ", count: 127) + "-\nx").note == nil, "128 with the last marker ending its line")
        XCTAssertEqual(render(String(repeating: "- ", count: 128) + "-\nx").note, R.tooDeepNote)
    }

    /// R886-3: after a hard break the rest of an item is at the item's text indent, not the marker's.
    func testIndentAfterHardBreak() {
        let out = render("- a\\\n  b")
        XCTAssertEqual(out.text.string, "•\ta\nb")
        XCTAssertEqual(para(out, "•")?.firstLineHeadIndent, 0)
        XCTAssertEqual(para(out, "b")?.firstLineHeadIndent, 22)
        XCTAssertEqual(para(out, "b")?.headIndent, 22)
    }

    /// #1187: the pre-scan's count, exactly: two per line with text, one per delimiter, one per pipe between cells.
    func testMarkupCount() {
        let cases: [(String, Int)] = [
            ("", 0), ("plain text", 2), ("a\nb", 4), ("a\n\n\nb", 4), ("  \n\t\n", 0), ("a\r\nb\rc", 6),
            ("*a*", 4), ("_a_ ~~b~~", 8), ("`c`", 4), ("[a](b)", 4), ("<b>x</b>", 6),
            ("|a|b|", 3), ("| a | b |  ", 3), ("|a|\n|b|", 4), ("||", 2), ("|||", 3), (" | a", 2), ("a |", 2),
            ("# h\n- i\n1. j", 6), ("> > q", 2), ("a < b", 4), ("<http://a>", 6),
            // #1211 (F1187-1), #1213: a bare autolink (two runs) counts two; other dots and colons nothing
            ("a.b", 2), ("a:b", 2), (".a", 2), ("a..b", 2), ("a.", 2), ("a. b", 2), ("a: b", 2), ("a.\nb", 4), ("a@b", 2),
            ("a@b.co", 4), ("www.a", 4), ("http://a", 4), ("www.a.co", 4), ("http://a.co", 4), ("a@b.co a@b.co", 6),
            ("a@ b.c", 2), ("a@b. c", 2), ("a@b.c.d", 4), ("w. a", 2), ("a:/", 4),
            // F1213-1: two for an "&" before "#" or an ASCII letter (an entity), nothing for any other "&"
            ("a&#64;b.c", 4), ("a&commat;b.c", 4), ("a@b&#46;c", 4), ("&amp;", 4), ("AT&T", 4), ("a & b", 2), ("a&&b", 4),
            ("a&", 2), ("&#", 4), ("x&=y", 2), ("a&\nb", 4), ("&&&", 2),
        ] + Self.autolinkShapes
        for (md, n) in cases { XCTAssertEqual(R.markupCount(md), n, md.debugDescription) }
    }

    /// #1213: shapes the parser may or may not turn into a link, one unit each, with markupCount's count (probe table).
    static let autolinkShapes: [(String, Int)] = [
        ("a@b.co", 4), ("www.a.co", 4), ("http://a.co", 4), ("a@b.c", 4), ("www.a", 4), ("http://a", 4),
        ("https://a", 4), ("ftp://a.b", 4), ("mailto:a@b.c", 4), ("a.co", 2), ("x:y", 2), ("a.b", 2), ("a@b", 2),
        ("WWW.a", 4), ("WWW.A.CO", 4), ("Www.a", 4), ("HTTP://a", 4), ("HTTPS://a", 4), ("ftp://a", 4), ("FTP://a", 4),
        ("mailto:a", 2), ("MAILTO:a@b.c", 4), ("mailto:a@b", 2), ("xmpp:a@b.c", 4), ("xmpp:a@b.c/r", 4), ("xmpp:a", 2),
        ("http://[::1]/", 6), ("http://[a]/", 6), ("a@", 2), ("@a.b", 4), ("now.then", 4), ("w.a", 4), ("xwww.a", 4),
        ("www.a.co/x?y=z", 4), ("http://a.co/x.y", 4), ("a@b.co.uk", 4), ("a@b.co@c.d", 6), ("a.b@c.d", 4),
        ("a@b.c.", 4), ("www.a.", 4), ("file.md", 2), ("1.2.3", 2), ("x://a", 4), ("a://b", 4), ("a+b@c.d", 4),
        ("a_b@c.d", 5), ("a-b@c.d", 4), ("(www.a)", 4), ("*www.a*", 6), ("a@b.co,c@d.co", 6), ("www.a.co,www.b.co", 6),
        ("http://a,http://b", 6), ("http://a.co,www.b.co", 6), ("a@b.co;http://c", 6), ("www.a@b.c", 6),
        ("https://a@b.c", 6), ("a@www.b", 4), ("a:b@c.d", 4), ("http://a.co.", 4), ("<http://a>", 6), ("<a@b.c>", 6),
        ("[x](http://a)", 6), ("`www.a`", 6), ("a.b.c.d.e", 2), ("v1.2.3:", 2), ("C:\\x", 2),
        // F1213-1 (QA 950): "@" or "." spelled as an entity is still linked
        ("a&#64;b.c", 4), ("a&#x40;b.c", 4), ("a&#X40;b.c", 4), ("a&#0064;b.c", 4), ("a&commat;b.c", 4), ("a@b&#46;c", 4),
        ("a&#64;b&#46;c", 6), ("a@b&period;c", 4), ("&amp;", 4), ("AT&T", 4), ("a&b.c", 4), ("&#64;", 4), ("a&#64;b", 4),
        ("a&#64;b&#46;c&#46;d", 8), ("www&period;a", 4), ("http&colon;//a", 4), ("a&#x40;b.c,c&#x40;d.e", 6),
        ("*a&#64;b.c*", 6), ("a&NotAnEntity;b.c", 4), ("a&#9999999999;b.c", 4), ("a&#64b.c", 4),
    ]

    /// #1213: on every shape above, and on #1187's inline shapes, 100 units count at least the runs the parser makes of
    /// them, units joined by a blank and by a line end. Parse only, a few hundred runs a shape.
    func testMarkupCountCoversTheParsersRuns() throws {
        let opts = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                           failurePolicy: .returnPartiallyParsedIfPossible, languageCode: nil)
        var docs = Self.inlineShapes(100)
        for (shape, _) in Self.autolinkShapes {
            docs.append((shape + " x100", String(repeating: shape + " ", count: 100)))
            docs.append((shape + " x100 lines", String(repeating: shape + "\n", count: 100)))
        }
        var linked = 0
        for (name, md) in docs {
            try autoreleasepool {
                let parsed = try AttributedString(markdown: md, options: opts)
                let runs = parsed.runs.count
                linked += parsed.runs.contains { $0.link != nil } ? 1 : 0
                XCTAssertGreaterThanOrEqual(R.markupCount(md), runs, name)
            }
        }
        print("MR1213b linked documents \(linked)")
        XCTAssertGreaterThanOrEqual(linked, 107, "the table holds shapes the parser links (107 in the #1213 part 2 run)")
    }

    /// #1187: at maxMarkup the file is rendered as before; one more delimiter and it is its source, with the note.
    /// Openers with no closer: the count is at the cap, the parse is one run.
    func testMarkupCap() {
        let at = String(repeating: "*a _a ", count: (R.maxMarkup - 2) / 2)   // the line's 2, then 2 per "*a _a "
        XCTAssertEqual(R.markupCount(at), R.maxMarkup)
        let out = render(at)
        XCTAssertTrue(out.note == nil, out.note ?? "")
        XCTAssertEqual(out.text.string, String(at.dropLast()), "the paragraph, its trailing space dropped")
        XCTAssertEqual(font(out, "*a _a")?.pointSize, 15, "body text, not source")
        let over = at + "_"
        XCTAssertEqual(R.markupCount(over), R.maxMarkup + 1)
        let src = render(over)
        XCTAssertEqual(src.note, R.tooMuchMarkupNote)
        XCTAssertEqual(src.note, "Too much markup: shown as source")
        XCTAssertEqual(src.text.string, over, "the source, every character")
        XCTAssertEqual(font(src, "*a _a")?.pointSize, 13, "monospaced source")
        XCTAssertEqual(render(Self.mixed(129) + "\n" + String(repeating: "*", count: R.maxMarkup)).note, R.tooDeepNote,
                       "the depth cap is checked first, as before")
    }

    /// #1187: the entry's shape at a mid size renders as it did before the cap: "*a" pairs as emphasis,
    /// every other letter italic.
    func testPairedOpenersRenderAsBefore() {
        let md = String(repeating: "*a", count: 1000)
        XCTAssertEqual(R.markupCount(md), 1002)
        let out = render(md)
        XCTAssertTrue(out.note == nil, out.note ?? "")
        XCTAssertEqual(out.text.string, String(repeating: "a", count: 1000))
        var italic: [Bool] = []
        out.text.enumerateAttribute(.font, in: NSRange(location: 0, length: out.text.length)) { v, range, _ in
            let i = (v as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true
            italic.append(contentsOf: Array(repeating: i, count: range.length))
        }
        XCTAssertEqual(italic, (0..<1000).map { $0 % 2 == 0 })
    }

    /// #1211 (F1187-1): bare e-mail autolinks count toward the markup cap: at it the file is Markdown, one more is source.
    func testMarkupCapCountsAutolinks() {
        let mails = String(repeating: "a@b.co ", count: 1000)   // 2 each: the first "." after the "@"
        XCTAssertEqual(R.markupCount(mails), 2 + 2000)
        let at = mails + String(repeating: "*a _a ", count: (R.maxMarkup - 2002) / 2)   // openers with no closer: one run
        XCTAssertEqual(R.markupCount(at), R.maxMarkup)
        autoreleasepool {
            let out = render(at)
            XCTAssertTrue(out.note == nil, out.note ?? "")
            var links = 0
            out.text.enumerateAttribute(.link, in: NSRange(location: 0, length: out.text.length)) { v, _, _ in if v != nil { links += 1 } }
            XCTAssertEqual(links, 1000, "every bare e-mail is a link run")
        }
        XCTAssertEqual(R.markupCount(at + "a@b.co"), R.maxMarkup + 2)
        let src = render(at + "a@b.co")
        XCTAssertEqual(src.note, R.tooMuchMarkupNote)
        XCTAssertEqual(src.text.string, at + "a@b.co")
    }

    /// F1213-1: e-mails spelled with an entity count toward the markup cap: at it the file is Markdown, one more is source.
    func testMarkupCapCountsEntityAutolinks() {
        let mails = String(repeating: "a&#64;b.c ", count: 1000)   // 2 each: the "&" before "#"
        XCTAssertEqual(R.markupCount(mails), 2 + 2000)
        let at = mails + String(repeating: "*a _a ", count: (R.maxMarkup - 2002) / 2)   // openers with no closer: one run
        XCTAssertEqual(R.markupCount(at), R.maxMarkup)
        autoreleasepool {
            let out = render(at)
            XCTAssertTrue(out.note == nil, out.note ?? "")
            var links = 0
            out.text.enumerateAttribute(.link, in: NSRange(location: 0, length: out.text.length)) { v, _, _ in if v != nil { links += 1 } }
            XCTAssertEqual(links, 1000, "every e-mail spelled with an entity is a link run")
        }
        XCTAssertEqual(R.markupCount(at + "a&#64;b.c"), R.maxMarkup + 2)
        let src = render(at + "a&#64;b.c")
        XCTAssertEqual(src.note, R.tooMuchMarkupNote)
        XCTAssertEqual(src.text.string, at + "a&#64;b.c")
    }

    /// Styled runs of `out` (font italic), counted run by run.
    private func italicRuns(_ out: R.Output) -> Int {
        var n = 0
        out.text.enumerateAttribute(.font, in: NSRange(location: 0, length: out.text.length)) { v, _, _ in
            if (v as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true { n += 1 }
        }
        return n
    }

    /// #1211: at most maxStyledRunsPerParagraph styled runs in one paragraph (to its line end); the rest of it is plain,
    /// the next paragraph is styled again. A hard break ends a paragraph; a soft break and a wide row's " | " do not.
    func testStyledRunsPerParagraphCap() {
        let p = R.maxStyledRunsPerParagraph
        XCTAssertEqual(p, 10_000)
        func para(_ n: Int) -> String { (0..<n).map { "*e\($0)*" }.joined(separator: " ") }
        let note = "Too many styles in one paragraph: the rest shown as plain text"
        autoreleasepool {
            let at = render(para(p))
            XCTAssertTrue(at.note == nil, at.note ?? "")
            XCTAssertEqual(italicRuns(at), p, "run \(p) of the paragraph is styled")
        }
        autoreleasepool {
            let over = render(para(p + 1) + "\n\n*next*")
            XCTAssertEqual(over.note, note)
            XCTAssertEqual(italicRuns(over), p + 1, "the paragraph's first \(p), then the next paragraph's one")
            XCTAssertEqual(font(over, "e\(p)")?.fontDescriptor.symbolicTraits.contains(.italic), false, "run \(p + 1) is plain")
            XCTAssertEqual(font(over, "next")?.fontDescriptor.symbolicTraits.contains(.italic), true)
        }
        autoreleasepool {
            let hard = render(para(p) + "\\\n*x*")
            XCTAssertTrue(hard.note == nil, hard.note ?? "")
            XCTAssertEqual(italicRuns(hard), p + 1, "a hard break starts a new paragraph")
        }
        autoreleasepool {
            let soft = render(para(p) + "\n*x*")
            XCTAssertEqual(soft.note, note, "a soft break keeps the paragraph")
            XCTAssertEqual(italicRuns(soft), p)
        }
        autoreleasepool {   // a wide table's cells of one row share a line
            let cols = R.maxTableColumns + 1, perCell = p / cols + 1
            let cell = String(repeating: "*a* ", count: perCell)
            let md = "|" + String(repeating: " h |", count: cols) + "\n|" + String(repeating: "-|", count: cols) + "\n|"
                + String(repeating: " \(cell)|", count: cols)
            let wide = render(md)
            XCTAssertEqual(wide.note, "Too many table columns, styles in one paragraph: the rest shown as plain text")
            XCTAssertEqual(italicRuns(wide), p - (cols - 1), "the \" | \" between two cells takes the last run's style and joins two runs")
        }
    }

    /// #1211 (R1211-2, #1213): an image counts toward maxStyledRunsPerParagraph. Past the bound it is its alt text as plain
    /// text and the loader is not asked; in the next paragraph an image is drawn again. The loader is the test's fake.
    func testImagesCountInTheParagraphBound() throws {
        let p = R.maxStyledRunsPerParagraph
        let note = "Too many styles in one paragraph: the rest shown as plain text"
        func para(_ n: Int) -> String { (0..<n).map { "*e\($0)*" }.joined(separator: " ") }
        let png = try pngData(width: 8, height: 8)
        func attachments(_ out: R.Output) -> Int {
            var n = 0
            out.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.text.length)) { v, _, _ in if v != nil { n += 1 } }
            return n
        }
        autoreleasepool {   // the image is run p + 1: its alt text, plain; the next paragraph's image is drawn
            let loader = Loader()
            loader.image = ImagePolicy.decode(png, maxPixelSize: 8)
            let out = render(para(p) + " ![over](p.png)\n\n![next](q.png)", loader)
            XCTAssertEqual(out.note, note)
            XCTAssertEqual(loader.requests, ["q.png"], "the image past the bound is not requested")
            XCTAssertEqual(attachments(out), 1)
            XCTAssertTrue(out.text.string.contains(" over\n"), "the alt text as plain text, no \"[image: ...]\"")
            XCTAssertTrue(at(out, "over")[.link] == nil)
            XCTAssertEqual(italicRuns(out), p)
            XCTAssertEqual(out.text.attribute(.toolTip, at: out.text.length - 1, effectiveRange: nil) as? String, "next")
        }
        autoreleasepool {   // the image is run p: drawn, and the styled run after it is past the bound
            let loader = Loader()
            loader.image = ImagePolicy.decode(png, maxPixelSize: 8)
            let out = render(para(p - 1) + " ![in](p.png) *last*", loader)
            XCTAssertEqual(out.note, note)
            XCTAssertEqual(loader.requests, ["p.png"])
            XCTAssertEqual(attachments(out), 1)
            XCTAssertEqual(italicRuns(out), p - 1)
            XCTAssertEqual(font(out, "last")?.fontDescriptor.symbolicTraits.contains(.italic), false, "run \(p + 1) is plain")
        }
    }

    /// #1211: the font of each kind of run, by value (the cache of derived fonts keeps every one): headings, emphasis,
    /// strong, both, code, a fragment link, strikethrough, a table's header and body, a list item.
    func testRunFontsByValue() {
        let md = "# H1 *hi* `hc`\n\nP *pi* **pb** ***pbi*** `pc` [pl](#top) ~~ps~~ *pi2* **pb2**\n\n"
            + "| *ti* | **tb** |\n|---|---|\n| `tc` | *tj* |\n\n- *li* `lc` **lb**\n\n> *qi*"
        let out = render(md)
        XCTAssertTrue(out.note == nil, out.note ?? "")
        // (word, point size, bold, italic, monospaced)
        let want: [(String, CGFloat, Bool, Bool, Bool)] = [
            ("H1", 20, true, false, false), ("hi", 20, true, true, false), ("hc", 18, false, false, true),
            ("P ", 15, false, false, false), ("pi ", 15, false, true, false), ("pb ", 15, true, false, false),
            ("pbi", 15, true, true, false), ("pc", 13.5, false, false, true), ("pl", 15, false, false, false),
            ("ps", 15, false, false, false), ("pi2", 15, false, true, false), ("pb2", 15, true, false, false),
            ("ti", 15, true, true, false), ("tb", 15, true, false, false), ("tc", 13.5, false, false, true),
            ("tj", 15, false, true, false), ("li", 15, false, true, false), ("lc", 13.5, false, false, true),
            ("lb", 15, true, false, false), ("qi", 15, false, true, false),
        ]
        for (word, size, bold, italic, mono) in want {
            guard let f = font(out, word) else { XCTFail("no font at \(word)"); continue }
            let t = f.fontDescriptor.symbolicTraits
            XCTAssertEqual(f.pointSize, size, accuracy: 0.01, word)
            XCTAssertEqual([t.contains(.bold), t.contains(.italic), t.contains(.monoSpace)], [bold, italic, mono], word)
        }
        XCTAssertNotNil(at(out, "ps")[.strikethroughStyle])
        XCTAssertNotNil(at(out, "pl")[.link])
    }

    // MARK: Heavy (PROSPER_HEAVY_TESTS=1): budgets wide enough for a loaded machine.

    /// Runs `work` off the main thread to `ceiling` seconds; on a timeout the task is cancelled
    /// (the renderer stops at its next run) and the row fails.
    private func timed(_ name: String, ceiling: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        let done = XCTestExpectation(description: name)
        let start = Date()
        let task = Task.detached { work(); done.fulfill() }
        if XCTWaiter().wait(for: [done], timeout: ceiling) != .completed {
            task.cancel()
            XCTFail("\(name): over \(ceiling) s")
            return
        }
        print("tv1b timing \(name): \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
    }

    private static func layout(_ text: NSAttributedString) {
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: TextViewerTextView.columnWidth, height: .greatestFiniteMagnitude))
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
    }

    /// D5: a 5,000-line document renders, and lays out, within 5 s each.
    func testFiveThousandLines() throws {
        try requireHeavyTests()
        let blocks = ["## Heading", "Some *text* with `code` and a [link](https://example.com).", "- item", "> quote", "    code"]
        let md = (0..<5000).map { blocks[$0 % blocks.count] + " \($0)" }.joined(separator: "\n\n")
        let style = Self.style, doc = Self.document
        let box = OutputBox()
        timed("render 5000 lines", ceiling: 5) { box.set(R.render(md, document: doc, style: style, loader: { _, _, _ in nil })) }
        let out = try XCTUnwrap(box.get())
        XCTAssertNil(out.note)
        timed("layout 5000 lines", ceiling: 5) { Self.layout(out.text) }
    }

    /// #1213: the most forms the caps allow (24,000 at 6 markup each, under maxMarkup; about 750 KB, about 29 MiB of
    /// runs): exactly maxImages slice parses, every form marked; counted, with a wide time ceiling.
    func testImagesInsideLinksAtTheCaps() throws {
        try requireHeavyTests()
        let n = 24_000
        let md = (0..<n).map { "[![i\($0)](p\($0).png)](#top)" }.joined(separator: "\n\n")
        XCTAssertEqual(R.markupCount(md), 6 * n)
        let loader = Loader()
        let style = Self.style, doc = Self.document
        let box = OutputBox()
        timed("render \(n) images inside links", ceiling: 20) {
            box.set(R.render(md, document: doc, style: style, loader: loader.load))
        }
        let out = try XCTUnwrap(box.get())
        XCTAssertEqual(loader.requests.count, R.maxImages, "one slice parse per form up to maxImages, then none")
        XCTAssertEqual(out.text.string.components(separatedBy: "[image: ").count - 1, n, "every form marked")
        XCTAssertEqual(out.note, R.trimmedNote(["links"]))
    }

    /// R5: hostile shapes: no crash, no recursion by depth here, 10 s each to render and lay out.
    func testHostileShapes() throws {
        try requireHeavyTests()
        func table(_ cols: Int, _ rows: Int) -> String {
            let row = "|" + String(repeating: " c |", count: cols)
            return ([row, "|" + String(repeating: "---|", count: cols)] + Array(repeating: row, count: rows)).joined(separator: "\n")
        }
        let shapes: [(String, String)] = [
            ("quote 5000 deep", String(repeating: "> ", count: 5000) + "x"),
            ("list 5000 deep", String(repeating: "- ", count: 5000) + "x"),
            ("list 700 deep by indent", (0..<700).map { String(repeating: " ", count: 2 * $0) + "- x" }.joined(separator: "\n")),
            ("one line of 1 MiB", String(repeating: "word ", count: R.maxSourceBytes / 5)),
            ("table 4x2500", table(4, 2500)),
            ("table 100x100", table(100, 100)),
        ]
        let style = Self.style, doc = Self.document
        for (name, md) in shapes {
            let box = OutputBox()
            timed("render \(name)", ceiling: 10) { box.set(R.render(md, document: doc, style: style, loader: { _, _, _ in nil })) }
            guard let out = box.get() else { continue }
            timed("layout \(name)", ceiling: 10) { Self.layout(out.text) }
        }
    }

    // MARK: Round 2: the app's thread, nesting at the cap, nested inlines, the worst tables.

    /// To stderr, unbuffered: a crash later in the run keeps what was measured before it.
    nonisolated static func fact(_ s: String) { fputs("tv1b fact \(s)\n", stderr) }

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0, peak = 0, done = 0
        private(set) var values: [Int] = []
        func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
        func leave() { lock.lock(); now -= 1; done += 1; lock.unlock() }
        func add(_ v: Int) { lock.lock(); values.append(v); lock.unlock() }
        var state: (peak: Int, done: Int) { lock.lock(); defer { lock.unlock() }; return (peak, done) }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// Runs `work` on its own thread with a `size`-byte stack painted with a pattern, to `ceiling`
    /// seconds, and returns how deep the stack went (KiB, to the page), or nil on a timeout.
    nonisolated static func stackUsed(size: Int = 512 << 20, ceiling: TimeInterval = 60,
                                      _ work: @escaping @Sendable () -> Void) -> Int? {
        let result = Count(), done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
            let bottom = top - UInt(pthread_get_stacksize_np(pthread_self())) + 16384
            var here = 0
            let paintEnd = withUnsafeMutablePointer(to: &here) { UInt(bitPattern: $0) } & ~UInt(4095) - 65536
            guard paintEnd > bottom, let base = UnsafeMutableRawPointer(bitPattern: bottom) else { done.signal(); return }
            memset(base, 0xA5, Int(paintEnd - bottom))
            work()
            let page = [UInt8](repeating: 0xA5, count: 4096)
            var p = bottom
            while p < paintEnd, memcmp(UnsafeRawPointer(bitPattern: p)!, page, 4096) == 0 { p += 4096 }
            result.add(Int(top - p) / 1024)
            done.signal()
        }
        thread.stackSize = size
        thread.start()
        guard done.wait(timeout: .now() + ceiling) == .success else { return nil }
        return result.all.first
    }

    /// The thread the app renders on (TextViewerModel.refresh: Task.detached(priority: .userInitiated)),
    /// its stack, and how many such threads run at once.
    func testAppThreadFacts() throws {
        let seen = Count()
        let done = XCTestExpectation(description: "detached")
        Task.detached(priority: .userInitiated) {
            seen.add(pthread_main_np() != 0 ? 1 : 0)
            seen.add(pthread_get_stacksize_np(pthread_self()) / 1024)
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 10), .completed)
        let values = seen.all
        XCTAssertEqual(values.count, 2)
        guard values.count == 2 else { return }
        XCTAssertEqual(values[0], 0, "off the main thread")
        Self.fact("detached userInitiated stack \(values[1]) KiB; main stack \(pthread_get_stacksize_np(pthread_self()) / 1024) KiB; activeProcessorCount \(ProcessInfo.processInfo.activeProcessorCount)")
        Self.poolStackKiB = values[1]
        // How many detached tasks run at once: each blocks its thread 0.3 s.
        let width = Count(), n = 4 * ProcessInfo.processInfo.activeProcessorCount
        for _ in 0..<n { Task.detached(priority: .userInitiated) { width.enter(); usleep(300_000); width.leave() } }
        let deadline = Date().addingTimeInterval(60)
        while width.state.done < n, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(width.state.done, n)
        Self.fact("pool width (detached userInitiated tasks blocked at once) \(width.state.peak) of \(n) launched")
        XCTAssertGreaterThan(Self.poolStackKiB, 0)
    }

    nonisolated(unsafe) static var poolStackKiB = 0   // set by testAppThreadFacts

    /// Renders `md` on a painted 512 MiB stack (how deep it goes), then, if that fits a pool
    /// thread with 64 KiB to spare, through `timed` (a detached task, the app's path) and lays it out.
    private func onAppThread(_ name: String, _ md: String, ceiling: TimeInterval = 10) -> R.Output? {
        let style = Self.style, doc = Self.document
        let start = Date()
        guard let used = Self.stackUsed({ _ = R.render(md, document: doc, style: style, loader: { _, _, _ in nil }) }) else {
            XCTFail("\(name): no render within 60 s on the measuring thread")
            return nil
        }
        Self.fact("\(name): \(md.utf8.count) bytes, stack \(used) KiB, render \(String(format: "%.3f", Date().timeIntervalSince(start))) s on the measuring thread")
        guard used + 64 <= Self.poolStackKiB else {
            XCTFail("\(name): needs \(used) KiB of stack; a pool thread has \(Self.poolStackKiB) KiB")
            return nil
        }
        let box = OutputBox()
        timed("render \(name)", ceiling: ceiling) { box.set(R.render(md, document: doc, style: style, loader: { _, _, _ in nil })) }
        guard let out = box.get() else { return nil }
        timed("layout \(name)", ceiling: ceiling) { Self.layout(out.text) }
        return out
    }

    /// The bound at the cap, exactly: quotes, lists by indent and both mixed on one line.
    func testNestingBoundAtTheCap() {
        XCTAssertEqual(R.nestingBound(Self.quotes(128)), 128)
        XCTAssertEqual(R.nestingBound(Self.listByIndent(128)), 128)
        XCTAssertEqual(R.nestingBound(Self.mixed(128)), 128, "a list marker's space is part of the marker")
        XCTAssertEqual(R.nestingBound(Self.mixed(129)), 129)
        XCTAssertEqual(R.nestingBound("- - x"), 2)
        XCTAssertEqual(R.nestingBound("1.\t2. x"), 2)
        XCTAssertNil(render(Self.mixed(128)).note)
        XCTAssertEqual(render(Self.mixed(129)).note, R.tooDeepNote)
    }

    static func quotes(_ d: Int) -> String { String(repeating: "> ", count: d) + "x" }
    static func listByIndent(_ d: Int) -> String { (0..<d).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n") }
    static func mixed(_ d: Int) -> String { (0..<d).map { $0 % 2 == 0 ? "> " : "- " }.joined() + "x" }

    /// Round 2 item 2: up to 50,000 cells a document are NSTextTable cells; the row that passes the
    /// cap, and every later one, is joined text.
    func testTableCellCap() {
        func oneColumn(_ cells: Int) -> String { "|h|\n|-|\n" + String(repeating: "|c|\n", count: cells - 1) }
        let at = render(oneColumn(R.maxTableCells))
        XCTAssertNil(at.note, "nothing trimmed at the cap")
        XCTAssertTrue(inTable(at, at: 0))
        XCTAssertTrue(inTable(at, at: at.text.length - 1), "cell 50,000 is a table cell")
        let over = render(oneColumn(R.maxTableCells + 1))
        XCTAssertTrue(inTable(over, at: 0))
        XCTAssertFalse(inTable(over, at: over.text.length - 1), "cell 50,001 is joined text")
        XCTAssertTrue(over.text.string.hasSuffix("c\nc"), String(over.text.string.suffix(8)))
        XCTAssertEqual(over.note, "Too many table cells: the rest shown as plain text")
    }

    /// Round 2 item 2: at most maxLinks (#1155: 8,000) links a document are links; the next is its plain text.
    func testLinkCountCap() {
        let out = render((0...R.maxLinks).map { "[l\($0)](https://example.com/\($0))" }.joined(separator: " "))
        var linked: [String] = []
        out.text.enumerateAttribute(.link, in: NSRange(location: 0, length: out.text.length)) { v, range, _ in
            if v != nil { linked.append((out.text.string as NSString).substring(with: range)) }
        }
        XCTAssertEqual(linked.count, R.maxLinks)
        XCTAssertEqual(linked.last, "l\(R.maxLinks - 1)")
        XCTAssertEqual(out.note, "Too many links: the rest shown as plain text")
        XCTAssertNil(render((1...R.maxLinks).map { "[l\($0)](https://example.com/\($0))" }.joined(separator: " ")).note,
                     "nothing trimmed at the cap")
        let last = (out.text.string as NSString).range(of: "l\(R.maxLinks)")
        XCTAssertNotEqual(last.location, NSNotFound)
        guard last.location != NSNotFound else { return }
        XCTAssertTrue(out.text.attribute(.link, at: last.location, effectiveRange: nil) == nil)
        XCTAssertTrue(out.text.attribute(.toolTip, at: last.location, effectiveRange: nil) == nil)
    }

    /// Round 2 item 2: at most 50,000 inline-styled runs a document; later runs take the block's style.
    func testStyledRunCap() {
        // #1211: in paragraphs of 1,000 runs, under the per-paragraph bound
        func styled(_ r: ClosedRange<Int>) -> String { r.map { "*e\($0)*" + ($0 % 1000 == 999 ? "\n\n" : " ") }.joined() }
        let out = render(styled(0...R.maxStyledRuns))
        func italic(_ word: String) -> Bool? {
            let r = (out.text.string as NSString).range(of: word)
            guard r.location != NSNotFound, let font = out.text.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont else { return nil }
            return font.fontDescriptor.symbolicTraits.contains(.italic)
        }
        XCTAssertEqual(italic("e0 "), true)
        XCTAssertEqual(italic("e49999"), true, "run 50,000 is styled")
        XCTAssertEqual(italic("e50000"), false, "run 50,001 is the paragraph's plain text")
        XCTAssertEqual(out.note, "Too many styles: the rest shown as plain text")
        XCTAssertNil(render(styled(1...R.maxStyledRuns)).note, "nothing trimmed at the cap")
        // Several caps: one note, each named once, in the order first hit.
        let both = render((0...R.maxLinks).map { "[l\($0)](https://example.com/\($0))" }.joined(separator: " ")
                          + "\n\n" + String(repeating: String(repeating: "*e* ", count: 1000) + "\n\n", count: R.maxStyledRuns / 1000))
        XCTAssertEqual(both.note, "Too many links, styles: the rest shown as plain text")
    }

    /// The stack meter itself: 2,000 frames of at least 1 KiB read as at least 2,000 KiB.
    func testStackMeterSeesDeepRecursion() {
        @Sendable func deep(_ n: Int) -> Int {
            withUnsafeTemporaryAllocation(byteCount: 1024, alignment: 8) { buf in
                buf.storeBytes(of: n, as: Int.self)
                return n == 0 ? 0 : deep(n - 1) + buf.load(as: Int.self)
            }
        }
        let used = Self.stackUsed { _ = deep(2000) }
        Self.fact("stack meter self-check: 2000 frames of 1 KiB read \(used.map { "\($0)" } ?? "nil") KiB")
        XCTAssertGreaterThanOrEqual(used ?? 0, 2000)
        XCTAssertLessThan(Self.stackUsed { _ = deep(1) } ?? Int.max, 200, "a shallow call reads shallow")
    }

    /// Round 2 item 1: block nesting at 127, at the cap (128) and at the first refused depth (129),
    /// on the app's thread, one line and 2,000 lines each.
    func testBlockNestingAtTheCapOnTheAppThread() throws {
        try requireHeavyTests()
        if Self.poolStackKiB == 0 { try testAppThreadFacts() }
        for d in [127, 128, 129] {
            let deepList = String(repeating: "  ", count: d - 1) + "- y"
            let shapes: [(String, String)] = [
                ("quotes \(d)", Self.quotes(d)),
                ("list by indent \(d)", Self.listByIndent(d)),
                ("mixed \(d)", Self.mixed(d)),
                ("quotes \(d) x 2000 lines", Array(repeating: Self.quotes(d), count: 2000).joined(separator: "\n")),
                ("list by indent \(d) + 2000 lines", Self.listByIndent(d) + "\n" + Array(repeating: deepList, count: 2000).joined(separator: "\n")),
                ("mixed \(d) x 2000 lines", Array(repeating: Self.mixed(d), count: 2000).joined(separator: "\n")),
            ]
            for (name, md) in shapes {
                let out = onAppThread(name, md)
                XCTAssertEqual(out?.note, d <= R.maxNesting ? nil : R.tooDeepNote, name)
            }
        }
    }

    /// Round 2 item 1 (b): inline shapes at 1,000 and 50,000 units and as many as 1 MiB holds.
    static func inlineShapes(_ k: Int?) -> [(String, String)] {
        func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
        // k nil: as many units as fit in 1 MiB
        func n(_ unit: Int) -> Int { k ?? (R.maxSourceBytes - 16) / unit }
        func growingTicks(_ bytes: Int) -> String {
            var parts: [String] = [], total = 0, len = 1
            while total + len + 2 <= bytes { parts.append(rep("`", len) + "a"); total += len + 2; len += 1 }
            return parts.joined(separator: " ")
        }
        let defs = (0..<n(14)).map { "[r\($0)]: /u\n" }.joined()
        return [
            ("emphasis nested *a _a", rep("*a _a ", n(12)) + "x" + rep(" a_ a*", n(12))),
            ("emphasis unclosed *a _a", rep("*a _a ", n(6))),
            ("strong nested **a", rep("**a ", n(8)) + "x" + rep(" a**", n(8))),
            ("brackets nested", rep("[", n(2)) + rep("]", n(2))),
            ("link text nested", rep("[a ", n(7)) + "x" + rep("](u)", n(7))),
            ("images nested", rep("![", n(10)) + "x" + rep("](p.png)", n(10))),
            ("backtick runs growing", growingTicks(k ?? R.maxSourceBytes - 16)),
            ("< runs", rep("<", n(1))),
            ("unclosed inline html", rep("<a b=\"c\" ", n(9))),
            ("backslashes", rep("\\", n(1))),
            ("only *", rep("*", n(1))),
            ("only _", rep("_", n(1))),
            ("only [", rep("[", n(1))),
            ("only `", rep("`", n(1))),
            ("unclosed [ then ](", rep("[", n(3)) + rep("](", n(3))),
            ("[a]( repeated", rep("[a](", n(4))),
            ("*a no closers", rep("*a", n(2))),
            ("link reference definitions", defs + "[r0] [r1]"),
            ("one reference defined again", rep("[r]: /u\n", n(8)) + "[r]"),
        ]
    }

    func testInlineShapesOnTheAppThread() throws {
        try requireHeavyTests()
        if Self.poolStackKiB == 0 { try testAppThreadFacts() }
        for k in [1000, 50000, nil] {
            for (name, md) in Self.inlineShapes(k) {
                XCTAssertLessThanOrEqual(md.utf8.count, R.maxSourceBytes, name)
                // #1187: over ten times the slowest shape under the markup cap (0.80 s here, 1.41 s on CI)
                let out = onAppThread("\(name) x \(k.map { "\($0)" } ?? "1 MiB")", md, ceiling: 15)
                // parsed, never the source fallback (a cap's "Too many ..." note may show: Round 3 F2), unless over the markup cap
                if R.markupCount(md) > R.maxMarkup {
                    XCTAssertEqual(out?.note, R.tooMuchMarkupNote, name)
                } else {
                    XCTAssertFalse([R.tooLargeNote, R.tooDeepNote, R.unparsedNote, R.tooMuchMarkupNote].contains(out?.note ?? ""), name)
                }
            }
        }
    }

    /// Round 2 item 2: the worst tables the caps allow, against flat shapes of the same size. Layout
    /// is measured on the main thread, where TextViewerTextView.show runs it. #1187: every shape renders as
    /// Markdown under maxMarkup (its count asserted). A table just under maxMarkup holds over 75,000 cells,
    /// about 90 MiB at the measured 1.2 KiB a run, so the new table shapes hold 32,000 cells (about 48 MiB).
    func testWorstTables() throws {
        try requireHeavyTests()
        func table(_ cols: Int, _ rows: Int) -> String {
            let head = "|" + String(repeating: "h|", count: cols) + "\n|" + String(repeating: "-|", count: cols) + "\n"
            return head + String(repeating: "|" + String(repeating: "a|", count: cols) + "\n", count: rows)
        }
        let shapes: [(name: String, md: String, marks: Int, table: Bool)] = [
            ("table 1 x 32000 cells", table(1, 31_999), 64_002, true),
            ("table 8 x 4000 cells", table(8, 3_999), 36_009, true),
            ("table 64 x 500 cells", table(64, 499), 32_565, true),
            ("table 1 x 50000 cells, at the cap", table(1, R.maxTableCells - 1), 100_002, true),
            ("table 8 x 6250, at the cap", table(8, R.maxTableCells / 8 - 1), 56_259, true),
            ("table 64 x 781, at the cap", table(64, R.maxTableCells / 64 - 1), 50_830, true),
            ("32000 4-byte list items", String(repeating: "- a\n", count: 32_000), 64_000, false),
            ("32000 one-letter paragraphs", String(repeating: "a\n\n", count: 32_000), 64_000, false),
            ("16000 short links", String(repeating: "[a](b) ", count: 16_000), 32_002, false),
        ]
        let style = Self.style, doc = Self.document
        for (name, md, marks, isTable) in shapes {
            XCTAssertEqual(R.markupCount(md), marks, name)
            let box = OutputBox()
            let before = Self.footprintMiB()
            timed("render \(name)", ceiling: 30) { box.set(R.render(md, document: doc, style: style, loader: { _, _, _ in nil })) }
            guard let out = box.get() else { continue }
            let held = Self.footprintMiB() - before
            XCTAssertTrue(out.note != R.tooMuchMarkupNote, name)
            if isTable { XCTAssertTrue(inTable(out, at: 0) && inTable(out, at: out.text.length - 1), "\(name): drawn as table cells") }
            let t0 = Date()
            timed("layout \(name)", ceiling: 30) { Self.layout(out.text) }
            let offMain = Date().timeIntervalSince(t0)
            guard offMain < 30 else { continue }   // a main-thread layout cannot be cancelled: only a bounded one
            let start = Date()
            Self.layout(out.text)   // on main, as show() does
            Self.fact("\(name): \(md.utf8.count) bytes, \(marks) marks, \(out.text.length) characters, output footprint \(String(format: "%.1f", held)) MiB, layout \(String(format: "%.3f", offMain)) s off main, \(String(format: "%.3f", Date().timeIntervalSince(start))) s on main")
        }
        // The plain-text path (a .txt file, or Markdown shown as source) for comparison.
        let plain = R.plain(String(repeating: "abc\n", count: R.maxSourceBytes / 4), style: style)
        let p0 = Date()
        Self.layout(plain.text)
        Self.fact("plain text, 1 MiB of 4-byte lines: \(String(format: "%.3f", Date().timeIntervalSince(p0))) s on main")
        // Links laid out without the renderer (so without its cap), on main: the cost per link.
        for n in [1000, 2000, 4000, 8000] {
            let s = NSMutableAttributedString()
            for i in 0..<n {
                let u = "https://example.com/\(i)"
                s.append(NSAttributedString(string: "link", attributes: [.link: URL(string: u)!, .toolTip: u,
                                                                          .underlineStyle: NSUnderlineStyle.single.rawValue]))
                s.append(NSAttributedString(string: " "))
            }
            let t0 = Date()
            Self.layout(s)
            let secs = Date().timeIntervalSince(t0)
            Self.fact("\(n) links, no cap: \(String(format: "%.3f", secs)) s on main")
            if secs > 10 { break }
        }
    }

    /// #1211: one paragraph at the per-paragraph bound, emphasis and inline code, rendered and laid out on main (as show()
    /// does), and the same paragraph with twice the runs (the rest plain). Up to 40,001 parsed runs: under 48 MiB at 1.2 KiB a
    /// run. Measured here: render 0.26 s and layout 0.07 s at the bound; the 10 s ceilings are over ten times that.
    func testStyledParagraphAtTheBound() throws {
        try requireHeavyTests()
        let style = Self.style, doc = Self.document, p = R.maxStyledRunsPerParagraph
        for (name, unit) in [("emphasis", "*a* "), ("inline code", "`a` ")] {
            for n in [p, 2 * p] {
                try autoreleasepool {
                    let box = OutputBox()
                    timed("render \(name) x \(n)", ceiling: 10) { box.set(R.render(String(repeating: unit, count: n), document: doc, style: style, loader: { _, _, _ in nil })) }
                    let out = try XCTUnwrap(box.get())
                    XCTAssertEqual(out.note, n > p ? "Too many styles in one paragraph: the rest shown as plain text" : nil, name)
                    let start = Date()
                    Self.layout(out.text)   // on main, as show() does: not cancellable, bounded by the cap
                    let secs = Date().timeIntervalSince(start)
                    Self.fact("\(name) x \(n) in one paragraph: layout \(String(format: "%.3f", secs)) s on main")
                    XCTAssertLessThan(secs, 10, name)
                }
            }
        }
    }

    /// phys_footprint in MiB (the LlamaInlineEngineTests pattern); -1 on failure.
    nonisolated static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: R.Output?
        func set(_ v: R.Output) { lock.lock(); value = v; lock.unlock() }
        func get() -> R.Output? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// #1236: the plain render cuts a text whose paragraph is longer than the cap, at a whole character, with a note. Pure
/// rows with a small cap passed in (no file, no view, nothing over a few MiB).
extension MarkdownRendererTests {

    private func shown(_ text: String, cap: Int, note: String? = nil) -> (String, String?) {
        let out = R.plain(text, style: Self.style, note: note, maxParagraphUnits: cap)
        return (out.text.string, out.note)
    }

    func testCutOneUnitOverTheCapAndWholeAtTheCap() {
        let over = shown(String(repeating: "a", count: 9), cap: 8)
        XCTAssertEqual(over.0, String(repeating: "a", count: 8), "one unit over: cut at the cap")
        XCTAssertEqual(over.1, R.cutNote(8))
        let at = String(repeating: "a", count: 8) + "\n" + String(repeating: "b", count: 8)
        XCTAssertTrue(R.paragraphCut(at, cap: 8) == nil, "every paragraph at the cap exactly")
        let whole = shown(at, cap: 8)
        XCTAssertEqual(whole.0, at, "the same text as today")
        XCTAssertTrue(whole.1 == nil, "no note")
        XCTAssertTrue(shown(at, cap: 8, note: R.tooDeepNote).1 == R.tooDeepNote, "a note given is kept as is")
    }

    /// The cap lands inside a character: the shown text ends before it. Each literal written as escapes.
    func testCutNeverSplitsACharacter() {
        let a = { (n: Int) in String(repeating: "a", count: n) }
        let cases: [(what: String, text: String, cap: Int, shown: String)] = [
            ("a 4-byte character", a(7) + "\u{1D400}" + "z", 8, a(7)),
            ("a joined emoji", a(4) + "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}" + "z", 8, a(4)),
            ("a flag (two regional indicators)", a(6) + "\u{1F1E7}\u{1F1EC}" + "z", 8, a(6)),
            ("a base letter and a combining mark", a(7) + "e\u{0301}" + "z", 8, a(7)),
            ("a 4-byte character at a cap of 1", "\u{1D400}", 1, ""),
            ("a whole character just under the cap", a(6) + "\u{1D400}" + "z", 8, a(6) + "\u{1D400}"),
        ]
        for c in cases {
            let (text, note) = shown(c.text, cap: c.cap)
            XCTAssertEqual(text, c.shown, c.what)
            XCTAssertEqual(text.utf16.count, c.shown.utf16.count, c.what)
            XCTAssertEqual(note, R.cutNote(c.cap), c.what)
        }
    }

    /// A character longer than the walk back (256 units of combining marks) is cut at a scalar at the cap; a shorter
    /// run of marks that starts within reach moves the cut back to its base letter.
    func testALongRunOfMarksIsCutAtAScalar() {
        let marks = { (n: Int) in String(repeating: "\u{0301}", count: n) }
        let far = String(repeating: "x", count: 10) + "a" + marks(600)
        let cut = shown(far, cap: 400).0
        XCTAssertEqual(cut.utf16.count, 400, "no character start within 256 units: a scalar boundary at the cap")
        XCTAssertTrue(cut.unicodeScalars.last == "\u{0301}")
        let near = String(repeating: "x", count: 300) + "a" + marks(600)
        XCTAssertEqual(shown(near, cap: 400).0, String(repeating: "x", count: 300), "the base letter starts within reach")
        XCTAssertEqual(shown("a" + marks(300), cap: 8).0, "", "the paragraph's first character is longer than the cap")
    }

    func testShortLinesThenALongLine() {
        let text = "ab\r\ncd\n" + String(repeating: "x", count: 20) + "\nafter\n"
        let (cut, note) = shown(text, cap: 8)
        XCTAssertEqual(cut, "ab\r\ncd\n" + String(repeating: "x", count: 8), "the short lines whole, the long one's first cap units, nothing after")
        XCTAssertEqual(note, R.cutNote(8))
    }

    /// What ends a paragraph is what TextKit 1 takes (NSString's paragraphRange): a literal table, one row per character,
    /// each checked against paragraphRange too. Six units, the character, six units: a cap of 8 cuts only one paragraph.
    func testParagraphSeparatorsAsTextKitSeesThem() {
        let table: [(name: String, sep: String, ends: Bool)] = [
            ("LF", "\n", true), ("CR", "\r", true), ("CR LF", "\r\n", true), ("U+2029", "\u{2029}", true),
            ("U+2028", "\u{2028}", false), ("U+0085", "\u{0085}", false),
        ]
        for row in table {
            let text = "aaaaaa" + row.sep + "bbbbbb"
            let first = (text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            XCTAssertEqual(first.length < (text as NSString).length, row.ends, "\(row.name): NSString's paragraphRange")
            let (cut, note) = shown(text, cap: 8)
            if row.ends {
                XCTAssertEqual(cut, text, "\(row.name) ends a paragraph: nothing cut")
                XCTAssertTrue(note == nil, row.name)
            } else {
                XCTAssertEqual(cut, "aaaaaa" + row.sep + "b", "\(row.name) does not end one: a 13-unit paragraph, cut at 8")
                XCTAssertEqual(note, R.cutNote(8), row.name)
            }
        }
        // Bare "\r" lines under the cap are not cut; one paragraph of U+2028-joined lines over it is.
        XCTAssertTrue(R.paragraphCut(Array(repeating: "abcdefgh", count: 50).joined(separator: "\r"), cap: 8) == nil)
        XCTAssertTrue(R.paragraphCut(Array(repeating: "abc", count: 3).joined(separator: "\u{2028}"), cap: 8) != nil)
    }

    /// No content traps: empty, only separators, a replacement character from a lossy decode, caps of 0 and 1, a negative cap.
    func testEdgeTextsDoNotTrap() {
        XCTAssertTrue(shown("", cap: 0) == ("", nil))
        XCTAssertTrue(shown("\n\r\n\u{2029}\r", cap: 0) == ("\n\r\n\u{2029}\r", nil))
        XCTAssertTrue(shown("ab", cap: 0) == ("", R.cutNote(0)))
        XCTAssertTrue(shown("\n\nab", cap: 1) == ("\n\na", R.cutNote(1)))
        XCTAssertTrue(shown("\u{FFFD}\u{FFFD}", cap: 1) == ("\u{FFFD}", R.cutNote(1)))
        XCTAssertTrue(shown(String(decoding: [0x61, 0xFF, 0x62], as: UTF8.self), cap: 2).0 == "a\u{FFFD}")
        XCTAssertTrue(shown("ab", cap: -5).0 == "", "a negative cap is taken as 0")
    }

    func testCutNoteLiteralAndWithAnotherNote() {
        XCTAssertEqual(R.cutNote(R.maxParagraphUnits),
                       "The rest of the file is not shown: a line is longer than 1,048,576 characters")
        XCTAssertEqual(R.maxParagraphUnits, 1_048_576)
        XCTAssertEqual(shown(String(repeating: "a", count: 9), cap: 8, note: R.tooLargeNote).1,
                       "The rest of the file is not shown: a line is longer than 8 characters \u{00B7} Over 1 MiB: shown as source")
    }

    /// A Markdown file over the source cap is shown as source through the plain render: at the product cap, one line of
    /// cap + 64 units shows cap units with both notes. About 1 MiB of source and 2 MiB of shown text; no view.
    func testMarkdownOverTheSourceCapWithALongLineIsCut() {
        let source = String(repeating: "x", count: R.maxParagraphUnits + 64)
        XCTAssertGreaterThan(source.utf8.count, R.maxSourceBytes)
        let out = R.render(source, document: Self.document, style: Self.style, loader: { _, _, _ in nil })
        XCTAssertEqual(out.text.length, R.maxParagraphUnits)
        XCTAssertEqual(out.note, R.cutNote(R.maxParagraphUnits) + " \u{00B7} " + R.tooLargeNote)
    }

    /// Rendered Markdown needs no cut: a code block of one line filling the 1 MiB source cap renders a paragraph under
    /// the paragraph cap (UTF-16 units are never more than UTF-8 bytes).
    func testRenderedCodeLineUnderTheSourceCapIsUnderTheCap() {
        let line = String(repeating: "a", count: R.maxSourceBytes - 9)
        let source = "```\n" + line + "\n```\n"
        XCTAssertEqual(source.utf8.count, R.maxSourceBytes)
        let out = R.render(source, document: Self.document, style: Self.style, loader: { _, _, _ in nil })
        XCTAssertTrue(out.note == nil, "rendered, not shown as source")
        XCTAssertGreaterThanOrEqual(out.text.length, line.utf16.count, "the code line is shown")
        XCTAssertTrue(R.paragraphCut(out.text.string, cap: R.maxParagraphUnits) == nil, "no rendered paragraph over the cap")
        Self.fact("#1236: a one-line code block at the source cap renders a \(line.utf16.count)-unit paragraph, cap \(R.maxParagraphUnits)")
    }
}

/// #1180 round 3: the riders of entry 1236 and of entries 1163 and 1229. Pure rows (no file, no view); the cut rows pass a
/// small cap, the two rows at the source cap hold about 1 MiB of source and 2 MiB of rendered text each.
extension MarkdownRendererTests {

    private static func flags(_ n: Int) -> String { String(repeating: "\u{1F1E7}\u{1F1EC}", count: n) }

    /// N1236-b (QA 983): the cut window starts more than 256 units into a run of flags, where its own pairing is off by
    /// one: the count back from the cut keeps every flag whole. "x" then 140 flags: flag k starts at unit 1 + 4k, so a
    /// cap of 1 + 4k + 2 lands on its second half.
    func testCutInsideALongRunOfFlagsKeepsWholeFlags() {
        let text = "x" + Self.flags(140)
        for k in [100, 101, 139] {
            let cap = 1 + 4 * k + 2
            let (cut, note) = shown(text, cap: cap)
            XCTAssertEqual(cut, "x" + Self.flags(k), "flag \(k): the shown text ends with a whole flag")
            XCTAssertEqual(cut.utf16.count, 1 + 4 * k, "flag \(k)")
            XCTAssertEqual(note, R.cutNote(cap))
        }
        XCTAssertEqual(shown(text, cap: 1 + 4 * 100).0, "x" + Self.flags(100), "a cap on a first half: the cut is already there")
    }

    /// N1236-b, hostile texts: a run longer than the count's bound, an indicator at the paragraph start, a lone surrogate
    /// half (a Swift literal cannot hold one: built from UTF-16 units, once repaired by String(decoding:), once kept by
    /// NSString). Nothing traps and the shown text is at most the cap (and a prefix of the repaired text).
    func testFlagCountOnHostileTexts() {
        // 2,200 flags; the cut 4,201 indicators in: past maxIndicatorRun (4,096) the window's cut is kept, which here
        // splits a flag, as before #1180.
        let long = "x" + Self.flags(2_200), cap = 1 + 4 * 2_100 + 2
        XCTAssertGreaterThan(2 * 2_100 + 1, R.maxIndicatorRun)
        let past = shown(long, cap: cap).0
        XCTAssertEqual(past.utf16.count, cap, "past the bound: the cut at the cap, on a second half")
        XCTAssertTrue(long.utf16.starts(with: past.utf16))
        XCTAssertEqual(shown("\u{1F1E7}\u{1F1EC}\u{1F1E7}", cap: 2).0, "", "a flag at the paragraph start")
        XCTAssertEqual(shown("ab\n" + Self.flags(3), cap: 2).0, "ab\n", "the count stops at the paragraph start")
        XCTAssertEqual(shown("\u{1F1E7}" + "z", cap: 1).0, "", "a lone indicator alone")
        let units: [UInt16] = [0x78, 0xD83C] + (0..<200).flatMap { _ in [UInt16(0xD83C), 0xDDE7] } + [0xDDE7]
        let repaired = String(decoding: units, as: UTF16.self)
        let kept = units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) } as String
        for (name, text) in [("repaired", repaired), ("kept", kept)] {
            for cap in [0, 1, 2, 3, 4, 300, 301, 401, 402, 403] {
                let cut = shown(text, cap: cap).0
                XCTAssertLessThanOrEqual(cut.utf16.count, cap, "\(name) \(cap)")
                // The slice of `kept` is a native String: its lone halves come back as U+FFFD, so only `repaired` is compared.
                if name == "repaired" { XCTAssertTrue(text.utf16.starts(with: cut.utf16), "\(name) \(cap)") }
            }
        }
    }

    /// QA 983, the missing row: a Markdown source over the source cap made of short lines (80 units, none near the
    /// paragraph cap) is shown whole as source, with the too-large note alone.
    func testMarkdownOverTheSourceCapOfShortLinesIsShownWhole() {
        let line = String(repeating: "a", count: 79) + "\n"
        let source = String(repeating: line, count: R.maxSourceBytes / 80 + 1)
        XCTAssertGreaterThan(source.utf8.count, R.maxSourceBytes)
        let out = R.render(source, document: Self.document, style: Self.style, loader: { _, _, _ in nil })
        XCTAssertEqual(out.note, R.tooLargeNote, "no cut note")
        XCTAssertEqual(out.text.length, source.utf16.count, "the full length")
        XCTAssertTrue(out.text.string == source, "the source as is")
    }

    /// The longest paragraph of `s` in UTF-16 units, paragraphs ended as paragraphCut ends them.
    private static func longestParagraph(_ s: String) -> Int {
        var longest = 0, run = 0
        for u in s.utf16 {
            if u == 0x0A || u == 0x0D || u == 0x2029 { run = 0 } else { run += 1; longest = max(longest, run) }
        }
        return longest
    }

    /// N1236-d: a one-item list whose item fills the source cap. Each marker the renderer draws ("•\t", "1.\t", nine
    /// nested markers sharing stops past depth 8) replaces source bytes at least as long, so the longest rendered
    /// paragraph is predicted at the source cap exactly (N = 0); the bound is the cap plus 8 units, a margin of 8.
    func testRenderedListItemAtTheSourceCapStaysNearTheCap() {
        for prefix in ["- ", "1. ", String(repeating: "- ", count: 9)] {
            let source = prefix + String(repeating: "a", count: R.maxSourceBytes - prefix.utf8.count)
            XCTAssertEqual(source.utf8.count, R.maxSourceBytes)
            let out = R.render(source, document: Self.document, style: Self.style, loader: { _, _, _ in nil })
            XCTAssertTrue(out.note == nil, "\(prefix.debugDescription): rendered, not shown as source")
            let longest = Self.longestParagraph(out.text.string)
            XCTAssertLessThanOrEqual(longest, R.maxSourceBytes + 8, prefix.debugDescription)
            XCTAssertGreaterThanOrEqual(longest, R.maxSourceBytes - prefix.utf8.count, "the item's text is shown")
            Self.fact("N1236-d: \(prefix.debugDescription) item at the source cap: longest paragraph \(longest) units, source cap plus \(longest - R.maxSourceBytes)")
        }
    }

    /// N1163-m: every block between an item's first and last block carries that item in its intent (raw HTML, a comment,
    /// code, a quote, a rule, a table, a reference definition). So a block with no items (start(), MarkdownRenderer.swift,
    /// the line before `let fresh`) has left every list, and the next item is fresh whatever openItems held: the guard
    /// "if !items.isEmpty" was dead and is gone. Under the guard's absence a shape that broke this rule would draw the
    /// item's marker again before "b"; each shape is also rendered.
    func testEveryBlockInsideAnItemCarriesTheItem() {
        func isItem(_ c: PresentationIntent.IntentType) -> Bool { if case .listItem = c.kind { true } else { false } }
        let shapes = ["- a\n\n  <div>x</div>\n\n  b", "- a\n  <div>x</div>\n\n  b", "- a\n\n  <!-- c -->\n\n  b",
                      "1. a\n\n   ```\n   c\n   ```\n\n   b", "- a\n\n  > q\n\n  b", "- a\n\n  ***\n\n  b",
                      "- a\n\n  | h |\n  |---|\n  | c |\n\n  b", "- a\n\n  [r]: #top\n\n  b", "- a\n\n      code\n\n  b"]
        for md in shapes {
            guard let parsed = try? AttributedString(markdown: md, options: R.parsingOptions(for: md)) else {
                XCTFail("\(md.debugDescription): not parsed"); continue
            }
            let items = parsed.runs.map { run in run.presentationIntent?.components.filter(isItem).map(\.identity) ?? [] }
            let first = items.firstIndex { !$0.isEmpty }, last = items.lastIndex { !$0.isEmpty }
            XCTAssertTrue(first != nil && last != nil && first! < last!, "\(md.debugDescription): the item spans runs")
            if let first, let last, first <= last {
                XCTAssertTrue(items[first...last].allSatisfy { !$0.isEmpty }, "\(md.debugDescription): a run with no item inside it: \(items)")
            }
            let s = render(md).text.string
            XCTAssertTrue(s.hasSuffix("b"), "\(md.debugDescription): \(s.debugDescription)")
            XCTAssertFalse(s.contains("\tb"), "\(md.debugDescription): one marker: \(s.debugDescription)")
        }
    }

    /// N1229-a: other first-line syntax after two leading BOMs draws as with one and as with none (render drops every
    /// leading BOM before the parse): a list, a quote, a code fence, a reference definition.
    func testTwoLeadingBOMsBeforeOtherFirstLineSyntax() {
        let b = "\u{FEFF}"
        func same(_ md: String) -> R.Output {
            let two = render(b + b + md)
            XCTAssertEqual(two.text.string, render(b + md).text.string, "\(md.debugDescription): as with one BOM")
            XCTAssertEqual(two.text.string, render(md).text.string, "\(md.debugDescription): as with none")
            return two
        }
        XCTAssertEqual(same("- one\n- two").text.string, "\u{2022}\tone\n\u{2022}\ttwo", "a list")
        let quote = same("> quoted")
        XCTAssertEqual(quote.text.string, "quoted", "a quote")
        XCTAssertEqual(para(quote, "quoted")?.textBlocks.count, 1, "its bar")
        let fence = same("```\ncode\n```")
        XCTAssertTrue(fence.text.string.hasPrefix("code"), fence.text.string.debugDescription)
        XCTAssertTrue(font(fence, "code")?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true, "a code fence")
        XCTAssertEqual(para(fence, "code")?.textBlocks.count, 1, "its block")
        let ref = same("[r]: #top\n\n[go][r]")
        XCTAssertEqual(ref.text.string, "go", "a reference definition draws nothing")
        XCTAssertEqual(linkString(ref, at: 0), "#top", "its link")
    }
}
