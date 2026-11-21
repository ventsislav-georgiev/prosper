import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1417 (#1356 step 3): the ref card. A fake presenter records each card and runs its `closed` as XrayPopoverPresenter
/// does (one at a time; the shown card's closed runs when it goes); a fake runner (XrayRefRunTests.Run) answers the --ref
/// read; Copy writes a scratch pasteboard; Open goes to a recorder seam. Hosted only in never-shown windows; no popover,
/// no URL opened, no key or mouse event posted, no dch.
@MainActor
final class XrayRefPopoverTests: XCTestCase {
    override func setUp() { XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 84, 0]) }   // #1443: stdin needs 1.84.0
    override func tearDown() { XrayPanels.probed = nil }
    typealias T = XrayRefStreamTests

    nonisolated static let refs = #"""
    [{"key":"issue:#12","shape":"issue","text":"#12","count":2,"last_offset":376,"title":"Login retries"},\#
    {"key":"issue:#1","shape":"issue","text":"#1","count":1},\#
    {"key":"ticket:x","shape":"ticket","text":"x","count":1},\#
    {"key":"ticket:-x","shape":"ticket","text":"-x","count":1},\#
    {"key":"url:https://example.org/acme/api/pull/7","shape":"url","text":"https://example.org/acme/api/pull/7","count":1},\#
    {"key":"url:ftp://example.org/acme","shape":"url","text":"ftp://example.org/acme","count":1},\#
    {"key":"url:file:///Users/example/notes.md","shape":"url","text":"file:///Users/example/notes.md","count":1},\#
    {"key":"file:/Users/example/acme/api/README.md","shape":"file","text":"README.md","count":1}]
    """#

    nonisolated static let memoryRows = [
        #"{"memory":{"id":"m1","title":"Retries","note":"login","kind":"project","scope":"project","updated":null,"path":"/Users/example/mem/m1.md","session":null,"chapter":null,"body":"Login retries twice (#12)."}}"#,
        #"{"memory":{"id":"m2","title":"PROJ-7 notes","note":"about PROJ-7","kind":"project","scope":"project","updated":null,"path":"/Users/example/mem/m2.md","session":null,"chapter":null,"body":"Nothing here."}}"#,
    ]

    /// The window's presenter, faked: present closes the shown card first (its closed runs), close runs it once.
    @MainActor final class Cards {
        var sizes: [CGSize] = []
        var views: [AnyView] = []
        var closeds: [@MainActor () -> Void] = []
        var shown: (@MainActor () -> Void)?
        var closes = 0
        func present(_ v: AnyView, _ s: CGSize, _ closed: @escaping @MainActor () -> Void) {
            close()
            (views, sizes, closeds) = (views + [v], sizes + [s], closeds + [closed])
            shown = closed
        }
        func close() {
            let f = shown
            shown = nil
            if f != nil { closes += 1 }
            f?()
        }
    }

    func entry(_ text: String) throws -> XrayRefs.Entry {
        let r = try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs: Self.refs)))
        return try XCTUnwrap(r.entries.first { $0.text == text })
    }

    /// A local panel on "api" with three tasks and two memories (one of each mentions #12), wired to `cards` and `panels`.
    func panel(_ run: XrayRefRunTests.Run, _ cards: Cards, _ panels: XrayPanels) -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
        (p.dch, p.run) = ("/fake/dch", run.run)
        p.panels = panels
        p.home = "/Users/example"
        p.presentRef = { cards.present($0, $1, $2) }
        p.dismiss = { cards.close() }
        p.tasks = XrayTasks(schema: 1, source: "claude", sessionTitle: nil, partial: false, headerWarn: nil, doneWarn: nil,
                            droppedCount: 0, skippedLines: 0,
                            tasks: [XrayRefContextTests.task("1", title: "Fix login", note: "see #12 for the retries"),
                                    XrayRefContextTests.task("2", title: "Ship PROJ-7"),
                                    XrayRefContextTests.task("3", title: "Docs", label: "#12 follow-up")])
        p.takeMemory((0, XrayPanelTasksTests.ndjson([XrayPanelMemoryTests.header] + Self.memoryRows
                                                     + [#"{"done":true,"count":2,"dropped":0}"#])))
        return p
    }

    /// Waits (at most 5 s) until the fake has seen `n` calls.
    func called(_ run: XrayRefRunTests.Run, _ n: Int) async {
        let end = Date().addingTimeInterval(5)
        while run.calls.count < n, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// Red without presentRef in openRef (no card), or with an unscaled size.
    func testRowReturnPresentsOnceAtTheCardSize() async throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 1.0] {
            ThemeRuntime.scale = scale
            let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
            p.openRef(try entry("#12"))
            XCTAssertEqual(cards.sizes, [CGSize(width: 460 * scale, height: 520 * scale)], "once, 460x520\u{00B7}s at \(scale) (#1760)")
            XCTAssertEqual(p.refCard?.text, "#12")
            await panels.refReading?.value
            XCTAssertEqual(run.calls, [["--xray", "api", "--ref", "-", "--scope", "project", "--full", "--json"]])
            XCTAssertEqual(run.stdins, ["#12\n"], "#1410: the ref on stdin")
            XCTAssertEqual(p.refContext?.ref, "#12")
        }
        // A text runRef refuses: the card still opens (its header is the row's) and says why; nothing runs.
        let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
        p.openRef(try entry("-x"))
        XCTAssertEqual(cards.sizes.count, 1)
        XCTAssertEqual(p.refNote, XrayPanelModel.refNotARef)
        XCTAssertEqual(run.calls.count, 0)
        // #1419 (R1410-i1): a local text over dch's stdin cap says why, at 255 bytes (runs) and 256 (refused); "-x" keeps its note.
        var long = try entry("#12")
        long.text = String(repeating: "a", count: 256)
        let r256 = XrayRefRunTests.Run(), c256 = Cards(), n256 = XrayPanels(), p256 = panel(r256, c256, n256)
        p256.openRef(long)
        XCTAssertEqual(p256.refNote, XrayPanelModel.refTooLong, "256 + newline is over dch's 256")
        XCTAssertEqual(r256.calls.count, 0)
        long.text = String(repeating: "a", count: 255)
        let r255 = XrayRefRunTests.Run(), c255 = Cards(), n255 = XrayPanels(), p255 = panel(r255, c255, n255)
        p255.openRef(long)
        XCTAssertTrue(p255.refNote == nil, "255 + newline runs")
        await n255.refReading?.value
        XCTAssertEqual(r255.calls.count, 1)
        XCTAssertNotEqual(p256.refNote, XrayPanelModel.refNotARef)
        XCTAssertEqual(XrayRefPopover.header(try entry("#12"), complete: true, home: "/Users/example", cwd: nil),
                       ["Issue #12", "Login retries", "2 mentions"], "the header from the row, before any --ref line")
        XCTAssertEqual(XrayRefPopover.header(try entry("#12"), complete: false, home: "/Users/example", cwd: nil).last, "\u{2265}2 mentions")
    }

    func testFourTabsAndTheirCounts() async throws {
        let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
        p.openRef(try entry("#12"))
        XCTAssertEqual(XrayRefPopover.Tab.allCases.map { XrayRefPopover.title($0, p) }, ["Mentions", "Definition", "Tasks", "Memory"],
                       "names alone before the read lands")
        await panels.refReading?.value
        XCTAssertEqual(XrayRefPopover.Tab.allCases.map { XrayRefPopover.title($0, p) },
                       ["Mentions 2", "Definition 1", "Tasks 2", "Memory 1"])
        XCTAssertEqual(XrayRefPopover.spoken(.mentions, p), "Mentions, 2")
    }

    /// Red with M3d (the Tasks tab lists the panel's every task): only the tasks that mention the ref, else the line.
    func testTasksAndMemoryTabsListOnlyMatchingRowsElseSayNone() async throws {
        let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
        p.openRef(try entry("#12"))
        await panels.refReading?.value
        XCTAssertEqual(XrayRefPopover.tasks(p).map(\.id), ["1", "3"], "a note or a label that holds #12; not PROJ-7")
        XCTAssertEqual(p.refContext?.memory.map(\.id), ["m1"])
        XCTAssertEqual(XrayRefPopover.count(.tasks, p), 2)
        XCTAssertEqual(XrayRefPopover.empty(.tasks, ref: "#12"), "No tasks mention #12")
        XCTAssertEqual(XrayRefPopover.empty(.memory, ref: "#12"), "No memories mention #12")
        p.tasks = nil
        p.openRef(try entry("#12"))
        await panels.refReading?.value
        XCTAssertEqual(XrayRefPopover.tasks(p).count, 0, "no task mentions it: the empty line is drawn")
    }

    /// Red with M3b (Open for a non-http url): the seam once for https; never for ftp:, file: or a non-url ref.
    func testOpenCallsTheSeamOnceForHttpsOnly() throws {
        let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
        var opened: [URL] = []
        p.openURL = { opened.append($0) }
        for t in ["https://example.org/acme/api/pull/7", "ftp://example.org/acme", "file:///Users/example/notes.md", "README.md", "#12"] {
            XrayRefPopover(panel: p, entry: try entry(t), complete: true).openLink()
        }
        XCTAssertEqual(opened, [URL(string: "https://example.org/acme/api/pull/7")].compactMap { $0 })
        XCTAssertTrue(XrayRefPopover.openURL(try entry("ftp://example.org/acme")) == nil, "no Open button")
        XCTAssertTrue(XrayRefPopover.openURL(try entry("README.md")) == nil, "a file ref: Copy only (OQ-164)")
    }

    /// Red with M3a (the close does not cancel): the presenter's close and Esc each cancel the read in flight; a replaced
    /// card's close never cancels the newer card's read.
    func testClosingTheCardCancelsItsReadOnly() async throws {
        let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
        p.openRef(try entry("#1"))
        var first = panels.refReading
        await called(run, 1)
        cards.close()
        await first?.value
        XCTAssertEqual(run.cancelled, 1, "the presenter closed it")
        XCTAssertTrue(panels.refReading == nil)
        p.openRef(try entry("#1"))
        first = panels.refReading
        await called(run, 2)
        XrayRefPopover(panel: p, entry: try entry("#1"), complete: true).escape()
        await first?.value
        XCTAssertEqual(run.cancelled, 2, "Esc closed it")
        p.openRef(try entry("#1"))
        first = panels.refReading
        await called(run, 3)
        p.openRef(try entry("#12"))   // runRef cancels #1, then the present closes #1's card: its closed must spare #12
        await first?.value
        await panels.refReading?.value
        XCTAssertEqual(run.cancelled, 3)
        XCTAssertEqual(p.refContext?.ref, "#12", "the newer read landed")
    }

    final class Box { var d: [String: CGRect] = [:] }

    /// The strip at 0.7, 0.85 and 1.0: inside the card's padding, never clipped (one device pixel of slack).
    func testTabStripFitsTheCardAtEveryScale() throws {
        let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
        p.refContext = XrayRefContext(T.parse(T.golden), ref: "#12", tasks: p.tasks, memory: p.memory)
        let e = try entry("#12"), pixel = AXTreeSupport.devicePixel
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let size = XrayRefPopover.size, box = Box()
            AgentPaneArea.probe = { k, _, r in box.d[k] = r }
            let v = XrayRefPopover(panel: p, entry: e, complete: true)
                .environment(\.agentPaneID, UUID()).coordinateSpace(.named(agentPaneAreaSpace))
            let (win, host) = AXTreeSupport.hosted(v, size)
            for i in 0..<43 where i >= 40 || box.d["xrayRefTabs"] == nil {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            AgentPaneArea.probe = nil
            win.contentView = nil
            win.close()
            let f = box.d["xrayRefTabs"] ?? .zero
            XCTAssertGreaterThan(f.width, 0, "drawn at \(scale)")
            XCTAssertGreaterThanOrEqual(f.minX, sz(12) - pixel, "not clipped at the left at \(scale)")
            XCTAssertLessThanOrEqual(f.maxX, size.width - sz(12) + pixel, "not clipped at the right at \(scale)")
        }
    }

    /// #1816: a card with more turn blocks than fit: after layout, every row of the blocks that fit is realized inside
    /// the visible rect at once, no scroll; the last block is not built (the list stays lazy). Red with lazy-row-offset-ids
    /// (the rows keyed by their offset in the block: each block's row 0 shared the first block's view and drew blank).
    func testEveryRowInTheVisibleRectDrawsWithoutAScroll() throws {
        let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
        let sizes = [2, 1, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2]   // turns 12...1, newest first
        var lines: [String] = [], offset = 0
        for (b, n) in sizes.enumerated() {
            for r in 0..<n {
                offset += 1
                lines.append(XrayRefTurnTests.mention(turn: sizes.count - b, offset: offset, sentence: "Work on #12 row \(b)-\(r)"))
            }
        }
        p.refContext = XrayRefTurnTests.context(lines)
        XCTAssertEqual(p.refContext?.turns?.count, sizes.count, "one block per turn")
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1
        let box = Box()
        AgentPaneArea.probe = { k, _, r in box.d[k] = r }
        let v = XrayRefPopover(panel: p, entry: try entry("#12"), complete: true)
            .environment(\.agentPaneID, UUID()).coordinateSpace(.named(agentPaneAreaSpace))
        let (win, host) = AXTreeSupport.hosted(v, XrayRefPopover.size)
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        AgentPaneArea.probe = nil
        win.contentView = nil
        win.close()
        let scroll = box.d["xrayRefScroll"] ?? .zero
        XCTAssertGreaterThan(scroll.height, 0, "the scroll view is laid out")
        for row in ["0-0", "0-1", "1-0", "2-0"] {   // the first three blocks: they fit the card's list at scale 1
            let f = box.d["xrayRefRow:Work on #12 row \(row)"] ?? .zero
            XCTAssertGreaterThan(f.height, 0, "row \(row) is built without a scroll")
            XCTAssertTrue(f.height == 0 || scroll.contains(CGPoint(x: f.midX, y: f.minY)), "row \(row) lies in the visible rect")
        }
        XCTAssertTrue(box.d["xrayRefRow:Work on #12 row \(sizes.count - 1)-1"] == nil, "the last block is not built: still lazy")
    }

    /// VoiceOver: the header's spoken row, a tab group with each tab's count and the shown one selected, the filter.
    /// #1760: no Copy and no Search button (selectable text and the inline filter replace them); Mentions is shown first.
    func testAccessibilityTabGroupAndLabels() throws {
        let run = XrayRefRunTests.Run(), cards = Cards(), panels = XrayPanels(), p = panel(run, cards, panels)
        p.refContext = XrayRefContext(T.parse(T.golden), ref: "#12", tasks: p.tasks, memory: p.memory)
        let v = XrayRefPopover(panel: p, entry: try entry("#12"), complete: true)
        let tree = AXTreeSupport.tree(v, XrayRefPopover.size) { t in t.contains { $0.reads("Filter this card") } }
        for n in ["Issue #12, Login retries, 2 mentions", "Ref tabs", "Definition, 1", "Mentions, 2", "Tasks, 2", "Memory, 1",
                  "Filter this card"] {
            XCTAssertTrue(tree.contains { $0.reads(n) }, n)
        }
        XCTAssertTrue(tree.contains { $0.reads("Mentions, 2") && $0.selected }, "Mentions is the shown tab")
        XCTAssertFalse(tree.contains { $0.names.contains { $0.hasPrefix("Copy") || $0.hasPrefix("Search this session") } },
                       "no Copy or Search button")
        XCTAssertFalse(tree.contains { $0.names.contains { $0.hasPrefix("Open ") } }, "no Open for an issue")
    }

    /// R1416-s1: a partial stream with nothing found reads "No definition found so far", never "found found".
    func testEmptyPartialStreamHeading() {
        XCTAssertEqual(XrayRefContext(T.parse([T.first]), ref: "#12", tasks: nil, memory: nil).heading, "No definition found so far")
        XCTAssertEqual(XrayRefContext(T.parse([T.first, T.done]), ref: "#12", tasks: nil, memory: nil).heading, "No definition found")
    }
}
