import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #474 Agent Island: display mapping, the no-fork poll gate, the jump walk and
/// the island geometry. No window is ordered front, no pasteboard is written,
/// every fixture dir comes from tempDir().
final class AgentIslandTests: XCTestCase {
    private func session(_ name: String, _ state: AgentState, activity: TimeInterval = 0,
                         alias: String = "", agents: Int = 0, dir: String = "/d") -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: alias, activity: activity,
                     state: state, agents: agents)
    }

    // MARK: - Display

    func testSortGroupsByUrgencyThenNewestActivity() {
        let rows = [session("i", .idle, activity: 50), session("w1", .working, activity: 10),
                    session("d", .done, activity: 90), session("b", .blocked, activity: 1),
                    session("w2", .working, activity: 20), session("i2", .idle, activity: 60)]
        XCTAssertEqual(AgentIsland.sorted(rows).map(\.name), ["b", "w2", "w1", "d", "i2", "i"])
    }

    func testStateMappingIncludingOldDchEmptyState() {
        XCTAssertEqual(AgentState(dch: "working"), .working)
        XCTAssertEqual(AgentState(dch: "blocked"), .blocked)
        XCTAssertEqual(AgentState(dch: "done"), .done)
        XCTAssertEqual(AgentState(dch: "idle"), .idle)
        XCTAssertEqual(AgentState(dch: ""), .idle, "dch before 1.4 reports no state")
        XCTAssertEqual(AgentState(dch: "bogus"), .idle)
        XCTAssertEqual(AgentState.allCases.map(\.label), ["Needs input", "Working", "Done", "Idle"])
        XCTAssertEqual(AgentState.allCases.map(\.glyph), ["!", "✳", "●", "●"])
        XCTAssertEqual(AgentState.working.color, Color(red: 0.85, green: 0.47, blue: 0.34))
        XCTAssertEqual(AgentState.blocked.color, Color(red: 1.0, green: 0.7, blue: 0.0))
        XCTAssertEqual(AgentState.done.color, Color(red: 0.4, green: 0.75, blue: 0.45))
        XCTAssertEqual(AgentState.idle.color, Color.white.opacity(0.4))
    }

    func testAgeFormattingAtUnitBoundaries() {
        let cases: [(TimeInterval, String)] = [(-5, "0s"), (0, "0s"), (12, "12s"), (59.9, "59s"), (60, "1m"),
                                               (3599, "59m"), (3600, "1h"), (86399, "23h"), (86400, "1d"),
                                               (3 * 86400 + 5, "3d")]
        for (s, want) in cases { XCTAssertEqual(AgentIsland.age(s), want, "\(s)") }
        XCTAssertEqual(AgentIsland.age(of: session("x", .idle, activity: 0), now: 1000), "",
                       "no activity stamp, no age")
        XCTAssertEqual(AgentIsland.age(of: session("x", .idle, activity: 1000), now: 1240), "4m")
    }

    func testCollapsedSummaryAndLabels() {
        var s = AgentIsland.summary([session("a", .working), session("b", .working), session("c", .idle),
                                     session("d", .done), session("e", .working)])
        XCTAssertEqual(s.mostUrgent, .working)
        XCTAssertEqual(s.earCount.value, 3)
        XCTAssertEqual(s.earCount.state, .working)
        XCTAssertEqual(AgentIsland.islandAccessibilityLabel(s), "Agent Island, 3 working, 1 done, 1 idle")

        s = AgentIsland.summary([session("a", .working), session("b", .blocked), session("c", .working),
                                 session("d", .working)])
        XCTAssertEqual(s.mostUrgent, .blocked)
        XCTAssertEqual(s.working, 3)
        XCTAssertEqual(s.blocked, 1)
        XCTAssertEqual(s.earCount.value, 1, "a blocked session takes the ear")
        XCTAssertEqual(s.earCount.state, .blocked)
        XCTAssertEqual(AgentIsland.islandAccessibilityLabel(s), "Agent Island, 3 working, 1 needs input")

        s = AgentIsland.summary([session("a", .idle)])
        XCTAssertEqual(s.mostUrgent, .idle)
        XCTAssertEqual(s.earCount.value, 0)
        XCTAssertNil(AgentIsland.summary([]).mostUrgent)

        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(
            session("fix-auth", .blocked, activity: 100, alias: "fix auth bug"), now: 112),
            "fix auth bug, Needs input, 12s ago")
    }

    // MARK: - Socket dirs and listing (G5)

    func testSocketDirSelectionForEverySourceWithIsolationOnAndOff() {
        let def = "/tmp/dch-501", iso = "/Users/u/.config/prosper/dch-isolated"
        func dirs(_ raw: String?, _ isolate: Bool) -> [String] {
            AgentIsland.socketDirs(source: AgentIslandSource(raw: raw), isolate: isolate,
                                   defaultDir: def, isolatedDir: iso)
        }
        for raw in [nil, "all", "mac", "remote", "bogus"] {
            XCTAssertEqual(dirs(raw, false), [def], "isolation off lists the one dir whatever \(raw ?? "nil") says")
        }
        XCTAssertEqual(dirs("all", true), [def, iso])
        XCTAssertEqual(dirs("mac", true), [def])
        XCTAssertEqual(dirs("remote", true), [iso])
        XCTAssertEqual(dirs(nil, true), [def, iso], "unset is all")
        XCTAssertEqual(dirs("bogus", true), [def, iso], "unknown is all")
        XCTAssertEqual(AgentIslandSource.allCases.map(\.label),
                       ["All sessions", "Mac terminal sessions", "Remote Terminal sessions"])
    }

    func testListRunsDchWithAnExplicitSocketDirPerDir() {
        var calls: [(args: [String], env: [String: String])] = []
        let json = #"[{"name":"x","alias":"","harness":"task","activity_epoch":42,"state":"working","agents":2}]"#
        let rows = AgentIsland.list(dirs: ["/tmp/dch-501", "/iso"]) { args, env in
            calls.append((args, env))
            if env["DCH_SOCKET_DIR"] == "/iso" { return args == ["-lj"] ? Data("y\tY\t7\n".utf8) : Data() }
            return Data(json.utf8)
        }
        XCTAssertEqual(calls.map(\.env["DCH_SOCKET_DIR"]), ["/tmp/dch-501", "/iso", "/iso"],
                       "the default dir is set explicitly too, never inherited from the isolation env")
        XCTAssertTrue(calls.allSatisfy { $0.env["DCH_SESSION"] == nil })
        XCTAssertEqual(calls.map(\.args), [["--ls-json"], ["--ls-json"], ["-lj"]], "old dch falls back to -lj")
        XCTAssertEqual(rows, [
            AgentSession(key: AgentSessionKey(dir: "/tmp/dch-501", name: "x"), alias: "task", activity: 42,
                         state: .working, agents: 2),
            AgentSession(key: AgentSessionKey(dir: "/iso", name: "y"), alias: "Y", activity: 7,
                         state: .idle, agents: 0),
        ])
        XCTAssertEqual(AgentIsland.listEnv(dir: "/a", base: ["DCH_SOCKET_DIR": "/iso", "DCH_SESSION": "s",
                                                             "PATH": "/bin"]),
                       ["DCH_SOCKET_DIR": "/a", "PATH": "/bin"])
    }

    // MARK: - Copy fallback (J9, G5c)

    func testAttachCommandQuotesTheNameAndCarriesANonDefaultDir() {
        let def = "/tmp/dch-501"
        XCTAssertEqual(AgentIsland.attachCommand(AgentSessionKey(dir: def, name: "prosper-ios"), defaultDir: def),
                       "dch -n prosper-ios")
        XCTAssertEqual(AgentIsland.attachCommand(AgentSessionKey(dir: def, name: "it's $HOME x"), defaultDir: def),
                       #"dch -n 'it'\''s $HOME x'"#)
        XCTAssertEqual(AgentIsland.attachCommand(
            AgentSessionKey(dir: "/Users/a b/.config/prosper/dch-isolated", name: "p1"), defaultDir: def),
            "DCH_SOCKET_DIR='/Users/a b/.config/prosper/dch-isolated' dch -n p1")
    }

    // MARK: - Client pid files (J4, J5)

    private func touch(_ dir: URL, _ name: String, mtime: TimeInterval? = nil) {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: nil)
        if let mtime {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                                                   ofItemAtPath: path)
        }
    }

    func testClientPIDFilesParseExactPrefixNewestFirst() {
        let dir = tempDir()
        touch(dir, "a.b.sock", mtime: 1)
        touch(dir, "a.b.sock.client.100", mtime: 1000)
        touch(dir, "a.b.sock.client.200", mtime: 2000)   // newest attach
        touch(dir, "a.b.sock.client.150", mtime: 1500)
        touch(dir, "a.b.sock.client.12x")
        touch(dir, "a.b.sock.client.")
        touch(dir, "a.b.sock.act")
        touch(dir, "a.sock.client.300")
        touch(dir, "a.b.c.sock.client.400")
        XCTAssertEqual(AgentIsland.clientPIDs(AgentSessionKey(dir: dir.path, name: "a.b")), [200, 150, 100])
        XCTAssertEqual(AgentIsland.clientPIDs(AgentSessionKey(dir: dir.path, name: "a")), [300],
                       "a never claims a.b's files")
        XCTAssertEqual(AgentIsland.clientPIDs(AgentSessionKey(dir: dir.path, name: "a.b.c")), [400])
        XCTAssertEqual(AgentIsland.clientPID(fileName: "a.b.sock.client.-5", name: "a.b"), nil)
        XCTAssertEqual(AgentIsland.clientPID(fileName: "a.b.sock.client.٣", name: "a.b"), nil, "ASCII digits only")
    }

    /// dch hashes a long name to its on-disk form (canon_name); the client files use
    /// that form, and the key carries it from --ls-json, never the alias.
    func testHashedLongNameMatchesByOnDiskName() {
        let dir = tempDir()
        let onDisk = "a-very-long-session-name-that-dch-shortened-3fa9c1"
        touch(dir, "\(onDisk).sock.client.77")
        XCTAssertEqual(AgentIsland.clientPIDs(AgentSessionKey(dir: dir.path, name: onDisk)), [77])
        XCTAssertEqual(AgentIsland.clientPIDs(AgentSessionKey(dir: dir.path, name: "fix auth bug")), [])
    }

    // MARK: - Jump (J1-J3, J5, J6)

    private let ours: pid_t = 9000

    private func dch(ppid: pid_t, tty: Bool = true, argv: [String] = ["dch", "-l"]) -> AgentProcInfo {
        AgentProcInfo(ppid: ppid, hasTTY: tty, path: "/opt/homebrew/Cellar/dch/1.20.0/bin/dch", argv: argv)
    }

    private func shell(_ ppid: pid_t) -> AgentProcInfo {
        AgentProcInfo(ppid: ppid, hasTTY: true, path: "/bin/zsh", argv: ["-zsh"])
    }

    func testLocalClientRules() {
        XCTAssertTrue(AgentIsland.isLocalClient(dch(ppid: 400), ourPID: ours))
        XCTAssertFalse(AgentIsland.isLocalClient(nil, ourPID: ours), "dead")
        XCTAssertFalse(AgentIsland.isLocalClient(dch(ppid: 1, tty: false), ourPID: ours), "orphan, as dch reaps it")
        XCTAssertTrue(AgentIsland.isLocalClient(dch(ppid: 1, tty: true), ourPID: ours), "reparented with a tty is live")
        XCTAssertFalse(AgentIsland.isLocalClient(AgentProcInfo(ppid: 400, hasTTY: true, path: "/Applications/Slack.app/Contents/MacOS/Slack", argv: ["Slack"]), ourPID: ours),
                       "a stale file naming a reused pid")
        XCTAssertFalse(AgentIsland.isLocalClient(dch(ppid: ours, argv: ["dch", "-E", "-f", "-n", "x"]), ourPID: ours),
                       "Prosper's own Remote Terminal client")
        XCTAssertFalse(AgentIsland.isLocalClient(dch(ppid: 1, tty: true, argv: ["dch", "-E", "-f", "-n", "x"]), ourPID: ours),
                       "Prosper's client orphaned with its tty")
        XCTAssertFalse(AgentIsland.isLocalClient(dch(ppid: ours), ourPID: ours), "any child of ours")
    }

    /// dch -l (500) -> zsh (400) -> login (300) -> Ghostty (200) -> launchd.
    private var table: [pid_t: AgentProcInfo] {
        [500: dch(ppid: 400), 400: shell(300), 300: shell(200), 200: shell(1),
         // tmux: dch (600) -> zsh (610) -> tmux server (620) -> launchd
         600: dch(ppid: 610), 610: shell(620), 620: AgentProcInfo(ppid: 1, hasTTY: false, path: "/opt/homebrew/bin/tmux", argv: ["tmux"]),
         // iTerm: dch (700) -> zsh (710) -> iTerm2 (720)
         700: dch(ppid: 710), 710: shell(720), 720: shell(1),
         // Prosper's Remote Terminal client
         800: dch(ppid: ours, argv: ["dch", "-E", "-f", "-n", "x"]),
         // a client under a shell Prosper spawned: the walk must not stop at Prosper
         900: dch(ppid: 910), 910: shell(ours), ours: shell(1)]
    }
    private let apps: Set<pid_t> = [200, 720]

    private func target(_ clients: [pid_t]) -> AgentJumpTarget {
        let t = table, a = apps, o = ours
        return AgentIsland.jumpTarget(clients: clients, info: { t[$0] }, isRegularApp: { a.contains($0) || $0 == o },
                                      ourPID: o)
    }

    func testParentWalkReachesTheTerminalApp() {
        XCTAssertEqual(target([500]), .app(200))
    }

    func testNewestLiveClientWins() {
        XCTAssertEqual(target([700, 500]), .app(720), "newest file first")
        XCTAssertEqual(target([500, 700]), .app(200))
        XCTAssertEqual(target([999, 500]), .app(200), "a dead newest pid is skipped")
    }

    func testChainWithoutAnAppIsAttachedElsewhere() {
        XCTAssertEqual(target([600]), .attachedElsewhere)
        XCTAssertEqual(target([900]), .attachedElsewhere, "Prosper itself is never the jump target")
        XCTAssertEqual(target([600, 500]), .app(200), "an older jumpable client beats a tmux one")
    }

    func testProsperOwnedOrDeadClientsMeanNotAttached() {
        XCTAssertEqual(target([800]), .notAttached)
        XCTAssertEqual(target([999]), .notAttached)
        XCTAssertEqual(target([]), .notAttached)
    }

    func testProcArgsParsingAndOwnProcessInfo() {
        var buf: [UInt8] = withUnsafeBytes(of: Int32(3)) { Array($0) }
        for (word, pad) in [("/opt/homebrew/bin/dch", 4), ("dch", 1), ("-E", 1), ("-n", 1), ("HOME=/Users/x", 1)] {
            buf += Array(word.utf8)
            buf += [UInt8](repeating: 0, count: pad)
        }
        XCTAssertEqual(AgentIsland.parseProcArgs(buf), ["dch", "-E", "-n"], "argc bounds argv; env is not argv")
        XCTAssertEqual(AgentIsland.parseProcArgs([1, 0]), [])

        let me = AgentIsland.procInfo(getpid())
        XCTAssertEqual(me?.ppid, getppid())
        XCTAssertFalse(me?.path.isEmpty ?? true)
        XCTAssertFalse(me?.argv.isEmpty ?? true)
        XCTAssertNil(AgentIsland.procInfo(-1))
    }

    // MARK: - Poll gate (G1a-c, G3, G5a, G5d)

    private final class Fake: @unchecked Sendable {
        var now: TimeInterval = 10_000
        var calls: [[String]] = []
        var rows: [AgentSession] = []
    }

    private func poller(_ dirs: [String], _ f: Fake) -> AgentIslandPoller {
        AgentIslandPoller(now: { f.now }, dirs: { dirs }, list: { d, _ in
            f.calls.append(d)
            return f.rows.filter { d.contains($0.key.dir) }
        })
    }

    func testGateFetchesOnceThenTrailingThenOnlyOnTheBackstop() {
        let dir = tempDir(), f = Fake()
        touch(dir, "s.sock")
        touch(dir, "s.sock.act", mtime: 9_000)
        f.rows = [session("s", .idle, activity: 9_000, dir: dir.path)]
        let p = poller([dir.path], f)
        XCTAssertEqual(p.tick()?.map(\.name), ["s"])
        XCTAssertEqual(f.calls.count, 1)
        f.now += 1; XCTAssertNil(p.tick()); XCTAssertEqual(f.calls.count, 1, "nothing changed")
        f.now += 1; _ = p.tick(); XCTAssertEqual(f.calls.count, 2, "one trailing fetch 2 s after a change")
        for _ in 0..<9 { f.now += 1; _ = p.tick() }
        XCTAssertEqual(f.calls.count, 2, "quiet dir: no fork for 9 s")
        f.now += 1; _ = p.tick()
        XCTAssertEqual(f.calls.count, 3, "10 s backstop")
    }

    func testActBumpFetchesButNeverWithinTheTwoSecondFloor() {
        let dir = tempDir(), f = Fake()
        touch(dir, "s.sock")
        touch(dir, "s.sock.act", mtime: 9_000)
        let p = poller([dir.path], f)
        _ = p.tick()
        f.now += 2; _ = p.tick()   // trailing
        XCTAssertEqual(f.calls.count, 2)
        f.now += 1
        touch(dir, "s.sock.act", mtime: 10_003)
        _ = p.tick()
        XCTAssertEqual(f.calls.count, 2, "1 s after the last fetch: floor")
        f.now += 1; _ = p.tick()
        XCTAssertEqual(f.calls.count, 3, "the .act bump fetches once the floor passes")
    }

    /// G1a: dch's working-to-idle flip touches no file; refetch at floor(act) + 6.
    func testWorkingSessionRefetchesWhenItsOutputGoesQuiet() {
        let dir = tempDir(), f = Fake()
        f.now = 10_000.5
        touch(dir, "s.sock")
        touch(dir, "s.sock.act", mtime: 10_000.3)
        f.rows = [session("s", .working, dir: dir.path)]
        let p = poller([dir.path], f)
        _ = p.tick()                       // 10000.5
        f.now = 10_002.5; _ = p.tick()     // trailing
        XCTAssertEqual(f.calls.count, 2)
        f.now = 10_005.9; _ = p.tick()
        XCTAssertEqual(f.calls.count, 2, "still inside dch's 5 s working window")
        f.rows = [session("s", .idle, dir: dir.path)]
        f.now = 10_006.0
        XCTAssertEqual(p.tick()?.first?.state, .idle, "fetched at floor(act) + 6, well before the backstop")
        XCTAssertEqual(f.calls.count, 3)
        f.now = 10_007; _ = p.tick(); f.now = 10_015; _ = p.tick()
        XCTAssertEqual(f.calls.count, 3, "idle: nothing armed until the backstop")
    }

    /// G1b: a hook's `dch --report` writes only .sock.state; an alias rename only .sock.alias.
    func testStateOrAliasSidecarAloneTriggersAFetch() {
        let dir = tempDir(), f = Fake()
        touch(dir, "s.sock")
        touch(dir, "s.sock.act", mtime: 9_000)
        let p = poller([dir.path], f)
        _ = p.tick(); f.now += 2; _ = p.tick()
        f.now += 5; _ = p.tick()
        XCTAssertEqual(f.calls.count, 2)
        touch(dir, "s.sock.state", mtime: 10_007)
        f.now += 1; _ = p.tick()
        XCTAssertEqual(f.calls.count, 3, ".state only")
        f.now += 2; _ = p.tick()   // its trailing fetch
        XCTAssertEqual(f.calls.count, 4)
        touch(dir, "s.sock.alias", mtime: 10_010)
        f.now += 2; _ = p.tick()
        XCTAssertEqual(f.calls.count, 5, ".alias only")
    }

    func testNewAndRemovedSessionsAndAnEmptyDir() {
        let dir = tempDir(), f = Fake()
        let p = poller([dir.path], f)
        XCTAssertEqual(p.tick(), [], "no sessions: hidden")
        XCTAssertEqual(f.calls.count, 0, "and no fork")
        touch(dir, "s.sock")
        f.rows = [session("s", .working, dir: dir.path)]
        XCTAssertEqual(p.tick()?.map(\.name), ["s"])
        XCTAssertEqual(f.calls.count, 1)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("s.sock"))
        f.now += 0.5
        XCTAssertEqual(p.tick(), [], "a vanished socket drops at once, no fork")
        XCTAssertEqual(f.calls.count, 1)
    }

    /// G5d: the isolated dir before first use is "no sessions" there, not an error.
    func testMissingDirIsNoSessions() {
        let dir = tempDir(), f = Fake()
        let missing = dir.appendingPathComponent("never-created").path
        let p = poller([missing], f)
        XCTAssertEqual(p.tick(), [])
        f.now += 1; XCTAssertNil(p.tick())
        XCTAssertEqual(f.calls.count, 0)

        touch(dir, "s.sock")
        f.rows = [session("s", .idle, dir: dir.path)]
        let both = poller([dir.path, missing], f)
        XCTAssertEqual(both.tick()?.map(\.name), ["s"])
        XCTAssertEqual(f.calls, [[dir.path]], "only dirs with sessions are listed")
    }

    /// G5a: the same name in both dirs is two sessions everywhere.
    func testSameNameInBothDirsStaysTwoSessions() {
        let a = tempDir("a"), b = tempDir("b"), f = Fake()
        for d in [a, b] { touch(d, "x.sock") }
        touch(a, "x.sock.client.11")
        touch(b, "x.sock.client.22")
        f.rows = [session("x", .working, activity: 5, dir: a.path), session("x", .idle, activity: 6, dir: b.path)]
        let rows = poller([a.path, b.path], f).tick() ?? []
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.map(\.key.dir), [a.path, b.path])
        XCTAssertEqual(AgentIsland.clientPIDs(rows[0].key), [11])
        XCTAssertEqual(AgentIsland.clientPIDs(rows[1].key), [22])
    }

    func testAgeTicksFromTheStatNotTheFetch() {
        let dir = tempDir(), f = Fake()
        touch(dir, "s.sock")
        touch(dir, "s.sock.act", mtime: 9_000)
        f.rows = [session("s", .idle, activity: 1, dir: dir.path)]
        let p = poller([dir.path], f)
        XCTAssertEqual(p.tick()?.first?.activity, 9_000)
        touch(dir, "s.sock.act", mtime: 9_500)
        f.now += 1
        XCTAssertEqual(p.tick()?.first?.activity, 9_500, "inside the floor: no fork, age still moves")
        XCTAssertEqual(f.calls.count, 1)
    }

    // MARK: - Poll timer off main (#478)

    /// The handler fires on the poll queue; a main-actor-inferred one traps there.
    @MainActor func testPollTimerFiresOnABackgroundQueue() {
        let dir = tempDir(), f = Fake()
        touch(dir, "s.sock")
        f.rows = [session("s", .idle, dir: dir.path)]
        let got = expectation(description: "sessions")
        let label = "agentisland.test.poll"
        let t = AgentIslandController.makePollTimer(poller([dir.path], f), queue: DispatchQueue(label: label, qos: .utility)) {
            XCTAssertEqual($0.map(\.name), ["s"])
            XCTAssertEqual(String(cString: __dispatch_queue_get_label(nil)), label, "ran on the poll queue")
            XCTAssertFalse(Thread.isMainThread)
            got.fulfill()
        }
        t.resume()
        wait(for: [got], timeout: 5)
        t.cancel()
    }

    /// The controller's own reload() and queue, so re-inlining the handler into a
    /// @MainActor method fails here too. No sessions: no panel is ever built.
    @MainActor func testReloadPollTimerTicksOnTheControllerQueue() throws {
        let c = AgentIslandController.shared
        let ticked = expectation(description: "tick")
        ticked.assertForOverFulfill = false
        c.makePoller = { AgentIslandPoller(dirs: { ticked.fulfill(); return [] }, list: { _, _ in [] }) }
        let wasLive = c.extLive
        defer { c.extLive = wasLive; c.reload(); c.makePoller = { AgentIslandPoller() } }
        c.extLive = true
        c.reload()
        try XCTSkipIf(AgentIslandGeometry.current() == nil, "no screen geometry: reload() starts no timer")
        wait(for: [ticked], timeout: 5)
    }

    // MARK: - Answer lock, card generations, live IO (#475 K2, N9, N4)

    private static let bashScreen = """
    ──────────────────────────────────────────────────────────────────────────────────────────
     Bash command

       rm -rf .build
       Clean the build tree

     Do you want to proceed?
     ❯ 1. Yes
       2. No, and tell Claude what to do differently (esc)
    """

    /// Counts dch calls; the screen and status never change.
    private final class FakeIO: @unchecked Sendable {
        let lock = NSLock()
        var reads = 0, sends: [String] = []
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in self.lock.withLock { self.reads += 1 }; return AgentIslandTests.bashScreen },
                          status: { _ in "blocked" },
                          send: { _, d in self.lock.withLock { self.sends.append(d) } })
        }
    }

    /// A fresh controller with no panel, expanded over one blocked session.
    @MainActor private func cardController(_ f: FakeIO) -> (AgentIslandController, AgentSession) {
        let c = AgentIslandController(), s = session("s", .blocked, activity: 1)
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: notched)
        c.store?.sessions = [s]
        c.store?.expanded = true
        return (c, s)
    }

    /// Runs the queued dch work, then the main hops it posted.
    @MainActor private func drain(_ c: AgentIslandController) {
        c.queue.sync {}
        let hopped = expectation(description: "main hops")
        DispatchQueue.main.async { hopped.fulfill() }
        wait(for: [hopped], timeout: 5)
    }

    @MainActor func testTwoAnswersWhileTheFirstIsInFlightSendOnce() throws {
        let f = FakeIO(), (c, s) = cardController(f)
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bashScreen)), o = p.options[0]
        c.answer(s, p, o)
        c.answer(s, p, o)   // the main hop that ends the first has not run yet
        drain(c)
        XCTAssertEqual(f.sends, ["1"])
        c.answer(s, p, o)   // released on the hop
        drain(c)
        XCTAssertEqual(f.sends, ["1", "1"])
    }

    @MainActor func testInFlightAnswerBlocksReAddingTheCard() throws {
        let f = FakeIO(), (c, s) = cardController(f)
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bashScreen))
        c.answer(s, p, p.options[0])
        c.store?.sessions = [session("s", .blocked, activity: 2)]   // output moved
        c.refreshCards()
        drain(c)
        XCTAssertEqual(f.reads, 1, "only the answer's guard read")
        XCTAssertNil(c.store?.cards[s.key])
    }

    @MainActor func testLateReadNeverRevivesAnAnsweredCard() throws {
        let f = FakeIO(), (c, s) = cardController(f)
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bashScreen))
        c.refreshCards()                 // read queued at generation 1
        c.answer(s, p, p.options[0])     // generation 2, card removed
        drain(c)
        XCTAssertEqual(f.reads, 2)
        XCTAssertEqual(f.sends, ["1"])
        XCTAssertNil(c.store?.cards[s.key], "the generation-1 read result is dropped")
    }

    @MainActor func testLateReadNeverRevivesARemovedCard() {
        let f = FakeIO(), (c, s) = cardController(f)
        c.refreshCards()                                        // read queued
        c.store?.sessions = [session("s", .working, activity: 2)]
        c.refreshCards()                                        // no longer blocked
        drain(c)
        XCTAssertEqual(f.reads, 1)
        XCTAssertNil(c.store?.cards[s.key], "the read queued while blocked is dropped")
    }

    func testLiveIOPassesTheSessionDirAndExactArgv() {
        final class Rec: @unchecked Sendable { var calls: [([String], [String: String])] = [] }
        let r = Rec(), key = AgentSessionKey(dir: "/x/dch dir", name: "my sess")
        let io = AgentPromptIO.live { args, env in r.calls.append((args, env)); return Data("out".utf8) }
        XCTAssertEqual(io.read(key), "out")
        XCTAssertEqual(io.status(key), "out")
        io.send(key, "2")
        XCTAssertEqual(r.calls.map(\.0), [["--read", "my sess"], ["--status", "my sess"], ["--send", "my sess", "2"]])
        for (_, env) in r.calls {
            XCTAssertEqual(env["DCH_SOCKET_DIR"], "/x/dch dir")
            XCTAssertNil(env["DCH_SESSION"])
        }
    }

    // MARK: - Lifecycle, jump, outside click (#477 L2, L4, QE2)

    /// Records what reload() did, in order; the island never gets a panel or a real screen.
    private final class Lifecycle: @unchecked Sendable {
        var log: [String] = []
        var geometry: AgentIslandGeometry?
        var fontsOnMain: [Bool] = []
    }

    @MainActor private func lifecycleController(_ l: Lifecycle) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.center = NotificationCenter()   // private: posting here reaches only this controller
        c.io = FakeIO().io
        c.touchFonts = { l.log.append("fonts"); l.fontsOnMain.append(Thread.isMainThread) }
        c.currentGeometry = { l.log.append("geometry"); return l.geometry }
        c.makePoller = { l.log.append("poller"); return AgentIslandPoller(dirs: { [] }, list: { _, _ in [] }) }
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        return c
    }

    @MainActor private func postScreenChange(_ c: AgentIslandController) {
        c.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let hop = expectation(description: "main")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 5)
    }

    @MainActor func testDisablingCancelsTheTimerAndRemovesTheScreenObserver() throws {
        let l = Lifecycle(), c = lifecycleController(l)
        l.geometry = notched
        c.extLive = true
        c.reload()
        let t = try XCTUnwrap(c.timer)
        XCTAssertNotNil(c.screenObserver)
        c.extLive = false
        c.reload()
        XCTAssertTrue(t.isCancelled)
        XCTAssertNil(c.timer)
        XCTAssertNil(c.screenObserver)
        XCTAssertNil(c.store)
        let reloads = l.log.filter { $0 == "fonts" }.count
        postScreenChange(c)
        XCTAssertEqual(l.log.filter { $0 == "fonts" }.count, reloads, "the observer is gone: a screen change runs nothing")
    }

    @MainActor func testDisabledReloadBuildsNothing() {
        let l = Lifecycle(), c = lifecycleController(l)
        l.geometry = notched
        c.reload()
        XCTAssertNil(c.timer)
        XCTAssertNil(c.screenObserver)
        XCTAssertNil(c.store)
        XCTAssertEqual(l.log, ["fonts"], "no geometry read, no poller, so no dch fork")
    }

    /// L4: no screen at reload, one later: the screen-change observer builds the island.
    @MainActor func testScreenlessReloadBuildsTheIslandWhenAScreenAppears() {
        let l = Lifecycle(), c = lifecycleController(l)
        c.extLive = true
        c.reload()
        XCTAssertNil(c.timer, "no screen: nothing to poll for yet")
        XCTAssertNotNil(c.screenObserver, "but a screen change is watched")
        XCTAssertFalse(l.log.contains("poller"))
        l.geometry = notched
        postScreenChange(c)
        XCTAssertNotNil(c.timer)
        XCTAssertEqual(c.store?.geometry, notched)
        XCTAssertEqual(l.log.filter { $0 == "poller" }.count, 1)
        postScreenChange(c)
        XCTAssertEqual(l.log.filter { $0 == "poller" }.count, 1, "idempotent: one timer")
    }

    /// #486 B12: a second enable keeps the one screen observer; a change reloads once.
    @MainActor func testSecondEnableInstallsNoSecondScreenObserver() throws {
        let l = Lifecycle(), c = lifecycleController(l)
        c.extLive = true
        c.reload()
        let first = try XCTUnwrap(c.screenObserver)
        c.reload()   // still screenless: the guard returns before the timer, every time
        XCTAssertTrue(c.screenObserver === first)
        let reloads = l.log.filter { $0 == "fonts" }.count
        postScreenChange(c)
        XCTAssertEqual(l.log.filter { $0 == "fonts" }.count, reloads + 1, "one observer, one reload")
    }

    /// QE2: the fonts are built on main before the geometry read and the poller.
    @MainActor func testReloadTouchesTheCardFontsOnMainFirst() {
        let l = Lifecycle(), c = lifecycleController(l)
        l.geometry = notched
        c.extLive = true
        c.reload()
        XCTAssertEqual(l.log, ["fonts", "geometry", "poller"])
        XCTAssertEqual(l.fontsOnMain, [true])
    }

    @MainActor func testAttachedElsewhereNoticesFirstAndCopiesOnTheSecondClick() {
        let c = AgentIslandController(), s = session("s", .idle, dir: "/x/other dir")
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: notched)
        c.store?.sessions = [s]
        c.jumpTarget = { _ in .attachedElsewhere }
        c.clickAction = { .copy }
        let l = Launches()
        c.launchTerminal = { t, launch, _ in l.calls.append((t, launch)) }
        let pb = Pasteboard.general
        pb.clearContents()
        let before = pb.changeCount
        c.jump(s)
        XCTAssertEqual(c.store?.notices[s.key], "Attached in tmux/ssh, click to copy attach command")
        XCTAssertEqual(pb.changeCount, before, "the first click copies nothing")
        XCTAssertNil(pb.string(forType: .string))
        c.jump(s)
        XCTAssertEqual(pb.string(forType: .string), AgentIsland.attachCommand(s.key, defaultDir: DchCommand.defaultSocketDir))
        XCTAssertEqual(c.store?.notices[s.key], "Attach command copied")
        XCTAssertTrue(l.calls.isEmpty, "copy never opens a terminal")
    }

    // MARK: - Click setting and terminal launch (#500)

    private final class Launches: @unchecked Sendable {
        var calls: [(AgentTerminal, AgentTerminal.Launch)] = []
        var done: [@Sendable (Bool) -> Void] = []
        var focused: [pid_t] = []
        var events: [NSAppleEventDescriptor] = []
    }

    /// A controller with a recording launcher (never a real terminal), Kitty picked
    /// and a fake dch path; `ok` nil leaves the launch pending.
    @MainActor private func clickController(_ target: AgentJumpTarget, _ click: AgentIslandClick,
                                            ok: Bool? = true, event: OSStatus = noErr,
                                            _ s: AgentSession) -> (AgentIslandController, Launches) {
        let c = AgentIslandController(), l = Launches()
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: notched)
        c.store?.sessions = [s]
        c.store?.expanded = true
        c.jumpTarget = { _ in target }
        c.clickAction = { click }
        c.terminal = { .kitty }
        c.focusApp = { pid, _ in l.focused.append(pid) }
        c.launchTerminal = { t, launch, done in
            l.calls.append((t, launch))
            if let ok { done(ok) } else { l.done.append(done) }
        }
        c.sendGhostty = { e, done in l.events.append(e); done(event) }
        DchCommand.dchPathOverride = "/opt/fake/dch"
        addTeardownBlock { DchCommand.dchPathOverride = nil }
        Pasteboard.general.clearContents()
        return (c, l)
    }

    func testClickSettingDefaultsToOpen() {
        XCTAssertEqual(AgentIslandClick(raw: nil), .open)
        XCTAssertEqual(AgentIslandClick(raw: "bogus"), .open)
        XCTAssertEqual(AgentIslandClick(raw: "copy"), .copy)
        XCTAssertEqual(AgentIslandClick(raw: "open"), .open)
    }

    /// The controller reads the app's store on every click.
    @MainActor func testControllerReadsTheClickAndTerminalPreferences() {
        let was = (Preferences.agentIslandClick, Preferences.agentIslandTerminal)
        defer { Preferences.agentIslandClick = was.0; Preferences.agentIslandTerminal = was.1 }
        let c = AgentIslandController()
        Preferences.agentIslandClick = nil
        XCTAssertEqual(c.clickAction(), .open)
        Preferences.agentIslandClick = "copy"
        XCTAssertEqual(c.clickAction(), .copy)
        Preferences.agentIslandTerminal = "terminal"
        XCTAssertEqual(c.terminal(), .terminal)
        Preferences.agentIslandTerminal = nil
        XCTAssertEqual(c.terminal(), AgentTerminal.isInstalled(.ghostty) ? .ghostty : .terminal)
    }

    func testTerminalDefaultIsGhosttyWhenInstalledElseTerminal() {
        let all: (AgentTerminal) -> Bool = { _ in true }, none: (AgentTerminal) -> Bool = { _ in false }
        XCTAssertEqual(AgentTerminal.resolve(raw: nil, installed: all), .ghostty)
        XCTAssertEqual(AgentTerminal.resolve(raw: nil, installed: none), .terminal)
        XCTAssertEqual(AgentTerminal.resolve(raw: "kitty", installed: all), .kitty)
        XCTAssertEqual(AgentTerminal.resolve(raw: "kitty", installed: { $0 == .ghostty }), .ghostty,
                       "an uninstalled pick falls back")
        XCTAssertEqual(AgentTerminal.resolve(raw: "terminal", installed: all), .terminal)
        XCTAssertEqual(AgentTerminal.available(installed: none), [.terminal], "Terminal always listed")
        XCTAssertEqual(AgentTerminal.available(installed: { $0 == .wezterm }), [.terminal, .wezterm])
        XCTAssertEqual(AgentTerminal.allCases.map(\.bundleID),
                       ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
                        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty"])
    }

    /// A name with spaces and both quotes, in a non-default dir: argv terminals get
    /// the words unquoted, script terminals get them shell-quoted.
    func testLaunchPerTerminalForANameWithSpacesAndQuotes() {
        let key = AgentSessionKey(dir: "/x/other dir", name: #"my "odd" it's"#)
        let argv = AgentIsland.attachArgv(key, dch: "/opt/my bin/dch")
        XCTAssertEqual(argv, ["/usr/bin/env", "DCH_SOCKET_DIR=/x/other dir", "/opt/my bin/dch", "-n", #"my "odd" it's"#])
        XCTAssertEqual(AgentTerminal.alacritty.launch(argv), .arguments(["-e"] + argv))
        XCTAssertEqual(AgentTerminal.wezterm.launch(argv), .arguments(["start", "--"] + argv))
        XCTAssertEqual(AgentTerminal.kitty.launch(argv), .arguments(argv))
        let want = "#!/bin/sh\n/bin/rm -f \"$0\"\nexec /usr/bin/env 'DCH_SOCKET_DIR=/x/other dir' '/opt/my bin/dch' -n 'my \"odd\" it'\\''s'\n"
        XCTAssertEqual(AgentTerminal.terminal.launch(argv), .script(want))
        XCTAssertEqual(AgentTerminal.iterm.launch(argv), .script(want))
        XCTAssertEqual(AgentTerminal.ghostty.launch(argv), .script(want),
                       "Ghostty: a window in the running instance, not a new instance per click")
    }

    /// The script round-trips through a real /bin/sh: a stand-in "dch" prints its
    /// env dir and argv, and the script deletes itself. No terminal, no dch.
    func testTerminalScriptRunsTheExactArgvAndDeletesItself() throws {
        let dir = tempDir()
        let fake = dir.appendingPathComponent("fake dch")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$DCH_SOCKET_DIR\" \"$@\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let key = AgentSessionKey(dir: "/x/other dir", name: #"my "odd" it's $HOME `x`"#)
        guard case .script(let text) = AgentTerminal.terminal.launch(AgentIsland.attachArgv(key, dch: fake.path)) else {
            return XCTFail("Terminal runs a script")
        }
        let file = dir.appendingPathComponent("a.command")
        try Data(text.utf8).write(to: file)
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [file.path]
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let got = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(got, "/x/other dir\n-n\n\(key.name)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the script deletes itself")
    }

    @MainActor func testAppTargetJumpsUnderEitherSetting() {
        for click in AgentIslandClick.allCases {
            let s = session("s", .idle)
            let (c, l) = clickController(.app(4242), click, s)
            c.jump(s)
            XCTAssertEqual(l.focused, [4242], "\(click)")
            XCTAssertTrue(l.calls.isEmpty, "\(click): a window to jump to opens nothing")
            XCTAssertNil(Pasteboard.general.string(forType: .string), "\(click)")
            XCTAssertEqual(c.store?.expanded, false, "\(click)")
        }
    }

    /// Not attached, or only in tmux/ssh: one click opens the chosen terminal with
    /// the attach argv, with no two-click notice and no copy, then collapses.
    @MainActor func testOpenSettingLaunchesTheTerminalForUnjumpableTargets() {
        for target in [AgentJumpTarget.notAttached, .attachedElsewhere] {
            let s = session(#"my "odd" it's"#, .idle, dir: "/x/other dir")
            let (c, l) = clickController(target, .open, s)
            c.jump(s)
            XCTAssertEqual(l.calls.count, 1, "\(target)")
            XCTAssertEqual(l.calls.first?.0, .kitty, "\(target)")
            XCTAssertEqual(l.calls.first?.1, .arguments(AgentIsland.attachArgv(s.key, dch: "/opt/fake/dch")), "\(target)")
            XCTAssertNil(c.store?.notices[s.key], "\(target): no notice")
            drain(c)
            XCTAssertEqual(c.store?.expanded, false, "\(target): collapses once open")
            XCTAssertNil(Pasteboard.general.string(forType: .string), "\(target): nothing copied")
            XCTAssertTrue(l.focused.isEmpty)
            XCTAssertTrue(l.events.isEmpty, "\(target): only Ghostty gets an Apple Event")
        }
    }

    @MainActor func testCopySettingCopiesANotAttachedSession() {
        let s = session("s", .idle, dir: "/x/other dir")
        let (c, l) = clickController(.notAttached, .copy, s)
        c.jump(s)
        XCTAssertTrue(l.calls.isEmpty)
        XCTAssertEqual(Pasteboard.general.string(forType: .string),
                       AgentIsland.attachCommand(s.key, defaultDir: DchCommand.defaultSocketDir))
        XCTAssertEqual(c.store?.notices[s.key], "Attach command copied")
    }

    @MainActor func testFailedOpenCopiesAndSaysSo() {
        let s = session("s", .idle, dir: "/x/other dir")
        let (c, l) = clickController(.notAttached, .open, ok: false, s)
        c.jump(s)
        XCTAssertEqual(l.calls.count, 1)
        drain(c)
        XCTAssertEqual(Pasteboard.general.string(forType: .string),
                       AgentIsland.attachCommand(s.key, defaultDir: DchCommand.defaultSocketDir))
        XCTAssertEqual(c.store?.notices[s.key], "Couldn't open kitty, attach command copied")
        XCTAssertEqual(c.store?.expanded, true, "the notice stays on screen")
    }

    @MainActor func testASecondClickWhileLaunchingOpensNothing() {
        let s = session("s", .idle)
        let (c, l) = clickController(.notAttached, .open, ok: nil, s)
        c.jump(s)
        c.jump(s)
        XCTAssertEqual(l.calls.count, 1, "one window per launch")
        l.done.first?(true)
        drain(c)
        c.jump(s)
        XCTAssertEqual(l.calls.count, 2, "the launch finished: a click opens again")
    }

    // MARK: - Ghostty Apple Event (#505)

    private func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    /// The configuration record's command, its env list, and its key count.
    private func ghosttyConfig(_ e: NSAppleEventDescriptor) -> (command: String?, env: [String], keys: Int) {
        let cfg = e.paramDescriptor(forKeyword: code(e.eventID == code("NTab") ? "GNtS" : "GNwS"))
        let env = cfg?.forKeyword(code("GScE"))
        return (cfg?.forKeyword(code("GScC"))?.stringValue,
                (0..<(env?.numberOfItems ?? 0)).compactMap { env?.atIndex($0 + 1)?.stringValue },
                cfg?.numberOfItems ?? 0)
    }

    func testGhosttyEventForAPlainName() {
        let e = AgentIsland.ghosttyNewWindow(AgentSessionKey(dir: "/d", name: "s"), dch: "/opt/fake/dch")
        XCTAssertEqual(e.eventClass, code("Ghst"))
        XCTAssertEqual(e.eventID, code("NWin"))
        let target = e.attributeDescriptor(forKeyword: keyAddressAttr)
        XCTAssertEqual(target?.descriptorType, typeApplicationBundleID)
        XCTAssertEqual(target.map { String(decoding: $0.data, as: UTF8.self) }, "com.mitchellh.ghostty")
        let cfg = ghosttyConfig(e)
        XCTAssertEqual(cfg.command, "/usr/bin/env DCH_SOCKET_DIR=/d /opt/fake/dch -n s",
                       "the env lead, no direct:/shell: prefix, no exec")
        XCTAssertEqual(cfg.keys, 1, "the command only; the dir rides in env's argument")
    }

    /// #527: new tab with the same configuration and no `in`, so Ghostty picks its
    /// main window, or makes a window when it has none.
    func testGhosttyNewTabEventCarriesTheConfigurationAndNoTargetWindow() {
        let key = AgentSessionKey(dir: "/d", name: "s")
        let e = AgentIsland.ghosttyNewTab(key, dch: "/opt/fake/dch")
        XCTAssertEqual(e.eventClass, code("Ghst"))
        XCTAssertEqual(e.eventID, code("NTab"))
        let target = e.attributeDescriptor(forKeyword: keyAddressAttr)
        XCTAssertEqual(target.map { String(decoding: $0.data, as: UTF8.self) }, "com.mitchellh.ghostty")
        XCTAssertNil(e.paramDescriptor(forKeyword: code("GNtW")), "no in: Ghostty's preferred parent, or a new window")
        XCTAssertNil(e.paramDescriptor(forKeyword: code("GNwS")), "new tab's own configuration keyword")
        XCTAssertEqual(e.numberOfItems, 1, "the configuration only")
        let cfg = ghosttyConfig(e)
        XCTAssertEqual(cfg.command, ghosttyConfig(AgentIsland.ghosttyNewWindow(key, dch: "/opt/fake/dch")).command)
        XCTAssertEqual(cfg.command, "/usr/bin/env DCH_SOCKET_DIR=/d /opt/fake/dch -n s")
        XCTAssertEqual(cfg.keys, 1)
    }

    /// Quotes, backslashes, $ and backticks in the name, the dir and the dch path
    /// reach dch as one argv word each, through the wrapper Ghostty's binary runs a
    /// shell-mode command with (bash --noprofile --norc -c "exec -l <command>"),
    /// and dch's own argv[0] carries no login "-" (it re-execs itself from it).
    func testGhosttyEventCommandRoundTripsThroughGhosttysShell() throws {
        let dir = tempDir()
        // A real binary: a #! script's $0 is its path whatever argv[0] was.
        let fake = dir.appendingPathComponent(#"fake "dch" $x"#)
        let src = dir.appendingPathComponent("fake.c")
        try Data(#"""
            #include <stdio.h>
            #include <stdlib.h>
            int main(int argc, char **argv) {
                const char *d = getenv("DCH_SOCKET_DIR");
                printf("%s\n%s\n", argv[0], d ? d : "");
                for (int i = 1; i < argc; i++) printf("%s\n", argv[i]);
                return 0;
            }
            """#.utf8).write(to: src)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-o", fake.path, src.path]
        try cc.run()
        cc.waitUntilExit()
        XCTAssertEqual(cc.terminationStatus, 0, "the stand-in dch compiles")
        let key = AgentSessionKey(dir: #"/x/other dir "q" it's $HOME \b=c"#, name: #"my "odd" it's $HOME `x` \n \"#)
        // #529: and a dch path with "=", which env alone would read as an assignment.
        let equals = dir.appendingPathComponent(#"fake "dch" $x=y"#)
        try FileManager.default.copyItem(at: fake, to: equals)
        for dch in [fake.path, equals.path] {
            let cfg = ghosttyConfig(AgentIsland.ghosttyNewWindow(key, dch: dch))
            XCTAssertEqual(cfg.command, AgentIsland.attachArgv(key, dch: dch).map(AgentIsland.shellQuoted).joined(separator: " "))
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["--noprofile", "--norc", "-c", "exec -l \(cfg.command ?? "")"]
            var env = ["PATH": "/usr/bin:/bin"]
            for kv in cfg.env { let pair = kv.split(separator: "=", maxSplits: 1).map(String.init); env[pair[0]] = pair[1] }
            p.environment = env   // whatever list the event carries, as Ghostty would apply it
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            let got = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let argv0 = got.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            XCTAssertEqual(argv0, dch, "dch's argv[0] is its path, no leading -")
            XCTAssertEqual(got, "\(dch)\n\(key.dir)\n-n\n\(key.name)\n")
        }
    }

    /// Ghostty: the event goes, no script, no copy, and the island collapses.
    @MainActor func testGhosttyOpensByAppleEventAndCollapses() {
        let s = session(#"my "odd" it's"#, .idle, dir: "/x/other dir")
        let (c, l) = clickController(.notAttached, .open, s)
        c.terminal = { .ghostty }
        c.jump(s)
        XCTAssertEqual(l.events.map(\.eventID), [code("NTab")], "one event: a new tab")
        XCTAssertEqual(l.events.first.map(ghosttyConfig)?.command,
                       ghosttyConfig(AgentIsland.ghosttyNewTab(s.key, dch: "/opt/fake/dch")).command)
        drain(c)
        XCTAssertTrue(l.calls.isEmpty, "no .command script, so no Ghostty prompt")
        XCTAssertEqual(c.store?.expanded, false)
        XCTAssertNil(Pasteboard.general.string(forType: .string))
        XCTAssertNil(c.store?.notices[s.key])
        c.jump(s)
        XCTAssertEqual(l.events.count, 2, "the open finished: a click opens again")
    }

    /// Not running, no dictionary or AppleScript off: the script path, and the
    /// next click tries the event again. (#529: a timeout copies instead.)
    @MainActor func testGhosttyFallsBackToTheScriptWhenTheEventFails() {
        for status in [procNotFound, errAEEventNotHandled].map(OSStatus.init) {
            let s = session("s", .idle, dir: "/x/other dir")
            let (c, l) = clickController(.notAttached, .open, event: status, s)
            c.terminal = { .ghostty }
            c.jump(s)
            drain(c); drain(c)
            XCTAssertEqual(l.events.count, 1, "\(status)")
            XCTAssertEqual(l.calls.count, 1, "\(status)")
            XCTAssertEqual(l.calls.first?.0, .ghostty, "\(status)")
            XCTAssertEqual(l.calls.first?.1, AgentTerminal.ghostty.launch(AgentIsland.attachArgv(s.key, dch: "/opt/fake/dch")))
            XCTAssertEqual(c.store?.expanded, false, "\(status): the script opened")
            XCTAssertFalse(c.ghosttyDenied, "\(status)")
            c.jump(s)
            XCTAssertEqual(l.events.count, 2, "\(status): not a denial, so the event is tried again")
        }
    }

    /// -1743: the script this time, and no event for the rest of the run.
    @MainActor func testDeniedGhosttyStopsSendingEvents() {
        let s = session("s", .idle)
        let (c, l) = clickController(.notAttached, .open, event: OSStatus(errAEEventNotPermitted), s)
        c.terminal = { .ghostty }
        c.jump(s)
        drain(c); drain(c)
        XCTAssertEqual(l.events.map(\.eventID), [code("NTab")], "no new-window retry after a denial")
        XCTAssertEqual(l.calls.count, 1, "the denied click still opens by script")
        XCTAssertTrue(c.ghosttyDenied)
        c.jump(s)
        drain(c)
        XCTAssertEqual(l.events.count, 1, "denied: no second event")
        XCTAssertEqual(l.calls.count, 2)
    }

    /// #527: Ghostty refuses the tab (non-native fullscreen, -10000): a new window,
    /// then the script; a denial on the window still latches.
    @MainActor func testGhosttyNewTabFailureFallsBackToNewWindowThenScript() {
        let failed = OSStatus(errAEEventFailed), denied = OSStatus(errAEEventNotPermitted)
        for (statuses, script, latched) in [([failed, noErr], false, false), ([failed, failed], true, false),
                                            ([failed, denied], true, true)] {
            let s = session("s", .idle, dir: "/x/other dir")
            let (c, l) = clickController(.notAttached, .open, s)
            var queue = statuses
            c.terminal = { .ghostty }
            c.sendGhostty = { e, done in l.events.append(e); done(queue.isEmpty ? noErr : queue.removeFirst()) }
            c.jump(s)
            drain(c); drain(c); drain(c)
            XCTAssertEqual(l.events.map(\.eventID), [code("NTab"), code("NWin")], "\(statuses)")
            XCTAssertEqual(l.events.last.map(ghosttyConfig)?.command,
                           ghosttyConfig(AgentIsland.ghosttyNewTab(s.key, dch: "/opt/fake/dch")).command, "\(statuses)")
            XCTAssertEqual(l.calls.count, script ? 1 : 0, "\(statuses)")
            XCTAssertEqual(l.calls.first?.0, script ? .ghostty : nil, "\(statuses)")
            XCTAssertEqual(c.ghosttyDenied, latched, "\(statuses)")
            XCTAssertEqual(c.store?.expanded, false, "\(statuses): opened")
            XCTAssertNil(Pasteboard.general.string(forType: .string), "\(statuses)")
            queue = [noErr]
            c.jump(s)
            XCTAssertEqual(l.events.count, latched ? 2 : 3, "\(statuses): the open finished, a click opens again")
        }
    }

    /// QA F1: a failure that lands after teardown opens nothing, at either step:
    /// no further event, no script, no copy.
    @MainActor func testGhosttyFailureAfterTeardownOpensNothing() {
        let failed = OSStatus(errAEEventFailed)
        for (live, last) in [([], failed), ([], OSStatus(errAETimeout)), ([], OSStatus(errAEEventNotPermitted)),
                             ([failed], failed)] as [([OSStatus], OSStatus)] {
            let s = session("s", .idle)
            let (c, l) = clickController(.notAttached, .open, s)
            var pending: [@Sendable (OSStatus) -> Void] = []
            c.terminal = { .ghostty }
            c.sendGhostty = { e, done in l.events.append(e); pending.append(done) }
            c.jump(s)
            for status in live where !pending.isEmpty { pending.removeFirst()(status); drain(c) }
            XCTAssertEqual(l.events.count, live.count + 1, "\(live)")
            c.reload()   // extLive is false: teardown
            XCTAssertNil(c.store)
            guard !pending.isEmpty else { XCTFail("\(live): no event pending at teardown"); continue }
            pending.removeFirst()(last)
            drain(c); drain(c)
            XCTAssertEqual(l.events.count, live.count + 1, "\(live) \(last): no further event")
            XCTAssertTrue(l.calls.isEmpty, "\(live) \(last): no script")
            XCTAssertNil(Pasteboard.general.string(forType: .string), "\(live) \(last)")
        }
    }

    /// The event and then the script fail: copy with the existing notice.
    @MainActor func testGhosttyEventAndScriptBothFailCopies() {
        let s = session("s", .idle, dir: "/x/other dir")
        let (c, l) = clickController(.notAttached, .open, ok: false, event: OSStatus(procNotFound), s)
        c.terminal = { .ghostty }
        c.jump(s)
        drain(c); drain(c)
        XCTAssertEqual(l.events.count, 1)
        XCTAssertEqual(l.calls.count, 1)
        XCTAssertEqual(Pasteboard.general.string(forType: .string),
                       AgentIsland.attachCommand(s.key, defaultDir: DchCommand.defaultSocketDir))
        XCTAssertEqual(c.store?.notices[s.key], "Couldn't open Ghostty, attach command copied")
        XCTAssertEqual(c.store?.expanded, true)
    }

    /// #529 (QA L1): a timeout (-1712) may still have opened the tab or window, so
    /// nothing else opens; the attach command is copied and the notice says why.
    @MainActor func testGhosttyTimeoutCopiesAndOpensNothingMore() {
        let failed = OSStatus(errAEEventFailed), timeout = OSStatus(errAETimeout)
        for statuses in [[timeout], [failed, timeout]] {
            let s = session("s", .idle, dir: "/x/other dir")
            let (c, l) = clickController(.notAttached, .open, s)
            var queue = statuses
            c.terminal = { .ghostty }
            c.sendGhostty = { e, done in l.events.append(e); done(queue.isEmpty ? noErr : queue.removeFirst()) }
            c.jump(s)
            drain(c); drain(c); drain(c)
            XCTAssertEqual(l.events.map(\.eventID), Array([code("NTab"), code("NWin")].prefix(statuses.count)),
                           "\(statuses): no further event")
            XCTAssertTrue(l.calls.isEmpty, "\(statuses): no script")
            XCTAssertEqual(Pasteboard.general.string(forType: .string),
                           AgentIsland.attachCommand(s.key, defaultDir: DchCommand.defaultSocketDir), "\(statuses)")
            XCTAssertEqual(c.store?.notices[s.key], "Ghostty didn't answer, attach command copied", "\(statuses)")
            XCTAssertEqual(c.store?.expanded, true, "\(statuses): the notice stays on screen")
            XCTAssertFalse(c.ghosttyDenied, "\(statuses)")
            c.jump(s)
            XCTAssertEqual(l.events.count, statuses.count + 1, "\(statuses): the open finished, a click opens again")
        }
    }

    /// QA #333 L-1: a terminal launch that fails after teardown writes nothing to
    /// the pasteboard (the store guard in opened()).
    @MainActor func testLateLaunchFailureAfterTeardownCopiesNothing() {
        let s = session("s", .idle, dir: "/x/other dir")
        let (c, l) = clickController(.notAttached, .open, ok: nil, s)
        c.jump(s)
        XCTAssertEqual(l.calls.count, 1)
        c.reload()   // extLive is false: teardown
        XCTAssertNil(c.store)
        let before = Pasteboard.general.changeCount
        l.done.first?(false)
        drain(c)
        XCTAssertEqual(Pasteboard.general.changeCount, before, "no pasteboard write after teardown")
        XCTAssertNil(Pasteboard.general.string(forType: .string))
    }

    /// QA #333 L-2: a dch path with "=" reaches dch, not env's assignment list, for
    /// an argv terminal (kitty) and a script one (Terminal). A stand-in "dch".
    func testDchPathWithAnEqualsSignStillRunsDch() throws {
        let dir = tempDir().appendingPathComponent("a=b", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("fake=dch")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$DCH_SOCKET_DIR\" \"$@\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let key = AgentSessionKey(dir: "/x/other dir", name: "s=1")
        let argv = AgentIsland.attachArgv(key, dch: fake.path)
        XCTAssertEqual(AgentIsland.attachArgv(key, dch: "/opt/fake/dch"),
                       ["/usr/bin/env", "DCH_SOCKET_DIR=/x/other dir", "/opt/fake/dch", "-n", "s=1"], "no = in the path: as before")
        guard case .arguments(let args) = AgentTerminal.kitty.launch(argv),
              case .script(let text) = AgentTerminal.terminal.launch(argv) else { return XCTFail("kitty argv, Terminal script") }
        let file = dir.appendingPathComponent("a.command")
        try Data(text.utf8).write(to: file)
        for (exe, rest) in [(args[0], Array(args.dropFirst())), ("/bin/sh", [file.path])] {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = rest
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, exe)
            XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                           "/x/other dir\n-n\ns=1\n", exe)
        }
    }

    /// QA #333 L-3: with the stored terminal gone the picker shows the fallback;
    /// picking that same one saves it (scratch Preferences domain).
    @MainActor func testPickingTheShownFallbackTerminalSavesIt() {
        let was = Preferences.agentIslandTerminal
        defer { Preferences.agentIslandTerminal = was }
        Preferences.agentIslandTerminal = "uninstalled"
        let pane = AgentIslandPane()
        let shown = pane.terminalPick.wrappedValue
        XCTAssertEqual(shown, AgentTerminal.resolve(raw: nil, installed: AgentTerminal.isInstalled), "the fallback shows")
        pane.terminalPick.wrappedValue = shown
        XCTAssertEqual(Preferences.agentIslandTerminal, shown.rawValue, "picking the shown fallback saves it")
    }

    /// A scripted cold start: the statuses each attempt returns, and what it did.
    private final class ColdStart: @unchecked Sendable {
        var statuses: [OSStatus]
        var attempts = 0, launches = 0, slept: [TimeInterval] = []
        init(_ s: [OSStatus]) { statuses = s }
        func deliver() -> OSStatus {
            GhosttyEventSender.deliver(
                attempt: { attempts += 1; return statuses.count > 1 ? statuses.removeFirst() : statuses[0] },
                launch: { launches += 1 }, sleep: { slept.append($0) })
        }
    }

    func testGhosttyColdStartLaunchesOnceAndRetriesUntilTheEventLands() {
        let r = ColdStart([OSStatus(procNotFound), OSStatus(procNotFound), OSStatus(errAEEventNotHandled), noErr])
        XCTAssertEqual(r.deliver(), noErr)
        XCTAssertEqual(r.launches, 1, "launched once, no arguments")
        XCTAssertEqual(r.attempts, 4, "-600 while starting, -1708 while its handler loads")
        XCTAssertEqual(r.slept, [0.5, 0.5, 0.5])
    }

    func testGhosttyColdStartGivesUpAfterEightSeconds() {
        let r = ColdStart([OSStatus(procNotFound)])
        XCTAssertEqual(r.deliver(), OSStatus(procNotFound))
        XCTAssertEqual(r.launches, 1)
        XCTAssertEqual(r.attempts, 17)
        XCTAssertEqual(r.slept.reduce(0, +), 8, accuracy: 0.001)
    }

    /// Running, or a status that is not "still starting": no launch, no retry.
    func testGhosttyEventOnlyRetriesAfterLaunchingIt() {
        for first in [noErr, OSStatus(errAEEventNotHandled), OSStatus(errAETimeout), OSStatus(errAEEventNotPermitted)] {
            let r = ColdStart([first, noErr])
            XCTAssertEqual(r.deliver(), first, "\(first)")
            XCTAssertEqual(r.launches, 0, "\(first): running Ghostty is never relaunched")
            XCTAssertEqual(r.attempts, 1, "\(first)")
        }
        let r = ColdStart([OSStatus(procNotFound), OSStatus(errAEEventNotPermitted), noErr])
        XCTAssertEqual(r.deliver(), OSStatus(errAEEventNotPermitted), "a denial mid-retry ends it")
        XCTAssertEqual(r.attempts, 2)
    }

    /// Through the controller: -600 then noErr opens with no script.
    @MainActor func testGhosttyColdStartOpensWithNoScript() {
        let s = session("s", .idle)
        let (c, l) = clickController(.notAttached, .open, s)
        let r = ColdStart([OSStatus(procNotFound), noErr])
        c.terminal = { .ghostty }
        c.sendGhostty = { _, done in done(r.deliver()) }
        c.jump(s)
        drain(c); drain(c)
        XCTAssertEqual(r.launches, 1)
        XCTAssertTrue(l.calls.isEmpty, "no script, so no Ghostty prompt")
        XCTAssertEqual(c.store?.expanded, false)
    }

    /// Through the controller: -600 for the whole budget opens by script; a
    /// -1743 during the retries still latches.
    @MainActor func testGhosttyColdStartFallsBackAndLatchesADenial() {
        for (statuses, denied) in [([procNotFound], false), ([procNotFound, errAEEventNotPermitted], true)] {
            let s = session("s", .idle)
            let (c, l) = clickController(.notAttached, .open, s)
            let r = ColdStart(statuses.map(OSStatus.init))
            c.terminal = { .ghostty }
            c.sendGhostty = { e, done in l.events.append(e); done(r.deliver()) }
            c.jump(s)
            drain(c); drain(c)
            XCTAssertEqual(l.calls.count, 1, "\(statuses): the script")
            XCTAssertEqual(c.ghosttyDenied, denied, "\(statuses)")
            c.jump(s)
            drain(c); drain(c)
            XCTAssertEqual(l.events.count, denied ? 1 : 2, "\(statuses)")
        }
    }

    @MainActor func testOutsideClickMonitorIsInstalledOnExpandAndRemovedOnCollapse() {
        final class Monitors: @unchecked Sendable { var installed = 0; var removed: [String] = [] }
        let m = Monitors(), c = AgentIslandController()
        c.showsPanel = false
        c.io = FakeIO().io
        c.store = AgentIslandStore(geometry: notched)
        c.store?.sessions = [session("s", .idle)]
        c.monitorClicks = { _ in m.installed += 1; return "monitor-\(m.installed)" }
        c.removeMonitor = { m.removed.append($0 as? String ?? "?") }
        c.setExpanded(true)
        XCTAssertEqual(m.installed, 1)
        XCTAssertNotNil(c.outsideClick)
        c.setExpanded(true)
        XCTAssertEqual(m.installed, 1, "already expanded: no second monitor")
        c.setExpanded(false)
        XCTAssertEqual(m.removed, ["monitor-1"])
        XCTAssertNil(c.outsideClick)
        c.setExpanded(true)
        c.reload()   // extLive is false: teardown removes the live monitor
        XCTAssertEqual(m.removed, ["monitor-1", "monitor-2"])
        XCTAssertNil(c.outsideClick)
    }

    // MARK: - Scanner and procargs (#477 L2)

    func testScannerReadsTheDirOnlyWhenItsMtimeMoves() throws {
        final class Count: @unchecked Sendable { var n = 0 }
        let dir = tempDir(), reads = Count(), fm = FileManager.default
        touch(dir, "s.sock")
        touch(dir, "s.sock.act", mtime: 100)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: dir.path)
        let scanner = AgentDirScanner(readDir: { reads.n += 1; return (try? fm.contentsOfDirectory(atPath: $0)) ?? [] })
        let key = AgentSessionKey(dir: dir.path, name: "s")
        XCTAssertEqual(scanner.scan([dir.path])[key]?.act, 100)
        XCTAssertEqual(reads.n, 1)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)],
                             ofItemAtPath: dir.appendingPathComponent("s.sock.act").path)
        XCTAssertEqual(scanner.scan([dir.path])[key]?.act, 200, "a sidecar is stat'd every tick")
        XCTAssertEqual(reads.n, 1, "the dir mtime held: no readdir")
        touch(dir, "t.sock")
        XCTAssertEqual(Set(scanner.scan([dir.path]).keys.map(\.name)), ["s", "t"])
        XCTAssertEqual(reads.n, 2, "a new entry moved the dir mtime")
        _ = scanner.scan([dir.path])
        XCTAssertEqual(reads.n, 2)
    }

    func testParseProcArgsOnTruncatedBuffersNeverTraps() {
        func words(_ argc: Int32, _ rest: String) -> [UInt8] {
            withUnsafeBytes(of: argc) { Array($0) } + Array(rest.utf8)
        }
        XCTAssertEqual(AgentIsland.parseProcArgs([]), [], "zero length")
        XCTAssertEqual(AgentIsland.parseProcArgs([3, 0, 0]), [], "shorter than the argc word")
        XCTAssertEqual(AgentIsland.parseProcArgs(words(3, "")), [], "argc alone")
        XCTAssertEqual(AgentIsland.parseProcArgs(words(3, "/opt/bin/dch")), [], "exec path with no terminator")
        XCTAssertEqual(AgentIsland.parseProcArgs(words(3, "/opt/bin/dch\0\0\0")), [], "padding, then nothing")
        XCTAssertEqual(AgentIsland.parseProcArgs(words(3, "/opt/bin/dch\0\0dch\0-n")), ["dch", "-n"],
                       "fewer args than argc, the last one unterminated")
        XCTAssertEqual(AgentIsland.parseProcArgs(words(.max, "/x\0a\0")), ["a"], "a huge argc stops at the end")
        XCTAssertEqual(AgentIsland.parseProcArgs(words(-1, "/x\0a\0")), [], "a negative argc is no argv")
    }

    func testShowSessionsPaneObservesTheIsolationPreferenceKey() {
        let was = Preferences.isolateRemoteSessions
        defer { Preferences.isolateRemoteSessions = was }
        Preferences.isolateRemoteSessions = !was
        XCTAssertEqual(Preferences.defaults.bool(forKey: AgentIslandPane.isolateKey), !was)
    }

    /// #486 B8: the picker reads the app's store, not .standard (the xctest domain here).
    @MainActor func testShowSessionsPaneReadsThePreferencesStore() {
        let was = Preferences.isolateRemoteSessions
        defer { Preferences.isolateRemoteSessions = was }
        let standard = UserDefaults.standard.bool(forKey: AgentIslandPane.isolateKey)
        Preferences.isolateRemoteSessions = !standard
        let isolate = AgentIslandPane().isolate
        XCTAssertEqual(isolate, !standard)
    }

    // MARK: - dch call timeout (#477)

    /// A dch call that never returns on its own: only killing its pid releases it.
    private final class Wedge: @unchecked Sendable {
        let lock = NSLock(), released = DispatchSemaphore(value: 0), timeout: TimeInterval
        var killed: [pid_t] = [], args: [[String]] = []
        init(timeout: TimeInterval) { self.timeout = timeout }
        func terminate(_ pid: pid_t) { lock.withLock { killed.append(pid) }; released.signal() }
        var io: AgentPromptIO {
            AgentPromptIO.live { args, _ in
                self.lock.withLock { self.args.append(args) }
                return DchCommand.bounded(self.timeout, terminate: self.terminate) { onPid in
                    onPid(4242)
                    self.released.wait()
                    return Data("late".utf8)
                } ?? Data()
            }
        }
    }

    @MainActor func testWedgedDchReadTimesOutKillsTheChildByPidAndLeavesMainFree() {
        let w = Wedge(timeout: 2), (c, s) = cardController(FakeIO())
        c.io = w.io
        let start = Date()
        c.refreshCards()   // the read wedges on the island queue for 2 s
        let hop = expectation(description: "main turns while the queue is stuck")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 1)
        XCTAssertTrue(w.lock.withLock { w.killed.isEmpty }, "main turned before the timeout")
        drain(c)
        XCTAssertEqual(w.lock.withLock { w.killed }, [4242], "killed by its recorded pid")
        XCTAssertEqual(c.store?.cards[s.key], AgentPrompt.card(screen: ""), "a timed-out read is an empty screen")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    @MainActor func testWedgedDchAnswerTimesOutAsChangedAndFreesTheSession() throws {
        let w = Wedge(timeout: 0.3), (c, s) = cardController(FakeIO())
        c.io = w.io
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bashScreen))
        c.answer(s, p, p.options[0])
        drain(c)
        XCTAssertEqual(w.lock.withLock { w.args }, [["--read", "s"]], "the guard read timed out: no status, no send")
        XCTAssertEqual(c.store?.cards[s.key], .changed)
        c.answer(s, p, p.options[0])   // no longer in flight
        drain(c)
        XCTAssertEqual(w.lock.withLock { w.args.count }, 2)
    }

    func testBoundedCallReturnsTheOutputAndNeverKillsAFinishedChild() {
        let out = DchCommand.bounded(5, terminate: { _ in XCTFail("finished in time") }) { onPid in
            onPid(4242)
            return Data("ok".utf8)
        }
        XCTAssertEqual(out, Data("ok".utf8))
    }

    /// The default terminate is a real SIGKILL to the pid the body reported. 2 s
    /// leaves Process.run() room under load (#486: 0.3 s passed at 0.33 s).
    func testBoundedCallKillsARealChildByItsPid() throws {
        final class Child: @unchecked Sendable { let lock = NSLock(); var p: Process? }
        let child = Child(), start = Date()
        let out = DchCommand.bounded(2) { onPid in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["30"]
            guard (try? p.run()) != nil else { return Data("no child".utf8) }
            child.lock.withLock { child.p = p }
            onPid(p.processIdentifier)
            p.waitUntilExit()
            return Data("late".utf8)
        }
        XCTAssertTrue(out == nil, "timed out")
        let p = try XCTUnwrap(child.lock.withLock { child.p })
        p.waitUntilExit()
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        XCTAssertEqual(p.terminationStatus, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "killed, not slept out (30 s)")
    }

    // MARK: - Production routing into the bound (#486)

    /// Every dch call runs `dch` (a script that sleeps 10 s) with the island timeout
    /// at 0.3 s; both restored at teardown. Never a real dch, even under a mutant
    /// that skips runIsland: the seam is the executable itself.
    private func wedgedDch() throws {
        let dir = tempDir(), script = dir.appendingPathComponent("dch").path
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let timeout = DchCommand.islandTimeout
        DchCommand.dchPathOverride = script
        DchCommand.islandTimeout = 0.3
        addTeardownBlock { DchCommand.dchPathOverride = nil; DchCommand.islandTimeout = timeout }
    }

    /// B11.
    func testIslandTimeoutIsFourSeconds() {
        XCTAssertEqual(DchCommand.islandTimeout, 4)
    }

    /// B9: list's default runner is bounded, and a timed-out dir keeps its last sessions.
    func testListDefaultRunnerIsBoundedAndKeepsTheLastSessions() throws {
        try wedgedDch()
        let dir = tempDir(), start = Date()
        let last = [session("s", .blocked, dir: dir.path), session("t", .idle, dir: "/other")]
        XCTAssertEqual(AgentIsland.list(dirs: [dir.path], keeping: last), [last[0]],
                       "--ls-json and -lj both timed out: this dir's last rows stand")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "two 0.3 s bounds, not two 10 s sleeps")
    }

    /// B9b: the prompt IO the controller uses by default is bounded too.
    func testLivePromptIOIsBounded() throws {
        try wedgedDch()
        let start = Date()
        XCTAssertEqual(AgentPromptIO.live.read(AgentSessionKey(dir: tempDir().path, name: "s")), "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "one 0.3 s bound, not a 10 s sleep")
    }

    /// B14: the production launcher reports the real child pid, the one bounded kills.
    func testRunCapturingBothReportsTheChildPid() {
        DchCommand.dchPathOverride = "/bin/sh"
        defer { DchCommand.dchPathOverride = nil }
        var reported: [pid_t] = []
        let r = DchCommand.runCapturingBoth(args: ["-c", "echo $$"], env: [:], onPid: { reported.append($0) })
        let printed = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(reported.map(String.init), [printed])
    }

    /// #486 item 2: a timed-out list keeps the island up; dch answering "none" clears it.
    func testTimedOutListKeepsTheSessionsButAnEmptyAnswerClearsThem() {
        final class Dch: @unchecked Sendable { var out: Data?; var calls = 0 }
        let dir = tempDir(), f = Fake(), dch = Dch()
        touch(dir, "s.sock")
        dch.out = Data(#"[{"name":"s","alias":"","activity_epoch":1,"state":"blocked","agents":0}]"#.utf8)
        let p = AgentIslandPoller(now: { f.now }, dirs: { [dir.path] }, list: {
            AgentIsland.list(dirs: $0, keeping: $1) { _, _ in dch.calls += 1; return dch.out }
        })
        XCTAssertEqual(p.tick()?.map(\.state), [.blocked])
        dch.out = nil
        f.now += AgentPollGate.backstop
        XCTAssertNil(p.tick(), "both calls timed out: no change, the blocked row stays")
        XCTAssertEqual(dch.calls, 3, "it did list: --ls-json, then --ls-json and -lj")
        dch.out = Data()
        f.now += AgentPollGate.backstop
        XCTAssertEqual(p.tick(), [], "dch answered with no rows: gone")
        XCTAssertEqual(dch.calls, 5)
    }

    /// #486 r2: --ls-json timing out is not the -lj answer; the -lj rows replace the kept ones.
    func testListJSONTimeoutFallsBackToTheLJRows() {
        let last = [session("s", .blocked, dir: "/d")]
        let rows = AgentIsland.list(dirs: ["/d"], keeping: last) { args, _ in
            args == ["-lj"] ? Data("t\tT\t5\n".utf8) : nil
        }
        XCTAssertEqual(rows, [AgentSession(key: AgentSessionKey(dir: "/d", name: "t"), alias: "T", activity: 5,
                                           state: .idle, agents: 0)])
    }

    // MARK: - Session meta (#506)

    private func pr(_ repo: String, _ num: Int, url: String? = nil, title: String = "") -> DchSessionMeta.PR {
        .init(url: url ?? "https://github.com/\(repo)/pull/\(num)", repo: repo, num: num, title: title)
    }

    func testListCarriesMetaIntoTheSession() {
        let json = #"[{"name":"x","state":"working","meta":{"prs":{"open":[],"merged":4}}},{"name":"y","state":"idle"}]"#
        let rows = AgentIsland.list(dirs: ["/d"]) { _, _ in Data(json.utf8) }
        XCTAssertEqual(rows.map(\.meta), [DchSessionMeta(merged: 4), nil])
    }

    func testMetaSummary() {
        XCTAssertEqual(AgentIsland.metaSummary(DchSessionMeta(
            tasks: .init(done: 22, total: 26, inProgress: 2, queued: 2), merged: 18)),
            "22/26 done · 2 in progress · 2 queued")
        XCTAssertEqual(AgentIsland.mergedLabel(DchSessionMeta(merged: 18)), "18 merged")
        XCTAssertNil(AgentIsland.mergedLabel(DchSessionMeta(merged: 0)))
        XCTAssertNil(AgentIsland.metaSummary(DchSessionMeta(merged: 18)), "merged is the title line's")
        XCTAssertEqual(AgentIsland.metaSummary(DchSessionMeta(tasks: .init(done: 485, total: 503, inProgress: 5,
                                                                           queued: 13), merged: 0)),
                       "485/503 done · 5 in progress · 13 queued")
        XCTAssertNil(AgentIsland.metaSummary(nil))
        XCTAssertNil(AgentIsland.metaSummary(DchSessionMeta(tasks: .init(done: 0, total: 0, inProgress: 0, queued: 0),
                                                            merged: 0)), "all zero: the row looks as before")
        let s = session("s", .working, activity: 100, alias: "T")
        var m = s; m.meta = DchSessionMeta(tasks: .init(done: 1, total: 2), openPRs: [pr("o/r", 12)], merged: 3)
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(s, now: 112), "T, Working, 12s ago", "no meta: unchanged")
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(m, now: 112),
                       "T, Working, 12s ago, 1/2 done, 3 merged, open pull requests o/r#12", "#525: owner kept here")
        m.meta = DchSessionMeta(openPRs: (1...5).map { pr("o/r", $0) })
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(m, now: 112),
                       "T, Working, 12s ago, open pull requests o/r#1, o/r#2, o/r#3 and 2 more pending PRs", "QA #347 L-e")
        m.meta = DchSessionMeta(openPRs: (1...4).map { pr("o/r", $0) })
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(m, now: 112),
                       "T, Working, 12s ago, open pull requests o/r#1, o/r#2, o/r#3 and 1 more pending PR")
    }

    /// QA #347 L-d: every drawn count caps at "99999+"; done > total stays as drawn.
    func testCountsCapAt99999() {
        XCTAssertEqual([99_999, 100_000, Int.max].map(AgentIsland.count), ["99999", "99999+", "99999+"])
        func summary(done: Int = 1, total: Int = 2, inProgress: Int = 3, queued: Int = 4) -> String? {
            AgentIsland.metaSummary(DchSessionMeta(tasks: .init(done: done, total: total, inProgress: inProgress,
                                                                queued: queued)))
        }
        XCTAssertEqual(summary(done: 100_000), "99999+/2 done · 3 in progress · 4 queued", "done")
        XCTAssertEqual(summary(total: 100_000), "1/99999+ done · 3 in progress · 4 queued", "total")
        XCTAssertEqual(summary(inProgress: 100_000), "1/2 done · 99999+ in progress · 4 queued", "in progress")
        XCTAssertEqual(summary(queued: 100_000), "1/2 done · 3 in progress · 99999+ queued", "queued")
        XCTAssertEqual(summary(done: 7, total: 3), "7/3 done · 3 in progress · 4 queued", "done > total as is")
        XCTAssertEqual(AgentIsland.mergedLabel(DchSessionMeta(merged: 100_000)), "99999+ merged")
        var s = session("s", .working, activity: 100, alias: "T")
        s.meta = DchSessionMeta(tasks: .init(done: Int.max, total: Int.max), merged: Int.max)
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(s, now: 112),
                       "T, Working, 12s ago, 99999+/99999+ done, 99999+ merged")
        // Layout: an Int.max merged label still leaves the chips their room.
        let three = (1...3).map { pr("o/r", $0) }
        XCTAssertEqual(AgentIsland.prChips(DchSessionMeta(openPRs: three, merged: Int.max)).chips.count, 3)
    }

    /// The width of `chips` plus a "+M pending PRs" chip and the merged count,
    /// as the PR line lays them out.
    private func lineWidth(_ meta: DchSessionMeta, _ chips: [AgentIsland.PRChip], _ more: Int) -> CGFloat {
        let parts = chips.map { AgentIsland.chipWidth($0.label) } + (more > 0 ? [AgentIsland.chipWidth(AgentIsland.moreLabel(more))] : [])
        let merged = AgentIsland.mergedLabel(meta).map { AgentIsland.chipWidth($0) - 2 * AgentIsland.chipInset + AgentIsland.mergedGap } ?? 0
        return parts.reduce(0, +) + CGFloat(max(parts.count - 1, 0)) * AgentIsland.chipSpacing + merged
    }

    /// QA #347 L-c, #525: the worst case (Int.max merged, 50 long PRs with
    /// 10-digit numbers) still shows one cut chip and measures within the PR
    /// line, "+M pending PRs" and merged count included.
    func testWorstCaseChipLineFitsTheBudget() {
        let meta = DchSessionMeta(openPRs: (1...50).map { pr("o/\(String(repeating: "a", count: 100))", 1_234_567_890 + $0) },
                                  merged: Int.max)
        let (chips, more) = AgentIsland.prChips(meta)
        XCTAssertEqual(chips.map(\.label), [String(repeating: "a", count: AgentIsland.maxRepoChars - 1) + "…#1234567891"],
                       "one chip, its repo cut at maxRepoChars")
        XCTAssertEqual(more, 49)
        XCTAssertLessThanOrEqual(lineWidth(meta, chips, more), AgentIsland.prChipBudget)
        XCTAssertEqual(AgentIsland.prChipBudget, AgentIslandGeometry.rowTextWidth)
        XCTAssertEqual(AgentIslandGeometry.rowTextWidth, CGFloat(392), "480 - 2 * 21 list inset - 8 - 14 - 10 - 14")
    }

    /// #525: the operator's preview, and 1, 2, 3 chips then the overflow chip.
    func testPRLineChipsAtTheLineBudget() {
        func labels(_ prs: [DchSessionMeta.PR], merged: Int? = nil) -> ([String], Int) {
            let r = AgentIsland.prChips(DchSessionMeta(openPRs: prs, merged: merged))
            return (r.chips.map(\.label), r.more)
        }
        let cde = pr("payhawk/cde-codebase", 370), sol = pr("payhawk/solution", 20399)
        let ads = pr("payhawk/account-data-service", 13509)
        XCTAssertEqual(labels([cde]).0, ["cde-codebase#370"], "owner dropped")
        XCTAssertEqual(labels([cde, sol], merged: 66).0, ["cde-codebase#370", "solution#20399"])
        XCTAssertEqual(labels([ads, sol], merged: 63).0, ["account-data-service#13509", "solution#20399"],
                       "perf-1: both fit, the long repo uncut")
        XCTAssertEqual(labels([cde, sol, pr("o/r", 1)], merged: 66).0, ["cde-codebase#370", "solution#20399", "r#1"])
        let sec = labels([cde, sol, pr("o/r", 1), pr("o/s", 2)], merged: 66)
        XCTAssertEqual(sec.0, ["cde-codebase#370", "solution#20399"], "sec-1: a third chip and +1 do not fit")
        XCTAssertEqual(sec.1, 2)
        let wide = labels([cde, sol, ads], merged: 99_999)
        XCTAssertEqual(wide.0, ["cde-codebase#370", "solution#20399"], "three wide chips do not fit")
        XCTAssertEqual(wide.1, 1)
        let four = labels((1...4).map { pr("o/r", $0) }, merged: 66)
        XCTAssertEqual(four.0, ["r#1", "r#2", "r#3"], "the cap is 3 chips")
        XCTAssertEqual(four.1, 1)
        let ten = labels((1...10).map { pr("o/r", $0) })
        XCTAssertEqual(ten.0, ["r#1", "r#2", "r#3"])
        XCTAssertEqual(ten.1, 7)
        XCTAssertEqual(AgentIsland.moreLabel(1), "+1 pending PR")
        XCTAssertEqual(AgentIsland.moreLabel(2), "+2 pending PRs")
        XCTAssertEqual(AgentIsland.moreLabel(49), "+49 pending PRs")
    }

    /// #525: a long repo stays whole while it fits; cut with "…" only when the
    /// chips cannot otherwise fit, more chips before uncut names.
    func testLongReposAreCutOnlyWhenTheChipsDoNotFitOtherwise() {
        let long = String(repeating: "r", count: 40)
        let one = AgentIsland.prChips(DchSessionMeta(openPRs: [pr("o/\(long)", 1)]))
        XCTAssertEqual(one.chips.map(\.label), ["\(long)#1"], "one long chip fits whole")
        let meta = DchSessionMeta(openPRs: (1...3).map { pr("o/\(long)", $0) })
        let (chips, more) = AgentIsland.prChips(meta)
        let cut = String(repeating: "r", count: AgentIsland.maxRepoChars - 1) + "…"
        XCTAssertEqual(chips.map(\.label), ["\(cut)#1", "\(cut)#2"], "two cut chips beat one whole one")
        XCTAssertEqual(more, 1)
        XCTAssertLessThanOrEqual(lineWidth(meta, chips, more), AgentIsland.prChipBudget)
        XCTAssertEqual(chips.map(\.fullName), ["o/\(long)#1", "o/\(long)#2"])
        XCTAssertEqual(chips.first?.help, "o/\(long)#1", "no title: the full name alone")
        let titled = AgentIsland.prChips(DchSessionMeta(openPRs: [pr("payhawk/solution", 7, title: "Fix it")])).chips
        XCTAssertEqual(titled.first?.help, "payhawk/solution#7 — Fix it")
        // At exactly the cap a repo is never cut.
        let capped = String(repeating: "c", count: AgentIsland.maxRepoChars)
        let atCap = AgentIsland.prChips(DchSessionMeta(openPRs: (1...3).map { pr("o/\(capped)", 1_000_000_000 + $0) }))
        XCTAssertFalse(atCap.chips.isEmpty)
        XCTAssertTrue(atCap.chips.allSatisfy { $0.label.hasPrefix(capped + "#") }, "\(atCap.chips.map(\.label))")
        let none = AgentIsland.prChips(meta, budget: 0)
        XCTAssertEqual(none.chips, [])
        XCTAssertEqual(none.more, 3, "nothing fits: only the overflow chip")
    }

    func testPRChipsCapWithPlusMAndFitTheBudget() {
        let many = DchSessionMeta(openPRs: (1...10).map { pr("o/r", $0) })
        let (chips, more) = AgentIsland.prChips(many)
        XCTAssertEqual(chips.map(\.label), ["r#1", "r#2", "r#3"])
        XCTAssertEqual(more, 7)
        XCTAssertEqual(AgentIsland.prChips(DchSessionMeta(openPRs: [pr("o/r", 1)])).more, 0)
        XCTAssertEqual(AgentIsland.prChips(nil).chips, [])
        // The merged count takes its width and gap out of the chips' budget.
        let three = AgentIsland.prChips(many).chips
        let tight = AgentIsland.chipWidth("r#1") + AgentIsland.chipSpacing + AgentIsland.chipWidth(AgentIsland.moreLabel(9))
        XCTAssertEqual(AgentIsland.prChips(many, budget: tight).chips.count, 1)
        let mergedMeta = DchSessionMeta(openPRs: many.openPRs, merged: 999_999_999)
        let merged = AgentIsland.prChips(mergedMeta, budget: tight + AgentIsland.chipWidth("99999+ merged") - 2 * AgentIsland.chipInset + AgentIsland.mergedGap)
        XCTAssertEqual(merged.chips.count, 1, "budget less merged and gap is exactly one chip")
        XCTAssertEqual(AgentIsland.prChips(mergedMeta, budget: tight).chips.count, 0)
        let short = tight + AgentIsland.chipWidth("99999+ merged") - 2 * AgentIsland.chipInset + AgentIsland.mergedGap - 0.5
        XCTAssertEqual(AgentIsland.prChips(mergedMeta, budget: short).chips.count, 0, "the full gap, not a chip spacing")
        XCTAssertEqual(merged.chips.count + merged.more, 10)
        XCTAssertEqual(three.count, 3)

        // Long names and numbers: fewer chips, all measured inside the budget with the "+M".
        let wide = DchSessionMeta(openPRs: (1...50).map { pr("o/a-very-long-repository-name-\($0)", 123_456_780 + $0) })
        let w = AgentIsland.prChips(wide)
        XCTAssertLessThan(w.chips.count, AgentIsland.maxPRChips)
        XCTAssertEqual(w.chips.count + w.more, 50)
        XCTAssertEqual(w.chips.first?.label.hasPrefix("a-very-long-"), true)
        XCTAssertLessThanOrEqual(lineWidth(wide, w.chips, w.more), AgentIsland.prChipBudget)
        XCTAssertEqual(AgentIsland.prChips(wide, budget: 0).chips, [], "nothing fits: only the +M")

        let titled = AgentIsland.prChips(DchSessionMeta(openPRs: [pr("o/r", 1, title: String(repeating: "x", count: 500))]))
        XCTAssertEqual(titled.chips.first?.title.count, AgentIsland.maxTitleChars)
    }

    /// QA #347 Q1: the k-loop counts the "+M" chip. One point short of 3 chips
    /// plus "+1 pending PR": without that term 3 chips would draw past the budget.
    func testPRChipsCountThePlusMChipWidth() {
        let four = DchSessionMeta(openPRs: (1...4).map { pr("o/r", $0) })
        let three = (1...3).reduce(0) { $0 + AgentIsland.chipWidth("r#\($1)") } + 2 * AgentIsland.chipSpacing
        let budget = three + AgentIsland.chipSpacing + AgentIsland.chipWidth(AgentIsland.moreLabel(1)) - 1
        let r = AgentIsland.prChips(four, budget: budget)
        XCTAssertEqual(r.chips.map(\.label), ["r#1", "r#2"], "two chips and +2 fit, three and +1 do not")
        XCTAssertEqual(r.more, 2)
        XCTAssertLessThanOrEqual(lineWidth(four, r.chips, r.more), budget)
    }

    /// QA #363 a: the cut pass leaves a repo of exactly `maxRepoChars` whole
    /// (`>`, not `>=`), even when the cut pass is the one that fits.
    func testCutPassLeavesARepoAtTheCapWhole() {
        let c18 = String(repeating: "c", count: AgentIsland.maxRepoChars)
        let meta = DchSessionMeta(openPRs: [pr("o/" + c18, 1), pr("o/" + String(repeating: "a", count: 30), 2),
                                            pr("o/" + String(repeating: "b", count: 30), 3)])
        let chips = AgentIsland.prChips(meta).chips
        XCTAssertEqual(chips.first?.label, c18 + "#1")
        XCTAssertEqual(chips.dropFirst().first?.label, String(repeating: "a", count: AgentIsland.maxRepoChars - 1) + "…#2",
                       "the cut pass is the one that fit")
    }

    @MainActor
    func testPRClickOpensOnlyAnAllowlistedURLThroughTheSeam() {
        var opened: [URL] = []
        let saved = AgentIsland.openURL
        AgentIsland.openURL = { opened.append($0) }
        defer { AgentIsland.openURL = saved }
        let meta = DchSessionMeta(openPRs: [
            pr("o/r", 12),
            pr("o/r", 13, url: "https://github.com.evil.com/o/r/pull/13"),
            pr("o/r", 14, url: "http://github.com/o/r/pull/14"),
        ])
        let chips = AgentIsland.prChips(meta).chips
        XCTAssertEqual(chips.map(\.label), ["r#12", "r#13", "r#14"], "a rejected URL still shows, as a label")
        XCTAssertEqual(chips.map { $0.url != nil }, [true, false, false])
        // #522: owner over 39 characters.
        let long = AgentIsland.prChips(DchSessionMeta(openPRs: [pr("o/r", 15, url: "https://github.com/\(String(repeating: "o", count: 40))/r/pull/15")])).chips
        XCTAssertEqual(long.map(\.label), ["r#15"])
        XCTAssertNil(long.first?.url, "an over-long owner is a label, never opened")
        chips.forEach(AgentIsland.open)
        XCTAssertEqual(opened, [URL(string: "https://github.com/o/r/pull/12")!])
        AgentIsland.open(AgentIsland.PRChip(label: "x#1", title: "", url: nil))
        XCTAssertEqual(opened.count, 1, "a label chip opens nothing")
    }

    /// QA #347 L-f: unstubbed, the default seam opens nothing under XCTest.
    @MainActor
    func testDefaultOpenURLOpensNothingUnderXCTest() {
        var reached: [URL] = []
        let saved = AgentIsland.workspaceOpen
        AgentIsland.workspaceOpen = { reached.append($0); return true }
        defer { AgentIsland.workspaceOpen = saved }
        AgentIsland.open(AgentIsland.PRChip(label: "r#12", title: "", url: URL(string: "https://github.com/o/r/pull/12")))
        XCTAssertEqual(reached, [])
    }

    /// QA I1: `dch --meta` writes only .sock.meta; the stamp must see it or PRs
    /// and tasks wait for the 10 s backstop.
    func testMetaSidecarAloneTriggersAFetch() {
        let dir = tempDir(), f = Fake()
        touch(dir, "s.sock")
        touch(dir, "s.sock.act", mtime: 9_000)
        touch(dir, "s.sock.meta", mtime: 9_000)
        let p = poller([dir.path], f)
        _ = p.tick(); f.now += 2; _ = p.tick()
        f.now += 5; _ = p.tick()
        XCTAssertEqual(f.calls.count, 2)
        touch(dir, "s.sock.meta", mtime: 10_007)
        f.now += 1; _ = p.tick()
        XCTAssertEqual(f.calls.count, 3, ".meta only")
        XCTAssertEqual(AgentDirScanner().scan([dir.path])[AgentSessionKey(dir: dir.path, name: "s")]?.meta, 10_007)
    }

    // MARK: - Geometry

    /// 14" MacBook Pro: 1512 x 982, notch 185 x 32 between two auxiliary areas.
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    func testNotchedScreenGeometry() {
        XCTAssertEqual(notched.notchWidth, 185)
        XCTAssertEqual(notched.barHeight, 32)
        XCTAssertEqual(notched.frame(notched.collapsedSize), CGRect(x: 632, y: 950, width: 249, height: 32),
                       "notch plus two 32 pt ears, centred, flush with the top")
        XCTAssertEqual(notched.frame(notched.expandedSize(rows: 3)),
                       CGRect(x: 516, y: 982 - (32 + 4 + 144 + 12), width: 480, height: 32 + 4 + 144 + 12))
        XCTAssertEqual(notched.expandedSize(rows: 20), notched.expandedSize(rows: 6), "scrolls after 6 rows")
    }

    func testNotchlessScreenGeometry() {
        let g = AgentIslandGeometry.make(
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415), topLeft: nil, topRight: nil, safeTop: 0)
        XCTAssertEqual(g.notchWidth, 0)
        XCTAssertEqual(g.barHeight, 25, "inside the menu bar")
        XCTAssertEqual(g.frame(g.collapsedSize), CGRect(x: 1512 + 1280 - 25, y: 1415, width: 50, height: 25))
        XCTAssertEqual(g.frame(g.expandedSize(rows: 1)).width, 480)
        XCTAssertEqual(g.frame(g.expandedSize(rows: 1)).midX, 1512 + 1280)
        let hidden = AgentIslandGeometry.make(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                              visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                              topLeft: nil, topRight: nil, safeTop: 0)
        XCTAssertEqual(hidden.barHeight, 24, "auto-hidden menu bar")
        XCTAssertEqual(hidden.expandedSize(rows: 1).width, 480)
    }

    /// #525: two lines without PR meta, three with a PR line.
    func testRowHeightsPerRow() {
        var s = session("s", .working)
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: .all), 48, "no meta: two lines, as before")
        s.meta = DchSessionMeta(tasks: .init(done: 1, total: 2))
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: .all), 48, "tasks ride on line 2")
        s.meta = DchSessionMeta(openPRs: [.init(url: "x", repo: "o/r", num: nil, title: "")])
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: .all), 48, "a PR with no label draws nothing")
        s.meta = DchSessionMeta(merged: 0)
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: .all), 48)
        s.meta = DchSessionMeta(merged: 3)
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: .all), AgentIslandGeometry.prRowHeight, "merged alone")
        s.meta = DchSessionMeta(openPRs: [pr("o/r", 1)])
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: .all), AgentIslandGeometry.prRowHeight, "one open PR")
        XCTAssertEqual(AgentIslandGeometry.prRowHeight, 64)
    }

    /// QA #363 b: a whole AgentIslandRow, laid out offscreen (ImageRenderer, no
    /// window), is 48 pt without a PR line and 64 pt with one, as the model says.
    @MainActor
    func testWholeRowMeasures48Or64Offscreen() throws {
        var s = session("s", .working, activity: 100, alias: "a title", agents: 2)
        let cases: [(DchSessionMeta?, AgentIslandRowDetails, CGFloat)] = [
            (nil, .all, 48), (DchSessionMeta(openPRs: [pr("o/r", 1)], merged: 3), .all, 64),
            (DchSessionMeta(merged: 3), .all, 64),
            (DchSessionMeta(openPRs: [pr("o/r", 1)], merged: 3), AgentIslandRowDetails(openPRs: false, merged: false), 48)]
        for (meta, show, want) in cases {
            s.meta = meta
            XCTAssertEqual(AgentIslandGeometry.height(of: s, show: show), want)
            let r = ImageRenderer(content: AgentIslandRow(session: s, now: 112, notice: nil, show: show) {}
                .frame(width: AgentIslandGeometry.rowTextWidth + 60))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage)
            XCTAssertEqual(CGFloat(cg.height), want, "\(String(describing: meta)) \(show)")
        }
    }

    /// QA #370 F6: a preview one row over the cap draws that row in the marker's
    /// place (11 rows as 11), and two or more over end in "… N more lines". Context
    /// keeps the 10-row cap (OQ-46: an 11th row is deny-only) and says "… 1 more
    /// line". The card height counts what is drawn.
    func testOneRowOverTheCapReadsAsOneRow() throws {
        let cap = AgentPrompt.maxContext
        let eleven = (1...cap + 1).map { "line \($0)" }, twelve = (1...cap + 2).map { "line \($0)" }
        XCTAssertEqual(AgentCardLayout.previewRows(eleven).rows, eleven)
        XCTAssertEqual(AgentCardLayout.previewRows(twelve).rows, Array(twelve.prefix(cap)) + ["… 2 more lines"])
        XCTAssertEqual(AgentCardLayout.contextRows(eleven).rows, Array(eleven.prefix(cap)) + ["… 1 more line"])
        XCTAssertTrue(AgentCardLayout.contextRows(eleven).overCap)
        XCTAssertEqual(AgentCardLayout.contextRows(twelve).rows, Array(twelve.prefix(cap)) + ["… 2 more lines"])
        // 8 + (11 rows * 14 + 8 + 6) + 26 jump + 8 + 4: 11 rows drawn either way.
        let h: CGFloat = 8 + (CGFloat(cap + 1) * 14 + 8 + 6) + 26 + 8 + 4
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.context(eleven)), h)
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.context(twelve)), h)
        // A preview card counts its rows as drawn: 11 preview rows add 11 lines.
        let p = AgentPrompt(question: "Q?", context: [], options: [AgentPromptOption(digit: 1, label: "Yes", hint: nil)])
        var ten = p, more = p
        ten.preview = Array(eleven.prefix(cap))
        more.preview = eleven
        XCTAssertEqual(more.layout.preview, eleven)
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(more)) - AgentIslandGeometry.cardHeight(.prompt(ten)),
                       more.layout.previewLine, "one more preview line, no marker")
    }

    /// #525: the list sums per-row heights; 6 rows show, then it scrolls, and
    /// a short screen scrolls on the summed height.
    @MainActor
    func testListHeightSumsMixedRows() {
        let g = notched, two = AgentIslandGeometry.rowHeight, three = AgentIslandGeometry.prRowHeight
        XCTAssertEqual(g.listHeight(rows: [two, three, two]), 2 * two + three)
        XCTAssertEqual(g.listHeight(rows: []), two, "empty: one row's room")
        XCTAssertEqual(g.listHeight(rows: [three, three], cards: 100), 2 * three + 100)
        let seven = [three, two, three, two, three, two, three]
        XCTAssertEqual(g.listHeight(rows: seven), 3 * three + 3 * two, "the first 6 rows")
        XCTAssertTrue(g.listScrolls(rows: seven))
        XCTAssertFalse(g.listScrolls(rows: Array(seven.prefix(6))))
        XCTAssertEqual(g.listHeight(rows: 3), g.listHeight(rows: [two, two, two]), "Int: two-line rows")
        XCTAssertEqual(g.expandedSize(rows: [three]).height, g.expandedSize(rows: 1).height + three - two)
        // 800 x 300, hidden bar: maxListHeight = 300 - 24 - 4 - 12 - 40 = 220.
        let short = AgentIslandGeometry.make(frame: CGRect(x: 0, y: 0, width: 800, height: 300),
                                             visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 300),
                                             topLeft: nil, topRight: nil, safeTop: 0)
        XCTAssertEqual(short.maxListHeight, 220)
        XCTAssertFalse(short.listScrolls(rows: [three, three, three]), "192")
        XCTAssertFalse(short.listScrolls(rows: 4), "4 two-line rows: 192")
        XCTAssertTrue(short.listScrolls(rows: [three, three, three, two]), "240 > 220")
        XCTAssertEqual(short.listHeight(rows: [three, three, three, two]), 220, "capped")
        XCTAssertEqual(short.listHeight(rows: [three, three, three]), 192)
        // The store hands the view and the panel the per-row heights.
        let store = AgentIslandStore(geometry: g)
        var a = session("a", .working), b = session("b", .idle)
        a.meta = DchSessionMeta(merged: 2)
        b.meta = DchSessionMeta(tasks: .init(done: 1, total: 2))
        store.sessions = [a, b]
        store.expanded = true
        XCTAssertEqual(store.rowHeights, [three, two])
        XCTAssertEqual(store.size, g.expandedSize(rows: [three, two]))
        XCTAssertEqual(store.size.height, 32 + 4 + three + two + 12)
    }

    /// #525: the PR line as SwiftUI lays it out (chips, overflow chip, the gap
    /// and the merged count at their ideal widths) fits the text column for the
    /// preview rows and the worst case, so the right-aligned merged count is never
    /// clipped.
    @MainActor
    func testPRLineLaysOutInsideTheTextColumn() {
        let big = Int.max
        let metas = [
            DchSessionMeta(openPRs: [pr("payhawk/cde-codebase", 370), pr("payhawk/solution", 20399),
                                     pr("o/r", 1), pr("o/s", 2)], merged: 66),
            DchSessionMeta(openPRs: [pr("payhawk/account-data-service", 13509), pr("payhawk/solution", 20399)], merged: 63),
            DchSessionMeta(openPRs: (1...50).map { pr("o/\(String(repeating: "a", count: 100))", 1_234_567_890 + $0) }, merged: big),
            DchSessionMeta(openPRs: (1...50).map { pr("o/r", 1_234_567_890 + $0) }, merged: big),
            DchSessionMeta(openPRs: (1...3).map { pr("o/\(String(repeating: "r", count: 40))", $0) }, merged: 99_999),
            DchSessionMeta(merged: big),
        ]
        for meta in metas {
            var s = session("s", .working); s.meta = meta
            let row = AgentIslandRow(session: s, now: 0, notice: nil) {}
            let host = NSHostingView(rootView: row.prLineView(AgentIsland.prChips(meta)).fixedSize())
            let w = host.fittingSize.width
            XCTAssertGreaterThan(w, 0)
            XCTAssertLessThanOrEqual(w, AgentIslandGeometry.rowTextWidth, "\(AgentIsland.prChips(meta).chips.map(\.label))")
            let model = lineWidth(meta, AgentIsland.prChips(meta).chips, AgentIsland.prChips(meta).more)
            XCTAssertLessThanOrEqual(w, model + 0.01, "SwiftUI never draws wider than the model measured")
            XCTAssertLessThanOrEqual(model - w, 4, "the model is SwiftUI's width, rounded up per text")
        }
    }

    // MARK: - Render (visual evidence, no window)

    @MainActor
    func testRendersCollapsedAndExpandedOffscreen() throws {
        let now = Date().timeIntervalSince1970
        let store = AgentIslandStore(geometry: notched)
        store.sessions = AgentIsland.sorted([
            session("fix-auth", .blocked, activity: now - 12, alias: "fix auth bug"),
            session("prosper-ios", .working, activity: now - 240, agents: 3),
            session("dobby-main", .working, activity: now - 30, alias: "refactor the ledger export so every round renders"),
            session("payhawk-apps", .done, activity: now - 7200, alias: "ship release notes"),
            session("infra-stats-main-3", .idle, activity: now - 3 * 86400),
        ])
        // #525: the operator's preview rows, sec-1 and perf-1.
        var sec = session("sec-branch-name", .working, activity: now, alias: "sec-1", agents: 3)
        sec.meta = DchSessionMeta(tasks: .init(done: 39, total: 64, inProgress: 3, queued: 22),
                                  openPRs: [pr("payhawk/cde-codebase", 370), pr("payhawk/solution", 20399),
                                            pr("o/r", 1), pr("o/s", 2)], merged: 66)
        var perf = session("solution-master-perf", .idle, activity: now - 15, alias: "perf-1")
        perf.meta = DchSessionMeta(tasks: .init(done: 74, total: 81, inProgress: 2, queued: 5),
                                   openPRs: [pr("payhawk/account-data-service", 13509), pr("payhawk/solution", 20399)],
                                   merged: 63)
        store.sessions[1] = sec
        store.sessions[2] = perf
        XCTAssertEqual(store.rowHeights.filter { $0 == AgentIslandGeometry.prRowHeight }.count, 2)
        store.notices[AgentSessionKey(dir: "/d", name: "payhawk-apps")] = "Attach command copied"
        let out = tempDir()
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        for (name, expanded) in [("agent-island-collapsed", false), ("agent-island-expanded", true)] {
            store.expanded = expanded
            let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
            r.scale = 2
            let cg = try XCTUnwrap(r.cgImage, name)
            XCTAssertEqual(CGFloat(cg.width), (store.size.width + 40) * 2, name)
            XCTAssertEqual(CGFloat(cg.height), (store.size.height + 40) * 2, name)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name).png"))
            if let extra { try png.write(to: extra.appendingPathComponent("\(name).png")) }
        }
    }

    /// #506 (c): rows with PR chips and task counts, worst cases included, stay
    /// inside the island at every audited UI scale. The island's sizes are fixed
    /// (nothing follows ThemeRuntime.scale), so every scale renders the same
    /// bitmap (to the rasterizer's ±1 antialiasing noise); and left and right of the rows' inset nothing but the shape's black
    /// or the backdrop is ever drawn, so no row overflows its width.
    @MainActor
    func testMetaRowsStayInsideTheIslandAtEveryScale() throws {
        let now = Date().timeIntervalSince1970, old = now - 50 * 86400
        func m(_ prs: [DchSessionMeta.PR], tasks: DchSessionMeta.Tasks? = nil, merged: Int? = nil) -> DchSessionMeta {
            DchSessionMeta(tasks: tasks, openPRs: prs, merged: merged)
        }
        let big = Int.max
        var rows = [
            session("prosper-main", .working, activity: old, alias: "prosper", agents: 2),
            session("sec-1", .blocked, activity: old, alias: "a very long session title that has to truncate somewhere", agents: 12),
            session("solution-master", .done, activity: old),
            session("dobby-main", .idle, activity: old, alias: "dobby"),
            session("plain", .idle, activity: old, alias: "no meta, as before"),
        ]
        rows[0].meta = m([pr("o/prosper", 12, title: "Fix the thing"), pr("o/prosper", 13)],
                         tasks: .init(done: 22, total: 26, inProgress: 2, queued: 2), merged: 18)
        rows[1].meta = m((1...50).map { pr("o/a-very-long-repository-name", 123_456_780 + $0) },
                         tasks: .init(done: big, total: big, inProgress: big, queued: big), merged: big)
        rows[2].meta = m([pr("payhawk/solution", 12794), pr("o/r", 7, url: "http://evil.example/o/r/pull/7"),
                          pr("o/s", 8), pr("o/t", 9)], tasks: .init(done: 485, total: 503, inProgress: 5, queued: 13))
        rows[3].meta = m([], merged: 3)
        let store = AgentIslandStore(geometry: notched)
        store.sessions = rows
        store.expanded = true
        let out = tempDir()
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        var pixels: [CGFloat: [UInt8]] = [:]
        func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= 2 }
        for scale: CGFloat in [0.7, 0.85, 1.0, 1.25] {
            ThemeRuntime.scale = scale
            let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
            r.scale = 2
            let cg = try XCTUnwrap(r.cgImage)
            let rep = NSBitmapImageRep(cgImage: cg)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            pixels[scale] = Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * rep.pixelsHigh))
            try png.write(to: out.appendingPathComponent("agent-island-meta-\(scale).png"))
            if let extra { try png.write(to: extra.appendingPathComponent("agent-island-meta-\(scale).png")) }
            // Rows area, in pixels: below the header, above the bottom corners.
            let g = notched, px = 2.0, pad = 20.0
            let top = Int((pad + g.barHeight + AgentIslandGeometry.listTop) * px)
            let bottom = Int((pad + store.size.height - AgentIslandGeometry.openRadii.bottom) * px)
            let band = Int((pad + AgentIslandGeometry.listInset) * px)
            var bg = [Int](repeating: 0, count: 4)
            rep.getPixel(&bg, atX: 0, y: 0)
            var stray = 0
            for y in top..<bottom {
                for x in Array(0..<band) + Array((rep.pixelsWide - band)..<rep.pixelsWide) {
                    var p = [Int](repeating: 0, count: 4)
                    rep.getPixel(&p, atX: x, y: y)
                    if !zip(p, bg).allSatisfy(near) && p.prefix(3).contains(where: { $0 > 2 }) { stray += 1 }
                }
            }
            XCTAssertEqual(stray, 0, "scale \(scale): row pixels outside the rows' inset")
        }
        let base = try XCTUnwrap(pixels[1.0])
        for (scale, px) in pixels {
            XCTAssertTrue(px.count == base.count && zip(px, base).allSatisfy { near(Int($0), Int($1)) },
                          "scale \(scale): the island does not follow the UI scale")
        }
    }

    // MARK: - Row details (#534)

    private static let rowDetailKeys = ["agentIslandShowAgents", "agentIslandShowOpenPRs", "agentIslandShowMerged",
                                        "agentIslandShowTasksDone", "agentIslandShowInProgress", "agentIslandShowQueued"]

    /// Clears the six keys in the scratch Preferences domain for one test and
    /// puts back whatever was there.
    private func clearRowDetailKeys() {
        let saved = Self.rowDetailKeys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(Self.rowDetailKeys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        Self.rowDetailKeys.forEach(Preferences.defaults.removeObject(forKey:))
    }

    /// The defaults match prosper-ios #533: Agents, Open PRs, Merged on; Tasks
    /// done, In progress, Queued off. Per Mac: no key syncs.
    func testRowDetailDefaultsAndKeysAreNotSynced() {
        clearRowDetailKeys()
        let d = Preferences.agentIslandRowDetails
        XCTAssertTrue(d.agents, "Agents on")
        XCTAssertTrue(d.openPRs, "Open PRs on")
        XCTAssertTrue(d.merged, "Merged on")
        XCTAssertFalse(d.tasksDone, "Tasks done off")
        XCTAssertFalse(d.inProgress, "In progress off")
        XCTAssertFalse(d.queued, "Queued off")
        XCTAssertEqual(d, AgentIslandRowDetails())
        for k in Self.rowDetailKeys { XCTAssertFalse(SyncedKeys.isSynced(k), "\(k): per Mac") }
        // A set writes only what changed, so the other five keep following the default.
        var on = d; on.tasksDone = true
        Preferences.agentIslandRowDetails = on
        XCTAssertEqual(Preferences.agentIslandRowDetails, on)
        XCTAssertEqual(Self.rowDetailKeys.filter { Preferences.defaults.object(forKey: $0) != nil },
                       ["agentIslandShowTasksDone"])
        Preferences.agentIslandRowDetails = .all
        XCTAssertEqual(Preferences.agentIslandRowDetails, .all)
        Preferences.agentIslandRowDetails = AgentIslandRowDetails(agents: false, openPRs: false, merged: false)
        XCTAssertEqual(Preferences.agentIslandRowDetails,
                       AgentIslandRowDetails(agents: false, openPRs: false, merged: false))
    }

    /// Line 2's summary drops each part toggled off; nothing left is nil.
    func testMetaSummaryHonoursRowDetails() {
        let m = DchSessionMeta(tasks: .init(done: 22, total: 26, inProgress: 2, queued: 3), merged: 18)
        func with(_ f: (inout AgentIslandRowDetails) -> Void) -> String? {
            var d = AgentIslandRowDetails.all; f(&d); return AgentIsland.metaSummary(m, show: d)
        }
        XCTAssertNil(AgentIsland.metaSummary(m, show: AgentIslandRowDetails()), "defaults: no task summary")
        XCTAssertEqual(AgentIsland.metaSummary(m, show: .all), "22/26 done · 2 in progress · 3 queued")
        XCTAssertNil(AgentIsland.metaSummary(m, show: AgentIslandRowDetails(agents: false, openPRs: false, merged: false)),
                     "all off")
        XCTAssertEqual(with { $0.tasksDone = false }, "2 in progress · 3 queued")
        XCTAssertEqual(with { $0.inProgress = false }, "22/26 done · 3 queued")
        XCTAssertEqual(with { $0.queued = false }, "22/26 done · 2 in progress")
        XCTAssertEqual(with { $0.tasksDone = false; $0.queued = false }, "2 in progress")
        XCTAssertEqual(with { $0.inProgress = false; $0.queued = false }, "22/26 done")
        XCTAssertEqual(with { $0.tasksDone = false; $0.inProgress = false }, "3 queued")
        XCTAssertNil(with { $0.tasksDone = false; $0.inProgress = false; $0.queued = false }, "the other three are not line 2's")
        let zeroQueued = DchSessionMeta(tasks: .init(done: 1, total: 2, inProgress: 0, queued: 0))
        XCTAssertNil(AgentIsland.metaSummary(zeroQueued, show: AgentIslandRowDetails(tasksDone: false, inProgress: true, queued: true)),
                     "on but zero: still nothing")
    }

    /// The PR line and the row height follow Open PRs and Merged; the store,
    /// listHeight and expandedSize agree with the drawn row.
    @MainActor
    func testPRLineAndRowHeightHonourRowDetails() {
        let two = AgentIslandGeometry.rowHeight, three = AgentIslandGeometry.prRowHeight
        let both = DchSessionMeta(openPRs: [pr("o/r", 1)], merged: 4)
        let prsOnly = DchSessionMeta(openPRs: [pr("o/r", 1)])
        let mergedOnly = DchSessionMeta(merged: 4)
        let noPRs = AgentIslandRowDetails(openPRs: false), noMerged = AgentIslandRowDetails(merged: false)
        let neither = AgentIslandRowDetails(openPRs: false, merged: false)
        XCTAssertTrue(AgentIsland.hasPRLine(both, show: noPRs), "merged still draws the line")
        XCTAssertFalse(AgentIsland.hasPRLine(prsOnly, show: noPRs), "Open PRs off: no line")
        XCTAssertEqual(AgentIsland.prChips(both, show: noPRs).chips, [])
        XCTAssertEqual(AgentIsland.prChips(DchSessionMeta(openPRs: (1...9).map { pr("o/r", $0) }), show: noPRs).more, 0,
                       "no +N pending PRs either")
        XCTAssertEqual(AgentIsland.mergedLabel(both, show: noPRs), "4 merged", "only N merged left")
        XCTAssertTrue(AgentIsland.hasPRLine(both, show: noMerged))
        XCTAssertFalse(AgentIsland.hasPRLine(mergedOnly, show: noMerged), "Merged off: no line")
        XCTAssertNil(AgentIsland.mergedLabel(both, show: noMerged))
        XCTAssertFalse(AgentIsland.hasPRLine(both, show: neither), "both off")
        var s = session("s", .working)
        s.meta = both
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: .all), three)
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: neither), two, "both off: 48 again")
        s.meta = prsOnly
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: noPRs), two)
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: noMerged), three)
        s.meta = mergedOnly
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: noMerged), two)
        XCTAssertEqual(AgentIslandGeometry.height(of: s, show: noPRs), three)
        // The store's rows and size follow `details`.
        let g = notched
        var a = session("a", .working), b = session("b", .idle)
        a.meta = both; b.meta = prsOnly
        let store = AgentIslandStore(geometry: g)
        store.sessions = [a, b]
        store.expanded = true
        XCTAssertEqual(store.details, .all, "a store built without details shows everything")
        XCTAssertEqual(store.rowHeights, [three, three])
        store.details = noPRs
        XCTAssertEqual(store.rowHeights, [three, two])
        XCTAssertEqual(store.size, g.expandedSize(rows: [three, two]))
        store.details = neither
        XCTAssertEqual(store.rowHeights, [two, two])
        XCTAssertEqual(store.size, g.expandedSize(rows: 2))
        XCTAssertEqual(store.size.height, 32 + 4 + 2 * two + 12)
    }

    /// Merged off gives the chips the whole budget.
    func testPRChipsGetTheFullBudgetWithMergedOff() {
        let many = DchSessionMeta(openPRs: (1...10).map { pr("o/r", $0) }, merged: 999_999_999)
        let tight = AgentIsland.chipWidth("r#1") + AgentIsland.chipSpacing + AgentIsland.chipWidth(AgentIsland.moreLabel(9))
        XCTAssertEqual(AgentIsland.prChips(many, show: .all, budget: tight).chips.count, 0, "merged takes its room")
        XCTAssertEqual(AgentIsland.prChips(many, show: AgentIslandRowDetails(merged: false), budget: tight).chips.map(\.label),
                       ["r#1"], "Merged off: the full budget")
        let full = AgentIsland.prChips(DchSessionMeta(openPRs: many.openPRs), budget: tight)
        XCTAssertEqual(AgentIsland.prChips(many, show: AgentIslandRowDetails(merged: false), budget: tight).chips, full.chips)
    }

    /// The row's accessibility label reads what the row draws.
    func testRowAccessibilityLabelHonoursRowDetails() {
        var s = session("s", .working, activity: 100, alias: "T", agents: 2)
        s.meta = DchSessionMeta(tasks: .init(done: 1, total: 2, inProgress: 3, queued: 4), openPRs: [pr("o/r", 12)], merged: 3)
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(s, now: 112, show: .all),
                       "T, Working, 12s ago, 1/2 done · 3 in progress · 4 queued, 3 merged, open pull requests o/r#12")
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(s, now: 112, show: AgentIslandRowDetails()),
                       "T, Working, 12s ago, 3 merged, open pull requests o/r#12", "defaults")
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(s, now: 112, show: AgentIslandRowDetails(openPRs: false, queued: true)),
                       "T, Working, 12s ago, 4 queued, 3 merged")
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(s, now: 112, show: AgentIslandRowDetails(merged: false)),
                       "T, Working, 12s ago, open pull requests o/r#12")
    }

    /// A Settings toggle reaches the open island at once: the controller reads
    /// Preferences into the store and resizes (here: the store's size; no panel).
    @MainActor
    func testRowDetailsChangedRedrawsTheOpenIsland() {
        clearRowDetailKeys()
        let c = AgentIslandController()
        c.showsPanel = false
        c.rowDetailsChanged()   // no store yet: nothing to do
        XCTAssertNil(c.store)
        c.store = AgentIslandStore(geometry: notched)
        var s = session("s", .working)
        s.meta = DchSessionMeta(tasks: .init(done: 1, total: 2), openPRs: [pr("o/r", 1)], merged: 2)
        c.store?.sessions = [s]
        c.store?.expanded = true
        let before = c.store?.size
        Preferences.agentIslandRowDetails = AgentIslandRowDetails(openPRs: false, merged: false)
        c.rowDetailsChanged()
        XCTAssertEqual(c.store?.details, AgentIslandRowDetails(openPRs: false, merged: false))
        XCTAssertEqual(c.store?.rowHeights, [AgentIslandGeometry.rowHeight])
        XCTAssertEqual(c.store.map { $0.size.height }, before.map { $0.height - (AgentIslandGeometry.prRowHeight - AgentIslandGeometry.rowHeight) })
    }

    /// Visual evidence: the island with the default row details and with all on,
    /// at UI scale 0.7, 0.85 and 1.0, and the Settings section at the same scales.
    /// Offscreen only (ImageRenderer, a windowless hosting view).
    @MainActor
    func testRendersRowDetailsOffscreen() throws {
        let now = Date().timeIntervalSince1970
        var sec = session("sec-branch-name", .working, activity: now - 5, alias: "sec-1", agents: 3)
        sec.meta = DchSessionMeta(tasks: .init(done: 22, total: 26, inProgress: 2, queued: 2),
                                  openPRs: [pr("payhawk/cde-codebase", 370), pr("payhawk/solution", 20399)], merged: 18)
        var perf = session("solution-master-perf", .idle, activity: now - 900, alias: "perf-1")
        perf.meta = DchSessionMeta(tasks: .init(done: 74, total: 81, inProgress: 2, queued: 5), merged: 63)
        var plain = session("prosper-main", .done, activity: now - 7200, agents: 1)
        plain.meta = DchSessionMeta(tasks: .init(done: 3, total: 9, inProgress: 1, queued: 0))
        let store = AgentIslandStore(geometry: notched)
        store.sessions = [sec, perf, plain]
        store.expanded = true
        let out = tempDir()
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        func write(_ png: Data, _ name: String) throws {
            try png.write(to: out.appendingPathComponent("\(name).png"))
            if let extra { try png.write(to: extra.appendingPathComponent("\(name).png")) }
        }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            for (name, d) in [("defaults", AgentIslandRowDetails()), ("all", AgentIslandRowDetails.all)] {
                store.details = d
                let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
                r.scale = 2
                let cg = try XCTUnwrap(r.cgImage)
                XCTAssertEqual(CGFloat(cg.height), (store.size.height + 40) * 2, "\(name) \(scale): drawn = sized")
                try write(try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])),
                          "agent-island-row-details-\(name)-\(scale)")
            }
            let width = sz(560)
            let h = NSHostingView(rootView: AgentIslandRowDetailsSection().frame(width: width).padding(sz(16))
                .background(Color(white: 0.1)).preferredColorScheme(.dark))
            h.frame = CGRect(origin: .zero, size: CGSize(width: width + 2 * sz(16), height: 10))
            h.frame.size = h.fittingSize
            h.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            h.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(h.bounds.height, 6 * sz(20), "scale \(scale): six toggle rows laid out")
            let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
            h.cacheDisplay(in: h.bounds, to: rep)
            try write(try XCTUnwrap(rep.representation(using: .png, properties: [:])), "settings-row-details-\(scale)")
        }
        XCTAssertEqual(store.details, .all)
        store.details = AgentIslandRowDetails()
        XCTAssertEqual(store.rowHeights, [AgentIslandGeometry.prRowHeight, AgentIslandGeometry.prRowHeight, AgentIslandGeometry.rowHeight])
    }
}
