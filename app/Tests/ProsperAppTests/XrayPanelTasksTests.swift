import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1351 (#1346 P3a): the X-ray panel's Tasks tab. Offscreen only: no window is shown, ordered front or made key; key
/// events are built and handed to the pure route or the window's own perform, never posted; the dch reads go through a
/// fake runner (literal NDJSON), the gate through a fake binary, the card through FakeCardPresenter, Open through a
/// recorder, Copy through Pasteboard.swift (the private XCTest pasteboard). No real dch runs.
@MainActor
final class XrayPanelTasksTests: XCTestCase {

    nonisolated static let header = #"{"schema":1,"session":"api","session_id":"s-1","source":"claude","title":"Example Org api","partial":false}"#
    nonisolated static let rows = [
        #"{"task":{"id":"1","title":"Write the parser","status":"active","label":"in_progress","active":"Writing the parser","note":null,"created":"2026-11-16T09:00:00Z","updated":"2026-11-16T11:00:00Z","blocked_by":[]}}"#,
        #"{"task":{"id":"12","title":"Fix the login test","status":"pending","label":"pending","note":"flaky on CI","created":"2026-11-16T09:00:00Z","updated":null,"blocked_by":["9","10"]}}"#,
        #"{"task":{"id":"13","title":"Ship it","status":"pending","label":"PARKED","created":null,"updated":null,"blocked_by":[]}}"#,
        #"{"task":{"id":"9","title":"Old work","status":"done","label":"completed","updated":"2026-11-14T12:00:00Z","url":"https://example.org/acme/api/issues/9","group":"Backend"}}"#,
    ]
    nonisolated static let done = #"{"done":true,"count":4,"dropped":2,"warn":"tasks_command was slow"}"#
    nonisolated static let memory = [#"{"schema":1,"source":"claude","title":null,"partial":false}"#,
                         #"{"memory":{"id":"m1","title":"Prefers short replies","kind":"feedback","scope":"user","path":"/Users/example/m1.md","session":null}}"#,
                         #"{"done":true,"count":1,"dropped":0}"#]
    /// 2026-11-16T12:00:00Z.
    nonisolated static let now = Date(timeIntervalSince1970: 1_794_830_400)

    nonisolated static func ndjson(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }
    nonisolated static var tasksOut: Data { ndjson([header] + rows + [done]) }

    /// The fake dch: records each argv, answers by form.
    final class FakeRun: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.withLock { _calls } }
        let tasks: (Int32, Data), memory: (Int32, Data)
        init(tasks: (Int32, Data) = (0, XrayPanelTasksTests.tasksOut),
             memory: (Int32, Data) = (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory))) {
            (self.tasks, self.memory) = (tasks, memory)
        }
        var run: XrayPanels.Run {
            { [self] path, args, _ in
                lock.withLock { _calls.append([path] + args) }
                return args.contains("--tasks") ? tasks : memory
            }
        }
    }

    /// The gate as XrayTabs decides it for a fake binary of `version`.
    static func gate(_ version: [Int]) -> @MainActor () -> String? {
        { if case .ok(let p) = XrayTabs.gate(DchCommand.Binary(path: "/fake/dch", version: version)) { p } else { nil } }
    }

    func withSeams(_ version: [Int], _ fake: FakeRun, _ body: () async throws -> Void) async rethrows {
        let (dch, run) = (XrayPanels.dch, XrayPanels.run)
        defer { (XrayPanels.dch, XrayPanels.run) = (dch, run); XrayPanels.shared.open = [:] }
        XCTAssertTrue(XrayPanels.dch() == nil, "under XCTest the product gate is shut: no row probes a real dch")
        XrayPanels.dch = Self.gate(version)
        XrayPanels.run = fake.run
        try await body()
    }

    func panel(_ tasks: (Int32, Data) = (0, XrayPanelTasksTests.tasksOut),
               memory: (Int32, Data) = (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory))) -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        p.now = { Self.now }
        p.apply(tasks: tasks, memory: memory)
        return p
    }

    static let otherKey = AgentSessionKey(dir: "/tmp/dch-test", name: "api-qa")

    /// A never-shown window on a model with session "api" selected; the terminal on a recorder (nothing spawns).
    func window(_ body: (AgentsNSWindow, AgentWindowModel, FakeCardPresenter) async throws -> Void) async rethrows {
        let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        store.sessions = [AgentSession(key: key, alias: "", activity: AgentWindowD1Tests.now - 60, state: .idle, agents: 0,
                                       version: "1.78.0"),
                          AgentSession(key: Self.otherKey, alias: "", activity: AgentWindowD1Tests.now - 120, state: .idle, agents: 0,
                                       version: "1.78.0")]
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        final class Spawns { var count = 0 }
        let spawns = Spawns()
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in spawns.count += 1; return AgentTerminalTests.FakeChild() }
        m.bind(store)
        m.setVisible(true)   // a hidden model does not refresh its rows (the energy rule)
        m.select(.live(key))
        defer { m.close() }
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        let fake = FakeCardPresenter()
        win.cards = fake
        try await body(win, m, fake)
        XCTAssertEqual(spawns.count, 0, "no terminal spawned")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    // MARK: rows, groups, count, footer

    func testGroupsRowsCountAndFooter() {
        let p = panel()
        XCTAssertEqual(p.tabs, [.tasks, .memory], "dch's order; only the tabs that exist")
        XCTAssertEqual(p.title(.tasks), "Tasks 3", "open = active + pending")
        XCTAssertEqual(p.title(.memory), "Memory 1")
        XCTAssertEqual(p.shownGroups.map(\.title), ["In progress", "Pending", "Done"], "no Dropped group without one")
        XCTAssertEqual(p.shownGroups.map { $0.tasks.map(\.id) }, [["1"], ["12", "13"], ["9"]])
        let rows = p.shownGroups.flatMap(\.tasks).map { XrayTaskRow($0, now: Self.now) }
        XCTAssertEqual(rows.map(\.mark), ["circle.dotted", "circle", "circle", "checkmark.circle"])
        XCTAssertEqual(rows.map(\.title), ["Writing the parser", "Fix the login test", "Ship it", "Old work"], "active shows `active`")
        XCTAssertEqual(rows.map(\.label), [nil, nil, "PARKED", nil], "a label only when it says more than the status")
        XCTAssertEqual(rows.map(\.blocked), [nil, "blocked by 9, 10", nil, nil])
        XCTAssertEqual(rows.map(\.age), ["1h", "3h", nil, "2d"], "updated, else created")
        XCTAssertEqual(p.footer, ["tasks_command was slow", "2 not shown"])
        let cut = panel((0, Self.ndjson([Self.header] + Self.rows)))
        XCTAssertEqual(cut.footer, ["partial"], "no done line: partial")
        XCTAssertTrue(p.listTitle == nil)
        let command = panel((0, Self.ndjson([#"{"schema":1,"source":"command","title":"Example Org ledger","partial":false}"#,
                                             Self.rows[1], Self.done])))
        XCTAssertEqual(command.listTitle, "Tasks \u{00B7} Example Org ledger")
        XCTAssertEqual(XrayTaskRow.age(Self.now.addingTimeInterval(600), now: Self.now)?.short, "1m", "a future date reads as now")
    }

    // MARK: filter

    /// #1381 (design 3.2): with no filter an empty group is not drawn (no "In progress 0"), as on the Memory tab; the
    /// tab count and the spoken headers stay. Red at TIP: shownGroups kept every group when the filter was empty.
    func testNoEmptyGroupIsDrawnWithNoFilter() {
        let p = panel((0, Self.ndjson([Self.header, Self.rows[1], Self.rows[2], Self.rows[3], Self.done])))
        XCTAssertEqual(p.filter, "")
        XCTAssertEqual(p.shownGroups.map { "\($0.title) \($0.tasks.count)" }, ["Pending 2", "Done 1"], "the drawn headers")
        XCTAssertEqual(p.title(.tasks), "Tasks 2")
        XCTAssertEqual(p.spoken(.tasks), "Tasks, 2 open")
        p.filter = "zzz-none"
        XCTAssertEqual(p.shownGroups.count, 0, "a filter that matches nothing: no group")
        p.filter = ""
        XCTAssertEqual(p.shownGroups.map(\.title), ["Pending", "Done"])
    }

    func testFilterIsCaseInsensitiveOverIdTitleNoteAndLabel() {
        let p = panel()
        func ids(_ q: String) -> [String] { p.filter = q; return p.shownGroups.flatMap(\.tasks).map(\.id) }
        XCTAssertEqual(ids("FLAKY"), ["12"], "the note")
        XCTAssertEqual(ids("parked"), ["13"], "the label")
        XCTAssertEqual(ids("login"), ["12"], "the title")
        XCTAssertEqual(ids("13"), ["13"], "the id")
        XCTAssertEqual(ids("Backend"), [], "not the group")
        XCTAssertEqual(ids(""), ["1", "12", "13", "9"])
        p.filter = "flaky"
        XCTAssertEqual(p.shownGroups.map(\.title), ["Pending"], "under a filter an emptied group goes")
    }

    func testEscClearsTheFilterThenCloses() {
        let p = panel()
        var closed = 0
        p.close = { closed += 1 }
        p.filter = "login"
        p.escape()
        XCTAssertEqual(p.filter, "")
        XCTAssertEqual(closed, 0, "the first Esc clears")
        p.escape()
        XCTAssertEqual(closed, 1, "the second closes")
        XCTAssertTrue(p.key("/", command: false), "slash puts the keys in the filter")
        XCTAssertTrue(p.filterFocused)
        XCTAssertFalse(p.key("/", command: false), "in the field a slash types")
        XCTAssertTrue(p.key("f", command: true), "Command-F")
        XCTAssertFalse(p.key("a", command: false))
    }

    // MARK: the card

    func testCardFieldsOpenTheRawURLAndCopy() {
        let p = panel()
        let tasks = p.shownGroups.flatMap(\.tasks)
        let fields = { (id: String) in
            tasks.first { $0.id == id }.map { XrayTaskCard.fields($0, now: Self.now).map { "\($0.label): \($0.value)" } } ?? []
        }
        XCTAssertEqual(fields("12"), ["Title: Fix the login test", "Status: Pending", "Note: flaky on CI", "Created: 3 hours ago",
                                      "Blocked by: 9, 10"])
        XCTAssertEqual(fields("9"), ["Title: Old work", "Status: Done", "Updated: 2 days ago", "Group: Backend",
                                     "URL: https://example.org/acme/api/issues/9"])
        XCTAssertEqual(fields("1"), ["Title: Write the parser", "Status: In progress", "Doing: Writing the parser",
                                     "Created: 3 hours ago", "Updated: 1 hour ago"])
        XCTAssertEqual(fields("13").dropFirst().first, "Status: Pending (PARKED)")

        // QA R1349-i1: Open gets the raw url, not the capped display form.
        let long = "https://example.org/" + String(repeating: "a", count: 2100)
        let t = XrayTasks.parse(Self.ndjson([Self.header, #"{"task":{"id":"2","title":"t","status":"pending","url":"\#(long)"}}"#,
                                             Self.done])).tasks.first
        var opened: [URL] = []
        let card = t.map { XrayTaskCard(task: $0, now: Self.now, open: { opened.append($0) }) }
        card?.openLink()
        XCTAssertTrue(opened.isEmpty, "R1351-s1: the shown url is the capped one, so no Open (was: the raw url, whole)")
        XCTAssertTrue(t.flatMap { XrayTaskCard.openURL($0) } == nil)
        XCTAssertNotEqual(t?.url, long, "the display form differs (capped)")
        let clean = "https://example.org/" + String(repeating: "a", count: 1900)
        let c = XrayTasks.parse(Self.ndjson([Self.header, #"{"task":{"id":"2","title":"t","status":"pending","url":"\#(clean)"}}"#,
                                             Self.done])).tasks.first
        XCTAssertEqual(c?.url, clean, "a clean url is the same in both forms")
        c.map { XrayTaskCard(task: $0, now: Self.now, open: { opened.append($0) }) }?.openLink()
        XCTAssertEqual(opened.map(\.absoluteString), [clean], "equal forms: Open gets it, whole")
        for bad in ["javascript:void(0)", "file:///etc/hosts", "mailto:someone@example.org", "https://", "not a url"] {
            XCTAssertTrue(XrayTaskCard.openable(bad) == nil, "\(bad) refused")
        }
        XCTAssertEqual(XrayTaskCard.openable("HTTPS://example.org/x")?.absoluteString, "HTTPS://example.org/x")
        let js = XrayTasks.parse(Self.ndjson([Self.header, #"{"task":{"id":"3","title":"t","status":"pending","url":"javascript:void(0)"}}"#,
                                              Self.done])).tasks.first
        js.map { XrayTaskCard(task: $0, now: Self.now, open: { opened.append($0) }) }?.openLink()
        XCTAssertEqual(opened.count, 1, "javascript: opens nothing")
        // R1351-s1: a scalar the display form drops (a zero-width space) makes shown and raw differ: no Open, no open.
        let zw = XrayTasks.parse(Self.ndjson([Self.header,
            #"{"task":{"id":"4","title":"t","status":"pending","url":"https://example.org/a\#u{200B}b"}}"#, Self.done])).tasks.first
        XCTAssertNotEqual(zw?.url, zw?.rawURL, "the unseen scalar is dropped from the shown form")
        XCTAssertTrue(zw.flatMap { XrayTaskCard.openURL($0) } == nil, "no Open control")
        zw.map { XrayTaskCard(task: $0, now: Self.now, open: { opened.append($0) }) }?.openLink()
        XCTAssertEqual(opened.count, 1, "the fake records no open for it")

        let nine = tasks.first { $0.id == "9" }
        nine.map { XrayTaskCard(task: $0, now: Self.now, open: { _ in }) }?.copy()
        XCTAssertEqual(Pasteboard.general.string(forType: .string), nine.map { XrayTaskCard.copyText($0, now: Self.now) })
        XCTAssertTrue(Pasteboard.general.string(forType: .string)?.hasPrefix("Title: Old work\nStatus: Done") == true)
    }

    // MARK: accessibility (design 3.8)

    func testAccessibilityLabels() {
        let p = panel()
        XCTAssertEqual(p.spoken(.tasks), "Tasks, 3 open")
        XCTAssertEqual(p.spoken(.memory), "Memory, 1")
        let spoken = p.shownGroups.flatMap(\.tasks).map { XrayTaskRow($0, now: Self.now).spoken }
        XCTAssertEqual(spoken, [
            "In progress task 1, Writing the parser, 1 hour ago",
            "Pending task 12, Fix the login test, blocked by 9, 10, 3 hours ago",
            "Pending task 13, Ship it, PARKED",
            "Done task 9, Old work, 2 days ago",
        ])
        // Offscreen: the panel draws (a hosting view never put in a shown window).
        let host = NSHostingView(rootView: XrayPanelView(panel: p).frame(width: 340, height: 400))
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    // MARK: no tab (design 3.9, QA R1349-i2)

    func testSchemaOtherThanOneMeansNoTab() {
        let two = Self.ndjson([#"{"schema":2,"session":"api","session_id":"s-1","source":"claude","title":null,"partial":false}"#]
                              + Self.rows + [Self.done])
        XCTAssertTrue(XrayPanelModel.tasksTab((0, two)) == nil, "schema 2: no Tasks tab")
        XCTAssertTrue(XrayPanelModel.tasksTab((0, Self.ndjson(Self.rows + [Self.done]))) == nil, "no header: no tab")
        XCTAssertEqual(XrayPanelModel.tasksTab((0, Self.tasksOut))?.open, 3, "schema 1: the tab")
        XCTAssertEqual(panel((0, two)).tabs, [.memory])
    }

    func testShellEmptyListAndExitTwoMeanNoTab() {
        let shell = Self.ndjson([#"{"schema":1,"session":"sh","session_id":"s-2","source":"none","title":null,"partial":false}"#,
                                 #"{"done":true,"count":0,"dropped":0}"#])
        let empty = Self.ndjson([Self.header, #"{"done":true,"count":0,"dropped":0}"#])
        XCTAssertTrue(XrayPanelModel.tasksTab((0, shell)) == nil, "a shell")
        XCTAssertTrue(XrayPanelModel.tasksTab((0, empty)) == nil, "an empty list")
        XCTAssertTrue(XrayPanelModel.tasksTab((2, Self.tasksOut)) == nil, "exit 2 (an older dch's bad flag)")
        XCTAssertTrue(XrayPanelModel.tasksTab((1, Data("dch: no x-ray corpus\n".utf8))) == nil, "exit 1")
        let none = panel((0, shell), memory: (2, Data()))
        XCTAssertEqual(none.tabs, [], "neither tab")
        XCTAssertTrue(none.loaded)
    }

    // MARK: Shift-Command-X: the route, the gate, the read, the card

    func testShiftCommandXRoutesByKeyCodeFromEveryResponder() throws {
        func route(_ e: NSEvent, _ r: AgentsNSWindow.ResponderKind, terminal: Bool = false, renaming: Bool = false,
                   form: Bool = false) -> AgentsNSWindow.KeyRoute {
            AgentsNSWindow.route(e, responder: r, sidebarFocused: false, terminalMode: terminal, renaming: renaming, form: form)
        }
        let x = try XCTUnwrap(AgentsNSWindow.keyEvent("x", [.command, .shift], 7))
        let cyrillic = try XCTUnwrap(AgentsNSWindow.keyEvent("\u{0447}", [.command, .shift], 7))
        for r in [AgentsNSWindow.ResponderKind.text, .terminal, .other] {
            XCTAssertEqual(route(x, r), .xray, "Transcript, \(r)")
            XCTAssertEqual(route(x, r, terminal: true), .xray, "Terminal, \(r)")
        }
        XCTAssertEqual(route(cyrillic, .text), .xray, "by key code on any layout")
        XCTAssertEqual(route(x, .text, renaming: true), .pass, "the rename field keeps it")
        XCTAssertEqual(route(x, .text, form: true), .swallow, "under the New session form")
        XCTAssertEqual(route(try XCTUnwrap(AgentsNSWindow.keyEvent("x", .command, 7)), .text), .pass, "Command-X stays Cut")
        XCTAssertTrue(AgentsNSWindow.keyTable.contains { $0.keyCode == 7 && $0.mods == [.command, .shift] && $0.route == .xray },
                      "in the Go menu's table")
    }

    func testBelowTheGateNoItemNoRouteNoProcess() async throws {
        let fake = FakeRun()
        try await withSeams([1, 77, 9], fake) {
            try await window { win, m, _ in
                XCTAssertTrue(AgentsNSWindow.xrayItem(m) == nil, "no \"...\" item")
                XCTAssertFalse(win.perform(.xray), "the key passes through")
                let e = try XCTUnwrap(AgentsNSWindow.keyEvent("x", [.command, .shift], 7))
                XCTAssertFalse(win.performKeyEquivalent(with: e), "and on to super, which has nothing for it")
                XCTAssertTrue(XrayPanels.shared.open.isEmpty, "no panel")
                XCTAssertEqual(fake.calls.count, 0, "no process")
            }
        }
    }

    func testAtTheGateTheKeyOpensReadsOnceAndClosesAndARowOpensTheCard() async throws {
        let fake = FakeRun()
        try await withSeams([1, 78, 0], fake) {
            try await window { win, m, cards in
                let pane = m.layout.focused
                XCTAssertEqual(AgentsNSWindow.xrayItem(m), .xray(pane: pane), "the \"...\" item")
                XCTAssertTrue(win.perform(.xray))
                let p = try XCTUnwrap(XrayPanels.shared.open[pane])
                await p.reading?.value
                XCTAssertEqual(Set(fake.calls), [["/fake/dch", "--xray", "api", "--tasks", "--json"],
                                                 ["/fake/dch", "--xray", "api", "--memory", "--json"]])
                XCTAssertEqual(fake.calls.count, 2, "read once, both forms")
                XCTAssertEqual(p.tabs, [.tasks, .memory])
                XCTAssertEqual(p.tab, .tasks)
                let task = try XCTUnwrap(p.shownGroups.first?.tasks.first)
                p.openCard(task)
                XCTAssertEqual(cards.presents, 1, "the card through the presenter seam")
                XCTAssertEqual(cards.size, XrayTaskCard.size)
                XCTAssertEqual(p.card, task)
                XCTAssertTrue(win.perform(.xray), "again: closes")
                XCTAssertTrue(XrayPanels.shared.open[pane] == nil)
                XCTAssertEqual(fake.calls.count, 2, "no read on close")
            }
        }
    }

    // MARK: Q3: the Todos chip

    /// R1 review: Terminal mode, the floating list open; the chip's tap (its binding toggled, as AgentTodosChip does)
    /// closes the list and never opens the panel or runs dch.
    func testTerminalChipWithTheFloatingListOpenClosesItWithoutXray() async throws {
        let fake = FakeRun()
        try await withSeams([1, 78, 0], fake) {
            try await window { win, m, _ in
                XCTAssertEqual(m.paneMode, .terminal)
                m.transcript.todosOpen = true
                let view = AgentDetailView(model: m, transcript: m.transcript)
                let chip = view.todosChip(view.floatingTodos, in: win)
                chip.wrappedValue.toggle()
                XCTAssertFalse(m.transcript.todosOpen, "the list closed")
                XCTAssertTrue(XrayPanels.shared.open.isEmpty, "no panel")
                XCTAssertEqual(fake.calls.count, 0, "no read")
                chip.wrappedValue.toggle()   // closed list, X-ray there: the panel on Tasks, the list stays shut
                await XrayPanels.shared.open[m.layout.focused]?.reading?.value
                XCTAssertEqual(XrayPanels.shared.open[m.layout.focused]?.tab, .tasks)
                XCTAssertFalse(m.transcript.todosOpen)
            }
        }
    }

    /// R1 review: the Go menu's X-Ray item is off below the gate (as the "..." item is absent), on at 1.78.0.
    func testGoMenuXrayItemIsOffBelowTheGate() async throws {
        for (version, on) in [([1, 77, 9], false), ([1, 78, 0], true)] {
            try await withSeams(version, FakeRun()) {
                try await window { win, _, _ in
                    XCTAssertEqual(win.enabled(.key(.xray)), on, "\(version)")
                }
            }
        }
    }

    func testTodosChipOpensTasksWhenTheTabExistsElseTheList() async throws {
        let empty = FakeRun(tasks: (0, Self.ndjson([Self.header, #"{"done":true,"count":0,"dropped":0}"#])))
        for (version, fake, wantPanel) in [([1, 78, 0], FakeRun(), true), ([1, 78, 0], empty, false), ([1, 77, 9], FakeRun(), false)] {
            try await withSeams(version, fake) {
                try await window { win, m, _ in
                    var listed = 0
                    win.todosChipTapped(listOpen: false) { listed += 1 }
                    await XrayPanels.shared.open[m.layout.focused]?.reading?.value
                    let p = XrayPanels.shared.open[m.layout.focused]
                    XCTAssertEqual(p != nil, wantPanel, "\(version) \(fake.tasks.0)")
                    XCTAssertEqual(p?.tab, wantPanel ? .tasks : nil)
                    XCTAssertEqual(listed, wantPanel ? 0 : 1, "else AgentTodosList, as today")
                    XCTAssertEqual(fake.calls.count, version == [1, 77, 9] ? 0 : 2)
                    win.todosChipTapped(listOpen: true) { listed += 1 }
                    XCTAssertEqual(listed, wantPanel ? 1 : 2, "an open list: the chip closes it")
                }
            }
        }
    }

    // MARK: R1351-i1: the chip's fallback on the wrong session

    /// A runner whose answers wait for the test: each call parks a continuation until `release` (no real wait).
    final class HeldRun: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [CheckedContinuation<Void, Never>] = []
        var count: Int { lock.withLock { held.count } }
        let out: Data
        init(out: Data) { self.out = out }
        var run: XrayPanels.Run {
            { [self] _, _, _ in
                await withCheckedContinuation { c in lock.withLock { held.append(c) } }
                return (0, out)
            }
        }
        func release() { lock.withLock { () -> [CheckedContinuation<Void, Never>] in let h = held; held = []; return h }.forEach { $0.resume() } }
    }

    /// Tap the chip on "api", select "api-qa" before the read returns, A has no Tasks tab: the list does not open over B.
    /// The control (no selection change) runs the fallback once.
    func testChipFallbackNeverOpensTheListOverAnotherSession() async throws {
        let none = Self.ndjson([Self.header, #"{"done":true,"count":0,"dropped":0}"#])
        for switchAway in [true, false] {
            let held = HeldRun(out: none)
            let (dch, run) = (XrayPanels.dch, XrayPanels.run)
            defer { (XrayPanels.dch, XrayPanels.run) = (dch, run); XrayPanels.shared.open = [:] }
            XrayPanels.dch = Self.gate([1, 78, 0])
            XrayPanels.run = held.run
            try await window { win, m, _ in
                var listed = 0
                win.todosChipTapped(listOpen: false) { listed += 1; m.transcript.todosOpen = true }
                let p = try XCTUnwrap(XrayPanels.shared.open[m.layout.focused])
                for _ in 0..<10_000 where held.count < 2 { await Task.yield() }   // both reads parked, no wall clock
                XCTAssertEqual(held.count, 2, "both reads are held")
                if switchAway { m.select(.live(Self.otherKey)) }
                held.release()
                await p.reading?.value
                XCTAssertEqual(listed, switchAway ? 0 : 1, switchAway ? "nothing opens over the other session" : "control: it opens")
                XCTAssertEqual(m.transcript.todosOpen, !switchAway)
            }
        }
    }

    // MARK: R1351-i2 and n1: the row's blocked-by cap, the drawer's width

    static func task(blocked: [String], id: String = "12") -> XrayTasks.Task {
        let ids = blocked.map { "\"\($0)\"" }.joined(separator: ",")
        return XrayTasks.parse(Self.ndjson([Self.header,
            #"{"task":{"id":"\#(id)","title":"Fix the login test","status":"pending","label":"PARKED","updated":"2026-11-16T11:00:00Z","blocked_by":[\#(ids)]}}"#,
            Self.done])).tasks[0]
    }

    /// Hosts `v` in a never-shown borderless window and returns the frames the pane probe saw (kind to the latest frame),
    /// in the container's space. Layout passes are bounded; nothing is posted.
    final class Box { var d: [String: CGRect] = [:] }
    func frames<V: View>(_ v: V, size: CGSize, kinds: [String]) -> [String: CGRect] {
        let box = Box()
        AgentPaneArea.probe = { k, _, r in box.d[k] = r }
        let host = NSHostingView(rootView: v.environment(\.agentPaneID, UUID()).coordinateSpace(.named(agentPaneAreaSpace)))
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { AgentPaneArea.probe = nil; win.contentView = nil; win.close() }
        for i in 0..<43 where i >= 40 || !kinds.allSatisfy({ box.d[$0] != nil }) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return box.d
    }

    func testRowShowsTheFirstBlockedIdsAndAPlusNCardKeepsAll() {
        let two = XrayTaskRow(Self.task(blocked: ["9", "10"]), now: Self.now)
        XCTAssertEqual(two.blocked, "blocked by 9, 10", "two ids whole")
        let ids = (1...12).map { "T\($0)" }
        let many = Self.task(blocked: ids)
        let row = XrayTaskRow(many, now: Self.now)
        XCTAssertEqual(row.blocked, "blocked by T1, T2, T3 +9", "the first ones and +N")
        XCTAssertTrue(row.spoken.contains("blocked by " + ids.joined(separator: ", ")), "VoiceOver keeps the whole list")
        XCTAssertTrue(XrayTaskCard.fields(many, now: Self.now).contains { $0.label == "Blocked by" && $0.value == ids.joined(separator: ", ") },
                      "the card keeps the full list")
        // The title keeps room at the drawer's width, worst case: the longest ids (32 scalars), a label and an age.
        let wide = Self.task(blocked: (1...12).map { String(repeating: "x", count: 31) + String($0 % 10) })
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let w = sz(340)
            let f = frames(XrayTaskRowView(row: XrayTaskRow(wide, now: Self.now), open: {}).padding(sz(10)).frame(width: w),
                           size: CGSize(width: w, height: 80), kinds: ["xrayTitle"])
            XCTAssertGreaterThan(f["xrayTitle"]?.width ?? 0, 0, "the title keeps room at \(scale)")
        }
    }

    func testDrawerIsAtMostThePaneWideAndNeverDrawsOutsideIt() {
        let pane = UUID(), target = XrayTarget(name: "api", dir: "/tmp/dch-test")
        let p = panel()
        XrayPanels.shared.open = [pane: p]
        defer { XrayPanels.shared.open = [:] }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            for paneWidth: CGFloat in [300, 500] {
                let host = Color.clear.frame(width: paneWidth, height: 400)
                    .overlay(alignment: .trailing) { XrayDrawer(pane: pane, target: target) }
                    .frame(width: 700, height: 400, alignment: .topLeading)
                let d = frames(host, size: CGSize(width: 700, height: 400), kinds: ["xray"])["xray"]
                XCTAssertTrue(d != nil, "the drawer is drawn")
                XCTAssertEqual(d?.width ?? 0, min(sz(340), paneWidth), accuracy: AXTreeSupport.devicePixel, "min(sz(340), the pane) at \(scale), pane \(paneWidth)")
                XCTAssertLessThanOrEqual(d?.maxX ?? 1000, paneWidth + AXTreeSupport.devicePixel, "no drawer pixel past the pane at \(scale), pane \(paneWidth)")
            }
        }
    }
}
