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
        AgentIslandPoller(now: { f.now }, dirs: { dirs }, list: { d in
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
        let t = AgentIslandController.makePollTimer(poller([dir.path], f), queue: DispatchQueue(label: "t", qos: .utility)) {
            XCTAssertEqual($0.map(\.name), ["s"])
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
        c.makePoller = { AgentIslandPoller(dirs: { ticked.fulfill(); return [] }, list: { _ in [] }) }
        defer { c.extLive = false; c.reload(); c.makePoller = { AgentIslandPoller() } }
        c.extLive = true
        c.reload()
        try XCTSkipIf(AgentIslandGeometry.current() == nil, "no screen geometry: reload() starts no timer")
        wait(for: [ticked], timeout: 5)
    }

    // MARK: - Answer lock, card generations, live IO (#475 K2, N9, N4)

    private static let bashScreen = """
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
}
