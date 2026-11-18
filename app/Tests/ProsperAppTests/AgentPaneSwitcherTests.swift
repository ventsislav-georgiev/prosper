import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1491: a pane's title is a menu button: a popover list of the sidebar's live rows (History left out) with a search
/// field; the pick goes into THAT pane (focused or not); a session another pane shows swaps with it; the pane's own
/// session changes nothing. Fakes only: never-shown windows, no popover opened, the list's own command() driven with the selectors
/// the search field sends (no event built or posted), a fake terminal spawn (no dch runs).
extension AgentWindowD1Tests {
    /// A window model on `sessions` (and History `records`) under the split gate, its panes `targets` (the first focused).
    @MainActor
    func paneSwitcherModel(_ sessions: [String], records: [String] = [], targets: [String?],
                           _ body: (AgentWindowModel, [UUID]) throws -> Void) throws {
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let m = windowModel(store(sessions.map { session($0, .idle) }, history: records.map { record($0) }))
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.setVisible(true)
        defer { m.close() }
        m.adopt(paneLayout(targets.map { $0.map(paneTarget) }))
        XCTAssertEqual(m.layout.order.count, targets.count, "control: the fixture's panes")
        try body(m, m.layout.order)
    }

    /// Pane `id`'s target's name ("" for an empty pane, nil for no such pane).
    @MainActor
    func paneSwitcherName(_ m: AgentWindowModel, _ id: UUID?) -> String? {
        guard let p = m.layout.panes.first(where: { $0.id == id }) else { return nil }
        guard case let .session(_, n)? = p.target else { return "" }
        return n
    }

