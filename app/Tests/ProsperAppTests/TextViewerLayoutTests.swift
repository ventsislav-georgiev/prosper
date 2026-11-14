import AppKit
import XCTest
@testable import ProsperApp

/// Counts what the layout manager lays out: every line fragment passes through this delegate call.
final class TextViewerLayoutCount: NSObject, NSLayoutManagerDelegate, @unchecked Sendable {
    var lines = 0, glyphs = 0
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        lines += 1
        glyphs += glyphRange.length
        return false
    }
    func reset() { lines = 0; glyphs = 0 }
}

/// #1155: a show lays out what is drawn, not the whole text. Rows count the layout work (line
/// fragments and glyphs) and wait on the model's loads counter to a deadline, never a fixed time.
/// Offscreen: the window is never ordered in or made key and is closed in a defer; no event is
/// posted; no link is acted on; the files are fakes in a tempDir().
@MainActor
final class TextViewerLayoutTests: XCTestCase {

    typealias R = MarkdownRenderer

    /// Glyphs one show plus its first draw may lay out: 1/32 of a 1 MiB text. Measured (ticket 1): a
    /// screen and TextKit's look-ahead took at most 6,208 glyphs (97 lines of 64 bytes); the TIP laid
    /// out every glyph of the text.
    static let ceiling = 32_768
    /// R1155-1: links in one paragraph cost superlinearly (16,000 runs 0.14 s, 32,000 runs 0.64 s).
    static let measuredLinkBound = 8_000
    /// Printed for the report (one line to stderr, as MarkdownRendererTests.fact does).
    nonisolated static func fact(_ s: String) { fputs("vl fact \(s)\n", stderr) }

    private struct Host {
        let window: NSWindow
        let scroll: NSScrollView
        let view: TextViewerTextView
        let count: TextViewerLayoutCount
        var clip: NSClipView { scroll.contentView }
    }

