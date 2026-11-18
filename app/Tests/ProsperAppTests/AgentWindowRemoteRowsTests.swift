import AppKit
import XCTest
@testable import ProsperApp

/// #836 step A (#822 P3): sessions on other machines from `dch --ls-json --remote`, in an "Other machines" section,
/// opened in Terminal only. Fakes only: the remote list is a JSON fixture handed to a fake runner closure, the terminal's
/// spawn is a recorder; no dch, no host, no window shown.
final class AgentWindowRemoteRowsTests: XCTestCase {

    static let dir = "/tmp/dch-test"
    static let localKey = AgentSessionKey(dir: dir, name: "api")

    /// dch.c:16380-16397 (v1.74.0): local rows first (no "host"), then each remote row with "host", "stale" and "cwd".
    static let fixture = #"""
    [{"name":"api","alias":"","harness":"","activity_epoch":1799999940,"state":"idle","version":"1.74.0","agents":0,"cwd":"/Users/example/api"},
     {"name":"build","alias":"","host":"host-b","state":"working","stale":false,"cwd":"/Users/example/build"},
     {"name":"api","alias":"api-qa","host":"host-a","state":"blocked","stale":false,"cwd":null},
     {"name":"web","alias":"","host":"host-a","state":"idle","stale":true,"cwd":"/Users/example/web"},
     {"name":"api","alias":"dup","host":"host-a","state":"idle","stale":false,"cwd":null},
     {"name":"-k","alias":"","host":"host-a","state":"idle","stale":false,"cwd":null},
     {"name":"x","alias":"","host":"-bad","state":"idle","stale":false,"cwd":null},
     {"name":"x\u001b[2J","alias":"","host":"host-a","state":"idle","stale":false,"cwd":null},
     {"name":"","alias":"","host":"host-a","state":"idle","stale":false,"cwd":null}]
    """#

    /// Records every remote list call; answers what `answer` holds now. Sendable: it runs where the model runs it.
    final class Lister: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _answer: Data?
        init(_ json: String?) { _answer = json.map { Data($0.utf8) } }
        var calls: [[String]] { lock.withLock { _calls } }
        func answer(_ json: String?) { lock.withLock { _answer = json.map { Data($0.utf8) } } }
        func run(_ args: [String]) -> Data? { lock.withLock { _calls.append(args); return _answer } }
    }

    final class Log {
        var spawns: [AgentTerminalSpawn] = []
        var ios: [AgentTerminalIO] = []
        var children: [AgentTerminalTests.FakeChild] = []
        var watches = 0
        var clock: TimeInterval = 100
    }

    func session(_ name: String, _ state: AgentState = .idle) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: Self.dir, name: name), alias: "", activity: AgentWindowD1Tests.now - 60,
                     state: state, agents: 0, meta: nil, version: "1.74.0",
                     claudeSessionID: "0b7c2f3e-1111-2222-3333-444455556666",
                     transcriptPath: "/Users/example/.claude/projects/p/0b7c2f3e-1111-2222-3333-444455556666.jsonl")
    }

    /// A visible window model on the fake list and a recording terminal; transcript watches are counted.
    @MainActor
    func model(_ lister: Lister, sessions: [AgentSession]) -> (AgentWindowModel, AgentIslandStore, Log) {
        let log = Log()
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        store.sessions = sessions
        let m = AgentWindowModel()
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in log.watches += 1; return NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        m.remoteRun = { args, _ in lister.run(args) }
        m.remoteClock = { log.clock }
        m.terminal.request = { AgentTerminalSpawn.attach($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { req, io in
            log.spawns.append(req)
            log.ios.append(io)
            let c = AgentTerminalTests.FakeChild()
            log.children.append(c)
            return c
        }
        m.terminal.makeScreen = { [weak t = m.terminal] events in
            if let t, let g = t.grid { t.gridChanged(cols: g.cols, rows: g.rows, generation: t.generation) }
            return AgentTerminalTests.FakeScreen(events)
        }
        m.terminal.after = { _, _ in }
        m.terminal.clientVersion = { _ in [1, 74, 0] }
        m.terminal.gridChanged(cols: 80, rows: 24)
        m.bind(store)
        m.setVisible(true)
        return (m, store, log)
    }

    /// The main queue runs until `done` holds (a child's exit is delivered there), 2 s at most.
    @MainActor
    func spin(until done: () -> Bool) {
        let end = Date().addingTimeInterval(2)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: (a) parsed, grouped under the host; local rows unchanged

    @MainActor
    func testRemoteRowsAreParsedGroupedUnderTheirHostAndLocalRowsStayAsTheyWere() throws {
        let parsed = try XCTUnwrap(AgentSidebar.parseRemote(Data(Self.fixture.utf8)))
        XCTAssertEqual(parsed.map { "\($0.host):\($0.name)" }, ["host-b:build", "host-a:api", "host-a:web"],
                       "only rows with a host; a flag-shaped, control-holding or empty name or host and a duplicate dropped")
        XCTAssertTrue(AgentSidebar.parseRemote(Data("{}".utf8)) == nil, "not an array: nil (the caller keeps its rows)")
        XCTAssertTrue(AgentSidebar.parseRemote(Data()) == nil)
        XCTAssertEqual(AgentSidebar.parseRemote(Data("[]".utf8)), [])

        let lister = Lister(Self.fixture)
        let local = session("api")
        let (m, store, _) = model(lister, sessions: [local])
        defer { m.close() }
        XCTAssertEqual(lister.calls, [["--ls-json", "--remote"]], "one remote call on show")
        XCTAssertEqual(m.sections.map(\.title), ["Sessions", AgentSidebar.otherMachinesTitle])
        let other = try XCTUnwrap(m.sections.last)
        XCTAssertEqual(other.rows.map(\.id), [.remote(host: "host-a", name: "api"), .remote(host: "host-a", name: "web"),
                                              .remote(host: "host-b", name: "build")], "grouped under the host, then by name")
        XCTAssertEqual(other.rows.map(\.title), ["api-qa", "web", "build"])
        XCTAssertEqual(other.rows.map(\.detail), ["Terminal only", "Stale", "Terminal only"])
        XCTAssertEqual(other.rows.map { $0.remote?.host }, ["host-a", "host-a", "host-b"], "the host label's value")
        XCTAssertTrue(AgentSidebar.collapsible.contains(AgentSidebar.otherMachinesTitle))
        // The local row is the one the island's values alone build.
        let alone = AgentSidebar.sections(sessions: [local], history: [], sort: store.sort, sidekickPattern: store.sidekickPattern,
                                          details: store.details, now: AgentWindowD1Tests.now)
        XCTAssertEqual(m.sections.first, alone.first)
        XCTAssertEqual(store.sessions, [local], "remote rows never enter the island's store")
    }

    // MARK: (b) Terminal only, no transcript lookup

    @MainActor
    func testRemoteRowOpensInTerminalOnlyWithNoTranscriptLookup() throws {
        let lister = Lister(Self.fixture)
        let (m, _, log) = model(lister, sessions: [session("api")])
        defer { m.close() }
        m.select(.live(Self.localKey))
        let watchesBefore = log.watches
        // A Transcript choice remembered for "api" by another row would leave it unattached; Terminal attaches as before.
        if m.paneHasTerminal { XCTAssertEqual(log.spawns.last?.args, ["-E", "-a", "api", "--scrollback", "2000"], "a local row attaches as before") }
        let id = AgentSidebar.RowID.remote(host: "host-a", name: "api")
        m.click(id)
        XCTAssertEqual(m.selection, id)
        XCTAssertTrue(m.paneHasTerminal)
        XCTAssertEqual(log.spawns.last?.args, ["-E", "--host", "host-a", "-a", "api", "--scrollback", "2000"],
                       "the remote attach, --host form, with the scrollback every 1.40+ client asks for")
        XCTAssertTrue(log.spawns.last?.env["DCH_SOCKET_DIR"] == nil, "no local socket dir for a remote attach")
        XCTAssertEqual(m.terminal.remoteHost, "host-a")
        XCTAssertEqual(log.watches, watchesBefore, "no transcript file is watched for a remote row")
        XCTAssertFalse(m.transcript.running)
        XCTAssertTrue(m.focusedLive == nil, "no island session behind it: no answers, no hooks")
        XCTAssertFalse(m.openSelected(), "no local Open in terminal")
        // The header's disabled controls each say why.
        for reason in [AgentRemoteHeader.todosReason] {
            XCTAssertFalse(reason.isEmpty)
        }
    }

    // MARK: (c) no island state

    @MainActor
    func testRemoteRowShowsNoIslandState() throws {
        let lister = Lister(Self.fixture)
        let (m, _, _) = model(lister, sessions: [])
        defer { m.close() }
        let row = try XCTUnwrap(m.row(.remote(host: "host-a", name: "api")))
        XCTAssertTrue(row.state == nil, "dch said blocked; the island cannot answer it, so no state is shown")
        XCTAssertTrue(row.session == nil && row.record == nil)
        XCTAssertEqual(row.age, "")
        XCTAssertFalse(m.sections.contains { $0.title == AgentSidebar.needsYouTitle }, "a remote blocked row is not Needs you")
        XCTAssertTrue(m.selection == nil, "the first fill never picks a remote row (an attach takes it from its device)")
    }

    // MARK: (d) the phone-facing listing stays local

    @MainActor
    func testServerListingStaysLocalAndNeverCallsRemote() throws {
        // The island's list (the server's cache and the window's local rows) through a counting runner.
        let seen = Lister(#"[{"name":"api","alias":"","activity_epoch":1799999940,"state":"idle"}]"#)
        let listed = AgentIsland.list(dirs: [Self.dir], run: { args, _ in seen.run(args) })
        XCTAssertEqual(listed.map(\.key), [Self.localKey])
        XCTAssertEqual(seen.calls, [["--ls-json"]])
        XCTAssertFalse(seen.calls.contains { $0.contains("--remote") }, "the island's list is local only")
        // The window's own remote call does not go there.
        let lister = Lister(Self.fixture)
        let (m, _, _) = model(lister, sessions: [])
        defer { m.close() }
        XCTAssertEqual(lister.calls.count, 1)
        XCTAssertFalse(seen.calls.contains { $0.contains("--remote") })
        // No server or island source holds a "--remote" argument (DchCommand.listSessions, the watch hub, the ctl reads);
        // Claude's own "--remote-control" flag is another word.
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp")
        for folder in ["Server", "AgentIsland"] {
            let files = try FileManager.default.contentsOfDirectory(at: src.appendingPathComponent(folder),
                                                                    includingPropertiesForKeys: nil)
            XCTAssertFalse(files.isEmpty, folder)
            for f in files where f.pathExtension == "swift" {
                XCTAssertFalse(try String(contentsOf: f, encoding: .utf8).contains("\"--remote\""), f.lastPathComponent)
            }
        }
    }

    // MARK: (e) an offline host's rows drop; a failed attach shows the card, never retries

    @MainActor
    func testOfflineHostRowsDropInOneRefreshAndAFailedCallKeepsThem() throws {
        let lister = Lister(Self.fixture)
        let (m, store, log) = model(lister, sessions: [session("api")])
        defer { m.close() }
        m.click(.remote(host: "host-b", name: "build"))
        XCTAssertEqual(log.spawns.last?.args, ["-E", "--host", "host-b", "-a", "build", "--scrollback", "2000"])
        // host-b is gone from dch's answer (past its two stale minutes): its rows go on the next refresh.
        lister.answer(#"[{"name":"api","alias":"","host":"host-a","state":"idle","stale":false,"cwd":null}]"#)
        log.clock += 1
        m.refresh()
        XCTAssertEqual(lister.calls.count, 1, "spaced: no second call within remoteEvery")
        log.clock += AgentWindowModel.remoteEvery
        m.refresh()
        XCTAssertEqual(lister.calls.count, 2)
        XCTAssertEqual(m.sections.last?.rows.map(\.id), [.remote(host: "host-a", name: "api")])
        XCTAssertTrue(m.row(.remote(host: "host-b", name: "build")) == nil)
        XCTAssertTrue(m.selection == nil, "the gone row is no longer selected")
        XCTAssertEqual(log.children.last?.terminated, 1, "its terminal detached")
        // A call that timed out (nil) or printed no array keeps the rows (no flicker).
        for answer in [nil, "dch: something"] as [String?] {
            lister.answer(answer)
            log.clock += AgentWindowModel.remoteEvery
            m.refresh()
            XCTAssertEqual(m.sections.last?.rows.count, 1, String(describing: answer))
        }
        // No remote rows at all: the section goes; the local one stays.
        lister.answer("[]")
        log.clock += AgentWindowModel.remoteEvery
        m.refresh()
        XCTAssertEqual(m.sections.map(\.title), ["Sessions"])
        XCTAssertEqual(store.sessions.count, 1)
    }

    @MainActor
    func testRemoteAttachFailureShowsTheCardAndRetriesOnlyAfterItsBackoff() throws {
        let lister = Lister(Self.fixture)
        let (m, _, log) = model(lister, sessions: [])
        defer { m.close() }
        m.click(.remote(host: "host-a", name: "api"))
        XCTAssertEqual(log.spawns.count, 1)
        XCTAssertEqual(m.terminal.phase, .live)
        log.ios.last?.exit(1)
        spin { m.terminal.phase != .live }
        XCTAssertEqual(m.terminal.phase, .failed("Lost the connection to host-a"))
        XCTAssertEqual(log.spawns.count, 1, "#896: the automatic retry waits for its backoff (this rig's clock never runs)")
        m.terminal.retry()   // the card's Reconnect
        XCTAssertEqual(log.spawns.count, 2)
        XCTAssertEqual(m.terminal.phase, .live)
        log.ios.last?.exit(0)
        spin { m.terminal.phase != .live }
        XCTAssertEqual(m.terminal.phase, .ended, "a remote exit 0 is an end, never the local one-time reattach")
        XCTAssertEqual(log.spawns.count, 2)
        m.terminal.retry()
        log.ios.last?.exit(4)
        spin { m.terminal.phase != .live }
        XCTAssertEqual(m.terminal.phase, .failed("host-a refused the attach"))
        XCTAssertEqual(log.spawns.count, 3)
    }
}
