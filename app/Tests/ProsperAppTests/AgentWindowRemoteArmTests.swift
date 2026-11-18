import AppKit
import XCTest
@testable import ProsperApp

/// #1330 (R836-q1): a remote attach takes the session from the device holding it (dch exit 5 there), so it starts only
/// from the human: a click, a keyboard pick, Attach or Reconnect. A window show, a restored target, a row dropped and
/// listed again or the New session form closing shows the Attach card instead. (R836-q2): host, name and alias are
/// outside text, drawn through OutsideText.shown; argv keeps them raw. Fakes only (AgentWindowRemoteRowsTests' model:
/// a fake remote list, a recording spawn); no dch, no host, no window shown.
final class AgentWindowRemoteArmTests: XCTestCase {
    typealias Lister = AgentWindowRemoteRowsTests.Lister
    let rows = Rows()
    static let wideArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)

    /// #1477 b3: AgentWindowRemoteRowsTests' model with every pane terminal on its recorders. With splits on each pane has
    /// its own controller (made on first need), so a layout's new pane would otherwise get one that never spawns a fake.
    struct Rows {
        let base = AgentWindowRemoteRowsTests()
        @MainActor func session(_ name: String, _ state: AgentState = .idle) -> AgentSession { base.session(name, state) }
        @MainActor func spin(until done: () -> Bool) { base.spin(until: done) }
        @MainActor
        func model(_ lister: Lister, sessions: [AgentSession]) -> (AgentWindowModel, AgentIslandStore, AgentWindowRemoteRowsTests.Log) {
            let (m, store, log) = base.model(lister, sessions: sessions)
            let first = m.terminal
            m.paneAfter = { _, _ in }   // an unfocused pane's rest is never run here
            m.makeTerminal = {
                let t = AgentTerminalController()
                t.request = first.request
                t.spawn = first.spawn
                t.makeScreen = { [weak t] events in
                    if let t, let g = t.grid { t.gridChanged(cols: g.cols, rows: g.rows, generation: t.generation) }
                    return AgentTerminalTests.FakeScreen(events)
                }
                t.after = { _, _ in }
                t.clientVersion = first.clientVersion
                t.gridChanged(cols: 80, rows: 24)
                return t
            }
            return (m, store, log)
        }
    }
    static let api = AgentSidebar.RowID.remote(host: "host-a", name: "api")
    static let apiKey = AgentTerminalSpawn.remoteKey(host: "host-a", name: "api")
    static let apiArgs = ["-E", "--host", "host-a", "-a", "api", "--scrollback", "2000"]

    // MARK: (a) hide and show

    @MainActor
    func testShowingTheWindowAgainShowsAttachAndNeverAttachesARemoteRow() throws {
        let (m, _, log) = rows.model(Lister(AgentWindowRemoteRowsTests.fixture), sessions: [])
        defer { m.close() }
        m.click(Self.api)
        XCTAssertEqual(log.spawns.count, 1)
        XCTAssertEqual(log.spawns.last?.args, Self.apiArgs)
        m.setVisible(false)
        XCTAssertEqual(log.children.last?.terminated, 1, "hidden: detached")
        m.setVisible(true)
        XCTAssertEqual(log.spawns.count, 1, "a show never takes the session from the other device")
        XCTAssertEqual(m.terminal.held, Self.apiKey, "the card with Attach")
        XCTAssertEqual(m.terminal.phase, .idle)
        XCTAssertTrue(m.terminal.screen == nil)
        // Another refresh keeps it held.
        m.refresh()
        XCTAssertEqual(log.spawns.count, 1)
        // Attach: exactly one.
        m.terminal.attachHeld()
        XCTAssertEqual(log.spawns.count, 2)
        XCTAssertEqual(log.spawns.last?.args, Self.apiArgs)
        XCTAssertTrue(m.terminal.held == nil)
        m.refresh()
        XCTAssertEqual(log.spawns.count, 2, "the next refresh keeps the one attach")
    }

    // MARK: (c) dropped and listed again

    @MainActor
    func testARemoteRowDroppedAndListedAgainNeverAttachesByItself() throws {
        let lister = Lister(AgentWindowRemoteRowsTests.fixture)
        let (m, _, log) = rows.model(lister, sessions: [])
        defer { m.close() }
        m.click(Self.api)
        XCTAssertEqual(log.spawns.count, 1)
        // host-a goes (offline past its stale minutes), then comes back.
        lister.answer(#"[{"name":"build","alias":"","host":"host-b","state":"idle","stale":false,"cwd":null}]"#)
        log.clock += AgentWindowModel.remoteEvery
        m.refresh()
        XCTAssertTrue(m.row(Self.api) == nil)
        XCTAssertEqual(log.children.last?.terminated, 1)
        lister.answer(AgentWindowRemoteRowsTests.fixture)
        log.clock += AgentWindowModel.remoteEvery
        m.refresh()
        XCTAssertTrue(m.row(Self.api) != nil)
        XCTAssertEqual(log.spawns.count, 1, "a re-listed row never takes the session by itself")
        XCTAssertEqual(m.terminal.held, Self.apiKey)
        m.click(Self.api)
        XCTAssertEqual(log.spawns.count, 2, "a click: exactly one")
    }

    // MARK: (b) a restored layout's remote target

    @MainActor
    func testARestoredRemoteTargetWaitsForAClick() throws {
        let (m, _, log) = rows.model(Lister(AgentWindowRemoteRowsTests.fixture), sessions: [])
        defer { m.close() }
        m.adopt(PaneLayout.single(.remote(host: "host-a", name: "api")))
        XCTAssertEqual(log.spawns.count, 0, "a restored target never attaches")
        XCTAssertEqual(m.terminal.held, Self.apiKey)
        m.refresh()
        XCTAssertEqual(m.selection, Self.api)
        XCTAssertEqual(log.spawns.count, 0)
        m.click(Self.api)
        XCTAssertEqual(log.spawns.count, 1)
        XCTAssertEqual(log.spawns.last?.args, Self.apiArgs)
    }

    /// #1477 b3: the same in a split: the remote target in the unfocused pane, a local session focused. A click on the
    /// remote row focuses its pane (rule 1) and starts exactly one attach, in that pane's terminal.
    @MainActor
    func testARestoredRemoteTargetInAnUnfocusedPaneWaitsForAClick() throws {
        XCTAssertTrue(AgentPaneLayout.splitsEnabled)
        let (m, _, log) = rows.model(Lister(AgentWindowRemoteRowsTests.fixture), sessions: [rows.session("web")])
        defer { m.close() }
        m.paneArea = Self.wideArea
        let local = Pane(id: UUID(), target: .session(dir: AgentWindowRemoteRowsTests.dir, name: "web"))
        let remote = Pane(id: UUID(), target: .remote(host: "host-a", name: "api"))
        m.adopt(PaneLayout(id: UUID(), name: nil, tree: .split(.columns, ratio: 0.5, .leaf(local), .leaf(remote)),
                           focused: local.id, zoomed: nil))
        m.refresh()
        let n = log.spawns.count   // the focused local "web" may have attached
        XCTAssertFalse(log.spawns.contains { $0.args == Self.apiArgs }, "a restored target never attaches")
        m.click(Self.api)
        XCTAssertEqual(m.layout.focused, remote.id, "the click focuses the remote target's pane")
        XCTAssertEqual(log.spawns.count, n + 1, "a click: exactly one attach")
        XCTAssertEqual(log.spawns.last?.args, Self.apiArgs)
        XCTAssertEqual(m.terminal.key, Self.apiKey, "in the focused pane's own terminal")
        m.refresh()
        XCTAssertEqual(log.spawns.count, n + 1, "the next refresh keeps the one attach")
    }

    // MARK: (d) the New session form closing over it

    @MainActor
    func testClosingTheNewSessionFormOverARemoteRowNeverAttaches() throws {
        let pref = "agentIslandNewSessionCommand"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        Preferences.agentIslandNewSessionCommand = "claude"
        let (m, store, log) = rows.model(Lister(AgentWindowRemoteRowsTests.fixture), sessions: [rows.session("web")])
        defer { m.close() }
        store.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 74, 0])
        let island = AgentIslandController()
        island.chooseFolder = { _ in XCTFail("no chooser here") }
        m.island = { island }
        m.home = "/Users/example"
        m.click(Self.api)
        XCTAssertEqual(log.spawns.last?.args, Self.apiArgs)
        let n = log.spawns.count   // the first fill may have attached the local "web" before
        m.openNewSession()
        XCTAssertTrue(m.newSession != nil)
        XCTAssertEqual(log.children.last?.terminated, 1, "the form covers the pane: detached")
        m.cancelNewSession()
        XCTAssertEqual(log.spawns.count, n, "closing the form never takes the session")
        XCTAssertEqual(m.terminal.held, Self.apiKey)
    }

    // MARK: a keyboard pick and Reconnect

    @MainActor
    func testAKeyboardPickAndReconnectEachStartExactlyOneAttach() throws {
        let (m, _, log) = rows.model(Lister(AgentWindowRemoteRowsTests.fixture), sessions: [])
        defer { m.close() }
        XCTAssertTrue(m.selection == nil)
        m.move(1)   // from none: the first row, host-a's api
        XCTAssertEqual(m.selection, Self.api)
        XCTAssertEqual(log.spawns.count, 1)
        log.ios.last?.exit(1)
        rows.spin { m.terminal.phase != .live }
        XCTAssertEqual(m.terminal.phase, .failed("Lost the connection to host-a"))
        m.refresh()
        XCTAssertEqual(log.spawns.count, 1, "#896: a re-list never retries; the backoff does (this rig's clock never runs)")
        m.terminal.retry()   // Reconnect
        XCTAssertEqual(log.spawns.count, 2)
    }

    // MARK: R836-q2: shown through OutsideText, argv raw

    @MainActor
    func testRemoteHostNameAndAliasAreShownThroughOutsideTextAndArgvKeepsThemRaw() throws {
        // A right-to-left override in the host, five combining acute accents on the alias (dch \u-escapes them in
        // its JSON; they decode back).
        let json = #"""
        [{"name":"api","alias":"qa\u0301\u0301\u0301\u0301\u0301","host":"host-\u202ea","state":"idle","stale":false,"cwd":null}]
        """#
        let rawHost = "host-\u{202E}a"
        let (m, _, log) = rows.model(Lister(json), sessions: [])
        defer { m.close() }
        let id = AgentSidebar.RowID.remote(host: rawHost, name: "api")
        let row = try XCTUnwrap(m.row(id), "the id keeps the raw host")
        XCTAssertEqual(row.title, "qa\u{301}\u{301}\u{301}", "marks capped at three")
        XCTAssertEqual(row.remote?.host, rawHost)
        XCTAssertEqual(AgentSidebarRowView.hostLabel(rawHost), "host-a", "the override dropped from the host label")
        m.click(id)
        XCTAssertEqual(log.spawns.last?.args, ["-E", "--host", rawHost, "-a", "api", "--scrollback", "2000"],
                       "argv carries the raw host")
        log.ios.last?.exit(4)
        rows.spin { m.terminal.phase != .live }
        XCTAssertEqual(m.terminal.phase, .failed("host-a refused the attach"), "the card's host shown, not raw")
        // #1324's remote History row title.
        let history = #"""
        [{"name":"docs","alias":"d\u202eocs","cwd":"/Users/example/docs","ended":1799999500,"end":"stopped","file":"docs","host":"host-a","stale":false}]
        """#
        let rec = try XCTUnwrap(AgentSidebar.parseRemoteHistory(Data(history.utf8))?.first)
        XCTAssertEqual(AgentSidebar.row(rec.record, now: AgentWindowD1Tests.now, stale: false, action: nil).title, "docs")
    }

    /// R1330-s1: the failed Resume text of a remote record holds the remote name and another machine's dch text.
    @MainActor
    func testARemoteRowsFailedResumeDetailIsShownThroughOutsideText() throws {
        let history = #"""
        [{"name":"do\u202ecs","alias":"","cwd":"/Users/example/docs","ended":1799999500,"end":"exit 1","file":"docs","host":"host-a","stale":false}]
        """#
        let rec = try XCTUnwrap(AgentSidebar.parseRemoteHistory(Data(history.utf8))?.first)
        let failed = "dch: do\u{202E}cs: no such file\u{202E}"
        let row = AgentSidebar.row(rec.record, now: AgentWindowD1Tests.now, stale: false, action: failed)
        XCTAssertEqual(row.detail, "dch: docs: no such file", "the override dropped from the detail")
        // The stored text (what the pane's refusal line draws) is the shown text.
        let (m, _, _) = rows.model(Lister("[]"), sessions: [])
        defer { m.close() }
        let res = AgentIsland.actionResult(status: 1, output: Data("dch: do\u{202E}cs: boom\u{202E}\n".utf8))
        let raw = AgentIsland.rowText(res, name: "docs", .resume)
        XCTAssertTrue(raw.contains("\u{202E}"), "the fake result carries the override: \(raw.count)")
        m.remoteResumed(rec.record.id, name: "docs", arg: "docs", res)
        XCTAssertEqual(m.remoteResumeText[rec.record.id], OutsideText.shown(raw))
        XCTAssertTrue(m.remoteResumeText[rec.record.id]?.contains("\u{202E}") == false)
    }
}