    /// The app's text area at scale 1 (820 x 640 less the header) in a window that is never shown.
    private func host() throws -> Host {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (scroll, view) = TextViewerTextView.makeScrollable()
        scroll.frame = CGRect(x: 0, y: 0, width: 820, height: 560)
        window.contentView = scroll
        scroll.tile()
        let count = TextViewerLayoutCount()
        let lm = try XCTUnwrap(view.layoutManager)
        lm.delegate = count
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 0, "the clip view is sized")
        return Host(window: window, scroll: scroll, view: view, count: count)
    }

    private func actions() -> TextViewerActions {
        TextViewerActions(defaultApp: { _ in nil }, openWith: { _, _ in }, reveal: { _ in }, openURL: { _ in }, view: { _ in })
    }

    /// `bytes` of `line` repeated, written in 64 KiB pieces (no large string in the test).
    private func write(_ url: URL, line: String, bytes: Int) throws {
        let chunk = Data(String(repeating: line, count: max(1, 65_536 / line.utf8.count)).utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        var left = bytes
        while left > 0 {
            let part = chunk.prefix(left)
            try h.write(contentsOf: part)
            left -= part.count
        }
    }

    private func append(_ url: URL, _ text: String) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    /// The model's next load, polled on the main run loop to a deadline (reading and rendering 16 MiB
    /// runs off the main thread in a debug build).
    private func loaded(_ model: TextViewerModel, after n: Int, file: StaticString = #filePath, line: UInt = #line) throws -> NSAttributedString {
        let deadline = Date().addingTimeInterval(60)
        while model.loads <= n, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertGreaterThan(model.loads, n, "not loaded within 60 s", file: file, line: line)
        return try XCTUnwrap(model.output?.text, file: file, line: line)
    }

    /// The scroll view drawn into a bitmap, as a window would draw it; returns the pixels with ink.
    @discardableResult
    private func draw(_ h: Host) throws -> Int {
        h.scroll.layoutSubtreeIfNeeded()
        let b = h.scroll.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = b.size
        h.scroll.cacheDisplay(in: b, to: rep)
        var ink = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 }
        }
        return ink
    }

    /// The first character of the line fragment at the top of the visible text.
    private func topCharacter(_ h: Host) throws -> Int {
        let lm = try XCTUnwrap(h.view.layoutManager), tc = try XCTUnwrap(h.view.textContainer)
        let y = max(0, h.clip.bounds.minY - h.view.textContainerOrigin.y)
        var line = NSRange()
        lm.lineFragmentRect(forGlyphAt: lm.glyphIndex(for: NSPoint(x: 0, y: y), in: tc), effectiveRange: &line)
        return lm.characterIndexForGlyph(at: line.location)
    }

    private func scroll(_ h: Host, toY y: CGFloat) {
        h.clip.scroll(to: NSPoint(x: 0, y: y.rounded()))
        h.scroll.reflectScrolledClipView(h.clip)
    }

    /// Opens `url` through the model, shows its first load and draws it; asserts the counted work.
    private func showCounted(_ url: URL, _ what: String, limit: Int = TextViewerLayoutTests.ceiling, file: StaticString = #filePath, line: UInt = #line) throws
        -> (Host, TextViewerModel, NSAttributedString) {
        let model = TextViewerModel(url: url, resolved: url, actions: actions(), imageLoader: { _, _, _ in nil })
        let text = try loaded(model, after: 0, file: file, line: line)
        let h = try host()
        h.count.reset()
        h.view.show(text)
        let ink = try draw(h)
        Self.fact("\(what): show + first draw laid out \(h.count.glyphs) glyphs, \(h.count.lines) lines, of \(text.length)")
        XCTAssertLessThanOrEqual(h.count.glyphs, limit, "\(what): glyphs laid out by show and the first draw (\(h.count.lines) lines)",
                                 file: file, line: line)
        XCTAssertGreaterThan(ink, 200, "\(what): the visible text is drawn", file: file, line: line)
        return (h, model, text)
    }

    // MARK: The entry's rows: main-thread layout at show, counted.

    func testOneMiBOfPlainShortLinesLaysOutTheViewOnly() throws {
        let url = tempDir("tv-layout").appendingPathComponent("short.log")
        try write(url, line: "abc\n", bytes: 1 << 20)
        let (h, _, text) = try showCounted(url, "1 MiB of 4-byte lines")
        defer { h.window.close() }
        XCTAssertEqual(text.length, 1 << 20)
        XCTAssertEqual(h.view.textStorage?.length, text.length, "the whole text is in the storage")
    }

    func testSixteenMiBOfPlainTextLaysOutTheViewOnly() throws {
        let line = "2026-11-14T12:00:00Z INFO api request handled in 12 ms id=xxxxx\n"
        XCTAssertEqual(line.utf8.count, 64)
        let url = tempDir("tv-layout").appendingPathComponent("big.log")
        try write(url, line: line, bytes: TextViewerDocument.maxBytes)
        let (h, _, text) = try showCounted(url, "16 MiB of 64-byte lines")
        defer { h.window.close() }
        XCTAssertEqual(text.length, 16 << 20, "the whole 16 MiB is shown, not refused")
        XCTAssertEqual(h.view.textStorage?.length, text.length)
    }

    func testOneMiBOfMarkdownLaysOutTheViewOnly() throws {
        let url = tempDir("tv-layout").appendingPathComponent("big.md")
        try Data(Self.markdown((1 << 20) - 4096).utf8).write(to: url)
        let (h, model, text) = try showCounted(url, "1 MiB of Markdown")
        defer { h.window.close() }
        XCTAssertNotEqual(model.output?.note, R.tooLargeNote, "rendered as Markdown, not shown as source")
        XCTAssertGreaterThan(text.length, 700_000)
    }

    /// Headings, emphasis, code, links, lists, quotes, code blocks, small tables and paragraphs.
    static func markdown(_ bytes: Int) -> String {
        let blocks = ["## Heading", "Some *text* with `code` and a [link](https://example.com/page).", "- item one\n- item two",
                      "> quote line", "    code line", "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |",
                      "Plain paragraph text that runs on for a while to wrap at the column width of the viewer."]
        var parts: [String] = [], total = 0, i = 0
        while true {
            let b = blocks[i % blocks.count] + " \(i)"
            if total + b.utf8.count + 2 > bytes { break }
            parts.append(b)
            total += b.utf8.count + 2
            i += 1
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: D9: the place across a reload (the file grows; the model hands over a new text).

    enum Place { case top, middle, end }

    private func reloadKeepsThePlace(_ url: URL, _ place: Place, _ what: String, limit: Int = TextViewerLayoutTests.ceiling,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let (h, model, text) = try showCounted(url, what, limit: limit, file: file, line: line)
        defer { h.window.close() }
        let lm = try XCTUnwrap(h.view.layoutManager)
        switch place {
        case .top: scroll(h, toY: -h.scroll.contentInsets.top)
        case .middle:   // the line holding the middle character at the top
            let g = lm.glyphIndexForCharacter(at: text.length / 2)
            scroll(h, toY: lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY + h.view.textContainerOrigin.y)
        case .end: h.view.scrollRangeToVisible(NSRange(location: text.length, length: 0))
        }
        try draw(h)
        let before = try topCharacter(h), y0 = h.clip.bounds.minY
        let offset = h.clip.bounds.minY - h.view.textContainerOrigin.y - lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: before), effectiveRange: nil).minY
        switch place {
        case .top: XCTAssertEqual(before, 0, "\(what): at the top", file: file, line: line)
        case .middle, .end: XCTAssertGreaterThan(before, text.length / 3, "\(what): scrolled down", file: file, line: line)
        }

        let n = model.loads
        try append(url, "\n\ntail line\n")
        model.reload()
        let grown = try loaded(model, after: n, file: file, line: line)
        XCTAssertFalse(grown === text, "\(what): the reload hands over a new text", file: file, line: line)
        XCTAssertGreaterThan(grown.length, text.length, file: file, line: line)
        h.count.reset()
        h.view.show(grown)
        try draw(h)
        Self.fact("\(what): reload laid out \(h.count.glyphs) glyphs, \(h.count.lines) lines")
        XCTAssertLessThanOrEqual(h.count.glyphs, limit, "\(what): glyphs laid out by the reload (\(h.count.lines) lines)",
                                 file: file, line: line)
        XCTAssertEqual(try topCharacter(h), before, "\(what): the same line at the top after the reload", file: file, line: line)
        let after = h.clip.bounds.minY - h.view.textContainerOrigin.y - lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: before), effectiveRange: nil).minY
        XCTAssertEqual(after, offset, accuracy: 1, "\(what): the same offset into that line", file: file, line: line)
        if place == .top { XCTAssertEqual(h.clip.bounds.minY, y0, "\(what): still at the very top", file: file, line: line) }
    }

    private func plainFile() throws -> URL {
        let url = tempDir("tv-layout").appendingPathComponent("grow.log")
        try write(url, line: "abc\n", bytes: 1 << 20)
        return url
    }

    func testReloadKeepsThePlaceAtTheTop() throws { try reloadKeepsThePlace(try plainFile(), .top, "plain top") }
    func testReloadKeepsThePlaceInTheMiddle() throws { try reloadKeepsThePlace(try plainFile(), .middle, "plain middle") }
    func testReloadKeepsThePlaceAtTheEnd() throws { try reloadKeepsThePlace(try plainFile(), .end, "plain end") }

    /// Markdown's height estimate is furthest off (ticket 1: a fraction of it moved the place 101 paragraphs).
    func testReloadKeepsThePlaceInTheMiddleOfMarkdown() throws {
        let url = tempDir("tv-layout").appendingPathComponent("grow.md")
        try Data(Self.markdown((1 << 20) - 4096).utf8).write(to: url)
        try reloadKeepsThePlace(url, .middle, "markdown middle")
    }

    /// Heavy only (a time ceiling): a reload of 1 MiB of Markdown shows in under 0.5 s on main, 21 times
    /// the 0.023 s measured here (#1155 round 2, debug build). Ticket 2: the TIP's setAttributedString
    /// over the old text alone took 1.12 s (its whole reload 2.08 s); not emptied first, 1.22 s.
    func testMarkdownReloadShowsInTime() throws {
        try requireHeavyTests()
        let url = tempDir("tv-layout").appendingPathComponent("again.md")
        try Data(Self.markdown((1 << 20) - 4096).utf8).write(to: url)
        let (h, model, _) = try showCounted(url, "markdown reload")
        defer { h.window.close() }
        let n = model.loads
        try append(url, "\n\ntail line\n")
        model.reload()
        let grown = try loaded(model, after: n)
        let t0 = Date()
        h.view.show(grown)
        let t = Date().timeIntervalSince(t0)
        Self.fact(String(format: "time: a 1 MiB Markdown reload's show %.4f s", t))
        XCTAssertLessThan(t, 0.5, "a 1 MiB Markdown reload took \(t) s on main")
    }

    // MARK: R2-1: up to wholeLayoutLength the text is laid out whole, as before #1155.

    private typealias TV = TextViewerTextView

    /// Every glyph laid out by show, and the frame as tall as a separate, contiguous layout of the same
    /// text at the same width makes it (the scroll bar is exact).
    private func assertLaidOutWhole(_ h: Host, _ text: NSAttributedString, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let lm = try XCTUnwrap(h.view.layoutManager), tc = try XCTUnwrap(h.view.textContainer)
        Self.fact("\(what): show laid out \(h.count.glyphs) glyphs of \(lm.numberOfGlyphs), frame \(h.view.frame.height)")
        XCTAssertEqual(lm.firstUnlaidCharacterIndex(), text.length, "\(what): every character laid out", file: file, line: line)
        XCTAssertGreaterThanOrEqual(h.count.glyphs, lm.numberOfGlyphs, "\(what): every glyph laid out by show", file: file, line: line)
        let storage = NSTextStorage(attributedString: text)
        let separate = NSLayoutManager()
        storage.addLayoutManager(separate)
        let container = NSTextContainer(size: NSSize(width: tc.size.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = tc.lineFragmentPadding
        separate.addTextContainer(container)
        separate.ensureLayout(for: container)
        let exact = separate.usedRect(for: container).height + 2 * h.view.textContainerInset.height
        XCTAssertEqual(h.view.frame.height, exact, accuracy: 1, "\(what): the frame is the exact height", file: file, line: line)
    }

    /// 4-byte lines: the kind whose height estimate is furthest off (ticket 1: 18x too short).
    private static func shortLines(_ length: Int) -> NSAttributedString {
        R.plain(String(repeating: "abc\n", count: length / 4), style: style).text
    }

    func testTextAtTheSizeIsLaidOutWhole() throws {
        let text = Self.shortLines(TV.wholeLayoutLength)
        XCTAssertEqual(text.length, TV.wholeLayoutLength)
        let h = try host()
        defer { h.window.close() }
        h.count.reset()
        h.view.show(text)
        try assertLaidOutWhole(h, text, "4-byte lines at the size")
        XCTAssertGreaterThan(try draw(h), 200, "the visible text is drawn")
    }

    func testMarkdownUnderTheSizeIsLaidOutWhole() throws {
        let text = R.render(Self.markdown(TV.wholeLayoutLength), document: Self.document, style: Self.style, loader: { _, _, _ in nil }).text
        XCTAssertLessThanOrEqual(text.length, TV.wholeLayoutLength)
        XCTAssertGreaterThan(text.length, TV.wholeLayoutLength / 2)
        let h = try host()
        defer { h.window.close() }
        h.count.reset()
        h.view.show(text)
        try assertLaidOutWhole(h, text, "Markdown under the size")
        XCTAssertGreaterThan(try draw(h), 200, "the visible text is drawn")
    }

    /// Small 2x2 tables (text blocks): the kind that costs the most per unit (4.7 us here).
    func testTablesUnderTheSizeAreLaidOutWhole() throws {
        var parts: [String] = [], bytes = 0, i = 0
        while bytes < 2 * TV.wholeLayoutLength {
            let t = "| a\(i) | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
            parts.append(t)
            bytes += t.utf8.count + 2
            i += 1
        }
        let text = R.render(parts.joined(separator: "\n\n"), document: Self.document, style: Self.style, loader: { _, _, _ in nil }).text
        XCTAssertLessThanOrEqual(text.length, TV.wholeLayoutLength)
        XCTAssertGreaterThan(text.length, TV.wholeLayoutLength / 4)
        let h = try host()
        defer { h.window.close() }
        h.count.reset()
        h.view.show(text)
        try assertLaidOutWhole(h, text, "tables under the size (\(i) tables)")
        XCTAssertGreaterThan(try draw(h), 200, "the visible text is drawn")
    }

    func testTextJustOverTheSizeLaysOutTheViewOnly() throws {
        let text = Self.shortLines(TV.wholeLayoutLength + 4)
        XCTAssertEqual(text.length, TV.wholeLayoutLength + 4)
        let h = try host()
        defer { h.window.close() }
        h.count.reset()
        h.view.show(text)
        XCTAssertGreaterThan(try draw(h), 200, "the visible text is drawn")
        Self.fact("4-byte lines just over the size: show + first draw laid out \(h.count.glyphs) glyphs of \(text.length)")
        XCTAssertLessThan(h.count.glyphs, text.length, "not the whole text (\(h.count.lines) lines)")
        XCTAssertLessThanOrEqual(h.count.glyphs, Self.ceiling)
    }

    private func smallFile() throws -> URL {
        let url = tempDir("tv-layout").appendingPathComponent("small.log")
        try write(url, line: "abc\n", bytes: TV.wholeLayoutLength - 64)   // the reload's 12 bytes keep it under the size
        return url
    }

    func testReloadKeepsThePlaceInTheMiddleOfASmallText() throws {
        try reloadKeepsThePlace(try smallFile(), .middle, "small middle", limit: TV.wholeLayoutLength)
    }
    func testReloadKeepsThePlaceAtTheEndOfASmallText() throws {
        try reloadKeepsThePlace(try smallFile(), .end, "small end", limit: TV.wholeLayoutLength)
    }

    // MARK: R2-2: a reload to a shorter or an empty text; a far jump as the "#fragment" scroll does it.

    private func cut(_ url: URL, to size: UInt64) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: size)
    }

    /// Scrolled to the end of 1 MiB, the file is cut to 256 KiB: the clip shows the end of the new text.
    func testReloadToAShorterTextEndsInsideIt() throws {
        let url = try plainFile()
        let (h, model, text) = try showCounted(url, "shorter, before")
        defer { h.window.close() }
        h.view.scrollRangeToVisible(NSRange(location: text.length, length: 0))
        try draw(h)
        XCTAssertGreaterThan(try topCharacter(h), text.length / 2, "scrolled to the end")
        let n = model.loads
        try cut(url, to: 1 << 18)
        model.reload()
        let short = try loaded(model, after: n)
        XCTAssertEqual(short.length, 1 << 18)
        h.count.reset()
        h.view.show(short)
        let ink = try draw(h)
        let top = try topCharacter(h)
        Self.fact("shorter: reload laid out \(h.count.glyphs) glyphs, clip \(h.clip.bounds), frame \(h.view.frame.height), top \(top)")
        XCTAssertLessThanOrEqual(h.count.glyphs, Self.ceiling, "glyphs laid out by the reload (\(h.count.lines) lines)")
        let lm = try XCTUnwrap(h.view.layoutManager)
        let last = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: short.length - 1), effectiveRange: nil)
            .offsetBy(dx: 0, dy: h.view.textContainerOrigin.y)
        Self.fact("shorter: last line \(last), clip \(h.clip.bounds), frame \(h.view.frame)")
        // AppKit's scroll range ends a few points below the frame in this scroll view; the End key lands there too.
        let lowest = h.clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: h.view.frame.height + 100_000), size: h.clip.bounds.size))
        Self.fact("shorter: AppKit's lowest bottom - frame.maxY \(lowest.maxY - h.view.frame.maxY), clip insets \(h.clip.contentInsets), scroll insets \(h.scroll.contentInsets), automatic \(h.scroll.automaticallyAdjustsContentInsets), scroller insets \(h.scroll.scrollerInsets)")
        XCTAssertLessThanOrEqual(h.clip.bounds.maxY, lowest.maxY + 1, "the clip ends no lower than AppKit's own lowest position")
        XCTAssertGreaterThanOrEqual(last.minY, h.clip.bounds.minY - 1, "the last line is on screen")
        XCTAssertLessThanOrEqual(last.maxY, h.clip.bounds.maxY + 1, "the last line is on screen")
        XCTAssertGreaterThan(ink, 200, "the end of the new text is drawn")
    }

    /// Scrolled to the middle, the file is emptied: the clip is at the top.
    func testReloadToAnEmptyTextIsAtTheTop() throws {
        let url = try plainFile()
        let (h, model, text) = try showCounted(url, "empty, before")
        defer { h.window.close() }
        h.view.scrollRangeToVisible(NSRange(location: text.length / 2, length: 0))
        try draw(h)
        XCTAssertGreaterThan(h.clip.bounds.minY, 1_000, "scrolled down")
        let n = model.loads
        try cut(url, to: 0)
        model.reload()
        let empty = try loaded(model, after: n)
        XCTAssertEqual(empty.length, 0)
        h.view.show(empty)
        try draw(h)
        Self.fact("empty: clip \(h.clip.bounds), frame \(h.view.frame.height)")
        XCTAssertEqual(h.view.textStorage?.length, 0)
        XCTAssertEqual(h.clip.bounds.minY, -h.scroll.contentInsets.top, accuracy: 0.5, "the clip is at the top")
    }

    /// TextViewerWindow's "#fragment" scroll calls scrollRangeToVisible on the anchor's character; the
    /// same call here, to the middle of 1 MiB of Markdown.
    func testFarJumpInMarkdownShowsTheLine() throws {
        let url = tempDir("tv-layout").appendingPathComponent("jump.md")
        try Data(Self.markdown((1 << 20) - 4096).utf8).write(to: url)
        let (h, _, text) = try showCounted(url, "jump, first show")
        defer { h.window.close() }
        let at = text.length / 2
        h.count.reset()
        h.view.scrollRangeToVisible(NSRange(location: at, length: 0))
        XCTAssertGreaterThan(try draw(h), 200, "the target screen is drawn")
        let lm = try XCTUnwrap(h.view.layoutManager)
        let r = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: at), effectiveRange: nil)
            .offsetBy(dx: 0, dy: h.view.textContainerOrigin.y)
        Self.fact("jump: laid out \(h.count.glyphs) glyphs, \(h.count.lines) lines; line \(r) in clip \(h.clip.bounds)")
        XCTAssertGreaterThanOrEqual(r.minY, h.clip.bounds.minY - 1, "the line of character \(at) is in the clip")
        XCTAssertLessThanOrEqual(r.maxY, h.clip.bounds.maxY + 1, "the line of character \(at) is in the clip")
        XCTAssertLessThanOrEqual(h.count.glyphs, Self.ceiling, "glyphs laid out by the jump and its draw (\(h.count.lines) lines)")
    }

    // MARK: The whole text is still there for select all, copy and accessibility.

    func testSelectAllCopyAndAccessibilitySeeTheWholeText() throws {
        let url = tempDir("tv-layout").appendingPathComponent("all.log")
        try write(url, line: "abc\n", bytes: 1 << 20)
        let model = TextViewerModel(url: url, resolved: url, actions: actions(), imageLoader: { _, _, _ in nil })
        let text = try loaded(model, after: 0)
        let h = try host()
        defer { h.window.close() }
        h.count.reset()
        h.view.show(text)
        try draw(h)

        h.view.selectAll(nil)
        let all = h.view.selectedRange()
        XCTAssertEqual(all, NSRange(location: 0, length: text.length), "select all spans the text not laid out")
        XCTAssertEqual(h.view.textStorage?.attributedSubstring(from: all).string, text.string, "the selection's text, from the storage")
        XCTAssertEqual((h.view.accessibilityValue() as? String)?.utf16.count, text.length, "VoiceOver's value is the whole text")
        XCTAssertEqual(h.view.accessibilityNumberOfCharacters(), text.length)

        // A selection from the first line into text never laid out, copied through the private test pasteboard.
        let span = NSRange(location: 2, length: 200_000)
        h.view.setSelectedRange(span)
        h.view.copy(nil)
        XCTAssertTrue(Pasteboard.general.name.rawValue.hasPrefix("eu.illegible.prosper.xctest"), "the private test pasteboard")
        XCTAssertEqual(Pasteboard.general.string(forType: .string), (text.string as NSString).substring(with: span))
        XCTAssertLessThanOrEqual(h.count.glyphs, Self.ceiling, "show, select all, copy and the AX value (\(h.count.lines) lines)")
    }

    // MARK: Rider R1155-1: the link cap.

    private static let document = URL(fileURLWithPath: "/Users/example/docs/README.md")
    private static let style = R.Style(scale: 1, text: .init(r: 0, g: 0, b: 0, a: 1), secondary: .init(r: 0.5, g: 0.5, b: 0.5, a: 1),
                                       accent: .init(r: 0, g: 0, b: 1, a: 1), card: .init(r: 0.9, g: 0.9, b: 0.9, a: 1),
                                       stroke: .init(r: 0.8, g: 0.8, b: 0.8, a: 1))

    /// One paragraph of `n` links: the worst case for the cap (a paragraph is laid out whole).
    private static func linkParagraph(_ n: Int) -> MarkdownRenderer.Output {
        R.render((0..<n).map { "[l\($0)](https://example.com/\($0))" }.joined(separator: " "),
                 document: document, style: style, loader: { _, _, _ in nil })
    }

    private static func links(_ out: MarkdownRenderer.Output) -> [String] {
        var linked: [String] = []
        out.text.enumerateAttribute(.link, in: NSRange(location: 0, length: out.text.length)) { v, range, _ in
            if v != nil { linked.append((out.text.string as NSString).substring(with: range)) }
        }
        return linked
    }

    /// The cap is the measured bound: 8,000 links are links, the 8,001st is plain text.
    func testLinkCapIsTheMeasuredBound() {
        let out = Self.linkParagraph(Self.measuredLinkBound + 1)
        let linked = Self.links(out)
        XCTAssertEqual(linked.count, Self.measuredLinkBound, "links drawn as links in one paragraph")
        XCTAssertEqual(linked.last, "l7999")
        XCTAssertEqual(out.note, "Too many links: the rest shown as plain text")
        XCTAssertTrue(Self.links(Self.linkParagraph(Self.measuredLinkBound)).count == Self.measuredLinkBound, "nothing trimmed at the cap")
    }

    /// Heavy only (a time ceiling): a paragraph of links at the cap is shown and drawn in under 2 s, 12
    /// times the 0.158 s measured here (#1155 round 2, debug build); a 32,000-link paragraph took 3.8 s.
    func testLinkCapParagraphShowsInTime() throws {
        try requireHeavyTests()
        let out = Self.linkParagraph(R.maxLinks)
        XCTAssertEqual(Self.links(out).count, R.maxLinks)
        let h = try host()
        defer { h.window.close() }
        let t0 = Date()
        h.view.show(out.text)
        XCTAssertGreaterThan(try draw(h), 200, "the links are drawn")
        let t = Date().timeIntervalSince(t0)
        Self.fact(String(format: "time: a paragraph of %ld links shown and drawn %.4f s", R.maxLinks, t))
        XCTAssertLessThan(t, 2, "a paragraph of \(R.maxLinks) links laid out in \(t) s (\(h.count.lines) lines)")
    }
}
