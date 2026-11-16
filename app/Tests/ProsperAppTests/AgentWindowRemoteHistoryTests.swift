import AppKit
import XCTest
@testable import ProsperApp

/// #1324 (step 2B): History lists other machines' records from `dch --history --json --remote` with their host, and
/// Resume brings one back there with `dch --host <h> --revive <file>.json --json`. Fakes only: JSON fixtures handed to
/// fake runner closures, a recording verb seam; no dch, no host, no window shown.
final class AgentWindowRemoteHistoryTests: XCTestCase {

    typealias Lister = AgentWindowRemoteRowsTests.Lister
    static let dir = AgentWindowRemoteRowsTests.dir
    static let local = DchHistoryRecord(key: AgentSessionKey(dir: dir, name: "old"), cwd: "/Users/example/old",
                                        ended: AgentWindowD1Tests.now - 600, end: "exit 0", file: "old")

    /// README.md:467 and :3300-3308 (v1.74.0): local records first (no "host"), then each host's as it sent them plus
    /// "host" and "stale". Left out here: no host, a flag-shaped name, host or file, a repeat of one host's record.
    static let fixture = #"""
    [{"name":"old","alias":"","cwd":"/Users/example/old","ended":1799999400,"end":"exit 0","file":"old"},
     {"name":"api","alias":"","cwd":"/Users/example/api","ended":1799999000,"end":"exit 1","file":"api","host":"host-a","stale":false},
     {"name":"docs","alias":"Docs","cwd":"/Users/example/docs","ended":1799999500,"end":"stopped","file":"docs","host":"host-a","stale":false},
     {"name":"build","alias":"","cwd":"/Users/example/build","ended":1799990000,"end":"exit 1","file":"build","host":"host-b","stale":true},
     {"name":"api","alias":"dup","cwd":"/Users/example/api","ended":1799999000,"end":"exit 1","file":"api","host":"host-a","stale":false},
     {"name":"-k","alias":"","ended":1799999000,"end":"exit 1","file":"x","host":"host-a","stale":false},
     {"name":"x","alias":"","ended":1799999000,"end":"exit 1","file":"x","host":"-bad","stale":false},
     {"name":"y","alias":"","ended":1799999000,"end":"exit 1","file":"-y","host":"host-a","stale":false}]
    """#

    final class Verbs {
        var calls: [(key: AgentSessionKey, dch: String, args: [String])] = []
        var done: (@Sendable (DchActionResult) -> Void)?
        var answer = true
    }

    final class Log {
        var clock: TimeInterval = 100
        var pins = 0
    }

    static func key(_ host: String, _ name: String) -> AgentSessionKey { AgentSessionKey(dir: "@" + host, name: name) }

    /// A visible window on the fake list (step A's fixture: host-a runs "api"), the fake History answer and a recording
    /// verb seam; the island's own Resume, Pin and Remove are counted.
    @MainActor
    func model(_ history: Lister, verbs: Verbs = Verbs(), lister: Lister = Lister(AgentWindowRemoteRowsTests.fixture))
        -> (AgentWindowModel, AgentIslandStore, Log) {
        let log = Log()
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        store.controlDch = DchCommand.Binary(path: "/opt/example/bin/dch", version: [1, 74, 0])
        store.history = [Self.local]
        let m = AgentWindowModel()
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in log.pins += 100 }
        m.resumeNoMessage = { _ in log.pins += 10 }
        m.pinRecord = { _ in log.pins += 1 }
        m.removeRecord = { _ in log.pins += 1 }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        m.remoteRun = { args, _ in lister.run(args) }
        m.remoteHistoryRun = { args, _ in history.run(args) }
        m.remoteClock = { log.clock }
        m.remoteVerb = { key, dch, args, done in
            verbs.calls.append((key, dch, args))
            verbs.done = done
            return verbs.answer
        }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.bind(store)
        m.setVisible(true)
        return (m, store, log)
    }

    @MainActor
    func spin(until done: () -> Bool) {
        let end = Date().addingTimeInterval(2)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: (a) parsed and labelled; local records unchanged

    @MainActor
    func testRemoteHistoryRecordsAreParsedLabelledAndLocalRowsStayAsTheyWere() throws {
        let parsed = try XCTUnwrap(AgentSidebar.parseRemoteHistory(Data(Self.fixture.utf8)))
        XCTAssertEqual(parsed.map { "\($0.host):\($0.record.name)" }, ["host-a:docs", "host-a:api", "host-b:build"],
                       "records with a host only, each host newest first; flag-shaped and repeated ones left out")
        XCTAssertEqual(parsed.map(\.record.key.dir), ["@host-a", "@host-a", "@host-b"], "step A's remote key")
        XCTAssertEqual(parsed.map(\.stale), [false, false, true])
        XCTAssertTrue(AgentSidebar.parseRemoteHistory(Data("{}".utf8)) == nil, "not an array: nil (the caller keeps its rows)")
        XCTAssertTrue(AgentSidebar.parseRemoteHistory(Data()) == nil)

        let history = Lister(Self.fixture)
        let (m, _, log) = model(history)
        defer { m.close() }
        XCTAssertEqual(history.calls, [AgentWindowModel.remoteHistoryArgs], "one History call on show, beside the list")
        XCTAssertEqual(AgentWindowModel.remoteHistoryArgs, ["--history", "--json", "--remote"])
        let h = try XCTUnwrap(m.sections.last)
        XCTAssertEqual(h.title, "History")
        XCTAssertEqual(h.rows.map(\.id), [.history(Self.local.id), .history(Self.key("host-a", "docs")),
                                          .history(Self.key("host-a", "api")), .history(Self.key("host-b", "build"))])
        XCTAssertEqual(h.rows.first, AgentSidebar.row(Self.local, now: AgentWindowD1Tests.now), "the local row as before")
        XCTAssertEqual(h.rows.map(\.host), [nil, "host-a", "host-a", "host-b"], "the host slot's value")
        XCTAssertEqual(h.rows.map(\.title), ["old", "Docs", "api", "build"])
        XCTAssertEqual(h.rows.last?.detail, "Stale \u{00B7} Ended \u{00B7} " + AgentIsland.endLabel("exit 1"), "dch's cache of a quiet host")
        // dch's History spacing: the list again after 2 s, History not before 10 s.
        log.clock += AgentWindowModel.remoteEvery
        m.refresh()
        XCTAssertEqual(history.calls.count, 1)
        log.clock += AgentWindowModel.remoteHistoryEvery
        m.refresh()
        XCTAssertEqual(history.calls.count, 2)
    }

    // MARK: (b) (d) Resume: the --host form, once, never --all; (c) the island's words, no auto-select

    @MainActor
    func testRemoteResumeRunsTheHostFormOnceAndNeverAll() throws {
        let history = Lister(Self.fixture), verbs = Verbs(), lister = Lister(AgentWindowRemoteRowsTests.fixture)
        let (m, _, log) = model(history, verbs: verbs, lister: lister)
        defer { m.close() }
        let api = try XCTUnwrap(m.row(.history(Self.key("host-a", "api")))?.record)
        m.click(.history(api.id))
        m.act(.resume, api)
        XCTAssertEqual(verbs.calls.count, 1)
        XCTAssertEqual(verbs.calls.last?.args, ["--host", "host-a", "--revive", "api.json", "--as", "api-2", "--json"],
                       "the unambiguous --host form, the exact record file; api runs on host-a, so --as")
        XCTAssertEqual(verbs.calls.last?.key, Self.key("host-a", "api"), "its own key: never a local job's")
        XCTAssertEqual(verbs.calls.last?.dch, "/opt/example/bin/dch")
        XCTAssertEqual(m.row(.history(api.id))?.detail, AgentIsland.resumingText)
        XCTAssertEqual(m.remoteResumeText[api.id], AgentIsland.resumingText)
        XCTAssertEqual(log.pins, 0, "never the island's local Resume")
        // Pin, Remove and Resume (no message) do nothing on a remote record.
        for v in [AgentWindowVerb.pin, .remove, .resumeNoMessage] { m.act(v, api) }
        XCTAssertEqual(log.pins, 0)
        XCTAssertTrue(m.confirming == nil)
        XCTAssertEqual(verbs.calls.count, 1)
        // The result: the island's words; the list and History read again at once; nothing selected or attached.
        let listed = lister.calls.count, read = history.calls.count
        let ok = #"{"name":"api","as":"api-2","result":"ok","reason":"","detail":"","session_id":"","running":true}"#
        let res = AgentIsland.actionResult(status: 0, output: Data((ok + "\n").utf8))
        verbs.done?(res)
        spin { m.remoteResumeText[api.id] != AgentIsland.resumingText }
        XCTAssertEqual(m.remoteResumeText[api.id], AgentIsland.rowText(res, name: "api", .resume))
        XCTAssertNotEqual(m.remoteResumeText[api.id], AgentIsland.resumingText)
        XCTAssertEqual(lister.calls.count, listed + 1)
        XCTAssertEqual(history.calls.count, read + 1)
        XCTAssertEqual(m.selection, .history(api.id), "a resumed remote session is never selected by itself")
        // A name dch would read as a flag never runs, and no call ever carries --all.
        let all = DchHistoryRecord(key: Self.key("host-a", "--all"), end: "exit 1")
        m.act(.resume, all)
        XCTAssertEqual(verbs.calls.count, 1)
        XCTAssertFalse(verbs.calls.contains { $0.args.contains("--all") })
        // A busy key: nothing ran, nothing shown.
        verbs.answer = false
        let docs = try XCTUnwrap(m.row(.history(Self.key("host-a", "docs")))?.record)
        m.act(.resume, docs)
        XCTAssertEqual(verbs.calls.last?.args, ["--host", "host-a", "--revive", "docs.json", "--json"])
        XCTAssertTrue(m.remoteResumeText[docs.id] == nil)
    }

    // MARK: (a) a failed answer keeps the rows; an offline host's go with dch's cache

    @MainActor
    func testAFailedRemoteHistoryAnswerKeepsTheRows() throws {
        let history = Lister(Self.fixture)
        let (m, _, log) = model(history)
        defer { m.close() }
        XCTAssertEqual(m.sections.last?.rows.count, 4)
        for answer in [nil, "dch: something", "{}"] as [String?] {
            history.answer(answer)
            log.clock += AgentWindowModel.remoteHistoryEvery
            m.refresh()
            XCTAssertEqual(m.sections.last?.rows.count, 4, String(describing: answer))
        }
        XCTAssertEqual(history.calls.count, 4)
        // host-b past dch's two stale minutes: its record goes on the next good answer; the local one stays.
        history.answer(#"[{"name":"api","ended":1799999000,"end":"exit 1","file":"api","host":"host-a","stale":false}]"#)
        log.clock += AgentWindowModel.remoteHistoryEvery
        m.refresh()
        XCTAssertEqual(m.sections.last?.rows.map(\.id), [.history(Self.local.id), .history(Self.key("host-a", "api"))])
        history.answer("[]")
        log.clock += AgentWindowModel.remoteHistoryEvery
        m.refresh()
        XCTAssertEqual(m.sections.last?.rows.map(\.id), [.history(Self.local.id)])
    }

    // MARK: (e) the phone-facing listing stays local

    @MainActor
    func testServerHistoryListingStaysLocal() throws {
        let seen = Lister(Self.fixture)
        let records = AgentIsland.history(dirs: [Self.dir], run: { args, _ in seen.run(args) })
        XCTAssertEqual(seen.calls, [["--history", "--json"]], "the island's (and the server's) History read is local only")
        XCTAssertEqual(records.count, 8, "parseHistory takes the array as given; the window's remote read is apart")
        // The window's own History call never goes through the island's runner.
        let history = Lister(Self.fixture)
        let (m, _, _) = model(history)
        defer { m.close() }
        XCTAssertEqual(history.calls, [AgentWindowModel.remoteHistoryArgs])
        XCTAssertEqual(seen.calls.count, 1)
    }
}
