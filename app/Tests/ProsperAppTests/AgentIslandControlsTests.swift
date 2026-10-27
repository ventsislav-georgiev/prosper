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

    private static let v123 = DchCommand.Binary(path: "/fake/dch", version: [1, 23, 0])

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

    func testGateRefusesBelowAMasterOrTheVerbMinimum() {
        let min = AgentIsland.reviveMinimum
        XCTAssertEqual(DchCommand.gate(Self.v123, masters: ["1.23.0", ""], minimum: min), .ok("/fake/dch"),
                       "an old master (\"\") passes")
        XCTAssertEqual(DchCommand.gate(Self.v123, masters: ["1.9.0"], minimum: min), .ok("/fake/dch"), "numeric, not string")
        XCTAssertEqual(DchCommand.gate(Self.v123, masters: ["1.23.0", "1.24.0"], minimum: min), .refused("needs dch 1.24.0"),
                       "older than a master: --restart would downgrade it")
        XCTAssertEqual(DchCommand.gate(DchCommand.Binary(path: "/b", version: [1, 22, 9]), masters: [], minimum: min),
                       .refused("needs dch 1.23.0"))
        XCTAssertEqual(DchCommand.gate(nil, masters: [], minimum: min), .refused("needs dch 1.23.0"))
        XCTAssertEqual(DchCommand.gate(DchCommand.Binary(path: "/b", version: [1, 30, 0]), masters: ["1.24.0"], minimum: min),
                       .ok("/b"))
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
      "agent":{"kind":"claude","session_id":"abc","name":"fix-tests","cwd":"/src/app","launch":["/usr/local/bin/headroom","wrap","claude"]}},
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
                         launch: ["/usr/local/bin/headroom", "wrap", "claude"])))
        XCTAssertEqual(rows[0].title, "My work")
        XCTAssertNil(rows[1].agent)
        XCTAssertEqual(rows[1].lastSeen, 1_761_409_999, "ended 0: last seen is updated")
        XCTAssertEqual(rows[2], DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "bare")))
        XCTAssertEqual(rows[2].title, "bare")
        XCTAssertEqual(AgentIsland.parseHistory(Data("{}".utf8), dir: "/d"), [])
        XCTAssertEqual(AgentIsland.parseHistory(Data(), dir: "/d"), [])
    }

    func testEndLabels() {
        XCTAssertEqual(AgentIsland.endLabel("signal 9"), "crashed (signal 9)")
        XCTAssertEqual(AgentIsland.endLabel("exit 1"), "exited (1)")
        XCTAssertEqual(AgentIsland.endLabel("exit 0"), "exited (0)")
        XCTAssertEqual(AgentIsland.endLabel("vanished"), "vanished")
        XCTAssertEqual(AgentIsland.endLabel(""), "vanished", "a master that died without writing its end")
        XCTAssertEqual(AgentIsland.endLabel("killed"), "killed")
        XCTAssertEqual(AgentIsland.endLabel("stopped"), "stopped", "1.24.0 passes through")
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
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: ["b"], records: []), ["--revive", "a"])
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: ["a"], records: []), ["--revive", "a", "--as", "a-2"])
        XCTAssertEqual(AgentIsland.reviveArgs(r, live: ["a", "a-2"], records: ["a-3"]), ["--revive", "a", "--as", "a-4"],
                       "a name another record holds is not free either")
    }

    func testResultIsTheExitCodeAndTheLastNonEmptyLine() {
        let r = AgentIsland.actionResult(status: 1, output: Data("a: revived as a in /x\n\ndch: session b is live\n  \n".utf8))
        XCTAssertEqual(r, DchActionResult(status: 1, line: "dch: session b is live"))
        XCTAssertEqual(AgentIsland.resumeText(r), "Resume failed: dch: session b is live")
        XCTAssertEqual(AgentIsland.resumeText(DchActionResult(status: 1, line: "")), "Resume failed (exit 1)")
        XCTAssertNil(AgentIsland.resumeText(DchActionResult(status: 0, line: "a: revived as a in /x")))
        XCTAssertEqual(AgentIsland.resumeText(DchActionResult(status: 0, line: "nothing to revive"), all: true), "nothing to revive")
        XCTAssertEqual(AgentIsland.resumeText(DchActionResult(status: 15, line: "", stopped: true)), "Resume stopped: no answer in 5m")
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
        for word in ["crashed", "exited with an error", "vanished", "3 days", "5 minutes"] {
            XCTAssertTrue(AgentIsland.resumeAllHelp.contains(word), word)
        }
        XCTAssertEqual(AgentIsland.resumeAllLabel, "Resume crashed")
    }

    // MARK: - Runner

    /// A fake process: records each launch, reports pid 4242 (or waits for
    /// `pidGate` first), then blocks until released. Signals are recorded and
    /// never end it, so a second one would show.
    private final class FakeProc: @unchecked Sendable {
        let lock = NSLock()
        var launches: [(path: String, args: [String], dir: String?)] = []
        var envs: [[String: String]] = []
        var signals: [pid_t] = []
        var status: Int32 = 0
        var output = ""
        let release = DispatchSemaphore(value: 0)
        var pidGate: DispatchSemaphore?
        let launched = DispatchSemaphore(value: 0)

        func runner(bound: TimeInterval = 60) -> DchActionRunner {
            DchActionRunner(bound: bound, launch: { path, args, env, onPid in
                self.lock.withLock { self.launches.append((path, args, env["DCH_SOCKET_DIR"])); self.envs.append(env) }
                self.pidGate?.wait()
                onPid(4242)
                self.launched.signal()
                self.release.wait()
                return self.lock.withLock { (self.status, Data(self.output.utf8)) }
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
        XCTAssertEqual(res.all, [DchActionResult(status: 143, line: "a: stopping", stopped: true)])
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
        XCTAssertEqual(res.all, [DchActionResult(status: 3, line: "dch: refused")])
        let slow = DchActionRunner(bound: 2)   // room for sh to set its trap under load
        XCTAssertTrue(slow.start(AgentSessionKey(dir: "/d", name: "b"), path: "/bin/sh",
                                 args: ["-c", "trap 'echo got term; exit 7' TERM; echo started; while :; do /bin/sleep 0.1; done"],
                                 env: { [:] }, done: res.add))
        XCTAssertEqual(res.done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(res.all.last, DchActionResult(status: 7, line: "got term", stopped: true),
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
    private func controller(_ f: FakeProc, _ reads: Reads, dch: DchCommand.Binary? = AgentIslandControlsTests.v123,
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
        XCTAssertEqual(c.store?.controlDch, Self.v123)
        c.setExpanded(false)
        settle(c)
        XCTAssertEqual(reads.count, 1, "closing reads nothing")
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
        let c = controller(f, reads, dch: DchCommand.Binary(path: "/old/dch", version: [1, 22, 0]))
        c.store?.sessions = [session("a")]
        c.setExpanded(true)
        settle(c) { c.store?.controlDch != nil }
        XCTAssertEqual(reads.count, 0)
        XCTAssertEqual(c.store?.history, [])
        XCTAssertEqual(c.store?.showsTabs, false, "no History tab")
    }

    /// Opening, Settings changes, tab clicks and a row's Resume never run
    /// `--revive --all`; only the Resume crashed click does, once per dir.
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
        XCTAssertEqual(f.args, [["--revive", "x"]], "nothing ran --all on its own")
        c.resumeCrashed()
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args.count, 2, "/d is busy with x: its --all is refused, /e runs")
        XCTAssertEqual(f.args.last, ["--revive", "--all"])
        XCTAssertEqual(f.lock.withLock { f.launches.last?.dir }, "/e", "with that dir's DCH_SOCKET_DIR")
        XCTAssertEqual(c.store?.actions[AgentSessionKey(dir: "/e", name: "")], AgentIsland.resumingText)
        f.release.signal(); f.release.signal()
        settle(c) { c.store?.actions.values.contains(AgentIsland.resumingText) == false }
        c.resumeCrashed()
        for _ in 0..<2 { XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(f.args.suffix(2), [["--revive", "--all"], ["--revive", "--all"]], "one per dir with history")
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
        c.resume(x)
        XCTAssertEqual(c.store?.actions[x.key], "Resuming…")
        c.resume(x)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "a", "--as", "a-3"]], "one launch; a-2 is another record's name")
        XCTAssertEqual(f.lock.withLock { f.launches.map(\.path) }, ["/fake/dch"])
        reads.records = [taken]   // revived under a new name: dch retired the old record
        f.release.signal()
        settle(c) { c.store?.history == [taken] }
        XCTAssertEqual(reads.count, 2, "re-read after the action")
        XCTAssertNil(c.store?.actions[x.key])
    }

    @MainActor
    func testFailedResumeShowsTheLastLine() {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("a")]
        f.status = 1
        f.output = "dch: no history for session a\n"
        let c = controller(f, reads)
        c.store?.sessions = [session("b")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        c.resume(record("a"))
        f.release.signal()
        settle(c) { c.store?.actions[record("a").key] != AgentIsland.resumingText }
        XCTAssertEqual(c.store?.actions[record("a").key], "Resume failed: dch: no history for session a")
        c.setExpanded(false)
        XCTAssertEqual(c.store?.actions, [:], "closing drops finished statuses")
    }

    /// A master newer than the control binary: Resume and Resume crashed are off, with the reason.
    @MainActor
    func testGateRefusalDisablesResume() throws {
        let f = FakeProc(), reads = Reads()
        reads.records = [record("x")]
        let c = controller(f, reads)
        c.store?.sessions = [session("a", version: "1.24.0"), session("b", version: "")]
        c.setExpanded(true)
        settle(c) { c.store?.history.count == 1 }
        XCTAssertEqual(c.store?.resumeGate, .refused("needs dch 1.24.0"))
        c.resume(record("x"))
        c.resumeCrashed()
        XCTAssertEqual(f.args, [])
        XCTAssertEqual(c.store?.actions, [:])
        let store = try XCTUnwrap(c.store)
        store.historyTab = true
        XCTAssertEqual(AgentIslandView(store: store).historyDrawn.map(\.enabled), [false])
        store.sessions = [session("a", version: "1.23.0")]
        XCTAssertEqual(AgentIslandView(store: store).historyDrawn.map(\.enabled), [true])
    }

    /// The drawn History rows carry their own record into Resume.
    @MainActor
    func testDrawnHistoryRowsCarryTheirRecord() {
        let store = AgentIslandStore(geometry: notched)
        store.sessions = [session("a")]
        store.controlDch = Self.v123
        store.history = [record("x", ended: 3), record("y", ended: 2)]
        store.historyTab = true
        var resumed: [String] = []
        let view = AgentIslandView(store: store, onResume: { resumed.append($0.name) })
        for r in view.historyDrawn { r.resume() }
        XCTAssertEqual(resumed, ["x", "y"])
    }

    /// Visual evidence: the History tab (with a running and a failed row) and the
    /// gate's reason in place of Resume crashed. Offscreen only.
    @MainActor
    func testRendersHistoryTabOffscreen() throws {
        let now = Date().timeIntervalSince1970
        let store = AgentIslandStore(geometry: notched, details: AgentIslandRowDetails(), sidekickPattern: "-qa")
        store.sessions = [session("prosper-main", version: "1.23.0"), session("prosper-qa")]
        store.controlDch = Self.v123
        var a = record("prosper-main", ended: now - 120, end: "signal 9")
        a.alias = "Prosper"
        a.cwd = NSHomeDirectory() + "/personal/prosper"
        a.agent = .init(kind: "claude", name: "agent-island-578")
        var b = record("ios", ended: now - 7200, end: "exit 1")
        b.cwd = NSHomeDirectory() + "/personal/prosper-ios"
        let c = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "dch-build"), cwd: "/tmp", updated: now - 4000, end: "")
        let d = record("scratch", ended: now - 90000, end: "killed")
        store.history = [a, b, c, d]
        store.actions[b.key] = "Resume failed: dch: session ios is live; revive it under another name"
        store.actions[d.key] = AgentIsland.resumingText
        store.actions[AgentSessionKey(dir: "/d", name: "")] = "nothing to revive"
        store.historyTab = true
        store.expanded = true
        let out = tempDir()
        func island(_ name: String) throws { try render(store, name, to: out) }
        try island("agent-island-history")
        store.sessions = [session("prosper-main", version: "1.24.0")]
        try island("agent-island-history-gated")
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
        store.controlDch = Self.v123
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
        c.store?.controlDch = Self.v123
        c.store?.sessions = [session("a", dir: "/d")]
        c.store?.history = [x, record("a-2", dir: "/e", ended: 50)]
        c.resume(x)
        XCTAssertEqual(f.launched.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(f.args, [["--revive", "a", "--as", "a-2"]])
        f.release.signal()
        settle(c) { c.store?.actions[x.key] != AgentIsland.resumingText }
    }
}
