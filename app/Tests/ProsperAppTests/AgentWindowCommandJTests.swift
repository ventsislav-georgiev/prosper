import AppKit
import XCTest
@testable import ProsperApp

/// #901 B3 step 6 (spec section 10 :754-757, 7.1 rule 2, 7.4; R6.12, R2.2): ⌘J across layouts, in the window MODEL.
/// Offscreen only: the one window is never shown, ordered in or made key; its ⌘J is an event BUILT with
/// NSEvent.keyEvent (`treeKey`) and handed to performKeyEquivalent, never posted. The split gate is saved, set and
/// restored through `gate(_:)`; every row uses a private in-memory suite (`layoutSuite`, XCTestDefaults). Sessions are
/// fakes in a fake store; transcripts are files under tempDir(); the session verbs are recording fakes (`Calls`, the
/// `opened` counter), never run. No timer is waited on. Closures: the `onNewRuntime` and `offMain` seams and the
/// store's publish sink run on the main actor (the model calls them from its main-actor code, inline).
extension AgentWindowD1Tests {
    /// A visible model over `layouts` (the first active), a store of `sessions` (name, state, seconds ago, transcript),
    /// the wide pane area; `log` records each runtime made and whether an old transcript still ran at that moment.
    @MainActor
    private func jumpModel(_ layouts: [PaneLayout], _ sessions: [(String, AgentState, TimeInterval)], files: Bool = false,
                           log: SwitchLog? = nil, opened: @escaping (AgentSession) -> Void = { _ in })
        throws -> (AgentWindowModel, AgentIslandStore, UserDefaults) {
        let d = layoutSuite(), act = try XCTUnwrap(layouts.first?.id)
        d.set(try PaneLayoutStore(layouts: layouts, active: act, mru: [act]).encode(), forKey: "agentWindowLayouts")
        var built: [AgentSession] = []
        for (n, s, ago) in sessions {
            var path: String?
            if files { path = try transcriptFile(n).path }
            built.append(session(n, s, ago: ago, path: path))
        }
        let st = store(built)
        let m = windowModel(st, opened: opened, layouts: d)
        m.paneArea = Self.wideArea
        m.runtimes.values.forEach { $0.transcript.taskStoreDirectory = { _ in nil } }   // never a real task store
        let base = m.onNewRuntime
        m.onNewRuntime = { r in
            base(r)
            r.transcript.taskStoreDirectory = { _ in nil }
            let pane = r.pane
            log?.made.append(pane)
            log?.oldRunningAtMake.append(log?.old.contains { $0.running } ?? false)
            r.transcript.offMain = { job in log?.reads.append(pane); job() }   // on main, where poll() calls it
        }
        m.setVisible(true)
        return (m, st, d)
    }

    /// The session name the focused pane of `m` shows.
    @MainActor
    private func focusedName(_ m: AgentWindowModel) -> String? {
        guard case let .session(_, n)? = m.layout.panes.first(where: { $0.id == m.layout.focused })?.target else { return nil }
        return n
    }

    /// The pane of `l` that shows `name`.
    private func paneOf(_ l: PaneLayout, _ name: String) throws -> UUID {
        try XCTUnwrap(l.panes.first { $0.target == paneTarget(name) }?.id)
    }

