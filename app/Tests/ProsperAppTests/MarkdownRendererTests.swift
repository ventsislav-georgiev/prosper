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
        var image: CGImage?
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
        var load: TextViewerImageLoader {
            { [self] src, _, _ in lock.lock(); seen.append(src.absoluteString); lock.unlock(); return image }
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
        XCTAssertEqual(out.note, R.tooLargeNote)
        XCTAssertEqual(out.text.length, R.maxSourceBytes + 1)
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
        XCTAssertTrue(hasTable(render(table(64))))
        let wide = render(table(65))
        XCTAssertFalse(hasTable(wide))
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
        func inTable(_ out: R.Output, at index: Int) -> Bool {
            guard index >= 0, index < out.text.length else { return false }
            let ps = out.text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
            return ps?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true
        }
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

    /// Round 2 item 2: at most 2,000 links a document are links; the 2,001st is its plain text.
    func testLinkCountCap() {
        let out = render((0...R.maxLinks).map { "[l\($0)](https://example.com/\($0))" }.joined(separator: " "))
        var linked: [String] = []
        out.text.enumerateAttribute(.link, in: NSRange(location: 0, length: out.text.length)) { v, range, _ in
            if v != nil { linked.append((out.text.string as NSString).substring(with: range)) }
        }
        XCTAssertEqual(linked.count, R.maxLinks)
        XCTAssertEqual(linked.last, "l1999")
        XCTAssertEqual(out.note, "Too many links: the rest shown as plain text")
        XCTAssertNil(render((1...R.maxLinks).map { "[l\($0)](https://example.com/\($0))" }.joined(separator: " ")).note,
                     "nothing trimmed at the cap")
        let last = (out.text.string as NSString).range(of: "l2000")
        XCTAssertNotEqual(last.location, NSNotFound)
        guard last.location != NSNotFound else { return }
        XCTAssertTrue(out.text.attribute(.link, at: last.location, effectiveRange: nil) == nil)
        XCTAssertTrue(out.text.attribute(.toolTip, at: last.location, effectiveRange: nil) == nil)
    }

    /// Round 2 item 2: at most 50,000 inline-styled runs a document; later runs take the block's style.
    func testStyledRunCap() {
        let out = render((0...R.maxStyledRuns).map { "*e\($0)*" }.joined(separator: " "))
        func italic(_ word: String) -> Bool? {
            let r = (out.text.string as NSString).range(of: word)
            guard r.location != NSNotFound, let font = out.text.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont else { return nil }
            return font.fontDescriptor.symbolicTraits.contains(.italic)
        }
        XCTAssertEqual(italic("e0 "), true)
        XCTAssertEqual(italic("e49999"), true, "run 50,000 is styled")
        XCTAssertEqual(italic("e50000"), false, "run 50,001 is the paragraph's plain text")
        XCTAssertEqual(out.note, "Too many styles: the rest shown as plain text")
        XCTAssertNil(render((1...R.maxStyledRuns).map { "*e\($0)*" }.joined(separator: " ")).note, "nothing trimmed at the cap")
        // Several caps: one note, each named once, in the order first hit.
        let both = render((0...R.maxLinks).map { "[l\($0)](https://example.com/\($0))" }.joined(separator: " ")
                          + "\n\n" + String(repeating: "*e* ", count: R.maxStyledRuns))
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
                let out = onAppThread("\(name) x \(k.map { "\($0)" } ?? "1 MiB")", md)
                // parsed, never the source fallback (a cap's "Too many ..." note may show: Round 3 F2)
                XCTAssertFalse([R.tooLargeNote, R.tooDeepNote, R.unparsedNote].contains(out?.note ?? ""), name)
            }
        }
    }

    /// Round 2 item 2: the worst tables the caps allow, against flat shapes of the same size. Layout
    /// is measured on the main thread, where TextViewerTextView.show runs it.
    func testWorstTables() throws {
        try requireHeavyTests()
        func table(_ cols: Int, _ rows: Int?) -> String {
            let head = "|" + String(repeating: "h|", count: cols) + "\n|" + String(repeating: "-|", count: cols) + "\n"
            let row = "|" + String(repeating: "a|", count: cols) + "\n"
            return head + String(repeating: row, count: rows ?? (R.maxSourceBytes - head.utf8.count) / row.utf8.count)
        }
        let shapes: [(String, String)] = [
            ("table 1 column x 1 MiB of rows", table(1, nil)),
            ("table 64 columns x 1 MiB of rows", table(64, nil)),
            ("table 8 x 20000", table(8, 20000)),
            ("table 1 x 50000 cells, at the cap", table(1, R.maxTableCells - 1)),
            ("table 8 x 6250, at the cap", table(8, R.maxTableCells / 8 - 1)),
            ("table 64 x 781, at the cap", table(64, R.maxTableCells / 64 - 1)),
            ("1 MiB of 4-byte list items", String(repeating: "- a\n", count: R.maxSourceBytes / 4)),
            ("1 MiB of one-letter paragraphs", String(repeating: "a\n\n", count: R.maxSourceBytes / 3)),
            ("1 MiB of short links", String(repeating: "[a](b) ", count: R.maxSourceBytes / 7)),
        ]
        let style = Self.style, doc = Self.document
        for (name, md) in shapes {
            let box = OutputBox()
            timed("render \(name)", ceiling: 120) { box.set(R.render(md, document: doc, style: style, loader: { _, _, _ in nil })) }
            guard let out = box.get() else { continue }
            let t0 = Date()
            timed("layout \(name)", ceiling: 120) { Self.layout(out.text) }
            let offMain = Date().timeIntervalSince(t0)
            guard offMain < 30 else { continue }   // a main-thread layout cannot be cancelled: only a bounded one
            let start = Date()
            Self.layout(out.text)   // on main, as show() does
            Self.fact("\(name): \(md.utf8.count) bytes, \(out.text.length) characters, layout \(String(format: "%.3f", offMain)) s off main, \(String(format: "%.3f", Date().timeIntervalSince(start))) s on main")
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

    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: R.Output?
        func set(_ v: R.Output) { lock.lock(); value = v; lock.unlock() }
        func get() -> R.Output? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
