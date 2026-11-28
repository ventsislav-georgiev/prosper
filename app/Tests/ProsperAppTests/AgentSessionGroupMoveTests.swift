import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2062: session groups by hand. dch 1.196's `group`/`group_manual` place a row, a live row's Move to group runs
/// `--group-set`, and New group… adds a group with an empty pattern. Offscreen only: no menu popped, no window shown,
/// no real dch (the controller's runner is a recorder that launches nothing), no defaults written (the model's seams).
final class AgentSessionGroupMoveTests: XCTestCase {
    static let dir = "/tmp/dch-test"
    static let v196 = DchCommand.Binary(path: "/fake/dch", version: [1, 196, 0])

    func session(_ name: String, group: String? = nil, manual: String? = nil) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: Self.dir, name: name), alias: "", activity: 0, state: .idle, agents: 0,
                     group: group, groupManual: manual)
    }

    let work = SessionGroup(id: "w1", name: "Work", pattern: "zzz")
    let qa = SessionGroup(id: SessionGroup.sidekicksID, name: "Sidekicks", pattern: "-qa")

    @MainActor
    func store(_ sessions: [AgentSession], dch: DchCommand.Binary? = v196) -> AgentIslandStore {
        let s = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        s.controlDch = dch
        s.sessions = sessions
        s.sessionGroups = [work, qa]
        s.storedGroupCount = 2
        return s
    }

    /// The argv of every launch; each answers `status` and `output`. #2062 r2: `configPath` set, each launch also keeps
    /// that file's text as it stands at the launch ("" when missing).
    final class Launches: @unchecked Sendable {
        let lock = NSLock()
        var all: [[String]] = []
        var status: Int32 = 0
        var output = ""
        var configPath: String?
        var configs: [String] = []
        var args: [[String]] { lock.withLock { all } }
    }

    @MainActor
    func controller(_ st: AgentIslandStore, _ rec: Launches) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        let dch = st.controlDch
        c.controlDch = { dch }
        c.controlEnv = { ["DCH_SOCKET_DIR": $0] }
        c.readHistory = { _, _ in [] }
        c.historyDirs = { [Self.dir] }
        c.readLiveRecords = { _ in [] }
        c.seedDirs = { [] }
        c.listSessions = { _ in [] }
        c.runner = DchActionRunner(bound: 60, launch: { _, args, _, _, onPid, onOutput in
            let (status, out) = rec.lock.withLock {
                rec.all.append(args)
                if let p = rec.configPath { rec.configs.append((try? String(contentsOfFile: p, encoding: .utf8)) ?? "") }
                return (rec.status, Data(rec.output.utf8))
            }
            onPid(4242)
            onOutput(out)
            return (status, out)
        }, signal: { _ in })
        c.store = st
        return c
    }

    @MainActor
    func settle(_ c: AgentIslandController, until: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        repeat {
            c.queue.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while !until() && Date() < end
    }

    // MARK: - Decoding and placement

    /// `group`/`group_manual` decode as names ("" for null); a row without them (older dch) keeps both nil.
    func testListRowsDecodeGroupAndManualAndARowWithoutThemHasNeither() {
        let rows = DchCommand.parseListJSON(Data("""
            [{"name":"api","group":"Work","group_manual":"Work"},
             {"name":"api-qa","group":null,"group_manual":null},
             {"name":"bad","group":"a=b","group_manual":7},
             {"name":"old"}]
            """.utf8))
        XCTAssertEqual(rows.map(\.group), ["Work", "", "", nil])
        XCTAssertEqual(rows.map(\.groupManual), ["Work", "", nil, nil])
    }

    /// dch's group places a row (any case; its manual one wins over the pattern); "" or a group these groups do not have
    /// is the main list; a row without the key is matched by the patterns as before.
    func testSplitPlacesByDchsGroupAndKeepsPatternGroupingForOlderRows() {
        let list = [session("api", group: "work", manual: "Work"), session("api-qa", group: ""),
                    session("old-qa"), session("x", group: "Gone"), session("plain")]
        let s = AgentIsland.split(list, groups: [work, qa])
        XCTAssertEqual(s.groups.first?.sessions.map(\.name), ["api"], "the manual group, not the pattern")
        XCTAssertEqual(s.groups.last?.sessions.map(\.name), ["old-qa"], "no key: the pattern places it")
        XCTAssertEqual(s.primary.map(\.name), ["api-qa", "x", "plain"], "list order kept")
        let old = AgentIsland.split([session("api"), session("api-qa")], groups: [work, qa])
        XCTAssertEqual(old.groups.last?.sessions.map(\.name), ["api-qa"], "an older dch: today's pattern grouping")
    }

    // MARK: - The row menu

    @MainActor
    func items(_ e: [AgentSidebarMenuEntry]) -> [AgentSidebarMenuEntry] {
        guard case .submenu(AgentIsland.moveToGroupLabel, true, let items)? = e.first, e.count == 1 else { return [] }
        return items
    }

    /// Every group (the manual one checked), a divider, Automatic (checked only with no manual group), New group…;
    /// none for an older row, an older control dch or a name dch reads as a flag; New group… off at the cap.
    @MainActor
    func testMoveToGroupMenuItemsAndChecksForAManualAndAnAutomaticSession() {
        let manual = session("api", group: "Work", manual: "work"), auto = session("api-qa", group: "Sidekicks")
        let st = store([manual, auto])
        let newGroup = AgentSidebarMenuEntry.item(AgentIsland.newGroupLabel, enabled: true, checked: nil, verb: .newGroup)
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(manual, store: st)), [
            .item("Work", enabled: true, checked: true, verb: .moveToGroup("Work")),
            .item("Sidekicks", enabled: true, checked: false, verb: .moveToGroup("Sidekicks")),
            .divider,
            .item(AgentIsland.automaticGroupLabel, enabled: true, checked: false, verb: .moveToGroup(nil)),
            newGroup,
        ])
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(auto, store: st)), [
            .item("Work", enabled: true, checked: false, verb: .moveToGroup("Work")),
            .item("Sidekicks", enabled: true, checked: false, verb: .moveToGroup("Sidekicks")),
            .divider,
            .item(AgentIsland.automaticGroupLabel, enabled: true, checked: true, verb: .moveToGroup(nil)),
            newGroup,
        ])
        XCTAssertEqual(AgentWindowControls.moveToGroupMenu(session("old"), store: st), [], "no group key: an older dch")
        XCTAssertEqual(AgentWindowControls.moveToGroupMenu(session("-x", group: ""), store: st), [], "a flag-like name")
        XCTAssertEqual(AgentWindowControls.moveToGroupMenu(auto, store: store([auto], dch: DchCommand.Binary(path: "/fake/dch",
                                                                                                            version: [1, 195, 0]))), [])
        st.storedGroupCount = SessionGroup.maxCount
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(auto, store: st)).last,
                       .item(AgentIsland.groupsFullText, enabled: false, checked: nil, verb: .newGroup))
        XCTAssertEqual(AgentWindowControls.sidebarMenu(store: st, autoAllow: false).dropFirst().first,
                       .item(AgentIsland.groupsFullText, enabled: false, checked: nil, verb: .newGroup), "the sidebar's too")
    }

    // MARK: - --group-set

    /// A group sends exactly `--group-set <name> <group> --json`, Automatic `--auto`; a failed reply's reason is the
    /// row's line and nothing runs again.
    @MainActor
    func testChoosingAGroupSendsGroupSetAndAFailedReplyReachesTheRowOnce() throws {
        let s = session("api", group: "Work", manual: ""), rec = Launches()
        let st = store([s]), c = controller(st, rec)
        // Each run waits for its launch, the runner to free the row and the answer's hop to main (the line it leaves).
        func run(_ g: String?, line: String? = nil) {
            let n = rec.args.count
            XCTAssertTrue(c.setGroup(s, group: g))
            settle(c) { rec.args.count > n && !c.runner.isBusy(s.key) && st.actions[s.key] == line }
        }
        rec.output = #"{"name":"api","group":"Work","result":"ok"}"# + "\n"
        run("Work")
        XCTAssertEqual(rec.args.last, ["--group-set", "api", "Work", "--json"])
        run(nil)
        XCTAssertEqual(rec.args.last, ["--group-set", "api", "--auto", "--json"])
        XCTAssertTrue(st.actions[s.key] == nil, "ok: no line")
        rec.lock.withLock {
            rec.status = 1
            rec.output = #"{"name":"api","group":null,"result":"failed","reason":"no_group"}"# + "\n"
        }
        run("Gone", line: AgentIsland.noGroupText)
        XCTAssertEqual(st.actions[s.key], AgentIsland.noGroupText)
        XCTAssertEqual(rec.args.count, 3, "never retried")
        rec.lock.withLock { rec.status = 0; rec.output = #"{"name":"api","group":"Work","result":"ok"}"# + "\n" }
        run("Work")
        XCTAssertTrue(st.actions[s.key] == nil, "the next move that works drops the failure")
        XCTAssertFalse(c.setGroup(session("gone", group: ""), group: "Work"), "not live: nothing")
        XCTAssertEqual(rec.args.count, 4)
    }

    func testGroupSetFailureWordsEachReasonAndHowTheCallEnded() {
        func r(_ status: Int32, _ reason: String?, stopped: Bool = false) -> DchActionResult {
            DchActionResult(status: status, json: reason.map { [DchJSONLine(name: "api", result: "failed", reason: $0)] } ?? [],
                            stopped: stopped)
        }
        XCTAssertTrue(AgentIsland.groupSetFailure(DchActionResult(status: 0, json: [DchJSONLine(name: "api", result: "ok")])) == nil)
        XCTAssertEqual(AgentIsland.groupSetFailure(r(1, "no_group")), "That group no longer exists")
        XCTAssertEqual(AgentIsland.groupSetFailure(r(1, "no_session")), "That session is no longer running")
        XCTAssertEqual(AgentIsland.groupSetFailure(r(1, "io_error")), "Couldn't save the group: dch could not write it")
        XCTAssertEqual(AgentIsland.groupSetFailure(r(2, nil)), "Couldn't move to the group: dch exited 2")
        XCTAssertEqual(AgentIsland.groupSetFailure(r(-1, nil, stopped: true)), "Couldn't move to the group: dch timed out")
        XCTAssertTrue(AgentIsland.isGroupSetFailure("Couldn't move to the group: dch exited 2"))
        XCTAssertEqual(AgentIsland.groupSetArgs("-x", "Work"), nil)
    }

    // MARK: - New group…

    func testNewGroupAddsAValidNameWithAnEmptyPatternAndRefusesBadOnesAndTheNinth() {
        guard case .success(let list) = AgentWindowControls.addingGroup("  Ops ", to: [work]) else { return XCTFail("added") }
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.last?.name, "Ops")
        XCTAssertEqual(list.last?.pattern, "", "an empty pattern: Automatic never puts a session there")
        for bad in ["", "   ", "a=b", "Sessions", "history", "WORK", String(repeating: "x", count: 33)] {
            if case .success = AgentWindowControls.addingGroup(bad, to: [work]) { XCTFail("\(bad) refused") }
        }
        let eight = (1...SessionGroup.maxCount).map { SessionGroup(id: "g\($0)", name: "G\($0)", pattern: "p\($0)") }
        XCTAssertEqual(AgentWindowControls.newGroupRefusal("Ninth", stored: eight), AgentIsland.groupsFullText)
        XCTAssertNil(AgentWindowControls.newGroupRefusal("Ninth", stored: Array(eight.dropLast())))
    }

    /// The sidebar's New group… stores the group and moves nothing; a row's stores it, then moves that row into it once;
    /// a refused name stays in the field with its reason and nothing is stored.
    @MainActor
    func testTheNameFieldStoresTheGroupAndARowsAskMovesItIn() {
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        var stored = [work], moves: [(String, String?)] = [], order: [String] = []
        m.storedGroups = { stored }
        m.saveGroups = { stored = $0; order.append("save") }
        m.setGroup = { s, g, configFirst in moves.append((s.name, g)); order.append(configFirst ? "move, config first" : "move") }
        m.runSidebar(.newGroup)
        XCTAssertEqual(m.newGroup, AgentWindowModel.NewGroupAsk())
        m.newGroup?.name = "a=b"
        m.answerNewGroup(true)
        XCTAssertEqual(stored.count, 1, "refused: nothing stored")
        XCTAssertNotNil(m.newGroup?.refused)
        m.newGroup?.name = "Ops"
        m.answerNewGroup(true)
        XCTAssertTrue(m.newGroup == nil)
        XCTAssertEqual(stored.map(\.name), ["Work", "Ops"])
        XCTAssertTrue(moves.isEmpty, "the sidebar's: no session moved")
        let s = session("api", group: "")
        m.runMove(.newGroup, s)
        m.newGroup?.name = "Ops 2"
        m.answerNewGroup(true)
        XCTAssertEqual(stored.last?.pattern, "")
        XCTAssertEqual(moves.map(\.0), ["api"])
        XCTAssertEqual(moves.last?.1, "Ops 2")
        m.runMove(.moveToGroup(nil), s)
        XCTAssertEqual(moves.count, 2)
        XCTAssertTrue(moves.last?.1 == nil, "Automatic: --auto")
        XCTAssertEqual(order, ["save", "save", "move, config first", "move"],
                       "#2062 r2: the new group is saved, then moved into with dch's config written first; a plain move is not")
        m.runSidebar(.newGroup)
        m.answerNewGroup(false)
        XCTAssertTrue(m.newGroup == nil, "Cancel")
        XCTAssertEqual(stored.count, 3)
    }

    // MARK: - Round 2: manual-only groups, the config before the move, the name field

    let ops = SessionGroup(id: "o1", name: "Ops", pattern: "")

    /// The groups list and the tabs in the XCTest store (never the operator's defaults), put back after the row.
    func useGroups(_ list: [SessionGroup]) {
        let keys = ["agentIslandSidekickTabs", "agentIslandSessionGroups", "agentIslandSessionGroupsUpdated",
                    "agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated", "agentIslandDchGroupsAdoptChecked"]
        let saved = keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        Preferences.agentIslandSidekickTabs = true
        Preferences.agentIslandSessionGroups = list
    }

    /// dch #721: a group with no pattern is manual-only. The controller gives it to the store (its tab, Move to group),
    /// the writer gives dch `group = Ops =`, the Settings editor saves it, and the local pattern split never fills it.
    @MainActor
    func testAManualGroupIsKeptEverywhereAndNeverFilledByThePatternSplit() {
        let blank = SessionGroup(id: "b1", name: "Blank", pattern: " \t")
        useGroups([work, ops, blank])
        let s = session("api", group: ""), st = store([s]), c = controller(st, Launches())
        c.rowDetailsChanged()
        XCTAssertEqual(st.sessionGroups.map(\.name), ["Work", "Ops", "Blank"], "the controller keeps manual groups")
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(s, store: st)).prefix(3), [
            .item("Work", enabled: true, checked: false, verb: .moveToGroup("Work")),
            .item("Ops", enabled: true, checked: false, verb: .moveToGroup("Ops")),
            .item("Blank", enabled: true, checked: false, verb: .moveToGroup("Blank")),
        ])
        let values = DchConfigWriter.groupValues([work, ops, blank])
        XCTAssertEqual(values, ["Work = zzz", "Ops =", "Blank ="])
        XCTAssertEqual(String(decoding: DchConfigWriter.render(Data(), autoAllow: false, pattern: "zzz", groups: values), as: UTF8.self),
                       "auto_allow = false\nsidekick_pattern = zzz\ngroup = Work = zzz\ngroup = Ops =\ngroup = Blank =\n",
                       "dch #721's form, never a placeholder regex")
        let e = SessionGroupsEditor([work, ops, blank])
        XCTAssertTrue(e.reason(ops, stored: []) == nil && e.reason(blank, stored: []) == nil, "no reason: saved")
        XCTAssertEqual(e.saved(stored: []), [work, ops, blank], "the editor's save keeps them")
        let split = AgentIsland.split([session("Ops"), session("ops-1"), session("Blank")], groups: [ops, blank])
        XCTAssertEqual(split.primary.map(\.name), ["Ops", "ops-1", "Blank"], "an older dch's rows: no pattern, no match")
        XCTAssertTrue(split.groups.allSatisfy { $0.sessions.isEmpty })
        let placed = AgentIsland.split([session("api", group: "ops", manual: "Ops")], groups: [ops])
        XCTAssertEqual(placed.firstGroup.map(\.name), ["api"], "dch's group places it")
    }

    /// New group… from a row: dch's config holds the new group's line when --group-set launches. The probe on `queue`
    /// is slow, so a launch that did not wait for the write would read the file before the line lands. A plain move
    /// writes nothing first (the debounce's timer is held here and never fires).
    @MainActor
    func testNewGroupFromARowWritesDchsConfigBeforeTheGroupSet() {
        useGroups([work, ops])
        let file = tempDir("groupConfigFirst").appendingPathComponent("config").path
        let s = session("api", group: ""), rec = Launches(), st = store([s]), c = controller(st, rec)
        rec.configPath = file
        let v = Self.v196
        c.controlDch = { Thread.sleep(forTimeInterval: 0.3); return v }
        c.dchConfigPath = { file }
        c.autoAllowOn = { false }
        c.after = { _, _ in }
        rec.output = #"{"name":"api","group":"Ops","result":"ok"}"# + "\n"
        XCTAssertTrue(c.setGroup(s, group: "Work"))
        settle(c) { rec.args.count == 1 && !c.runner.isBusy(s.key) }
        XCTAssertEqual(rec.lock.withLock { rec.configs }, [""], "a plain move: no write first")
        XCTAssertTrue(c.setGroup(s, group: "Ops", configFirst: true))
        settle(c) { rec.args.count == 2 && !c.runner.isBusy(s.key) }
        XCTAssertEqual(rec.args.last, ["--group-set", "api", "Ops", "--json"])
        XCTAssertEqual(rec.lock.withLock { rec.configs }.last,
                       "auto_allow = false\nsidekick_pattern = zzz\ngroup = Work = zzz\ngroup = Ops =\ngroup_color = Work = #2563EB\ngroup_color = Ops = #15803D\n",
                       "written before the launch")
    }

    /// The New group… field stands the window's key chords down as a rename field does, and only while it is up.
    @MainActor
    func testTheNewGroupFieldStandsTheKeyChordsDown() {
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        let k = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0,
                                 context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        func route() -> AgentsNSWindow.KeyRoute {
            AgentsNSWindow.route(k, responder: .text, sidebarFocused: false, terminalMode: false, renaming: m.typingName)
        }
        XCTAssertFalse(m.typingName)
        XCTAssertNotEqual(route(), .pass, "no field: Option-Command-1 is the window's")
        m.runSidebar(.newGroup)
        XCTAssertTrue(m.typingName, "the field is up")
        XCTAssertEqual(route(), .pass, "the field keeps the chord")
        m.answerNewGroup(false)
        XCTAssertFalse(m.typingName, "Cancel: the chords are back")
    }

    /// The name is trimmed before it is checked: " Work" beside Work and a blank name are refused; " Ops " is stored as Ops.
    func testNewGroupTrimsTheNameBeforeItIsChecked() {
        XCTAssertEqual(AgentWindowControls.addingGroup(" Work", to: [work]), .failure(.init(reason: "Another group has this name")))
        XCTAssertEqual(AgentWindowControls.addingGroup("  ", to: [work]), .failure(.init(reason: "A name is 1-32 bytes, without \"=\"")))
        guard case .success(let list) = AgentWindowControls.addingGroup(" Ops ", to: [work]) else { return XCTFail("added") }
        XCTAssertEqual(list.last?.name, "Ops")
    }

    // MARK: - Round 3: the field takes the keys, flag-like group names, Group tabs off, a manual group on an older dch

    /// Stands in for the terminal: counts the keys it is handed.
    final class KeyRecorder: NSView {
        var downs = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { downs += 1 }
    }

    @MainActor
    func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(fields) }

    /// F1: New group… (the sidebar's and a row's) puts the field up with the keys: a typed key reaches the field, never
    /// the terminal; Escape and Create give the keys back to the terminal. A window of the window's own class, never shown.
    @MainActor
    func testTheNewGroupFieldTakesTheKeysAndGivesThemBack() throws {
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        var stored = [work], moves: [(String, String?)] = []
        m.storedGroups = { stored }
        m.saveGroups = { stored = $0 }
        m.setGroup = { s, g, _ in moves.append((s.name, g)) }
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        defer { win.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let terminal = KeyRecorder(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let host = NSHostingView(rootView: AgentNewGroupStrip(model: m))
        host.frame = CGRect(x: 0, y: 20, width: 320, height: 180)
        root.addSubview(terminal)
        root.addSubview(host)
        win.contentView = root
        XCTAssertTrue(win.makeFirstResponder(terminal), "premise: the terminal has the keys")
        func key(_ code: UInt16, _ chars: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        func spin() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))   // SwiftUI's update and the field's focus hop
        }
        func open(_ ask: () -> Void) throws -> NSTextView {
            ask()
            spin()
            let f = try XCTUnwrap(fields(host).first { $0.placeholderString == "Group name" }, "the field is up")
            let editor = try XCTUnwrap(f.currentEditor() as? NSTextView, "the field is editing")
            XCTAssertTrue(win.firstResponder === editor, "the field has the keys")
            return editor
        }
        var editor = try open { m.runSidebar(.newGroup) }
        win.sendEvent(key(31, "o"))
        XCTAssertEqual(editor.string, "o", "typing lands in the field")
        XCTAssertEqual(m.newGroup?.name, "o")
        XCTAssertEqual(terminal.downs, 0, "never in the terminal")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(m.newGroup == nil, "Escape cancels")
        XCTAssertTrue(win.firstResponder === terminal, "Escape gives the keys back")
        spin()
        XCTAssertTrue(fields(host).isEmpty, "the field is gone")
        editor = try open { m.runMove(.newGroup, session("api", group: "")) }
        for (code, c) in [(UInt16(31), "O"), (35, "p"), (1, "s")] { win.sendEvent(key(code, c)) }
        XCTAssertEqual(editor.string, "Ops")
        XCTAssertEqual(terminal.downs, 0, "never in the terminal")
        m.answerNewGroup(true)
        XCTAssertEqual(stored.map(\.name), ["Work", "Ops"])
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.last?.1, "Ops", "the row moves into the group typed in the field")
        XCTAssertTrue(win.firstResponder === terminal, "Create gives the keys back")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// F2: a name dch would read as a flag ("--auto" would be Automatic) is refused by New group… and never sent: the
    /// args are nil and nothing launches.
    @MainActor
    func testAGroupNameDchWouldReadAsAFlagIsRefusedAndNeverSent() {
        for bad in ["-x", "--auto", " -x"] {
            XCTAssertEqual(AgentWindowControls.addingGroup(bad, to: [work]), .failure(.init(reason: AgentIsland.dashNameText)), bad)
        }
        XCTAssertTrue(AgentIsland.groupSetArgs("api", "-x") == nil)
        XCTAssertTrue(AgentIsland.groupSetArgs("api", "--auto") == nil)
        XCTAssertEqual(AgentIsland.groupSetArgs("api", "x-1"), ["--group-set", "api", "x-1", "--json"])
        XCTAssertEqual(AgentIsland.groupSetArgs("api", nil), ["--group-set", "api", "--auto", "--json"])
        let s = session("api", group: ""), rec = Launches(), c = controller(store([s]), rec)
        XCTAssertFalse(c.setGroup(s, group: "-x"), "nothing runs")
        c.queue.sync {}
        XCTAssertTrue(rec.args.isEmpty)
    }

    /// n2: with Group tabs off dch is given no groups, so New group… is off in both menus with the reason; on again, back.
    @MainActor
    func testNewGroupIsOffWhileGroupTabsAreOff() {
        useGroups([work])
        Preferences.agentIslandSidekickTabs = false
        let s = session("api", group: ""), st = store([s]), c = controller(st, Launches())
        c.rowDetailsChanged()
        let off = AgentSidebarMenuEntry.item(AgentIsland.groupTabsOffText, enabled: false, checked: nil, verb: .newGroup)
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(s, store: st)).last, off)
        XCTAssertEqual(AgentWindowControls.sidebarMenu(store: st, autoAllow: false).dropFirst().first, off, "the sidebar's too")
        Preferences.agentIslandSidekickTabs = true
        c.rowDetailsChanged()
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(s, store: st)).last,
                       .item(AgentIsland.newGroupLabel, enabled: true, checked: nil, verb: .newGroup))
    }

    /// n3: no_group for a manual-only group (an older dch skips `group = <name> =`) names that cause; for a pattern group
    /// it stays "no longer exists". Only no_group changes.
    @MainActor
    func testNoGroupForAManualGroupSaysItNeedsANewerDch() {
        let s = session("api", group: ""), rec = Launches(), st = store([s]), c = controller(st, rec)
        st.sessionGroups = [work, ops]
        rec.status = 1
        rec.output = #"{"name":"api","group":null,"result":"failed","reason":"no_group"}"# + "\n"
        for (g, line) in [("ops", AgentIsland.manualNoGroupText), ("Work", AgentIsland.noGroupText)] {
            let n = rec.args.count
            XCTAssertTrue(c.setGroup(s, group: g))
            settle(c) { rec.args.count > n && !c.runner.isBusy(s.key) && st.actions[s.key] == line }
            XCTAssertEqual(st.actions[s.key], line, g)
        }
        XCTAssertEqual(AgentIsland.manualNoGroupText, "That group needs a newer dch (manual groups)")
        XCTAssertTrue(AgentIsland.isGroupSetFailure(AgentIsland.manualNoGroupText), "a move that works drops it")
        let gone = DchActionResult(status: 1, json: [DchJSONLine(name: "api", result: "failed", reason: "no_session")])
        XCTAssertEqual(AgentIsland.groupSetFailure(gone, manual: true), "That session is no longer running")
    }
}
