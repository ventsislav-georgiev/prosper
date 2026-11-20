import AppKit
import GhosttyTerminal
import XCTest
@testable import ProsperApp

/// #1357 (P9): ref clicks in Terminal mode. Pure column and cell maps, and the host view and controller paths with
/// recorders in their seams: no window, no event posted (refClick is called, not clicked), no card, no URL opened, no dch.
@MainActor
final class XrayTerminalRefTests: XCTestCase {
    typealias F = XrayRefLinkFixture
    let local = AgentSessionKey(dir: "/Users/example/dch", name: "api")
    let remote = AgentSessionKey(dir: "@example-host", name: "api")

    /// Red if the column map is off by one at either end, counts a wide character as one cell, or takes a ref dch did
    /// not underline.
    func testColumnMapsToTheUnderlinedRefUnderIt() throws {
        let refs = try F.parsed().entries
        let line = "fix #12 now, API-7 too"
        XCTAssertEqual([3, 4, 5, 6, 7].map { XrayRefSpans.key(atColumn: $0, in: line, refs: refs) },
                       [nil, "issue:#12", "issue:#12", "issue:#12", nil])
        XCTAssertTrue(XrayRefSpans.key(atColumn: 13, in: line, refs: refs) == nil, "API-7 is underline:false")
        XCTAssertTrue(XrayRefSpans.key(atColumn: -1, in: line, refs: refs) == nil)
        // two wide characters and a space: "#12" sits in cells 5-7, not 3-5
        let wide = "\u{65E5}\u{672C} #12"
        XCTAssertEqual([4, 5, 7, 8].map { XrayRefSpans.key(atColumn: $0, in: wide, refs: refs) }, [nil, "issue:#12", "issue:#12", nil])
        XCTAssertEqual(XrayRefSpans.cells("a\u{65E5}b"), 4)
    }

    /// Red if a url or file ref is taken on the grid: libghostty's own Cmd-click link opens those (one action per click).
    func testUrlAndFileRefsAreLeftToTheirLinks() throws {
        var refs = try F.parsed().entries
        for i in refs.indices { refs[i].shape = i == 0 ? .url : .file }
        XCTAssertTrue(XrayRefSpans.key(atColumn: 4, in: "fix #12 now", refs: refs) == nil)
        refs[0].shape = .issue
        XCTAssertEqual(XrayRefSpans.key(atColumn: 4, in: "fix #12 now", refs: refs), "issue:#12")
    }

    let grid = TerminalGridMetrics(columns: 80, rows: 24, widthPixels: 1280, heightPixels: 816, cellWidthPixels: 16, cellHeightPixels: 34)

    /// Red if the padding, the backing scale or the bounds check is lost, or an outside value reaches Int() unchecked.
    func testCellFromAPointHonoursPaddingScaleAndBounds() {
        typealias V = AgentTerminalHostView
        // 2x: a cell is 8 x 17 points, the grid starts at (4, 2)
        XCTAssertTrue(V.cell(at: CGPoint(x: 4 + 8 * 3 + 1, y: 2 + 17 * 2 + 1), grid, scale: 2).map { [$0.col, $0.row] } == [3, 2])
        XCTAssertTrue(V.cell(at: CGPoint(x: 4, y: 2), grid, scale: 2).map { [$0.col, $0.row] } == [0, 0])
        XCTAssertTrue(V.cell(at: CGPoint(x: 4 + 16 * 3 + 1, y: 2 + 34 * 2 + 1), grid, scale: 1).map { [$0.col, $0.row] } == [3, 2])
        for p in [CGPoint(x: 3, y: 10), CGPoint(x: 10, y: 1), CGPoint(x: 4 + 8 * 80, y: 10), CGPoint(x: 10, y: 2 + 17 * 24),
                  CGPoint(x: CGFloat.nan, y: 10), CGPoint(x: 10, y: CGFloat.infinity), CGPoint(x: 1e300, y: 10)] {
            XCTAssertTrue(V.cell(at: p, grid, scale: 2) == nil, "\(p)")
        }
        XCTAssertTrue(V.cell(at: CGPoint(x: 10, y: 10), grid, scale: 0) == nil)
        let empty = TerminalGridMetrics(columns: 80, rows: 24, widthPixels: 0, heightPixels: 0, cellWidthPixels: 0, cellHeightPixels: 34)
        XCTAssertTrue(V.cell(at: CGPoint(x: 10, y: 10), empty, scale: 2) == nil)
    }