    /// Item 3, the order (10 :754-756): Needs you order is web-ui (blocked, 30 s), api-fix (blocked, 60 s), ops-sync
    /// (blocked, 90 s), docs-pass (done, 10 s). From api-fix (focused) the next is ops-sync (AFTER the focused session,
    /// not the top: web-ui); from ops-sync it is web-ui (wrapped, and blocked before the done docs-pass that follows
    /// ops-sync); from web-ui api-fix. With the blocked ones idle, docs-pass (done) is next; with only the focused
    /// session needing you, ⌘J does nothing (false, nothing written).
    @MainActor
    func testAgentWindowCommandJOrderBlockedFirstAfterTheFocusedSessionWrapping() throws {
        gate(true)
        let a = paneLayout([paneTarget("api-fix"), paneTarget("docs-pass"), paneTarget("web-ui"), paneTarget("ops-sync")])
        let (m, st, _) = try jumpModel([a], [("api-fix", .blocked, 60), ("docs-pass", .done, 10), ("web-ui", .blocked, 30),
                                             ("ops-sync", .blocked, 90)])
        defer { m.close() }
        XCTAssertEqual(m.sections.first?.rows.map(\.title), ["web-ui", "api-fix", "ops-sync", "docs-pass"], "Needs you order")
        XCTAssertEqual(focusedName(m), "api-fix")
        XCTAssertTrue(m.nextNeedsYou())
        XCTAssertEqual(focusedName(m), "ops-sync", "after the focused session, not the top of the list")
        XCTAssertTrue(m.nextNeedsYou())
        XCTAssertEqual(focusedName(m), "web-ui", "wrapped; blocked before the done session that follows")
        XCTAssertTrue(m.nextNeedsYou())
        XCTAssertEqual(focusedName(m), "api-fix")
        XCTAssertEqual(m.layout.id, a.id)
        st.sessions = [session("api-fix", .idle), session("docs-pass", .done, ago: 10), session("web-ui", .idle),
                       session("ops-sync", .idle)]
        XCTAssertTrue(m.nextNeedsYou())
        XCTAssertEqual(focusedName(m), "docs-pass", "no blocked session: the done one")
        let writes = m.layoutWrites, before = m.layout
        XCTAssertFalse(m.nextNeedsYou(), "only the focused session needs you: nothing to jump to")
        XCTAssertEqual(m.layout, before)
        XCTAssertEqual(m.layoutWrites, writes)
    }

    /// Item 3, the three placements (10 :756-757). Layouts A (active: api-fix focused, docs-pass), B (web-ui), C (ops-sync,
    /// web-ui), D (docs-pass). (a) docs-pass blocked: shown in the active layout and in D: the ACTIVE layout wins (7.1
    /// rule 1: no switch when it is in view), its pane focused, one write. (b) web-ui blocked, shown in B and C: the
    /// FIRST stored layout wins (B, the lower ⌃N number): switched through switchLayout (the MRU, one write) with web-ui
    /// focused; this step goes through the window's key route (a built ⌘J). (c) lint-run blocked, in no pane: it goes
    /// into the focused pane (B's), 7.1 rule 2; the layout stays B. No session verb runs, nothing is opened.
    @MainActor
    func testAgentWindowCommandJPlacesInTheActiveLayoutAnotherLayoutOrTheFocusedPane() throws {
        gate(true)
        let a = paneLayout([paneTarget("api-fix"), paneTarget("docs-pass")]), b = paneLayout([paneTarget("web-ui")])
        let c = paneLayout([paneTarget("ops-sync"), paneTarget("web-ui")]), e = paneLayout([paneTarget("docs-pass")])
        var opened = 0
        let (m, st, d) = try jumpModel([a, b, c, e], [("api-fix", .idle, 60), ("docs-pass", .blocked, 30),
                                                      ("web-ui", .idle, 60), ("ops-sync", .idle, 60)],
                                       opened: { _ in opened += 1 })
        defer { m.close() }
        let calls = Calls()
        calls.wire(m)
        var writes = m.layoutWrites

        XCTAssertTrue(m.nextNeedsYou())
        XCTAssertEqual(m.layout.id, a.id, "(a) in the active layout: no switch")
        XCTAssertEqual(m.layout.focused, try paneOf(a, "docs-pass"))
        XCTAssertEqual(m.keyFocus, .pane)
        XCTAssertEqual(m.layoutWrites, writes + 1)
        writes = m.layoutWrites

        st.sessions = [session("api-fix", .idle), session("docs-pass", .idle), session("web-ui", .blocked),
                       session("ops-sync", .idle)]
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        XCTAssertTrue(win.performKeyEquivalent(with: treeKey(38, [.command], "j")), "(b) the built ⌘J is the window's")
        XCTAssertEqual(m.layout.id, b.id, "(b) the first stored layout showing it")
        XCTAssertEqual(m.layout.focused, try paneOf(b, "web-ui"))
        XCTAssertEqual(m.layoutWrites, writes + 1, "one write for the switch and its focus")
        let saved = savedLayouts(d)
        XCTAssertEqual(saved.active, b.id)
        XCTAssertEqual(saved.mru.first, b.id, "the switch's MRU")
        writes = m.layoutWrites
        win.model = nil

        st.sessions = st.sessions + [session("lint-run", .blocked)]
        XCTAssertTrue(m.nextNeedsYou())
        XCTAssertEqual(m.layout.id, b.id, "(c) no switch")
        XCTAssertEqual(m.layout.panes.count, 1)
        XCTAssertEqual(focusedName(m), "lint-run", "(c) into the focused pane")
        XCTAssertEqual(m.layoutWrites, writes + 1)
        XCTAssertEqual(opened, 0, "nothing opened")
        XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no session verb")
        XCTAssertTrue(m.newSession == nil)
    }

