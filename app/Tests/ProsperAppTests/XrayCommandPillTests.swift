import AppKit
import GhosttyTerminal
import XCTest
@testable import ProsperApp

/// #1952: hovering a command block ("! cmd" / "$ cmd") in a live local pane shows a Copy pill on the pane's right edge.
/// The pointer is handed to commandHover directly (no event posted), the host is never in a window (windowShown seam),
/// the pasteboard is a private named one (never NSPasteboard.general), the settle item is kept and performed by hand.
@MainActor
final class XrayCommandPillTests: XCTestCase {
    typealias V = XrayGridMarksView
    static let lines = [
        "  Run this:",
        "",
        "  ! gcloud sql backups create --instance=canary",
        "    --project=example --description=probe",
        "",
        "plain prose here",
        "$ ls -la",
        "next",
        "⏺ ! echo hi",
        "",
        "  !nospace",
        "",
        "  ! ",
    ]

    /// Red if a "! " or "$ " head is missed, its wrapped rows are not joined as one line, the "! "/"$ " stays, a prose,
    /// blank or out-of-range row gives a block, a column-0 head takes the next row, or a Claude Code marker hides the head.
    func testTheBlockRule() {
        let l = Self.lines, cmd = "gcloud sql backups create --instance=canary --project=example --description=probe"
        XCTAssertEqual(V.commandBlock(l, at: 2, cols: 80), .init(row: 2, text: cmd))
        XCTAssertEqual(V.commandBlock(l, at: 3, cols: 80), .init(row: 2, text: cmd), "a continuation row finds its head")
        XCTAssertEqual(V.commandBlock(l, at: 6, cols: 80), .init(row: 6, text: "ls -la"))
        XCTAssertEqual(V.commandBlock(l, at: 8, cols: 80), .init(row: 8, text: "echo hi"))
        for row in [0, 1, 4, 5, 7, 9, 10, 11, 12, -1, 13] {
            XCTAssertTrue(V.commandBlock(l, at: row, cols: 80) == nil, "row \(row)")
        }
    }

    /// Red if a token Claude Code split at a full row gets a space, or a trailing " \" keeps its backslash.
    func testTheJoinRule() {
        // the head row fills 20 columns: the URL was split mid-way
        XCTAssertEqual(V.commandBlock(["  ! https://ex.com/a", "  /b/c"], at: 1, cols: 20), .init(row: 0, text: "https://ex.com/a/b/c"))
        XCTAssertEqual(V.commandBlock(["  ! https://ex.com/a", "  /b/c"], at: 0, cols: 80), .init(row: 0, text: "https://ex.com/a /b/c"))
        XCTAssertEqual(V.commandBlock(["  $ make \\", "    all"], at: 0, cols: 80), .init(row: 0, text: "make all"))
    }

    @MainActor
    final class Rig {
        let t: AgentTerminalController
        let v: AgentTerminalHostView
        var items: [DispatchWorkItem] = []
        init(t: AgentTerminalController, v: AgentTerminalHostView) { (self.t, self.v) = (t, v) }
        var marks: XrayGridMarksView { v.marks }
        func settle() { for i in items where !i.isCancelled { i.perform() } }
    }

    /// A live local terminal (never in a window), cells 8 x 17 points through the cellAt seam, the grid settled.
    func rig(_ viewport: [String] = XrayCommandPillTests.lines) throws -> Rig {   // Gate B plays no part
        let t = AgentTerminalController()
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        let r = Rig(t: t, v: v)
        t.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        t.makeScreen = { AgentTerminalTests.FakeScreen($0) }
        v.owner = t
        t.view = v
        v.gridMetrics = TerminalGridMetrics(columns: 80, rows: 24, widthPixels: 1280, heightPixels: 816, cellWidthPixels: 16, cellHeightPixels: 34)
        v.viewportText = { viewport.joined(separator: "\n") }
        v.cellAt = { p in (Int(p.x / 8), Int(p.y / 17)) }
        v.marks.windowShown = { _ in true }
        v.marks.after = { [weak r] _, item in r?.items.append(item) }
        t.attach(AgentSessionKey(dir: "/Users/example/dch", name: "api"))
        t.gridChanged(cols: 80, rows: 24)
        t.gridChanged(cols: 80, rows: 24, generation: t.generation)
        XCTAssertEqual(t.phase, .live)
        r.settle()
        XCTAssertTrue(v.marks.settle == nil)
        return r
    }

    static func at(row: Int) -> CGPoint { CGPoint(x: 40, y: CGFloat(row) * 17 + 5) }