    /// Red if the cell map assumes the 4x2 origin (#1682): at origin (10, 6) the same pixel lands in another cell, and the
    /// config's padding lines are the ones the fallback origin is made from.
    func testCellFromAPointHonoursANonDefaultOrigin() {
        typealias V = AgentTerminalHostView
        let o = CGPoint(x: 10, y: 6)
        XCTAssertTrue(V.cell(at: CGPoint(x: 10 + 8 * 3 + 1, y: 6 + 17 * 2 + 1), grid, scale: 2, origin: o).map { [$0.col, $0.row] } == [3, 2])
        XCTAssertTrue(V.cell(at: CGPoint(x: 9, y: 10), grid, scale: 2, origin: o) == nil, "left of the origin")
        XCTAssertTrue(V.cell(at: CGPoint(x: 4 + 8 * 3 + 1, y: 2 + 17 * 2 + 1), grid, scale: 2, origin: o).map { [$0.col, $0.row] } != [3, 2])
        XCTAssertEqual([V.gridOrigin.x, V.gridOrigin.y], [CGFloat(AgentTerminalLook.paddingX), CGFloat(AgentTerminalLook.paddingY)])
    }

    /// Red if refClick maps the point itself instead of asking the surface (#1682): the seam stands for a surface whose
    /// padding is not 4x2 and answers column 4, row 1 for a point the 4x2 map puts elsewhere; its nil is off the grid.
    func testRefClickTakesTheCellFromTheSurface() {
        let opened = Opened()
        let (v, t) = view(local, opened)
        withExtendedLifetime(t) {
            var asked: [CGPoint] = []
            v.cellAt = { asked.append($0); return $0.x < 100 ? (col: 4, row: 1) : nil }
            F.gateOn { XCTAssertTrue(v.refClick(at: CGPoint(x: 12, y: 9))) }   // the 4x2 map: column 1, row 0
            XCTAssertEqual(opened.calls.last?.line, "fix #12 now")
            XCTAssertEqual(opened.calls.last?.col, 4)
            F.gateOn { XCTAssertFalse(v.refClick(at: CGPoint(x: 200, y: 9))) }
            XCTAssertEqual(asked.count, 2)
            XCTAssertEqual(opened.calls.count, 1)
        }
    }

    /// Red if a view with no surface (rows have none) stops falling back on the config's padding, or answers a cell.
    func testNoSurfaceAnswersNoCell() {
        let (v, t) = view(local, Opened())
        withExtendedLifetime(t) { XCTAssertTrue(v.surfaceCell(at: CGPoint(x: 40, y: 20)) == nil) }
    }

    private final class Opened { var calls: [(key: AgentSessionKey, line: String, col: Int)] = [] }

    private func view(_ key: AgentSessionKey, _ opened: Opened) -> (AgentTerminalHostView, AgentTerminalController) {
        let t = AgentTerminalController()
        t.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        t.makeScreen = { AgentTerminalTests.FakeScreen($0) }
        t.attach(key)
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        v.owner = t
        v.gridMetrics = grid
        v.viewportText = { "$ git log\nfix #12 now\n" }
        v.openRef = { _, key, line, col in opened.calls.append((key, line, col)); return true }
        return (v, t)
    }