    /// R6.12, the active layout zoomed (7.4): api-fix zoomed and focused, docs-pass blocked: ⌘J MOVES the zoom to
    /// docs-pass: exactly one pane suspends and one starts, every frame stays put, the blob carries the moved zoom.
    @MainActor
    func testAgentWindowCommandJMovesTheZoomInTheActiveLayout() throws {
        gate(true)
        let a = paneLayout([paneTarget("api-fix"), paneTarget("docs-pass"), paneTarget("web-ui")]).toggleZoom()
        let (m, _, d) = try jumpModel([a], [("api-fix", .idle, 60), ("docs-pass", .blocked, 30), ("web-ui", .idle, 60)],
                                      files: true)
        defer { m.close() }
        let api = try paneOf(a, "api-fix"), docs = try paneOf(a, "docs-pass"), web = try paneOf(a, "web-ui")
        XCTAssertEqual(m.layout.zoomed, api)
        func running(_ p: UUID) -> Bool { m.runtimes[p]?.transcript.running == true }
        func suspended(_ p: UUID) -> Bool { m.runtimes[p]?.transcript.suspended == true }
        XCTAssertTrue(running(api) && !running(docs) && !running(web))
        let frames = m.paneFrames(in: m.paneArea), writes = m.layoutWrites
        XCTAssertTrue(m.nextNeedsYou())
        XCTAssertEqual(m.layout.focused, docs)
        XCTAssertEqual(m.layout.zoomed, docs, "the zoom moved, not unzoomed")
        XCTAssertEqual(m.shownPanes, [docs])
        XCTAssertEqual(m.paneFrames(in: m.paneArea), frames, "every frame stays put")
        XCTAssertTrue(suspended(api) && !running(api), "exactly one suspend")
        XCTAssertTrue(running(docs) && !running(web), "exactly one start")
        XCTAssertEqual(m.layoutWrites, writes + 1)
        XCTAssertEqual(savedLayouts(d).layouts.first { $0.id == a.id }?.zoomed, docs, "the blob carries the moved zoom")
    }

