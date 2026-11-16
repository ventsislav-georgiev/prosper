import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1319 rows: a presenter that never shows anything. It records each present and close and hosts the content in an
/// NSHostingView inside a borderless window that is never shown, ordered front or made key.
@MainActor
final class FakeCardPresenter: XrayCardPresenter {
    private(set) var presents = 0, closes = 0
    private(set) var size: CGSize?
    private(set) weak var anchor: NSView?
    private(set) var window: NSWindow?
    private var closed: (@MainActor () -> Void)?

    var isShown: Bool { closed != nil }

    func present(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void) {
        presents += 1
        self.size = size
        self.anchor = anchor
        self.closed = closed
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        window = w
    }

    func close() {
        closes += 1
        let f = closed
        closed = nil
        window?.close()
        window = nil
        f?()
    }

    /// The list's filter field, as hosted.
    var field: ChapterListField.Field? { window?.contentView.flatMap { Self.find($0) } }

    /// The field editor that holds the keys in the hosting window (the field is first responder there).
    var editor: NSTextView? {
        guard let e = window?.firstResponder as? NSTextView, let f = field, e.delegate === f else { return nil }
        return e
    }

    static func find(_ v: NSView) -> ChapterListField.Field? {
        if let f = v as? ChapterListField.Field { return f }
        for c in v.subviews { if let f = find(c) { return f } }
        return nil
    }
}

/// #1319 (#832 X1 step B, spec v2.1 8.3): the Jump to Chapter list on its own: its frame, filter, keys, the Load
/// earlier row, where it opens, the jump, and the titles as outside text (R904-f1). Fake chapters only (no transcript
/// file, no dch); views hosted offscreen or drawn by ImageRenderer; the fake presenter's window is never shown.
@MainActor
final class TranscriptChapterListTests: XCTestCase {
    typealias Chapter = TranscriptOutline.Chapter

    private func chapters(_ titles: [String], from id: Int = 0, kinds: [Int: Chapter.Kind] = [:]) -> [Chapter] {
        titles.enumerated().map { i, t in
            Chapter(id: id + 10 * i, ordinal: i + 1, title: t, kind: kinds[i] ?? .prompt, hasError: false)
        }
    }

    private func list(_ cs: [Chapter], older: Bool = false, jumper: TranscriptJumper = TranscriptJumper()) -> TranscriptChapterListModel {
        TranscriptChapterListModel(chapters: { cs }, older: { older }, loadEarlier: {}, jumper: jumper)
    }

    private func numbered(_ n: Int) -> [Chapter] { chapters((0..<n).map { "Prompt \($0)" }) }

    private func at(_ l: TranscriptChapterListModel) -> Int { l.index ?? -1 }

    // MARK: 8.3 surface: fixed 360x308*s

    /// 1, 3 and 30 matches (and the Load earlier row): always 360x308*s, at 1.0 and 0.85.
    @MainActor
    func testListFrameStaysFixedWhateverMatches() {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in [1.0, 0.85] as [CGFloat] {
            ThemeRuntime.scale = scale
            for (n, older) in [(1, false), (3, false), (30, false), (3, true), (0, false)] {
                let l = list(numbered(n), older: older)
                let size = NSHostingView(rootView: TranscriptChapterList(list: l)).fittingSize
                let tag = "\(n) matches, older \(older), scale \(scale)"
                XCTAssertEqual(size.width, 360 * scale, accuracy: pixel, tag)
                XCTAssertEqual(size.height, 308 * scale, accuracy: pixel, tag)
                XCTAssertEqual(TranscriptChapterList.size.height, 308 * scale, accuracy: 0.01, tag)
            }
            // Typing narrows the matches; the surface keeps its size.
            let l = list(numbered(30))
            let host = NSHostingView(rootView: TranscriptChapterList(list: l))
            let before = host.fittingSize
            l.query = "Prompt 2"
            XCTAssertEqual(l.matches.count, 12, "Prompt 2, Prompt 12 and Prompt 20...29")
            XCTAssertEqual(host.fittingSize, before, "scale \(scale): the filter never resizes it")
            l.query = "Prompt 29"
            XCTAssertEqual(l.matches.count, 1)
            XCTAssertEqual(host.fittingSize, before, "scale \(scale): one match, same size")
        }
    }

