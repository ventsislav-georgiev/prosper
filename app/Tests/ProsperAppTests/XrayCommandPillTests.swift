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
        XCTAssertEqual(V.commandBlock(l, at: 2, cols: 80), .init(row: 2, text: cmd, last: 3, col: 2))
        XCTAssertEqual(V.commandBlock(l, at: 3, cols: 80), .init(row: 2, text: cmd, last: 3, col: 2), "a continuation row finds its head")
        XCTAssertEqual(V.commandBlock(l, at: 6, cols: 80), .init(row: 6, text: "ls -la", last: 6, col: 0))
        XCTAssertEqual(V.commandBlock(l, at: 8, cols: 80), .init(row: 8, text: "echo hi", last: 8, col: 2))
        for row in [0, 1, 4, 5, 7, 9, 10, 11, 12, -1, 13] {
            XCTAssertTrue(V.commandBlock(l, at: row, cols: 80) == nil, "row \(row)")
        }
    }

    /// Red if a token Claude Code split at a full row gets a space, or a trailing " \" keeps its backslash.
    func testTheJoinRule() {
        // the head row fills 20 columns: the URL was split mid-way
        XCTAssertEqual(V.commandBlock(["  ! https://ex.com/a", "  /b/c"], at: 1, cols: 20), .init(row: 0, text: "https://ex.com/a/b/c", last: 1, col: 2))
        XCTAssertEqual(V.commandBlock(["  ! https://ex.com/a", "  /b/c"], at: 0, cols: 80), .init(row: 0, text: "https://ex.com/a /b/c", last: 1, col: 2))
        XCTAssertEqual(V.commandBlock(["  $ make \\", "    all"], at: 0, cols: 80), .init(row: 0, text: "make all", last: 1, col: 2))
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
    /// viewport per move, or lacks its tooltip and label. #2040: a shown pill stays on prose and when the pointer leaves.
    func testHoverShowsThePillOnTheHeadRowAtTheRightEdge() throws {
        let r = try rig(), m = r.marks
        m.commandHover(Self.at(row: 3))
        XCTAssertEqual(m.hoveredCommand?.row, 2)
        XCTAssertFalse(m.pill.isHidden)
        XCTAssertEqual(m.pill.frame.midY, AgentTerminalHostView.gridOrigin.y + 2 * 17 + 8.5, accuracy: 0.01, "#1954: centred on the head row")
        XCTAssertEqual(m.pill.frame.maxX, m.bounds.width - 4, accuracy: 0.01)
        XCTAssertEqual(m.commandReads, 1)
        m.commandHover(CGPoint(x: 100, y: 3 * 17 + 9))
        XCTAssertEqual(m.commandReads, 1, "a move in the same row reads nothing")
        m.hideCommand()
        m.commandHover(Self.at(row: 5))
        XCTAssertTrue(m.pill.isHidden, "prose")
        XCTAssertTrue(m.hoveredCommand == nil)
        m.commandHover(Self.at(row: 2))
        XCTAssertFalse(m.pill.isHidden)
        m.commandHover(Self.at(row: 5))
        XCTAssertFalse(m.pill.isHidden, "#2040: prose after a command keeps it")
        m.commandHover(nil)
        XCTAssertFalse(m.pill.isHidden, "#2040: the pointer left: kept")
        XCTAssertEqual(m.pill.copy.toolTip, "Copy command")
        XCTAssertEqual(m.pill.copy.accessibilityLabel(), "Copy command")
    }

    /// Red if any point outside the shown pill takes a click, the pill's button does not, or a hidden pill takes one.
    /// #1953: the pill is 3 x 21 = 63 pt wide: Copy on its left half, Run on its right half, both take their clicks.
    func testHitTestIsNilOutsideThePill() throws {
        let r = try rig(), m = r.marks
        let centre = CGPoint(x: m.bounds.width - 4 - 17, y: AgentTerminalHostView.gridOrigin.y + 2 * 17 + 8)
        let left = CGPoint(x: m.bounds.width - 4 - 63 + 10, y: centre.y)
        let inHost = { (p: CGPoint) in r.v.convert(p, from: m) }
        XCTAssertTrue(m.hitTest(inHost(centre)) == nil, "hidden pill")
        m.commandHover(Self.at(row: 2))
        XCTAssertFalse(m.pill.isHidden)
        m.pill.layoutSubtreeIfNeeded()
        XCTAssertTrue(m.hitTest(inHost(centre)) === m.pill.run, "#1953: the right half is Run")
        XCTAssertTrue(r.v.hitTest(inHost(centre)) === m.pill.run, "through the terminal's own hitTest")
        XCTAssertTrue(m.hitTest(inHost(left)) === m.pill.copy, "#1953: the left half is Copy, inside the wider pill")
        XCTAssertTrue(r.v.hitTest(inHost(left)) === m.pill.copy)
        XCTAssertEqual(m.pill.copy.frame.width, m.pill.run.frame.width, accuracy: 0.01, "both the same size")
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
        m.hideCommand()
        pb.clearContents()
        m.commandHover(Self.at(row: 5))
        m.copyCommand()
        XCTAssertTrue(pb.string(forType: .string) == nil, "no block: nothing copied")
    }

    /// #2040: red if output that leaves the block as it was hides the pill, a move before the settle does not show it, or a
    /// resize keeps it.
    func testOutputKeepsItAndAResizeHidesIt() throws {
        let r = try rig(), m = r.marks
        m.commandHover(Self.at(row: 2))
        XCTAssertFalse(m.pill.isHidden)
        m.output()
        XCTAssertFalse(m.pill.isHidden, "#2040: the block did not change")
        m.commandHover(Self.at(row: 6))
        XCTAssertTrue(m.settle != nil)
        XCTAssertEqual(m.hoveredCommand?.row, 6, "#2040: shown before the settle")
        XCTAssertFalse(m.pill.isHidden)
        m.output(resized: true)
        XCTAssertTrue(m.pill.isHidden, "a resize")
    }

    /// A rig whose viewport is `vp` (changed by the row) and whose viewport reads are counted in `reads`.
    final class Screen {
        var vp: [String]
        var reads = 0
        init(_ vp: [String]) { self.vp = vp }
    }
    func screen(_ r: Rig, _ vp: [String] = XrayCommandPillTests.lines) -> Screen {
        let s = Screen(vp)
        r.v.viewportText = { [unowned s] in s.reads += 1; return s.vp.joined(separator: "\n") }
        return s
    }

    /// #2040: red if a drain that leaves the block's rows as they were hides the pill or moves it, or Copy then copies
    /// anything but the command.
    func testOutputThatLeavesTheBlockKeepsThePill() throws {
        let r = try rig(), m = r.marks, s = screen(r)
        let pb = NSPasteboard(name: .init("eu.illegible.prosper.test.2040.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        r.v.pasteboard = { pb }
        m.commandHover(Self.at(row: 3))
        let frame = m.pill.frame
        for i in 0..<4 {
            s.vp[7] = "status \(i)"   // a status line redraw elsewhere
            m.output()
            XCTAssertFalse(m.pill.isHidden, "drain \(i)")
            XCTAssertEqual(m.pill.frame, frame, "drain \(i)")
        }
        r.settle()
        XCTAssertFalse(m.pill.isHidden, "the settle")
        m.copyCommand()
        XCTAssertEqual(pb.string(forType: .string), "gcloud sql backups create --instance=canary --project=example --description=probe")
    }

    /// #2040: red if output that pushes the block up a row (the same text) or rewrites it keeps the pill on the old row.
    func testOutputThatMovesTheBlockHidesIt() throws {
        let r = try rig(), m = r.marks, s = screen(r)
        m.commandHover(Self.at(row: 3))
        XCTAssertFalse(m.pill.isHidden)
        s.vp = Array(Self.lines.dropFirst()) + ["new output"]
        m.output()
        XCTAssertTrue(m.pill.isHidden, "pushed up one row")
        XCTAssertTrue(m.hoveredCommand == nil)
        m.commandHover(Self.at(row: 5))
        XCTAssertEqual(m.hoveredCommand?.row, 5, "the next move reads again")
        s.vp[5] = "$ ls -l"
        m.output()
        XCTAssertTrue(m.pill.isHidden, "the text changed in place")
    }

    /// #2040: red if a move onto a row with no command (prose, blank, two rows off the corridor) hides the pill or
    /// changes the command it copies.
    func testANonCommandRowKeepsThePill() throws {
        let r = try rig(), m = r.marks
        m.commandHover(Self.at(row: 6))
        for row in [0, 1, 4, 9, 11] {
            m.commandHover(Self.at(row: row))
            XCTAssertFalse(m.pill.isHidden, "row \(row)")
            XCTAssertEqual(m.hoveredCommand?.text, "ls -la", "row \(row)")
        }
    }

    /// #2040: red if hovering another command (during output too) leaves the pill on the first, or Copy takes the old text.
    func testAnotherCommandMovesThePill() throws {
        let r = try rig(), m = r.marks
        let pb = NSPasteboard(name: .init("eu.illegible.prosper.test.2040.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        r.v.pasteboard = { pb }
        m.commandHover(Self.at(row: 2))
        let first = m.pill.frame
        m.output()   // not settled: the next command still shows
        m.commandHover(Self.at(row: 8))
        XCTAssertFalse(m.pill.isHidden)
        XCTAssertEqual(m.hoveredCommand?.row, 8)
        XCTAssertNotEqual(m.pill.frame.minY, first.minY)
        m.copyCommand()
        XCTAssertEqual(pb.string(forType: .string), "echo hi")
    }

    /// #2040: red if Run sends or Copy copies after the text under the shown row changed (between show and click), or
    /// the pill stays up after such a click.
    func testAClickAfterTheTextChangedDoesNothing() throws {
        let r = try rig(), m = r.marks, s = screen(r)
        let pb = NSPasteboard(name: .init("eu.illegible.prosper.test.2040.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        r.v.pasteboard = { pb }
        var sent: [String] = []
        r.t.runOff = { _ in nil }
        r.t.run = { _, text, tell in sent.append(text); tell(AgentWindowText.ran) }
        m.commandHover(Self.at(row: 6))
        s.vp[6] = "$ rm -rf build"
        m.runCommand()
        XCTAssertEqual(sent, [], "Run: never a command not shown")
        XCTAssertTrue(m.pill.isHidden)
        s.vp[6] = "$ ls -la"
        m.commandHover(Self.at(row: 6))
        XCTAssertFalse(m.pill.isHidden)
        s.vp[6] = "$ ls -l"
        m.copyCommand()
        XCTAssertTrue(pb.string(forType: .string) == nil, "Copy: nothing")
        XCTAssertNotEqual(r.t.notice, XrayGridMarksView.copiedText)
        XCTAssertTrue(m.pill.isHidden)
        s.vp[6] = "$ ls -la"
        m.commandHover(Self.at(row: 6))
        m.runCommand()
        XCTAssertEqual(sent, ["ls -la"], "unchanged: it runs")
    }

    /// #2040: red if a drain reads the viewport while no pill is shown (and no marks are drawn), or more than once per
    /// drain while one is.
    func testNoViewportReadPerDrainWithoutAPill() throws {
        let r = try rig(), m = r.marks, s = screen(r)
        for _ in 0..<5 { m.output() }
        XCTAssertEqual(s.reads, 0, "no pill")
        m.commandHover(Self.at(row: 2))
        XCTAssertEqual(s.reads, 1)
        for _ in 0..<3 { m.output() }
        XCTAssertEqual(s.reads, 4, "one per drain while the pill is up")
        m.hideCommand()
        for _ in 0..<3 { m.output() }
        XCTAssertEqual(s.reads, 4, "hidden again: none")
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

    /// #1954: red if a move from the continuation row to the row above the head (on the way to the pill) hides it or
    /// reads the viewport, a move two rows off the block keeps it, or a move left of the block's column keeps it.
    func testTheCorridorKeepsThePillOnTheWayToIt() throws {
        let r = try rig(), m = r.marks
        m.commandHover(Self.at(row: 3))
        XCTAssertFalse(m.pill.isHidden)
        XCTAssertEqual(m.commandReads, 1)
        for p in [Self.at(row: 1), CGPoint(x: m.bounds.width - 60, y: 1 * 17 + 5), Self.at(row: 4),
                  CGPoint(x: m.bounds.width - 1, y: 4 * 17 + 5)] {
            m.commandHover(p)
            XCTAssertFalse(m.pill.isHidden, "\(p)")
            XCTAssertEqual(m.commandReads, 1, "inside the corridor: no viewport read \(p)")
        }
        m.commandHover(Self.at(row: 0))
        XCTAssertFalse(m.pill.isHidden, "#2040: two rows above the head, no command there: kept")
        XCTAssertEqual(m.commandReads, 2, "outside it: one read for the new row")
        m.commandHover(Self.at(row: 3))
        XCTAssertFalse(m.pill.isHidden)
        XCTAssertEqual(m.commandReads, 2, "#2040: the kept pill keeps its corridor, so its own row reads nothing")
        m.commandHover(Self.at(row: 5))
        XCTAssertEqual(m.commandReads, 3, "two rows below the block's last row: read")
        m.commandHover(Self.at(row: 3))
        m.commandHover(CGPoint(x: 10, y: 1 * 17 + 5))
        XCTAssertEqual(m.commandReads, 4, "left of the block's column, outside the corridor: read")
        XCTAssertEqual(m.hoveredCommand?.row, 2, "#2040: no other command there: kept")
    }

    /// QA R1954 f1: red if a corridor slack row that is another command's row keeps the first command (no read), so the
    /// pill and Copy stay on it while the pointer is on the next, in either direction, at column 0 or indented.
    func testAnAdjacentCommandIsNotSlack() throws {
        for (pair, texts) in [(["$ npm install", "$ npm test"], ["npm install", "npm test"]), (["  $ a", "  $ b"], ["a", "b"])] {
            let r = try rig(pair + ["", "prose"]), m = r.marks
            let pb = NSPasteboard(name: .init("eu.illegible.prosper.test.1954.\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            r.v.pasteboard = { pb }
            for (row, i) in [(0, 0), (1, 1), (0, 0)] {
                m.commandHover(Self.at(row: row))
                XCTAssertFalse(m.pill.isHidden, "\(pair) row \(row)")
                XCTAssertEqual(m.hoveredCommand?.row, row, "\(pair)")
                m.copyCommand()
                XCTAssertEqual(pb.string(forType: .string), texts[i], "\(pair) row \(row)")
            }
            XCTAssertEqual(m.commandReads, 3, "each new command row reads once")
        }
    }

    /// #1954: red if the pill is one cell high, leaves the overlay's bounds, or its width does not scale with its height.
    func testThePillIsTallerThanACellAndInsideBounds() throws {
        // row 23's padded pill would end at 2 + 23 * 17 + 19 = 412, past the 410 pt overlay: it is moved up
        let r = try rig(["  ! top"] + Array(repeating: "", count: 22) + ["  $ ls"]), m = r.marks
        XCTAssertEqual(m.bounds.height, 410)
        for row in [0, 23] {
            m.commandHover(Self.at(row: row))
            XCTAssertFalse(m.pill.isHidden)
            XCTAssertEqual(m.pill.frame.height, 17 + 4, accuracy: 0.01)
            XCTAssertEqual(m.pill.frame.width, 3 * (17 + 4), accuracy: 0.01, "#1953: two buttons, each 1.5 x its height")
            XCTAssertTrue(m.bounds.contains(m.pill.frame), "\(m.pill.frame) in \(m.bounds)")
        }
    }

    /// #1954: the scroll hide (AgentTerminalHostView.scrollWheel) needs an NSEvent, so this drives the hideCommand it calls:
    /// red if the corridor outlives a hide (a move in it would then keep a hidden pill's block without a read).
    func testAHideDropsTheCorridor() throws {
        let r = try rig(), m = r.marks
        m.commandHover(Self.at(row: 3))
        m.hideCommand()
        XCTAssertTrue(m.commandCorridor.isNull)
        m.commandHover(Self.at(row: 1))
        XCTAssertTrue(m.pill.isHidden)
        XCTAssertEqual(m.commandReads, 2)
    }

    // MARK: #1953: Run

    /// Red if Run is not wired, sends anything but the hovered command (prefix stripped) to the pane's own session, or its
    /// outcome does not show in the pane; or a click with no block sends.
    func testRunSendsTheHoveredCommandToThePanesSession() throws {
        let r = try rig(), m = r.marks
        var sent: [(AgentSessionKey?, String)] = []
        r.t.runOff = { _ in nil }
        r.t.run = { key, text, tell in sent.append((key, text)); tell(AgentWindowText.ran) }
        XCTAssertTrue(m.pill.run.target === m)
        XCTAssertEqual(m.pill.run.action, #selector(XrayGridMarksView.runCommand))
        m.commandHover(Self.at(row: 3))
        m.runCommand()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.last?.0, AgentSessionKey(dir: "/Users/example/dch", name: "api"))
        XCTAssertEqual(sent.last?.1, "gcloud sql backups create --instance=canary --project=example --description=probe")
        XCTAssertEqual(r.t.notice, AgentWindowText.ran)
        m.hideCommand()
        m.commandHover(Self.at(row: 5))
        m.runCommand()
        XCTAssertEqual(sent.count, 1, "no block: nothing sent")
    }

    /// Red if Run stays on while the session cannot take it (working, blocked, unknown), its tooltip does not say why, it
    /// stays off once the session is idle again, or either button lacks its label.
    func testRunIsOffWithItsReasonUnlessIdleOrDone() throws {
        let r = try rig(), m = r.marks
        var off: String? = AgentWindowText.working
        r.t.runOff = { _ in off }
        m.commandHover(Self.at(row: 6))
        XCTAssertFalse(m.pill.run.isEnabled)
        XCTAssertEqual(m.pill.run.toolTip, "Run command: " + AgentWindowText.working)
        XCTAssertTrue(m.pill.copy.isEnabled, "Copy is never off")
        m.hideCommand()
        off = AgentWindowText.blocked
        m.commandHover(Self.at(row: 6))
        XCTAssertFalse(m.pill.run.isEnabled)
        XCTAssertEqual(m.pill.run.toolTip, "Run command: " + AgentWindowText.blocked)
        m.hideCommand()
        off = nil
        m.commandHover(Self.at(row: 6))
        XCTAssertTrue(m.pill.run.isEnabled)
        XCTAssertEqual(m.pill.run.toolTip, "Run command")
        XCTAssertEqual(m.pill.run.accessibilityLabel(), "Run command")
        XCTAssertEqual(m.pill.copy.accessibilityLabel(), "Copy command")
        XCTAssertEqual(AgentTerminalController().runOff(nil), AgentWindowText.notRunning, "unwired: off")
    }

    /// Red if a move onto the wider pill's Run half hides it or reads the viewport.
    func testTheWiderPillKeepsItselfUnderThePointer() throws {
        let r = try rig(), m = r.marks
        m.commandHover(Self.at(row: 3))
        let onRun = CGPoint(x: m.pill.frame.maxX - 5, y: m.pill.frame.midY)
        let onCopy = CGPoint(x: m.pill.frame.minX + 5, y: m.pill.frame.midY)
        for p in [onCopy, onRun] {
            m.commandHover(p)
            XCTAssertFalse(m.pill.isHidden, "\(p)")
            XCTAssertEqual(m.commandReads, 1, "\(p)")
        }
    }

    // Through the window's interaction: the composer's path, a fake dch IO (never a real dch).

    static let key = AgentWindowInteractionTests.key
    typealias Fake = AgentWindowInteractionTests.MessageFake

    func interaction(_ f: Fake) -> AgentWindowInteraction {
        let c = AgentIslandController()
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        c.autoAllowOn = { false }
        c.after = { _, _ in }
        c.onSessions = { _ in }
        let i = AgentWindowInteraction()
        i.controller = c
        i.pause = { _ in }
        i.readQueue = { $0() }
        return i
    }

    func session(_ state: AgentState) -> AgentSession { AgentSession(key: Self.key, alias: "", activity: 1, state: state, agents: 0) }

    func until(_ what: String, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !cond(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(cond(), what)
    }

    /// Red if Run sends without the "! " prefix, through anything but one --say, while working or blocked, with no live
    /// row, only for the followed session (R1: a side-by-side pane's own idle session runs too), or says nothing on success.
    func testRunSendsBangCommandOnlyWhileIdleOrDone() {
        let f = Fake(statuses: ["idle", "working"])
        let i = interaction(f)
        var told: [String] = []
        for (state, why) in [(AgentState.working, AgentWindowText.working), (.blocked, AgentWindowText.blocked)] {
            XCTAssertEqual(i.runOff(session(state)), why)
            i.run("ls -la", session: session(state)) { told.append($0) }
            XCTAssertFalse(i.busy)
            XCTAssertEqual(told.last, why)
        }
        XCTAssertEqual(i.runOff(nil), AgentWindowText.notRunning, "no live row: off")
        i.run("ls -la", session: nil) { told.append($0) }
        XCTAssertEqual(told.last, AgentWindowText.notRunning)
        XCTAssertEqual(f.lock.withLock { f.says }, [], "nothing typed while working, blocked or with no live row")
        // the followed (focused) session is another one: the pane's own idle session still runs
        i.follow(AgentSession(key: AgentSessionKey(dir: Self.key.dir, name: "focused"), alias: "", activity: 1, state: .idle, agents: 0))
        XCTAssertTrue(i.runOff(session(.idle)) == nil)
        i.run("ls -la", session: session(.idle)) { told.append($0) }
        until("ran") { !i.busy }
        XCTAssertEqual(f.lock.withLock { f.says }, ["! ls -la"])
        XCTAssertEqual(told.last, AgentWindowText.ran)
        XCTAssertTrue(i.runOff(session(.done)) == nil, "done too")
    }

    /// Red if a command over two lines, or with a tab or a hidden character, is cleaned and sent instead of refused whole.
    func testRunRefusesAMultiLineOrHiddenCharacterCommand() {
        let f = Fake(statuses: ["idle", "working"])
        let i = interaction(f)
        var told: [String] = []
        for cmd in ["ls\nrm -rf x", "ls\r", "ls\tx", "ls\u{200B}x", "ls\u{1B}[201~", "ls\u{2028}x", "  "] {
            i.run(cmd, session: session(.idle)) { told.append($0) }
            XCTAssertEqual(told.last, AgentWindowText.runOneLine, cmd.debugDescription)
            XCTAssertFalse(i.busy)
        }
        XCTAssertEqual(f.lock.withLock { f.says }, [])
        XCTAssertEqual(AgentWindowInteraction.runText(" make all "), "! make all")
    }

    /// Red if dch's "draft" skip of a "!" text reads as a draft in the composer instead of Claude's shell mode, or a plain
    /// message's draft notice changed.
    func testADraftSkipOfARunIsShellMode() {
        let draft = #"{"name":"s","result":"skipped","reason":"draft","detail":""}"#
        let f = Fake(statuses: ["idle"], reply: draft)
        let d = AgentWindowDriver(key: Self.key, io: f.io, pause: { _ in })
        XCTAssertEqual(d.send("! ls"), .failed(AgentWindowText.shellMode))
        XCTAssertEqual(d.send("hi"), .failed(AgentWindowText.draft), "a plain message keeps its draft notice")
        XCTAssertEqual(AgentWindowDriver.sayFailure(("skipped", "draft")), AgentWindowText.draft, "the card reply's mapping is unchanged")
        let g = Fake(statuses: ["idle"], reply: draft)
        let i = interaction(g)
        var told: [String] = []
        i.run("ls", session: session(.idle)) { told.append($0) }
        until("refused") { !i.busy }
        XCTAssertEqual(told, [AgentWindowText.shellMode])
    }

    /// #1962/#1966: red if a "!" text dch took back out (detail "taken back out") says anything but shellNotRun, a "!" text it could not
    /// take back (empty detail, or "may be left there in bash mode") says anything but shellLeft, or a plain message's texts changed.
    func testAFailedRunSaysWhetherTheCommandWasLeftInClaudesInput() {
        let back = "s: the message stayed in the composer through every Enter: taken back out, bash mode left, nothing run"
        let kept = "s: the message stayed in the composer through every Enter: it may be left there in bash mode, so clear it before pressing Enter"
        let plain = ["not_submitted": AgentWindowText.notSubmitted, "not_typed": "dch didn't send it (not_typed). Open in terminal"]
        for reason in ["not_submitted", "not_typed"] {
            for (detail, want) in [(back, AgentWindowText.shellNotRun), ("", AgentWindowText.shellLeft), (kept, AgentWindowText.shellLeft)] {
                let f = Fake(statuses: ["idle"], reply: #"{"name":"s","result":"failed","reason":"\#(reason)","detail":"\#(detail)"}"#)
                let d = AgentWindowDriver(key: Self.key, io: f.io, pause: { _ in })
                XCTAssertEqual(d.send("! ls"), .failed(want), "\(reason): \(detail)")
                XCTAssertEqual(d.send("hi"), .failed(detail == back ? AgentWindowText.shellNotRun : plain[reason]!), "plain \(reason): \(detail)")
            }
            XCTAssertEqual(AgentWindowDriver.sayFailure(("failed", reason + "_back"), shell: true), AgentWindowText.shellNotRun, reason)
            XCTAssertEqual(AgentWindowDriver.sayFailure(("failed", reason + "_back"), shell: false), AgentWindowText.shellNotRun, reason)
            XCTAssertEqual(AgentWindowDriver.sayFailure(("failed", reason), shell: true), AgentWindowText.shellLeft, reason)
            XCTAssertEqual(AgentWindowDriver.sayFailure(("failed", reason), shell: false), plain[reason], reason)
        }
        let g = Fake(statuses: ["idle"], reply: #"{"name":"s","result":"failed","reason":"not_submitted","detail":""}"#)
        let i = interaction(g)
        var told: [String] = []
        i.run("ls", session: session(.idle)) { told.append($0) }
        until("refused") { !i.busy }
        XCTAssertEqual(told, [AgentWindowText.shellLeft])
    }

    /// #1966: sayReply turns the reason into *_back only for failed + not_submitted/not_typed + a detail with "taken back out".
    func testSayReplyMarksATakenBackTextOnlyFromTheDetail() {
        func reply(_ result: String, _ reason: String, _ detail: String) -> String {
            AgentWindowDriver.sayReply(#"{"name":"s","result":"\#(result)","reason":"\#(reason)","detail":"\#(detail)"}"#)?.reason ?? "nil"
        }
        let back = "taken back out, bash mode left, nothing run"
        XCTAssertEqual(reply("failed", "not_submitted", back), "not_submitted_back")
        XCTAssertEqual(reply("failed", "not_typed", back), "not_typed_back")
        XCTAssertEqual(reply("failed", "not_submitted", ""), "not_submitted")
        XCTAssertEqual(reply("failed", "not_typed", "it may be left there in bash mode, so clear it before pressing Enter"), "not_typed")
        XCTAssertEqual(reply("failed", "draft_left", back), "draft_left")
        XCTAssertEqual(reply("skipped", "not_submitted", back), "not_submitted")
        XCTAssertEqual(AgentWindowDriver.sayReply(#"{"name":"s","result":"failed","reason":"not_typed"}"#)?.reason, "not_typed", "no detail key")
    }
}
