import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #897 (#829 spec G9): the Agent Sessions sidebar "..." menu, built as values from the island's gates, and the store's
/// own list-wide question drawn in the sidebar and answered through the island's confirm calls. Offscreen only: no menu
/// popped, no window shown, no Settings window, no real dch (the controller's runner is a recorder; nothing launches).
final class AgentWindowSidebarMenuTests: XCTestCase {
    static let now: TimeInterval = 1_800_000_000
    static let dir = "/tmp/dch-test"
    static let ellipsis = "\u{2026}"

    func bin(_ v: [Int]) -> DchCommand.Binary { DchCommand.Binary(path: "/fake/dch", version: v) }

    func session(_ name: String, version: String = "1.30.0") -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: Self.dir, name: name), alias: "", activity: Self.now - 60, state: .idle,
                     agents: 0, version: version)
    }

    /// An unpinned record that ended on a signal after an hour: Resume interrupted takes it, Clear unpinned too.
    func crashed(_ name: String) -> DchHistoryRecord {
        var r = DchHistoryRecord(key: AgentSessionKey(dir: Self.dir, name: name))
        r.cwd = "/Users/example/\(name)"
        r.started = Self.now - 3600
        r.ended = Self.now - 60
        r.updated = Self.now - 60
        r.end = "signal 9"
        return r
    }

    @MainActor
    func store(_ sessions: [AgentSession], history: [DchHistoryRecord] = [], dch: DchCommand.Binary?) -> AgentIslandStore {
        let s = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        s.now = { Self.now }
        s.controlDch = dch
        s.sessions = sessions
        s.history = history
        return s
    }

    /// Every dch argv the controller's runner was handed; nothing is launched.
    final class Launches: @unchecked Sendable {
        let lock = NSLock()
        var all: [[String]] = []
        var args: [[String]] { lock.withLock { all } }
    }

    /// A panel-less controller on `st` whose every outside read is a fake and whose runner records.
    @MainActor
    func controller(_ st: AgentIslandStore, _ rec: Launches) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        let dch = st.controlDch
        c.controlDch = { dch }   // a History re-read keeps the store's binary
        c.controlEnv = { ["DCH_SOCKET_DIR": $0] }
        c.readHistory = { _, _ in [] }
        c.historyDirs = { [Self.dir] }
        c.readLiveRecords = { _ in [] }
        c.seedDirs = { [] }
        c.listSessions = { _ in [] }
        c.chooseFolder = { _ in XCTFail("no chooser in these rows") }
        c.runner = DchActionRunner(bound: 60, launch: { _, args, _, _, onPid, _ in
            rec.lock.withLock { rec.all.append(args) }
            onPid(4242)
            return (0, Data())
        }, signal: { _ in })
        c.store = st
        return c
    }

    /// A window model on `st` whose island is `c` and whose Settings opener records.
    @MainActor
    func model(_ st: AgentIslandStore, _ c: AgentIslandController, settings: @escaping () -> Void = {}) -> AgentWindowModel {
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.now = { Self.now }
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        m.openSession = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.island = { c }
        m.openIslandSettings = settings
        m.bind(st)
        return m
    }

    @MainActor
    func settle(_ until: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !until() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func titles(_ es: [AgentSidebarMenuEntry]) -> [String] {
        es.map {
            switch $0 {
            case .item(let t, _, _, _), .submenu(let t, _, _): t
            case .divider: "-"
            case .note(let t): "note: " + t
            }
        }
    }

    func enabled(_ es: [AgentSidebarMenuEntry]) -> [Bool] {
        es.compactMap {
            switch $0 {
            case .item(_, let on, _, _), .submenu(_, let on, _): on
            case .divider, .note: nil
            }
        }
    }

    func entry(_ es: [AgentSidebarMenuEntry], _ title: String) -> AgentSidebarMenuEntry? {
        es.first { if case .item(let t, _, _, _) = $0 { t == title } else if case .submenu(let t, _, _) = $0 { t == title } else { false } }
    }

    // MARK: The item list and its order

    /// G9's order with every gate open: New session > (recent, -, Choose folder...), New group... (#2062), -, the four list-wide verbs that
    /// ask (an ellipsis each), -, Resume interrupted (n), its no-message twin, Clear unpinned..., -, Sort >, Row
    /// details >, Always allow (checked as the setting), Agent Island Settings....
    @MainActor
    func testSidebarMenuListsTheG9ItemsInTheSpecsOrder() throws {
        let st = store([session("api"), session("api-qa")], history: [crashed("old")], dch: bin([1, 38, 0]))
        XCTAssertEqual(st.resumeAllButton, AgentIsland.resumeAllLabel(1), "precondition: one record to resume")
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: true)
        XCTAssertEqual(titles(e), [
            AgentIsland.newSessionLabel, AgentIsland.newGroupLabel, "-",
            "Restart stale agents" + Self.ellipsis, "Restart all agents (force)" + Self.ellipsis,
            AgentIsland.stopAllGlobalLabel, AgentIsland.killAllGlobalLabel, "-",
            "Resume interrupted (1)", "Resume interrupted (1) without the message", "Clear unpinned" + Self.ellipsis, "-",
            "Sort", "Row details", "Always allow permission prompts", "Agent Island Settings" + Self.ellipsis,
            "Diagnostics" + Self.ellipsis,
        ])
        XCTAssertEqual(Set(enabled(e)), [true], "all on with every gate open")
        guard case .submenu(_, _, let new)? = e.first else { return XCTFail("New session is a submenu") }
        XCTAssertEqual(new.last, .item(AgentIsland.chooseFolderLabel, enabled: true, checked: nil, verb: .chooseFolder))
        XCTAssertEqual(new.count, st.controlsMenu.recent.isEmpty ? 1 : st.controlsMenu.recent.count + 2,
                       "the island's recent folders, a divider, then Choose folder...")
        XCTAssertEqual(entry(e, AgentIsland.killAllGlobalLabel), .item(AgentIsland.killAllGlobalLabel, enabled: true, checked: nil, verb: .killAll))
        XCTAssertEqual(entry(e, AgentIsland.stopAllGlobalLabel), .item(AgentIsland.stopAllGlobalLabel, enabled: true, checked: nil, verb: .stopAll))
        XCTAssertEqual(entry(e, "Always allow permission prompts"),
                       .item("Always allow permission prompts", enabled: true, checked: true, verb: .autoAllow))
        XCTAssertEqual(entry(AgentWindowControls.sidebarMenu(store: st, autoAllow: false), "Always allow permission prompts"),
                       .item("Always allow permission prompts", enabled: true, checked: false, verb: .autoAllow))
        st.sort = .name
        st.details = AgentIslandRowDetails(agents: true, openPRs: false, merged: true)
        let again = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        XCTAssertEqual(entry(again, "Sort"), .submenu("Sort", enabled: true, [
            .item("Last activity", enabled: true, checked: false, verb: .sort(.activity)),
            .item("Name", enabled: true, checked: true, verb: .sort(.name)),
        ]))
        // #1455: every part of a session row, in drawn order, the Settings section's list (AgentRowDetailsTests).
        XCTAssertEqual(entry(again, "Row details"), .submenu("Row details", enabled: true, [
            .item("Model", enabled: true, checked: true, verb: .rowDetail(\.model)),
            .item("Effort", enabled: true, checked: true, verb: .rowDetail(\.effort)),
            .item("State", enabled: true, checked: true, verb: .rowDetail(\.state)),
            .item("Agents", enabled: true, checked: true, verb: .rowDetail(\.agents)),
            .item("Shells", enabled: true, checked: true, verb: .rowDetail(\.shells)),   // #1583
            .item("Merged", enabled: true, checked: true, verb: .rowDetail(\.merged)),
            .item("Open PRs", enabled: true, checked: false, verb: .rowDetail(\.openPRs)),
            .item("Age", enabled: true, checked: true, verb: .rowDetail(\.age)),
            .item("Shortcut", enabled: true, checked: true, verb: .rowDetail(\.shortcut)),
        ]))
    }

    // MARK: Enablement, one row per island gate

    /// The base gate (no control dch): every list-wide item off with the island's title, New session off, Resume and
    /// Clear absent (their buttons are), and the island's "Controls <why>" note last. Settings items stay on, and so does
    /// New group… (#2062: it only stores a group in Prosper's list, no dch call; the config write follows when a dch is found).
    @MainActor
    func testSidebarMenuBaseGateRefusedTurnsTheListWideItemsOff() throws {
        let st = store([session("api")], history: [crashed("old")], dch: nil)
        let why = try XCTUnwrap(st.resumeGate.refusal)
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        XCTAssertEqual(titles(e), [
            AgentIsland.newSessionLabel, AgentIsland.newGroupLabel, "-", "Restart stale agents", "Restart all agents (force)",
            AgentIsland.stopAllGlobalLabel, AgentIsland.killAllGlobalLabel, "-",
            "Sort", "Row details", "Always allow permission prompts", "Agent Island Settings" + Self.ellipsis,
            "Diagnostics" + Self.ellipsis, "-", "note: Controls \(why)",
        ])
        XCTAssertEqual(enabled(e), [false, true, false, false, false, false, true, true, true, true, true])
    }

    /// The restart gate (a 1.24.0 control dch): Restart and Stop all off, naming the version; Kill all needs only the
    /// base gate (the island's #744 rule).
    @MainActor
    func testSidebarMenuRestartGateNamesTheVersionAndLeavesKillOn() throws {
        let st = store([session("api", version: "1.24.0")], dch: bin([1, 24, 0]))
        XCTAssertEqual(st.restartNeeds, "needs dch 1.24.1")
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        XCTAssertEqual(Array(titles(e).prefix(7)), [
            AgentIsland.newSessionLabel, AgentIsland.newGroupLabel, "-", "Restart stale agents (needs dch 1.24.1)",
            "Restart all agents (force) (needs dch 1.24.1)", "Stop all\(Self.ellipsis) (needs dch 1.24.1)",
            AgentIsland.killAllGlobalLabel,
        ])
        XCTAssertEqual(Array(enabled(e).prefix(6)), [true, true, false, false, false, true])
    }

    /// No live session: Restart, Stop all and Kill all off (nothing to act on); New session on.
    @MainActor
    func testSidebarMenuWithNothingLiveTurnsStopKillAndRestartOff() throws {
        let st = store([], dch: bin([1, 38, 0]))
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        XCTAssertEqual(Array(titles(e).prefix(7)), [
            AgentIsland.newSessionLabel, AgentIsland.newGroupLabel, "-", "Restart stale agents", "Restart all agents (force)",
            AgentIsland.stopAllGlobalLabel, AgentIsland.killAllGlobalLabel,
        ])
        XCTAssertEqual(Array(enabled(e).prefix(6)), [true, true, false, false, false, false])
        let island = AgentIslandController.controlGates(st)
        XCTAssertFalse(island.stop(global: true) || island.kill(global: true) || island.restart, "the island's own rule")
    }

    /// The History gates: Clear unpinned needs 1.25.0 (historyEditGate), Resume interrupted's no-message twin 1.27.0
    /// (reviveNoMessageGate); below them the items are absent, as the island's History header buttons are.
    @MainActor
    func testSidebarMenuHistoryItemsFollowTheirGates() throws {
        let st = store([session("api", version: "1.24.1")], history: [crashed("old")], dch: bin([1, 24, 1]))
        XCTAssertEqual(titles(AgentWindowControls.sidebarMenu(store: st, autoAllow: false)).filter { $0.hasPrefix("Resume") || $0.hasPrefix("Clear") },
                       ["Resume interrupted (1)"], "1.24.1: Resume only")
        st.controlDch = bin([1, 26, 0])
        st.sessions = [session("api", version: "1.26.0")]
        XCTAssertEqual(titles(AgentWindowControls.sidebarMenu(store: st, autoAllow: false)).filter { $0.hasPrefix("Resume") || $0.hasPrefix("Clear") },
                       ["Resume interrupted (1)", "Clear unpinned" + Self.ellipsis], "1.26.0: Clear unpinned too")
        st.controlDch = bin([1, 38, 0])
        st.sessions = [session("api")]
        XCTAssertEqual(titles(AgentWindowControls.sidebarMenu(store: st, autoAllow: false)).filter { $0.hasPrefix("Resume") || $0.hasPrefix("Clear") },
                       ["Resume interrupted (1)", "Resume interrupted (1) without the message", "Clear unpinned" + Self.ellipsis])
    }

    // MARK: Asking: never acts before the answer

    /// Kill all asks the store's question and runs nothing; Cancel runs nothing; Kill runs dch -k per asked row.
    @MainActor
    func testSidebarKillAllAsksAndNeverActsBeforeTheAnswer() throws {
        let st = store([session("api"), session("api-qa")], dch: bin([1, 38, 0]))
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        m.runSidebar(.killAll)
        XCTAssertTrue(st.confirmingKillAll, "asks")
        let q = try XCTUnwrap(AgentWindowControls.storeQuestion(st))
        XCTAssertEqual(q.kind, .killAll)
        XCTAssertEqual(q.text, st.killAllQuestion)
        XCTAssertEqual(q.action, "End")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(rec.args.count, 0, "nothing runs before the answer")
        m.answerStoreQuestion(false)
        XCTAssertFalse(st.confirmingKillAll)
        XCTAssertTrue(AgentWindowControls.storeQuestion(st) == nil, "the strip goes")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(rec.args.count, 0, "Cancel runs nothing")
        m.runSidebar(.killAll)
        m.answerStoreQuestion(true)
        settle { rec.args.count >= 2 }
        XCTAssertEqual(Set(rec.args), Set([AgentIsland.killArgs("api"), AgentIsland.killArgs("api-qa")].compactMap { $0 }),
                       "Kill: the island's dch -k per asked row")
    }

    /// Restart all (both), Stop all and Clear unpinned only ask too: the store's flag is up, nothing runs.
    @MainActor
    func testSidebarListWideVerbsOnlyAsk() throws {
        let st = store([session("api")], history: [crashed("old")], dch: bin([1, 38, 0]))
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        m.runSidebar(.restartAll(force: false))
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text, AgentIsland.restartAllQuestion)
        m.runSidebar(.restartAll(force: true))
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text, AgentIsland.restartAllForceQuestion)
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.action, "Restart")
        m.runSidebar(.stopAll)
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.kind, .stopAll)
        XCTAssertFalse(st.confirmingRestartAll, "one question at a time (store.dropQuestions)")
        m.runSidebar(.clearUnpinned)
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text, AgentIsland.clearQuestion(1))
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.action, "Clear")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(rec.args.count, 0, "asking runs nothing")
        m.answerStoreQuestion(false)
        XCTAssertFalse(st.confirmingClear)
        XCTAssertEqual(rec.args.count, 0)
    }

    // MARK: The question strip answers through the store

    /// R-2: the island's own question (asked on the island) is the strip's; the window's answer reaches the island's
    /// confirm call (Stop runs dch --stop on the asked rows), and the question is gone on both.
    @MainActor
    func testSidebarQuestionStripAnswersTheIslandsQuestionThroughTheStore() throws {
        let st = store([session("api")], dch: bin([1, 38, 0]))
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        c.askStopAll(global: true)
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text, st.stopAllQuestion, "the island's question, its words")
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.action, "Stop")
        let strip = NSHostingView(rootView: AgentStoreQuestionStrip(store: st) { m.answerStoreQuestion($0) }.frame(width: 260))
        XCTAssertGreaterThan(strip.fittingSize.height, 0, "drawn while asked")
        m.answerStoreQuestion(true)
        XCTAssertFalse(st.confirmingStopAll, "answered on the store")
        settle { !rec.args.isEmpty }
        XCTAssertEqual(rec.args.last, AgentIsland.stopArgs(["api"]))
        XCTAssertTrue(AgentWindowControls.storeQuestion(st) == nil)
        m.answerStoreQuestion(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(rec.args.count, 1, "no question up: an answer runs nothing")
    }

    // MARK: Always allow asks first (R897-q1), Kill all asks in its title (R897-n1)

    /// ON from the menu raises the strip and writes nothing; Cancel writes nothing; Turn on writes it. The setting is
    /// the XCTest scratch defaults (Preferences.defaults), restored after; dch's config path is nil under XCTest.
    @MainActor
    func testSidebarAlwaysAllowOnAsksFirstAndWritesOnlyOnTurnOn() throws {
        let k = "agentIslandAutoAllow", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        Preferences.agentIslandAutoAllow = false
        let st = store([session("api")], dch: bin([1, 38, 0]))
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        XCTAssertEqual(NSHostingView(rootView: AgentAlwaysAllowStrip(model: m).frame(width: 260)).fittingSize.height, 0,
                       "no question before the item")
        m.runSidebar(.autoAllow)
        XCTAssertTrue(m.askingAlwaysAllow, "ON asks")
        XCTAssertFalse(Preferences.agentIslandAutoAllow, "nothing is written before the answer")
        XCTAssertEqual(AgentWindowControls.alwaysAllowQuestion,
                       "Always allow: Claude Code's permission prompts will be answered Yes, so commands run without your review.")
        XCTAssertEqual(AgentWindowControls.alwaysAllowAction, "Turn on")
        let strip = NSHostingView(rootView: AgentAlwaysAllowStrip(model: m).frame(width: 260))   // fresh: a hosted tree is not re-read
        XCTAssertGreaterThan(strip.fittingSize.height, 0, "the strip is drawn while asked")
        m.answerAlwaysAllow(false)
        XCTAssertFalse(m.askingAlwaysAllow)
        XCTAssertFalse(Preferences.agentIslandAutoAllow, "Cancel writes nothing")
        m.answerAlwaysAllow(true)
        XCTAssertFalse(Preferences.agentIslandAutoAllow, "an answer with no question up writes nothing")
        m.runSidebar(.autoAllow)
        m.answerAlwaysAllow(true)
        XCTAssertTrue(Preferences.agentIslandAutoAllow, "Turn on writes it")
        XCTAssertFalse(m.askingAlwaysAllow)
        XCTAssertEqual(rec.args.count, 0, "no dch run")
    }

    /// OFF stays immediate: no question, the setting is off at once.
    @MainActor
    func testSidebarAlwaysAllowOffWritesAtOnce() throws {
        let k = "agentIslandAutoAllow", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        Preferences.agentIslandAutoAllow = true
        let st = store([session("api")], dch: bin([1, 38, 0]))
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        m.runSidebar(.autoAllow)
        XCTAssertFalse(m.askingAlwaysAllow, "OFF does not ask")
        XCTAssertFalse(Preferences.agentIslandAutoAllow, "OFF writes at once")
    }

    /// R897-n1: Kill all asks, so the item reads "End all..." (a literal, on and off), as the island's does.
    @MainActor
    func testSidebarKillAllTitleHasTheEllipsis() throws {
        for dch in [bin([1, 38, 0]), nil] {
            let st = store([session("api")], dch: dch)
            let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
            XCTAssertTrue(titles(e).contains("End all\u{2026}"), "titles: \(titles(e))")
            XCTAssertEqual(entry(e, "End all\u{2026}"),
                           .item("End all\u{2026}", enabled: dch != nil, checked: nil, verb: .killAll))
        }
    }

    // MARK: Settings

    /// "Agent Island Settings...": the model's opener seam, once; nothing asked, nothing run.
    @MainActor
    func testSidebarSettingsItemOpensThePaneThroughTheSeam() throws {
        let st = store([session("api")], dch: bin([1, 38, 0]))
        let rec = Launches(), c = controller(st, rec)
        var opened = 0
        let m = model(st, c) { opened += 1 }
        defer { m.close() }
        m.runSidebar(.settings)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(AgentWindowControls.storeQuestion(st) == nil)
        XCTAssertEqual(rec.args.count, 0)
        XCTAssertEqual(AgentWindowControls.islandExtensionID, "com.prosper.agentisland")
        XCTAssertEqual(AgentWindowControls.islandSectionID, "agentisland")
    }

    // MARK: #1466: an equal publish leaves the menu alone

    /// #1540: the sidebar "..." is a StableMenu; how many times its Menu body ran.
    @MainActor var menuBodies: Int { StableMenuProbe.bodies[AgentSidebarMenuButton.menuID, default: 0] }

    /// Counts its own body: a store publish reached the hosted tree when this moves.
    struct PublishProbe: View {
        @ObservedObject var store: AgentIslandStore
        @MainActor static var bodies = 0
        var body: some View {
            let _ = Self.bodies += 1
            AgentSidebarMenuButton(store: store) { _ in }
        }
    }

    /// The poll publishes about every second with nothing the "..." shows changed (F5 in the report): the menu's body
    /// must not run again then (a re-run rebuilds the open menu and closes an open submenu such as Row details), and
    /// must run once a gate or a checked item changes. Offscreen: a hosted tree, no window, no menu popped.
    @MainActor
    func testSidebarMenuIsNotRebuiltOnAnEqualPublishButIsOnAChange() throws {
        let st = store([session("api"), session("api-qa")], dch: bin([1, 38, 0]))
        let host = NSHostingView(rootView: PublishProbe(store: st).frame(width: 40, height: 40))
        func pump(_ moved: () -> Bool) {
            settle { host.layoutSubtreeIfNeeded(); _ = host.fittingSize; return moved() }
        }
        pump { menuBodies > 0 }
        let probe0 = PublishProbe.bodies, menu0 = menuBodies
        XCTAssertGreaterThan(menu0, 0, "precondition: the menu is drawn")
        let before = AgentWindowControls.sidebarMenu(store: st, autoAllow: Preferences.agentIslandAutoAllow)
        for _ in 0..<2 {   // two poll ticks whose menu content is equal
            let probe = PublishProbe.bodies
            st.sessions = st.sessions
            st.notices = st.notices
            pump { PublishProbe.bodies > probe }
            XCTAssertGreaterThan(PublishProbe.bodies, probe, "precondition: the publish reached the hosted tree")
        }
        XCTAssertEqual(AgentWindowControls.sidebarMenu(store: st, autoAllow: Preferences.agentIslandAutoAllow), before,
                       "precondition: the entries are equal")
        XCTAssertEqual(menuBodies, menu0,
                       "equal publishes: the menu is not rebuilt (probe ran \(PublishProbe.bodies - probe0) times)")
        st.details.agents.toggle()   // a checked Row details item changes
        pump { menuBodies > menu0 }
        XCTAssertEqual(menuBodies, menu0 + 1, "a changed entry rebuilds the menu once")
        st.controlDch = nil   // the base gate turns off: every list-wide item goes off
        pump { menuBodies > menu0 + 1 }
        XCTAssertEqual(menuBodies, menu0 + 2, "a changed gate rebuilds the menu once")
    }

    // MARK: #2104: a row's right-click menu (Model, Effort, Move to group) is not rebuilt by an equal publish

    /// The row's parent: observes the store (as the window does) and draws the store's first session's row with its menu.
    struct RowMenuProbe: View {
        @ObservedObject var store: AgentIslandStore
        let model: AgentWindowModel
        @MainActor static var bodies = 0
        var body: some View {
            let _ = Self.bodies += 1
            if let s = store.sessions.first {
                Text(s.name).modifier(AgentRowMenu(store: store, row: AgentSidebar.row(s, details: store.details, now: 0),
                                                   model: model, open: { _ in }))
            }
        }
    }

    @MainActor var rowMenuBodies: Int { StableMenuProbe.bodies[AgentRowMenu.menuID, default: 0] }

    /// The operator's 3rd report (#2104): a live row's right-click menu and its Move to group submenu hid and showed
    /// again about every second: the items observed the store inside the `.contextMenu`, so each poll publish re-declared
    /// them. Equal publishes must leave the menu alone; a changed effort (the Effort check) or a changed group (the Move
    /// to group check) rebuilds it once. Offscreen: a hosted tree, no window, no menu popped.
    @MainActor
    func testSidebarRowMenuIsNotRebuiltOnAnEqualPublishButIsOnAChange() throws {
        var s0 = session("api")
        s0.group = ""   // dch 1.196's group key: Move to group is listed
        let st = store([s0, session("api-qa")], dch: bin([1, 196, 0]))
        st.sessionGroups = [SessionGroup(id: "w1", name: "Work", pattern: "zzz")]
        let m = model(st, controller(st, Launches()))
        let host = NSHostingView(rootView: RowMenuProbe(store: st, model: m).frame(width: 40, height: 40))
        func pump(_ moved: () -> Bool) {
            settle { host.layoutSubtreeIfNeeded(); _ = host.fittingSize; return moved() }
        }
        func snap() -> AgentRowMenu.Snapshot? {
            st.sessions.first.map { AgentRowMenu.snapshot(AgentSidebar.row($0, details: st.details, now: 0), store: st, model: m) }
        }
        pump { rowMenuBodies > 0 }
        let menu0 = rowMenuBodies
        XCTAssertGreaterThan(menu0, 0, "precondition: the menu is drawn")
        XCTAssertEqual(snap()?.switches.map(\.title), [AgentModelSwitch.modelLabel, AgentModelSwitch.effortLabel],
                       "precondition: the menu holds Model and Effort")
        XCTAssertEqual(snap()?.move.count, 1, "precondition: the menu holds Move to group")
        let before = snap()
        for _ in 0..<3 {   // three poll ticks whose menu content is equal
            let probe = RowMenuProbe.bodies
            st.sessions = st.sessions
            st.notices = st.notices
            pump { RowMenuProbe.bodies > probe }
            XCTAssertGreaterThan(RowMenuProbe.bodies, probe, "precondition: the publish reached the hosted tree")
        }
        XCTAssertTrue(snap() == before, "precondition: the snapshot is equal")
        XCTAssertEqual(rowMenuBodies, menu0, "equal publishes: the row menu is not rebuilt")
        var s1 = try XCTUnwrap(st.sessions.first)
        s1.effort = s1.effort == "high" ? "low" : "high"   // the Effort submenu's checked item moves
        st.sessions = [s1] + st.sessions.dropFirst()
        pump { rowMenuBodies > menu0 }
        XCTAssertEqual(rowMenuBodies, menu0 + 1, "a changed effort rebuilds the menu once")
        s1.groupManual = "Work"   // Move to group's checked item moves
        st.sessions = [s1] + st.sessions.dropFirst()
        pump { rowMenuBodies > menu0 + 1 }
        XCTAssertEqual(rowMenuBodies, menu0 + 2, "a changed group rebuilds the menu once")
    }

    // MARK: #1540: the pane header "..." (Model and Effort submenus) is not rebuilt by an equal publish

    /// The header's parent: observes the store (as the window does) and hands the "⋯" the store's first session.
    struct HeaderProbe: View {
        @ObservedObject var store: AgentIslandStore
        @MainActor static var bodies = 0
        var body: some View {
            let _ = Self.bodies += 1
            if let s = store.sessions.first { AgentSessionMenuButton(store: store, session: s, ask: { _ in }) }
        }
    }

    @MainActor var headerBodies: Int { StableMenuProbe.bodies[AgentSessionMenuButton.menuID, default: 0] }

    /// The operator's report (#1540): the pane header's Model submenu closed about a second after it opened, Effort
    /// too: each store publish rebuilt the menu. Equal publishes must leave its body alone; a changed effort (the
    /// Effort submenu's check) or a changed gate rebuilds it once. Offscreen: a hosted tree, no window, no menu popped.
    @MainActor
    func testPaneHeaderMenuIsNotRebuiltOnAnEqualPublishButIsOnAChange() throws {
        let st = store([session("api"), session("api-qa")], dch: bin([1, 38, 0]))
        let host = NSHostingView(rootView: HeaderProbe(store: st).frame(width: 40, height: 40))
        func pump(_ moved: () -> Bool) {
            settle { host.layoutSubtreeIfNeeded(); _ = host.fittingSize; return moved() }
        }
        func snap() -> AgentSessionMenuButton.Snapshot? {
            st.sessions.first.map { AgentSessionMenuButton.snapshot($0, store: st, ended: false, panes: []) }
        }
        pump { headerBodies > 0 }
        let menu0 = headerBodies
        XCTAssertGreaterThan(menu0, 0, "precondition: the menu is drawn")
        let s0 = try XCTUnwrap(st.sessions.first)
        XCTAssertEqual(snap()?.switches.map(\.title), [AgentModelSwitch.modelLabel, AgentModelSwitch.effortLabel],
                       "precondition: the menu holds the Model and Effort submenus")
        for _ in 0..<3 {   // three poll ticks whose menu content is equal
            let probe = HeaderProbe.bodies
            st.sessions = st.sessions
            st.notices = st.notices
            pump { HeaderProbe.bodies > probe }
            XCTAssertGreaterThan(HeaderProbe.bodies, probe, "precondition: the publish reached the hosted tree")
        }
        XCTAssertEqual(headerBodies, menu0, "equal publishes: the pane header menu is not rebuilt")
        var s1 = s0
        s1.effort = s0.effort == "high" ? "low" : "high"   // the Effort submenu's checked item moves
        st.sessions = [s1] + st.sessions.dropFirst()
        pump { headerBodies > menu0 }
        XCTAssertEqual(headerBodies, menu0 + 1, "a changed effort rebuilds the menu once")
        let gated = snap()
        st.controlDch = nil   // the base gate turns off: the session items go off
        XCTAssertTrue(snap() != gated, "precondition: the gate changes the entries")
        pump { headerBodies > menu0 + 1 }
        XCTAssertEqual(headerBodies, menu0 + 2, "a changed gate rebuilds the menu once")
    }

    // MARK: #2060: a group header's "\u{22EF}"

    /// Two groups and ungrouped rows, every one idle (none in Needs you) and stoppable.
    @MainActor
    func groupedStore() -> AgentIslandStore {
        let st = store([session("api"), session("web"), session("api-qa"), session("web-qa"), session("doc-a")], dch: bin([1, 38, 0]))
        st.sessionGroups = [SessionGroup(id: "qa", name: "QA", pattern: "-qa$"), SessionGroup(id: "docs", name: "Docs", pattern: "^doc"),
                            SessionGroup(id: "none", name: "Empty", pattern: "^zzz")]
        return st
    }

    /// The rows the sidebar draws under `id`'s header, as its "\u{22EF}" gets them.
    @MainActor
    func groupRows(_ st: AgentIslandStore, _ id: String) throws -> [AgentSession] {
        let sections = AgentSidebar.sections(sessions: st.sessions, history: st.history, sort: .name, groups: st.sessionGroups,
                                             details: .all, now: Self.now)
        let section = try XCTUnwrap(sections.first { $0.id == AgentSidebar.groupFold(id) })
        return try XCTUnwrap(AgentSidebar.groupSessions(section))
    }

    /// Each item of the QA header's menu sends its verb for exactly QA's sessions: none of Docs', none of the ungrouped.
    @MainActor
    func testGroupMenuActsOnExactlyThatGroupsSessions() throws {
        let st = groupedStore()
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        let sections = AgentSidebar.sections(sessions: st.sessions, history: [], sort: .name, groups: st.sessionGroups,
                                             details: .all, now: Self.now)
        let main = try XCTUnwrap(sections.first { $0.id == "Sessions" })
        XCTAssertTrue(AgentSidebar.groupSessions(main) == nil, "no menu on Sessions")
        let qa = try groupRows(st, "qa")
        XCTAssertEqual(qa.map(\.name), ["api-qa", "web-qa"])
        func run(_ v: AgentSidebarVerb, calls: Int) -> [[String]] {
            rec.lock.withLock { rec.all = [] }
            m.runGroup(v, name: "QA", rows: qa)
            XCTAssertEqual(rec.args.count, 0, "asks first")
            m.answerStoreQuestion(true)
            settle { rec.args.count >= calls }
            settle { !c.runner.hasJob(AgentSessionKey(dir: Self.dir, name: "")) && qa.allSatisfy { !c.runner.hasJob($0.key) } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            return rec.args
        }
        let outside = ["api", "web", "doc-a", "--all"]
        let stop = run(.stopAll, calls: 1)
        XCTAssertEqual(stop.count, 1, "one --stop for the dir")
        XCTAssertEqual(Set(stop.flatMap { $0 }), ["--stop", "api-qa", "web-qa", "--json"])
        let kill = run(.killAll, calls: 2)
        XCTAssertEqual(Set(kill), Set([AgentIsland.killArgs("api-qa"), AgentIsland.killArgs("web-qa")].compactMap { $0 }))
        let stale = run(.restartAll(force: false), calls: 2)
        XCTAssertEqual(Set(stale), Set([["--restart", "api-qa", "--include-agents", "--json"],
                                        ["--restart", "web-qa", "--include-agents", "--json"]]), "by name, no -f, never --all")
        let force = run(.restartAll(force: true), calls: 2)
        XCTAssertEqual(Set(force), Set([AgentIsland.restartArgs("api-qa"), AgentIsland.restartArgs("web-qa")].compactMap { $0 }))
        for args in stop + kill + stale + force { XCTAssertTrue(Set(args).isDisjoint(with: outside), "outside QA: \(args)") }
    }

    /// The question names the group and its count; the window-wide one after it is the island's own again.
    @MainActor
    func testGroupMenuQuestionNamesTheGroupAndTheCount() throws {
        let st = groupedStore()
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        let qa = try groupRows(st, "qa"), docs = try groupRows(st, "docs")
        m.runGroup(.stopAll, name: "QA", rows: qa)
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text, "Stop 2 sessions in QA?")
        m.runGroup(.killAll, name: "Docs", rows: docs)
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text, "End 1 session in Docs? No pause message first.")
        m.runGroup(.restartAll(force: false), name: "QA", rows: qa)
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text, "Restart stale agents in 2 sessions in QA? Each pauses for up to minutes.")
        m.runGroup(.restartAll(force: true), name: "QA", rows: qa)
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text,
                       "Restart every agent, busy ones too, in 2 sessions in QA? Each pauses for up to minutes.")
        m.runSidebar(.restartAll(force: false))
        XCTAssertEqual(AgentWindowControls.storeQuestion(st)?.text, AgentIsland.restartAllQuestion, "the window-wide one is unscoped")
        m.answerStoreQuestion(false)
        XCTAssertEqual(rec.args.count, 0, "nothing ran")
    }

    /// An empty group draws no header, and its menu is empty (no menu, not disabled items).
    @MainActor
    func testEmptyGroupShowsNoMenu() throws {
        let st = groupedStore()
        let sections = AgentSidebar.sections(sessions: st.sessions, history: [], sort: .name, groups: st.sessionGroups,
                                             details: .all, now: Self.now)
        XCTAssertFalse(sections.contains { $0.id == AgentSidebar.groupFold("none") })
        XCTAssertEqual(AgentWindowControls.groupMenu(store: st, rows: []), [])
    }

    /// The items in order, pinned; each off by the window menu's rule over the group's rows.
    @MainActor
    func testGroupMenuItemsInOrder() throws {
        let st = groupedStore()
        let menu = AgentWindowControls.groupMenu(store: st, rows: try groupRows(st, "qa"))
        XCTAssertEqual(titles(menu), ["Restart stale agents" + Self.ellipsis, "Restart all agents (force)" + Self.ellipsis,
                                      "Stop all" + Self.ellipsis, "End all" + Self.ellipsis])
        let verbs = menu.compactMap { (e: AgentSidebarMenuEntry) -> AgentSidebarVerb? in
            if case .item(_, _, _, let v) = e { return v }
            return nil
        }
        XCTAssertEqual(verbs, [.restartAll(force: false), .restartAll(force: true), .stopAll, .killAll])
        XCTAssertEqual(enabled(menu), [true, true, true, true])
        st.sessions = [session("old-qa", version: "1.23.0")]
        XCTAssertEqual(enabled(AgentWindowControls.groupMenu(store: st, rows: try groupRows(st, "qa"))), [true, true, false, true],
                       "an old master cannot stop: Stop all is off, as in the window menu")
    }

    // MARK: #2061: a group's Colour ▸

    /// After the actions: Colour ▸ with the 8 palette names, the colour shown now checked, then Automatic, checked while no
    /// colour is picked; a pick moves both checks. Each item's verb carries its hex (Automatic: nil).
    @MainActor
    func testGroupMenuColourSubmenuTitlesAndChecks() throws {
        let st = groupedStore()
        st.groupColors = ["qa": SessionGroup.palette[0].hex, "docs": SessionGroup.palette[1].hex]
        let menu = AgentWindowControls.groupMenu(store: st, rows: try groupRows(st, "qa"), name: "QA")
        XCTAssertEqual(titles(menu).suffix(2), ["-", AgentWindowControls.colourLabel])
        XCTAssertEqual(menu.last?.symbol, AgentMenuSymbol.colour)
        guard case .submenu(_, true, let items)? = menu.last else { return XCTFail("no Colour submenu") }
        XCTAssertEqual(titles(items), SessionGroup.palette.map(\.name) + ["-", "Automatic"])
        func checks(_ es: [AgentSidebarMenuEntry]) -> [Bool?] {
            es.compactMap { if case .item(_, _, let c, _) = $0 { return c } else { return nil } }
        }
        XCTAssertEqual(checks(items), [true] + Array(repeating: false, count: 7) + [true])
        let verbs = items.compactMap { (e: AgentSidebarMenuEntry) -> AgentSidebarVerb? in
            if case .item(_, _, _, let v) = e { return v }
            return nil
        }
        XCTAssertEqual(verbs, SessionGroup.palette.map { .groupColor($0.hex) } + [.groupColor(nil)])
        st.sessionGroups[0].color = SessionGroup.palette[4].hex
        st.groupColors["qa"] = SessionGroup.palette[4].hex
        guard case .submenu(_, _, let picked)? = AgentWindowControls.groupMenu(store: st, rows: try groupRows(st, "qa"), name: "QA").last
        else { return XCTFail("no Colour submenu") }
        XCTAssertEqual(checks(picked), Array(repeating: false, count: 4) + [true] + Array(repeating: false, count: 3) + [false])
        XCTAssertEqual(titles(AgentWindowControls.groupMenu(store: st, rows: try groupRows(st, "qa"), name: "Nope")).last,
                       "End all" + Self.ellipsis, "no such group: no Colour")
    }

    /// The header's colour reaches the view: the store's colours (set before its groups) are the model's after the
    /// groups' publish, and AgentSidebar.groupColor gives the QA section its colour from them.
    @MainActor
    func testTheStoresGroupColoursReachTheSidebarOnAGroupsPublish() throws {
        let st = groupedStore()
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        m.setVisible(true)
        st.groupColors = ["qa": SessionGroup.palette[3].hex]
        st.sessionGroups = st.sessionGroups
        XCTAssertEqual(m.groupColors, ["qa": SessionGroup.palette[3].hex])
        let qa = try XCTUnwrap(m.sections.first { $0.id == AgentSidebar.groupFold("qa") })
        XCTAssertEqual(AgentSidebar.groupColor(qa, m.groupColors), Color(hex: SessionGroup.palette[3].hex))
    }

    /// A Colour item stores the pick on that group only, through the Settings save; Automatic stores nil; the same pick
    /// again saves nothing. Nothing runs.
    @MainActor
    func testColourItemSavesThePickOnItsGroup() throws {
        let st = groupedStore()
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        var stored = st.sessionGroups, saves = 0
        m.storedGroups = { stored }
        m.saveGroups = { stored = $0; saves += 1 }
        let qa = try groupRows(st, "qa")
        m.runGroup(.groupColor(SessionGroup.palette[2].hex), name: "QA", rows: qa)
        XCTAssertEqual(stored.map(\.color), [SessionGroup.palette[2].hex, nil, nil])
        m.runGroup(.groupColor(SessionGroup.palette[2].hex), name: "QA", rows: qa)
        XCTAssertEqual(saves, 1, "the same pick again: no save")
        m.runGroup(.groupColor(nil), name: "QA", rows: qa)
        XCTAssertEqual(stored.map(\.color), [nil, nil, nil])
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(rec.args.count, 0, "nothing ran")
    }

    // MARK: #2063: a group's New session here

    /// With dch 1.196.0 a stored group's menu has New session here… between the actions and Colour ▸, its verb naming the
    /// group; not for a name that is no stored group (Sessions), a blank Sidekicks (isOff), a flag-like name or an older dch.
    @MainActor
    func testGroupMenuNewSessionHereIsGatedAsTheFormsPicker() throws {
        let st = groupedStore()
        st.controlDch = bin([1, 196, 0])
        let rows = try groupRows(st, "qa")
        let menu = AgentWindowControls.groupMenu(store: st, rows: rows, name: "QA")
        XCTAssertEqual(titles(menu).suffix(3), ["-", AgentWindowControls.newSessionHereLabel, AgentWindowControls.colourLabel])
        let here = menu.dropLast().last
        XCTAssertEqual(here, .item(AgentWindowControls.newSessionHereLabel, enabled: true, checked: nil, verb: .newSessionInGroup("QA")))
        XCTAssertEqual(here?.symbol, AgentMenuSymbol.newSession)
        XCTAssertFalse(titles(AgentWindowControls.groupMenu(store: st, rows: rows, name: "Sessions")).contains(AgentWindowControls.newSessionHereLabel),
                       "not a stored group")
        st.sessionGroups[0] = SessionGroup(id: SessionGroup.sidekicksID, name: "QA", pattern: "")
        XCTAssertFalse(titles(AgentWindowControls.groupMenu(store: st, rows: rows, name: "QA")).contains(AgentWindowControls.newSessionHereLabel),
                       "a blank Sidekicks (isOff)")
        st.sessionGroups[0] = SessionGroup(id: "qa", name: "-qa", pattern: "-qa$")
        XCTAssertFalse(titles(AgentWindowControls.groupMenu(store: st, rows: rows, name: "-qa")).contains(AgentWindowControls.newSessionHereLabel),
                       "a name dch would read as a flag")
        st.sessionGroups[0] = SessionGroup(id: "qa", name: "QA", pattern: "-qa$")
        st.controlDch = bin([1, 195, 9])
        XCTAssertFalse(titles(AgentWindowControls.groupMenu(store: st, rows: rows, name: "QA")).contains(AgentWindowControls.newSessionHereLabel),
                       "an older dch")
    }

    /// New session here opens the form with that group chosen (not Automatic); on an open form it chooses the group.
    @MainActor
    func testNewSessionHereOpensTheFormWithTheGroupChosen() throws {
        let st = groupedStore()
        st.controlDch = bin([1, 196, 0])
        let rec = Launches(), c = controller(st, rec), m = model(st, c)
        defer { m.close() }
        let rows = try groupRows(st, "qa")
        m.runGroup(.newSessionInGroup("QA"), name: "QA", rows: rows)
        XCTAssertEqual(m.newSession?.group, "QA")
        XCTAssertEqual(m.newSessionGroups.map(\.name), ["QA", "Docs", "Empty"])
        m.runGroup(.newSessionInGroup("Docs"), name: "Docs", rows: rows)
        XCTAssertEqual(m.newSession?.group, "Docs")
        XCTAssertEqual(rec.args.count, 0, "nothing ran")
    }
}