    /// R6.12, the TARGET layout zoomed (7.4 :562-563): A (api-fix) active; B (docs-pass, web-ui, ops-sync) saved zoomed on
    /// docs-pass; web-ui blocked. ⌘J switches to B with its saved layout, the zoom moved to web-ui in the same write
    /// (DECISION: one adopt, so the saved zoomed pane is never started and stopped again): A's pane stopped before any
    /// of B's runtimes is made; only web-ui runs; the blob's B is zoomed on web-ui.
    @MainActor
    func testAgentWindowCommandJMovesTheZoomOfAZoomedTargetLayout() throws {
        gate(true)
        let a = paneLayout([paneTarget("api-fix")])
        let b = paneLayout([paneTarget("docs-pass"), paneTarget("web-ui"), paneTarget("ops-sync")]).toggleZoom()
        let log = SwitchLog()
        let (m, _, d) = try jumpModel([a, b], [("api-fix", .idle, 60), ("docs-pass", .idle, 60), ("web-ui", .blocked, 30),
                                               ("ops-sync", .idle, 60)], files: true, log: log)
        defer { m.close() }
        let docs = try paneOf(b, "docs-pass"), web = try paneOf(b, "web-ui"), ops = try paneOf(b, "ops-sync")
        XCTAssertEqual(b.zoomed, docs)
        log.old = a.order.compactMap { m.runtimes[$0]?.transcript }
        XCTAssertTrue(log.old.count == 1 && log.old.allSatisfy(\.running))
        log.made = []
        log.oldRunningAtMake = []
        let writes = m.layoutWrites
        XCTAssertTrue(m.nextNeedsYou())
        XCTAssertEqual(m.layout.id, b.id)
        XCTAssertEqual(m.layout.focused, web)
        XCTAssertEqual(m.layout.zoomed, web, "the zoom moved to the target")
        XCTAssertEqual(m.shownPanes, [web])
        XCTAssertEqual(log.made.count, 3, "a runtime per pane of B")
        XCTAssertEqual(log.oldRunningAtMake, [false, false, false], "A's pane stopped before any of B's is made")
        XCTAssertTrue(m.runtimes[web]?.transcript.running == true)
        XCTAssertTrue(m.runtimes[docs]?.transcript.running == false && m.runtimes[ops]?.transcript.running == false)
        XCTAssertEqual(m.layoutWrites, writes + 1, "one write")
        let saved = savedLayouts(d).layouts.first { $0.id == b.id }
        XCTAssertEqual(saved?.zoomed, web)
        XCTAssertEqual(saved?.focused, web)
    }

    /// R2.2 (11.2): a switch 1 -> 2 -> 1: on the way back too, every pane of layout 2 is stopped before any runtime of
    /// layout 1 is made, layout 1's saved focused pane (the second) is read first, one read per pane, one write.
    @MainActor
    func testAgentWindowCommandJSwitchThereAndBackStopsBeforeStartingFocusedFirst() throws {
        gate(true)
        var one = paneLayout([paneTarget("api-fix"), paneTarget("docs-pass")])
        let second = try paneOf(one, "docs-pass")
        one = try one.focus(second).get()
        let two = paneLayout([paneTarget("web-ui"), paneTarget("ops-sync")])
        let log = SwitchLog()
        let (m, _, _) = try jumpModel([one, two], [("api-fix", .idle, 60), ("docs-pass", .idle, 60), ("web-ui", .idle, 60),
                                                   ("ops-sync", .idle, 60)], files: true, log: log)
        defer { m.close() }
        XCTAssertTrue(m.switchLayout(number: 2) == nil)
        XCTAssertEqual(m.layout.id, two.id)
        log.old = two.order.compactMap { m.runtimes[$0]?.transcript }
        XCTAssertTrue(log.old.count == 2 && log.old.allSatisfy(\.running), "layout 2's panes run")
        log.made = []
        log.oldRunningAtMake = []
        log.reads = []
        let writes = m.layoutWrites
        XCTAssertTrue(m.switchLayout(number: 1) == nil)
        XCTAssertEqual(m.layout.id, one.id)
        XCTAssertEqual(log.made.count, 2)
        XCTAssertEqual(log.oldRunningAtMake, [false, false], "every pane of 2 stopped before any of 1 is made")
        XCTAssertTrue(log.old.allSatisfy { !$0.running && !$0.suspended }, "one stop each: stopped, not suspended")
        XCTAssertEqual(log.reads.first, second, "the saved focused pane is read first")
        XCTAssertEqual(log.reads.count, 2, "one read per pane")
        XCTAssertEqual(m.layout.focused, second)
        XCTAssertEqual(m.layoutWrites, writes + 1)
    }

