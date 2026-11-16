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

    /// G9's order with every gate open: New session > (recent, -, Choose folder...), -, the four list-wide verbs that
    /// ask (an ellipsis each), -, Resume interrupted (n), its no-message twin, Clear unpinned..., -, Sort >, Row
    /// details >, Always allow (checked as the setting), Agent Island Settings....
    @MainActor
    func testSidebarMenuListsTheG9ItemsInTheSpecsOrder() throws {
        let st = store([session("api"), session("api-qa")], history: [crashed("old")], dch: bin([1, 38, 0]))
        XCTAssertEqual(st.resumeAllButton, AgentIsland.resumeAllLabel(1), "precondition: one record to resume")
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: true)
        XCTAssertEqual(titles(e), [
            AgentIsland.newSessionLabel, "-",
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
        XCTAssertEqual(entry(again, "Row details"), .submenu("Row details", enabled: true, [
            .item("Agents", enabled: true, checked: true, verb: .rowDetail(\.agents)),
            .item("Open PRs", enabled: true, checked: false, verb: .rowDetail(\.openPRs)),
            .item("Merged", enabled: true, checked: true, verb: .rowDetail(\.merged)),
        ]))
    }

    // MARK: Enablement, one row per island gate

    /// The base gate (no control dch): every list-wide item off with the island's title, New session off, Resume and
    /// Clear absent (their buttons are), and the island's "Controls <why>" note last. Settings items stay on.
    @MainActor
    func testSidebarMenuBaseGateRefusedTurnsTheListWideItemsOff() throws {
        let st = store([session("api")], history: [crashed("old")], dch: nil)
        let why = try XCTUnwrap(st.resumeGate.refusal)
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        XCTAssertEqual(titles(e), [
            AgentIsland.newSessionLabel, "-", "Restart stale agents", "Restart all agents (force)",
            AgentIsland.stopAllGlobalLabel, AgentIsland.killAllGlobalLabel, "-",
            "Sort", "Row details", "Always allow permission prompts", "Agent Island Settings" + Self.ellipsis,
            "Diagnostics" + Self.ellipsis, "-", "note: Controls \(why)",
        ])
        XCTAssertEqual(enabled(e), [false, false, false, false, false, true, true, true, true, true])
    }

    /// The restart gate (a 1.24.0 control dch): Restart and Stop all off, naming the version; Kill all needs only the
    /// base gate (the island's #744 rule).
    @MainActor
    func testSidebarMenuRestartGateNamesTheVersionAndLeavesKillOn() throws {
        let st = store([session("api", version: "1.24.0")], dch: bin([1, 24, 0]))
        XCTAssertEqual(st.restartNeeds, "needs dch 1.24.1")
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        XCTAssertEqual(Array(titles(e).prefix(6)), [
            AgentIsland.newSessionLabel, "-", "Restart stale agents (needs dch 1.24.1)",
            "Restart all agents (force) (needs dch 1.24.1)", "Stop all\(Self.ellipsis) (needs dch 1.24.1)",
            AgentIsland.killAllGlobalLabel,
        ])
        XCTAssertEqual(Array(enabled(e).prefix(5)), [true, false, false, false, true])
    }

    /// No live session: Restart, Stop all and Kill all off (nothing to act on); New session on.
    @MainActor
    func testSidebarMenuWithNothingLiveTurnsStopKillAndRestartOff() throws {
        let st = store([], dch: bin([1, 38, 0]))
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        XCTAssertEqual(Array(titles(e).prefix(6)), [
            AgentIsland.newSessionLabel, "-", "Restart stale agents", "Restart all agents (force)",
            AgentIsland.stopAllGlobalLabel, AgentIsland.killAllGlobalLabel,
        ])
        XCTAssertEqual(Array(enabled(e).prefix(5)), [true, false, false, false, false])
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
        XCTAssertEqual(q.action, "Kill")
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

    /// R897-n1: Kill all asks, so the item reads "Kill all..." (a literal, on and off), as the island's does.
    @MainActor
    func testSidebarKillAllTitleHasTheEllipsis() throws {
        for dch in [bin([1, 38, 0]), nil] {
            let st = store([session("api")], dch: dch)
            let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
            XCTAssertTrue(titles(e).contains("Kill all\u{2026}"), "titles: \(titles(e))")
            XCTAssertEqual(entry(e, "Kill all\u{2026}"),
                           .item("Kill all\u{2026}", enabled: dch != nil, checked: nil, verb: .killAll))
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
}