    // MARK: 8.3 filter

    func testFilterIsCaseInsensitiveEveryWordInConversationOrder() {
        let l = list(chapters(["Fix the Build", "build docs", "Deploy build FIX", "unrelated"]))
        l.query = "BUILD fix"
        XCTAssertEqual(l.matches.map(\.title), ["Fix the Build", "Deploy build FIX"], "every word, any case, in order")
        XCTAssertEqual(l.selected, .chapter(0), "the selection moved to the first match")
        l.query = "build"
        XCTAssertEqual(l.matches.map(\.title), ["Fix the Build", "build docs", "Deploy build FIX"])
        XCTAssertEqual(l.selected, .chapter(0), "a selection still matching stays")
        l.query = "  "
        XCTAssertEqual(l.matches.count, 4, "blank: everything")
        l.query = "zzz"
        XCTAssertTrue(l.matches.isEmpty && l.rows.isEmpty)
        var closed = 0
        l.close = { closed += 1 }
        XCTAssertTrue(l.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(closed, 0, "Return on no match: nothing")
        XCTAssertTrue(l.jumper.request == nil, "and no jump")
    }

    // MARK: 8.3 keys

    func testKeysMoveWithoutWrapByPagesAndToTheEnds() {
        let l = list(numbered(30))
        func key(_ s: Selector) { XCTAssertTrue(l.command(s), "\(s)") }
        XCTAssertEqual(at(l), 29, "opens on the last chapter")
        XCTAssertEqual(l.firstShown, 21, "the last nine rows drawn")
        key(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(at(l), 29, "down at the end: no wrap")
        key(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(at(l), 28)
        key(#selector(NSResponder.scrollPageUp(_:)))
        XCTAssertEqual(at(l), 19, "Page Up: 9 rows")
        key(#selector(NSResponder.pageUp(_:)))
        XCTAssertEqual(at(l), 10)
        XCTAssertEqual(l.firstShown, 10, "the selection stays in view")
        key(#selector(NSResponder.scrollPageUp(_:)))
        key(#selector(NSResponder.scrollPageUp(_:)))
        XCTAssertEqual(at(l), 0, "Page Up stops at the first row")
        key(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(at(l), 0, "up at the start: no wrap")
        key(#selector(NSResponder.scrollPageDown(_:)))
        XCTAssertEqual(at(l), 9, "Page Down: 9 rows")
        XCTAssertEqual(l.firstShown, 1)
        key(#selector(NSResponder.scrollToEndOfDocument(_:)))
        XCTAssertEqual(at(l), 29, "End")
        key(#selector(NSResponder.scrollToBeginningOfDocument(_:)))
        XCTAssertEqual(at(l), 0, "Home")
        XCTAssertEqual(l.firstShown, 0)
        key(#selector(NSResponder.moveToEndOfDocument(_:)))
        XCTAssertEqual(at(l), 29)
        XCTAssertFalse(l.command(#selector(NSResponder.moveLeft(_:))), "the field keeps the others")
    }

    // MARK: 8.3 selection on open

    func testOpensOnTheLastJumpInThisPaneElseTheLastChapter() {
        let cs = numbered(4)   // ids 0, 10, 20, 30
        let j = TranscriptJumper()
        XCTAssertEqual(list(cs, jumper: j).selected, .chapter(30), "no jump yet: the last chapter")
        j.jump(toBlock: 25)
        XCTAssertEqual(list(cs, jumper: j).selected, .chapter(20), "a jump into chapter 20's blocks")
        j.jump(to: cs[1])
        XCTAssertEqual(list(cs, jumper: j).selected, .chapter(10))
        j.jumpToLatest()
        XCTAssertEqual(list(cs, jumper: j).selected, .chapter(30), "back to latest: the last chapter")
        XCTAssertEqual(list(cs, jumper: TranscriptJumper()).selected, .chapter(30), "another pane's jumper is its own")
        XCTAssertEqual(list([], older: true).selected, .load, "nothing loaded: the Load earlier row")
        XCTAssertTrue(list([]).selected == nil)
    }

    // MARK: 8.3 the Load earlier row

    func testLoadEarlierRowLoadsAndKeepsTheListOnTheSameChapter() {
        var all = chapters(["Earlier part of a turn", "Second", "Third"], from: 100, kinds: [0: .partial])
        var older = true, loads = 0, closes = 0
        let l = TranscriptChapterListModel(chapters: { all }, older: { older }, loadEarlier: { loads += 1 },
                                           jumper: TranscriptJumper())
        l.close = { closes += 1 }
        XCTAssertEqual(l.rows.first, .load, "the first row while older lines exist")
        XCTAssertEqual(l.rows.count, 4)
        XCTAssertTrue(l.command(#selector(NSResponder.scrollToBeginningOfDocument(_:))))
        XCTAssertEqual(l.selected, .load)
        XCTAssertTrue(l.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(loads, 1, "Return runs loadEarlier")
        XCTAssertEqual(closes, 0, "and the list stays open")
        XCTAssertTrue(l.jumper.request == nil, "no jump")
        XCTAssertEqual(l.selected, .chapter(100), "on the chapter under the row")
        // The page arrives: three chapters before, the old partial first turn merged into the page's last (id 90).
        all = chapters(["Page 0", "Page 1", "Page 2"], from: 70) + chapters(["Second", "Third"], from: 110)
        older = false
        XCTAssertEqual(l.rows.count, 5, "no Load earlier row once everything is loaded")
        XCTAssertEqual(at(l), 2, "the chapter that now holds the old first block (id 90)")
        XCTAssertTrue(l.command(#selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(l.selected, .chapter(110))
    }

    // MARK: 8.3 / 8.4 Return jumps (this list's jumper) and closes

    func testReturnJumpsThroughThePanesJumperAndCloses() {
        let cs = numbered(5), j = TranscriptJumper(), other = TranscriptJumper()
        let l = list(cs, jumper: j)
        var closes = 0
        l.close = { closes += 1 }
        XCTAssertTrue(l.command(#selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(l.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(j.request?.block, 30, "chapter 4's first block")
        XCTAssertTrue(other.request == nil, "another pane's jumper: nothing")
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(l.command(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(closes, 2, "Esc closes")
    }

    // MARK: the field, hosted by the fake presenter

    /// The field is first responder in its own (never shown) window; its commands, typing and Command-L reach the list.
    func testFieldIsFirstResponderAndDrivesTheList() throws {
        let fake = FakeCardPresenter()
        let l = list(numbered(12))
        l.close = { fake.close() }
        fake.present(AnyView(TranscriptChapterList(list: l)), size: TranscriptChapterList.size, anchor: NSView()) {}
        let w = try XCTUnwrap(fake.window)
        defer { w.close() }
        XCTAssertFalse(w.isVisible, "never shown")
        let editor = try XCTUnwrap(fake.editor, "the field is first responder in its window")
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(at(l), 10, "Up through the field")
        editor.insertText("prompt 1", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(l.query, "prompt 1", "typing filters")
        XCTAssertEqual(l.matches.map(\.ordinal), [2, 11, 12], "Prompt 1, 10, 11")
        let field = try XCTUnwrap(fake.field)
        let shiftL = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                      windowNumber: w.windowNumber, context: nil, characters: "L", charactersIgnoringModifiers: "L",
                                      isARepeat: false, keyCode: 37)!
        _ = field.performKeyEquivalent(with: shiftL)
        XCTAssertEqual(fake.closes, 0, "Shift-Command-L is not the list's key")
        let cmdL = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: w.windowNumber, context: nil, characters: "\u{0434}",
                                    charactersIgnoringModifiers: "\u{0434}", isARepeat: false, keyCode: 37)!
        XCTAssertTrue(field.performKeyEquivalent(with: cmdL))
        XCTAssertEqual(fake.closes, 1, "Command-L again closes")
    }

    // MARK: R904-f1: chapter titles are outside text

    /// Drawn through OutsideText.shown (unseen scalars dropped, three marks per base at most).
    func testTitlesAreShownThroughTheMarkCap() {
        let piled = "ab" + String(repeating: "\u{0301}", count: 30) + "\u{202E}c\u{200B}d"
        let c = Chapter(id: 0, ordinal: 1, title: piled, kind: .prompt, hasError: false)
        let shown = TranscriptChapterListModel.title(c)
        XCTAssertEqual(shown.unicodeScalars.map(\.value), OutsideText.shown(piled, max: TranscriptOutline.titleCap).unicodeScalars.map(\.value))
        XCTAssertEqual(shown.unicodeScalars.map(\.value), ("ab" + String(repeating: "\u{0301}", count: 3) + "cd").unicodeScalars.map(\.value))
        let l = list([c])
        l.query = "cd"
        XCTAssertEqual(l.matches.count, 1, "the filter reads the shown title (the hidden scalar does not split the word)")
    }

    /// One row at UI scale 0.7 and 0.85: a title of piled marks draws no ink outside its 28*s row; the same string in
    /// a plain unclipped Text does (else the method proves nothing).
    func testTitleRowDrawsNothingOutsideItsRowAt07And085() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let letters = "abcdefghijklmnop"
        let hostile = letters.map { String($0) + String(repeating: "\u{0323}", count: 24) + String(repeating: "\u{0301}", count: 24) }.joined()
        let ref = try XCTUnwrap(ImageRenderer(content: Color.black.frame(width: 4, height: 4)).cgImage)
        let refBytes = [UInt8](try XCTUnwrap(ref.dataProvider?.data as Data?))
        let bpp = ref.bitsPerPixel / 8
        let background = Array(refBytes.prefix(bpp))
        for scale in [0.7, 0.85] as [CGFloat] {
            ThemeRuntime.scale = scale
            let pad: CGFloat = 40, width = sz(360), height = sz(28)
            func ink<V: View>(_ line: V, _ tag: String) throws -> (outside: Int, inside: Int) {
                let r = ImageRenderer(content: VStack(spacing: 0) {
                    Color.clear.frame(height: pad)
                    line.frame(width: width, height: height)
                    Color.clear.frame(height: pad)
                }.background(Color.black))
                r.scale = 1
                let cg = try XCTUnwrap(r.cgImage, tag)
                let bytes = [UInt8](try XCTUnwrap(cg.dataProvider?.data as Data?, tag))
                let row = cg.bytesPerRow
                guard cg.bitsPerPixel == ref.bitsPerPixel, bytes.count >= row * cg.height, row >= cg.width * bpp else {
                    XCTFail("\(tag): unexpected bitmap")
                    return (0, 0)
                }
                let top = Int(pad), bottom = Int((pad + height).rounded(.up))
                var outside = 0, inside = 0
                for y in 0..<cg.height {
                    let start = y * row
                    let drawn = (0..<cg.width).contains { x in !bytes[(start + x * bpp)..<(start + x * bpp + bpp)].elementsEqual(background) }
                    guard drawn else { continue }
                    if y < top || y >= bottom { outside += 1 } else { inside += 1 }
                }
                fputs("x1b1319 fact \(tag): ink rows outside \(outside), inside \(inside)\n", stderr)
                return (outside, inside)
            }
            let control = try ink(Text(verbatim: hostile).font(Neon.font(11)).foregroundStyle(Neon.textPrimary).lineLimit(1), "control \(scale)")
            XCTAssertGreaterThan(control.outside, 0, "control \(scale): no ink outside an unclipped line: the method is wrong")
            let c = Chapter(id: 0, ordinal: 1, title: hostile, kind: .prompt, hasError: true)
            let drawn = try ink(ChapterRow(chapter: c), "row \(scale)")
            XCTAssertGreaterThan(drawn.inside, 0, "row \(scale): the row draws")
            XCTAssertEqual(drawn.outside, 0, "row \(scale): ink outside its own row")
        }
    }
}