    /// Red at base: AgentWindowModel.switcherRows does not exist. The list is the sidebar's rows in its order without
    /// History ("old" is a sidebar row, never a switcher row); a row shown in ANOTHER pane carries that pane's number.
    @MainActor
    func testPaneSwitcherListsTheLiveRowsInSidebarOrderAndMarksOtherPanes() throws {
        try paneSwitcherModel(["api", "web", "db"], records: ["old"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            XCTAssertTrue(m.rows.contains { $0.title == "old" }, "control: the History row is in the sidebar")
            let rows = m.switcherRows(for: b)
            XCTAssertEqual(Set(rows.map(\.row.title)), ["api", "web", "db"], "the live rows, no History")
            XCTAssertEqual(rows.map(\.row.title), m.rows.filter { $0.record == nil }.map(\.title), "the sidebar's order")
            let mark = Dictionary(rows.map { ($0.row.title, $0.inPane) }, uniquingKeysWith: { x, _ in x })
            XCTAssertEqual(mark["api"], .some(1), "api is in pane 1 (seen from pane 2)")
            XCTAssertEqual(mark["web"], .some(nil), "pane 2's own session is not marked")
            XCTAssertEqual(mark["db"], .some(nil), "db is in no pane")
            let fromA = Dictionary(m.switcherRows(for: a).map { ($0.row.title, $0.inPane) }, uniquingKeysWith: { x, _ in x })
            XCTAssertEqual(fromA["web"], .some(2), "web is in pane 2 (seen from pane 1)")
            XCTAssertEqual(fromA["api"], .some(nil), "pane 1's own session is not marked")
            XCTAssertEqual(AgentPaneSwitcherView.mark(2), "in pane 2")
        }
    }

    /// Red at base: no AgentPaneSwitcherList. Mutant switcher-filter-case (a plain `contains`) fails the "API" line.
    @MainActor
    func testPaneSwitcherFilterNarrowsByNameCaseInsensitively() throws {
        var closed = 0
        let items = ["api", "api-qa", "web"].map { AgentPaneSwitcherList.Item(id: .live(AgentSessionKey(dir: "/tmp/dch-test", name: $0)), title: $0, inPane: nil) }
        let list = AgentPaneSwitcherList(items, pick: { _ in }, close: { closed += 1 })
        XCTAssertEqual(list.shown.map(\.title), ["api", "api-qa", "web"], "no filter: every row")
        list.index = 1
        list.query = "API"
        XCTAssertEqual(list.shown.map(\.title), ["api", "api-qa"], "case-insensitive")
        XCTAssertEqual(list.index, 0, "a new filter starts at its first row")
        list.query = "qa"
        XCTAssertEqual(list.shown.map(\.title), ["api-qa"])
        list.query = "zzz"
        XCTAssertTrue(list.shown.isEmpty, "nothing matches")
        XCTAssertTrue(list.command(#selector(NSResponder.insertNewline(_:))), "Return is the list's")
        XCTAssertEqual(closed, 1, "Return on an empty result only closes")
    }

    /// Red at base: no AgentPaneSwitcherList. Down and Up move (clamped, no wrap), Return picks the highlighted row,
    /// Escape closes; another selector is not the list's; the field's doCommandBy reaches the same command().
    @MainActor
    func testPaneSwitcherKeysMoveReturnPicksEscapeCloses() throws {
        var picked: [AgentSidebar.RowID] = [], closed = 0
        let ids = ["api", "web", "db"].map { AgentSidebar.RowID.live(AgentSessionKey(dir: "/tmp/dch-test", name: $0)) }
        let items = zip(ids, ["api", "web", "db"]).map { AgentPaneSwitcherList.Item(id: $0, title: $1, inPane: nil) }
        let list = AgentPaneSwitcherList(items, pick: { picked.append($0) }, close: { closed += 1 })
        XCTAssertTrue(list.command(#selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(list.index, 0, "Up at the top stays")
        for _ in 0..<3 { XCTAssertTrue(list.command(#selector(NSResponder.moveDown(_:)))) }
        XCTAssertEqual(list.index, 2, "Down stops at the last row")
        XCTAssertTrue(list.command(#selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(list.index, 1)
        XCTAssertFalse(list.command(#selector(NSResponder.moveLeft(_:))), "the caret's keys are the field's")
        XCTAssertTrue(list.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(picked, [ids[1]], "Return picks the highlighted row")
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(list.command(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(closed, 1, "Escape closes")
        XCTAssertEqual(picked.count, 1, "Escape picks nothing")
        let c = AgentPaneSwitcherField.Coordinator(list)
        XCTAssertTrue(c.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(list.index, 0, "the field's Up moves the list")
        XCTAssertFalse(c.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))),
                       "the caret's keys stay the field's")
    }

    /// Red at base: no AgentWindowModel.choose. Mutant switcher-focused-pane (the pick goes into the focused pane) fails
    /// the "into pane 2" lines: pane 1 is focused when pane 2's title picks.
    @MainActor
    func testPaneSwitcherPickGoesIntoTheClickedPaneFocusedOrNot() throws {
        try paneSwitcherModel(["api", "web", "db", "ops"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            XCTAssertEqual(m.layout.focused, a, "control: pane 1 focused")
            m.choose(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "db")), into: b)
            XCTAssertEqual(paneSwitcherName(m, b), "db", "into pane 2, the unfocused one")
            XCTAssertEqual(paneSwitcherName(m, a), "api", "pane 1 keeps its session")
            XCTAssertEqual(m.layout.focused, b, "the picked pane takes the focus, as a sidebar click")
            // Through the list's own Return, on pane 1's title (now unfocused).
            var dismissed = 0
            let list = AgentPaneSwitcherList.of(AgentPaneSwitch(model: m, pane: a), dismiss: { dismissed += 1 })
            list.query = "OPS"
            XCTAssertTrue(list.command(#selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(dismissed, 1, "the pick closes the list")
            XCTAssertEqual(paneSwitcherName(m, a), "ops", "into pane 1")
            XCTAssertEqual(paneSwitcherName(m, b), "db", "pane 2 keeps its session")
            XCTAssertEqual(m.layout.focused, a)
        }
        // Unsplit: the one pane's session is replaced, as a sidebar click does.
        try paneSwitcherModel(["api", "web"], targets: ["api"]) { m, panes in
            let only = try XCTUnwrap(panes.first)
            m.choose(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "web")), into: only)
            XCTAssertEqual(paneSwitcherName(m, only), "web")
            XCTAssertEqual(m.selectedRow?.title, "web", "the selection follows, as a sidebar click")
        }
    }

    /// Red at base: no AgentWindowModel.choose. Mutant switcher-no-swap (pane 1 keeps "api") fails the swap lines and
    /// the never-twice line.
    @MainActor
    func testPaneSwitcherPickOfAnotherPanesSessionSwaps() throws {
        try paneSwitcherModel(["api", "web"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            m.choose(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "api")), into: b)
            XCTAssertEqual(paneSwitcherName(m, b), "api", "pane 2 shows the pick")
            XCTAssertEqual(paneSwitcherName(m, a), "web", "pane 1 takes pane 2's session (a swap)")
            let shown = m.layout.panes.compactMap { $0.target?.identity }
            XCTAssertEqual(Set(shown).count, shown.count, "a session is never shown twice")
            XCTAssertEqual(m.layout.focused, b)
        }
        // A swap with an empty pane: the other pane is left empty.
        let l = paneLayout([paneTarget("api"), nil])
        let empty = try XCTUnwrap(l.order.last), first = try XCTUnwrap(l.order.first)
        let out = try l.put(paneTarget("api"), in: empty).get()
        XCTAssertEqual(out.panes.first { $0.id == empty }?.target, paneTarget("api"))
        XCTAssertTrue(out.panes.first { $0.id == first }?.target == nil, "pane 1 gets pane 2's nothing")
        XCTAssertEqual(out.focused, l.focused, "put never moves the focus")
    }

    /// Red at base: no AgentWindowModel.choose. Picking the pane's own session changes nothing (layout, focus).
    @MainActor
    func testPaneSwitcherPickOfThePanesOwnSessionChangesNothing() throws {
        try paneSwitcherModel(["api", "web"], targets: ["api", "web"]) { m, panes in
            let b = try XCTUnwrap(panes.last)
            let before = m.layout
            m.choose(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "web")), into: b)
            XCTAssertEqual(m.layout, before, "nothing changes")
            XCTAssertEqual(m.layout.focused, before.focused, "the focus stays")
            var dismissed = 0
            let list = AgentPaneSwitcherList.of(AgentPaneSwitch(model: m, pane: b), dismiss: { dismissed += 1 })
            list.query = "web"
            XCTAssertTrue(list.command(#selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(dismissed, 1, "the list closes")
            XCTAssertEqual(m.layout, before, "still nothing changes")
        }
    }

    /// The view `v`'s accessibility tree in a never-shown window once a node satisfies `done`.
    @MainActor
    func paneSwitcherTree<V: View>(_ v: V, _ size: CGSize, until done: @escaping ([AXTreeNode]) -> Bool) -> [AXTreeNode] {
        let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height, alignment: .top))
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        let tree = AXTreeSupport.poll(host, until: done)
        XCTAssertFalse(win.isVisible, "never on screen")
        return tree
    }

    /// Red at base: no AgentPaneSwitch (the title is a plain text). In all three headers the title is a button that reads the
    /// session's name and the hint "Choose a session for this pane" (the local ones: the folder as value; the remote one:
    /// no folder). Remote twin: mutant remote-title-plain (a plain title) fails the "one button (remote)" line.
    @MainActor
    func testPaneSwitcherTitleIsAMenuButtonInAllThreeHeaders() throws {
        _ = ThemeStore.shared   // #1510: warm before the scale is pinned
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        try paneSwitcherModel(["api"], targets: ["api"]) { m, panes in
            let pane = try XCTUnwrap(panes.first)
            let row = try XCTUnwrap(m.selectedRow)
            let s = try XCTUnwrap(row.session)
            let project = try XCTUnwrap(AgentSessionHeader.project(cwd: nil, session: s))
            let sw = AgentPaneSwitch(model: m, pane: pane)
            let remote = XrayRemoteTabsTests.remoteRow
            let r = try XCTUnwrap(remote.remote)
            let headers: [(String, AnyView)] = [
                ("session", AnyView(AgentSessionHeader(row: row, session: s, cwd: nil, open: {}, xrayPane: pane, switcher: sw))),
                ("compact", AnyView(AgentCompactHeader.of(row, s, cwd: nil, ended: false, store: nil, ask: { _ in }, open: {},
                                                          xrayPane: pane, switcher: sw))),
                ("remote", AnyView(AgentRemoteHeader(row: remote, remote: r, pane: pane, switcher: sw))),
            ]
            for (name, view) in headers {
                let title = name == "remote" ? remote.title : row.title
                let folder: String? = name == "remote" ? nil : project
                let isButton = { (n: AXTreeNode) in n.role == "AXButton" && n.named(title) && !n.ignored }
                let tree = paneSwitcherTree(view, CGSize(width: 700, height: 60)) { $0.contains(where: isButton) }
                let b = tree.filter(isButton)
                XCTAssertEqual(b.count, 1, "the title is one button (\(name)): \(tree.map { "\($0.role)|\($0.name)" })")
                XCTAssertTrue(b.first?.help.hasSuffix("\n" + AgentPaneSwitch.hint) == true, "the hint (\(name)): \(b.first?.help ?? "")")
                if name == "remote" { XCTAssertEqual(b.first?.help, title + "\n" + AgentPaneSwitch.hint, "the title, then the hint") }
                if let folder {
                    XCTAssertTrue(b.first?.help.contains(folder) == true, "the folder stays in the tooltip (\(name))")
                    XCTAssertTrue(b.first?.value == folder, "the folder is its value (\(name))")
                }
            }
        }
    }

    /// Red at base: no switcher argument. The compact header's title (now the switcher, its chevron inside the slot) is
    /// at least as wide as the plain title of #1476 and the "..." does not move, at 0.7, 0.85 and 1.0.
    @MainActor
    func testPaneSwitcherKeepsTheCompactTitleWidthAtEveryScale() throws {
        _ = ThemeStore.shared   // #1510: a cold init resets the scale mid-loop
        let pixel = AXTreeSupport.devicePixel
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            XCTAssertEqual(ThemeRuntime.scale, scale, "the scale holds")
            let s = session("api", .idle, alias: Self.headerTitle)
            let m = windowModel(store([s]))
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(s.key))
            let row = try XCTUnwrap(m.selectedRow)
            let pane = m.layout.focused
            let size = CGSize(width: sz(300), height: AgentCompactHeader.height)
            func frames(_ on: Bool) -> (title: CGRect?, dots: CGRect?) {
                let h = AgentCompactHeader.of(row, s, cwd: nil, ended: false, store: nil, ask: { _ in }, open: {}, xrayPane: pane,
                                              switcher: on ? AgentPaneSwitch(model: m, pane: pane) : nil)
                let tree = paneSwitcherTree(h, size) { $0.contains { $0.named("Session actions") } }
                return (tree.first { $0.named(row.title) && !$0.ignored }?.frame, tree.first { $0.named("Session actions") }?.frame)
            }
            let plain = frames(false), on = frames(true)
            let tag = "\(scale)"
            let was = try XCTUnwrap(plain.title, "the plain title (\(tag))"), now = try XCTUnwrap(on.title, "the switcher (\(tag))")
            XCTAssertGreaterThanOrEqual(now.width, was.width - pixel, "the title keeps its #1476 width (\(tag))")
            XCTAssertLessThanOrEqual(now.maxX, try XCTUnwrap(on.dots).minX + pixel, "before the \"...\" (\(tag))")
            assertSame(on.dots, plain.dots, "the \"...\" does not move (\(tag))")
        }
    }

    /// Red at base: no switcher argument on AgentRemoteHeader. The remote header's title (now the switcher, its chevron
    /// inside the slot) is at least as wide as the plain title, and the checklist chip and the X-ray button (right-aligned)
    /// do not move, at 0.7, 0.85 and 1.0; the host text stays after the title.
    @MainActor
    func testPaneSwitcherKeepsTheRemoteTitleWidthAtEveryScale() throws {
        _ = ThemeStore.shared   // #1510: a cold init resets the scale mid-loop
        let pixel = AXTreeSupport.devicePixel
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            XCTAssertEqual(ThemeRuntime.scale, scale, "the scale holds")
            let m = windowModel(store([session("api", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            let pane = m.layout.focused
            let remote = XrayRemoteTabsTests.remoteRow
            let r = try XCTUnwrap(remote.remote)
            let size = CGSize(width: sz(500), height: 60)
            let chip = AgentRemoteHeader.todosOpens
            func frames(_ on: Bool) -> (title: CGRect?, chip: CGRect?, xray: CGRect?) {
                let h = AgentRemoteHeader(row: remote, remote: r, pane: pane, switcher: on ? AgentPaneSwitch(model: m, pane: pane) : nil)
                let tree = paneSwitcherTree(h, size) { $0.contains { $0.named(chip) } && $0.contains { $0.named(AgentXrayButton.label) } }
                return (tree.first { $0.named(remote.title) && !$0.ignored }?.frame, tree.first { $0.named(chip) }?.frame,
                        tree.first { $0.named(AgentXrayButton.label) && !$0.ignored }?.frame)
            }
            let plain = frames(false), on = frames(true)
            let tag = "\(scale)"
            let was = try XCTUnwrap(plain.title, "the plain title (\(tag))"), now = try XCTUnwrap(on.title, "the switcher (\(tag))")
            XCTAssertGreaterThanOrEqual(now.width, was.width - pixel, "the title keeps its width (\(tag))")
            XCTAssertLessThanOrEqual(now.maxX, try XCTUnwrap(on.chip).minX + pixel, "before the checklist chip (\(tag))")
            assertSame(on.chip, plain.chip, "the checklist chip does not move (\(tag))")
            assertSame(on.xray, plain.xray, "the X-ray button does not move (\(tag))")
        }
    }

    /// Red at base: nothing pins the remote arm for a switcher pick. A pick of a remote row from a pane's switcher (the
    /// list's own Return) goes into that pane and ARMS the attach: the fake terminal spawns the --host attach. Mutant
    /// remote-pick-no-attach (the arm dropped in choose) leaves the card with Attach and no spawn.
    @MainActor
    func testPaneSwitcherPickOfARemoteRowArmsTheAttach() throws {
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let m = windowModel(store([session("api", .idle), session("web", .idle)]))
        final class Spawns { var all: [AgentTerminalSpawn] = [] }
        let spawns = Spawns()
        m.remoteOffMain = false
        m.remoteRun = { _, _ in
            Data(#"[{"name":"build","alias":"","host":"example-host","state":"idle","stale":false,"cwd":null}]"#.utf8)
        }
        m.terminal.request = { AgentTerminalSpawn.attach($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { req, _ in spawns.all.append(req); return AgentTerminalTests.FakeChild() }
        m.terminal.makeScreen = { [weak t = m.terminal] events in
            if let t, let g = t.grid { t.gridChanged(cols: g.cols, rows: g.rows, generation: t.generation) }
            return AgentTerminalTests.FakeScreen(events)
        }
        m.terminal.after = { _, _ in }
        m.terminal.clientVersion = { _ in [1, 74, 0] }
        m.terminal.gridChanged(cols: 80, rows: 24)
        m.setVisible(true)
        defer { m.close() }
        let b = m.layout.focused   // the one pane: its terminal is the seamed one
        let id = AgentSidebar.RowID.remote(host: "example-host", name: "build")
        XCTAssertTrue(m.rows.contains { $0.id == id }, "control: the remote row is in the sidebar")
        let list = AgentPaneSwitcherList.of(AgentPaneSwitch(model: m, pane: b), dismiss: {})
        XCTAssertTrue(list.items.contains { $0.id == id }, "control: the switcher lists it")
        list.query = "build"
        XCTAssertTrue(list.command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(m.layout.focused, b, "the pane has the focus")
        XCTAssertEqual(m.layout.panes.first { $0.id == b }?.target, .remote(host: "example-host", name: "build"), "into the pane")
        XCTAssertEqual(spawns.all.last?.args, ["-E", "--host", "example-host", "-a", "build", "--scrollback", "2000"],
                       "armed: the remote attach starts, not the card with Attach")
        XCTAssertTrue(m.terminal.held == nil, "nothing is held back")
    }
}