    /// Red if refClick reads another row or column than the one under the point (no window: scale 2), skips a remote
    /// row (#1568: it opens its card too), or runs with gate B off.
    func testRefClickHandsTheRowAndColumnUnderThePoint() {
        let opened = Opened()
        let (v, t) = view(local, opened)
        withExtendedLifetime(t) {
            F.gateOn { XCTAssertTrue(v.refClick(at: CGPoint(x: 4 + 8 * 4 + 2, y: 2 + 17 + 3))) }
            XCTAssertEqual(opened.calls.count, 1)
            XCTAssertEqual(opened.calls.last?.key, local)
            XCTAssertEqual(opened.calls.last?.line, "fix #12 now")
            XCTAssertEqual(opened.calls.last?.col, 4)
            F.gateOn { XCTAssertFalse(v.refClick(at: CGPoint(x: 10, y: 2 + 17 * 5 + 1)), "row 5 is past the text") }
            let old = XrayRefLink.decorate
            XrayRefLink.decorate = { false }
            XCTAssertFalse(v.refClick(at: CGPoint(x: 4 + 8 * 4 + 2, y: 2 + 17 + 3)), "gate B off")
            XrayRefLink.decorate = old
            XCTAssertEqual(opened.calls.count, 1)
        }
        let far = Opened()
        let (rv, rt) = view(remote, far)
        withExtendedLifetime(rt) {
            F.gateOn { XCTAssertTrue(rv.refClick(at: CGPoint(x: 4 + 8 * 4 + 2, y: 2 + 17 + 3))) }
        }
        XCTAssertEqual(far.calls.count, 1, "#1568: a remote row's grid opens its card")
        XCTAssertEqual(far.calls.last?.key, remote)
    }

    /// Red if a Cmd-down skips refClick or a plain down runs it. The NSEvent is built and handed to the view, never posted.
    func testOnlyACommandDownLooksForARef() throws {
        let opened = Opened()
        let (v, t) = view(local, opened)
        try withExtendedLifetime(t) {
            func down(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
                // locationInWindow with no window is the view's own space (unflipped): row 1, column 4 from the top
                try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 4 + 8 * 4 + 2, y: 410 - (2 + 17 + 3)),
                                                 modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1))
            }
            try F.gateOn {
                v.mouseDown(with: try down([]))
                XCTAssertEqual(opened.calls.count, 0, "a plain click is the program's")
                v.mouseDown(with: try down(.command))
                XCTAssertEqual(opened.calls.count, 1)
                XCTAssertEqual(opened.calls.last?.col, 4)
            }
        }
    }

    /// Red if a prosper-xray link reaches the system or the Text Viewer, misses the card path, or a remote row's does.
    func testAProsperXrayLinkGoesToTheCardPathOnly() throws {
        for (key, expected) in [(local, 1), (remote, 0)] {
            let t = AgentTerminalController()
            t.spawn = { _, _ in AgentTerminalTests.FakeChild() }
            t.makeScreen = { AgentTerminalTests.FakeScreen($0) }
            t.attach(key)
            var links: [URL] = []
            t.openURL = { XCTFail("system: \($0)") }
            t.showFile = { XCTFail("viewer: \($0)") }
            t.openRefLink = { url, _, k in links.append(url); XCTAssertEqual(k, key) }
            t.open("prosper-xray://ref?k=issue%3A%2312")
            t.open("PROSPER-XRAY://ref?k=issue%3A%2312")
            XCTAssertEqual(links.count, 2 * expected, "\(key)")
        }
    }

    /// Red if a window with no model (no focused pane) yields refs or opens a card from the grid, or a nil window does.
    func testAWindowWithoutAModelOpensNothing() {
        let w = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        XCTAssertTrue(XrayRefLink.terminalRefs(w, local) == nil)
        XCTAssertFalse(XrayRefLink.openOnGrid(w, key: local, line: "fix #12 now", column: 4))
        XCTAssertFalse(XrayRefLink.openOnGrid(nil, key: local, line: "fix #12 now", column: 4))
    }
}
