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
        XCTAssertEqual(AgentIsland.restartAllForceArgs, ["--restart", "--all", "--include-agents", "-f", "--json"], "#700: -f")
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

    /// #744 (QA #572 INFO-1): a Kill runs beside its row's or its dir's Stop or Restart
    /// (`yields`), never beside another job or a second Kill; while it runs no other job
    /// starts on its row or its dir.
    func testRunnerKillRunsBesideAStopOrRestartOnly() {
        let f = FakeProc(), runner = f.runner(), res = Results()
        let k = { (dir: String, name: String) in AgentSessionKey(dir: dir, name: name) }
        let go = { (key: AgentSessionKey, yields: Bool, kill: Bool) in
            runner.start(key, path: "/fake/dch", args: [key.name], yields: yields, kill: kill, env: { [:] }, done: res.add)
        }
        XCTAssertTrue(go(k("/d", "a"), true, false), "a Stop on a")
        XCTAssertTrue(go(k("/d", "a"), false, true), "a Kill beside it")
        XCTAssertFalse(go(k("/d", "a"), false, true), "never a second Kill")
        XCTAssertTrue(go(k("/d", "b"), false, true), "a Kill on an idle row")
        XCTAssertTrue(runner.isBusy(k("/d", "b")))
        XCTAssertFalse(go(k("/d", "b"), true, false), "no job starts on a row being killed")
        XCTAssertFalse(go(k("/d", ""), true, false), "nor on its dir")
        XCTAssertTrue(go(k("/d", "c"), false, false), "another job (a phone verb) on c")
        XCTAssertFalse(go(k("/d", "c"), false, true), "no Kill beside it")
        XCTAssertTrue(go(k("/e", ""), true, false), "a Stop all on /e")
        XCTAssertTrue(go(k("/e", "x"), false, true), "a Kill beside a dir's Stop all")
        XCTAssertTrue(go(k("/f", ""), false, false), "a Clear on /f")
        XCTAssertFalse(go(k("/f", "x"), false, true), "no Kill beside it")
        XCTAssertFalse(runner.hasJob(k("/d", "")), "rows' jobs are not the dir's own")
        XCTAssertTrue(runner.hasJob(k("/e", "")))
        for _ in 0..<7 { f.release.signal() }
        for _ in 0..<7 { XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success) }
        XCTAssertTrue(go(k("/d", "b"), false, false), "free again once the Kill is back")
        f.release.signal()
        XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success)
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

    /// #672: the bound is an idle bound. A job that writes a line every bound/2
    /// runs past 2x the bound unsignalled; a silent one gets its one SIGTERM at it.
    func testTheBoundIsAnIdleBoundThatOutputRestarts() {
        let bound: TimeInterval = 0.6, res = Results(), sent = Results()
        let release = DispatchSemaphore(value: 0)
        let runner = DchActionRunner(bound: bound, launch: { _, args, _, _, onPid, onOutput in
            onPid(4242)
            if args == ["talk"] {
                for i in 0..<5 {   // 1.5 s, 2.5x the bound
                    Thread.sleep(forTimeInterval: bound / 2)
                    onOutput(Data("a: step \(i)\n".utf8))
                }
            } else {
                release.wait()
            }
            return (0, Data())
        }, signal: { _ in sent.add(DchActionResult(status: 15, text: [])) })
        let start = Date()
        XCTAssertTrue(runner.start(AgentSessionKey(dir: "/d", name: "a"), path: "/fake/dch", args: ["talk"],
                                   env: { [:] }, done: res.add))
        XCTAssertEqual(res.done.wait(timeout: .now() + 10), .success)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 2 * bound)
        XCTAssertEqual(sent.all, [], "output kept restarting the bound")
        XCTAssertEqual(res.all.map(\.stopped), [false])

        let quiet = AgentSessionKey(dir: "/d", name: "b"), t0 = Date()
        XCTAssertTrue(runner.start(quiet, path: "/fake/dch", args: ["quiet"], env: { [:] }, done: res.add))
        XCTAssertEqual(sent.done.wait(timeout: .now() + 10), .success, "a silent job is signalled")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), bound * 0.9, "not before the bound")
        XCTAssertLessThan(Date().timeIntervalSince(t0), bound * 1.8, "at the bound, not after a second silence")
        XCTAssertEqual(sent.done.wait(timeout: .now() + 2 * bound), .timedOut, "exactly one SIGTERM")
        release.signal()
        XCTAssertEqual(res.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(res.all.map(\.stopped), [false, true])
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
        addTeardownBlock { @MainActor in Self.drainNewSessionCommand(c) }
        return c
    }

    /// #657: an inferred New session command is stored on main after a queue hop.
    /// A test that returns without settling (none does today) would have it land
    /// after its own reset, in the next test. Teardown drains the queue, then main
    /// past the write, and only then unsets it. Bounded: a blocked queue fails the
    /// test instead of hanging the run.
    @MainActor
    private static func drainNewSessionCommand(_ c: AgentIslandController) {
        let queued = DispatchSemaphore(value: 0)
        c.queue.async { queued.signal() }
        guard queued.wait(timeout: .now() + 10) == .success else {
            return XCTFail("#657: the controller's queue did not drain in 10 s")
        }
        // Posted only now, so it runs after the write the queue block posted (main is FIFO).
        nonisolated(unsafe) var drained = false
        DispatchQueue.main.async { drained = true }
        let end = Date().addingTimeInterval(10)
        while !drained && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if !drained { XCTFail("#657: main did not drain in 10 s") }
        Preferences.agentIslandNewSessionCommand = ""
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

    /// #606: a live session's record first, else the newest history record
    /// overall (never per folder), else nil (claude, not stored); stripped.
    func testInferredCommandPrefersLiveThenNewestHistoryThenNone() {
        let history = [agentRecord("n", ended: 30, cwd: "/b", launch: ["claude", "--chrome", "--resume", "s3"]),
                       agentRecord("e", ended: 25, cwd: "/a", launch: []),
                       agentRecord("m", ended: 20, cwd: "/a", launch: ["headroom", "wrap", "claude", "--resume", "s2"])]
        XCTAssertEqual(AgentIsland.inferredCommand(live: [], history: history), ["claude", "--chrome"],
                       "the newest history record overall, without its --resume")
        XCTAssertEqual(AgentIsland.inferredCommand(live: [], history: Array(history.dropFirst())), ["headroom", "wrap", "claude"],
                       "an empty launch is no source: the next record")
        var live = agentRecord("l", ended: 0, cwd: "/z", launch: ["/opt/homebrew/bin/claude", "--continue"],
                               argv: ["headroom", "wrap", "claude", "--chrome", "--continue"])
        live.end = ""
        XCTAssertEqual(AgentIsland.inferredCommand(live: [live], history: history), ["headroom", "wrap", "claude", "--chrome"],
                       "a live session's record wins over history")
        XCTAssertEqual(AgentIsland.inferredCommand(live: [record("plain", end: "")], history: history), ["claude", "--chrome"],
                       "a live record with no agent is no source")
        XCTAssertNil(AgentIsland.inferredCommand(live: [], history: [record("x")]), "no agent anywhere: no source")
        XCTAssertNil(AgentIsland.inferredCommand(live: [], history: []))
        // QA #449 M1: dch's revive_spawn choice per record.
        let wrapped = agentRecord("w", ended: 5, cwd: "/w", launch: ["/opt/homebrew/bin/claude", "--resume", "X", "--chrome"],
                                  argv: ["headroom", "wrap", "claude", "--resume", "X", "--chrome"])
        XCTAssertEqual(AgentIsland.inferredCommand(live: [], history: [wrapped]), ["headroom", "wrap", "claude", "--chrome"],
                       "claude in the argv: the session's own command, wrapper kept")
        let shell = agentRecord("s", ended: 5, cwd: "/s", launch: ["headroom", "wrap", "claude", "--resume", "X"], argv: ["/bin/zsh"])
        XCTAssertEqual(AgentIsland.inferredCommand(live: [], history: [shell]), ["headroom", "wrap", "claude"],
                       "a shell session: the typed launch")
        var noAgent = record("n", ended: 9)
        noAgent.argv = ["headroom", "wrap", "claude", "--x"]
        XCTAssertEqual(AgentIsland.inferredCommand(live: [], history: [noAgent, shell]), ["headroom", "wrap", "claude"],
                       "a record with no agent is no source")
    }

    /// #606: shell words, quote-aware, no expansion; shellLine reads back exactly.
    func testShellWordsSplitQuoteAwareWithNoExpansion() {
        XCTAssertEqual(AgentIsland.shellWords("headroom wrap claude --chrome"), ["headroom", "wrap", "claude", "--chrome"])
        XCTAssertEqual(AgentIsland.shellWords("  claude\t  --x \n"), ["claude", "--x"], "any whitespace run separates")
        XCTAssertEqual(AgentIsland.shellWords("claude --append-system-prompt 'be brief' \"a \\\"b\\\" c\""),
                       ["claude", "--append-system-prompt", "be brief", "a \"b\" c"])
        XCTAssertEqual(AgentIsland.shellWords("a'b c'd \"\" '' e\\ f"), ["ab cd", "", "", "e f"], "quotes join, empty words count")
        XCTAssertEqual(AgentIsland.shellWords("'it'\\''s' \"x\\y\""), ["it's", "x\\y"], "a backslash in \"\" only escapes \" and \\")
        XCTAssertEqual(AgentIsland.shellWords("claude ~/x $HOME *.swift"), ["claude", "~/x", "$HOME", "*.swift"], "no expansion")
        XCTAssertEqual(AgentIsland.shellWords("claude 'open"), ["claude", "open"], "an unclosed quote runs to the end")
        XCTAssertEqual(AgentIsland.shellWords("   "), [])
        XCTAssertEqual(AgentIsland.shellWords(""), [])
        for argv in [["/opt/homebrew/bin/headroom", "wrap", "claude", "--chrome"], ["claude", "it's", "a b", "", "$X", "\"q\"", "x\\y"]] {
            XCTAssertEqual(AgentIsland.shellWords(AgentIsland.shellLine(argv)), argv)
        }
        XCTAssertEqual(AgentIsland.shellLine(["headroom", "wrap", "claude", "--chrome"]), "headroom wrap claude --chrome")
    }

    /// #606: stored trimmed; empty (or blank) removes the key: unset again.
    @MainActor
    func testNewSessionCommandPreferenceTrimsAndEmptyUnsets() {
        defer { Preferences.agentIslandNewSessionCommand = "" }
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "", "unset by default")
        Preferences.agentIslandNewSessionCommand = "  headroom wrap claude --chrome \n"
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "headroom wrap claude --chrome")
        Preferences.agentIslandNewSessionCommand = " \t "
        XCTAssertNil(Preferences.defaults.object(forKey: "agentIslandNewSessionCommand"), "blank: the key is gone")
        XCTAssertEqual(AgentIslandPane.commit(" headroom wrap claude --chrome "), "headroom wrap claude --chrome",
                       "the field's commit stores trimmed and shows what was stored")
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "headroom wrap claude --chrome")
        XCTAssertEqual(AgentIslandPane.commit(""), "")
        XCTAssertNil(Preferences.defaults.object(forKey: "agentIslandNewSessionCommand"), "cleared: unset")
    }

    /// #606 visual evidence: the pane with the operator's command at UI scale
    /// 0.7, 0.85 and 1.0. Offscreen only (a windowless hosting view).
    @MainActor
    func testRendersNewSessionCommandFieldOffscreen() throws {
        defer { Preferences.agentIslandNewSessionCommand = "" }
        Preferences.agentIslandNewSessionCommand = "headroom wrap claude --chrome"
        let out = tempDir()
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            let width = sz(560)
            let h = NSHostingView(rootView: AgentIslandPane().frame(width: width).padding(sz(16))
                .background(Color(white: 0.1)).preferredColorScheme(.dark))
            h.frame = CGRect(origin: .zero, size: CGSize(width: width + 2 * sz(16), height: 10))
            h.frame.size = h.fittingSize
            h.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            h.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
            h.cacheDisplay(in: h.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("settings-new-session-\(scale).png"))
            if let extra { try png.write(to: extra.appendingPathComponent("settings-new-session-\(scale).png")) }
        }
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "headroom wrap claude --chrome", "showing it changes nothing")
    }

    /// #606: a live session's dch record, at dch's documented path; only a
    /// running record, ours and closed to others; newest activity first.
    func testLiveRecordsReadDchsRecordOfEachLiveSession() throws {
        let state = tempDir().path, dir = "/tmp/dch-test"
        let recs = state + "/dch/sessions/-tmp-dch-test"
        try FileManager.default.createDirectory(atPath: recs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func put(_ name: String, end: String, argv: String = "[\"headroom\",\"wrap\",\"claude\"]", mode: Int = 0o600) throws {
            let body = "{\"name\":\"\(name)\",\"sock_dir\":\"\(dir)\",\"cwd\":\"/src\",\"argv\":\(argv),\"started\":1,"
                + "\"updated\":2,\"ended\":0,\"end\":\"\(end)\",\"agent\":{\"kind\":\"claude\",\"session_id\":\"s\","
                + "\"name\":\"\",\"cwd\":\"/src\",\"launch\":[\"claude\"]}}\n"
            let path = recs + "/\(name).json"
            try Data(body.utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        try put("old", end: "")
        try put("new", end: "", argv: "[\"claude\",\"--chrome\"]")
        try put("ended", end: "exit 0")
        try put("open", end: "", mode: 0o620)
        try put("world", end: "", mode: 0o602)
        try FileManager.default.createSymbolicLink(atPath: recs + "/link.json", withDestinationPath: recs + "/new.json")
        func live(_ name: String, _ activity: TimeInterval) -> AgentSession {
            AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: "", activity: activity, state: .idle, agents: 1)
        }
        let sessions = [live("old", 1), live("ended", 9), live("open", 8), live("none", 7), live("link", 6), live("world", 6), live("new", 5)]
        let got = AgentIsland.liveRecords(sessions, env: ["XDG_STATE_HOME": state, "HOME": "/nonexistent"])
        XCTAssertEqual(got.map(\.name), ["new", "old"], "newest first; no ended, group- or world-writable, symlinked or missing record")
        XCTAssertEqual(got.map(\.argv), [["claude", "--chrome"], ["headroom", "wrap", "claude"]])
        XCTAssertEqual(AgentIsland.inferredCommand(live: got, history: []), ["claude", "--chrome"])
        let home = tempDir().path
        try FileManager.default.createDirectory(atPath: home + "/.local", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.local/state", withDestinationPath: state)
        XCTAssertEqual(AgentIsland.liveRecords(sessions, env: ["XDG_STATE_HOME": "rel", "HOME": home]).map(\.name), ["new", "old"],
                       "a relative XDG_STATE_HOME: ~/.local/state")
    }

    /// #608: as dch's hrec_load, a record of another socket dir sharing the slug
    /// (/tmp/dch/test vs /tmp/dch-test) or without sock_dir is not this session's,
    /// and one over 1 MB is not read.
    func testLiveRecordsRefuseAnotherSockDirAndOverOneMB() throws {
        let state = tempDir().path, dir = "/tmp/dch-test", recs = state + "/dch/sessions/-tmp-dch-test"
        try FileManager.default.createDirectory(atPath: recs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func put(_ name: String, sockDir: String? = "/tmp/dch-test", size: Int = 0) throws {
            let head = "{\"name\":\"\(name)\"," + (sockDir.map { "\"sock_dir\":\"\($0)\"," } ?? "")
                + "\"cwd\":\"/src\",\"argv\":[\"claude\"],\"end\":\"\",\"pad\":\""
            let body = head + String(repeating: "x", count: max(0, size - head.utf8.count - 3)) + "\"}\n"
            try Data(body.utf8).write(to: URL(fileURLWithPath: recs + "/\(name).json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recs + "/\(name).json")
        }
        try put("own")
        try put("other", sockDir: "/tmp/dch/test")
        try put("none", sockDir: nil)
        try put("mb", size: 1 << 20)
        try put("over", size: (1 << 20) + 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: recs + "/mb.json")[.size] as? Int, 1 << 20)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: recs + "/over.json")[.size] as? Int, (1 << 20) + 1)
        let sessions = ["own", "other", "none", "mb", "over"].enumerated().map { i, n in
            AgentSession(key: AgentSessionKey(dir: dir, name: n), alias: "", activity: TimeInterval(9 - i), state: .idle, agents: 1)
        }
        XCTAssertEqual(AgentIsland.liveRecords(sessions, env: ["XDG_STATE_HOME": state]).map(\.name), ["own", "mb"])
    }

    /// QA #482 I3: every record opened is closed, refused or read: ~50 reads over
    /// a 0o602 record, a symlink, another sock_dir, one over 1 MB and one accepted
    /// leave /dev/fd as it was (within a few unrelated fds).
    func testLiveRecordsLeakNoFd() throws {
        let state = tempDir().path, dir = "/tmp/dch-test", recs = state + "/dch/sessions/-tmp-dch-test"
        try FileManager.default.createDirectory(atPath: recs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func put(_ name: String, sockDir: String = dir, size: Int = 0, mode: Int = 0o600) throws {
            let head = "{\"name\":\"\(name)\",\"sock_dir\":\"\(sockDir)\",\"cwd\":\"/src\",\"argv\":[\"claude\"],\"end\":\"\",\"pad\":\""
            let body = head + String(repeating: "x", count: max(0, size - head.utf8.count - 3)) + "\"}\n"
            try Data(body.utf8).write(to: URL(fileURLWithPath: recs + "/\(name).json"))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: recs + "/\(name).json")
        }
        try put("own")
        try put("world", mode: 0o602)
        try put("other", sockDir: "/tmp/dch/test")
        try put("over", size: (1 << 20) + 1)
        try FileManager.default.createSymbolicLink(atPath: recs + "/link.json", withDestinationPath: recs + "/own.json")
        let sessions = ["own", "world", "other", "over", "link"].enumerated().map { i, n in
            AgentSession(key: AgentSessionKey(dir: dir, name: n), alias: "", activity: TimeInterval(9 - i), state: .idle, agents: 1)
        }
        func read() -> [String] { AgentIsland.liveRecords(sessions, env: ["XDG_STATE_HOME": state]).map(\.name) }
        func fds() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
        XCTAssertEqual(read(), ["own"])   // warm: anything opened once and kept is in `before`
        let before = try fds()
        for _ in 0..<50 { XCTAssertEqual(read(), ["own"]) }
        // A leak is 4 per read (about 200); slack for an unrelated thread's fd.
        XCTAssertLessThan(try fds() - before, 10, "no fd left open by a refused or an accepted record")
    }

    /// #608: as dch_history_dir, the records dir (and dch/, sessions/ above it)
    /// must be a real dir, ours and closed to others, or no record is read.
    func testLiveRecordsNeedTheirDirsOursAndClosed() throws {
        let state = tempDir().path, dirs = ["/dch", "/dch/sessions", "/dch/sessions/-tmp-dch-test"].map { state + $0 }
        try FileManager.default.createDirectory(atPath: dirs[2], withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let body = "{\"name\":\"a\",\"sock_dir\":\"/tmp/dch-test\",\"cwd\":\"/src\",\"argv\":[\"claude\"],\"end\":\"\"}\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: dirs[2] + "/a.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dirs[2] + "/a.json")
        let a = [AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: "a"), alias: "", activity: 1, state: .idle, agents: 1)]
        func names() -> [String] { AgentIsland.liveRecords(a, env: ["XDG_STATE_HOME": state]).map(\.name) }
        XCTAssertEqual(names(), ["a"])
        for d in dirs {
            for mode in [0o775, 0o757] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: d)
                XCTAssertEqual(names(), [], "\(d) at \(String(mode, radix: 8))")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d)
            XCTAssertEqual(names(), ["a"])
        }
        let real = state + "/real"
        try FileManager.default.moveItem(atPath: dirs[2], toPath: real)
        try FileManager.default.createSymbolicLink(atPath: dirs[2], withDestinationPath: real)
        XCTAssertEqual(names(), [], "a symlinked records dir")
    }

    /// #608: the stat rule of dirs and records: the type, our uid, no group or other write.
    func testIsOursNeedsTypeUidAndNoGroupOrOtherWrite() {
        func st(_ mode: mode_t, uid: uid_t = getuid()) -> stat {
            var s = stat()
            s.st_mode = mode
            s.st_uid = uid
            return s
        }
        XCTAssertTrue(AgentIsland.isOurs(st(S_IFREG | 0o644), type: S_IFREG))
        XCTAssertTrue(AgentIsland.isOurs(st(S_IFDIR | 0o755), type: S_IFDIR))
        XCTAssertFalse(AgentIsland.isOurs(st(S_IFDIR | 0o700), type: S_IFREG), "a dir for a record")
        XCTAssertFalse(AgentIsland.isOurs(st(S_IFIFO | 0o600), type: S_IFREG), "a fifo")
        XCTAssertFalse(AgentIsland.isOurs(st(S_IFREG | 0o600, uid: getuid() + 1), type: S_IFREG), "another uid")
        XCTAssertFalse(AgentIsland.isOurs(st(S_IFREG | 0o620), type: S_IFREG), "group-writable")
        XCTAssertFalse(AgentIsland.isOurs(st(S_IFREG | 0o602), type: S_IFREG), "world-writable")
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
        XCTAssertEqual(AgentIsland.newSessionArgs(folder: "/src/app", command: ["claude"], taken: ["app"]), ["--spawn", "app-2", "claude"])
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

    /// #700: Restart all agents (force) asks its own question; it and the stale
    /// one never show together; Cancel runs nothing; closing drops it.
    @MainActor
    func testRestartAllForceAsksItsOwnQuestionAndCancelRunsNothing() throws {
        let f = FakeProc()
        let c = opened(f, [session("a")])
        let store = try XCTUnwrap(c.store)
        let menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items.map(\.title), ["New session", "Restart stale agents", "Restart all agents (force)", "Stop all in Sessions…",
                                                 "Stop all…", "Kill all in Sessions…", "Kill all…"])
        press(menu.items[1])
        XCTAssertTrue(store.confirmingRestartAll)
        XCTAssertFalse(store.restartAllForce, "the stale question")
        press(menu.items[2])
        XCTAssertTrue(store.confirmingRestartAll)
        XCTAssertTrue(store.restartAllForce, "the forced question replaces the stale one")
        XCTAssertTrue(store.showsControlLine)
        XCTAssertEqual(AgentIsland.restartAllForceQuestion, "Restart every agent, busy ones too? Each pauses for up to minutes.")
        press(menu.items[1])
        XCTAssertFalse(store.restartAllForce, "and back: one restart question at a time")
        press(menu.items[2])
        c.confirmRestartAll(false)
        XCTAssertFalse(store.confirmingRestartAll)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "Cancel: no verb")
        c.confirmRestartAll(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "an answer with no question runs nothing")
        press(menu.items[2])
        c.setExpanded(false)
        XCTAssertFalse(store.confirmingRestartAll, "closing drops the question")
        XCTAssertEqual(f.args, [])
    }

    /// #700: confirmed, the forced item runs -f once per dir with a live session;
    /// the dir shows its own running text (a dir under it refuses a row's verb), then the summary.
    @MainActor
    func testRestartAllForceRunsPerDirWithForce() throws {
        let f = FakeProc()
        let c = opened(f, [session("a"), session("q"), session("c", dir: "/e")], dirs: ["/d", "/e"])
        let store = try XCTUnwrap(c.store)
        f.progress = #"{"name":"a","phase":"pausing"}"# + "\n"
        press(c.makeControlsMenu().items[2])
        c.confirmRestartAll(true)
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.args, [AgentIsland.restartAllForceArgs, AgentIsland.restartAllForceArgs])
        XCTAssertEqual(Set(f.lock.withLock { f.launches.compactMap(\.dir) }), ["/d", "/e"])
        let d = AgentSessionKey(dir: "/d", name: ""), e = AgentSessionKey(dir: "/e", name: ""), a = AgentSessionKey(dir: "/d", name: "a")
        XCTAssertEqual(store.actions[d], "Restarting all agents…")
        XCTAssertEqual(store.actions[e], AgentIsland.restartAllForceRunningText)
        XCTAssertEqual(store.dirStatus, "Restarting all agents… · Restarting all agents…")
        settle(c) { store.actions[a] == "Pausing…" }
        c.restart(session("q"))
        c.askRestartAll()
        c.confirmRestartAll(true)
        XCTAssertEqual(f.args.count, 2, "a dir under the forced Restart all refuses a row and a second Restart all")
        f.output = """
            {"name":"a","result":"ok","reason":"","detail":"claude 2.1.0 -> 2.1.0, resumed abc","session_id":"abc"}

            """
        f.release.signal(); f.release.signal()
        settle(c) { store.actions[d] != AgentIsland.restartAllForceRunningText && store.actions[e] != AgentIsland.restartAllForceRunningText }
        XCTAssertEqual(store.actions[a], "Restarted")
        XCTAssertEqual(store.actions[d], "1 agent restarted")
        XCTAssertEqual(f.args.count, 2)
    }

    /// New session: --spawn <free name> [stripped launch], the Process cwd is the
    /// folder, the env is the control env minus the Claude Code identity.
    /// #606: unset, the launch is inferred from the newest record (any folder) and stored.
    @MainActor
    func testNewSessionSpawnsInTheFolderWithAStrippedEnv() throws {
        let f = FakeProc()
        let argv = ["/opt/homebrew/bin/headroom", "wrap", "claude", "--resume", "sid", "--chrome"]
        let app = tempDir().appendingPathComponent("app").path, gone = tempDir().appendingPathComponent("gone").path
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        defer { Preferences.agentIslandNewSessionCommand = "" }
        let c = opened(f, [session("app")], history: [agentRecord("app-2", ended: 6, cwd: app,
                                                                 launch: ["/opt/homebrew/bin/claude", "--resume", "sid", "--chrome"], argv: argv),
                                                     agentRecord("old", ended: 5, cwd: gone, launch: ["claude"])])
        c.controlEnv = { ["PATH": "/login/bin", "DCH_SOCKET_DIR": $0, "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
                          "CLAUDE_PID": "9", "CLAUDE_EFFORT": "high", "CLAUDE_CONFIG_DIR": "/c"] }
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(store.controlsMenu, .init(recent: [app], refused: nil), "the deleted folder is left out")
        let sub = try XCTUnwrap(c.makeControlsMenu().items.first?.submenu)
        XCTAssertEqual(sub.items.map(\.title), [(app as NSString).abbreviatingWithTildeInPath, "", AgentIsland.chooseFolderLabel])
        press(sub.items[0])
        settle(c) { !f.args.isEmpty }
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--spawn", "app-3", "/opt/homebrew/bin/headroom", "wrap", "claude", "--chrome"]],
                       "app is live and app-2 a record: app-3; no --resume")
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "/opt/homebrew/bin/headroom wrap claude --chrome",
                       "#606: a real source is stored")
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
        settle(c) { !f.args.isEmpty }
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--spawn", "My-Repo", "claude"]])
        XCTAssertEqual(f.lock.withLock { f.launches[0].cwd }, "/picked/My Repo")
        XCTAssertNil(Preferences.defaults.object(forKey: "agentIslandNewSessionCommand"),
                     "#606: no source: claude, and nothing stored")
        f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "My-Repo")) }
    }

    /// #606: a set command is used as typed (no resume stripping) for every
    /// folder, over the history and the live sessions; nothing is read.
    @MainActor
    func testNewSessionUsesTheSettingAsTypedOverHistory() throws {
        defer { Preferences.agentIslandNewSessionCommand = "" }
        let f = FakeProc(), history = [agentRecord("h", ended: 5, cwd: "/a", launch: ["claude", "--x"])]
        let c = opened(f, [session("a")], history: history)
        c.readLiveRecords = { _ in XCTFail("a set command reads no record"); return [] }
        Preferences.agentIslandNewSessionCommand = "headroom wrap claude --chrome 'my x' --continue"
        c.newSession(in: "/a")
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success, "no inference: at once")
        XCTAssertEqual(f.args, [["--spawn", "a-2", "headroom", "wrap", "claude", "--chrome", "my x", "--continue"]])
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "headroom wrap claude --chrome 'my x' --continue", "never rewritten")
        f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "a-2")) }
    }

    /// #606: unset, a live session's record wins over history; it is stored once
    /// and then used as is (no drift when the live sessions change).
    @MainActor
    func testNewSessionInfersFromLiveRecordsAndStoresOnce() throws {
        defer { Preferences.agentIslandNewSessionCommand = "" }
        let f = FakeProc()
        let c = opened(f, [session("a"), session("b")],
                       history: [agentRecord("h", ended: 5, cwd: "/a", launch: ["claude", "--from-history"])])
        var live = agentRecord("b", ended: 0, cwd: "/b", launch: ["/bin/claude"], argv: ["headroom", "wrap", "claude", "--chrome", "-c"])
        live.end = ""
        let seen = Reads(), rec = live
        c.readLiveRecords = { s in seen.lock.withLock { seen.calls.append(("", s.map(\.name))) }; return [rec] }
        c.newSession(in: "/x/proj")
        settle(c) { !f.args.isEmpty }
        XCTAssertEqual(seen.lock.withLock { seen.calls.map(\.1) }, [["a", "b"]], "the poller's live sessions")
        XCTAssertEqual(f.args, [["--spawn", "proj", "headroom", "wrap", "claude", "--chrome"]], "the live record, stripped")
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "headroom wrap claude --chrome")
        f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "proj")) }
        c.newSession(in: "/x/two")
        settle(c) { f.args.count == 2 }
        XCTAssertEqual(f.args.last, ["--spawn", "two", "headroom", "wrap", "claude", "--chrome"], "stored: no second inference")
        XCTAssertEqual(seen.count, 1)
        f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "two")) }
        // Settings asks the same way: a stored value comes back at once.
        var got: [String]?
        c.newSessionCommand { got = $0 }
        XCTAssertEqual(got, ["headroom", "wrap", "claude", "--chrome"])
    }

    /// #608: a value the user commits while inference is still reading is
    /// theirs; the inferred command never overwrites it.
    @MainActor
    func testNewSessionCommandKeepsAValueCommittedWhileInferring() throws {
        defer { Preferences.agentIslandNewSessionCommand = "" }
        let f = FakeProc(), reading = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let c = opened(f, [session("a")])
        var live = agentRecord("a", ended: 0, cwd: "/a", launch: ["claude"], argv: ["claude", "--inferred"])
        live.end = ""
        let rec = live
        c.readLiveRecords = { _ in reading.signal(); gate.wait(); return [rec] }
        var got: [String]?
        c.newSessionCommand { got = $0 }
        XCTAssertEqual(reading.wait(timeout: .now() + 5), .success, "inference is under way")
        Preferences.agentIslandNewSessionCommand = "headroom wrap claude"
        gate.signal()
        settle(c) { got != nil }
        XCTAssertNotNil(got)
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "headroom wrap claude", "the user's value stands")
    }

    /// #606: Settings' ask while unset infers from the history already read and
    /// stores it; with no source it hands back claude and stores nothing.
    @MainActor
    func testNewSessionCommandAskInfersFromHistoryOffMain() throws {
        defer { Preferences.agentIslandNewSessionCommand = "" }
        let f = FakeProc()
        let c = opened(f, [session("a")], history: [record("plain")])
        c.readLiveRecords = { _ in XCTAssertFalse(Thread.isMainThread, "records are read off main"); return [] }
        var got: [String]?
        c.newSessionCommand { got = $0 }
        XCTAssertNil(got, "never answered on the caller's turn while inferring")
        settle(c) { got != nil }
        XCTAssertEqual(got, ["claude"])
        XCTAssertNil(Preferences.defaults.object(forKey: "agentIslandNewSessionCommand"))
        c.store?.history = [agentRecord("h", ended: 5, cwd: "/a", launch: ["claude", "--chrome", "--resume", "x"])]
        got = nil
        c.newSessionCommand { got = $0 }
        settle(c) { got != nil }
        XCTAssertEqual(got, ["claude", "--chrome"])
        XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --chrome")
    }

    /// #657: a test that returns while its ask is still inferring: the teardown drain
    /// waits the inference out and lands the pending write before it unsets, so
    /// nothing reaches the next test.
    @MainActor
    func testTeardownDrainLandsAPendingInferredCommandBeforeUnsetting() {
        let c = opened(FakeProc(), [session("a")], history: [agentRecord("h", ended: 5, cwd: "/a", launch: ["claude", "--leak"])])
        let gate = DispatchSemaphore(value: 0)
        c.readLiveRecords = { _ in gate.wait(); return [] }
        var got: [String]?
        c.newSessionCommand { got = $0 }
        XCTAssertNil(got, "still inferring: the test ends here")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gate.signal() }   // inference outlives the test
        Self.drainNewSessionCommand(c)   // what teardown runs
        settle(c) { got != nil }         // the next test's turn on main
        XCTAssertEqual(got, ["claude", "--leak"], "the ask did infer and store")
        XCTAssertNil(Preferences.defaults.object(forKey: "agentIslandNewSessionCommand"), "nothing lands after the reset")
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
        c.askRestartAll(force: true)
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
        XCTAssertEqual(menu.items.map(\.title), [AgentIsland.newSessionLabel, AgentIsland.restartAllLabel, AgentIsland.restartAllForceLabel,
                                                 "Stop all in Sessions…", "Stop all…", "Kill all in Sessions…", "Kill all…",
                                                 "", "Controls needs dch 1.25.0"])
        XCTAssertEqual(menu.items.map(\.isEnabled), [false, false, false, false, false, false, false, false, false],
                       "off, with the reason under them")
        for i in 1...6 { press(menu.items[i]) }
        XCTAssertFalse(store.confirmingRestartAll, "the action re-checks the gate")
        XCTAssertFalse(store.confirmingStopAll || store.confirmingKillAll, "#744: Stop all and Kill all too")
        XCTAssertFalse(AgentIslandView(store: store).drawn[0].killEnabled, "#744: a row's Kill too")
        c.askKill(session("a", version: "1.25.0"))
        XCTAssertNil(store.confirmingKill)
        store.sessions = [session("a", version: "1.24.0")]
        XCTAssertNil(store.controlsMenu.refused)
        XCTAssertEqual(AgentIslandView(store: store).drawn.map(\.refused), [nil])
        XCTAssertEqual(c.makeControlsMenu().items.map(\.isEnabled), [true, true, true, true, true, true, true])
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
        XCTAssertEqual(menu.items.map(\.title), [AgentIsland.newSessionLabel, "Restart stale agents (needs dch 1.24.1)",
                                                 "Restart all agents (force) (needs dch 1.24.1)",
                                                 "Stop all in Sessions… (needs dch 1.24.1)", "Stop all… (needs dch 1.24.1)",
                                                 "Kill all in Sessions…", "Kill all…"])
        XCTAssertEqual(menu.items.map(\.isEnabled), [true, false, false, false, false, true, true],
                       "#744: Kill needs no newer dch: base gate only")
        XCTAssertEqual(drawn.map(\.killEnabled), [true, true], "#744: a row's Kill too, any master")
        drawn[0].restart()
        drawn[0].stop()
        c.askRestartAll()
        c.askRestartAll(force: true)
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
                                                                 AgentIsland.restartAllForceLabel, "Stop all in Sessions…", "Stop all…",
                                                                 "Kill all in Sessions…", "Kill all…"])
        XCTAssertEqual(c.makeControlsMenu().items.map(\.isEnabled), [true, true, true, true, true, true, true])
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
        XCTAssertEqual(shown, [["New session", "Restart stale agents", "Restart all agents (force)", "Stop all in Sessions…",
                                "Stop all…", "Kill all in Sessions…", "Kill all…"]])
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
        XCTAssertEqual(menu.items.map(\.title), [AgentIsland.newSessionLabel, AgentIsland.restartAllLabel,
                                                 AgentIsland.restartAllForceLabel, "Stop all in Sessions…", "Stop all…",
                                                 "Kill all in Sessions…", "Kill all…"])
        XCTAssertEqual(menu.items.map(\.isEnabled), [true, false, false, false, false, false, false],
                       "nothing live: nothing to stop or kill")
        c.askRestartAll()
        c.askRestartAll(force: true)
        c.askStopAll(global: true)
        c.askKillAll()
        c.askKillAll(global: true)
        XCTAssertFalse(store.confirmingRestartAll || store.confirmingStopAll || store.confirmingKillAll)
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
        XCTAssertEqual(store.stopTargets(global: false).stop.map(\.name), ["main"])
        XCTAssertEqual(store.stopTargets(global: false).skipped, 1)
        var menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items[3].title, "Stop all in Sessions…")
        XCTAssertTrue(menu.items[3].isEnabled)
        c.askRestartAll()
        press(menu.items[3])
        XCTAssertTrue(store.confirmingStopAll)
        XCTAssertFalse(store.confirmingRestartAll, "one question at a time")
        c.confirmStopAll(false)
        c.askRestartAll(force: true)
        press(menu.items[3])
        XCTAssertTrue(store.confirmingStopAll)
        XCTAssertFalse(store.confirmingRestartAll, "the forced question too")
        XCTAssertTrue(store.showsControlLine)
        XCTAssertEqual(AgentIsland.stopAllQuestion(1, skipped: 1, tab: "Sessions"), "Stop 1 session in Sessions? 1 on an old dch skipped.")
        XCTAssertEqual(AgentIsland.stopAllQuestion(3, skipped: 0, tab: nil), "Stop 3 sessions in every tab?")
        XCTAssertEqual(AgentIsland.stopAllQuestion(3, skipped: 0, tab: nil, tabs: false), "Stop 3 sessions?",
                       "#749: no tabs, no \"every tab\"")
        XCTAssertEqual(AgentIsland.stopAllQuestion(2, skipped: 3, dashed: 1, tab: "Sessions"),
                       "Stop 2 sessions in Sessions? 2 on an old dch skipped. 1 skipped: name starts with “-”.")
        XCTAssertEqual(AgentIsland.stopAllQuestion(2, skipped: 1, dashed: 1, tab: "Sessions"),
                       "Stop 2 sessions in Sessions? 1 skipped: name starts with “-”.", "#749: a \"-\" name is no old dch")
        XCTAssertEqual(store.asked, .init(keys: [AgentSessionKey(dir: "/d", name: "main")], skipped: 1, tab: "Sessions"),
                       "the line's count, skips and tab, fixed when asked")
        c.confirmStopAll(false)
        XCTAssertFalse(store.confirmingStopAll)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "Cancel: no verb")
        c.showSidekicks(true)
        menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items[3].title, "Stop all in Sidekicks…")
        f.progress = #"{"name":"x-qa","phase":"ending"}"# + "\n"
        press(menu.items[3])
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
        XCTAssertEqual(store.stopTargets(global: false).stop, [])
        XCTAssertEqual(store.stopTargets(global: false).skipped, 2)
        let item = c.makeControlsMenu().items[3]
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

    // MARK: - #744: Stop all (global), Kill, Kill all

    /// The inline questions up at once; at most one, ever.
    @MainActor
    private func questions(_ store: AgentIslandStore) -> Int {
        [store.confirmingRestartAll, store.confirmingStopAll, store.confirmingKillAll, store.confirmingKill != nil,
         store.confirmingClear].filter { $0 }.count
    }

    /// dch -k takes one name, the very next argument, and no --json; with no name, a
    /// '-' name or "" it picks a session itself (its picker, or the cwd's auto-name).
    func testKillArgsAlwaysNameOneSessionAndNeverKl() {
        XCTAssertEqual(AgentIsland.killArgs("a"), ["-k", "a"])
        XCTAssertEqual(AgentIsland.killArgs("x-qa"), ["-k", "x-qa"])
        for bad in ["", "-", "-l", "-kl", "--all", "-x"] {
            XCTAssertNil(AgentIsland.killArgs(bad), "never without a name dch takes as one: \(bad)")
        }
        XCTAssertEqual(AgentIsland.killArgs("a")?.count, 2, "no --json, no -f, nothing after the name")
        XCTAssertEqual(AgentIsland.killQuestion("main"), "Kill main? No pause message first.")
        XCTAssertEqual(AgentIsland.killAllQuestion(1, skipped: 0, tab: "Sidekicks"),
                       "Kill 1 session in Sidekicks? No pause message first.")
        XCTAssertEqual(AgentIsland.killAllQuestion(3, skipped: 2, tab: nil),
                       "Kill 3 sessions in every tab? No pause message first. 2 skipped: name starts with “-”.")
        XCTAssertEqual(AgentIsland.killAllQuestion(3, skipped: 0, tab: nil, tabs: false), "Kill 3 sessions? No pause message first.")
        XCTAssertEqual(AgentIsland.killAllQuestion(3, skipped: 0, tab: "Sessions", tabs: false),
                       "Kill 3 sessions in Sessions? No pause message first.", "a tab asked for is still named")
        XCTAssertEqual(AgentIsland.stopAllGlobalLabel, "Stop all…")
        XCTAssertEqual(AgentIsland.killAllLabel(tab: "Sidekicks"), "Kill all in Sidekicks…")
        XCTAssertEqual(AgentIsland.killAllGlobalLabel, "Kill all…")
    }

    /// dch's two outcomes, read strictly: "killed: <name>" + exit 0 is killed (its name
    /// canonicalised, so any "killed: " line); else the last line, or the exit.
    func testKillResultsReadDchsTwoOutcomes() {
        let r = { (status: Int32, out: String) in AgentIsland.actionResult(status: status, output: Data(out.utf8)) }
        XCTAssertTrue(AgentIsland.killed(r(0, "killed: a\n")))
        XCTAssertEqual(AgentIsland.killText(r(0, "killed: a\n")), "Killed")
        XCTAssertFalse(AgentIsland.killed(r(1, "no session: a\n")))
        XCTAssertTrue(AgentIsland.killGone(r(1, "no session: a\n")))
        XCTAssertEqual(AgentIsland.killText(r(1, "no session: a\n")), "Already ended", "QA #572 INFO-7: not a failure")
        XCTAssertFalse(AgentIsland.killGone(r(0, "killed: a\n")))
        XCTAssertFalse(AgentIsland.killGone(r(1, "dch: cannot connect\n")))
        XCTAssertEqual(AgentIsland.killText(r(1, "dch: cannot connect\n")), "Kill failed: dch: cannot connect")
        XCTAssertFalse(AgentIsland.killed(r(0, "")), "exit 0 without dch's line is no kill")
        XCTAssertEqual(AgentIsland.killText(r(0, "")), "Kill failed (exit 0)")
        XCTAssertFalse(AgentIsland.killed(r(1, "killed: a\n")), "a non-zero exit is no kill")
        XCTAssertFalse(AgentIsland.killed(r(0, "not killed: a\n")))
        let cut = AgentIsland.actionResult(status: 143, output: Data("killed: a\n".utf8), stopped: true)
        XCTAssertFalse(AgentIsland.killed(cut))
        XCTAssertEqual(AgentIsland.killText(cut), "Kill cancelled: no answer in 5m")
        XCTAssertEqual(AgentIsland.killTally(killed: 2, gone: 1, failed: 1, busy: 1), "2 killed, 1 already ended, 1 failed, 1 busy")
        XCTAssertEqual(AgentIsland.killTally(killed: 1, gone: 0, failed: 0, busy: 0), "1 killed")
        XCTAssertEqual(AgentIsland.killTally(killed: 0, gone: 0, failed: 0, busy: 2), "2 busy")
        XCTAssertEqual(AgentIsland.killTally(killed: 0, gone: 0, failed: 0, busy: 0), "nothing killed")
    }

    /// Stop all (global): every tab's sessions whose master can stop, by name, one
    /// --stop per dir with its dir's env, never --all; the tab item stays the tab's.
    @MainActor
    func testStopAllGlobalCoversEveryTabPerDir() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads, dch: DchCommand.Binary(path: "/fake/dch", version: [1, 100, 0]), dirs: ["/d", "/e"])
        c.store?.sidekickPattern = "-qa"
        c.store?.sessions = [session("main", version: "1.24.0"), session("legacy", version: "1.23.0"),
                             session("x-qa", version: "1.24.1"), session("z-qa", dir: "/e", version: "1.100.0"),
                             session("w", dir: "/e", version: "1.24.1")]
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil && c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(Set(store.stopTargets(global: false).stop.map(\.name)), ["main", "w"])
        XCTAssertEqual(Set(store.stopTargets(global: true).stop.map(\.name)), ["main", "w", "x-qa", "z-qa"])
        XCTAssertEqual(store.stopTargets(global: true).skipped, 1, "legacy, on an old dch")
        let menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items[4].title, "Stop all…")
        XCTAssertTrue(menu.items[4].isEnabled)
        c.askKillAll()
        press(menu.items[4])
        XCTAssertTrue(store.confirmingStopAll)
        XCTAssertNil(store.asked.tab)
        XCTAssertEqual(questions(store), 1, "one question at a time")
        XCTAssertEqual(store.stopAllTargets.count, 4, "the question counts every tab")
        XCTAssertEqual(store.asked.skipped, 1)
        press(menu.items[3])
        XCTAssertEqual(store.asked.tab, "Sessions", "the tab item asks for the tab")
        XCTAssertEqual(store.stopAllTargets.count, 2)
        press(menu.items[4])
        c.confirmStopAll(true)
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        let byDir = Dictionary(uniqueKeysWithValues: f.lock.withLock { f.launches.map { ($0.dir ?? "", Set($0.args)) } })
        XCTAssertEqual(byDir, ["/d": ["--stop", "main", "x-qa", "--json"], "/e": ["--stop", "z-qa", "w", "--json"]],
                       "both tabs, by name, one call per dir with its DCH_SOCKET_DIR")
        XCTAssertFalse(f.args.joined().contains("--all"), "never --all")
        XCTAssertNil(store.actions[AgentSessionKey(dir: "/d", name: "legacy")], "an old master is skipped")
        f.output = ""
        f.release.signal(); f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "")) && !c.runner.isBusy(AgentSessionKey(dir: "/e", name: "")) }
    }

    /// A row's Kill asks first ("Kill <name>?" inline), then runs `dch -k <name>`
    /// with its dir's env: "Killing…", then dch's outcome, and one History re-read.
    /// Cancel, a gone row and a busy row run nothing.
    @MainActor
    func testRowKillAsksThenRunsDashKByName() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads, dirs: ["/d", "/e"])
        c.store?.sessions = [session("a", version: "1.23.0"), session("b", dir: "/e"), session("-x")]
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil && c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        let all = AgentIslandView(store: store, onKill: { c.askKill($0) }).drawn
        XCTAssertEqual(all.map(\.session.name), ["-x", "a", "b"])
        XCTAssertEqual(all.map(\.killEnabled), [false, true, true], "any master; never a name dch reads as a flag")
        all[0].kill()
        XCTAssertNil(store.confirmingKill)
        let drawn = Array(all.dropFirst())
        let a = AgentSessionKey(dir: "/d", name: "a"), b = AgentSessionKey(dir: "/e", name: "b")
        c.askStopAll()
        drawn[0].kill()
        XCTAssertEqual(store.confirmingKill, a)
        XCTAssertEqual(questions(store), 1, "one question at a time")
        XCTAssertTrue(store.showsControlLine)
        c.askRestartAll()
        XCTAssertNil(store.confirmingKill, "another question replaces it")
        drawn[0].kill()
        c.confirmKill(false)
        XCTAssertNil(store.confirmingKill)
        c.confirmKill(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "Cancel, and an answer with no question: nothing runs")
        drawn[0].kill()
        let before = reads.count
        c.confirmKill(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["-k", "a"]])
        XCTAssertEqual(f.lock.withLock { f.launches.map(\.dir) }, ["/d"], "its dir's DCH_SOCKET_DIR")
        XCTAssertEqual(store.actions[a], AgentIsland.killingText)
        drawn[0].kill()
        c.confirmKill(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "a busy row refuses")
        XCTAssertEqual(store.actions[a], AgentIsland.killingText, "#749 (QA #572 INFO-R7): a second Kill leaves \"Killing…\"")
        f.output = "killed: a\n"
        f.release.signal()
        settle(c) { store.actions[a] != AgentIsland.killingText && reads.count > before }
        XCTAssertEqual(store.actions[a], "Killed")
        XCTAssertEqual(reads.count, before + 1, "one History re-read after the kill")
        drawn[1].kill()
        XCTAssertEqual(store.confirmingKill, b)
        store.sessions = [session("a", version: "1.23.0")]
        XCTAssertNil(store.killTarget, "its row went")
        XCTAssertNil(store.confirmingKill, "QA #572 INFO-6: the question goes with its row")
        XCTAssertFalse(store.showsControlLine && store.dirStatus.isEmpty, "no question for a gone row")
        store.sessions = [session("a", version: "1.23.0"), session("b", dir: "/e")]
        XCTAssertNil(store.killTarget, "a session of that key coming back does not bring the question back")
        c.confirmKill(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "a gone row is never killed, nor its successor")
        drawn[1].kill()
        c.setExpanded(false)
        XCTAssertNil(store.confirmingKill, "closing drops the question")
        c.setExpanded(true)
        drawn[1].kill()
        c.confirmKill(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args.last, ["-k", "b"])
        f.status = 1
        f.output = "no session: b\n"
        f.release.signal()
        settle(c) { store.actions[b] != AgentIsland.killingText }
        XCTAssertEqual(store.actions[b], "Already ended")
        XCTAssertFalse(f.args.contains { $0.contains("-kl") || $0.count != 2 }, "never -kl, always one name")
    }

    /// Kill all in <tab> and Kill all: the scope's sessions by name, one `-k <name>`
    /// each with its dir's env, never -kl; a '-' name is skipped and counted; a busy
    /// row is left alone; each dir gets "N killed, N busy". A tab switch drops the
    /// tab's question (its rows would change under it); the global one stays.
    @MainActor
    func testKillAllPerTabAndGlobalByNamePerDir() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads, dirs: ["/d", "/e"])
        c.store?.sidekickPattern = "-qa"
        c.store?.sessions = [session("main", version: "1.23.0"), session("-dash"), session("x-qa"),
                             session("z-qa", dir: "/e"), session("w", dir: "/e")]
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil && c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(store.killTargets(global: false).kill.map(\.name), ["main", "w"])
        XCTAssertEqual(store.killTargets(global: false).skipped, 1, "-dash only: any master can be killed")
        XCTAssertEqual(store.killTargets(global: true).kill.count, 4)
        var menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items[5].title, "Kill all in Sessions…")
        XCTAssertEqual(menu.items[6].title, "Kill all…")
        XCTAssertTrue(menu.items[5].isEnabled && menu.items[6].isEnabled)
        press(menu.items[5])
        XCTAssertTrue(store.confirmingKillAll)
        XCTAssertEqual(store.asked.tab, "Sessions")
        XCTAssertEqual(questions(store), 1)
        c.showSidekicks(true)
        XCTAssertFalse(store.confirmingKillAll, "a tab switch drops the tab's Kill all")
        menu = c.makeControlsMenu()
        XCTAssertEqual(menu.items[5].title, "Kill all in Sidekicks…")
        press(menu.items[5])
        XCTAssertEqual(Set(store.killAllTargets.map(\.name)), ["x-qa", "z-qa"])
        c.confirmKillAll(false)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "Cancel: nothing runs")
        press(menu.items[6])
        XCTAssertNil(store.asked.tab)
        c.showSidekicks(false)
        XCTAssertTrue(store.confirmingKillAll, "the global question stays across tabs")
        XCTAssertEqual(store.killAllTargets.count, 4)
        XCTAssertEqual(store.asked.skipped, 1)
        // x-qa is busy with its own Kill: Kill all leaves it alone.
        let xq = AgentSessionKey(dir: "/d", name: "x-qa")
        c.askKill(session("x-qa"))
        c.confirmKill(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(store.confirmingKillAll, "the row's question replaced Kill all's")
        press(menu.items[6])
        c.confirmKillAll(true)
        for _ in 0..<3 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "x-qa is not asked twice")
        XCTAssertEqual(Set(f.args), [["-k", "x-qa"], ["-k", "main"], ["-k", "z-qa"], ["-k", "w"]])
        XCTAssertEqual(f.args.count, 4)
        XCTAssertFalse(f.args.contains { $0.contains("-kl") || $0.count != 2 }, "never -kl, one name per call")
        XCTAssertFalse(f.args.contains(["-k", "-dash"]), "a '-' name is never passed")
        let dirs = Dictionary(uniqueKeysWithValues: f.lock.withLock { f.launches.map { ($0.args[1], $0.dir ?? "") } })
        XCTAssertEqual(dirs, ["x-qa": "/d", "main": "/d", "z-qa": "/e", "w": "/e"], "each with its dir's DCH_SOCKET_DIR")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "main")], AgentIsland.killingText)
        f.output = "killed: it\n"
        let before = reads.count
        for _ in 0..<4 { f.release.signal() }
        let d = AgentSessionKey(dir: "/d", name: ""), e = AgentSessionKey(dir: "/e", name: "")
        settle(c) { store.actions[d] != nil && store.actions[e] != nil && store.actions[xq] == "Killed" && reads.count >= before + 2 }
        settle(c)
        XCTAssertEqual(store.actions[d], "1 killed, 1 busy")
        XCTAssertEqual(store.actions[e], "2 killed")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/e", name: "w")], "Killed")
        XCTAssertEqual(reads.count, before + 2, "QA #572 INFO-3: one History re-read for the row Kill, one for all of Kill all")
    }

    /// Kill all in <tab> kills that tab's rows only; dch's failures count as failed.
    @MainActor
    func testKillAllInTabKillsOnlyTheTabsRows() throws {
        let f = FakeProc()
        let c = opened(f, [session("main"), session("x-qa"), session("y-qa")])
        let store = try XCTUnwrap(c.store)
        store.sidekickPattern = "-qa"
        c.showSidekicks(true)
        press(c.makeControlsMenu().items[5])
        XCTAssertEqual(AgentIsland.killAllQuestion(store.asked.keys.count, skipped: store.asked.skipped, tab: store.asked.tab),
                       "Kill 2 sessions in Sidekicks? No pause message first.")
        XCTAssertEqual(store.killAllQuestion, "Kill 2 sessions in Sidekicks? No pause message first.")
        c.confirmKillAll(true)
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(Set(f.args), [["-k", "x-qa"], ["-k", "y-qa"]], "the shown tab's rows only")
        f.status = 1
        f.output = "no session: gone\n"
        f.release.signal(); f.release.signal()
        let d = AgentSessionKey(dir: "/d", name: "")
        settle(c) { store.actions[d] != nil }
        XCTAssertEqual(store.actions[d], "2 already ended", "QA #572 INFO-7: ended before the kill, not failed")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "x-qa")], "Already ended")
    }

    /// Kill all with every row busy: nothing runs, the dir says so at once.
    @MainActor
    func testKillAllWithEveryRowBusyRunsNothing() throws {
        let f = FakeProc()
        let c = opened(f, [session("a")])
        let store = try XCTUnwrap(c.store)
        c.askKill(session("a"))
        c.confirmKill(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        c.askKillAll(global: true)
        c.confirmKillAll(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [["-k", "a"]])
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], "1 busy")
        f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "a")) }
    }

    // MARK: - QA #572: Stop all / Kill all scope, Kill through a Stop

    /// QA #572 F1, F2: a per-tab Stop all or Kill all acts on the rows it named when
    /// asked. A tab click, or the shown tab falling back by itself when its side
    /// empties (what a poll tick does), drops the question; no answer reaches the
    /// other tab's rows, even with the drop bypassed.
    @MainActor
    func testPerTabStopAndKillAllNeverReachTheOtherTabsRows() throws {
        let f = FakeProc()
        let main = session("main", version: "1.24.1"), w = session("w", version: "1.24.1"), xqa = session("x-qa", version: "1.24.1")
        let rows = [main, w, xqa]
        let c = opened(f, rows)
        let store = try XCTUnwrap(c.store)
        store.sidekickPattern = "-qa"
        for kill in [true, false] {
            let what = kill ? "Kill all" : "Stop all"
            let ask = { kill ? c.askKillAll() : c.askStopAll() }
            let confirm = { kill ? c.confirmKillAll(true) : c.confirmStopAll(true) }
            let up = { kill ? store.confirmingKillAll : store.confirmingStopAll }
            // A click.
            c.showSidekicks(true)
            ask()
            XCTAssertEqual(store.asked, .init(keys: [xqa.key], skipped: 0, tab: "Sidekicks"), what)
            c.showSidekicks(true)
            XCTAssertTrue(up(), "\(what): the same tab clicked keeps it")
            c.showSidekicks(false)
            XCTAssertFalse(up(), "\(what): a tab click drops it")
            confirm()
            // The fallback: x-qa ends, Sidekicks empties, Sessions shows with no click.
            c.showSidekicks(true)
            ask()
            store.sessions = [main, w]
            XCTAssertEqual(store.sessionTab.label, "Sessions", "the shown tab flipped by itself")
            XCTAssertFalse(up(), "\(what): its tab went")
            confirm()
            // The other way: every Sessions row ends, Sidekicks shows with no click.
            store.sessions = rows
            c.showSidekicks(false)
            ask()
            XCTAssertEqual(store.asked.keys, [main.key, w.key], what)
            store.sessions = [xqa]
            XCTAssertEqual(store.sessionTab.label, "Sidekicks")
            XCTAssertFalse(up(), "\(what): its tab went")
            confirm()
            // A Settings pattern change: no sidekicks left, x-qa now under Sessions.
            store.sessions = rows
            c.showSidekicks(true)
            ask()
            store.sidekickPattern = "zzz"
            XCTAssertEqual(store.sessionTab.sessions.count, 3)
            XCTAssertFalse(up(), "\(what): the asked tab is gone, though its row is shown")
            confirm()
            store.sidekickPattern = "-qa"
            // A pattern change on the shown tab: main turns sidekick, Sessions keeps w only.
            c.showSidekicks(false)
            ask()
            store.sidekickPattern = "ma"
            XCTAssertEqual(store.sessionTab.label, "Sessions")
            XCTAssertFalse(up(), "\(what): one of its rows left the tab")
            confirm()
            store.sidekickPattern = "-qa"
            // The answer alone, the drop bypassed: the asked tab is not the shown one, so no row.
            c.showSidekicks(true)
            ask()
            c.showSidekicks(false)
            if kill { store.confirmingKillAll = true } else { store.confirmingStopAll = true }
            XCTAssertEqual(kill ? store.killAllTargets : store.stopAllTargets, [], what)
            confirm()
        }
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "no dch -k and no --stop for rows the question did not name")
    }

    /// QA #572 F1, F2: the question's count is the rows named when asked. One of them
    /// ending drops it; a session appearing in the scope keeps it, its count, and is
    /// not acted on.
    @MainActor
    func testStopAndKillAllActOnTheAskedRowsOnly() throws {
        let f = FakeProc()
        let a = session("a", version: "1.24.1"), b = session("b", version: "1.24.1"), late = session("late", version: "1.24.1")
        let c = opened(f, [a, b])
        let store = try XCTUnwrap(c.store)
        c.askKillAll(global: true)
        store.sessions = [a]
        XCTAssertFalse(store.confirmingKillAll, "an asked row ended: dropped")
        c.askStopAll()
        store.sessions = [b]
        XCTAssertFalse(store.confirmingStopAll, "an asked row ended: dropped")
        store.sessions = [a, b]
        c.askKillAll(global: true)
        store.sessions = [a, b, late]
        XCTAssertTrue(store.confirmingKillAll)
        XCTAssertEqual(store.asked.keys.count, 2, "the line's count stays the asked one")
        c.confirmKillAll(true)
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(Set(f.args), [["-k", "a"], ["-k", "b"]], "never the session that came after the question")
        f.output = "killed: it\n"
        f.release.signal(); f.release.signal()
        settle(c) { !c.runner.isBusy(a.key) && !c.runner.isBusy(b.key) }
        store.actions = [:]
        c.askStopAll()
        store.sessions = [a, b, late, session("later", version: "1.24.1")]
        XCTAssertTrue(store.confirmingStopAll)
        c.confirmStopAll(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(Set(f.args.last ?? []), ["--stop", "a", "b", "late", "--json"], "the asked rows, not the later one")
        f.output = ""
        f.release.signal()
        settle(c) { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "")) }
    }

    /// QA #572 F1 through the real paths: the poll tick that ends the last sidekick, and
    /// the Settings toggle that turns the tabs off, each drop a Kill all in Sidekicks.
    @MainActor
    func testKillAllInTabDropsWhenATickOrSettingsFlipsTheTab() throws {
        let keys = ["agentIslandSidekickTabs", "agentIslandSidekickPattern"]
        let saved = keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        Preferences.agentIslandSidekickTabs = true
        Preferences.agentIslandSidekickPattern = "-qa"
        let f = FakeProc(), dir = tempDir()
        let sock = { (n: String) in dir.appendingPathComponent("\(n).sock").path }
        for n in ["main", "w", "x-qa"] { FileManager.default.createFile(atPath: sock(n), contents: nil) }
        let c = controller(f, Reads(), dirs: [dir.path])
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
        settle(c) { c.store?.sessions.count == 3 && c.store?.controlDch != nil }
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(store.sidekickPattern, "-qa")
        c.showSidekicks(true)
        c.askKillAll()
        XCTAssertTrue(store.confirmingKillAll)
        XCTAssertEqual(store.asked.tab, "Sidekicks")
        try FileManager.default.removeItem(atPath: sock("x-qa"))
        settle(c) { store.sessions.count == 2 }
        XCTAssertEqual(store.sessionTab.label, "Sessions", "the tick flipped the tab")
        XCTAssertFalse(store.confirmingKillAll, "the tick that emptied Sidekicks dropped the question")
        c.confirmKillAll(true)
        FileManager.default.createFile(atPath: sock("x-qa"), contents: nil)
        settle(c) { store.sessions.count == 3 }
        c.showSidekicks(true)
        c.askKillAll()
        XCTAssertTrue(store.confirmingKillAll)
        Preferences.agentIslandSidekickTabs = false
        c.rowDetailsChanged()
        XCTAssertEqual(store.sessionTab.label, "Sessions")
        XCTAssertFalse(store.confirmingKillAll, "the Settings change dropped it")
        c.confirmKillAll(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "no dch -k at all")
    }

    /// A runner whose `-k` returns at once ("killed: <name>") and whose other verbs
    /// print `output` and exit 1 once `open` is signalled (a Stop or Restart that hangs).
    private final class Hang: @unchecked Sendable {
        let open = DispatchSemaphore(value: 0), lock = NSLock()
        var args: [[String]] = []
        var output = "dch: master gone\n"
        /// #750: printed before the wait on `open` (a dir job's phases).
        var progress = ""
        /// #749: `-k` exits 1 with this line instead; with `holdKill`, only once `killGate` is signalled.
        var killFail: String?
        var holdKill = false
        let killGate = DispatchSemaphore(value: 0)
        var kills: [[String]] { lock.withLock { args.filter { $0.first == "-k" } } }

        func runner() -> DchActionRunner {
            DchActionRunner(launch: { _, args, _, _, onPid, onOutput in
                self.lock.withLock { self.args.append(args) }
                onPid(4243)
                if args.first == "-k" {
                    let (hold, fail) = self.lock.withLock { (self.holdKill, self.killFail) }
                    if hold { self.killGate.wait() }
                    if let fail { return (1, Data("\(fail)\n".utf8)) }
                    return (0, Data("killed: \(args[1])\n".utf8))
                }
                let early = self.lock.withLock { Data(self.progress.utf8) }
                if !early.isEmpty { onOutput(early) }
                self.open.wait()
                let out = self.lock.withLock { Data(self.output.utf8) }
                onOutput(out)
                return (1, early + out)
            }, signal: { _ in })
        }
    }

    /// QA #572 INFO-1: Kill cuts through a row's Stop or Restart that hangs, and the
    /// Stop's or Restart's late result never overwrites "Killed". Any other job on the
    /// row refuses the Kill, and the row says so. The next job on the row shows its own result.
    @MainActor
    func testKillCutsThroughAStopOrRestartAndKeepsItsOutcome() throws {
        let h = Hang()
        let a = session("a", version: "1.24.1"), b = session("b", version: "1.24.1"), p = session("p", version: "1.24.1")
        let c = opened(FakeProc(), [a, b, p])
        c.runner = h.runner()
        let store = try XCTUnwrap(c.store)
        c.stop(a)
        c.restart(b)
        XCTAssertEqual(store.actions[a.key], AgentIsland.stoppingText)
        XCTAssertEqual(store.actions[b.key], AgentIsland.restartingText)
        for s in [a, b] {
            c.askKill(s)
            c.confirmKill(true)
        }
        settle(c) { store.actions[a.key] == "Killed" && store.actions[b.key] == "Killed" }
        XCTAssertEqual(Set(h.kills), [["-k", "a"], ["-k", "b"]], "beside the Stop and the Restart")
        c.stop(a)
        XCTAssertEqual(h.lock.withLock { h.args.count }, 4, "the row's Stop still runs: no second one")
        h.open.signal(); h.open.signal()
        settle(c) { !c.runner.isBusy(a.key) && !c.runner.isBusy(b.key) }
        let landed = Date().addingTimeInterval(0.3)
        settle(c) { Date() >= landed }   // their results' hop to main
        XCTAssertEqual(store.actions[a.key], "Killed", "the Stop's late failure does not overwrite the kill")
        XCTAssertEqual(store.actions[b.key], "Killed", "nor the Restart's")
        // A job a Kill may not cut through (a phone verb on the row): refused, visibly.
        XCTAssertTrue(c.runner.start(p.key, path: "/fake/dch", args: ["--send", "p", "hi"], env: { [:] }) { _ in })
        c.askKill(p)
        c.confirmKill(true)
        settle(c)
        XCTAssertEqual(h.kills.count, 2, "no -k beside another job")
        XCTAssertEqual(store.actions[p.key], AgentIsland.killBusyText)
        // The row's next job shows its own result again.
        h.output = "dch: no screen\n"
        c.stop(a)
        XCTAssertEqual(store.actions[a.key], AgentIsland.stoppingText)
        h.open.signal(); h.open.signal()
        settle(c) { store.actions[a.key] != AgentIsland.stoppingText && !c.runner.isBusy(p.key) }
        XCTAssertNotEqual(store.actions[a.key], "Killed")
        XCTAssertNotEqual(store.actions[a.key], AgentIsland.stoppingText, "the new Stop's result is shown")
        settle(c) { store.actions[p.key] == nil }
        XCTAssertNil(store.actions[p.key], "#749 (QA #572 INFO-R2): the refusal goes with the job")
    }

    /// QA #572 INFO-1, INFO-2: Kill all cuts through a running Stop all and leaves its
    /// dir text (the rows say "Killed"); under a job it may not cut through it runs
    /// nothing and leaves that job's text, never "N busy" over it.
    @MainActor
    func testKillAllBesideDirJobsLeavesTheirText() throws {
        let h = Hang()
        let a = session("a", version: "1.24.1"), b = session("b", version: "1.24.1")
        let c = opened(FakeProc(), [a, b])
        c.runner = h.runner()
        let store = try XCTUnwrap(c.store)
        let d = AgentSessionKey(dir: "/d", name: "")
        h.output = #"{"name":"a","result":"failed","reason":"gone","detail":"a: master gone"}"# + "\n"
            + #"{"name":"b","result":"failed","reason":"gone","detail":"b: master gone"}"# + "\n"
        c.askStopAll()
        c.confirmStopAll(true)
        XCTAssertEqual(store.actions[d], AgentIsland.stoppingText)
        c.askKillAll(global: true)
        c.confirmKillAll(true)
        settle(c) { store.actions[a.key] == "Killed" && store.actions[b.key] == "Killed" }
        XCTAssertEqual(Set(h.kills), [["-k", "a"], ["-k", "b"]])
        XCTAssertEqual(store.actions[d], AgentIsland.stoppingText, "Stop all's running text stays")
        h.open.signal()
        settle(c) { store.actions[d] != AgentIsland.stoppingText }
        XCTAssertEqual(store.actions[a.key], "Killed", "Stop all's late lines do not overwrite the kills")
        XCTAssertEqual(store.actions[b.key], "Killed")
        XCTAssertEqual(store.actions[d], "2 killed", "#749 (QA #572 INFO-R5): Stop all counts the rows killed, not failed")
        XCTAssertTrue(c.runner.start(d, path: "/fake/dch", args: ["--forget", "--all"], env: { [:] }) { _ in })
        store.actions[d] = AgentIsland.clearingText
        c.askKillAll(global: true)
        c.confirmKillAll(true)
        settle(c)
        XCTAssertEqual(h.kills.count, 2, "nothing killed under a Clear")
        XCTAssertEqual(store.actions[d], AgentIsland.clearingText, "not \"2 busy\" over the Clear's text")
        XCTAssertEqual(store.actions[a.key], AgentIsland.killBusyText, "#749 (QA #572 INFO-R3): the rows say why, as a row Kill")
        XCTAssertEqual(store.actions[b.key], AgentIsland.killBusyText)
        h.open.signal()
        settle(c) { !c.runner.isBusy(d) && store.actions[a.key] == nil && store.actions[b.key] == nil }
        XCTAssertNil(store.actions[a.key], "#749 (QA #572 INFO-R2): the note goes once the Clear ended")
        XCTAssertNil(store.actions[b.key])
        // Restart all yields too.
        c.askRestartAll()
        c.confirmRestartAll(true)
        XCTAssertTrue(c.runner.hasJob(d))
        c.askKill(a)
        c.confirmKill(true)
        settle(c) { h.kills.count == 3 && store.actions[a.key] == "Killed" }
        XCTAssertEqual(h.kills.count, 3, "a Kill beside a Restart all")
        XCTAssertEqual(store.actions[a.key], "Killed")
        h.open.signal()
        settle(c) { !c.runner.isBusy(d) && store.actions[d] != AgentIsland.restartAllRunningText }
        XCTAssertEqual(store.actions[d], "1 killed, 1 failed", "#750 (QA #576 INFO-3): Restart all counts the row killed too")
    }

    /// #749 (QA #572 INFO-R4): a Kill that fails hands the row back to the Stop or Restart it
    /// cut through. Still running: the Kill's failure shows until their result. Already done:
    /// their held-back result, then the Kill's failure.
    @MainActor
    func testAFailedKillLetsTheStopOrRestartResultThrough() throws {
        let h = Hang()
        h.killFail = "dch: permission denied"
        let a = session("a", version: "1.24.1"), b = session("b", version: "1.24.1")
        let c = opened(FakeProc(), [a, b])
        c.runner = h.runner()
        let store = try XCTUnwrap(c.store)
        let gone = AgentIsland.actionResult(status: 1, output: Data("dch: master gone\n".utf8))
        let failed = "Kill failed: dch: permission denied"
        c.restart(b)
        c.askKill(b)
        c.confirmKill(true)
        settle(c) { store.actions[b.key] == failed }
        XCTAssertEqual(store.actions[b.key], failed)
        XCTAssertNil(c.killedRows[b.key], "the row is the Restart's again")
        h.open.signal()
        let restarted = AgentIsland.rowText(gone, name: "b", .restart)
        settle(c) { store.actions[b.key] == restarted }
        XCTAssertEqual(store.actions[b.key], restarted, "the Restart's result shows")
        h.lock.withLock { h.holdKill = true }
        c.stop(a)
        c.askKill(a)
        c.confirmKill(true)
        XCTAssertEqual(store.actions[a.key], AgentIsland.killingText)
        h.open.signal()
        let stopped = AgentIsland.rowText(gone, name: "a", .stop)
        settle(c) { c.killedRows[a.key] == stopped }
        XCTAssertEqual(c.killedRows[a.key], stopped, "the Stop's result, held back")
        XCTAssertEqual(store.actions[a.key], AgentIsland.killingText, "while the Kill runs")
        h.killGate.signal()
        settle(c) { store.actions[a.key] != AgentIsland.killingText }
        XCTAssertEqual(store.actions[a.key], "\(stopped); \(failed)")
        XCTAssertNil(c.killedRows[a.key])
        // A Stop all that ended with only a phase held for the row: the Kill's failure alone.
        let d = AgentSessionKey(dir: "/d", name: "")
        h.output = #"{"name":"b","phase":"ending"}"# + "\n"
        c.askStopAll()
        c.confirmStopAll(true)
        c.askKill(b)
        c.confirmKill(true)
        h.open.signal()
        settle(c) { !c.runner.hasJob(d) && c.killedRows[b.key] == "Ending…" && store.actions[d] != AgentIsland.stoppingText }
        XCTAssertEqual(c.killedRows[b.key], "Ending…")
        h.killGate.signal()
        settle(c) { store.actions[b.key] != AgentIsland.killingText }
        XCTAssertEqual(store.actions[b.key], failed, "a stale phase is never shown")
        // "no session" (already ended) keeps the row, as "Killed" does.
        h.lock.withLock { h.holdKill = false; h.killFail = "no session: a"; h.output = "dch: master gone\n" }
        c.stop(a)
        c.askKill(a)
        c.confirmKill(true)
        settle(c) { store.actions[a.key] == AgentIsland.alreadyEndedText }
        h.open.signal()
        settle(c) { !c.runner.isBusy(a.key) }
        let landed = Date().addingTimeInterval(0.3)
        settle(c) { Date() >= landed }   // the Stop's result hop to main
        XCTAssertEqual(store.actions[a.key], AgentIsland.alreadyEndedText, "the Stop's late failure does not overwrite it")
    }

    /// #749 (QA #572 INFO-R2, INFO-R7): a refused Kill's note stays while the job that refused
    /// it (here one the island does not show) runs, and goes once it ended, with no tick. A
    /// killed row leaves `killedRows` on the tick that drops it.
    @MainActor
    func testRefusedKillNoteGoesWithItsJobAndAKilledRowIsPruned() throws {
        let h = Hang(), dir = tempDir()
        let sock = { (n: String) in dir.appendingPathComponent("\(n).sock").path }
        for n in ["a", "b"] { FileManager.default.createFile(atPath: sock(n), contents: nil) }
        let c = controller(FakeProc(), Reads(), dirs: [dir.path])
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
        c.runner = h.runner()
        settle(c) { c.store?.sessions.count == 2 && c.store?.controlDch != nil }
        let store = try XCTUnwrap(c.store)
        let sa = try XCTUnwrap(store.sessions.first { $0.name == "a" }), sb = try XCTUnwrap(store.sessions.first { $0.name == "b" })
        XCTAssertTrue(c.runner.start(sa.key, path: "/fake/dch", args: ["--revive", "a"], env: { [:] }) { _ in })
        c.askKill(sa)
        c.confirmKill(true)
        XCTAssertEqual(store.actions[sa.key], AgentIsland.killBusyText)
        let later = Date().addingTimeInterval(1.5)
        settle(c) { Date() >= later }
        XCTAssertEqual(store.actions[sa.key], AgentIsland.killBusyText, "kept while the job runs")
        h.open.signal()
        settle(c) { store.actions[sa.key] == nil }
        XCTAssertNil(store.actions[sa.key], "gone once it ended")
        XCTAssertEqual(store.sessions.count, 2)
        c.askKill(sb)
        c.confirmKill(true)
        settle(c) { store.actions[sb.key] == "Killed" }
        XCTAssertEqual(c.killedRows[sb.key], "")
        try FileManager.default.removeItem(atPath: sock("b"))
        settle(c) { store.sessions.count == 1 }
        XCTAssertNil(c.killedRows[sb.key], "pruned with its row")
    }

    /// #749 (QA #572 INFO-R6): Stop all's skips give their true reason (an old dch, a "-"
    /// name); "every tab" only while the tabs are on.
    @MainActor
    func testStopAndKillAllQuestionsSayWhyAndScopeOnlyWithTabs() throws {
        let c = opened(FakeProc(), [session("a", version: "1.24.1"), session("old", version: "1.23.0"),
                                    session("-dash", version: "1.24.1"), session("-olddash", version: "1.23.0")])
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(store.sidekickPattern, "")
        c.askStopAll(global: true)
        XCTAssertTrue(store.confirmingStopAll)
        let skips = " 2 on an old dch skipped. 1 skipped: name starts with “-”."
        XCTAssertEqual(store.stopAllQuestion, "Stop 1 session?" + skips)
        store.sidekickPattern = "-qa"
        XCTAssertEqual(store.stopAllQuestion, "Stop 1 session in every tab?" + skips)
        store.sidekickPattern = ""
        c.askKillAll(global: true)
        XCTAssertEqual(store.killAllQuestion, "Kill 2 sessions? No pause message first. 2 skipped: name starts with “-”.")
        c.askKillAll()
        XCTAssertEqual(store.killAllQuestion, "Kill 2 sessions in Sessions? No pause message first. 2 skipped: name starts with “-”.")
    }

    /// #749 (QA #572 INFO-R5): Stop all's failed lines for rows a Kill cut through count as killed.
    /// #750 (QA #576 INFO-3): Restart all's too; the master pass never.
    func testStopAllTallyCountsKilledRowsAsKilled() {
        let line = { (n: String, r: String) in #"{"name":"\#(n)","result":"\#(r)","reason":"x","detail":"\#(n): x"}"# }
        let out = [line("a", "failed"), line("b", "failed"), line("c", "ok")].joined(separator: "\n") + "\n"
        let r = { (k: Set<String>) in
            var r = AgentIsland.actionResult(status: 1, output: Data(out.utf8))
            r.killed = k
            return r
        }
        let t = { (k: Set<String>) in AgentIsland.tally(r(k), .stop, title: "Stop all", empty: "nothing stopped") }
        XCTAssertEqual(t([]), "1 stopped, 2 failed")
        XCTAssertEqual(t(["a"]), "1 stopped, 1 killed, 1 failed")
        XCTAssertEqual(t(["a", "b"]), "1 stopped, 2 killed", "their failures explain the exit")
        XCTAssertEqual(t(["c"]), "1 stopped, 2 failed", "only a failed row reads killed")
        let sum = { (k: Set<String>) in AgentIsland.restartAllSummary(r(k)) }
        XCTAssertEqual(sum([]), "1 agent restarted, 2 failed")
        XCTAssertEqual(sum(["a"]), "1 agent restarted, 1 killed, 1 failed")
        XCTAssertEqual(sum(["a", "b"]), "1 agent restarted, 2 killed", "their failures explain the exit")
        XCTAssertEqual(sum(["c"]), "1 agent restarted, 2 failed")
        var killedOnly = AgentIsland.actionResult(status: 1, output: Data((line("a", "failed") + "\n").utf8))
        killedOnly.killed = ["a"]
        XCTAssertEqual(AgentIsland.restartAllSummary(killedOnly), "1 killed", "not \"all agents current\"")
        let master = #"{"name":"a","phase":"master","result":"failed","reason":"x","detail":"a: x"}"#
        var m = AgentIsland.actionResult(status: 1, output: Data((master + "\n").utf8))
        m.killed = ["a"]
        XCTAssertEqual(AgentIsland.restartAllSummary(m), "1 failed", "a master pass is no session result")
    }

    /// #750 (QA #576 INFO-1): a refused Kill's note goes once nothing a Kill refuses runs on the
    /// row, though a Stop (which a Kill cuts through) started there since.
    @MainActor
    func testRefusedKillNoteGoesWhenOnlyAStopRunsThere() throws {
        let h = Hang()
        let a = session("a", version: "1.24.1")
        let c = opened(FakeProc(), [a])
        c.runner = h.runner()
        let store = try XCTUnwrap(c.store)
        XCTAssertTrue(c.runner.start(a.key, path: "/fake/dch", args: ["--revive", "a"], env: { [:] }) { _ in })
        c.askKill(a)
        c.confirmKill(true)
        XCTAssertEqual(store.actions[a.key], AgentIsland.killBusyText)
        // The Revive ends and a phone Stop starts, inside the first 1 s check (main is not run here).
        h.open.signal()
        let end = Date().addingTimeInterval(5)
        while c.runner.isBusy(a.key) && Date() < end { usleep(1000) }
        XCTAssertTrue(c.runner.start(a.key, path: "/fake/dch", args: ["--stop", "a", "--json"], yields: true, env: { [:] }) { _ in })
        settle(c) { store.actions[a.key] == nil }
        XCTAssertNil(store.actions[a.key], "a Kill would run now")
        XCTAssertTrue(c.runner.isBusy(a.key), "while the Stop still runs")
        h.open.signal()
        settle(c) { !c.runner.isBusy(a.key) }
    }

    /// #750 (QA #576 INFO-2): Stop all counts a row killed only when its Kill worked before Stop
    /// all ended: not a Kill still out then (that fails after), not one that found the row ended.
    @MainActor
    func testStopAllCountsKilledOnlyForAKillThatWorked() throws {
        let h = Hang()
        let a = session("a", version: "1.24.1"), b = session("b", version: "1.24.1")
        let c = opened(FakeProc(), [a, b])
        c.runner = h.runner()
        let store = try XCTUnwrap(c.store)
        let d = AgentSessionKey(dir: "/d", name: "")
        h.output = #"{"name":"a","result":"failed","reason":"gone","detail":"a: master gone"}"# + "\n"
            + #"{"name":"b","result":"failed","reason":"gone","detail":"b: master gone"}"# + "\n"
        h.lock.withLock { h.holdKill = true; h.killFail = "dch: permission denied" }
        c.askStopAll()
        c.confirmStopAll(true)
        c.askKill(a)
        c.confirmKill(true)
        XCTAssertEqual(store.actions[a.key], AgentIsland.killingText)
        h.open.signal()
        settle(c) { store.actions[d] != AgentIsland.stoppingText }
        XCTAssertEqual(store.actions[d], "2 failed", "a Kill still out is no kill")
        h.killGate.signal()
        settle(c) { store.actions[a.key] != AgentIsland.killingText }
        XCTAssertEqual(store.actions[a.key], "master gone; Kill failed: dch: permission denied")
        XCTAssertEqual(store.actions[d], "2 failed")
        // Already ended: the row says so, the dir counts it failed (dch's word on the Stop).
        h.lock.withLock { h.holdKill = false; h.killFail = "no session: a" }
        c.askStopAll()
        c.confirmStopAll(true)
        c.askKill(a)
        c.confirmKill(true)
        settle(c) { store.actions[a.key] == AgentIsland.alreadyEndedText }
        XCTAssertEqual(store.actions[a.key], AgentIsland.alreadyEndedText)
        h.open.signal()
        settle(c) { store.actions[d] != AgentIsland.stoppingText }
        XCTAssertEqual(store.actions[d], "2 failed", "\"Already ended\" is no kill")
        XCTAssertEqual(store.actions[a.key], AgentIsland.alreadyEndedText)
    }

    /// #750 (QA #576 item 5): a Kill counts only in its own dir's Stop all, even where a row of
    /// another dir has its name.
    @MainActor
    func testStopAllCountsAKillOnlyInItsOwnDir() throws {
        let h = Hang()
        let a = session("a", version: "1.24.1"), e = session("a", dir: "/e", version: "1.24.1")
        let c = opened(FakeProc(), [a, e], dirs: ["/d", "/e"])
        c.runner = h.runner()
        let store = try XCTUnwrap(c.store)
        let d = AgentSessionKey(dir: "/d", name: ""), de = AgentSessionKey(dir: "/e", name: "")
        h.output = #"{"name":"a","result":"failed","reason":"gone","detail":"a: master gone"}"# + "\n"
        c.askStopAll(global: true)
        c.confirmStopAll(true)
        XCTAssertEqual(store.actions[d], AgentIsland.stoppingText)
        XCTAssertEqual(store.actions[de], AgentIsland.stoppingText)
        c.askKill(a)
        c.confirmKill(true)
        settle(c) { store.actions[a.key] == "Killed" }
        h.open.signal(); h.open.signal()
        settle(c) { store.actions[d] != AgentIsland.stoppingText && store.actions[de] != AgentIsland.stoppingText }
        XCTAssertEqual(store.actions[d], "1 killed")
        XCTAssertEqual(store.actions[de], "1 failed", "the other dir's a was not killed")
        XCTAssertEqual(store.actions[e.key], "master gone")
    }

    /// #750 (QA #576 INFO-4): a dir job's ok result for a row a Kill cut through is held too:
    /// a failed Kill on a row Restart all restarted reads both.
    @MainActor
    func testAFailedKillUnderRestartAllShowsTheRowsRestart() throws {
        let h = Hang()
        h.lock.withLock { h.holdKill = true; h.killFail = "dch: permission denied" }
        let a = session("a", version: "1.24.1")
        let c = opened(FakeProc(), [a])
        c.runner = h.runner()
        let store = try XCTUnwrap(c.store)
        let d = AgentSessionKey(dir: "/d", name: "")
        h.progress = #"{"name":"a","phase":"pausing"}"# + "\n"
        h.output = #"{"name":"a","result":"ok","reason":"","detail":""}"# + "\n"
        c.askRestartAll()
        c.confirmRestartAll(true)
        settle(c) { store.actions[a.key] == "Pausing…" }
        XCTAssertEqual(store.actions[a.key], "Pausing…")
        c.askKill(a)
        c.confirmKill(true)
        XCTAssertEqual(store.actions[a.key], AgentIsland.killingText)
        XCTAssertEqual(c.killedRows[a.key], "Pausing…", "the running text it cut through, held")
        h.open.signal()
        settle(c) { !c.runner.hasJob(d) && store.actions[d] != AgentIsland.restartAllRunningText }
        let restarted = AgentIsland.Verb.restart.done
        XCTAssertEqual(c.killedRows[a.key], restarted, "Restart all's result, held back")
        XCTAssertEqual(store.actions[a.key], AgentIsland.killingText, "while the Kill runs")
        h.killGate.signal()
        settle(c) { store.actions[a.key] != AgentIsland.killingText }
        XCTAssertEqual(store.actions[a.key], "\(restarted); Kill failed: dch: permission denied")
    }

    /// Visual evidence: the inline Kill all and row Kill questions, a row
    /// killing and a Kill all tally. Offscreen only.
    @MainActor
    func testRendersKillControlsOffscreen() throws {
        let store = AgentIslandStore(geometry: notched, details: AgentIslandRowDetails())
        store.sessions = [session("prosper-main", version: "1.24.0"), session("ios", version: "1.23.0")]
        store.controlDch = Self.v1241
        store.expanded = true
        let out = tempDir()
        store.ask(store.sessions, skipped: 0, global: true)
        store.confirmingKillAll = true
        try render(store, "agent-island-744-kill-all-confirm", to: out)
        store.confirmingKillAll = false
        store.confirmingKill = AgentSessionKey(dir: "/d", name: "ios")
        try render(store, "agent-island-744-kill-confirm", to: out)
        store.confirmingKill = nil
        store.actions[AgentSessionKey(dir: "/d", name: "prosper-main")] = AgentIsland.killingText
        store.actions[AgentSessionKey(dir: "/d", name: "ios")] = "Kill failed: no session: ios"
        store.actions[AgentSessionKey(dir: "/d", name: "")] = "1 killed, 1 failed"
        try render(store, "agent-island-744-kill-results", to: out)
    }

    // MARK: - #605: pin, Remove from History, Clear unpinned

    private static let v125 = DchCommand.Binary(path: "/fake/dch", version: [1, 25, 0])

    private func pinned(_ name: String, dir: String = "/d", ended: TimeInterval = 100) -> DchHistoryRecord {
        var r = record(name, dir: dir, ended: ended)
        r.pinned = true
        return r
    }

    func testPinnedParsesPresentAndAbsent() {
        let json = #"[{"name":"keep","pinned":true},{"name":"plain"},{"name":"off","pinned":false},{"name":"odd","pinned":"yes"}]"#
        let rows = AgentIsland.parseHistory(Data(json.utf8), dir: "/d")
        XCTAssertEqual(rows.map(\.pinned), [true, false, false, false], "only \"pinned\":true pins; absent is false")
        XCTAssertEqual(rows[0], DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "keep"), pinned: true))
    }

    /// Pinned first, newest first; unpinned fill up to 50; a pin is never capped.
    @MainActor
    func testPinnedRowsLeadAndAreNeverCapped() {
        let unpinned = (0..<60).map { record("u\($0)", ended: TimeInterval(1000 - $0)) }
        let pins = [pinned("p-new", ended: 500), pinned("p-old", ended: 5)]
        // `history` is newest first: the pins sit among the unpinned records.
        let history = (unpinned + pins).sorted { $0.lastSeen > $1.lastSeen }
        let rows = AgentIsland.cappedHistory(history)
        XCTAssertEqual(rows.count, AgentIsland.historyCap)
        XCTAssertEqual(rows.prefix(2).map(\.name), ["p-new", "p-old"])
        XCTAssertEqual(rows.dropFirst(2).map(\.name), (0..<48).map { "u\($0)" }, "unpinned newest first, up to the cap")
        let many = (0..<55).map { pinned("p\($0)", ended: TimeInterval(900 - $0)) } + unpinned.prefix(3)
        let all = AgentIsland.cappedHistory(many.sorted { $0.lastSeen > $1.lastSeen })
        XCTAssertEqual(all.map(\.name), (0..<55).map { "p\($0)" }, "55 pinned: every pin, no unpinned row")
        let store = AgentIslandStore(geometry: notched)
        store.history = many
        XCTAssertEqual(store.shownHistory, [], "History tab not chosen")
        store.historyTab = true
        XCTAssertEqual(store.shownHistory.count, 55)
        XCTAssertEqual(store.cappedHistory.count, 55, "the tab reads History (55)")
        XCTAssertEqual(store.unpinnedCount, 3)
        XCTAssertEqual(AgentIsland.cappedHistory([]), [])
    }

    /// 1.25.0 for the control binary, and at least every live master (an old "" passes).
    @MainActor
    func testHistoryEditGateNeeds125() {
        XCTAssertEqual(AgentIsland.historyEditMinimum, [1, 25, 0])
        let store = AgentIslandStore(geometry: notched)
        store.history = [record("x"), pinned("p")]
        store.historyTab = true
        func drawn() -> [AgentIslandView.HistoryDrawn] { AgentIslandView(store: store).historyDrawn }
        for (dch, masters, gate) in [
            (DchCommand.Binary(path: "/b", version: [1, 24, 2]), [""], DchCommand.Gate.refused("needs dch 1.25.0")),
            (Self.v125, ["", "1.24.0"], .ok("/fake/dch")),
            (Self.v125, ["1.25.0"], .ok("/fake/dch")),
            (Self.v125, ["1.26.0"], .refused("needs dch 1.26.0")),
            (DchCommand.Binary(path: "/b", version: [1, 26, 0]), ["1.26.0"], .ok("/b")),
        ] {
            store.controlDch = dch
            store.sessions = masters.enumerated().map { session("s\($0.offset)", version: $0.element) }
            XCTAssertEqual(store.historyEditGate, gate, "\(dch.version) \(masters)")
            let on = gate.isOK
            XCTAssertEqual(drawn().map { $0.pin != nil }, [on, on], "pin drawn only with the gate")
            XCTAssertEqual(drawn().map { $0.remove != nil }, [false, on], "X never on a pin; only with the gate")
            XCTAssertEqual(store.clearUnpinnedButton, on ? "Clear unpinned" : nil)
        }
        store.controlDch = DchCommand.Binary(path: "/b", version: [1, 24, 2])
        store.sessions = []
        XCTAssertEqual(drawn().map(\.enabled), [true, true], "1.24.x: History (Resume) stays usable")
        XCTAssertFalse(store.showsHistoryHeader, "and no header line for Clear")
        store.controlDch = nil
        XCTAssertEqual(store.historyEditGate, .refused("needs dch 1.25.0"))
    }

    /// The drawn pin and X carry their own record; no X on a pinned row.
    @MainActor
    func testDrawnPinAndRemoveCarryTheirRecordAndPinsHaveNoX() {
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = Self.v125
        store.history = [record("x", ended: 3), pinned("p", ended: 2)]
        store.historyTab = true
        var pins: [String] = [], removes: [String] = []
        let rows = AgentIslandView(store: store, onPin: { pins.append($0.name) }, onRemove: { removes.append($0.name) })
            .historyDrawn
        XCTAssertEqual(rows.map(\.record.name), ["p", "x"])
        XCTAssertNil(rows[0].remove, "a pinned row has no X: unpin first")
        for r in rows { r.pin?(); r.remove?() }
        XCTAssertEqual(pins, ["p", "x"])
        XCTAssertEqual(removes, ["x"])
    }

    /// Pin, Unpin and the X: exact args, the record's dir's control env, a busy
    /// row refuses, History re-read after each; a pinned record never runs --forget.
    @MainActor
    func testPinUnpinAndRemoveRunInTheRecordsDirThenReread() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x", dir: "/e"), pinned("y", dir: "/e", ended: 50)]
        let c = controller(f, reads, dch: Self.v125, dirs: ["/e"])
        c.controlEnv = { ["PATH": "/login/bin", "DCH_SOCKET_DIR": $0] }
        c.store?.sessions = [session("live", dir: "/e")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        let store = try XCTUnwrap(c.store)
        store.historyTab = true
        let rows = AgentIslandView(store: store, onPin: { c.pin($0) }, onRemove: { c.remove($0) }).historyDrawn
        XCTAssertEqual(rows.map(\.record.name), ["y", "x"])
        func step(_ press: () -> Void, _ args: [String], line: UInt = #line) {
            let before = reads.count, launches = f.args.count
            press()
            press()   // busy: refused, never queued
            XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success, line: line)
            XCTAssertEqual(f.args.count, launches + 1, "one launch", line: line)
            XCTAssertEqual(f.args.last, args, line: line)
            XCTAssertEqual(f.lock.withLock { f.envs.last }, ["PATH": "/login/bin", "DCH_SOCKET_DIR": "/e"], line: line)
            f.release.signal()
            settle(c) { reads.count == before + 1 }
            XCTAssertEqual(reads.count, before + 1, "History re-read", line: line)
        }
        step({ rows[1].pin?() }, ["--pin", "x", "--json"])
        step({ rows[0].pin?() }, ["--unpin", "y", "--json"])
        step({ rows[1].remove?() }, ["--forget", "x", "--json"])
        c.remove(pinned("y", dir: "/e", ended: 50))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "a pinned record: no --forget, no -f")
        XCTAssertEqual(f.args.count, 3)
        XCTAssertEqual(store.actions, [:], "ok: nothing on the status line")
        store.sessions = [session("live", dir: "/e", version: "1.26.0")]
        c.pin(record("x", dir: "/e"))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "the gate refuses: nothing runs")
        store.sessions = [session("live", dir: "/e")]
        store.controlDch = Self.v1241   // Resume's gate passes, the edit gate does not
        c.pin(record("x", dir: "/e"))
        c.remove(record("x", dir: "/e"))
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "1.24.1: no --pin or --forget")
        XCTAssertEqual(f.args.count, 3)
    }

    func testEditFailureTextPerReason() {
        func res(_ status: Int32, _ out: String, stopped: Bool = false) -> DchActionResult {
            AgentIsland.actionResult(status: status, output: Data(out.utf8), stopped: stopped)
        }
        func line(_ reason: String, _ detail: String) -> String {
            #"{"name":"x","result":"failed","reason":"\#(reason)","detail":"\#(detail)","session_id":""}"# + "\n"
                + #"{"ok":0,"skipped":0,"failed":1}"# + "\n"
        }
        XCTAssertNil(AgentIsland.editFailure(res(0, #"{"name":"x","result":"ok","reason":"","detail":"pinned","session_id":"s"}"#),
                                             name: "x", .pin))
        XCTAssertNil(AgentIsland.editFailure(res(0, ""), name: "x", .unpin))
        XCTAssertEqual(AgentIsland.editFailure(res(1, line("not_found", "no history for this session")), name: "x", .pin),
                       "Pin x failed: no history for this session")
        XCTAssertEqual(AgentIsland.editFailure(res(1, line("live", "session is live")), name: "x", .remove),
                       "Remove x failed: session is live")
        XCTAssertEqual(AgentIsland.editFailure(res(1, line("pinned", "pinned (-f forgets it anyway)")), name: "x", .remove),
                       "Remove x failed: pinned, unpin it first", "never dch's -f hint")
        XCTAssertEqual(AgentIsland.editFailure(res(1, line("io_error", "Permission denied")), name: "x", .unpin),
                       "Unpin x failed: Permission denied", "io_error carries the OS error")
        XCTAssertEqual(AgentIsland.editFailure(res(1, line("io_error", "")), name: "x", .pin), "Pin x failed: io_error")
        XCTAssertEqual(AgentIsland.editFailure(res(1, ""), name: "x", .remove), "Remove x failed (exit 1)")
        XCTAssertEqual(AgentIsland.editFailure(res(1, "dch: --pin: unknown option\n"), name: "x", .pin),
                       "Pin x failed: dch: --pin: unknown option")
        XCTAssertEqual(AgentIsland.editFailure(res(143, "", stopped: true), name: "x", .remove),
                       "Remove x cancelled: no answer in 5m")
        XCTAssertEqual(AgentIsland.pinArgs(["x"], pin: true), ["--pin", "x", "--json"])
        XCTAssertEqual(AgentIsland.pinArgs(["x"], pin: false), ["--unpin", "x", "--json"])
        XCTAssertEqual(AgentIsland.forgetArgs(["x"]), ["--forget", "x", "--json"])
        XCTAssertEqual(AgentIsland.forgetAllArgs, ["--forget", "--all", "--json"])
    }

    /// A failed edit lands on the dir's status line in the History header, never silently.
    @MainActor
    func testFailedEditShowsOnTheDirStatusLine() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x"), record("y", ended: 50)]
        let c = controller(f, reads, dch: Self.v125)
        c.store?.sessions = [session("a")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        let store = try XCTUnwrap(c.store)
        store.historyTab = true
        let all = AgentSessionKey(dir: "/d", name: "")
        f.status = 1
        f.output = #"{"name":"x","result":"failed","reason":"io_error","detail":"Operation not permitted","session_id":""}"#
            + "\n" + #"{"ok":0,"skipped":0,"failed":1}"# + "\n"
        c.remove(record("x"))
        f.release.signal()
        settle(c) { store.actions[all] != nil }
        XCTAssertEqual(store.actions[all], "Remove x failed: Operation not permitted")
        XCTAssertEqual(store.historyStatus, "Remove x failed: Operation not permitted")
        XCTAssertTrue(store.showsHistoryHeader)
        f.output = ""
        c.pin(record("y", ended: 50))
        f.release.signal()
        settle(c) { store.actions[all] != "Remove x failed: Operation not permitted" }
        XCTAssertEqual(store.actions[all], "Pin y failed (exit 1)", "a non-zero exit with no lines")
    }

    func testClearTallyCountsClearedSkippedAndFailed() {
        let out = """
            {"name":"a","result":"ok","reason":"","detail":"forgotten","session_id":""}
            {"name":"b","result":"ok","reason":"","detail":"forgotten","session_id":""}
            {"name":"p","result":"skipped","reason":"pinned","detail":"pinned","session_id":""}
            {"name":"l","result":"skipped","reason":"live","detail":"session is live","session_id":""}
            {"name":"c","result":"failed","reason":"io_error","detail":"Permission denied","session_id":""}
            {"ok":2,"skipped":2,"failed":1}

            """
        let r = AgentIsland.actionResult(status: 1, output: Data(out.utf8))
        XCTAssertEqual(r.json.count, 5, "the closing count line has no name: text, not a result")
        XCTAssertEqual(AgentIsland.tally(r, .clear, title: "Clear unpinned", empty: "nothing to clear"),
                       "2 cleared, 1 failed, 2 skipped")
        let none = AgentIsland.actionResult(status: 0, output: Data(#"{"ok":0,"skipped":0,"failed":0}"#.utf8))
        XCTAssertEqual(AgentIsland.tally(none, .clear, title: "Clear unpinned", empty: "nothing to clear"), "nothing to clear")
        XCTAssertEqual(AgentIsland.Verb.clear.minutes, 5, "the runner's default bound")
        XCTAssertEqual(AgentIsland.Verb.stop.minutes, 15)
    }

    /// Clear unpinned: shows with an unpinned record (counted past the cap), the
    /// first press only asks, Cancel runs nothing, Clear runs --forget --all once
    /// per History dir, then the tally and one re-read per dir.
    @MainActor
    func testClearUnpinnedAsksFirstAndRunsOncePerDir() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = (0..<55).map { record("u\($0)", ended: TimeInterval(1000 - $0)) }
            + [record("e", dir: "/e", ended: 1), pinned("p", ended: 2)]
        let c = controller(f, reads, dch: Self.v125, dirs: ["/d", "/e"])
        c.store?.sessions = [session("a", version: "1.25.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 57 }
        let store = try XCTUnwrap(c.store)
        c.showHistory()
        settle(c)
        XCTAssertEqual(store.unpinnedCount, 56, "every record, not the 50 shown")
        XCTAssertEqual(store.clearUnpinnedButton, "Clear unpinned")
        c.askClearUnpinned()
        XCTAssertTrue(store.confirmingClear)
        XCTAssertTrue(store.showsHistoryHeader)
        XCTAssertEqual(AgentIsland.clearQuestion(store.unpinnedCount), "Clear 56 unpinned?")
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "the first press runs nothing")
        c.confirmClearUnpinned(false)
        XCTAssertFalse(store.confirmingClear)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [], "Cancel: no verb")
        c.askClearUnpinned()
        c.askStopAll()
        XCTAssertFalse(store.confirmingClear, "one question at a time")
        c.askClearUnpinned()
        XCTAssertFalse(store.confirmingStopAll)
        let before = reads.count
        c.confirmClearUnpinned(true)
        c.confirmClearUnpinned(true)   // the question is gone: a second answer runs nothing
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.args, [AgentIsland.forgetAllArgs, AgentIsland.forgetAllArgs])
        XCTAssertEqual(Set(f.lock.withLock { f.launches.compactMap(\.dir) }), ["/d", "/e"])
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], AgentIsland.clearingText)
        f.output = #"{"name":"u0","result":"ok","reason":"","detail":"forgotten","session_id":""}"# + "\n"
            + #"{"name":"p","result":"skipped","reason":"pinned","detail":"pinned","session_id":""}"# + "\n"
        f.release.signal(); f.release.signal()
        settle(c) { reads.count >= before + 2 && !store.actions.values.contains(AgentIsland.clearingText) }
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], "1 cleared, 1 skipped")
        XCTAssertEqual(reads.count, before + 2, "one History read per finished dir")
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args.count, 2)
        store.history = [pinned("p")]
        XCTAssertNil(store.clearUnpinnedButton, "nothing unpinned: no Clear")
        c.askClearUnpinned()
        XCTAssertFalse(store.confirmingClear)
    }

    /// VoiceOver: "pinned" in the row's label, and the buttons' names.
    @MainActor
    func testVoiceOverLabelsForPinAndRemove() {
        let p = pinned("p"), x = record("x")
        func label(_ r: DchHistoryRecord) -> String {
            AgentIsland.historyRowAccessibilityLabel(r, status: nil, end: "crashed (signal 9)", age: "2m", cwd: "/src",
                                                     show: AgentIslandRowDetails())
        }
        XCTAssertEqual(label(p), "p, pinned, crashed (signal 9), 2m ago, /src")
        XCTAssertEqual(label(x), "x, crashed (signal 9), 2m ago, /src")
        func row(_ r: DchHistoryRecord) -> AgentIslandHistoryRow {
            AgentIslandHistoryRow(record: r, now: 0, status: nil, enabled: true, action: {}, pin: {}, remove: nil)
        }
        XCTAssertEqual(row(p).pinLabel, "Unpin")
        XCTAssertEqual(row(x).pinLabel, "Pin")
        XCTAssertEqual(AgentIsland.removeLabel, "Remove from History")
    }

    /// Visual evidence at UI scale 0.7, 0.85 and 1.0 (the island draws at fixed
    /// sizes): pinned and unpinned rows, the Clear confirm, and the same tab under
    /// 1.24.1 with no pin, X or Clear (a different render). Offscreen only.
    @MainActor
    func testRendersHistoryPinsAndClearConfirmOffscreen() throws {
        let now = Date().timeIntervalSince1970
        let store = AgentIslandStore(geometry: notched, details: AgentIslandRowDetails())
        store.sessions = [session("prosper-main", version: "1.25.0")]
        store.controlDch = Self.v125
        var a = pinned("prosper-main", ended: now - 120)
        a.alias = "Prosper"
        a.cwd = NSHomeDirectory() + "/personal/prosper"
        var b = pinned("dch", ended: now - 86400 * 4)
        b.cwd = NSHomeDirectory() + "/personal/dch"
        var c = record("ios", ended: now - 7200, end: "exit 1")
        c.cwd = NSHomeDirectory() + "/personal/prosper-ios"
        let d = record("scratch", ended: now - 90000, end: "killed")
        var e = record("review", ended: now - 600, end: "stopped")
        e.cwd = NSHomeDirectory() + "/personal/prosper"
        store.history = [a, e, c, d, b]
        store.actions[AgentSessionKey(dir: "/d", name: "")] = "Remove ios failed: session is live"
        store.historyTab = true
        store.expanded = true
        XCTAssertEqual(store.shownHistory.map(\.name), ["prosper-main", "dch", "review", "ios", "scratch"])
        let out = tempDir(), saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        func pixels() throws -> Data {
            let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
            r.scale = 1
            return try XCTUnwrap(try XCTUnwrap(r.cgImage).dataProvider?.data) as Data
        }
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            store.confirmingClear = false
            try render(store, "agent-island-605-history-pins-\(scale)", to: out)
            store.confirmingClear = true
            try render(store, "agent-island-605-clear-confirm-\(scale)", to: out)
        }
        store.confirmingClear = false
        let edits = try pixels()
        store.controlDch = Self.v1241
        store.sessions = [session("prosper-main", version: "1.24.1")]
        XCTAssertNotEqual(edits, try pixels(), "under 1.25.0: no pin, X or Clear drawn")
        try render(store, "agent-island-605-history-gated-1.24.1", to: out)
    }

    // MARK: - #627: a name dch would read as a flag; Clear's question

    /// dch's argv has no "--": every verb that names a session refuses a name
    /// starting with '-' ("--all" would be `--forget --all`); a batch refuses whole.
    func testNamedVerbsRefuseADashLedName() {
        for bad in ["--all", "-n"] {
            XCTAssertNil(AgentIsland.reviveArgs(record(bad), live: [], records: []), bad)
            XCTAssertNil(AgentIsland.reviveArgs(record(bad), live: [bad], records: []), "\(bad) live: no --as either")
            XCTAssertNil(AgentIsland.restartArgs(bad), bad)
            XCTAssertNil(AgentIsland.stopArgs(["a", bad]), "\(bad): the whole batch, never just the rest")
            XCTAssertNil(AgentIsland.pinArgs([bad], pin: true), bad)
            XCTAssertNil(AgentIsland.pinArgs([bad], pin: false), bad)
            XCTAssertNil(AgentIsland.forgetArgs([bad]), bad)
        }
        XCTAssertEqual(AgentIsland.stopArgs(["a", "b-n"]), ["--stop", "a", "b-n", "--json"], "a dash inside a name passes")
        XCTAssertEqual(AgentIsland.forgetArgs(["x"]), ["--forget", "x", "--json"])
    }

    /// History: a "--all" or "-n" record draws no Resume, pin or X, and the
    /// controller runs nothing for it; a normal record next to them works.
    @MainActor
    func testDashLedHistoryRowsGetNoControlsAndRunNothing() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("--all", ended: 3), record("-n", ended: 2), record("x", ended: 1)]
        let c = controller(f, reads, dch: Self.v125)
        c.store?.sessions = [session("live", version: "1.25.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 3 }
        let store = try XCTUnwrap(c.store)
        store.historyTab = true
        let rows = AgentIslandView(store: store, onResume: { c.resume($0) }, onPin: { c.pin($0) },
                                   onRemove: { c.remove($0) }).historyDrawn
        XCTAssertEqual(rows.map(\.record.name), ["--all", "-n", "x"])
        XCTAssertEqual(rows.map(\.enabled), [false, false, true], "no Resume")
        XCTAssertEqual(rows.map { $0.pin != nil }, [false, false, true], "no pin")
        XCTAssertEqual(rows.map { $0.remove != nil }, [false, false, true], "no X")
        for r in rows.prefix(2) {
            r.resume()
            c.pin(r.record)
            c.remove(r.record)
            c.pin(pinned(r.record.name))   // an unpin
        }
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "nothing runs for a dash-led name")
        XCTAssertEqual(f.args, [])
        XCTAssertEqual(store.historyActions, [:])
        XCTAssertEqual(store.actions, [:])
        let before = reads.count
        rows[2].remove?()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--forget", "x", "--json"]], "a normal name is unaffected")
        f.release.signal()
        settle(c) { reads.count > before }
    }

    /// Sessions: a live "--all" or "-n" draws no Restart or Stop, Stop all leaves
    /// it out, and the controller runs nothing for it; "a" next to them works.
    @MainActor
    func testDashLedSessionsGetNoRestartOrStopAndRunNothing() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads)
        c.store?.sessions = [session("--all", version: "1.24.1"), session("-n", version: "1.24.1"),
                             session("a", version: "1.24.1")]
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil && c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        let drawn = AgentIslandView(store: store, onRestart: { c.restart($0) }, onStop: { c.stop($0) }).drawn
        let bad = drawn.filter { $0.session.name.hasPrefix("-") }
        let good = try XCTUnwrap(drawn.first { $0.session.name == "a" })
        XCTAssertEqual(bad.count, 2)
        for r in bad {
            XCTAssertFalse(r.controls, r.session.name)
            XCTAssertFalse(r.restartEnabled, r.session.name)
            XCTAssertFalse(r.stopEnabled, r.session.name)
            r.restart()
            r.stop()
        }
        XCTAssertTrue(good.controls)
        XCTAssertTrue(good.restartEnabled)
        XCTAssertTrue(good.stopEnabled)
        XCTAssertEqual(store.stopTargets(global: false).stop.map(\.name), ["a"])
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "nothing runs for a dash-led name")
        XCTAssertEqual(f.args, [])
        XCTAssertEqual(store.actions, [:])
        c.askStopAll()
        c.confirmStopAll(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--stop", "a", "--json"]], "Stop all names only a")
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != nil }
    }

    /// LOW-1: Clear's answer runs only while its question is up: never with none
    /// asked, and never again once a Clear has finished (its dir key is free then).
    @MainActor
    func testClearAnswerWithNoQuestionUpRunsNothing() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("u"), pinned("p", ended: 50)]
        let c = controller(f, reads, dch: Self.v125)
        c.store?.sessions = [session("a", version: "1.25.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        let store = try XCTUnwrap(c.store)
        c.showHistory()
        settle(c)
        XCTAssertNotNil(store.clearUnpinnedButton)
        c.confirmClearUnpinned(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "no question asked: no --forget --all")
        c.askClearUnpinned()
        c.confirmClearUnpinned(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        let before = reads.count
        f.release.signal()
        settle(c) { reads.count > before && !store.actions.values.contains(AgentIsland.clearingText) }
        XCTAssertFalse(c.runner.isBusy(AgentSessionKey(dir: "/d", name: "")), "the Clear finished")
        c.confirmClearUnpinned(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "the answered question is gone")
        XCTAssertEqual(f.args, [AgentIsland.forgetAllArgs])
    }

    /// I4: "Clear N unpinned?" goes once a re-read leaves nothing unpinned.
    @MainActor
    func testClearQuestionGoesWhenNothingUnpinnedIsLeft() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("u"), pinned("p", ended: 50)]
        let c = controller(f, reads, dch: Self.v125)
        c.store?.sessions = [session("a", version: "1.25.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        let store = try XCTUnwrap(c.store)
        c.showHistory()
        settle(c)
        c.askClearUnpinned()
        XCTAssertTrue(store.confirmingClear)
        reads.lock.withLock { reads.records = [record("v"), pinned("p", ended: 50)] }
        c.refreshHistory()
        settle(c) { store.history.first?.name == "v" }
        XCTAssertTrue(store.confirmingClear, "one left: the question stays")
        reads.lock.withLock { reads.records = [pinned("p", ended: 50)] }
        c.refreshHistory()
        settle(c) { store.history.count == 1 }
        XCTAssertEqual(store.unpinnedCount, 0)
        XCTAssertFalse(store.confirmingClear, "no \"Clear 0 unpinned?\"")
        c.confirmClearUnpinned(true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(f.args, [])
    }

    // MARK: - #669: Resume (no message)

    private static let v126 = DchCommand.Binary(path: "/fake/dch", version: [1, 26, 9])
    private static let v127 = DchCommand.Binary(path: "/fake/dch", version: [1, 27, 0])

    /// `--no-message` after the name (and `--as`), before `--json`; without it, the argv is unchanged.
    func testReviveNoMessageArgsWithAndWithoutAs() {
        XCTAssertEqual(AgentIsland.reviveArgs(record("a"), live: [], records: [], noMessage: true),
                       ["--revive", "a", "--no-message", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(record("a"), live: ["a"], records: ["a-2"], noMessage: true),
                       ["--revive", "a", "--as", "a-3", "--no-message", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(record("a"), live: [], records: []), ["--revive", "a", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(record("a"), live: ["a"], records: []), ["--revive", "a", "--as", "a-2", "--json"])
        XCTAssertNil(AgentIsland.reviveArgs(record("--all"), live: [], records: [], noMessage: true), "#627 holds")
        XCTAssertEqual(AgentIsland.reviveAllNoMessageArgs, ["--revive", "--all", "--no-message", "--json"])
        XCTAssertEqual(AgentIsland.reviveAllArgs, ["--revive", "--all", "--json"])
    }

    /// 1.27.0 for the control dch and every live master ("" passes); a 1.26 master
    /// does not block a 1.27 control dch. Refused: no row icon, no header choice; Resume stays.
    @MainActor
    func testReviveNoMessageGateNeeds127AndHidesItsControls() {
        XCTAssertEqual(AgentIsland.reviveNoMessageMinimum, [1, 27, 0])
        let store = AgentIslandStore(geometry: notched)
        let now = Date().timeIntervalSince1970
        store.now = { now }
        store.history = [record("x", ended: now - 600), pinned("p", ended: now - 700), record("--all", ended: now - 800)]
        store.historyTab = true
        func drawn() -> [AgentIslandView.HistoryDrawn] { AgentIslandView(store: store).historyDrawn }
        for (dch, masters, gate) in [
            (Self.v126, [""], DchCommand.Gate.refused("needs dch 1.27.0")),
            (Self.v126, ["1.26.0"], .refused("needs dch 1.27.0")),
            (Self.v127, ["", "1.26.0"], .ok("/fake/dch")),
            (Self.v127, ["1.27.0"], .ok("/fake/dch")),
            (Self.v127, ["1.28.0"], .refused("needs dch 1.28.0")),
        ] {
            store.controlDch = dch
            store.sessions = masters.enumerated().map { session("s\($0.offset)", version: $0.element) }
            XCTAssertEqual(store.reviveNoMessageGate, gate, "\(dch.version) \(masters)")
            let on = gate.isOK
            XCTAssertEqual(drawn().map { $0.resumeNoMessage != nil }, [on, on, false], "drawn only with the gate; #627 never")
            XCTAssertEqual(drawn().map(\.enabled), [store.resumeGate.isOK, store.resumeGate.isOK, false], "Resume unchanged")
        }
        store.controlDch = Self.v126
        store.sessions = []
        XCTAssertTrue(store.resumeGate.isOK)
        XCTAssertNotNil(store.resumeAllButton, "1.26: Resume interrupted stays")
        store.controlDch = nil
        XCTAssertEqual(store.reviveNoMessageGate, .refused("needs dch 1.27.0"))
    }

    /// The drawn icon and the row's VoiceOver action run the row's own record with no message.
    @MainActor
    func testDrawnResumeNoMessageCarriesItsRecordAndIsAVoiceOverAction() {
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = Self.v127
        store.history = [record("x", ended: 3), record("y", ended: 2)]
        store.historyTab = true
        var quiet: [String] = [], plain: [String] = []
        let view = AgentIslandView(store: store, onResume: { plain.append($0.name) },
                                   onResumeNoMessage: { quiet.append($0.name) })
        for r in view.historyDrawn { r.resumeNoMessage?() }
        XCTAssertEqual(quiet, ["x", "y"])
        XCTAssertEqual(plain, [], "never the plain Resume")
        XCTAssertEqual(AgentIsland.resumeNoMessageLabel, "Resume (no message)")
        XCTAssertEqual(AgentIsland.resumeAllNoMessageAccessibility(2), "Resume interrupted (2) without the message")
    }

    /// #742: a History row's right-click menu draws each item only under its own
    /// gate: Resume (resumeGate), Resume (no message) (1.27.0), Pin/Unpin and
    /// Remove (1.25.0, no Remove on a pin); a dash-led name gets nothing.
    @MainActor
    func testHistoryMenuItemsFollowTheirGates() {
        let store = AgentIslandStore(geometry: notched)
        let now = Date().timeIntervalSince1970
        store.now = { now }
        store.history = [record("x", ended: now - 600), pinned("p", ended: now - 700), record("--all", ended: now - 800)]
        store.historyTab = true
        func menus() -> [[String]] { AgentIslandView(store: store).historyDrawn.map { $0.menu.map(\.title) } }
        let both = ["Resume", "Resume (no message)"]
        store.controlDch = Self.v127
        XCTAssertEqual(menus(), [both + ["Unpin"], both + ["Pin", "Remove from History"], []], "a pin leads")
        store.controlDch = Self.v125
        XCTAssertEqual(menus(), [["Resume", "Unpin"], ["Resume", "Pin", "Remove from History"], []], "1.25: no no-message")
        store.controlDch = Self.v1241
        XCTAssertEqual(menus(), [["Resume"], ["Resume"], []], "1.24.1: Resume only")
        store.controlDch = nil
        XCTAssertEqual(menus(), [[], [], []], "Resume refused: an empty menu")
        XCTAssertEqual(AgentIsland.resumeWithMessageHelp, "Resume with dch's carry-on message")
    }

    /// #742: each menu item runs its own verb: Resume is `--revive x --json` (dch
    /// types its carry-on message), Resume (no message) adds `--no-message`.
    @MainActor
    func testHistoryMenuItemsRunTheirArgs() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads, dch: Self.v127)
        c.store?.sessions = [session("live", version: "1.27.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        store.historyTab = true
        let row = try XCTUnwrap(AgentIslandView(store: store, onResume: { c.resume($0) },
                                                onResumeNoMessage: { c.resume($0, noMessage: true) },
                                                onPin: { c.pin($0) }, onRemove: { c.remove($0) }).historyDrawn.first)
        let item = Dictionary(uniqueKeysWithValues: row.menu.map { ($0.title, $0.action) })
        for (title, args) in [("Resume", ["--revive", "x", "--json"]),
                              ("Resume (no message)", ["--revive", "x", "--no-message", "--json"]),
                              ("Pin", ["--pin", "x", "--json"]), ("Remove from History", ["--forget", "x", "--json"])] {
            let before = reads.count
            try XCTUnwrap(item[title], title)()
            XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success, title)
            XCTAssertEqual(f.args.last, args, title)
            f.release.signal()
            settle(c) { reads.count > before }
        }
        XCTAssertEqual(f.args.count, 4)
    }

    /// The JSON has no "resuming" phase: "starting", then an ok result; the row says
    /// the message was skipped, under the 1.27.0 gate; a 1.26 control dch runs nothing.
    @MainActor
    func testRowResumeNoMessageRunsNoMessageArgsAndSaysSo() throws {
        let f = FakeProc(), reads = Reads()
        let x = record("x"), y = record("y")
        reads.records = [x, y]
        let c = controller(f, reads, dch: Self.v126)
        c.store?.sessions = [session("live", version: "1.26.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        let store = try XCTUnwrap(c.store)
        c.resume(x, noMessage: true)
        c.resumeCrashed(noMessage: true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 0.3), .timedOut, "1.26: refused")
        XCTAssertEqual(f.args, [])
        XCTAssertEqual(store.historyActions, [:])
        c.controlDch = { Self.v127 }
        c.refreshHistory()
        settle(c) { store.controlDch == Self.v127 }
        f.progress = #"{"name":"x","phase":"starting"}"# + "\n"
        c.resume(x, noMessage: true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "x", "--no-message", "--json"]])
        settle(c) { store.historyActions[x.key] == "Starting…" }
        f.output = #"{"name":"x","result":"ok","reason":"","detail":"revived x; resume message not sent","session_id":"s"}"# + "\n"
        f.release.signal()
        settle(c) { store.historyActions[x.key] != "Starting…" }
        XCTAssertEqual(store.historyActions[x.key], "Resumed without the message")
    }

    /// Resume interrupted's "(no message)": `--revive --all --no-message --json` per dir;
    /// the row and the dir tally say the message was skipped.
    @MainActor
    func testResumeAllNoMessageRunsPerDirAndTallies() throws {
        let f = FakeProc(), reads = Reads()
        let x = record("x")
        reads.records = [x]
        let c = controller(f, reads, dch: Self.v127)
        c.store?.sessions = [session("x", version: "1.27.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        f.progress = #"{"name":"x","phase":"starting"}"# + "\n"
        c.resumeCrashed(noMessage: true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "--all", "--no-message", "--json"]])
        settle(c) { store.historyActions[x.key] == "Starting…" }
        f.output = #"{"name":"x","as":"x-2","result":"ok","reason":"","detail":"resume message not sent","session_id":""}"# + "\n"
        f.release.signal()
        let all = AgentSessionKey(dir: "/d", name: "")
        settle(c) { store.actions[all] != AgentIsland.resumingText }
        XCTAssertEqual(store.actions[all], "1 resumed without the message")
        XCTAssertEqual(store.historyActions[x.key], "Resumed as x-2 without the message")
    }

    /// Texts: a no-message result never reads as dch-lite's "not typed"; failures name the verb.
    func testNoMessageResultTexts() {
        func row(_ out: String, status: Int32 = 0) -> String { AgentIsland.rowText(result(out, status: status), name: "a", .resumeNoMessage) }
        XCTAssertEqual(row(#"{"name":"a","phase":"starting"}"# + "\n" + #"{"name":"a","result":"ok","reason":"","detail":"","session_id":""}"#),
                       "Resumed without the message")
        XCTAssertEqual(row(#"{"name":"a","result":"ok","reason":"no_screen","detail":"","session_id":""}"#), "Resumed without the message")
        XCTAssertEqual(row("dch: unknown option --no-message", status: 2), "Resume (no message) failed: dch: unknown option --no-message")
        XCTAssertEqual(row(#"{"name":"a","result":"failed","reason":"no_history","detail":"a: no history for this session","session_id":""}"#, status: 1),
                       "no history for this session", "failure reasons unchanged")
        XCTAssertEqual(AgentIsland.rowText(result("", status: 143, stopped: true), name: "a", .resumeNoMessage),
                       "Resume (no message) cancelled: no answer in 5m")
    }

    /// Visual evidence at UI scale 0.7, 0.85 and 1.0: History rows with the no-message
    /// icon beside the pin and X, and the header's "(no message)" next to Resume
    /// interrupted; then the same under 1.26 (no icon, no choice: a different render). Offscreen only.
    @MainActor
    func testRendersResumeNoMessageOffscreen() throws {
        let now = Date().timeIntervalSince1970
        let store = AgentIslandStore(geometry: notched, details: AgentIslandRowDetails())
        store.sessions = [session("prosper-main", version: "1.27.0")]
        store.controlDch = Self.v127
        var a = pinned("prosper-main", ended: now - 120)
        a.alias = "Prosper"
        a.cwd = NSHomeDirectory() + "/personal/prosper"
        var c = record("ios", ended: now - 7200, end: "signal 9")
        c.cwd = NSHomeDirectory() + "/personal/prosper-ios"
        var e = record("review", ended: now - 600, end: "exit 1")
        e.cwd = NSHomeDirectory() + "/personal/prosper"
        store.history = [a, e, c]
        store.historyActions[e.key] = "Resumed without the message"
        store.historyTab = true
        store.expanded = true
        XCTAssertNotNil(store.resumeAllButton)
        let out = tempDir(), saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        func pixels() throws -> Data {
            let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
            r.scale = 1
            return try XCTUnwrap(try XCTUnwrap(r.cgImage).dataProvider?.data) as Data
        }
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            try render(store, "agent-island-669-no-message-\(scale)", to: out)
        }
        let quiet = try pixels()
        store.controlDch = Self.v126
        store.sessions = [session("prosper-main", version: "1.26.0")]
        XCTAssertNotEqual(quiet, try pixels(), "under 1.27.0: no icon, no header choice")
        try render(store, "agent-island-669-gated-1.26", to: out)
    }

    // MARK: - #714: dch 1.28.0 aside records ("file")

    /// dch 1.28.0's --history --json (do_history_verb): the name's own record, then
    /// two a cold start under "work" moved aside, each the stored body plus
    /// "pinned" (when pinned), then "file".
    private static let asideJSON = #"""
    [{"name":"work","sock_dir":"/d","alias":"","cwd":"/src","argv":["claude"],"started":1762000500,"updated":1762003000,"ended":1762003000,"end":"stopped","agent":{"kind":"claude","session_id":"new","name":"","cwd":"/src","launch":[]}},
     {"name":"work","sock_dir":"/d","alias":"","cwd":"/src","argv":["claude"],"started":1761990000,"updated":1762000000,"ended":1762000000,"end":"signal 9","agent":{"kind":"claude","session_id":"mid","name":"","cwd":"/src","launch":[]},"pinned":true,"file":"work.1762000000"},
     {"name":"work","sock_dir":"/d","alias":"","cwd":"/src","argv":["claude"],"started":1760990000,"updated":1761000000,"ended":1761000000,"end":"stopped","agent":{"kind":"claude","session_id":"old","name":"","cwd":"/src","launch":[]},"file":"work.1761000000"}]
    """#

    private static var asideRecords: [DchHistoryRecord] { AgentIsland.parseHistory(Data(asideJSON.utf8), dir: "/d") }

    /// Three records of one name: one id each (an aside record's is its file), and
    /// History keeps all three. #743: it draws one row, the name's newest, the others folded.
    @MainActor
    func testAsideRecordsParseWithAnIdEach() {
        let rows = Self.asideRecords
        XCTAssertEqual(rows.map(\.name), ["work", "work", "work"])
        XCTAssertEqual(rows.map(\.id), [AgentSessionKey(dir: "/d", name: "work"), AgentSessionKey(dir: "/d", name: "work.1762000000"),
                                        AgentSessionKey(dir: "/d", name: "work.1761000000")])
        XCTAssertEqual(rows.map(\.pinned), [false, true, false])
        XCTAssertEqual(rows.map { $0.agent?.sessionID }, ["new", "mid", "old"])
        XCTAssertEqual(AgentIsland.history(dirs: ["/d"]) { _, _ in Data(Self.asideJSON.utf8) }.map(\.id), rows.map(\.id))
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = Self.v125
        store.history = rows
        store.historyTab = true
        let drawn = AgentIslandView(store: store).historyDrawn
        XCTAssertEqual(drawn.map(\.id), [rows[0].id], "#743: one row per name")
        XCTAssertEqual(drawn.map(\.older), [2])
    }

    /// Resume of an aside record passes its file; the name's own record passes the name.
    /// The status stays on the record acted on, never its namesakes. #743: the pin and X
    /// are the one row's, the bare name below 1.28.1; the row shows its own record's
    /// status, else an older one's.
    @MainActor
    func testAsideRowActionsTargetTheirFileAndStatusStaysOnTheRow() throws {
        let f = FakeProc(), reads = Reads()
        let rows = Self.asideRecords
        reads.records = rows
        let c = controller(f, reads, dch: Self.v125)
        c.store?.sessions = [session("b", version: "1.25.0")]   // an island to open; work is not live
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 3 }
        let store = try XCTUnwrap(c.store)
        func step(_ press: () -> Void, _ args: [String], line: UInt = #line) {
            let before = reads.count
            press()
            XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success, line: line)
            XCTAssertEqual(f.args.last, args, line: line)
            f.release.signal()
            settle(c) { reads.count == before + 1 }
        }
        f.progress = #"{"name":"work","phase":"starting"}"# + "\n"
        c.resume(rows[2])
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args.last, ["--revive", "work.1761000000", "--json"], "work is not live: it comes back as work")
        settle(c) { store.historyActions[rows[2].id] == "Starting…" }
        XCTAssertEqual(store.historyActions[rows[2].id], "Starting…", "dch's line names work; the row is the file's")
        XCTAssertNil(store.historyActions[rows[0].id], "never on the name's own row")
        f.progress = ""
        f.output = #"{"name":"work","as":"work","result":"ok","reason":"","detail":"revived as work in /src","session_id":"old"}"# + "\n"
        f.release.signal()
        settle(c) { store.historyActions[rows[2].id] == "Resumed" && reads.count == 2 }
        settle(c)   // the re-read lands: the status stays on its record's id
        XCTAssertEqual(store.historyActions[rows[2].id], "Resumed")
        XCTAssertNil(store.historyActions[rows[0].id])
        XCTAssertNil(store.historyActions[rows[1].id])
        f.output = ""
        store.sessions = [session("b", version: "1.25.0"), session("work", version: "1.25.0")]
        f.output = #"{"name":"work","as":"work-2","result":"ok","reason":"","detail":"","session_id":"mid"}"# + "\n"
        step({ c.resume(rows[1]) }, ["--revive", "work.1762000000", "--as", "work-2", "--json"])
        XCTAssertEqual(store.historyActions[rows[1].id], "Resumed as work-2", "dch's result line, read by the record's name")
        f.output = ""
        step({ c.pin(rows[0]) }, ["--pin", "work", "--json"])
        step({ c.remove(rows[0]) }, ["--forget", "work", "--json"])
        XCTAssertEqual(f.args.count, 4)
        store.historyActions = [rows[2].id: "Resumed"]
        store.historyTab = true
        func statuses() -> [String?] { AgentIslandView(store: store).historyDrawn.map { $0.status } }
        XCTAssertEqual(statuses(), ["Resumed"], "an older record's status, while the row's own has none")
        store.historyActions[rows[1].id] = "Resumed as work-2"
        XCTAssertEqual(statuses(), ["Resumed as work-2"], "the newest older record's first")
        store.historyActions[rows[0].id] = "Resuming…"
        XCTAssertEqual(statuses(), ["Resuming…"], "the row's own record's first")
    }

    /// Resume interrupted's line names only "work": it shows on the row of the record
    /// dch's --all takes (#716 L-1: rv_all_takes skips the stopped own record and
    /// revives the crashed aside one), the newest such; with none, the name's newest.
    /// Never on every row of the name.
    @MainActor
    func testResumeAllLineLandsOnTheRecordDchRevives() throws {
        let f = FakeProc(), reads = Reads()
        let rows = Self.asideRecords
        reads.records = rows
        let c = controller(f, reads)
        c.store?.sessions = [session("b", version: "1.24.1")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 3 }
        let store = try XCTUnwrap(c.store)
        store.now = { 1_762_003_060 }   // the crashed aside (ended 1762000000, ran 10000 s) is --all's
        f.progress = #"{"name":"work","phase":"starting"}"# + "\n"
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        settle(c) { store.historyActions[rows[1].id] == "Starting…" }
        XCTAssertEqual(store.historyActions, [rows[1].id: "Starting…"], "the crashed aside's row, not the stopped own one")
        f.progress = ""
        f.output = #"{"name":"work","as":"work","result":"ok","reason":"","detail":"","session_id":"mid"}"# + "\n"
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.resumingText }
        XCTAssertEqual(store.historyActions[rows[1].id], "Resumed")
        XCTAssertNil(store.historyActions[rows[0].id])
        f.output = ""
        // No record of the name is --all's by the Mac's clock: the name's newest row.
        store.now = { 1_762_003_060 + 4 * 86_400 }
        store.historyActions = [:]
        f.progress = #"{"name":"work","phase":"starting"}"# + "\n"
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        settle(c) { store.historyActions[rows[0].id] == "Starting…" }
        XCTAssertEqual(store.historyActions, [rows[0].id: "Starting…"])
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.resumingText }
        // work is live again: History holds only its aside records; the line lands on the one --all takes.
        reads.records = Array(rows.dropFirst())
        c.refreshHistory()
        settle(c) { store.history.count == 2 }
        store.now = { 1_762_003_060 }
        store.historyActions = [:]
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        settle(c) { store.historyActions[rows[1].id] == "Starting…" }
        XCTAssertEqual(store.historyActions, [rows[1].id: "Starting…"])
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.resumingText }
    }

    /// A pin or X on the name's row says it covers the name's older records too
    /// (dch 1.28.0 matches them all by the bare name). #743: the only row of the name.
    /// #716 L-2: the X's count leaves out a pinned aside record (dch keeps it).
    @MainActor
    func testOwnRowsPinAndXSayTheyCoverOlderRecords() throws {
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = Self.v125
        store.history = Self.asideRecords
        store.historyTab = true
        let drawn = AgentIslandView(store: store).historyDrawn
        XCTAssertEqual(drawn.map(\.id.name), ["work"])
        XCTAssertEqual(drawn.map(\.older), [2])
        XCTAssertEqual(drawn.map(\.olderUnpinned), [1])
        func row(_ file: String) throws -> AgentIslandHistoryRow {
            let d = try XCTUnwrap(drawn.first { $0.id.name == file })
            return AgentIslandHistoryRow(record: d.record, now: 0, status: nil, enabled: true, action: {}, pin: {}, remove: {},
                                         older: d.older, olderUnpinned: d.olderUnpinned)
        }
        XCTAssertEqual(try row("work").pinLabel, "Pin (also 2 older records of this name)")
        XCTAssertEqual(try row("work").removeLabel, "Remove from History (also 1 older record of this name)",
                       "the pinned work.1762000000 stays")
        XCTAssertEqual(AgentIsland.editLabel("Unpin", older: 1), "Unpin (also 1 older record of this name)")
    }

    /// dch 1.28.0's new revive and stop reasons read in words; a line's Claude id
    /// shows where dch's detail does not carry it. Remove's "live" stays dch's.
    func testNewReviveAndStopReasonsReadInWords() {
        func row(_ o: [String: String], _ verb: AgentIsland.Verb, name: String = "a") -> String {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
            return AgentIsland.rowText(result(line, status: 1), name: name, verb)
        }
        let lossy = "NOT revived — its command had bytes that are not UTF-8, recorded as U+FFFD: it would run "
            + "something else; resume by hand: claude --resume abc"
        XCTAssertEqual(row(["name": "a", "as": "a", "result": "failed", "reason": "not_utf8", "detail": lossy, "session_id": "abc"], .resume),
                       "Not resumed: its record has bytes that are not UTF-8; claude --resume abc")
        XCTAssertEqual(row(["name": "a", "as": "a", "result": "failed", "reason": "not_utf8", "detail": "", "session_id": ""], .resumeNoMessage),
                       "Not resumed: its record has bytes that are not UTF-8")
        XCTAssertEqual(row(["name": "a", "as": "a", "result": "failed", "reason": "live", "detail": "session a is live",
                            "session_id": "abc"], .resume), "Not resumed: a is running")
        XCTAssertEqual(row(["name": "a", "as": "a-2", "result": "failed", "reason": "live", "detail": "", "session_id": ""], .resume),
                       "Not resumed: a-2 is running")
        XCTAssertEqual(row(["name": "a", "result": "failed", "reason": "claude_unreadable",
                            "detail": "a claude runs in it, but no session record of it can be read; left running", "session_id": ""], .stop),
                       "Not stopped: its Claude session record can't be read; left running")
        XCTAssertEqual(row(["name": "a", "result": "interrupted", "reason": "signal",
                            "detail": "interrupted (signal 15) while waiting for it to pause; resume message typed",
                            "session_id": "abc"], .stop),
                       "interrupted (signal 15) while waiting for it to pause; resume message typed (claude --resume abc)")
        XCTAssertEqual(row(["name": "a", "result": "interrupted", "reason": "signal", "detail": "", "session_id": "abc"], .stop),
                       "Stop interrupted (claude --resume abc)")
        let exited = "interrupted (signal 2) after /exit; resume by hand: claude --resume abc"
        XCTAssertEqual(row(["name": "a", "result": "interrupted", "reason": "signal", "detail": exited, "session_id": "abc"], .stop),
                       exited, "the id once")
        XCTAssertEqual(row(["name": "a", "result": "failed", "reason": "live", "detail": "session is live", "session_id": ""], .remove),
                       "session is live", "forget's live is no Resume")
    }

    // MARK: - #714 round 2: dch 1.28.1 "file" on every record, `<file>.json` edits

    private static let v1281 = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 1])

    /// dch 1.28.1's --history --json (do_history_verb): the same three records, the
    /// name's own now with its file too ("work").
    private static let fileJSON = asideJSON.replacingOccurrences(
        of: #""session_id":"new","name":"","cwd":"/src","launch":[]}}"#,
        with: #""session_id":"new","name":"","cwd":"/src","launch":[]},"file":"work"}"#)

    private static var fileRecords: [DchHistoryRecord] { AgentIsland.parseHistory(Data(fileJSON.utf8), dir: "/d") }

    /// The own record's file is its name: not aside. Ids match 1.28.0's; an edit
    /// target is `<file>.json` when exact, else round 1's (name, or the aside file).
    func testRecordFileOnEveryRecordKeepsTheOwnRowAndItsId() {
        let rows = Self.fileRecords, old = Self.asideRecords
        XCTAssertEqual(rows.map(\.file), ["work", "work.1762000000", "work.1761000000"])
        XCTAssertEqual(rows.map(\.id), old.map(\.id), "1.28.0 and 1.28.1 output give the same ids")
        XCTAssertEqual(rows.map(\.isAside), [false, true, true])
        XCTAssertEqual(old.map(\.isAside), [false, true, true])
        XCTAssertEqual(rows.map(\.target), ["work", "work.1762000000", "work.1761000000"], "revive: unchanged")
        XCTAssertEqual(rows.map { $0.editTarget(exact: true) }, ["work.json", "work.1762000000.json", "work.1761000000.json"])
        XCTAssertEqual(rows.map { $0.editTarget(exact: false) }, ["work", "work.1762000000", "work.1761000000"])
        XCTAssertEqual(old[0].editTarget(exact: true), "work", "no file: the name")
    }

    /// #743: the "(also N older …)" note shows at every gate: the one row of the name
    /// acts on all its records (the bare name below 1.28.1, each `<file>.json` from it).
    @MainActor
    func testOlderRecordsNoteAtEveryGate() {
        for dch in [Self.v125, DchCommand.Binary(path: "/fake/dch", version: [1, 28, 0]), Self.v1281] {
            for records in [Self.asideRecords, Self.fileRecords] {
                let store = AgentIslandStore(geometry: notched)
                store.controlDch = dch
                store.history = records
                store.historyTab = true
                let drawn = AgentIslandView(store: store).historyDrawn
                XCTAssertEqual(drawn.map { [$0.id.name: $0.older] }, [["work": 2]], "\(dch.version) \(records.map(\.file))")
                // QA #534 S3: the X's count too (the pinned work.1762000000 is never removed).
                XCTAssertEqual(drawn.map(\.olderUnpinned), [1], "\(dch.version)")
            }
        }
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = Self.v1281
        store.sessions = [session("b", version: "1.29.0")]   // a newer live master: the gate refuses, round 1's note
        store.history = Self.fileRecords
        store.historyTab = true
        XCTAssertEqual(AgentIslandView(store: store).historyDrawn.first { $0.id.name == "work" }?.older, 2)
    }

    /// The row's pin and X pass `<file>.json` under 1.28.1, one per record of the name
    /// (#743: the X only the unpinned ones); below it the bare name. Resume stays name /
    /// aside file at both tiers. A failed pin's line, named after its argument, still
    /// reads dch's detail.
    @MainActor
    func testEditsPassTheRecordFileFrom1281() throws {
        for (dch, version, exact) in [(Self.v1281, "1.28.1", true), (Self.v125, "1.25.0", false)] {
            let f = FakeProc(), reads = Reads()
            let rows = Self.fileRecords
            reads.records = rows
            let c = controller(f, reads, dch: dch)
            c.store?.sessions = [session("b", version: version)]
            c.setExpanded(true)
            settle(c) { c.store?.history.count == 3 }
            let store = try XCTUnwrap(c.store)
            func step(_ press: () -> Void, _ args: [String], line: UInt = #line) {
                let before = reads.count
                press()
                XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success, line: line)
                XCTAssertEqual(f.args.last, args, "\(version)", line: line)
                f.release.signal()
                settle(c) { reads.count == before + 1 }
            }
            store.historyTab = true
            let row = try XCTUnwrap(AgentIslandView(store: store, onPin: { c.pin($0) }, onRemove: { c.remove($0) }).historyDrawn.first)
            XCTAssertEqual(row.id, rows[0].id)
            let all = exact ? ["work.json", "work.1762000000.json", "work.1761000000.json"] : ["work"]
            let unpinned = exact ? ["work.json", "work.1761000000.json"] : ["work"]
            step({ c.resume(rows[0]) }, ["--revive", "work", "--json"])
            step({ c.resume(rows[2]) }, ["--revive", "work.1761000000", "--json"])
            step({ row.pin?() }, ["--pin"] + all + ["--json"])
            step({ row.remove?() }, ["--forget"] + unpinned + ["--json"])
            f.output = #"{"name":"\#(all[0])","result":"failed","reason":"io_error","detail":"Permission denied"}"# + "\n"
            f.status = 1
            step({ row.pin?() }, ["--pin"] + all + ["--json"])
            XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], "Pin work failed: Permission denied", version)
            XCTAssertEqual(f.args.count, 5)
        }
    }

    // MARK: - #716: QA #530 follow-ups

    /// L-2: below 1.28.1 the own row's X forgets the name's records by the bare name;
    /// dch refuses a pinned aside one (its line carries that record's Claude id) and
    /// exits 1. The row went: no failure on the dir line. A pinned refusal of the
    /// row's own record (pinned since the read) still reads as one.
    @MainActor
    func testOwnRowsXIsNoFailureWhenDchKeepsAPinnedAside() throws {
        let f = FakeProc(), reads = Reads()
        let rows = Self.asideRecords
        reads.records = rows
        let c = controller(f, reads, dch: Self.v125)
        c.store?.sessions = [session("b", version: "1.25.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 3 }
        let store = try XCTUnwrap(c.store)
        let dirKey = AgentSessionKey(dir: "/d", name: "")
        func line(_ result: String, _ reason: String, _ detail: String, _ sid: String) -> String {
            #"{"name":"work","result":"\#(result)","reason":"\#(reason)","detail":"\#(detail)","session_id":"\#(sid)"}"#
        }
        func remove(_ lines: [String], line: UInt = #line) {
            let before = reads.count
            f.output = lines.joined(separator: "\n") + "\n"
            f.status = 1
            c.remove(rows[0])
            XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success, line: line)
            XCTAssertEqual(f.args.last, ["--forget", "work", "--json"], line: line)
            f.release.signal()
            settle(c) { reads.count == before + 1 }
        }
        // dch 1.28.0 (dch.c:7126-7159): one line per record of the name, newest first.
        remove([line("ok", "", "forgotten", "new"), line("failed", "pinned", "pinned (-f forgets it anyway)", "mid"),
                line("ok", "", "forgotten", "old")])
        XCTAssertNil(store.actions[dirKey], "the pinned aside is not this row")
        remove([line("failed", "pinned", "pinned (-f forgets it anyway)", "new"),
                line("failed", "pinned", "pinned (-f forgets it anyway)", "mid"), line("ok", "", "forgotten", "old")])
        XCTAssertEqual(store.actions[dirKey], "Remove work failed: \(AgentIsland.pinnedRefusal)", "its own record refused")
        store.actions[dirKey] = nil
        remove([line("ok", "", "forgotten", "new"), line("failed", "pinned", "pinned (-f forgets it anyway)", "mid"),
                line("failed", "io_error", "Permission denied", "old")])
        XCTAssertEqual(store.actions[dirKey], "Remove work failed: Permission denied", "another failure still reads")
        store.actions[dirKey] = nil
        remove([line("failed", "pinned", "pinned (-f forgets it anyway)", "")])
        XCTAssertEqual(store.actions[dirKey], "Remove work failed: \(AgentIsland.pinnedRefusal)", "no id: never taken for another record's")
    }

    /// L-3: a revive that matches nothing names its line after the argument (dch
    /// 1.28.0:6973-6977), the aside row's file: the row reads dch's detail.
    @MainActor
    func testAsideRowsNoHistoryReadsDchsDetail() throws {
        let f = FakeProc(), reads = Reads()
        let rows = Self.asideRecords
        reads.records = rows
        let c = controller(f, reads, dch: Self.v125)
        c.store?.sessions = [session("b", version: "1.25.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 3 }
        let store = try XCTUnwrap(c.store)
        f.output = #"{"name":"work.1761000000","as":"work.1761000000","result":"failed","reason":"no_history","#
            + #""detail":"no history for this session","session_id":""}"# + "\n"
        f.status = 1
        c.resume(rows[2])
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args.last, ["--revive", "work.1761000000", "--json"])
        f.release.signal()
        settle(c) { store.historyActions[rows[2].id] != AgentIsland.resumingText && reads.count == 2 }
        XCTAssertEqual(store.historyActions[rows[2].id], "no history for this session")
    }

    // MARK: - #719: dch 1.28.2 / 1.28.3

    private static let v1282 = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 2])
    private static let v1283 = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 3])
    private static let t719: TimeInterval = 1_762_100_000

    /// A record --all takes by `t719` (ran two hours, ended `ago` s before), its file and Claude id.
    private func rec719(_ file: String, name: String? = nil, dir: String = "/d", sid: String, ago: TimeInterval,
                        end: String = "signal 9", configDir: String = "") -> DchHistoryRecord {
        var r = DchHistoryRecord(key: AgentSessionKey(dir: dir, name: name ?? file), cwd: "/src", argv: ["claude"],
                                 started: Self.t719 - 7200, updated: Self.t719 - ago, ended: Self.t719 - ago, end: end, file: file)
        r.agent = .init(kind: "claude", sessionID: sid, configDir: configDir)
        return r
    }

    /// QA #533 F1: from 1.28.2 "Resume interrupted (N)" counts what dch's --revive --all
    /// takes, per dir, newest first: never a Claude id a live session holds ("L"), nor
    /// one a newer taken record holds ("X"), nor (1.28.3) one whose newer record ended
    /// on purpose ("S" stopped). Below 1.28.2, or with a newer master, the old count.
    @MainActor
    func testResumableCountHoldsClaudeIdsLikeDchFrom1282() {
        let history = [rec719("new", sid: "X", ago: 60), rec719("held", sid: "L", ago: 70),
                       rec719("stop", sid: "S", ago: 80, end: "stopped"), rec719("old", sid: "X", ago: 90),
                       rec719("crash", sid: "S", ago: 100), rec719("free", sid: "", ago: 110),
                       rec719("free2", sid: "", ago: 115), rec719("other", dir: "/e", sid: "X", ago: 120)]
        func taken(_ dch: DchCommand.Binary, _ master: String) -> (Int, Set<String>) {
            let store = AgentIslandStore(geometry: notched)
            store.now = { Self.t719 }
            store.controlDch = dch
            store.sessions = [session("b", version: master)]
            store.liveSIDs = ["L"]
            store.history = history
            return (store.resumableCount, Set(store.reviveAllTaken.map(\.name)))
        }
        XCTAssertEqual(taken(Self.v1283, "1.28.3").1, ["new", "free", "free2", "other"],
                       "each dir holds its own taken ids; no id holds nothing")
        XCTAssertEqual(taken(Self.v1283, "1.28.3").0, 4)
        XCTAssertEqual(taken(Self.v1282, "1.28.2").1, ["new", "crash", "free", "free2", "other"], "1.28.2 holds no ended id")
        XCTAssertEqual(taken(Self.v1281, "1.28.1").1, ["new", "held", "old", "crash", "free", "free2", "other"],
                       "below 1.28.2: unchanged")
        XCTAssertEqual(taken(Self.v1281, "1.28.1").0, 7)
        XCTAssertEqual(taken(Self.v1283, "1.29.0").0, 7, "a newer master: the gate refuses, the old count")
        // QA #535 M2: an older master (right after an update) leaves the gate open: --revive
        // runs in the control dch, so its held count.
        XCTAssertEqual(taken(Self.v1283, "1.28.1").1, ["new", "free", "free2", "other"], "an older master: control 1.28.3's count")
        // QA #535 M1: an ended record holds its id only from where the loop reaches it: a
        // crash newer than its id's stop is taken (and then holds the older crash).
        let order = AgentIslandStore(geometry: notched)
        order.now = { Self.t719 }
        order.controlDch = Self.v1283
        order.history = [rec719("again", sid: "S", ago: 50), rec719("stop", sid: "S", ago: 80, end: "stopped"),
                         rec719("crash", sid: "S", ago: 100)]
        XCTAssertEqual(Set(order.reviveAllTaken.map(\.name)), ["again"])
        // The repro: claude --resume L by hand in a new session; after it exits 0, its record holds L.
        let store = AgentIslandStore(geometry: notched)
        store.now = { Self.t719 }
        store.controlDch = Self.v1283
        store.liveSIDs = ["L"]
        store.history = [rec719("work", sid: "L", ago: 300)]
        XCTAssertNil(store.resumeAllButton, "L runs: nothing to resume")
        store.liveSIDs = []
        XCTAssertEqual(store.resumeAllButton, "Resume interrupted (1)")
        store.history.insert(rec719("work.1762099990", name: "work", sid: "L", ago: 10, end: "exit 0"), at: 0)
        XCTAssertNil(store.resumeAllButton, "its newer record ended exit 0")
        store.history[0].end = "killed"
        XCTAssertNil(store.resumeAllButton)
    }

    /// The live sessions' Claude ids are read with the history from 1.28.2, off main,
    /// from their dch records; never below it.
    @MainActor
    func testHistoryReadTakesTheLiveClaudeIdsFrom1282() throws {
        for (dch, version, want) in [(Self.v1282, "1.28.2", ["L"] as Set), (Self.v1281, "1.28.1", [])] {
            let f = FakeProc(), reads = Reads(), seen = Reads()
            reads.records = [rec719("work", sid: "L", ago: 300)]
            let c = controller(f, reads, dch: dch)
            c.store?.sessions = [session("b", version: version), session("c", version: version)]
            var b = rec719("b", sid: "L", ago: 0, end: ""), cc = rec719("c", sid: "", ago: 0, end: "")
            b.ended = 0
            cc.agent = nil
            let live = [b, cc]
            c.readLiveRecords = { s in
                XCTAssertFalse(Thread.isMainThread)
                seen.lock.withLock { seen.calls.append(("", s.map(\.name))) }
                return live
            }
            c.store?.liveSIDs = ["stale"]
            c.setExpanded(true)
            settle(c) { reads.count == 1 && c.store?.liveSIDs != ["stale"] }
            XCTAssertEqual(c.store?.liveSIDs, want, version)
            XCTAssertEqual(seen.lock.withLock { seen.calls.map(\.1) }, want.isEmpty ? [] : [["b", "c"]], version)
        }
    }

    /// QA #535 M-1: dch holds a Claude that runs in any dir, so the seed also lists the
    /// socket dirs the view does not ("Mac only" here: /e), off main and from 1.28.2 only.
    @MainActor
    func testHeldSeedListsTheOtherSocketDirFrom1282() throws {
        for (dch, version, want) in [(Self.v1283, "1.28.3", ["B", "M"] as Set), (Self.v1281, "1.28.1", [])] {
            let f = FakeProc(), reads = Reads(), listed = Reads()
            reads.records = [rec719("work", sid: "M", ago: 300)]
            let c = controller(f, reads, dch: dch)
            c.store?.sessions = [session("b", version: version)]
            c.store?.now = { Self.t719 }
            c.seedDirs = { ["/d", "/e"] }
            c.listSessions = { dirs in
                XCTAssertFalse(Thread.isMainThread)
                listed.lock.withLock { listed.calls.append(("", dirs)) }
                return dirs.map { AgentSession(key: AgentSessionKey(dir: $0, name: "m"), alias: "", activity: 0, state: .idle, agents: 0) }
            }
            c.readLiveRecords = { s in
                s.map { var r = DchHistoryRecord(key: $0.key); r.agent = .init(kind: "claude", sessionID: $0.name.uppercased()); return r }
            }
            c.store?.liveSIDs = ["stale"]
            c.setExpanded(true)
            settle(c) { reads.count == 1 && c.store?.liveSIDs != ["stale"] }
            XCTAssertEqual(c.store?.liveSIDs, want, version)
            XCTAssertEqual(listed.lock.withLock { listed.calls.map(\.1) }, want.isEmpty ? [] : [["/e"]], "only the dir not listed")
            XCTAssertEqual(c.store?.resumableCount, want.isEmpty ? 1 : 0, "its Claude runs in /e: --revive --all skips it")
        }
    }

    /// The seed's dirs: each once, only ones on disk (dch's --ls-json would create one).
    func testSeedSocketDirsAreTheOnesOnDisk() {
        let dir = tempDir().path
        XCTAssertEqual(AgentIsland.seedSocketDirs([dir, dir + "/missing", dir]), [dir])
        // The production candidates: both dirs (compared as strings; nothing on disk is touched).
        XCTAssertEqual(AgentIsland.seedSocketDirCandidates, [DchCommand.defaultSocketDir, DchCommand.isolatedSocketDir])
        XCTAssertEqual(AgentIsland.seedSocketDirs(exists: { _ in true }), [DchCommand.defaultSocketDir, DchCommand.isolatedSocketDir],
                       "the default: both candidates")
    }

    /// From 1.28.2 Resume passes `<file>.json` for every row, the own one too, with
    /// --as when the name is live; below it #716's name / aside file.
    @MainActor
    func testResumePassesTheRecordFileFrom1282() throws {
        for (dch, version, j) in [(Self.v1282, "1.28.2", ".json"), (Self.v1281, "1.28.1", "")] {
            let f = FakeProc(), reads = Reads()
            let rows = Self.fileRecords
            reads.records = rows
            let c = controller(f, reads, dch: dch)
            c.store?.sessions = [session("b", version: version)]
            c.setExpanded(true)
            settle(c) { c.store?.history.count == 3 }
            let store = try XCTUnwrap(c.store)
            func step(_ r: DchHistoryRecord, noMessage: Bool = false, _ args: [String], line: UInt = #line) {
                let before = reads.count
                c.resume(r, noMessage: noMessage)
                XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success, line: line)
                XCTAssertEqual(f.args.last, args, version, line: line)
                f.release.signal()
                settle(c) { reads.count == before + 1 }
            }
            step(rows[0], ["--revive", "work" + j, "--json"])
            step(rows[2], noMessage: true, ["--revive", "work.1761000000" + j, "--no-message", "--json"])
            store.sessions = [session("b", version: version), session("work", version: version)]
            step(rows[1], ["--revive", "work.1762000000" + j, "--as", "work-2", "--json"])
            XCTAssertEqual(f.args.count, 3)
        }
    }

    /// dch 1.28.2's failures of a by-name Resume read in words on the row: ambiguous
    /// (named after the `<file>.json` argument), live_sid (with the holder); a by-hand
    /// resume hint carries the record's own CLAUDE_CONFIG_DIR, quoted.
    @MainActor
    func testResumeFailuresFrom1282ReadInWordsOnTheRow() throws {
        let f = FakeProc(), reads = Reads()
        let rows = [rec719("work", sid: "S", ago: 300, configDir: "/Users/me/claude work")]
        reads.records = rows
        let c = controller(f, reads, dch: Self.v1282)
        c.store?.sessions = [session("b", version: "1.28.2")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        let store = try XCTUnwrap(c.store)
        func resume(_ line: String) -> String? {
            let before = reads.count
            f.output = line + "\n"
            f.status = 1
            c.resume(rows[0])
            XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
            f.release.signal()
            settle(c) { reads.count == before + 1 }
            return store.historyActions[rows[0].id]
        }
        XCTAssertEqual(resume(#"{"name":"work.json","as":"work.json","result":"failed","reason":"ambiguous","detail":"ambiguous: work.json matches more than one session's records; pass the one meant as <file>.json","session_id":""}"#),
                       "Not resumed: \(AgentIsland.ambiguousText)")
        XCTAssertEqual(resume(#"{"name":"work","as":"work","result":"failed","reason":"live_sid","detail":"claude S already runs in live session b (claude pid 42)","session_id":"S"}"#),
                       "Not resumed: claude S already runs in live session b (claude pid 42)")
        XCTAssertEqual(resume(#"{"name":"work","as":"work","result":"failed","reason":"not_utf8","detail":"","session_id":"S"}"#),
                       "Not resumed: its record has bytes that are not UTF-8; CLAUDE_CONFIG_DIR='/Users/me/claude work' claude --resume S")
        XCTAssertEqual(f.args.last, ["--revive", "work.json", "--json"])
    }

    /// QA #533 L-1: --all's skip line names its record, "(record <file>)": it lands on
    /// that row and reads as skipped, and the row dch actually resumed (--no-message:
    /// its ok comes after every skip) shows Resumed. A line naming no record lands on
    /// the name's newest taken row (QA #534 S2: not an older taken one).
    @MainActor
    func testResumeAllSkipLineLandsOnItsRecordFrom1282() throws {
        let f = FakeProc(), reads = Reads()
        let rows = [rec719("work", sid: "A", ago: 60), rec719("work.1762099910", name: "work", sid: "A", ago: 90),
                    rec719("work.1762099880", name: "work", sid: "B", ago: 120)]
        reads.records = rows
        let c = controller(f, reads, dch: Self.v1283)
        c.store?.sessions = [session("b", version: "1.28.3")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 3 }
        let store = try XCTUnwrap(c.store)
        store.now = { Self.t719 }
        XCTAssertEqual(store.resumableCount, 2, "the dup of A is not counted")
        f.progress = [#"{"name":"work","phase":"starting"}"#,
                      #"{"name":"work","as":"work","result":"skipped","reason":"dup_sid","detail":"skipped — claude A is revived from a newer record as work (record work.1762099910)","session_id":"A"}"#]
            .joined(separator: "\n") + "\n"
        c.resumeCrashed(noMessage: true)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        let skipped = "Skipped: claude A is revived from a newer record as work"
        settle(c) { store.historyActions[rows[1].id] == skipped }
        XCTAssertEqual(store.historyActions, [rows[0].id: "Starting…", rows[1].id: skipped])
        f.progress = ""
        f.output = #"{"name":"work","as":"work","result":"ok","reason":"","detail":"revived as work in /src, claude A resumed; resume message not sent (--no-message)","session_id":"A"}"# + "\n"
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.resumingText }
        XCTAssertEqual(store.historyActions[rows[0].id], "Resumed without the message")
        XCTAssertEqual(store.historyActions[rows[1].id], skipped)
        XCTAssertNil(store.historyActions[rows[2].id])
        // A failed line's by-hand hint runs under its row's record's CLAUDE_CONFIG_DIR.
        var withDir = rows
        withDir[0].agent?.configDir = "/Users/me/.claude-w"
        reads.records = withDir
        c.refreshHistory()
        settle(c) { store.history.first?.agent?.configDir == "/Users/me/.claude-w" }
        store.historyActions = [:]
        f.output = #"{"name":"work","as":"work","result":"failed","reason":"relaunch_failed","detail":"revived as work in /src, but claude could not be started; resume by hand: claude --resume A","session_id":"A"}"# + "\n"
        f.status = 1
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.resumingText }
        XCTAssertEqual(store.historyActions[rows[0].id], "revived as work in /src, but claude could not be started; "
                       + "resume by hand: CLAUDE_CONFIG_DIR=/Users/me/.claude-w claude --resume A")
        // A live session runs A: --all takes only work.1762099880 (B), and a line naming work lands there.
        var live = rec719("b", sid: "A", ago: 0, end: "")
        live.ended = 0
        let liveRecs = [live]
        c.readLiveRecords = { _ in liveRecs }
        c.refreshHistory()
        settle(c) { store.liveSIDs == ["A"] }
        XCTAssertEqual(store.resumableCount, 1)
        store.historyActions = [:]
        (f.output, f.status, f.progress) = ("", 0, #"{"name":"work","phase":"starting"}"# + "\n")
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        settle(c) { store.historyActions[rows[2].id] == "Starting…" }
        XCTAssertEqual(store.historyActions, [rows[2].id: "Starting…"])
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.resumingText }
    }

    /// QA #535 M3: a skip line's "(record <file>)" is its own dir's record: own records
    /// named "work" in /d and /e each get their dir's line.
    @MainActor
    func testResumeAllSkipLineFindsItsRecordInItsOwnDir() throws {
        let f = FakeProc(), reads = Reads()
        let rows = [rec719("work", sid: "A", ago: 60), rec719("work", dir: "/e", sid: "B", ago: 90)]
        reads.records = rows
        let c = controller(f, reads, dch: Self.v1283, dirs: ["/d", "/e"])
        c.store?.sessions = [session("b", version: "1.28.3")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        let store = try XCTUnwrap(c.store)
        store.now = { Self.t719 }
        f.progress = #"{"name":"work","as":"work","result":"skipped","reason":"live_sid","detail":"skipped — claude X already runs in live session b (record work)","session_id":"X"}"# + "\n"
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        let skipped = "Skipped: claude X already runs in live session b"
        settle(c) { store.historyActions[rows[0].id] == skipped && store.historyActions[rows[1].id] == skipped }
        XCTAssertEqual(store.historyActions, [rows[0].id: skipped, rows[1].id: skipped])
        f.release.signal()
        f.release.signal()
        settle(c) { ["/d", "/e"].allSatisfy { store.actions[AgentSessionKey(dir: $0, name: "")] != AgentIsland.resumingText } }
    }

    /// #720 review S-m2: a final with no Claude id keeps the fallback, the name's newest
    /// taken row (where its phase put the running text), not a taken record whose id is "".
    @MainActor
    func testResumeAllFinalWithNoClaudeIdKeepsTheNewestTakenRow() throws {
        let f = FakeProc(), reads = Reads()
        let rows = [rec719("work", sid: "A", ago: 60), rec719("work.1762099880", name: "work", sid: "", ago: 120)]
        reads.records = rows
        let c = controller(f, reads, dch: Self.v1283)
        c.store?.sessions = [session("b", version: "1.28.3")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        let store = try XCTUnwrap(c.store)
        store.now = { Self.t719 }
        XCTAssertEqual(store.resumableCount, 2)
        let ok = #"{"name":"work","as":"work","result":"ok","reason":"","detail":"revived as work in /src","session_id":""}"#
        f.progress = #"{"name":"work","phase":"starting"}"# + "\n"
        f.output = ok + "\n"
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        settle(c) { store.historyActions[rows[0].id] == "Starting…" }
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.resumingText }
        XCTAssertEqual(store.historyActions[rows[0].id], AgentIsland.finalText(try XCTUnwrap(AgentIsland.jsonLine(ok)), .resume))
        XCTAssertNil(store.historyActions[rows[1].id])
    }

    /// QA #535 L-4: two taken records of one name: a final names its Claude id and lands
    /// on that row, and shows there, so the newer row keeps its own failure and the older
    /// one its own Resumed; not on a newer record of that id --all does not take (ran
    /// under 5 minutes). Phases (name only) stay on the newest taken row.
    @MainActor
    func testResumeAllFinalsLandOnTheRowOfTheirClaudeId() throws {
        let f = FakeProc(), reads = Reads()
        var short = rec719("work.1762099990", name: "work", sid: "B", ago: 10)
        short.started = Self.t719 - 60
        let rows = [rec719("work", sid: "A", ago: 60), rec719("work.1762099880", name: "work", sid: "B", ago: 120)]
        reads.records = [short] + rows
        let c = controller(f, reads, dch: Self.v1283)
        c.store?.sessions = [session("b", version: "1.28.3")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 3 }
        let store = try XCTUnwrap(c.store)
        store.now = { Self.t719 }
        XCTAssertEqual(store.resumableCount, 2)
        let failed = #"{"name":"work","as":"work","result":"failed","reason":"relaunch_failed","detail":"revived as work in /src, but claude could not be started; resume by hand: claude --resume A","session_id":"A"}"#
        let ok = #"{"name":"work","as":"work-2","result":"ok","reason":"","detail":"revived as work-2 in /src, claude B resumed","session_id":"B"}"#
        f.progress = #"{"name":"work","phase":"starting"}"# + "\n" + #"{"name":"work","phase":"starting"}"# + "\n"
        f.output = failed + "\n" + ok + "\n"
        f.status = 1
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        settle(c) { store.historyActions[rows[0].id] == "Starting…" }
        XCTAssertEqual(store.historyActions, [rows[0].id: "Starting…"])
        f.release.signal()
        settle(c) { store.actions[AgentSessionKey(dir: "/d", name: "")] != AgentIsland.resumingText }
        XCTAssertEqual(store.historyActions[rows[0].id], AgentIsland.finalText(try XCTUnwrap(AgentIsland.jsonLine(failed)), .resume))
        XCTAssertEqual(store.historyActions[rows[1].id], AgentIsland.finalText(try XCTUnwrap(AgentIsland.jsonLine(ok)), .resume))
        XCTAssertNil(store.historyActions[short.id])
    }

    /// The new reasons in words: live_sid by name (failed) and under --all (skipped),
    /// dup_sid's 1.28.2 and 1.28.3 forms, ambiguous; an unpin dch finds nothing for
    /// (1.28.2: not_found, exit 1) is no failure, a pin's or remove's still is.
    func testDch1282ReasonsReadInWords() {
        func row(_ o: [String: String], _ verb: AgentIsland.Verb = .resume, status: Int32 = 1) -> String {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
            return AgentIsland.rowText(result(line, status: status), name: o["name"] ?? "", verb)
        }
        func skip(_ reason: String, _ detail: String) -> [String: String] {
            ["name": "a", "as": "a", "result": "skipped", "reason": reason, "detail": detail, "session_id": "abc"]
        }
        XCTAssertEqual(row(["name": "a", "as": "a", "result": "failed", "reason": "live_sid",
                            "detail": "claude abc already runs in live session b", "session_id": "abc"]),
                       "Not resumed: claude abc already runs in live session b")
        XCTAssertEqual(row(skip("live_sid", "skipped — claude abc already runs in claude pid 42, outside any live session (record a)"), status: 0),
                       "Skipped: claude abc already runs in claude pid 42, outside any live session")
        XCTAssertEqual(row(skip("dup_sid", "skipped — claude abc is revived from a newer record as a-2 (record a.1762000000)"), .resumeNoMessage, status: 0),
                       "Skipped: claude abc is revived from a newer record as a-2")
        XCTAssertEqual(row(skip("dup_sid", "skipped — claude abc ended in a newer record: stopped (record a (old))"), status: 0),
                       "Skipped: claude abc ended in a newer record: stopped")
        XCTAssertEqual(row(skip("dup_sid", ""), status: 0), "Skipped: a newer record holds its Claude")
        XCTAssertEqual(row(["name": "a", "result": "failed", "reason": "ambiguous", "detail": "ambiguous: a.json matches …"]),
                       "Not resumed: \(AgentIsland.ambiguousText)")
        XCTAssertEqual(row(["name": "a", "result": "failed", "reason": "ambiguous", "detail": "ambiguous: a.json matches …"], .pin),
                       "Pin failed: \(AgentIsland.ambiguousText)")
        XCTAssertEqual(AgentIsland.recordFile(DchJSONLine(name: "a", detail: "skipped — x (record a (old))")), "a (old)")
        XCTAssertNil(AgentIsland.recordFile(DchJSONLine(name: "a", detail: "revived as a in /src (record)")))
        XCTAssertEqual(AgentIsland.recordFile(DchJSONLine(name: "a", detail: "skipped — claude x already runs in w (record y) (record a)")), "a",
                       "the last one is dch's")
        XCTAssertNil(AgentIsland.recordFile(DchJSONLine(name: "a", detail: "skipped — x (record a) and more")),
                     "QA #535 M4: dch's \"(record <file>)\" ends the detail")
        func edit(_ verb: AgentIsland.Verb, _ reason: String, detail: String = "no history for this session") -> String? {
            AgentIsland.editFailure(result(#"{"name":"a","result":"failed","reason":"\#(reason)","detail":"\#(detail)","session_id":""}"#,
                                           status: 1), name: "a", verb)
        }
        XCTAssertNil(edit(.unpin, "not_found"), "the record went: the re-read drops its row")
        XCTAssertEqual(edit(.pin, "not_found"), "Pin a failed: no history for this session")
        XCTAssertEqual(edit(.remove, "not_found"), "Remove a failed: no history for this session")
        XCTAssertEqual(edit(.unpin, "io_error", detail: "Permission denied"), "Unpin a failed: Permission denied")
        XCTAssertEqual(edit(.unpin, "ambiguous", detail: "ambiguous: a.json matches …"), "Unpin a failed: \(AgentIsland.ambiguousText)")
    }

    /// dch 1.28.2 records carry agent.config_dir: it parses (absent or "" is the
    /// default); the by-hand hint gets CLAUDE_CONFIG_DIR=<dir>, shell-quoted, only then.
    func testConfigDirParsesAndPrefixesTheByHandHint() {
        let json = #"[{"name":"a","agent":{"kind":"claude","session_id":"S","config_dir":"/Users/me/.claude-w","launch":[]},"file":"a"},"#
            + #"{"name":"b","agent":{"kind":"claude","session_id":"T","config_dir":""}},{"name":"c","agent":{"session_id":"U"}}]"#
        let rows = AgentIsland.parseHistory(Data(json.utf8), dir: "/d")
        XCTAssertEqual(rows.map { $0.agent?.configDir }, ["/Users/me/.claude-w", "", ""])
        XCTAssertEqual(rows.map { $0.agent?.sessionID }, ["S", "T", "U"])
        XCTAssertEqual(AgentIsland.byHand("resume by hand: claude --resume S", rows[0]),
                       "resume by hand: CLAUDE_CONFIG_DIR=/Users/me/.claude-w claude --resume S")
        XCTAssertEqual(AgentIsland.byHand("x; claude --resume T", rows[1]), "x; claude --resume T")
        XCTAssertEqual(AgentIsland.byHand("x; claude --resume S", nil), "x; claude --resume S")
        var odd = rows[0]
        odd.agent?.configDir = "/tmp/it's here"
        XCTAssertEqual(AgentIsland.byHand("claude --resume S", odd), #"CLAUDE_CONFIG_DIR='/tmp/it'\''s here' claude --resume S"#)
        XCTAssertEqual(AgentIsland.byHand("claude --resume Z", odd), "claude --resume Z", "another id: untouched")
        // QA #535 L-3: zsh expands `=cmd` at a value's start and after ':' in an assignment.
        odd.agent?.configDir = "=claude"
        XCTAssertEqual(AgentIsland.byHand("claude --resume S", odd), "CLAUDE_CONFIG_DIR='=claude' claude --resume S")
        odd.agent?.configDir = "/a:=claude"
        XCTAssertEqual(AgentIsland.byHand("claude --resume S", odd), "CLAUDE_CONFIG_DIR='/a:=claude' claude --resume S")
        XCTAssertEqual(AgentIsland.attachCommand(AgentSessionKey(dir: "=d", name: "=n"), defaultDir: "/d"), "DCH_SOCKET_DIR='=d' dch -n '=n'")
        XCTAssertEqual(["k=v", "--x=y", "/a:b", "a=:b"].map(AgentIsland.shellQuoted), ["k=v", "--x=y", "/a:b", "a=:b"],
                       "any other = or : stays bare")
        XCTAssertEqual(AgentIsland.shellWords(AgentIsland.shellLine(["=x", "a:=b"])), ["=x", "a:=b"])
    }

    /// QA #534 S1: an own row with no agent (a plain shell) has Claude id "": below
    /// 1.28.1 its X's pinned refusal of an aside record (that record's id) is not this
    /// row's failure; a refusal with no id still is.
    @MainActor
    func testAgentlessOwnRowsXIgnoresAnAsidesPinnedRefusal() throws {
        let f = FakeProc(), reads = Reads()
        var aside = rec719("work.1762000000", name: "work", sid: "X", ago: 600)
        aside.pinned = true
        let own = record("work", end: "exit 0")
        reads.records = [own, aside]
        let c = controller(f, reads, dch: Self.v125)
        c.store?.sessions = [session("b", version: "1.25.0")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 2 }
        let store = try XCTUnwrap(c.store), dirKey = AgentSessionKey(dir: "/d", name: "")
        XCTAssertNil(own.agent)
        func remove(_ lines: [String]) {
            let before = reads.count
            f.output = lines.joined(separator: "\n") + "\n"
            f.status = 1
            c.remove(own)
            XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
            f.release.signal()
            settle(c) { reads.count == before + 1 }
        }
        remove([#"{"name":"work","result":"ok","reason":"","detail":"forgotten","session_id":""}"#,
                #"{"name":"work","result":"failed","reason":"pinned","detail":"pinned (-f forgets it anyway)","session_id":"X"}"#])
        XCTAssertNil(store.actions[dirKey], "the aside's refusal")
        remove([#"{"name":"work","result":"failed","reason":"pinned","detail":"pinned (-f forgets it anyway)","session_id":""}"#])
        XCTAssertEqual(store.actions[dirKey], "Remove work failed: \(AgentIsland.pinnedRefusal)")
    }

    // MARK: - #743: one History row per name

    /// One dch record as `--history --json` prints it (dch.c do_history_verb). `file`: nil
    /// is 1.28.0's own record (no "file"); 1.28.1 sends it on every record.
    private static func rec743(_ name: String, file: String?, ended: Int, sid: String, pinned: Bool = false,
                               cwd: String = "/src", argv: [String] = ["claude"]) -> [String: Any] {
        var o: [String: Any] = ["name": name, "alias": "", "cwd": cwd, "argv": argv, "started": ended - 3600,
                                "updated": ended, "ended": ended, "end": "stopped"]
        if !sid.isEmpty { o["agent"] = ["kind": "claude", "session_id": sid, "name": "", "cwd": cwd, "launch": [String]()] }
        if pinned { o["pinned"] = true }
        if let file { o["file"] = file }
        return o
    }

    /// The records Prosper reads (AgentIsland.history: per dir, newest first) from each dir's JSON.
    private static func history743(_ dirs: [String: [[String: Any]]]) -> [DchHistoryRecord] {
        AgentIsland.history(dirs: dirs.keys.sorted()) { _, env in
            try? JSONSerialization.data(withJSONObject: dirs[env["DCH_SOCKET_DIR"] ?? ""] ?? [])
        }
    }

    /// The shapes a by-hand `dch <name>` leaves (master.c rec_aside: a cold start moves the
    /// name's record to `<name>.<ended>` and copies its pin; --revive carries the record on,
    /// no aside), as 1.28.0 and 1.28.1 print them.
    private static func shapes743(fileOnOwn: Bool) -> [(String, [String: [[String: Any]]])] {
        let own = fileOnOwn ? "work" : nil
        return [
            ("pinned name started again by hand, ended twice", ["/d": [
                rec743("work", file: own, ended: 2000, sid: "new", pinned: true),
                rec743("work", file: "work.1000", ended: 1000, sid: "old", pinned: true)]]),
            ("another cwd, argv and no agent", ["/d": [
                rec743("work", file: own, ended: 2000, sid: "", cwd: "/b", argv: ["zsh"]),
                rec743("work", file: "work.1000", ended: 1000, sid: "old", cwd: "/a")]]),
            ("the name live again: its own record is not listed, two asides", ["/d": [
                rec743("work", file: "work.2000", ended: 2000, sid: "mid"),
                rec743("work", file: "work.1000", ended: 1000, sid: "old", pinned: true)]]),
            ("revived from Prosper: one record", ["/d": [rec743("work", file: own, ended: 2000, sid: "old")]]),
        ]
    }

    /// Every shape draws one row for "work", its newest record, the rest as its older
    /// count; the other names stay, in order. A name in another socket dir is another
    /// session (its own records and --revive): its own row.
    @MainActor
    func testHistoryDrawsOneRowPerNameForEveryDuplicateShape() {
        for fileOnOwn in [false, true] {
            for (what, dirs) in Self.shapes743(fileOnOwn: fileOnOwn) {
                var dirs = dirs
                dirs["/d"]! += [Self.rec743("a", file: fileOnOwn ? "a" : nil, ended: 3000, sid: "a"),
                                Self.rec743("b", file: fileOnOwn ? "b" : nil, ended: 1500, sid: "b")]
                dirs["/e"] = [Self.rec743("work", file: fileOnOwn ? "work" : nil, ended: 2500, sid: "e")]
                let history = Self.history743(dirs), records = dirs["/d"]!.count - 2
                let store = AgentIslandStore(geometry: notched)
                store.controlDch = Self.v1281
                store.history = history
                store.historyTab = true
                let drawn = AgentIslandView(store: store).historyDrawn, label = "\(what), file on own: \(fileOnOwn)"
                // Pinned rows lead (#605): the pinned-twice name first.
                let lead = drawn.first?.record.pinned == true
                XCTAssertEqual(drawn.map { "\($0.record.key.dir) \($0.record.name)" },
                               lead ? ["/d work", "/d a", "/e work", "/d b"] : ["/d a", "/e work", "/d work", "/d b"], label)
                let work = drawn[lead ? 0 : 2]
                XCTAssertEqual(work.record.lastSeen, 2000, "the newest record: \(label)")
                XCTAssertEqual(work.older, records - 1, label)
                XCTAssertEqual(work.olderUnpinned, history.filter { $0.key == work.record.key && $0.id != work.id && !$0.pinned }.count, label)
                XCTAssertEqual(drawn.map(\.older).reduce(0, +), records - 1, "only work's: \(label)")
                XCTAssertEqual(Set(drawn.map(\.id)).count, drawn.count, label)
                XCTAssertEqual(store.cappedHistory.count, 4, "the tab's count: \(label)")
                XCTAssertEqual(store.history.count, records + 3, "the records stay: \(label)")
            }
        }
        // Pinned twice: the pin shows once, on the one row.
        let pinned = Self.history743(Self.shapes743(fileOnOwn: true)[0].1)
        XCTAssertEqual(AgentIsland.cappedHistory(pinned).map { [$0.name: $0.pinned] }, [["work": true]])
    }

    /// The cap counts rows, not records: 60 names with an aside each give 50 rows, the
    /// newest names; pinned names first and never capped.
    func testHistoryCapCountsRowsNotRecords() {
        var d: [[String: Any]] = []
        for i in 0..<60 {
            d.append(Self.rec743("s\(i)", file: "s\(i)", ended: 100_000 - i * 10, sid: "n\(i)", pinned: i == 59))
            d.append(Self.rec743("s\(i)", file: "s\(i).\(i)", ended: 100_000 - i * 10 - 5, sid: "o\(i)", pinned: i == 59))
        }
        let rows = AgentIsland.cappedHistory(Self.history743(["/d": d]))
        XCTAssertEqual(rows.count, AgentIsland.historyCap)
        XCTAssertEqual(rows.map(\.name), ["s59"] + (0..<49).map { "s\($0)" })
        XCTAssertTrue(rows.allSatisfy { !$0.isAside }, "each the name's newest")
    }

    /// A row's pin, unpin and X act on every record it folds, and on no other: 1.28.1 each
    /// `<file>.json` (the X the unpinned ones); below it the bare name while the name's own
    /// record is listed, else (the name is live, its record not listed) each aside file, so
    /// the bare name never reaches the live session's record.
    func testHistoryRowEditTargetsCoverEveryRecordOfTheName() {
        func targets(_ fileOnOwn: Bool, _ shape: Int, exact: Bool, forget: Bool) -> [String] {
            let rows = AgentIsland.cappedHistory(Self.history743(Self.shapes743(fileOnOwn: fileOnOwn)[shape].1))
            let all = Self.history743(Self.shapes743(fileOnOwn: fileOnOwn)[shape].1)
            XCTAssertEqual(rows.count, 1)
            return AgentIsland.editTargets(rows[0], older: AgentIsland.older(rows[0], in: all), exact: exact, forget: forget)
        }
        for fileOnOwn in [false, true] {
            XCTAssertEqual(targets(fileOnOwn, 0, exact: false, forget: false), ["work"])
            XCTAssertEqual(targets(fileOnOwn, 1, exact: false, forget: true), ["work"])
            XCTAssertEqual(targets(fileOnOwn, 2, exact: false, forget: false), ["work.2000", "work.1000"])
            XCTAssertEqual(targets(fileOnOwn, 2, exact: false, forget: true), ["work.2000"], "the pinned one stays")
            XCTAssertEqual(targets(fileOnOwn, 2, exact: true, forget: false), ["work.2000.json", "work.1000.json"])
            XCTAssertEqual(targets(fileOnOwn, 2, exact: true, forget: true), ["work.2000.json"])
            XCTAssertEqual(targets(fileOnOwn, 3, exact: false, forget: true), ["work"])
        }
        XCTAssertEqual(targets(true, 0, exact: true, forget: false), ["work.json", "work.1000.json"])
        XCTAssertEqual(targets(true, 1, exact: true, forget: true), ["work.json", "work.1000.json"])
        XCTAssertEqual(targets(true, 3, exact: true, forget: true), ["work.json"])
        XCTAssertEqual(targets(false, 0, exact: true, forget: false), ["work", "work.1000.json"], "1.28.0 output: the own record has no file")
        XCTAssertEqual(AgentIsland.pinArgs(["work.json", "work.1000.json"], pin: false), ["--unpin", "work.json", "work.1000.json", "--json"])
        XCTAssertNil(AgentIsland.forgetArgs(["w", "-x"]), "#627: any dash-led target, nothing runs")
    }

    /// The operator's "pinned twice", pressed on the drawn row: one row, pinned; its pin
    /// unpins both records under 1.25.0 (bare name) and 1.28.1 (each file); no X. The name
    /// live again (asides only): the X forgets the unpinned aside alone, never by the name.
    @MainActor
    func testPinnedTwiceRowActsOnEveryRecordOfTheNameUnderBothGates() throws {
        for (dch, version, exact) in [(Self.v1281, "1.28.1", true), (Self.v125, "1.25.0", false)] {
            let f = FakeProc(), reads = Reads()
            reads.records = Self.history743(Self.shapes743(fileOnOwn: exact)[0].1)
            let c = controller(f, reads, dch: dch)
            c.store?.sessions = [session("b", version: version)]
            c.setExpanded(true)
            settle(c) { c.store?.history.count == 2 }
            let store = try XCTUnwrap(c.store)
            store.historyTab = true
            func drawn() -> [AgentIslandView.HistoryDrawn] {
                AgentIslandView(store: store, onPin: { c.pin($0) }, onRemove: { c.remove($0) }).historyDrawn
            }
            func step(_ press: () -> Void, _ args: [String], line: UInt = #line) {
                let before = reads.count
                press()
                XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success, line: line)
                XCTAssertEqual(f.args.last, args, version, line: line)
                f.release.signal()
                settle(c) { reads.count == before + 1 }
            }
            let row = try XCTUnwrap(drawn().first)
            XCTAssertEqual(drawn().count, 1, version)
            XCTAssertTrue(row.record.pinned)
            XCTAssertNil(row.remove, "a pinned row has no X")
            XCTAssertEqual(row.menu.map(\.title).filter { $0.hasPrefix("Unpin") }, ["Unpin (also 1 older record of this name)"])
            step({ row.pin?() }, ["--unpin"] + (exact ? ["work.json", "work.1000.json"] : ["work"]) + ["--json"])
            reads.records = Self.history743(Self.shapes743(fileOnOwn: exact)[2].1)
            c.refreshHistory()
            settle(c) { store.history.first?.file == "work.2000" }
            let live = try XCTUnwrap(drawn().first)
            XCTAssertEqual(drawn().count, 1, version)
            XCTAssertEqual(live.older, 1)
            XCTAssertEqual(live.olderUnpinned, 0)
            step({ live.remove?() }, ["--forget", exact ? "work.2000.json" : "work.2000", "--json"])
            step({ live.pin?() }, ["--pin"] + (exact ? ["work.2000.json", "work.1000.json"] : ["work.2000", "work.1000"]) + ["--json"])
            XCTAssertEqual(f.args.count, 3)
        }
    }
}