    /// 15.0 GATE-OFF GUARD: two layouts and blocked sessions; ⌘J by the model and by the window's key route (a built
    /// event): false, the same layout and focus, the same blob bytes, 0 writes.
    @MainActor
    func testAgentWindowCommandJGateOffDoesNothing() throws {
        gate(false)
        let a = paneLayout([paneTarget("api-fix"), paneTarget("docs-pass")]), b = paneLayout([paneTarget("web-ui")])
        let (m, _, d) = try jumpModel([a, b], [("api-fix", .idle, 60), ("docs-pass", .blocked, 30), ("web-ui", .blocked, 30),
                                               ("lint-run", .blocked, 20)])
        defer { m.close() }
        let before = m.layout, bytes = d.data(forKey: "agentWindowLayouts"), writes = m.layoutWrites
        XCTAssertFalse(m.nextNeedsYou())
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        _ = win.performKeyEquivalent(with: treeKey(38, [.command], "j"))
        win.model = nil
        XCTAssertEqual(m.layout, before, "gate off: the same layout, focus and targets")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes)
        XCTAssertEqual(m.layoutWrites, writes)
    }

    /// R901-s6-q1 (#901 B3 step 7): A (api, focused) active, B (api-qa) stored, api-qa blocked. The stored-layout switch
    /// REFUSES (a recording fake through the `switching` seam: no refusal is reachable through the model's own store,
    /// report.txt 1b): asked once, for B and B's api-qa pane, with the keys still the sidebar's; nothing switches;
    /// Command-J falls through to 7.1 rule 2: api-qa goes into A's focused pane (a row's click: the pane takes the keys).
    /// GUARD refusal-ignored.
    @MainActor
    func testAgentWindowCommandJRefusedSwitchFallsThroughToTheFocusedPane() throws {
        gate(true)
        let a = paneLayout([paneTarget("api")]), b = paneLayout([paneTarget("api-qa")])
        var opened = 0
        let (m, _, d) = try jumpModel([a, b], [("api", .idle, 60), ("api-qa", .blocked, 30)], opened: { _ in opened += 1 })
        defer { m.close() }
        let calls = Calls()
        calls.wire(m)
        m.keyFocus = .sidebar
        let target = try paneOf(b, "api-qa"), writes = m.layoutWrites
        var asked: [(layout: UUID, pane: UUID, keys: PaneKeys.KeyFocus)] = []
        XCTAssertTrue(m.nextNeedsYou(switching: { l, p in asked.append((l, p, m.keyFocus)); return .noSuchLayout }))
        XCTAssertEqual(asked.count, 1, "the stored-layout switch was asked once")
        XCTAssertEqual(asked.first?.layout, b.id)
        XCTAssertEqual(asked.first?.pane, target)
        XCTAssertEqual(asked.first?.keys, .sidebar, "the keys do not move before the switch is made")
        XCTAssertEqual(m.layout.id, a.id, "refused: nothing switched")
        XCTAssertEqual(savedLayouts(d).active, a.id)
        XCTAssertEqual(m.layout.panes.count, 1)
        XCTAssertEqual(focusedName(m), "api-qa", "fell through to rule 2: into the focused pane")
        XCTAssertEqual(m.keyFocus, .pane, "rule 2 is a row's click: the pane takes the keys")
        XCTAssertEqual(m.layoutWrites, writes + 1, "rule 2's one write")
        XCTAssertEqual(opened, 0, "nothing opened")
        XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no session verb")
    }

    /// R901-s6-q2 (#901 B3 step 7): with the gate on and a field or the form open, a BUILT Command-J (never posted)
    /// handed to a never-shown window does not reach nextNeedsYou: nothing switches, focuses or is written, and the
    /// window answers as today's route does (the same event with the gate off, where the Command-J line is skipped).
    /// A (api) active, B (api-qa) stored, api-qa blocked: without the exclusion Command-J would switch to B.
    @MainActor
    private func assertCommandJStandsDown(_ m: AgentWindowModel, _ d: UserDefaults, _ why: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let before = m.layout, keys = m.keyFocus, writes = m.layoutWrites, bytes = d.data(forKey: "agentWindowLayouts")
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        defer { win.model = nil; win.close() }
        let on = win.performKeyEquivalent(with: treeKey(38, [.command], "j"))
        XCTAssertEqual(m.layout, before, "\(why): nothing switched or focused", file: file, line: line)
        XCTAssertEqual(m.keyFocus, keys, "\(why): the keys stay", file: file, line: line)
        XCTAssertEqual(m.layoutWrites, writes, "\(why): nothing written", file: file, line: line)
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes, file: file, line: line)
        gate(false)   // today's route: the Command-J line skipped; gate(_:) restores the saved value at teardown
        let today = win.performKeyEquivalent(with: treeKey(38, [.command], "j"))
        gate(true)
        XCTAssertEqual(on, today, "\(why): the event goes on to today's route", file: file, line: line)
        XCTAssertEqual(m.layout, before, file: file, line: line)
    }

    /// The A/B fixture of the three stand-down rows.
    @MainActor
    private func standDownModel() throws -> (AgentWindowModel, AgentIslandStore, UserDefaults, PaneLayout) {
        let a = paneLayout([paneTarget("api")]), b = paneLayout([paneTarget("api-qa")])
        let (m, st, d) = try jumpModel([a, b], [("api", .idle, 60), ("api-qa", .blocked, 30)])
        return (m, st, d, a)
    }

    /// R901-s6-q2 (a): the session Rename field open (openRenameField: no ask, no select, no verb). GUARD
    /// rename-exclusion-dropped.
    @MainActor
    func testAgentWindowCommandJStandsDownForTheRenameField() throws {
        gate(true)
        let (m, _, d, a) = try standDownModel()
        defer { m.close() }
        m.openRenameField(AgentRenameEdit(key: AgentSessionKey(dir: "/tmp/dch-test", name: "api"), text: ""))
        XCTAssertTrue(m.renaming != nil, "the rename field is open")
        assertCommandJStandsDown(m, d, "rename field")
        XCTAssertEqual(m.layout.id, a.id)
        XCTAssertTrue(m.renaming != nil, "the field stays open")
    }

    /// R901-s6-q2 (b): a layout's inline Rename field open. GUARD layout-rename-exclusion-dropped.
    @MainActor
    func testAgentWindowCommandJStandsDownForTheLayoutRenameField() throws {
        gate(true)
        let (m, _, d, a) = try standDownModel()
        defer { m.close() }
        m.beginLayoutRename(a.id)
        XCTAssertEqual(m.layoutRenaming, a.id, "the layout field is open")
        assertCommandJStandsDown(m, d, "layout rename field")
        XCTAssertEqual(m.layoutRenaming, a.id, "the field stays open")
    }

    /// R901-s6-q2 (c): the New session form open (a typed command: the island is asked nothing; the dch binary is a value
    /// for the form's gate, never run; a spawn fails the row). GUARD form-exclusion-dropped.
    @MainActor
    func testAgentWindowCommandJStandsDownForTheNewSessionForm() throws {
        gate(true)
        try withNewSessionPrefs {
            Preferences.agentIslandNewSessionCommand = "claude"
            let (m, st, d, a) = try standDownModel()
            defer { m.close() }
            st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
            m.home = "/Users/example"
            m.spawnSession = { _, _, _, _ in XCTFail("no spawn"); return nil }   // main actor (the model calls it)
            m.openNewSession()
            XCTAssertTrue(m.newSession != nil, "the form is open")
            assertCommandJStandsDown(m, d, "New session form")
            XCTAssertEqual(m.layout.id, a.id)
            XCTAssertTrue(m.newSession != nil, "the form stays open")
        }
    }
}