    /// Red if the pill is missing on a command row, sits off the head row or off the right edge, shows on prose, reads the
    /// viewport per move, or lacks its tooltip and label.
    func testHoverShowsThePillOnTheHeadRowAtTheRightEdge() throws {
        let r = try rig(), m = r.marks
        m.commandHover(Self.at(row: 3))
        XCTAssertEqual(m.hoveredCommand?.row, 2)
        XCTAssertFalse(m.pill.isHidden)
        XCTAssertEqual(m.pill.frame.minY, AgentTerminalHostView.gridOrigin.y + 2 * 17, accuracy: 0.01)
        XCTAssertEqual(m.pill.frame.maxX, m.bounds.width - 4, accuracy: 0.01)
        XCTAssertEqual(m.commandReads, 1)
        m.commandHover(CGPoint(x: 100, y: 3 * 17 + 9))
        XCTAssertEqual(m.commandReads, 1, "a move in the same row reads nothing")
        m.commandHover(Self.at(row: 5))
        XCTAssertTrue(m.pill.isHidden, "prose")
        XCTAssertTrue(m.hoveredCommand == nil)
        m.commandHover(Self.at(row: 2))
        XCTAssertFalse(m.pill.isHidden)
        m.commandHover(nil)
        XCTAssertTrue(m.pill.isHidden, "the pointer left")
        XCTAssertEqual(m.pill.copy.toolTip, "Copy command")
        XCTAssertEqual(m.pill.copy.accessibilityLabel(), "Copy command")
    }

    /// Red if any point outside the shown pill takes a click, the pill's button does not, or a hidden pill takes one.
    func testHitTestIsNilOutsideThePill() throws {
        let r = try rig(), m = r.marks
        let centre = CGPoint(x: m.bounds.width - 4 - 17, y: AgentTerminalHostView.gridOrigin.y + 2 * 17 + 8)
        let inHost = { (p: CGPoint) in r.v.convert(p, from: m) }
        XCTAssertTrue(m.hitTest(inHost(centre)) == nil, "hidden pill")
        m.commandHover(Self.at(row: 2))
        XCTAssertFalse(m.pill.isHidden)
        XCTAssertTrue(m.hitTest(inHost(centre)) === m.pill.copy)
        XCTAssertTrue(r.v.hitTest(inHost(centre)) === m.pill.copy, "through the terminal's own hitTest")
        for p in [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: AgentTerminalHostView.gridOrigin.y + 2 * 17 + 8),
                  CGPoint(x: centre.x, y: centre.y + 17)] {
            XCTAssertTrue(m.hitTest(inHost(p)) == nil, "\(p)")
            XCTAssertTrue(r.v.hitTest(inHost(p)) === r.v, "\(p)")
        }
        m.hideCommand()
        XCTAssertTrue(m.hitTest(inHost(centre)) == nil, "hidden again: the overlay never keeps the click")
    }

    /// Red if Copy keeps the "! " / "$ ", writes anywhere but the host's pasteboard, shows no "Copied", or the button is
    /// not wired to it.
    func testCopyStripsThePrefixAndSaysCopied() throws {
        let r = try rig(), m = r.marks
        let pb = NSPasteboard(name: .init("eu.illegible.prosper.test.1952.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        r.v.pasteboard = { pb }
        XCTAssertTrue(m.pill.copy.target === m)
        XCTAssertEqual(m.pill.copy.action, #selector(XrayGridMarksView.copyCommand))
        m.commandHover(Self.at(row: 6))
        m.copyCommand()
        XCTAssertEqual(pb.string(forType: .string), "ls -la")
        XCTAssertEqual(r.t.notice, XrayGridMarksView.copiedText)
        m.commandHover(Self.at(row: 3))
        m.copyCommand()
        XCTAssertEqual(pb.string(forType: .string), "gcloud sql backups create --instance=canary --project=example --description=probe")
        m.commandHover(Self.at(row: 5))
        m.copyCommand()
        XCTAssertEqual(pb.string(forType: .string), "gcloud sql backups create --instance=canary --project=example --description=probe",
                       "no block: nothing copied")
    }

    /// Red if output leaves the pill up, a move before the settle shows it, or the next move after the settle does not.
    func testOutputHidesItUntilTheSettle() throws {
        let r = try rig(), m = r.marks
        m.commandHover(Self.at(row: 2))
        XCTAssertFalse(m.pill.isHidden)
        m.output()
        XCTAssertTrue(m.pill.isHidden)
        m.commandHover(Self.at(row: 2))
        XCTAssertTrue(m.pill.isHidden, "not settled")
        r.settle()
        XCTAssertTrue(m.pill.isHidden, "comes back on a move, not on the settle")
        m.commandHover(Self.at(row: 2))
        XCTAssertFalse(m.pill.isHidden)
        m.output(resized: true)
        XCTAssertTrue(m.pill.isHidden, "a resize")
    }

    /// Red if an unfocused pane, a window not shown or a pane not live shows the pill.
    func testOnlyALiveLocalFocusedPane() throws {
        let r = try rig(), m = r.marks
        r.t.paneFocused = { false }
        m.commandHover(Self.at(row: 2))
        XCTAssertTrue(m.pill.isHidden, "unfocused")
        r.t.paneFocused = { true }
        m.windowShown = { _ in false }
        m.commandHover(Self.at(row: 2))
        XCTAssertTrue(m.pill.isHidden, "window not shown")
        m.windowShown = { _ in true }
        m.commandHover(Self.at(row: 2))
        XCTAssertFalse(m.pill.isHidden)
        r.t.detach()
        m.commandHover(Self.at(row: 3))
        XCTAssertTrue(m.pill.isHidden, "not live")
    }
}
