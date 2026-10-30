import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #578 Agent Island session controls, phase 1a: the control binary choice,
/// `--history --json`, Resume and the long-verb runner. No test runs a real dch:
/// processes are fakes, /bin/sh, or a script under tempDir().
final class AgentIslandControlsTests: XCTestCase {
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    private func session(_ name: String, dir: String = "/d", version: String = "") -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: "", activity: 0, state: .idle, agents: 0,
                     version: version)
    }

    private func record(_ name: String, dir: String = "/d", ended: TimeInterval = 100, end: String = "signal 9") -> DchHistoryRecord {
        DchHistoryRecord(key: AgentSessionKey(dir: dir, name: name), cwd: "/src", updated: ended, ended: ended, end: end)
    }

    private static let v124 = DchCommand.Binary(path: "/fake/dch", version: [1, 24, 0])
    /// #580 addendum 2: Restart agent, Restart all and Stop need 1.24.1.
    private static let v1241 = DchCommand.Binary(path: "/fake/dch", version: [1, 24, 1])

    // MARK: - Binary choice

    func testVersionOutputMustBeExactlyDchXYZ() {
        XCTAssertEqual(DchCommand.parseVersion("dch 1.23.0\n"), [1, 23, 0])
        XCTAssertEqual(DchCommand.parseVersion("dch 1.23.0"), [1, 23, 0])
        for bad in ["dch 1.23", "dch 1.23.0.1", "1.23.0", "dch-lite 1.23.0", "dch 1.23.x", "dch 1.23.0 (dev)",
                    "dch  1.23.0", "dch 1..0", "", "dch 1.23.0\n\n", "dch ١.23.0"] {
            XCTAssertNil(DchCommand.parseVersion(bad), bad)
        }
    }

    func testVersionsCompareNumericallyPerComponent() {
        XCTAssertTrue(DchCommand.isAtLeast([1, 10, 0], [1, 9, 0]), "1.10.0 > 1.9.0, never as strings")
        XCTAssertFalse(DchCommand.isAtLeast([1, 9, 0], [1, 10, 0]))
        XCTAssertTrue(DchCommand.isAtLeast([1, 23, 0], [1, 23, 0]))
        XCTAssertFalse(DchCommand.isAtLeast([1, 22, 9], [1, 23, 0]))
        XCTAssertTrue(DchCommand.isAtLeast([2, 0, 0], [1, 99, 99]))
        XCTAssertTrue(DchCommand.isAtLeast([1, 23, 0], []), "an old master's \"\" is []")
        XCTAssertEqual(DchCommand.masterVersion(""), [])
        XCTAssertEqual(DchCommand.masterVersion("1.24.0-rc1"), [1, 24, 0])
    }

    /// Never dch's working tree; Homebrew first so it wins a tie.
    func testControlCandidatesSkipTheDchWorkingTreeAndLeadWithHomebrew() {
        let c = DchCommand.controlCandidates
        XCTAssertEqual(c.first, "/opt/homebrew/bin/dch")
        XCTAssertEqual(c.last, "/usr/local/bin/dch")
        XCTAssertFalse(c.contains { $0.contains("/personal/dch") }, "\(c)")
        XCTAssertLessThanOrEqual(c.count, 3)
    }

    func testNewestBinaryWinsAndTheEarlierCandidateWinsATie() {
        func pick(_ v: [String: [Int]]) -> String? {
            DchCommand.newest(["/opt/homebrew/bin/dch", "/app/dch", "/usr/local/bin/dch"], version: { v[$0] })?.path
        }
        XCTAssertEqual(pick(["/opt/homebrew/bin/dch": [1, 23, 0], "/app/dch": [1, 23, 0], "/usr/local/bin/dch": [1, 23, 0]]),
                       "/opt/homebrew/bin/dch", "a tie keeps Homebrew")
        XCTAssertEqual(pick(["/opt/homebrew/bin/dch": [1, 9, 0], "/app/dch": [1, 10, 0]]), "/app/dch", "numeric")
        XCTAssertEqual(pick(["/opt/homebrew/bin/dch": [1, 23, 0], "/usr/local/bin/dch": [1, 24, 0]]), "/usr/local/bin/dch")
        XCTAssertEqual(pick(["/app/dch": [1, 22, 0]]), "/app/dch", "a candidate with no answer is skipped")
        XCTAssertNil(pick([:]))
    }

    /// #580: one minimum, 1.24.0, for every control; still at least every live master.
    func testGateRefusesBelowAMasterOrTheVerbMinimum() {
        let min = AgentIsland.controlMinimum
        XCTAssertEqual(min, [1, 24, 0])
        XCTAssertEqual(DchCommand.gate(Self.v124, masters: ["1.23.0", ""], minimum: min), .ok("/fake/dch"),
                       "an old master (\"\") passes")
        XCTAssertEqual(DchCommand.gate(Self.v124, masters: ["1.9.0"], minimum: min), .ok("/fake/dch"), "numeric, not string")
        XCTAssertEqual(DchCommand.gate(Self.v124, masters: ["1.24.0", "1.25.0"], minimum: min), .refused("needs dch 1.25.0"),
                       "older than a master: --restart would downgrade it")
        XCTAssertEqual(DchCommand.gate(DchCommand.Binary(path: "/b", version: [1, 23, 0]), masters: [], minimum: min),
                       .refused("needs dch 1.24.0"), "1.23.0 has no --json or --stop")
        XCTAssertEqual(DchCommand.gate(nil, masters: [], minimum: min), .refused("needs dch 1.24.0"))
        XCTAssertEqual(DchCommand.gate(DchCommand.Binary(path: "/b", version: [1, 30, 0]), masters: ["1.24.0"], minimum: min),
                       .ok("/b"))
    }

    /// #580: Stop needs the row's own master at 1.24.0 or later, compared as numbers.
    func testStopGateReadsTheRowsMasterVersionNumerically() {
        for (v, ok) in [("", false), ("1.23.0", false), ("1.23.9", false), ("1.24.0", true), ("1.24.1", true),
                        ("1.100.0", true), ("2.0.0", true), ("garbage", false), ("1.2x.0", false), ("v1.24.0", false)] {
            XCTAssertEqual(AgentIsland.canStop(session("a", version: v)), ok, v)
        }
    }

    /// The probe runs `<path> --version` once per resolved path and mtime.
    func testVersionProbeIsCachedPerPathAndMtime() throws {
        let dir = tempDir(), script = dir.appendingPathComponent("dch").path, count = dir.appendingPathComponent("count").path
        func install(_ answer: String, mtime: TimeInterval) throws {
            try "#!/bin/sh\necho \"$1\" >> '\(count)'\necho '\(answer)'\n".write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: Date(timeIntervalSince1970: mtime)],
                                                  ofItemAtPath: script)
        }
        func runs() -> [String] { ((try? String(contentsOfFile: count, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        let link = dir.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: script)
        try install("dch 1.23.0", mtime: 1_000)
        XCTAssertEqual(DchCommand.probedVersion(script), [1, 23, 0])
        XCTAssertEqual(DchCommand.probedVersion(script), [1, 23, 0])
        XCTAssertEqual(DchCommand.probedVersion(link), [1, 23, 0], "a symlink shares its target's entry")
        XCTAssertEqual(runs(), ["--version"], "one probe per mtime, never per call")
        try install("dch 1.24.0-dev", mtime: 2_000)
        XCTAssertNil(DchCommand.probedVersion(link), "a new mtime probes again; not exactly dch X.Y.Z")
        XCTAssertNil(DchCommand.probedVersion(script))
        XCTAssertEqual(runs().count, 2, "a non-version answer is cached too")
        XCTAssertNil(DchCommand.probedVersion(dir.appendingPathComponent("missing").path))
        XCTAssertEqual(runs().count, 2)
    }

    // MARK: - History

    private static let historyJSON = #"""
    [{"name":"work","sock_dir":"/d","alias":"My work","cwd":"/src/app","argv":["headroom","wrap","claude"],
      "started":1761400000,"updated":1761403600,"ended":1761403612,"end":"signal 9","future":{"x":1},
      "agent":{"kind":"claude","session_id":"abc","name":"fix-tests","cwd":"/src/app","launch":["/usr/local/bin/claude"]}},
     {"name":"gone","updated":1761409999,"ended":0,"end":"vanished","agent":null},
     {"name":"","ended":5},
     {"alias":"no name"},
     {"name":"bare"}]
    """#

    func testHistoryParseToleratesUnknownAndMissingFields() {
        let rows = AgentIsland.parseHistory(Data(Self.historyJSON.utf8), dir: "/d")
        XCTAssertEqual(rows.map(\.name), ["work", "gone", "bare"], "nameless records are dropped")
        XCTAssertEqual(rows[0], DchHistoryRecord(
            key: AgentSessionKey(dir: "/d", name: "work"), alias: "My work", cwd: "/src/app", argv: ["headroom", "wrap", "claude"],
            started: 1_761_400_000, updated: 1_761_403_600, ended: 1_761_403_612, end: "signal 9",
            agent: .init(kind: "claude", sessionID: "abc", name: "fix-tests", cwd: "/src/app",
                         launch: ["/usr/local/bin/claude"])))
        XCTAssertEqual(rows[0].title, "My work")
        XCTAssertNil(rows[1].agent)
        XCTAssertEqual(rows[1].lastSeen, 1_761_409_999, "ended 0: last seen is updated")
        XCTAssertEqual(rows[2], DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "bare")))
        XCTAssertEqual(rows[2].title, "bare")
        XCTAssertEqual(AgentIsland.parseHistory(Data("{}".utf8), dir: "/d"), [])
        XCTAssertEqual(AgentIsland.parseHistory(Data(), dir: "/d"), [])
    }

    /// #585: neutral words; nothing the user ended on purpose reads as a crash.
    func testEndLabels() {
        let table: [(String, String)] = [
            ("killed", "closed"), ("stopped", "stopped"),
            ("exit 0", "exited"), ("exit 1", "exited (1)"), ("exit 130", "exited (130)"),
            ("signal 15", "ended (signal 15)"), ("signal 1", "ended (signal 1)"), ("signal 2", "ended (signal 2)"),
            ("signal 9", "crashed (signal 9)"), ("signal 11", "crashed (signal 11)"), ("signal 6", "crashed (signal 6)"),
            ("signal 150", "crashed (signal 150)"),
            ("", "vanished"), ("vanished", "vanished"),
            ("paused", "paused"), ("exitx", "exitx"),
        ]
        for (end, label) in table { XCTAssertEqual(AgentIsland.endLabel(end), label, end) }
        // #580: a real 1.24.0 record after `dch --stop s1`.
        let real = #"[{"name":"s1","sock_dir":"/d","alias":"","cwd":"/src","argv":["/bin/sleep","1000"],"started":1793139535,"#
            + #""updated":1793139537,"ended":1793139537,"end":"stopped","agent":null}]"#
        let r = try? XCTUnwrap(AgentIsland.parseHistory(Data(real.utf8), dir: "/d").first)
        XCTAssertEqual(r?.end, "stopped")
        XCTAssertEqual(r.map { AgentIsland.endLabel($0.end) }, "stopped")
    }

    /// #585: dch 1.24.1's rv_all_takes, edge by edge.
    func testReviveAllTakesMatchesDchRule() {
        let now: TimeInterval = 2_000_000_000, day: TimeInterval = 86400
        func rec(_ end: String, started: TimeInterval = 2_000_000_000 - 3600, ended: TimeInterval = 2_000_000_000 - 60,
                 updated: TimeInterval = 0) -> DchHistoryRecord {
            DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "s"), started: started, updated: updated, ended: ended, end: end)
        }
        for end in ["exit 0", "killed", "stopped"] {
            XCTAssertFalse(AgentIsland.reviveAllTakes(rec(end), now: now), end)
        }
        for end in ["exit 1", "signal 15", "signal 9", "vanished", "", "odd"] {
            XCTAssertTrue(AgentIsland.reviveAllTakes(rec(end), now: now), end)
        }
        let started = now - 4 * day
        XCTAssertTrue(AgentIsland.reviveAllTakes(rec("signal 9", started: started, ended: now - 3 * day + 1), now: now))
        XCTAssertTrue(AgentIsland.reviveAllTakes(rec("signal 9", started: started, ended: now - 3 * day), now: now),
                      "dch: seen >= now - 3 days")
        XCTAssertFalse(AgentIsland.reviveAllTakes(rec("signal 9", started: started, ended: now - 3 * day - 1), now: now))
        XCTAssertFalse(AgentIsland.reviveAllTakes(rec("signal 9", started: now - 1000, ended: now - 1000 + 299), now: now))
        XCTAssertTrue(AgentIsland.reviveAllTakes(rec("signal 9", started: now - 1000, ended: now - 1000 + 300), now: now))
        // Vanished with ended 0: last seen is updated.
        XCTAssertTrue(AgentIsland.reviveAllTakes(rec("vanished", started: now - 1000, ended: 0, updated: now - 600), now: now))
        XCTAssertFalse(AgentIsland.reviveAllTakes(rec("vanished", started: now - 1000, ended: 0, updated: now - 701), now: now),
                       "ran 299 s by updated")
        XCTAssertFalse(AgentIsland.reviveAllTakes(rec("", started: now - 4 * day, ended: 0, updated: now - 3 * day - 1), now: now),
                       "seen too long ago by updated")
        XCTAssertFalse(AgentIsland.reviveAllTakes(rec("", started: 0, ended: 0, updated: 0), now: now), "never seen")
    }

    /// #585: the History header: no line at all with nothing to resume, no
    /// status and the gate open; "Resume interrupted (N)" counting the takers.
    @MainActor
    func testHistoryHeaderShowsOnlyWithResumableRecords() {
        let now: TimeInterval = 2_000_000_000
        let store = AgentIslandStore(geometry: notched)
        store.now = { now }
        store.sessions = [session("a", version: "1.24.0")]
        store.controlDch = Self.v124
        func rec(_ name: String, _ end: String, ago: TimeInterval = 60) -> DchHistoryRecord {
            DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: name), started: now - 3600, updated: now - ago,
                             ended: now - ago, end: end)
        }
        store.history = [rec("k", "killed"), rec("s", "stopped"), rec("e", "exit 0"), rec("old", "signal 9", ago: 4 * 86400)]
        store.historyTab = true
        XCTAssertEqual(store.resumableCount, 0)
        XCTAssertNil(store.resumeAllButton)
        XCTAssertFalse(store.showsHistoryHeader)
        XCTAssertEqual(store.rowHeights, Array(repeating: AgentIslandGeometry.rowHeight, count: 4), "plain history, no line")
        store.actions[AgentSessionKey(dir: "/d", name: "")] = "nothing to resume"
        XCTAssertTrue(store.showsHistoryHeader, "a dir status keeps the line")
        XCTAssertNil(store.resumeAllButton)
        store.actions = [:]
        store.history.append(contentsOf: [rec("t", "signal 15"), rec("v", "")])
        XCTAssertEqual(store.resumableCount, 2)
        XCTAssertEqual(store.resumeAllButton, "Resume interrupted (2)")
        XCTAssertTrue(store.showsHistoryHeader)
        XCTAssertEqual(store.rowHeights, [AgentIslandGeometry.historyHeaderHeight]
                       + Array(repeating: AgentIslandGeometry.rowHeight, count: 6))
        store.sessions = [session("a", version: "1.25.0")]
        XCTAssertNil(store.resumeAllButton, "the gate's refusal in its place")
        XCTAssertTrue(store.showsHistoryHeader)
        store.historyTab = false
        XCTAssertFalse(store.showsHistoryHeader, "Sessions tab: no History line")
    }

    /// One `--history --json` per dir with that dir's DCH_SOCKET_DIR; newest first across dirs.
    func testHistoryReadsEachDirAndSortsNewestFirst() {
        final class Calls: @unchecked Sendable { var calls: [([String], String?, Bool)] = [] }
        let calls = Calls()
        let out = AgentIsland.history(dirs: ["/a", "/b"]) { args, env in
            calls.calls.append((args, env["DCH_SOCKET_DIR"], env["DCH_SESSION"] == nil))
            return Data((env["DCH_SOCKET_DIR"] == "/a"
                ? #"[{"name":"old","ended":10},{"name":"vanished","updated":40,"ended":0}]"#
                : #"[{"name":"new","ended":30}]"#).utf8)
        }
        XCTAssertEqual(calls.calls.map(\.0), [["--history", "--json"], ["--history", "--json"]])
        XCTAssertEqual(calls.calls.map(\.1), ["/a", "/b"])
        XCTAssertTrue(calls.calls.allSatisfy(\.2), "DCH_SESSION is never passed on")
        XCTAssertEqual(out.map(\.key), [AgentSessionKey(dir: "/a", name: "vanished"), AgentSessionKey(dir: "/b", name: "new"),
                                        AgentSessionKey(dir: "/a", name: "old")])
    }

    func testReviveArgsPickTheFirstFreeName() {
        let r = record("a")
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: ["b"], records: []), ["--revive", "a", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: ["a"], records: []), ["--revive", "a", "--as", "a-2", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: ["a", "a-2"], records: ["a-3"]), ["--revive", "a", "--as", "a-4", "--json"],
                       "a name another record holds is not free either")
    }

    // MARK: - #580: --json results

    /// dch 1.24.0 output. Lines marked "real" were captured from the built 1.24.0
    /// binary in a private socket dir (sessions running /bin/sleep or /bin/cat);
    /// the rest follow the README's shapes (they need a live Claude or dch-lite).
    enum Fixture {
        // real
        static let restartOne = """
            {"name":"s1","phase":"master","result":"ok","reason":"","detail":"restarted on dch 1.24.0","session_id":""}
            {"name":"s1","result":"skipped","reason":"not_claude","detail":"no claude runs in the session","session_id":""}
            """
        static let restartAllCurrent = """
            {"name":"s1","phase":"master","result":"skipped","reason":"current","detail":"already on dch 1.24.0","session_id":""}
            {"name":"s2","phase":"master","result":"skipped","reason":"current","detail":"already on dch 1.24.0","session_id":""}
            {"name":"s1","result":"skipped","reason":"not_claude","detail":"no claude runs in the session","session_id":""}
            {"name":"s2","result":"skipped","reason":"not_claude","detail":"no claude runs in the session","session_id":""}
            """
        static let restartAllForced = """
            {"name":"s1","phase":"master","result":"ok","reason":"","detail":"restarted on dch 1.24.0","session_id":""}
            {"name":"s2","phase":"master","result":"ok","reason":"","detail":"restarted on dch 1.24.0","session_id":""}
            {"name":"s1","result":"skipped","reason":"not_claude","detail":"no claude runs in the session","session_id":""}
            {"name":"s2","result":"skipped","reason":"not_claude","detail":"no claude runs in the session","session_id":""}
            """
        static let restartNoSession = """
            {"name":"nosuch","phase":"master","result":"failed","reason":"no_session","detail":"no such session","session_id":""}
            dch: no session: nosuch
            """
        static let stopOne = """
            {"name":"s1","phase":"ending"}
            {"name":"s1","result":"ok","reason":"","detail":"","session_id":""}
            """
        static let stopNoSession = #"{"name":"nosuch","result":"failed","reason":"no_session","detail":"no such session","session_id":""}"#
        static let stopTwo = """
            {"name":"s1","phase":"ending"}
            {"name":"s1","result":"ok","reason":"","detail":"","session_id":""}
            {"name":"s1b","phase":"ending"}
            {"name":"s1b","result":"ok","reason":"","detail":"","session_id":""}
            {"name":"s2","phase":"ending"}
            {"name":"s2","result":"ok","reason":"","detail":"","session_id":""}
            """
        static let reviveOne = """
            {"name":"s1","phase":"starting"}
            {"name":"s1","as":"s1","result":"ok","reason":"","detail":"revived as s1 in /Users/u/personal/prosper","session_id":""}
            """
        static let reviveAs = """
            {"name":"s1","phase":"starting"}
            {"name":"s1","as":"s1b","result":"ok","reason":"","detail":"revived as s1b in /Users/u/personal/prosper","session_id":""}
            """
        static let reviveNoHistory = """
            {"name":"nosuch","as":"nosuch","result":"failed","reason":"no_history","detail":"no history for this session","session_id":""}
            dch: no history for session nosuch
            """
        static let reviveNotStarted = """
            {"name":"s3","phase":"starting"}
            {"name":"s3","as":"s3","result":"failed","reason":"not_started","detail":"NOT revived — the session did not start","session_id":""}
            dch: s3: /tmp/p/myprog: No such file or directory
            dch: failed to spawn session
            """
        static let spawnNotExecutable = """
            dch: s4: /tmp/p/nonexistent-prog: No such file or directory
            dch: failed to spawn session
            """
        // README shapes
        static let restartAgent = """
            {"name":"a","phase":"master","result":"ok","reason":"","detail":"restarted on dch 1.24.0","session_id":""}
            {"name":"a","phase":"pausing"}
            {"name":"a","phase":"exiting"}
            {"name":"a","phase":"relaunching"}
            {"name":"a","phase":"resuming"}
            {"name":"a","result":"ok","reason":"","detail":"claude 2.0.1 -> 2.1.0, resumed abc","session_id":"abc"}
            """
        static let reviveLite = #"{"name":"a","as":"a","result":"ok","reason":"no_screen","detail":"a: revived, resume message not typed","session_id":"abc"}"#
        static let stopInterrupted = """
            {"name":"a","phase":"pausing"}
            {"name":"a","result":"interrupted","reason":"signal","detail":"a: interrupted — resume message typed","session_id":""}
            """
        // Hand-written, dch 1.24.1 (not tagged yet), from the dch session's shapes (#580 addendum 2).
        static let restartInShell = """
            {"name":"a","phase":"master","result":"skipped","reason":"current","detail":"already on dch 1.24.1","session_id":""}
            {"name":"a","result":"skipped","reason":"in_shell","detail":"a: skipped — claude was started inside the session's shell, not as its command","session_id":""}
            """
        static let stopInShell = """
            {"name":"a","phase":"pausing"}
            {"name":"a","phase":"ending"}
            {"name":"a","result":"ok","reason":"","detail":"","session_id":"abc"}
            """
        static let stopOldMaster = #"{"name":"a","result":"failed","reason":"old_master","detail":"a: NOT stopped — its master is older than dch 1.24.0","session_id":""}"#
    }

    private func result(_ out: String, status: Int32 = 0, stopped: Bool = false) -> DchActionResult {
        AgentIsland.actionResult(status: status, output: Data((out + "\n").utf8), stopped: stopped)
    }

    /// Each stdout line decodes on its own; a line that does not (stderr's text,
    /// a stray line, bad JSON, a wrong type, no name, neither phase nor result)
    /// is text, never a crash.
    func testJSONLinesDecodeLenientlyAndTheRestIsText() {
        let r = result("""
            {"name":"s1","phase":"ending"}
            warning: something
            {"name":"s1","result":"ok","reason":"","detail":"","session_id":"","future":[1]}
            {"name":"x","result":
            {"name":5,"result":"ok"}
            {"result":"ok"}
            {"name":"y"}
              dch: s1: trailing spaces  \("")
            """, status: 1)
        XCTAssertEqual(r.json, [DchJSONLine(name: "s1", phase: "ending"),
                                DchJSONLine(name: "s1", result: "ok", reason: "", detail: "", sessionID: "")])
        XCTAssertEqual(r.text, ["warning: something", #"{"name":"x","result":"#, #"{"name":5,"result":"ok"}"#,
                                #"{"result":"ok"}"#, #"{"name":"y"}"#, "dch: s1: trailing spaces"])
        XCTAssertEqual(r.dchLine, "dch: s1: trailing spaces")
        XCTAssertEqual(AgentIsland.actionResult(status: 0, output: Data()), DchActionResult(status: 0))
        let o = AgentIsland.jsonLine(#"{"name":"s1","as":"s1b","result":"ok","reason":"","detail":"d","session_id":"z"}"#)
        XCTAssertEqual(o?.revivedAs, "s1b")
        XCTAssertEqual(o?.sessionID, "z")
    }

    /// A phase is running text, never a result; the master pass is neither.
    func testPhasesAreRunningTextOnly() throws {
        let words = ["pausing": "Pausing…", "exiting": "Exiting…", "relaunching": "Relaunching…", "resuming": "Resuming…",
                     "starting": "Starting…", "ending": "Ending…"]
        for (p, t) in words {
            let o = DchJSONLine(name: "a", phase: p)
            XCTAssertEqual(AgentIsland.phaseText(o), t)
            XCTAssertTrue(o.isPhase && !o.isFinal && !o.isMaster, p)
        }
        XCTAssertNil(AgentIsland.phaseText(DchJSONLine(name: "a", phase: "waiting")), "an unknown phase shows nothing")
        // QA #452: a result is "result" with no "phase", or phase "master"; any other phase is progress.
        let odd = DchJSONLine(name: "a", phase: "pausing", result: "ok")
        XCTAssertTrue(odd.isPhase && !odd.isFinal && !odd.isMaster)
        XCTAssertEqual(AgentIsland.phaseText(odd), "Pausing…")
        XCTAssertFalse(DchJSONLine(name: "a", phase: "master").isMaster, "a master object always carries its result")
        let master = try XCTUnwrap(result(Fixture.restartOne).json.first)
        XCTAssertTrue(master.isMaster && !master.isPhase && !master.isFinal)
        XCTAssertNil(AgentIsland.phaseText(master), "the master object is the master pass's result, not a running text")
        XCTAssertNil(AgentIsland.phaseText(result(Fixture.stopNoSession).json[0]))
        for p in words.values { XCTAssertTrue(AgentIsland.runningTexts.contains(p)) }
    }

    /// A one-row job's text, from its last result for the row (real fixtures first).
    func testRowTextsFromTheResults() {
        func row(_ out: String, _ name: String, _ verb: AgentIsland.Verb, status: Int32 = 0) -> String {
            AgentIsland.rowText(result(out, status: status), name: name, verb)
        }
        XCTAssertEqual(row(Fixture.restartOne, "s1", .restart), "no claude runs in the session", "the agent's result, not the master's")
        XCTAssertEqual(row(Fixture.restartAgent, "a", .restart), "Restarted")
        XCTAssertEqual(row(Fixture.restartNoSession, "nosuch", .restart, status: 1), "no such session", "a master failure")
        XCTAssertEqual(row(Fixture.stopOne, "s1", .stop), "Stopped")
        XCTAssertEqual(row(Fixture.restartInShell, "a", .restart), "skipped — claude was started inside the session's shell, not as its command",
                       "1.24.1's in_shell skip: dch's detail")
        XCTAssertEqual(row(Fixture.stopInShell, "a", .stop), "Stopped", "1.24.1: pausing, ending, no exiting")
        XCTAssertEqual(row(Fixture.stopOldMaster, "a", .stop, status: 1), "NOT stopped — its master is older than dch 1.24.0")
        XCTAssertEqual(row(Fixture.stopNoSession, "nosuch", .stop, status: 1), "no such session")
        XCTAssertEqual(row(Fixture.stopInterrupted, "a", .stop, status: 1), "interrupted — resume message typed", "\"a: \" stripped")
        XCTAssertEqual(row(Fixture.reviveOne, "s1", .resume), "Resumed")
        XCTAssertEqual(row(Fixture.reviveAs, "s1", .resume), "Resumed as s1b")
        XCTAssertEqual(row(Fixture.reviveLite, "a", .resume), "Resumed (resume message not typed)", "dch-lite: ok no_screen")
        XCTAssertEqual(row(Fixture.reviveNoHistory, "nosuch", .resume, status: 1), "no history for this session")
        XCTAssertEqual(row(Fixture.reviveNotStarted, "s3", .resume, status: 1), "NOT revived — the session did not start")
        // No result for the row: the exit decides; L1's "dch: " line, else the code.
        XCTAssertEqual(row(#"{"name":"a","phase":"pausing"}"# + "\ndch: a: killed", "a", .stop, status: 1),
                       "Stop failed: dch: a: killed", "a phase is never the result")
        XCTAssertEqual(row("", "a", .restart, status: 1), "Restart failed (exit 1)")
        XCTAssertEqual(row(Fixture.stopOne, "other", .stop), "Stopped", "exit 0, nothing about the row")
        XCTAssertEqual(AgentIsland.rowText(result("", status: 143, stopped: true), name: "a", .stop), "Stop cancelled: no answer in 15m")
        XCTAssertEqual(AgentIsland.rowText(result("", status: 143, stopped: true), name: "a", .resume), "Resume cancelled: no answer in 5m")
        XCTAssertEqual(AgentIsland.finalText(DchJSONLine(name: "a", result: "failed", reason: "not_idle", detail: ""), .stop),
                       "Stop failed (not_idle)", "no detail: the reason")
    }

    func testRestartAllSummaryFromTheResults() {
        func sum(_ out: String, status: Int32 = 0) -> String { AgentIsland.restartAllSummary(result(out, status: status)) }
        XCTAssertEqual(sum(Fixture.restartAllCurrent), "all agents current", "not_claude and current are no skip")
        XCTAssertEqual(sum(Fixture.restartAllForced), "2 sessions restarted on dch 1.24.0",
                       "masters moved, no agent: not \"all agents current\", and no agent counted")
        XCTAssertEqual(sum(Fixture.restartAgent), "1 session restarted on dch 1.24.0, 1 agent restarted")
        XCTAssertEqual(sum(Fixture.restartAllCurrent + "\n" + """
            {"name":"p","result":"skipped","reason":"respawn_pending","detail":"p: skipped — a respawn is pending","session_id":""}
            """), "all agents current (1 skipped)")
        XCTAssertEqual(sum("""
            {"name":"a","phase":"pausing"}
            {"name":"b","phase":"pausing"}
            {"name":"a","result":"ok","reason":"","detail":"claude 2.0.1 -> 2.1.0, resumed abc","session_id":"abc"}
            {"name":"b","result":"failed","reason":"not_idle","detail":"b: NOT restarted — not idle within 600s","session_id":"def"}
            {"name":"c","result":"interrupted","reason":"signal","detail":"c: interrupted","session_id":""}
            """, status: 1), "1 agent restarted, 2 failed")
        XCTAssertEqual(sum(Fixture.restartNoSession, status: 1), "1 failed", "a master failure is a failure")
        XCTAssertEqual(sum(Fixture.restartInShell), "all agents current (1 skipped)", "in_shell is a skip")
        XCTAssertEqual(sum(Fixture.restartAgent + "\n" + Fixture.restartInShell),
                       "1 session restarted on dch 1.24.0, 1 agent restarted, 1 skipped")
        // QA #449 L1: exit 1 with no failed result still reads as failed.
        XCTAssertEqual(sum(Fixture.restartAgent + "\ndch: b: re-exec failed; still on dch 1.23.0", status: 1),
                       "1 session restarted on dch 1.24.0, 1 agent restarted, failed: dch: b: re-exec failed; still on dch 1.23.0")
        XCTAssertEqual(sum(Fixture.restartAllCurrent, status: 1), "Restart all failed (exit 1)")
        XCTAssertEqual(sum("dch: --restart: no sessions", status: 1), "Restart all failed: dch: --restart: no sessions")
        XCTAssertEqual(AgentIsland.restartAllSummary(result("", status: 15, stopped: true)), "Restart all cancelled: no answer in 15m")
    }

    func testResumeCrashedAndStopAllTallies() {
        func resume(_ out: String, status: Int32 = 0) -> String {
            AgentIsland.tally(result(out, status: status), .resume, title: "Resume", empty: "nothing to resume")
        }
        func stop(_ out: String, status: Int32 = 0) -> String {
            AgentIsland.tally(result(out, status: status), .stop, title: "Stop all", empty: "nothing stopped")
        }
        XCTAssertEqual(resume(""), "nothing to resume", "real: --revive --all --json with nothing to revive is empty, exit 0")
        XCTAssertEqual(resume(Fixture.reviveOne + "\n" + Fixture.reviveAs), "2 resumed")
        XCTAssertEqual(resume(Fixture.reviveOne + "\n" + Fixture.reviveNotStarted, status: 1), "1 resumed, 1 failed")
        XCTAssertEqual(resume("dch: cannot read history", status: 1), "Resume failed: dch: cannot read history")
        XCTAssertEqual(stop(Fixture.stopTwo), "3 stopped")
        XCTAssertEqual(stop(Fixture.stopOne + "\n" + Fixture.stopNoSession + "\n" + Fixture.stopInterrupted + "\n" + """
            {"name":"q","result":"skipped","reason":"no_screen","detail":"q: skipped — no_screen","session_id":""}
            """, status: 1), "1 stopped, 2 failed, 1 skipped")
        XCTAssertEqual(stop(Fixture.stopOne, status: 1), "1 stopped, failed (exit 1)", "L1: exit 1 with no failed result")
        XCTAssertEqual(stop("", status: 1), "Stop all failed (exit 1)")
        XCTAssertEqual(AgentIsland.tally(result("", stopped: true), .stop, title: "Stop all", empty: ""),
                       "Stop all cancelled: no answer in 15m")
    }

    /// --json on every long verb; Stop names sessions, never --all.
    func testLongVerbArgsCarryJSON() {
        XCTAssertEqual(AgentIsland.reviveArgs(record("a"), live: [], records: []), ["--revive", "a", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(record("a"), live: ["a"], records: []), ["--revive", "a", "--as", "a-2", "--json"])
        XCTAssertEqual(AgentIsland.reviveAllArgs, ["--revive", "--all", "--json"])
        XCTAssertEqual(AgentIsland.restartArgs("a"), ["--restart", "a", "--include-agents", "-f", "--json"], "a row restarts even when current")
        XCTAssertEqual(AgentIsland.restartAllArgs, ["--restart", "--all", "--include-agents", "--json"], "no -f: stale agents only")
        XCTAssertEqual(AgentIsland.stopArgs(["a", "b"]), ["--stop", "a", "b", "--json"])
    }

    /// #594 (QA #464 T7): Resume names dch's record, never the row's title (alias or agent name).
    func testReviveArgsUseTheDchNameNotTheTitle() {
        var r = record("dobby-main")
        r.alias = "A"
        r.agent = .init(name: "dobby-qa")
        XCTAssertEqual(r.title, "A")
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: [], records: []), ["--revive", "dobby-main", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: ["dobby-main", "A"], records: []),
                       ["--revive", "dobby-main", "--as", "dobby-main-2", "--json"], "--as from the name too")
        r.alias = ""
        XCTAssertEqual(r.title, "dobby-qa")
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: [], records: []), ["--revive", "dobby-main", "--json"])
    }

    /// --spawn has no --json: its exec failure's first stderr line, not dch's
    /// closing "failed to spawn session", is the text (real 1.24.0 output).
    func testSpawnFailureShowsTheExecLine() {
        let r = result(Fixture.spawnNotExecutable, status: 1)
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.text.count, 2, "both stderr lines")
        XCTAssertEqual(AgentIsland.spawnText(r, name: "s4"), "New session failed: dch: s4: /tmp/p/nonexistent-prog: No such file or directory")
        XCTAssertEqual(AgentIsland.spawnText(result("dch: s4: a\ndch: s4: b\ndch: failed to spawn session", status: 1), name: "s4"),
                       "New session failed: dch: s4: b", "the last line naming the session")
        XCTAssertEqual(AgentIsland.spawnText(result("dch: s40: x\ndch: failed to spawn session", status: 1), name: "s4"),
                       "New session failed: dch: failed to spawn session", "another name's line is not this one's")
        XCTAssertEqual(AgentIsland.spawnText(result("dch: session s4 exists", status: 1), name: "s4"), "New session failed: dch: session s4 exists")
        XCTAssertEqual(AgentIsland.spawnText(result("", status: 1), name: "s4"), "New session failed (exit 1)")
        XCTAssertNil(AgentIsland.spawnText(result("s4"), name: "s4"))
    }

    // MARK: - Control env (QA #445 M1)

    static let launchd = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/u", "DCH_SESSION": "s"]

    func testControlEnvHasTheUserPathFromTheProbeOrTheFallback() {
        let login = "/opt/homebrew/bin:/usr/bin:/bin"
        let probed = AgentIsland.controlEnv(dir: "/d", login: login, base: Self.launchd)
        XCTAssertEqual(probed["PATH"], "/opt/homebrew/bin:/usr/bin:/bin:/opt/homebrew/sbin:/usr/local/bin:/Users/u/.local/bin",
                       "the login order wins; missing well-known dirs follow")
        XCTAssertEqual(probed["DCH_SOCKET_DIR"], "/d")
        XCTAssertNil(probed["DCH_SESSION"])
        let fallback = AgentIsland.controlEnv(dir: "/d", login: nil, base: Self.launchd)
        XCTAssertEqual(fallback["PATH"],
                       "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/Users/u/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(LoginPath.path(login: nil, process: "/usr/local/bin:/usr/bin", home: "/h"),
                       "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/h/.local/bin:/usr/bin", "deduplicated")
    }

    func testMarkerParseIgnoresProfileNoise() {
        let m = LoginPath.marker
        XCTAssertEqual(LoginPath.parse("Agent pid 29033\nwelcome\(m)/a:/b\(m)bye\n"), "/a:/b")
        XCTAssertNil(LoginPath.parse("Agent pid 1\n/a:/b"))
        XCTAssertNil(LoginPath.parse("\(m)/a:/b"))
        XCTAssertNil(LoginPath.parse("\(m)\(m)"))
    }

    private final class Probes: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        var out: Data?
    }

    /// A timed-out probe (nil) means the fallback and no cache: the next use
    /// probes again. A parsed PATH is cached for the process.
    func testProbeTimeoutUsesTheFallbackAndOnlyAWorkingProbeIsCached() {
        let probes = Probes(), cache = LoginPath.Cache()
        let probe: LoginPath.Probe = { shell, script in
            probes.lock.withLock { probes.calls.append(shell); return probes.out }
        }
        XCTAssertNil(LoginPath.read(shell: "/bin/fish", cache: cache, probe: probe))
        XCTAssertTrue(AgentIsland.controlEnv(dir: "/d", login: nil, base: Self.launchd)["PATH"]!.hasPrefix("/opt/homebrew/bin:"))
        probes.lock.withLock { probes.out = Data("noise\(LoginPath.marker)/x:/y\(LoginPath.marker)".utf8) }
        XCTAssertEqual(LoginPath.read(shell: nil, cache: cache, probe: probe), "/x:/y")
        XCTAssertEqual(LoginPath.read(shell: "/bin/fish", cache: cache, probe: probe), "/x:/y")
        XCTAssertEqual(probes.lock.withLock { probes.calls }, ["/bin/fish", "/bin/zsh"], "retried once, then cached")
    }

    /// The default probe end to end against a fake shell (never a real login
    /// shell): it gets `-lc` and the script, and profile noise around it is dropped.
    func testShellProbeRunsTheScriptAndDropsNoise() throws {
        let shell = tempDir().appendingPathComponent("fakesh")
        try "#!/bin/sh\ntest \"$1\" = -lc || exit 1\necho \"Agent pid 1\"\nPATH=/p/q:/r /bin/sh -c \"$2\"\necho bye\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        XCTAssertEqual(LoginPath.read(shell: shell.path, cache: LoginPath.Cache()), "/p/q:/r")
    }

    func testResumeAllHelpNamesEveryAbnormalEnd() {
        for word in ["ended on a signal", "crashed", "exited with an error", "vanished", "3 days", "5 minutes"] {
            XCTAssertTrue(AgentIsland.resumeAllHelp.contains(word), word)
        }
        XCTAssertEqual(AgentIsland.resumeAllLabel(3), "Resume interrupted (3)")
        // #580/#585: dch's --revive --all never takes a closed (killed), stopped or exit 0 record.
        XCTAssertTrue(AgentIsland.resumeAllHelp.hasSuffix(
            "Closed, stopped and cleanly exited sessions come back only from their own row"))
    }

    // MARK: - Runner

    /// A fake process: records each launch, reports pid 4242 (or waits for
    /// `pidGate` first), then blocks until released. Signals are recorded and
    /// never end it, so a second one would show.
    private final class FakeProc: @unchecked Sendable {
        let lock = NSLock()
        var launches: [(path: String, args: [String], dir: String?, cwd: String?)] = []
        var envs: [[String: String]] = []
        var signals: [pid_t] = []
        var status: Int32 = 0
        var output = ""
        /// #579: printed once the pid is known, before the release (a restart's progress lines).
        var progress = ""
        let release = DispatchSemaphore(value: 0)
        var pidGate: DispatchSemaphore?
        let launched = DispatchSemaphore(value: 0)

        func runner(bound: TimeInterval = 60) -> DchActionRunner {
            DchActionRunner(bound: bound, launch: { path, args, env, cwd, onPid, onOutput in
                self.lock.withLock { self.launches.append((path, args, env["DCH_SOCKET_DIR"], cwd)); self.envs.append(env) }
                self.pidGate?.wait()
                onPid(4242)
                let early = self.lock.withLock { Data(self.progress.utf8) }
                if !early.isEmpty { onOutput(early) }
                self.launched.signal()
                self.release.wait()
                let out = self.lock.withLock { Data(self.output.utf8) }
                onOutput(out)
                return self.lock.withLock { (self.status, early + out) }
            }, signal: { pid in self.lock.withLock { self.signals.append(pid) } })
        }

        var args: [[String]] { lock.withLock { launches.map(\.args) } }
        var sent: [pid_t] { lock.withLock { signals } }
    }

    private final class Results: @unchecked Sendable {
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var all: [DchActionResult] = []
        func add(_ r: DchActionResult) { lock.withLock { all.append(r) }; done.signal() }
    }

    func testRunnerRefusesASecondVerbOnABusyRowAndAllExcludesItsDir() {
        let f = FakeProc(), runner = f.runner(), res = Results()
        let a = AgentSessionKey(dir: "/d", name: "a"), b = AgentSessionKey(dir: "/d", name: "b")
        let all = AgentSessionKey(dir: "/d", name: ""), other = AgentSessionKey(dir: "/e", name: "a")
        let go = { (k: AgentSessionKey) in runner.start(k, path: "/fake/dch", args: [k.name], env: { [:] }, done: res.add) }
        XCTAssertTrue(go(a))
        XCTAssertFalse(go(a), "busy: refused, never queued")
        XCTAssertTrue(go(b), "another row runs")
        XCTAssertFalse(go(all), "--all waits for no row: refused")
        XCTAssertTrue(go(other), "another dir is free")
        XCTAssertTrue(runner.isBusy(a))
        for _ in 0..<3 { f.release.signal() }
        for _ in 0..<3 { XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success) }
        XCTAssertFalse(runner.isBusy(a))
        XCTAssertTrue(go(all))
        XCTAssertFalse(go(a), "a row of a dir under --all is refused")
        XCTAssertTrue(go(other))
        f.release.signal(); f.release.signal()
        for _ in 0..<2 { XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.args.map { $0.joined() }.sorted(), ["", "a", "a", "a", "b"], "refused requests never launched")
        XCTAssertEqual(f.sent, [], "nothing was cancelled")
    }

    /// The bound expiring and two cancels send exactly one SIGTERM, then the
    /// runner waits for the process; it stays busy until it exits.
    func testCancelSendsExactlyOneSIGTERMThenWaits() {
        let f = FakeProc(), runner = f.runner(bound: 0.2), res = Results(), k = AgentSessionKey(dir: "/d", name: "a")
        f.status = 143
        f.output = "a: stopping\n"
        XCTAssertTrue(runner.start(k, path: "/fake/dch", args: ["--revive", "a"], env: { [:] }, done: res.add))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        runner.cancel(k)
        runner.cancel(k)
        Thread.sleep(forTimeInterval: 0.5)   // the bound has expired too
        XCTAssertEqual(f.sent, [4242], "one SIGTERM, to the recorded pid")
        XCTAssertTrue(runner.isBusy(k), "still waiting for it to exit")
        XCTAssertEqual(res.done.wait(timeout: .now() + 0.2), .timedOut, "no result before it exits")
        f.release.signal()
        XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(res.all, [DchActionResult(status: 143, text: ["a: stopping"], stopped: true)])
        runner.cancel(k)
        XCTAssertEqual(f.sent, [4242], "a reaped job is never signalled")
    }

    /// A job that finished before its bound: the bound's timer signals nothing
    /// (the pid is reaped and may belong to another process by then).
    func testAFinishedJobIsNeverSignalledByItsBound() {
        let f = FakeProc(), runner = f.runner(bound: 0.3), res = Results(), k = AgentSessionKey(dir: "/d", name: "a")
        XCTAssertTrue(runner.start(k, path: "/fake/dch", args: [], env: { [:] }, done: res.add))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        f.release.signal()
        XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success)
        Thread.sleep(forTimeInterval: 0.6)   // past the bound
        XCTAssertEqual(f.sent, [])
        XCTAssertEqual(res.all.map(\.stopped), [false])
    }

    /// Cancelled before the pid was known: the one SIGTERM goes when it is.
    func testCancelBeforeThePidIsKnownSignalsOnceItIs() {
        let f = FakeProc(), runner = f.runner(), res = Results(), k = AgentSessionKey(dir: "/d", name: "a")
        let gate = DispatchSemaphore(value: 0)
        f.pidGate = gate
        XCTAssertTrue(runner.start(k, path: "/fake/dch", args: [], env: { [:] }, done: res.add))
        runner.cancel(k)
        XCTAssertEqual(f.sent, [])
        gate.signal()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        runner.cancel(k)
        XCTAssertEqual(f.sent, [4242])
        f.release.signal()
        XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(res.all.map(\.stopped), [true])
    }

    /// The default launch with a real child (/bin/sh, never dch): stdout and
    /// stderr in one stream, the exit code, and one SIGTERM the child survives
    /// long enough to answer.
    func testDefaultLaunchMergesOutputAndTheBoundTermsTheChildOnce() {
        let res = Results()
        let fast = DchActionRunner()
        XCTAssertTrue(fast.start(AgentSessionKey(dir: "/d", name: "a"), path: "/bin/sh",
                                 args: ["-c", "echo 'a: revived'; echo 'dch: refused' >&2; exit 3"], env: { [:] }, done: res.add))
        XCTAssertEqual(res.done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(res.all, [DchActionResult(status: 3, text: ["a: revived", "dch: refused"])])
        let slow = DchActionRunner(bound: 2)   // room for sh to set its trap under load
        XCTAssertTrue(slow.start(AgentSessionKey(dir: "/d", name: "b"), path: "/bin/sh",
                                 args: ["-c", "trap 'echo got term; exit 7' TERM; echo started; while :; do /bin/sleep 0.1; done"],
                                 env: { [:] }, done: res.add))
        XCTAssertEqual(res.done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(res.all.last, DchActionResult(status: 7, text: ["started", "got term"], stopped: true),
                       "SIGTERM (not SIGKILL): the child's trap ran and its exit code came back")
    }

    // MARK: - Store and tabs

    @MainActor
    func testTabsShowForSidekicksOrHistoryAndHistoryOnlyWorks() {
        let store = AgentIslandStore(geometry: notched, sidekickPattern: "-qa")
        store.sessions = [session("a"), session("b")]
        XCTAssertFalse(store.showsTabs, "no sidekicks, no history")
        store.history = [record("x", ended: 1), record("y", ended: 2)]
        XCTAssertTrue(store.showsTabs, "history alone shows the tab row")
        XCTAssertEqual(store.visible.map(\.name), ["a", "b"], "Sessions until the History tab is chosen")
        XCTAssertEqual(store.shownHistory, [])
        store.historyTab = true
        XCTAssertEqual(store.visible, [], "no session rows under History")
        XCTAssertEqual(store.shownHistory.map(\.name), ["x", "y"])
        XCTAssertEqual(store.rowHeights, [AgentIslandGeometry.historyHeaderHeight, AgentIslandGeometry.rowHeight, AgentIslandGeometry.rowHeight])
        store.expanded = true
        XCTAssertEqual(store.size, notched.expandedSize(rows: store.rowHeights, tabs: true))
        store.history = (0..<60).map { record("r\($0)", ended: TimeInterval(1000 - $0)) }
        XCTAssertEqual(store.shownHistory.count, AgentIsland.historyCap)
        store.history = []
        XCTAssertFalse(store.historyTab, "history gone: back to Sessions")
        XCTAssertFalse(store.showsTabs)
        store.sessions = [session("a"), session("a-qa")]
        XCTAssertTrue(store.showsTabs, "sidekicks alone")
    }

    /// #585 L1: the count covers every record, past the shown historyCap.
    @MainActor
    func testResumableCountCoversRecordsPastTheCap() {
        let now: TimeInterval = 2_000_000_000
        let store = AgentIslandStore(geometry: notched)
        store.now = { now }
        store.sessions = [session("a", version: "1.24.0")]
        store.controlDch = Self.v124
        func rec(_ name: String, _ end: String) -> DchHistoryRecord {
            DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: name), started: now - 3600, updated: now - 60,
                             ended: now - 60, end: end)
        }
        store.history = (0..<AgentIsland.historyCap).map { rec("k\($0)", "killed") } + [rec("late", "signal 15")]
        store.historyTab = true
        XCTAssertEqual(store.shownHistory.count, AgentIsland.historyCap)
        XCTAssertEqual(store.resumableCount, 1)
        XCTAssertEqual(store.resumeAllButton, "Resume interrupted (1)")
    }

    @MainActor
    func testTabClicksMoveBetweenTheThreeTabs() {
        let c = AgentIslandController()
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: notched, sidekickPattern: "-qa")
        c.store?.sessions = [session("a"), session("a-qa")]
        c.showHistory()
        XCTAssertEqual(c.store?.historyTab, false, "no history: no History tab to show")
        c.store?.history = [record("x")]
        c.showHistory()
        XCTAssertEqual(c.store?.historyTab, true)
        c.showSidekicks(true)
        XCTAssertEqual(c.store?.historyTab, false)
        XCTAssertEqual(c.store?.visible.map(\.name), ["a-qa"])
        c.showHistory()
        c.showSidekicks(false)
        XCTAssertEqual(c.store?.visible.map(\.name), ["a"])
    }

    // MARK: - Controller

    private final class Reads: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(String, [String])] = []
        var records: [DchHistoryRecord] = []
        var count: Int { lock.withLock { calls.count } }
    }

    /// A panel-less controller whose history read, control binary and runner are fakes.
    @MainActor
    private func controller(_ f: FakeProc, _ reads: Reads, dch: DchCommand.Binary? = AgentIslandControlsTests.v1241,
                            dirs: [String] = ["/d"]) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        c.controlDch = { dch }
        c.readHistory = { path, dirs in reads.lock.withLock { reads.calls.append((path, dirs)); return reads.records } }
        c.historyDirs = { dirs }
        c.runner = f.runner()
        c.store = AgentIslandStore(geometry: notched)
        return c
    }

    @MainActor
    private func settle(_ c: AgentIslandController, until done: () -> Bool = { true }) {
        let end = Date().addingTimeInterval(5)
        repeat {
            c.queue.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while !done() && Date() < end
    }

    @MainActor
    func testHistoryIsReadOnOpenWithTheControlBinaryAndNeverOtherwise() {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads, dirs: ["/d", "/e"])
        c.store?.sessions = [session("a")]
        c.rowDetailsChanged()
        c.showSidekicks(false)
        c.refreshCards()
        settle(c)
        XCTAssertEqual(reads.count, 0, "closed: no read")
        c.setExpanded(true)
        settle(c) { c.store?.history.isEmpty == false }
        XCTAssertEqual(reads.calls.map(\.0), ["/fake/dch"])
        XCTAssertEqual(reads.calls.map(\.1), [["/d", "/e"]])
        XCTAssertEqual(c.store?.history, [record("x")])
        XCTAssertEqual(c.store?.controlDch, Self.v1241)
        c.setExpanded(false)
        settle(c)
        XCTAssertEqual(reads.count, 1, "closing reads nothing")
    }

    /// #585 L2: a History tab click re-reads history, so a session that ended
    /// while the island was open is counted.
    @MainActor
    func testHistoryTabClickRereadsHistory() {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads)
        c.store?.sessions = [session("a")]
        c.setExpanded(true)
        settle(c) { c.store?.history.isEmpty == false }
        XCTAssertEqual(reads.count, 1)
        reads.lock.withLock { reads.records = [record("x"), record("y")] }
        c.showHistory()
        settle(c) { c.store?.history.count == 2 }
        XCTAssertEqual(reads.count, 2, "the tab click read again")
        XCTAssertEqual(c.store?.history, [record("x"), record("y")])
    }

    /// The 1 s poll publishing sessions reads no history and runs no verb,
    /// closed or open (with history there for a stray --revive --all to take).
    @MainActor
    func testPollTicksNeverReadHistory() throws {
        let f = FakeProc(), reads = Reads(), dir = tempDir()
        reads.records = [record("x", dir: dir.path)]
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.sock").path, contents: nil)
        let c = controller(f, reads, dirs: [dir.path])
        c.store = nil
        c.center = NotificationCenter()
        c.touchFonts = {}
        let g = notched
        c.currentGeometry = { g }
        let path = dir.path
        c.makePoller = { Self.sockPoller(path) }
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        c.extLive = true
        c.reload()
        settle(c) { c.store?.sessions.isEmpty == false }
        XCTAssertEqual(c.store?.sessions.map(\.name), ["a"], "a tick published")
        settle(c)
        XCTAssertEqual(reads.count, 1, "#581: the launch read only, no history read on a tick")
        XCTAssertEqual(f.args, [])
        c.setExpanded(true)
        settle(c) { reads.count == 2 }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(c.store?.history.count, 1)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("b.sock").path, contents: nil)
        settle(c) { c.store?.sessions.count == 2 }   // the gate's 2 s floor, then a fetch
        XCTAssertEqual(c.store?.sessions.map(\.name).sorted(), ["a", "b"], "a second tick published while open")
        XCTAssertEqual(reads.count, 2, "the launch and open reads only")
        XCTAssertEqual(f.args, [], "no verb from a tick")
    }

    /// Nonisolated, so its closures are too: the poll queue calls them (a
    /// main-inferred closure called off main traps under Swift 6).
    /// Lists one idle session per `.sock` file in the dir.
    nonisolated private static func sockPoller(_ dir: String) -> AgentIslandPoller {
        AgentIslandPoller(dirs: { [dir] }, list: { dirs, _ in
            dirs.flatMap { d in
                ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".sock") }.map {
                    AgentSession(key: AgentSessionKey(dir: d, name: String($0.dropLast(5))), alias: "", activity: 0,
                                 state: .idle, agents: 0)
                }
            }
        })
    }

    /// An unstubbed controller under XCTest finds no control binary: expanding it
    /// (as AgentIslandTests' outside-click test does) runs no real dch.
    func testDefaultControlBinaryIsNoneUnderXCTest() async {
        let probe = await MainActor.run { AgentIslandController().controlDch }
        XCTAssertNil(probe())
    }

    @MainActor
    func testABinaryBelowTheMinimumReadsNoHistory() {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads, dch: DchCommand.Binary(path: "/old/dch", version: [1, 23, 0]))
        c.store?.sessions = [session("a")]
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil }
        XCTAssertEqual(reads.count, 0)
        XCTAssertEqual(c.store?.history, [])
        XCTAssertEqual(c.store?.showsTabs, false, "no History tab")
    }

    /// Opening, Settings changes, tab clicks and a row's Resume never run
    /// `--revive --all`; only the Resume interrupted click does, once per dir.
    @MainActor
    func testReviveAllRunsOnlyFromTheClick() {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x", dir: "/d"), record("y", dir: "/e")]
        let c = controller(f, reads, dirs: ["/d", "/e"])
        c.store?.sessions = [session("a")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        c.rowDetailsChanged()
        c.showHistory()
        c.showSidekicks(false)
        c.setExpanded(false)
        c.setExpanded(true)
        settle(c)
        c.resume(record("x", dir: "/d"))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "x", "--json"]], "nothing ran --all on its own")
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args.count, 2, "/d is busy with x: its --all is refused, /e runs")
        XCTAssertEqual(f.args.last, ["--revive", "--all", "--json"])
        XCTAssertEqual(f.lock.withLock { f.launches.last?.dir }, "/e", "with that dir's DCH_SOCKET_DIR")
        XCTAssertEqual(c.store?.actions[AgentSessionKey(dir: "/e", name: "")], AgentIsland.resumingText)
        f.release.signal(); f.release.signal()
        settle(c) { c.store?.actions.values.contains(AgentIsland.resumingText) == false }
        c.resumeCrashed()
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.args.suffix(2), [AgentIsland.reviveAllArgs, AgentIsland.reviveAllArgs], "one per dir with history")
        XCTAssertEqual(Set(f.lock.withLock { f.launches.suffix(2).compactMap(\.dir) }), ["/d", "/e"])
        f.release.signal(); f.release.signal()
        settle(c) { c.store?.actions.values.contains(AgentIsland.resumingText) == false }
    }

    /// QA #445 M1: a Resume runs with the controller's control env (the user's
    /// PATH), not listEnv's process env; under XCTest that env runs no login
    /// shell and leads with the fallback dirs.
    @MainActor
    func testResumeRunsWithTheControlEnv() {
        let f = FakeProc(), reads = Reads()
        let x = record("a")
        reads.records = [x]
        let c = controller(f, reads)
        let fallback = AgentIslandController().controlEnv("/d")["PATH"] ?? ""
        XCTAssertTrue(fallback.hasPrefix(LoginPath.wellKnown(home: NSHomeDirectory()).joined(separator: ":") + ":"), fallback)
        c.controlEnv = { ["PATH": "/login/bin", "DCH_SOCKET_DIR": $0] }
        c.store?.sessions = [session("b")]   // #581: an empty island does not open
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        c.resume(x)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.lock.withLock { f.envs }, [["PATH": "/login/bin", "DCH_SOCKET_DIR": "/d"]])
        f.release.signal()
        settle(c) { c.store?.actions[x.key] == nil }
    }

    /// A live name revives under the first free name; the row says "Resuming…"
    /// and refuses a second click; success clears it and re-reads the history.
    @MainActor
    func testResumeUsesAsForALiveNameAndRefusesABusyRow() {
        let f = FakeProc(), reads = Reads()
        let x = record("a"), taken = record("a-2", ended: 50)
        reads.records = [x, taken]
        let c = controller(f, reads)
        c.store?.sessions = [session("a"), session("a", dir: "/other")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        f.progress = #"{"name":"a","phase":"starting"}"# + "\n"
        c.resume(x)
        XCTAssertEqual(c.store?.historyActions[x.key], "Resuming…")
        XCTAssertNil(c.store?.actions[x.key], "#580: the live row a is another session: it says nothing")
        c.resume(x)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "a", "--as", "a-3", "--json"]], "one launch; a-2 is another record's name")
        XCTAssertEqual(f.lock.withLock { f.launches.map(\.path) }, ["/fake/dch"])
        settle(c) { c.store?.historyActions[x.key] == "Starting…" }
        XCTAssertEqual(c.store?.historyActions[x.key], "Starting…", "the phase line, as it comes")
        reads.records = [taken]   // revived under a new name: dch retired the old record
        f.output = #"{"name":"a","as":"a-3","result":"ok","reason":"","detail":"revived as a-3 in /src","session_id":""}"# + "\n"
        f.release.signal()
        settle(c) { c.store?.history == [taken] }
        XCTAssertEqual(reads.count, 2, "re-read after the action")
        XCTAssertNil(c.store?.historyActions[x.key], "the record is gone, and its status with it")
        XCTAssertNil(c.store?.actions[x.key], "never on the live row a")
    }

    @MainActor
    func testFailedResumeShowsTheLastLine() {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("a")]
        f.status = 1
        f.output = """
            {"name":"a","as":"a","result":"failed","reason":"no_history","detail":"no history for this session","session_id":""}
            dch: no history for session a

            """
        let c = controller(f, reads)
        c.store?.sessions = [session("b")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        c.resume(record("a"))
        f.release.signal()
        settle(c) { c.store?.historyActions[record("a").key] != AgentIsland.resumingText }
        XCTAssertEqual(c.store?.historyActions[record("a").key], "no history for this session", "dch's detail")
        c.setExpanded(false)
        XCTAssertEqual(c.store?.historyActions, [:], "closing drops finished statuses")
    }

    /// A master newer than the control binary: Resume and Resume interrupted are off, with the reason.
    @MainActor
    func testGateRefusalDisablesResume() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads)
        c.store?.sessions = [session("a", version: "1.25.0"), session("b", version: "")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        XCTAssertEqual(c.store?.resumeGate, .refused("needs dch 1.25.0"))
        c.resume(record("x"))
        c.resumeCrashed()
        XCTAssertEqual(f.args, [])
        XCTAssertEqual(c.store?.actions, [:])
        XCTAssertEqual(c.store?.historyActions, [:])
        let store = try XCTUnwrap(c.store)
        store.historyTab = true
        XCTAssertEqual(AgentIslandView(store: store).historyDrawn.map(\.enabled), [false])
        store.sessions = [session("a", version: "1.24.0")]
        XCTAssertEqual(AgentIslandView(store: store).historyDrawn.map(\.enabled), [true])
    }

    /// The drawn History rows carry their own record into Resume.
    @MainActor
    func testDrawnHistoryRowsCarryTheirRecord() {
        let store = AgentIslandStore(geometry: notched)
        store.sessions = [session("a")]
        store.controlDch = Self.v124
        store.history = [record("x", ended: 3), record("y", ended: 2)]
        store.historyTab = true
        var resumed: [String] = []
        let view = AgentIslandView(store: store, onResume: { resumed.append($0.name) })
        for r in view.historyDrawn { r.resume() }
        XCTAssertEqual(resumed, ["x", "y"])
    }

    /// Visual evidence: the History tab (with a running and a failed row), the
    /// gate's reason in place of Resume interrupted, and (#585) plain history
    /// with no header line. Offscreen only.
    @MainActor
    func testRendersHistoryTabOffscreen() throws {
        let now = Date().timeIntervalSince1970
        let store = AgentIslandStore(geometry: notched, details: AgentIslandRowDetails(), sidekickPattern: "-qa")
        store.sessions = [session("prosper-main", version: "1.24.0"), session("prosper-qa")]
        store.controlDch = Self.v124
        var a = record("prosper-main", ended: now - 120, end: "signal 9")
        a.alias = "Prosper"
        a.cwd = NSHomeDirectory() + "/personal/prosper"
        a.agent = .init(kind: "claude", name: "agent-island-578")
        var b = record("ios", ended: now - 7200, end: "exit 1")
        b.cwd = NSHomeDirectory() + "/personal/prosper-ios"
        let c = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "dch-build"), cwd: "/tmp", updated: now - 4000, end: "")
        let d = record("scratch", ended: now - 90000, end: "killed")
        var e = record("review", ended: now - 600, end: "stopped")   // #580
        e.cwd = NSHomeDirectory() + "/personal/prosper"
        store.history = [a, e, b, c, d]
        store.historyActions[b.key] = "session ios is live"
        store.historyActions[d.key] = "Starting…"
        store.actions[AgentSessionKey(dir: "/d", name: "")] = "nothing to resume"
        store.historyTab = true
        store.expanded = true
        let out = tempDir()
        func island(_ name: String) throws { try render(store, name, to: out) }
        try island("agent-island-history")
        store.sessions = [session("prosper-main", version: "1.25.0")]
        try island("agent-island-history-gated")
        // #585: nothing --revive --all would take and no status: no header line.
        store.sessions = [session("prosper-main", version: "1.24.0")]
        XCTAssertEqual(store.resumeAllButton, "Resume interrupted (3)", "a, b and c; not d (killed) or e (stopped)")
        var f = record("done", ended: now - 300, end: "exit 0")
        f.cwd = NSHomeDirectory() + "/personal/dch"
        // SIGTERM after 2 min: neutral words, and too short-lived for --all.
        let g = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "quick"), cwd: "/src", started: now - 1320,
                                 updated: now - 1200, ended: now - 1200, end: "signal 15")
        store.history = [e, f, g, d]
        store.actions = [:]
        store.historyActions = [:]
        XCTAssertFalse(store.showsHistoryHeader)
        try island("agent-island-history-plain")
        store.historyTab = false
        try island("agent-island-history-tab-sessions")
    }

    /// Offscreen PNG of the island into `out`, and into PROSPER_RENDER_DIR when set.
    @MainActor
    private func render(_ store: AgentIslandStore, _ name: String, to out: URL) throws {
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
        r.scale = 2
        let cg = try XCTUnwrap(r.cgImage)
        XCTAssertEqual(CGFloat(cg.height), (store.size.height + 40) * 2, "\(name): drawn = sized")
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("\(name).png"))
        if let extra { try png.write(to: extra.appendingPathComponent("\(name).png")) }
    }

    /// #594 (T8): the view hands store.details to both row kinds. Session name on vs
    /// off redraws a History row titled by its agent and a Sessions row titled by its
    /// alias. One render difference each, never two equal renders.
    @MainActor
    func testTheViewPassesItsDetailsToHistoryAndSessionsRows() throws {
        let now = Date().timeIntervalSince1970
        let store = AgentIslandStore(geometry: notched, details: AgentIslandRowDetails())
        store.sessions = [session("live")]
        store.controlDch = Self.v124
        var a = record("dobby-main", ended: now - 7200, end: "signal 9")
        a.agent = .init(name: "dobby-qa")
        store.history = [a]
        store.historyTab = true
        store.expanded = true
        func pixels() throws -> Data {
            let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
            r.scale = 1
            return try XCTUnwrap(try XCTUnwrap(r.cgImage).dataProvider?.data) as Data
        }
        let historyOff = try pixels()
        XCTAssertEqual(historyOff, try pixels(), "control: same input, same render")
        store.details.sessionName = true
        XCTAssertNotEqual(historyOff, try pixels(), "History row: the dch name drawn only with Session name on")
        store.details = AgentIslandRowDetails()
        store.historyTab = false
        store.sessions = [AgentSession(key: AgentSessionKey(dir: "/d", name: "dobby-main"), alias: "A", activity: now - 7200,
                                       state: .idle, agents: 0)]
        let sessionsOff = try pixels()
        XCTAssertEqual(sessionsOff, try pixels(), "control: same input, same render")
        store.details.sessionName = true
        XCTAssertNotEqual(sessionsOff, try pixels(), "Sessions row: the dch name drawn only with Session name on")
    }

    // MARK: - #581: the island with history and no live session

    /// A controller started like AppDelegate does (extLive + reload) over an
    /// empty socket dir; history goes through AgentIsland.history with a fake
    /// dch that records every argv.
    private final class Argvs: @unchecked Sendable {
        let lock = NSLock()
        var all: [[String]] = []
        var json = ""
    }

    @MainActor
    private func launched(_ f: FakeProc, _ argvs: Argvs, dir: URL) -> AgentIslandController {
        let c = controller(f, Reads(), dirs: [dir.path])
        c.readHistory = { _, dirs in
            AgentIsland.history(dirs: dirs) { args, _ in argvs.lock.withLock { argvs.all.append(args); return Data(argvs.json.utf8) } }
        }
        c.store = nil
        c.center = NotificationCenter()
        c.touchFonts = {}
        let g = notched
        c.currentGeometry = { g }
        let path = dir.path
        c.makePoller = { Self.sockPoller(path) }
        c.monitorClicks = { _ in NSObject() }   // a token, so a leaked monitor shows
        c.removeMonitor = { _ in }
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        return c
    }

    /// After a reboot: no live session, every record "vanished". The launch reads
    /// `--history --json` once, shows the collapsed island, and revives nothing.
    @MainActor
    func testLaunchReadShowsTheIslandWithHistoryAndNeverRevives() {
        let f = FakeProc(), argvs = Argvs(), dir = tempDir()
        argvs.json = #"[{"name":"a","updated":10,"ended":0,"end":"vanished"},{"name":"b","ended":20,"end":"signal 9"}]"#
        let c = launched(f, argvs, dir: dir)
        c.extLive = true
        c.reload()
        settle(c) { c.store?.history.count == 2 }
        XCTAssertEqual(argvs.lock.withLock { argvs.all }, [["--history", "--json"]], "one read, a read only")
        XCTAssertEqual(c.store?.sessions, [])
        XCTAssertTrue(c.shown, "history and no live session: the island shows")
        XCTAssertEqual(c.store?.expanded, false, "collapsed")
        Thread.sleep(forTimeInterval: 1.2)   // a poll tick or two
        settle(c)
        XCTAssertEqual(argvs.lock.withLock { argvs.all }, [["--history", "--json"]], "ticks read nothing")
        XCTAssertEqual(f.args, [], "no verb ran: never --revive at launch")
        c.reload()   // a screen change: same island, no second launch read
        settle(c)
        XCTAssertEqual(argvs.lock.withLock { argvs.all.count }, 1)
    }

    /// No history and no live session: hidden as before, and it cannot be opened.
    @MainActor
    func testNoHistoryAndNoSessionStaysHidden() {
        let f = FakeProc(), argvs = Argvs(), dir = tempDir()
        argvs.json = "[]"
        let c = launched(f, argvs, dir: dir)
        c.extLive = true
        c.reload()
        settle(c) { c.store?.controlDch != nil }   // the launch read landed
        XCTAssertEqual(argvs.lock.withLock { argvs.all.count }, 1)
        XCTAssertFalse(c.shown)
        c.setExpanded(true)
        XCTAssertEqual(c.store?.expanded, false, "nothing to show: no expand")
        XCTAssertNil(c.outsideClick)
    }

    /// The extension off: no store, no read, nothing shown; turning it off
    /// later hides an island that history was showing.
    @MainActor
    func testExtensionOffShowsNothing() {
        let f = FakeProc(), argvs = Argvs(), dir = tempDir()
        argvs.json = #"[{"name":"a","ended":20,"end":"signal 9"}]"#
        let c = launched(f, argvs, dir: dir)
        c.extLive = false
        c.reload()
        settle(c)
        XCTAssertNil(c.store)
        XCTAssertFalse(c.shown)
        XCTAssertEqual(argvs.lock.withLock { argvs.all.count }, 0, "off: no read")
        c.extLive = true
        c.reload()
        settle(c) { c.shown }
        XCTAssertTrue(c.shown)
        c.extLive = false
        c.reload()
        XCTAssertNil(c.store)
        XCTAssertFalse(c.shown, "off again: hidden")
    }

    /// Expanding with no live session opens on History; with one, on Sessions.
    @MainActor
    func testExpandLandsOnHistoryWhenNoSessionIsLive() {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads)
        c.store?.history = [record("x")]
        c.setExpanded(true)
        XCTAssertEqual(c.store?.expanded, true)
        XCTAssertEqual(c.store?.historyTab, true, "Sessions is empty: History")
        XCTAssertEqual(c.store?.visible, [])
        settle(c) { reads.count == 1 }
        c.setExpanded(false)
        c.store?.historyTab = false
        c.store?.sessions = [session("a")]
        c.setExpanded(true)
        XCTAssertEqual(c.store?.historyTab, false, "a live session: Sessions as before")
    }

    /// An open island never closes itself: history emptying with nothing live
    /// (a Resume's re-read landing before the revived session's tick) keeps it
    /// open on Sessions, and the tick's session shows there. Only the user
    /// collapses it; collapsed with nothing to show, it hides.
    @MainActor
    func testAnOpenIslandNeverClosesItself() throws {
        let f = FakeProc(), argvs = Argvs(), dir = tempDir()
        argvs.json = #"[{"name":"x","ended":20,"end":"signal 9"}]"#
        let c = launched(f, argvs, dir: dir)
        c.extLive = true
        c.reload()
        settle(c) { c.store?.history.isEmpty == false }
        XCTAssertEqual(c.store?.sessions, [])
        c.setExpanded(true)
        XCTAssertEqual(c.store?.historyTab, true)
        argvs.lock.withLock { argvs.json = "[]" }
        c.refreshHistory()   // as after the Resume of x
        settle(c) { c.store?.history.isEmpty == true }
        XCTAssertEqual(c.store?.expanded, true, "nothing to show, still open")
        XCTAssertTrue(c.shown)
        XCTAssertEqual(c.store?.historyTab, false, "history gone: back to Sessions")
        let sock = dir.appendingPathComponent("x.sock")
        FileManager.default.createFile(atPath: sock.path, contents: nil)
        settle(c) { c.store?.sessions.isEmpty == false }
        XCTAssertEqual(c.store?.visible.map(\.name), ["x"], "the revived session shows in the open list")
        XCTAssertEqual(c.store?.expanded, true)
        try FileManager.default.removeItem(at: sock)
        settle(c) { c.store?.sessions.isEmpty == true }
        settle(c)   // the edge read (still [])
        XCTAssertEqual(c.store?.expanded, true)
        XCTAssertTrue(c.shown)
        XCTAssertNotNil(c.outsideClick)
        c.setExpanded(false)
        XCTAssertFalse(c.shown, "collapsed with nothing to show: hidden")
        XCTAssertNil(c.outsideClick)
    }

    /// One history read when the live count reaches 0, none while it only
    /// drops or stays at 0: the ended session's record then keeps the island.
    @MainActor
    func testLastSessionEndingReadsHistoryOnce() throws {
        let f = FakeProc(), argvs = Argvs(), dir = tempDir()
        argvs.json = "[]"
        let a = dir.appendingPathComponent("a.sock"), b = dir.appendingPathComponent("b.sock")
        for s in [a, b] { FileManager.default.createFile(atPath: s.path, contents: nil) }
        let c = launched(f, argvs, dir: dir)
        let reads = { argvs.lock.withLock { argvs.all.count } }
        c.extLive = true
        c.reload()
        settle(c) { c.store?.sessions.count == 2 && c.store?.controlDch != nil }
        XCTAssertEqual(reads(), 1, "the launch read")
        try FileManager.default.removeItem(at: b)
        settle(c) { c.store?.sessions.count == 1 }
        settle(c)
        XCTAssertEqual(reads(), 1, "2 -> 1 live: no read")
        argvs.lock.withLock { argvs.json = #"[{"name":"a","ended":20,"end":"exit 0"}]"# }
        try FileManager.default.removeItem(at: a)
        settle(c) { c.store?.history.count == 1 }
        XCTAssertEqual(reads(), 2, "1 -> 0 live: one read")
        XCTAssertEqual(c.store?.sessions, [])
        XCTAssertTrue(c.shown, "its record keeps the island")
        Thread.sleep(forTimeInterval: 1.2)   // more ticks at 0 (an unchanged tick publishes nothing)
        settle(c)
        XCTAssertEqual(reads(), 2, "no read per tick at 0")
        XCTAssertEqual(f.args, [], "and never a verb")
    }

    /// Visual evidence: the history-only island, collapsed (dim 0, no glyph)
    /// and open on History. Offscreen only.
    @MainActor
    func testRendersHistoryOnlyIslandOffscreen() throws {
        let now = Date().timeIntervalSince1970
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = Self.v124
        var a = record("prosper-main", ended: 0, end: "vanished")
        a.updated = now - 300
        a.cwd = NSHomeDirectory() + "/personal/prosper"
        store.history = [a, record("ios", ended: now - 7200, end: "exit 1")]
        XCTAssertTrue(store.showsIsland)
        XCTAssertNil(store.summary.mostUrgent, "no urgency glyph")
        let out = tempDir()
        try render(store, "agent-island-history-only-collapsed", to: out)
        store.historyTab = true
        store.expanded = true
        try render(store, "agent-island-history-only-open", to: out)
    }

    // MARK: - QA #445 pins (Q9, Q8, Q13)

    /// L1 (Q9): the env closure runs on the job's thread, never on the caller's
    /// main thread, and start() does not wait for it.
    @MainActor
    func testRunnerBuildsTheEnvOnTheJobsThread() {
        final class Seen: @unchecked Sendable { let lock = NSLock(); var main: [Bool] = [] }
        let f = FakeProc(), runner = f.runner(), res = Results(), seen = Seen()
        XCTAssertTrue(Thread.isMainThread)
        let t0 = Date()
        XCTAssertTrue(runner.start(AgentSessionKey(dir: "/d", name: "a"), path: "/fake/dch", args: [], env: {
            seen.lock.withLock { seen.main.append(Thread.isMainThread) }
            Thread.sleep(forTimeInterval: 0.4)   // a slow login-shell probe
            return [:]
        }, done: res.add))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.3, "start returned before the env was built")
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        f.release.signal()
        XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(seen.lock.withLock { seen.main }, [false])
    }

    /// L2 (Q8): a relative or missing SHELL probes /bin/zsh; an absolute one is used.
    func testRelativeOrMissingShellProbesBinZsh() {
        let probes = Probes()
        let probe: LoginPath.Probe = { shell, _ in probes.lock.withLock { probes.calls.append(shell) }; return nil }
        XCTAssertNil(LoginPath.read(shell: "zsh", cache: .init(), probe: probe))
        XCTAssertNil(LoginPath.read(shell: nil, cache: .init(), probe: probe))
        XCTAssertNil(LoginPath.read(shell: "/opt/homebrew/bin/fish", cache: .init(), probe: probe))
        XCTAssertEqual(probes.lock.withLock { probes.calls }, ["/bin/zsh", "/bin/zsh", "/opt/homebrew/bin/fish"])
    }

    /// I1 (Q13): the --as pick skips only the same dir's record names; a record
    /// named a-2 in another dir leaves a-2 free here.
    @MainActor
    func testAsPickIgnoresAnotherDirsRecords() {
        let f = FakeProc(), reads = Reads()
        let x = record("a", dir: "/d")
        reads.records = [x]
        let c = controller(f, reads)
        c.store?.controlDch = Self.v124
        c.store?.sessions = [session("a", dir: "/d")]
        c.store?.history = [x, record("a-2", dir: "/e", ended: 50)]
        c.resume(x)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "a", "--as", "a-2", "--json"]])
        f.release.signal()
        settle(c) { c.store?.historyActions[x.key] != AgentIsland.resumingText }
    }

    // MARK: - #579: Restart agent, Restart all agents, New session

    /// dch's resume_argv rules: a new session never resumes a recorded conversation.
    func testStrippingResumeFollowsDchsRules() {
        func strip(_ s: String) -> String { AgentIsland.strippingResume(s.split(separator: " ").map(String.init)).joined(separator: " ") }
        XCTAssertEqual(strip("headroom wrap claude --resume sid --chrome"), "headroom wrap claude --chrome", "--resume and its id")
        XCTAssertEqual(strip("claude --resume --chrome"), "claude --chrome", "an optional value: a flag is not --resume's")
        XCTAssertEqual(strip("claude --resume"), "claude")
        XCTAssertEqual(strip("claude -r sid --chrome"), "claude --chrome")
        XCTAssertEqual(strip("claude -r -x"), "claude -x")
        XCTAssertEqual(strip("claude --session-id sid --chrome"), "claude --chrome")
        XCTAssertEqual(strip("claude --session-id --chrome"), "claude", "--session-id always takes the next token")
        XCTAssertEqual(strip("claude --resume=sid --session-id=x --chrome"), "claude --chrome", "the = forms drop as one token")
        XCTAssertEqual(strip("claude -c --continue --fork-session --model opus"), "claude --model opus", "these drop alone")
        XCTAssertEqual(strip("claude --chrome -- --resume sid -c"), "claude --chrome -- --resume sid -c", "the prompt after -- stays")
        XCTAssertEqual(strip("claude --resume sid -- -c"), "claude -- -c")
        XCTAssertEqual(strip("wrapper -c /usr/local/bin/claude --continue"), "wrapper -c /usr/local/bin/claude",
                       "only after the claude token")
        XCTAssertEqual(strip("agent --resume sid -v"), "agent -v", "no claude token: after argv[0]")
        XCTAssertEqual(AgentIsland.strippingResume([]), [])
    }

    /// argv defaults to a shell session: only then is agent.launch the typed
    /// line (a wrapper included). A session whose command is the wrapper records
    /// it as argv, and launch is the process below it (dch_agent_probe).
    private func agentRecord(_ name: String, dir: String = "/d", ended: TimeInterval, cwd: String, launch: [String],
                             argv: [String] = ["/bin/zsh"]) -> DchHistoryRecord {
        var r = record(name, dir: dir, ended: ended)
        r.cwd = "/ignored"
        r.argv = argv
        r.agent = .init(kind: "claude", cwd: cwd, launch: launch)
        return r
    }

    /// The newest launch for the folder, else the newest anywhere, else claude; stripped either way.
    func testLaunchPickPrefersTheFolderThenTheNewestThenClaude() {
        let history = [agentRecord("n", ended: 30, cwd: "/b", launch: ["claude", "--chrome", "--resume", "s3"]),
                       agentRecord("e", ended: 25, cwd: "/a", launch: []),
                       agentRecord("m", ended: 20, cwd: "/a", launch: ["headroom", "wrap", "claude", "--resume", "s2"]),
                       agentRecord("o", ended: 10, cwd: "/a", launch: ["old"])]
        XCTAssertEqual(AgentIsland.launchCommand(cwd: "/a", history: history), ["headroom", "wrap", "claude"],
                       "the folder's newest non-empty launch, without its --resume")
        XCTAssertEqual(AgentIsland.launchCommand(cwd: "/c", history: history), ["claude", "--chrome"], "the newest overall")
        XCTAssertEqual(AgentIsland.launchCommand(cwd: "/a", history: [record("x")]), ["claude"], "no agent launch: claude")
        // QA #449 M1: dch's revive_spawn choice per record.
        let wrapped = agentRecord("w", ended: 5, cwd: "/w", launch: ["/opt/homebrew/bin/claude", "--resume", "X", "--chrome"],
                                  argv: ["headroom", "wrap", "claude", "--resume", "X", "--chrome"])
        XCTAssertEqual(AgentIsland.launchCommand(cwd: "/w", history: [wrapped]), ["headroom", "wrap", "claude", "--chrome"],
                       "claude in the argv: the session's own command, wrapper kept")
        let shell = agentRecord("s", ended: 5, cwd: "/s", launch: ["headroom", "wrap", "claude", "--resume", "X"], argv: ["/bin/zsh"])
        XCTAssertEqual(AgentIsland.launchCommand(cwd: "/s", history: [shell]), ["headroom", "wrap", "claude"],
                       "a shell session: the typed launch")
        var noAgent = record("n", ended: 9)
        noAgent.argv = ["headroom", "wrap", "claude", "--x"]
        XCTAssertEqual(AgentIsland.launchCommand(cwd: "/src", history: [noAgent, shell]), ["headroom", "wrap", "claude"],
                       "a record with no agent is no source")
    }

    func testRecentFoldersAreDistinctAgentFoldersNewestFirstAtMostEight() {
        var history = [agentRecord("a", ended: 100, cwd: "/f0", launch: ["claude"]), record("plain", ended: 99),
                       agentRecord("b", ended: 98, cwd: "/f0", launch: ["claude"])]
        var noAgentCwd = agentRecord("c", ended: 97, cwd: "", launch: ["claude"])
        noAgentCwd.cwd = "/session-cwd"
        history.append(noAgentCwd)
        history += (1...10).map { agentRecord("r\($0)", ended: TimeInterval(90 - $0), cwd: "/f\($0)", launch: ["claude"]) }
        let all: (String) -> Bool = { _ in true }
        XCTAssertEqual(AgentIsland.recentFolders(history, exists: all), ["/f0", "/session-cwd", "/f1", "/f2", "/f3", "/f4", "/f5", "/f6"])
        XCTAssertEqual(AgentIsland.recentFolders(history, exists: { $0 != "/f1" }),
                       ["/f0", "/session-cwd", "/f2", "/f3", "/f4", "/f5", "/f6", "/f7"], "a missing folder is skipped, the next fills in")
        XCTAssertEqual(AgentIsland.recentFolders([record("plain")], exists: all), [], "only agent records")
        let real = tempDir().path
        XCTAssertEqual(AgentIsland.recentFolders([agentRecord("x", ended: 2, cwd: real + "/gone", launch: ["claude"]),
                                                  agentRecord("y", ended: 1, cwd: real, launch: ["claude"])]), [real],
                       "by default a folder that no longer exists is not offered")
    }

    func testSessionNameIsTheSanitizedBasenameFirstFree() {
        XCTAssertEqual(AgentIsland.sessionName(folder: "/Users/u/prosper"), "prosper")
        XCTAssertEqual(AgentIsland.sessionName(folder: "/Users/u/My Project!"), "My-Project")
        XCTAssertEqual(AgentIsland.sessionName(folder: "/x/--a  b.c_d"), "a-b.c_d", "no leading -: dch would read a flag")
        XCTAssertEqual(AgentIsland.sessionName(folder: "/x/.hidden"), "hidden")
        XCTAssertEqual(AgentIsland.sessionName(folder: "/x/café"), "caf")
        XCTAssertEqual(AgentIsland.sessionName(folder: "/x/ü"), "session")
        XCTAssertEqual(AgentIsland.sessionName(folder: "/"), "session")
        XCTAssertEqual(AgentIsland.freeName("app", taken: ["app", "app-2"]), "app-3")
        XCTAssertEqual(AgentIsland.freeName("app", taken: ["app-2"]), "app")
        XCTAssertEqual(AgentIsland.newSessionArgs(folder: "/src/app", history: [], taken: ["app"]), ["--spawn", "app-2", "claude"])
    }

    func testSpawnEnvDropsTheClaudeCodeIdentity() {
        let env = ["PATH": "/p", "DCH_SOCKET_DIR": "/d", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
                   "CLAUDE_CODE_SSE_PORT": "1", "CLAUDE_PID": "9", "CLAUDE_EFFORT": "high", "CLAUDE_CONFIG_DIR": "/c", "HOME": "/h"]
        XCTAssertEqual(AgentIsland.spawnEnv(env), ["PATH": "/p", "DCH_SOCKET_DIR": "/d", "CLAUDE_CONFIG_DIR": "/c", "HOME": "/h"])
    }

    /// QA #447 I3: history and no live session: the label says History is there.
    func testIslandLabelMentionsHistoryWithNoSession() {
        XCTAssertEqual(AgentIsland.islandAccessibilityLabel(AgentIsland.summary([]), history: 3), "Agent Island, no sessions, 3 in History")
        XCTAssertEqual(AgentIsland.islandAccessibilityLabel(AgentIsland.summary([]), history: 0), "Agent Island, no sessions")
        XCTAssertEqual(AgentIsland.islandAccessibilityLabel(AgentIsland.summary([session("a")]), history: 3), "Agent Island, 1 idle")
    }

    /// The default launch (/bin/sh, never dch) streams lines as they come, a
    /// UTF-8 character split across two writes whole, and runs in `cwd`.
    func testRunnerStreamsLinesAndRunsInTheCwd() throws {
        final class Lines: @unchecked Sendable { let lock = NSLock(); var all: [String] = [] }
        let lines = Lines(), res = Results(), runner = DchActionRunner()
        XCTAssertTrue(runner.start(AgentSessionKey(dir: "/d", name: "a"), path: "/bin/sh",
                                   args: ["-c", #"printf 'a: one\n\n  b: caf\303'; /bin/sleep 0.1; printf '\251 \342\200\224 ok\nlast'"#],
                                   env: { [:] }, onLine: { l in lines.lock.withLock { lines.all.append(l) } }, done: res.add))
        XCTAssertEqual(res.done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(lines.lock.withLock { lines.all }, ["a: one", "b: café — ok", "last"], "before done, trimmed, no empty line")
        XCTAssertEqual(res.all.last?.line, "last")
        let dir = tempDir()
        XCTAssertTrue(runner.start(AgentSessionKey(dir: "/d", name: "b"), path: "/bin/pwd", args: ["-P"], cwd: dir.path,
                                   env: { [:] }, done: res.add))
        XCTAssertEqual(res.done.wait(timeout: .now() + 10), .success)
        let pwd = try XCTUnwrap(res.all.last?.line)
        XCTAssertTrue(pwd.hasPrefix("/") && pwd.hasSuffix("/" + dir.lastPathComponent), pwd)
    }

    /// A job's own bound wins over the runner's.
    func testPerJobBoundOverridesTheRunners() {
        let f = FakeProc(), runner = f.runner(bound: 60), res = Results(), k = AgentSessionKey(dir: "/d", name: "a")
        XCTAssertTrue(runner.start(k, path: "/fake/dch", args: [], bound: 0.2, env: { [:] }, done: res.add))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(f.sent, [4242])
        f.release.signal()
        XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success)
    }

    /// A menu item's action through its own target (no NSApp under XCTest, and
    /// the menu is never shown). Ignores isEnabled: tests check that apart.
    @MainActor
    private func press(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        _ = (item.target as AnyObject?)?.perform(action, with: item)
    }

    /// An open controller whose gate is open (control binary read on open).
    @MainActor
    private func opened(_ f: FakeProc, _ sessions: [AgentSession], history: [DchHistoryRecord]? = nil,
                        dirs: [String] = ["/d"]) -> AgentIslandController {
        let history = history ?? [record("x")]
        let reads = Reads()
        reads.records = history
        let c = controller(f, reads, dirs: dirs)
        c.store?.sessions = sessions
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil && c.store?.history.count == history.count }
        return c
    }

    /// A row's Restart agent: -f and --json, the control env, "Restarting…",
    /// refused while busy, dch's phases as they come, then the row's agent result.
    @MainActor
    func testRowRestartRunsWithForceAndShowsDchsLine() throws {
        let f = FakeProc()
        let c = opened(f, [session("a"), session("b")])
        c.controlEnv = { ["PATH": "/login/bin", "DCH_SOCKET_DIR": $0, "CLAUDECODE": "1"] }
        let store = try XCTUnwrap(c.store)
        let row = try XCTUnwrap(AgentIslandView(store: store, onRestart: { c.restart($0) }).drawn.first { $0.session.name == "a" })
        XCTAssertNil(row.refused)
        f.progress = """
            {"name":"a","phase":"master","result":"ok","reason":"","detail":"restarted on dch 1.24.0","session_id":""}
            {"name":"a","phase":"pausing"}
            {"name":"b","phase":"exiting"}
            not json

            """
        row.restart()
        XCTAssertEqual(store.actions[row.session.key], AgentIsland.restartingText)
        c.restart(session("a"))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--restart", "a", "--include-agents", "-f", "--json"]], "one launch: a busy row refuses")
        XCTAssertEqual(f.lock.withLock { f.envs }, [["PATH": "/login/bin", "DCH_SOCKET_DIR": "/d", "CLAUDECODE": "1"]],
                       "the control env; the CLAUDE* strip is --spawn's only")
        XCTAssertNil(f.lock.withLock { f.launches[0].cwd })
        settle(c) { store.actions[row.session.key] == "Pausing…" }
        XCTAssertEqual(store.actions[row.session.key], "Pausing…", "the phase, not the master pass")
        XCTAssertNil(store.actions[AgentSessionKey(dir: "/d", name: "b")], "another name's line is not this row's")
        f.output = #"{"name":"a","result":"skipped","reason":"not_claude","detail":"no claude runs in the session","session_id":""}"# + "\n"
        f.release.signal()
        settle(c) { store.actions[row.session.key] != "Pausing…" }
        XCTAssertEqual(store.actions[row.session.key], "no claude runs in the session")
        c.refreshHistory()
        settle(c)
        XCTAssertNotNil(store.actions[row.session.key], "a history read keeps a live row's result")
    }

    /// Restart all only asks; Cancel runs nothing and drops the line.
    @MainActor
    func testRestartAllAsksFirstAndCancelRunsNothing() throws {
        let f = FakeProc()
        let c = opened(f, [session("a")])
        let store = try XCTUnwrap(c.store)
        let before = store.rowHeights
        let menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items[1].title, AgentIsland.restartAllLabel)
        press(menu.items[1])
        XCTAssertTrue(store.confirmingRestartAll)
        XCTAssertTrue(store.showsControlLine)
        XCTAssertEqual(store.rowHeights, [AgentIslandGeometry.historyHeaderHeight] + before, "the island grows by the line")
        settle(c)
        XCTAssertEqual(f.args, [], "asking runs nothing")
        c.confirmRestartAll(false)
        XCTAssertFalse(store.confirmingRestartAll)
        XCTAssertEqual(store.rowHeights, before)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "Cancel: no verb")
        c.confirmRestartAll(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "an answer with no question runs nothing")
        c.askRestartAll()
        c.setExpanded(false)
        XCTAssertFalse(store.confirmingRestartAll, "closing drops the question")
        XCTAssertEqual(f.args, [])
    }

    /// Confirmed: one job per dir with a live session, no -f. A row shows dch's
    /// phases once it reaches it, then its result; a row left on a phase is
    /// cleared; a skip with no phase leaves its row alone; the dir gets the summary.
    @MainActor
    func testRestartAllRunsPerDirWithoutForceAndReportsRows() throws {
        let f = FakeProc()
        let c = opened(f, [session("a"), session("b"), session("q"), session("p"), session("c", dir: "/e")], dirs: ["/d", "/e"])
        let store = try XCTUnwrap(c.store)
        f.progress = """
            {"name":"a","phase":"master","result":"skipped","reason":"current","detail":"already on dch 1.24.0","session_id":""}
            {"name":"a","phase":"pausing"}
            {"name":"b","phase":"pausing"}
            {"name":"zz","phase":"pausing"}

            """
        c.askRestartAll()
        c.confirmRestartAll(true)
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.args, [AgentIsland.restartAllArgs, AgentIsland.restartAllArgs])
        XCTAssertEqual(Set(f.lock.withLock { f.launches.compactMap(\.dir) }), ["/d", "/e"])
        let d = AgentSessionKey(dir: "/d", name: ""), a = AgentSessionKey(dir: "/d", name: "a")
        XCTAssertEqual(store.actions[d], AgentIsland.restartAllRunningText)
        settle(c) { store.actions[a] == "Pausing…" }
        XCTAssertEqual(store.actions[a], "Pausing…")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "b")], "Pausing…")
        XCTAssertNil(store.actions[AgentSessionKey(dir: "/d", name: "q")], "not reached: no running text")
        XCTAssertNil(store.actions[AgentSessionKey(dir: "/d", name: "zz")], "not a live row")
        c.restart(session("q"))
        XCTAssertEqual(f.args.count, 2, "a row of a dir under Restart all is refused")
        c.stop(session("q", version: "1.24.0"))
        XCTAssertEqual(f.args.count, 2, "so is its Stop")
        XCTAssertTrue(store.showsControlLine, "the dir status shows over the Sessions rows")
        f.output = """
            {"name":"a","result":"ok","reason":"","detail":"claude 2.0.1 -> 2.1.0, resumed abc","session_id":"abc"}
            {"name":"q","result":"skipped","reason":"not_claude","detail":"no claude runs in the session","session_id":""}
            {"name":"p","result":"failed","reason":"no_record","detail":"p: NOT restarted — no claude session record","session_id":""}

            """
        f.release.signal(); f.release.signal()
        settle(c) { store.actions[d] != AgentIsland.restartAllRunningText && store.actions[AgentSessionKey(dir: "/e", name: "")] != AgentIsland.restartAllRunningText }
        XCTAssertEqual(store.actions[a], "Restarted")
        XCTAssertNil(store.actions[AgentSessionKey(dir: "/d", name: "b")], "no stale Pausing…")
        XCTAssertNil(store.actions[AgentSessionKey(dir: "/d", name: "q")], "a not_claude skip with no phase: the row says nothing")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "p")], "NOT restarted — no claude session record", "a failure always shows")
        XCTAssertEqual(store.actions[d], "1 agent restarted, 1 failed")
        XCTAssertEqual(store.dirStatus, "1 agent restarted, 1 failed · 1 agent restarted, 1 failed")
    }

    /// New session: --spawn <free name> [stripped launch], the Process cwd is the
    /// folder, the env is the control env minus the Claude Code identity.
    @MainActor
    func testNewSessionSpawnsInTheFolderWithAStrippedEnv() throws {
        let f = FakeProc()
        let argv = ["/opt/homebrew/bin/headroom", "wrap", "claude", "--resume", "sid", "--chrome"]
        let app = tempDir().appendingPathComponent("app").path, gone = tempDir().appendingPathComponent("gone").path
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        let c = opened(f, [session("app")], history: [agentRecord("old", ended: 6, cwd: gone, launch: ["claude"]),
                                                     agentRecord("app-2", ended: 5, cwd: app,
                                                                 launch: ["/opt/homebrew/bin/claude", "--resume", "sid", "--chrome"], argv: argv)])
        c.controlEnv = { ["PATH": "/login/bin", "DCH_SOCKET_DIR": $0, "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
                          "CLAUDE_PID": "9", "CLAUDE_EFFORT": "high", "CLAUDE_CONFIG_DIR": "/c"] }
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(store.controlsMenu, .init(recent: [app], refused: nil), "the deleted folder is left out")
        let sub = try XCTUnwrap(c.makeControlsMenu().items.first?.submenu)
        XCTAssertEqual(sub.items.map(\.title), [(app as NSString).abbreviatingWithTildeInPath, "", AgentIsland.chooseFolderLabel])
        press(sub.items[0])
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--spawn", "app-3", "/opt/homebrew/bin/headroom", "wrap", "claude", "--chrome"]],
                       "app is live and app-2 a record: app-3; no --resume")
        XCTAssertEqual(f.lock.withLock { f.launches[0].cwd }, app)
        XCTAssertEqual(f.lock.withLock { f.envs }, [["PATH": "/login/bin", "DCH_SOCKET_DIR": "/d", "CLAUDE_CONFIG_DIR": "/c"]])
        f.status = 1
        f.output = "dch: app-3: headroom: No such file or directory\ndch: failed to spawn session\n"   // #580: real 1.24.0 shape
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != nil }
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], "New session failed: dch: app-3: headroom: No such file or directory")
        XCTAssertNil(store.actions[AgentSessionKey(dir: "/d", name: "app-3")])
    }

    /// "Choose folder…" goes through the seam (never a real panel); cancel spawns nothing.
    @MainActor
    func testChooseFolderGoesThroughTheSeam() throws {
        let f = FakeProc()
        let c = opened(f, [session("a")])
        var answer: String? = nil, asked = 0
        c.chooseFolder = { done in asked += 1; done(answer) }
        c.chooseNewSessionFolder()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(c.store?.expanded, false, "the island collapses for the panel")
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "cancelled: nothing spawns")
        answer = "/picked/My Repo"
        let sub = try XCTUnwrap(c.makeControlsMenu().items.first?.submenu)
        XCTAssertEqual(sub.items.map(\.title), [AgentIsland.chooseFolderLabel], "no agent history: the chooser only")
        press(sub.items[0])
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--spawn", "My-Repo", "claude"]])
        XCTAssertEqual(f.lock.withLock { f.launches[0].cwd }, "/picked/My Repo")
        f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "My-Repo")) }
    }

    /// A master newer than the control binary: every #579 verb is off, with the reason.
    @MainActor
    func testGateRefusalDisablesRestartAndNewSession() throws {
        let f = FakeProc()
        let c = opened(f, [session("a", version: "1.25.0")])
        let store = try XCTUnwrap(c.store)
        c.chooseFolder = { _ in XCTFail("no chooser while refused") }
        c.restart(session("a"))
        c.askRestartAll()
        c.newSession(in: "/src")
        c.chooseNewSessionFolder()
        XCTAssertFalse(store.confirmingRestartAll)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [])
        XCTAssertEqual(store.actions, [:])
        c.stop(session("a", version: "1.25.0"))
        c.askStopAll()
        XCTAssertFalse(store.confirmingStopAll)
        XCTAssertEqual(f.args, [], "#580: Stop and Stop all too")
        XCTAssertEqual(store.controlsMenu.refused, "needs dch 1.25.0")
        XCTAssertEqual(AgentIslandView(store: store).drawn.map(\.refused), ["needs dch 1.25.0"])
        let menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items.map(\.title), [AgentIsland.newSessionLabel, AgentIsland.restartAllLabel, "Stop all in Sessions…",
                                                 "", "Controls needs dch 1.25.0"])
        XCTAssertEqual(menu.items.map(\.isEnabled), [false, false, false, false, false], "off, with the reason under them")
        press(menu.items[1])
        press(menu.items[2])
        XCTAssertFalse(store.confirmingRestartAll, "the action re-checks the gate")
        XCTAssertFalse(store.confirmingStopAll)
        store.sessions = [session("a", version: "1.24.0")]
        XCTAssertNil(store.controlsMenu.refused)
        XCTAssertEqual(AgentIslandView(store: store).drawn.map(\.refused), [nil])
        XCTAssertEqual(c.makeControlsMenu().items.map(\.isEnabled), [true, true, true])
    }

    /// #580 addendum 2: a 1.24.0 control dch types /exit into a shell that ran
    /// claude by hand, so Restart agent, Restart all and Stop / Stop all are off
    /// below 1.24.1 and say so; Resume and New session stay on at 1.24.0. On a
    /// row whose master is old, the dch hint is the one Stop shows.
    @MainActor
    func testRestartAndStopNeedDch1241AndResumeDoesNot() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads, dch: Self.v124)
        c.store?.sessions = [session("a", version: "1.24.0"), session("old", version: "1.23.0")]
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil && c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        XCTAssertNil(store.resumeGate.refusal)
        XCTAssertEqual(store.restartNeeds, "needs dch 1.24.1")
        let drawn = AgentIslandView(store: store, onRestart: { c.restart($0) }, onStop: { c.stop($0) }).drawn
        XCTAssertEqual(drawn.map(\.restartTitle), ["Restart agent (needs dch 1.24.1)", "Restart agent (needs dch 1.24.1)"])
        XCTAssertEqual(drawn.map(\.stopTitle), ["Stop (needs dch 1.24.1)", "Stop (needs dch 1.24.1)"],
                       "one hint: the dch one wins over \"restart this session first\"")
        XCTAssertEqual(drawn.map(\.restartEnabled) + drawn.map(\.stopEnabled), [false, false, false, false])
        let menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items.map(\.title), [AgentIsland.newSessionLabel, "Restart all agents (needs dch 1.24.1)",
                                                 "Stop all in Sessions… (needs dch 1.24.1)"])
        XCTAssertEqual(menu.items.map(\.isEnabled), [true, false, false])
        drawn[0].restart()
        drawn[0].stop()
        c.askRestartAll()
        c.askStopAll()
        XCTAssertFalse(store.confirmingRestartAll || store.confirmingStopAll)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "no restart or stop under 1.24.0")
        c.resume(record("x"))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "x", "--json"]], "Resume is on at 1.24.0")
        f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "x")) }

        store.controlDch = Self.v1241
        XCTAssertNil(store.restartNeeds)
        let on = AgentIslandView(store: store, onRestart: { c.restart($0) }).drawn
        XCTAssertEqual(on.map(\.restartTitle), [AgentIsland.restartLabel, AgentIsland.restartLabel])
        XCTAssertEqual(on.map(\.stopTitle), [AgentIsland.stopLabel, AgentIsland.stopOldMasterLabel])
        XCTAssertEqual(on.map(\.restartEnabled) + on.map(\.stopEnabled), [true, true, true, false])
        XCTAssertEqual(c.makeControlsMenu().items.map(\.title), [AgentIsland.newSessionLabel, AgentIsland.restartAllLabel,
                                                                 "Stop all in Sessions…"])
        XCTAssertEqual(c.makeControlsMenu().items.map(\.isEnabled), [true, true, true])
        on[0].restart()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args.last, AgentIsland.restartArgs("a"), "on at 1.24.1")
        f.release.signal()
        settle(c) { !c.runner.isBusy(drawn[0].session.key) }
    }

    /// The header "⋯" pops the menu through the seam (never a real one here).
    @MainActor
    func testControlsButtonPopsTheMenuThroughTheSeam() {
        let f = FakeProc()
        let c = opened(f, [session("a")])
        var shown: [[String]] = []
        c.popUpMenu = { shown.append($0.items.map(\.title)) }
        c.showControlsMenu()
        XCTAssertEqual(shown, [[AgentIsland.newSessionLabel, AgentIsland.restartAllLabel, "Stop all in Sessions…"]])
        XCTAssertEqual(f.args, [])
    }

    /// History only, nothing live: Restart all would reach no session, so it is
    /// off (and asking does nothing); New session stays on.
    @MainActor
    func testRestartAllIsOffWithNoLiveSession() throws {
        let f = FakeProc()
        let reads = Reads()
        reads.records = [agentRecord("a", ended: 5, cwd: "/src/a", launch: ["claude"])]
        let c = controller(f, reads)
        let store = try XCTUnwrap(c.store)
        c.refreshHistory()  // nothing live: the island shows once the history is in
        settle(c) { store.controlDch != nil && !store.history.isEmpty }
        c.setExpanded(true)
        XCTAssertNil(store.controlsMenu.refused)
        let menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items.map(\.title), [AgentIsland.newSessionLabel, AgentIsland.restartAllLabel, "Stop all in Sessions…"])
        XCTAssertEqual(menu.items.map(\.isEnabled), [true, false, false], "nothing live: nothing to stop")
        c.askRestartAll()
        XCTAssertFalse(store.confirmingRestartAll)
        XCTAssertEqual(f.args, [])
    }

    /// Visual evidence: the header "⋯", the inline Restart all question, and a
    /// row showing "Restarting…" with a dir summary line. Offscreen only.
    @MainActor
    func testRendersSessionControlsOffscreen() throws {
        let store = AgentIslandStore(geometry: notched, details: AgentIslandRowDetails())
        store.sessions = [session("prosper-main", version: "1.24.0"), session("ios"), session("dch-build")]
        store.controlDch = Self.v1241
        store.expanded = true
        let out = tempDir()
        try render(store, "agent-island-579-header-menu", to: out)
        store.confirmingRestartAll = true
        try render(store, "agent-island-579-confirm", to: out)
        store.confirmingRestartAll = false
        store.actions[AgentSessionKey(dir: "/d", name: "prosper-main")] = AgentIsland.restartingText
        store.actions[AgentSessionKey(dir: "/d", name: "ios")] = "Restarted"
        store.actions[AgentSessionKey(dir: "/d", name: "")] = AgentIsland.restartAllRunningText
        try render(store, "agent-island-579-restarting", to: out)
    }

    // MARK: - #580: Stop and Stop all

    /// A row's Stop: only on a 1.24.0+ master; `--stop <name> --json`; phases as
    /// they come; refused while the row runs a job; the result, then one History read.
    @MainActor
    func testRowStopRunsByNameOnANewMasterAndReReadsHistory() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads)
        c.store?.sessions = [session("a", version: "1.24.0"), session("old", version: "1.23.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        let drawn = AgentIslandView(store: store, onStop: { c.stop($0) }).drawn
        XCTAssertEqual(drawn.map(\.canStop), [true, false], "the old master's item reads \"restart this session first\"")
        drawn[1].stop()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "an old master never stops")
        XCTAssertEqual(store.actions, [:])
        f.progress = #"{"name":"a","phase":"pausing"}"# + "\n"
        drawn[0].stop()
        XCTAssertEqual(store.actions[drawn[0].session.key], AgentIsland.stoppingText)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        c.stop(drawn[0].session)
        c.restart(drawn[0].session)
        XCTAssertEqual(f.args, [["--stop", "a", "--json"]], "one long verb per session: the second Stop and the Restart are refused")
        settle(c) { store.actions[drawn[0].session.key] == "Pausing…" }
        XCTAssertEqual(store.actions[drawn[0].session.key], "Pausing…")
        let before = reads.count
        f.status = 1
        f.output = #"{"name":"a","result":"failed","reason":"not_idle","detail":"a: NOT stopped — claude did not go idle; resume message typed","session_id":""}"# + "\n"
        f.release.signal()
        settle(c) { reads.count > before }
        XCTAssertEqual(store.actions[drawn[0].session.key], "NOT stopped — claude did not go idle; resume message typed")
        XCTAssertEqual(reads.count, before + 1, "one History read after the stop")
    }

    /// Stop all in <tab>: the shown tab's sessions whose master can stop, by
    /// name and per dir, never --all; asks first on the inline line (Cancel runs
    /// nothing); refused while the dir runs a job; the dir gets the tally.
    @MainActor
    func testStopAllNamesTheShownTabsEligibleSessions() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        // The control binary is newer than every master (the gate's other rule).
        let c = controller(f, reads, dch: DchCommand.Binary(path: "/fake/dch", version: [1, 100, 0]), dirs: ["/d", "/e"])
        c.store?.sidekickPattern = "-qa"
        c.store?.sessions = [session("main", version: "1.24.0"), session("legacy", version: "1.23.0"),
                             session("x-qa", version: "1.24.1"), session("y-qa", version: ""),
                             session("z-qa", dir: "/e", version: "1.100.0")]
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil && c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(store.stopAllTargets.stop.map(\.name), ["main"])
        XCTAssertEqual(store.stopAllTargets.skipped, 1)
        var menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items[2].title, "Stop all in Sessions…")
        XCTAssertTrue(menu.items[2].isEnabled)
        c.askRestartAll()
        press(menu.items[2])
        XCTAssertTrue(store.confirmingStopAll)
        XCTAssertFalse(store.confirmingRestartAll, "one question at a time")
        XCTAssertTrue(store.showsControlLine)
        XCTAssertEqual(AgentIsland.stopAllQuestion(1, skipped: 1), "Stop 1 session? 1 on an old dch skipped.")
        XCTAssertEqual(AgentIsland.stopAllQuestion(3, skipped: 0), "Stop 3 sessions?")
        c.confirmStopAll(false)
        XCTAssertFalse(store.confirmingStopAll)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "Cancel: no verb")
        c.showSidekicks(true)
        menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items[2].title, "Stop all in Sidekicks…")
        f.progress = #"{"name":"x-qa","phase":"ending"}"# + "\n"
        press(menu.items[2])
        c.confirmStopAll(true)
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(Set(f.args), [["--stop", "x-qa", "--json"], ["--stop", "z-qa", "--json"]],
                       "the shown tab only, by name, the old and the unknown master left out")
        XCTAssertFalse(f.args.joined().contains("--all"), "never --all")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: f.lock.withLock { f.launches.map { ($0.args[1], $0.dir ?? "") } }),
                       ["x-qa": "/d", "z-qa": "/e"], "each with its dir's DCH_SOCKET_DIR")
        let xq = AgentSessionKey(dir: "/d", name: "x-qa"), zq = AgentSessionKey(dir: "/e", name: "z-qa")
        XCTAssertEqual(store.actions[zq], AgentIsland.stoppingText)
        settle(c) { store.actions[xq] == "Ending…" }
        XCTAssertEqual(store.actions[xq], "Ending…")
        XCTAssertNil(store.actions[AgentSessionKey(dir: "/d", name: "y-qa")], "not asked to stop")
        c.stop(session("x-qa", version: "1.24.1"))
        c.askStopAll()
        c.confirmStopAll(true)
        settle(c)
        XCTAssertEqual(f.args.count, 2, "a running Stop all refuses its rows and a second Stop all")
        let before = reads.count
        f.output = """
            {"name":"x-qa","result":"ok","reason":"","detail":"","session_id":"abc"}
            {"name":"z-qa","result":"skipped","reason":"no_screen","detail":"z-qa: skipped — no_screen","session_id":""}

            """
        f.release.signal(); f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/e", name: "")] != AgentIsland.stoppingText
            && store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.stoppingText && reads.count >= before + 2 }
        XCTAssertEqual(store.actions[xq], "Stopped")
        XCTAssertEqual(store.actions[zq], "skipped — no_screen")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], "1 stopped, 1 skipped")
        XCTAssertEqual(reads.count, before + 2, "one History read per finished job")
    }

    /// No session in the shown tab can stop: the item is off and asking does nothing.
    @MainActor
    func testStopAllIsOffWithNoEligibleSession() throws {
        let f = FakeProc()
        let c = opened(f, [session("a", version: "1.23.0"), session("b", version: "")])
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(store.stopAllTargets.stop, [])
        XCTAssertEqual(store.stopAllTargets.skipped, 2)
        let item = c.makeControlsMenu().items[2]
        XCTAssertEqual(item.title, "Stop all in Sessions…")
        XCTAssertFalse(item.isEnabled)
        c.askStopAll()
        XCTAssertFalse(store.confirmingStopAll)
        c.confirmStopAll(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [])
    }

    /// Resume interrupted: --revive --all --json; a phase or result lands on its
    /// History row, never on a live row of that name; empty stdout + exit 0
    /// reads "nothing to resume".
    @MainActor
    func testResumeCrashedShowsRowsAndNothingToResume() throws {
        let f = FakeProc(), reads = Reads()
        let x = record("x")
        reads.records = [x]
        let c = controller(f, reads)
        c.store?.sessions = [session("x", version: "1.24.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        f.progress = #"{"name":"x","phase":"starting"}"# + "\n"
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "--all", "--json"]])
        settle(c) { store.historyActions[x.key] == "Starting…" }
        XCTAssertEqual(store.historyActions[x.key], "Starting…")
        XCTAssertNil(store.actions[x.key], "the live x is another session")
        f.output = #"{"name":"x","as":"x-2","result":"ok","reason":"","detail":"revived as x-2 in /src","session_id":""}"# + "\n"
        f.release.signal()
        let all = AgentSessionKey(dir: "/d", name: "")
        settle(c) { store.actions[all] != AgentIsland.resumingText }
        XCTAssertEqual(store.actions[all], "1 resumed")
        XCTAssertEqual(store.historyActions[x.key], "Resumed as x-2")
        f.progress = ""
        f.output = ""
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        f.release.signal()
        settle(c) { store.actions[all] != AgentIsland.resumingText }
        XCTAssertEqual(store.actions[all], "nothing to resume")
    }

    /// Visual evidence: the inline Stop all question, and rows with a Stop
    /// running, failed and a Stop all tally. Offscreen only.
    @MainActor
    func testRendersStopControlsOffscreen() throws {
        let store = AgentIslandStore(geometry: notched, details: AgentIslandRowDetails())
        store.sessions = [session("prosper-main", version: "1.24.0"), session("ios", version: "1.24.0"),
                          session("dch-build", version: "1.23.0")]
        store.controlDch = Self.v1241
        store.expanded = true
        let out = tempDir()
        store.confirmingStopAll = true
        try render(store, "agent-island-580-stop-confirm", to: out)
        store.confirmingStopAll = false
        store.actions[AgentSessionKey(dir: "/d", name: "prosper-main")] = "Pausing…"
        store.actions[AgentSessionKey(dir: "/d", name: "ios")] = "NOT stopped — claude did not go idle; resume message typed"
        store.actions[AgentSessionKey(dir: "/d", name: "")] = "1 stopped, 1 failed"
        try render(store, "agent-island-580-stop-results", to: out)
    }
}
