import AppKit
import XCTest
@testable import ProsperApp

/// #1323 (step 2C): New session on another Mac: a host picker from the remote list, that host's recent folders or a
/// typed absolute path, and `dch --host H --spawn name --cwd <path> -- <command>` on the verb seam (the island's runner).
/// Fakes only: step A's remote list fixture, #1324's History fixture, a recording verb seam and a recording terminal;
/// no dch, no host, no window shown, no chooser.
final class AgentWindowRemoteSpawnTests: XCTestCase {
    typealias Lister = AgentWindowRemoteRowsTests.Lister
    let rows = AgentWindowRemoteRowsTests()
    static let prefs = AgentWindowD1Tests.newSessionPrefs

    final class Calls {
        var verbs: [(key: AgentSessionKey, dch: String, args: [String])] = []
        var done: (@Sendable (DchActionResult) -> Void)?
        var local: [(folder: String, argv: [String], name: String?)] = []
    }

    /// Step A's visible model on the fake list (host-a, host-b), #1324's History fixture, an open gate at `version`,
    /// the verb seam and the island's spawn recorded; the form open.
    @MainActor
    func model(_ lister: Lister = Lister(AgentWindowRemoteRowsTests.fixture),
               history: String = AgentWindowRemoteHistoryTests.fixture, version: [Int] = [1, 74, 0])
        -> (AgentWindowModel, AgentWindowRemoteRowsTests.Log, Calls) {
        let calls = Calls(), hist = Lister(history)
        let (m, store, log) = rows.model(lister, sessions: [])
        store.controlDch = DchCommand.Binary(path: "/opt/example/bin/dch", version: version)
        let island = AgentIslandController()
        island.historyDirs = { ["/tmp/dch-test"] }
        island.chooseFolder = { _ in XCTFail("no chooser here") }
        m.island = { island }
        m.home = "/Users/example"
        m.shell = "/bin/fish"
        m.folderExists = { $0.hasPrefix("/Users/example") }
        m.spawnSession = { folder, argv, name, _ in
            calls.local.append((folder, argv, name))
            return AgentSessionKey(dir: "/tmp/dch-test", name: name ?? "?")
        }
        m.remoteHistoryRun = { args, _ in hist.run(args) }
        m.remoteVerb = { key, dch, args, done in
            calls.verbs.append((key, dch, args))
            calls.done = done
            return true
        }
        log.clock += AgentWindowModel.remoteHistoryEvery
        m.refresh()   // the History fixture in
        m.openNewSessionNamed()
        return (m, log, calls)
    }

    @MainActor
    func withPrefs(_ body: () throws -> Void) rethrows {
        let saved = Self.prefs.map { Preferences.defaults.object(forKey: $0) }
        defer { for (k, v) in zip(Self.prefs, saved) { Preferences.defaults.set(v, forKey: k) } }
        for k in Self.prefs { Preferences.defaults.removeObject(forKey: k) }
        Preferences.agentIslandNewSessionCommand = "make test"
        try body()
    }

    // MARK: 1. the picker

    @MainActor
    func testHostPickerIsHiddenWithNoRemoteHostAndBelowDch141() throws {
        try withPrefs {
            let (none, _, _) = model(Lister("[]"), history: "[]")
            defer { none.close() }
            XCTAssertTrue(none.newSession != nil)
            XCTAssertEqual(none.newSessionHosts, [], "no remote host: no picker")
            let (old, _, _) = model(version: [1, 40, 9])
            defer { old.close() }
            XCTAssertEqual(old.newSessionHosts, [], "dch 1.40: no --host H --spawn name --cwd")
            let (m, _, _) = model(version: [1, 41, 0])
            defer { m.close() }
            XCTAssertEqual(m.newSessionHosts, ["host-a", "host-b"])
            XCTAssertEqual(m.newSessionHostLabel(nil), "This Mac")
        }
    }

    // MARK: 2-3. argv with --cwd, recent folders per host

    @MainActor
    func testRemoteStartRunsSpawnHostNameWithCwdOnTheVerbSeam() throws {
        try withPrefs {
            let (m, _, calls) = model()
            defer { m.close() }
            m.cancelNewSession()
            m.openNewSession()   // unnamed: model() opens the form with openNewSessionNamed, which types a name
            m.setNewSessionHost("host-a")
            m.setNewSessionFolder("/Users/example/site")
            // #1731: picking only a folder derives no name; Start refuses until one is typed.
            XCTAssertEqual(m.newSessionName, "", "a folder alone leaves the name empty (#1731)")
            XCTAssertFalse(m.startNewSession(), "no typed name: Start refuses (#1731)")
            XCTAssertEqual(calls.verbs.count, 0)
            m.setNewSessionName("site")
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(calls.verbs.count, 1)
            XCTAssertEqual(calls.verbs.last?.args,
                           ["--host", "host-a", "--spawn", "site", "--cwd", "/Users/example/site", "--", "make", "test"])
            XCTAssertEqual(calls.verbs.last?.dch, "/opt/example/bin/dch")
            XCTAssertEqual(calls.verbs.last?.key, AgentTerminalSpawn.remoteKey(host: "host-a", name: "site"))
            XCTAssertEqual(calls.local.count, 0, "never the local spawn")
            XCTAssertEqual(m.newSession?.starting, AgentTerminalSpawn.remoteKey(host: "host-a", name: "site"))
            // A name taken on that host is refused by the same check.
            let (n, _, _) = model()
            defer { n.close() }
            n.setNewSessionHost("host-a")
            n.setNewSessionName("docs")
            XCTAssertEqual(n.newSessionErrors.name, "docs is taken")
            XCTAssertFalse(n.canStartNewSession)
        }
    }

    /// #1919: an empty Name on another Mac: New shell takes the folder's free name there.
    @MainActor
    func testAnEmptyNameShellOnAnotherMacTakesTheFoldersName() throws {
        try withPrefs {
            let (m, _, calls) = model()
            defer { m.close() }
            m.setNewSessionHost("host-a")
            m.setNewSessionFolder("/Users/example/zzz")
            m.setNewSessionName("")
            XCTAssertTrue(m.startShell())
            XCTAssertEqual(calls.verbs.last?.args.prefix(4).map { $0 }, ["--host", "host-a", "--spawn", "zzz"])
            XCTAssertEqual(calls.local.count, 0)
            // #1922: "docs" is live on host-a, so the folder's name there is skipped to "docs-2".
            let (n, _, c2) = model()
            defer { n.close() }
            n.setNewSessionHost("host-a")
            n.setNewSessionFolder("/Users/example/docs")
            n.setNewSessionName("")
            XCTAssertTrue(n.startShell())
            XCTAssertEqual(c2.verbs.last?.args.prefix(4).map { $0 }, ["--host", "host-a", "--spawn", "docs-2"])
        }
    }

    /// r1: dch keeps `--spawn host-a:site` local when a local session or record has that exact name; --host never does.
    @MainActor
    func testALocalSessionNamedHostColonNameNeverTurnsTheRemoteStartLocal() throws {
        try withPrefs {
            let (m, _, calls) = model()
            defer { m.close() }
            m.store?.sessions = [rows.session("host-a:site")]
            m.store?.history = [DchHistoryRecord(key: AgentSessionKey(dir: AgentWindowRemoteRowsTests.dir, name: "host-a:site"),
                                                 cwd: "/Users/example/site", ended: AgentWindowD1Tests.now - 60, end: "exit 0",
                                                 file: "host-a:site")]
            m.setNewSessionHost("host-a")
            m.setNewSessionFolder("/Users/example/site")
            m.setNewSessionName("site")   // #1731: the name is typed, not derived from the folder
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(calls.verbs.last?.args,
                           ["--host", "host-a", "--spawn", "site", "--cwd", "/Users/example/site", "--", "make", "test"],
                           "--host with the plain name, never host-a:site")
            XCTAssertFalse(calls.verbs.last?.args.contains("host-a:site") ?? true)
            XCTAssertEqual(calls.local.count, 0)
        }
    }

    @MainActor
    func testRecentFoldersArePerHostNewestFirstWithoutDuplicates() throws {
        try withPrefs {
            let (m, _, _) = model()
            defer { m.close() }
            m.setNewSessionHost("host-a")
            XCTAssertEqual(m.newSessionRecents, ["/Users/example/web", "/Users/example/docs", "/Users/example/api"],
                           "the live session's cwd, then History newest first")
            XCTAssertEqual(m.newSession?.folder, "/Users/example/web", "prefilled with the newest")
            m.setNewSessionHost("host-b")
            XCTAssertEqual(m.newSessionRecents, ["/Users/example/build"], "live and History name it once")
            m.setNewSessionHost(nil)
            XCTAssertEqual(m.newSession?.folder, "~", "this Mac: the usual default again")
            let relative = AgentSidebar.Remote(host: "host-a", name: "x", alias: "", stale: false, cwd: "rel/x")
            XCTAssertEqual(AgentNewSession.remoteRecents(host: "host-a", sessions: [relative], history: []), [])
        }
    }

    /// R1323-s1: another Mac's cwd with a bidi control or a zero-width scalar is neither offered nor prefilled raw.
    @MainActor
    func testRemoteFoldersWithOutsideTextScalarsAreNotOfferedOrPrefilled() throws {
        try withPrefs {
            let hist = #"""
            [{"name":"p","alias":"","cwd":"/Users/example/plain","ended":1799990000,"end":"exit 0","file":"p","host":"host-a","stale":false},
             {"name":"b","alias":"","cwd":"/Users/example/a\u202Eb","ended":1799999000,"end":"exit 0","file":"b","host":"host-a","stale":false},
             {"name":"z","alias":"","cwd":"/Users/example/c\u200Bd","ended":1799999500,"end":"exit 0","file":"z","host":"host-a","stale":false}]
            """#
            let lister = Lister(#"[{"name":"api","alias":"","host":"host-a","state":"idle","stale":false,"cwd":null}]"#)
            let (m, _, _) = model(lister, history: hist)
            defer { m.close() }
            m.setNewSessionHost("host-a")
            XCTAssertEqual(m.newSessionRecents, ["/Users/example/plain"], "the two newer outside-text folders are dropped")
            XCTAssertEqual(m.newSession?.folder, "/Users/example/plain")
        }
    }

    // MARK: 2. a relative path

    @MainActor
    func testARelativePathIsRefusedInTheFormAndNothingRuns() throws {
        try withPrefs {
            let (m, _, calls) = model()
            defer { m.close() }
            m.setNewSessionHost("host-a")
            for typed in ["src/app", "~/src", "./x"] {
                m.setNewSessionFolder(typed)
                XCTAssertEqual(m.newSessionErrors.folder,
                               "Type a full path starting with /: a relative path has no folder to start from", typed)
                XCTAssertFalse(m.canStartNewSession)
                XCTAssertFalse(m.startNewSession())
            }
            m.setNewSessionFolder("")
            XCTAssertEqual(m.newSessionErrors.folder, "Type a folder on that Mac")
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(calls.verbs.count, 0)
            m.chooseNewSessionFolder()   // no chooser for another Mac (the island's chooser fails the test)
        }
    }

    // MARK: 4. each failure

    @MainActor
    func testEachFailureShowsItsOwnLineAndTheFormStaysOpen() throws {
        try withPrefs {
            let (m, _, calls) = model()
            defer { m.close() }
            m.setNewSessionHost("host-a")
            m.setNewSessionFolder("/Users/example/site")
            let cases: [(Int32, [String], String)] = [
                (1, ["dch: --cwd: no such directory: /Users/example/site"], "No such folder on host-a"),
                (1, ["dch: host-a: creating sessions is off on this host (dch serve --allow-create)"],
                 "host-a does not allow new sessions: run dch serve --allow-create there"),
                (6, ["dch: host-a: does not support --spawn (needs dch serve --allow-create)"],
                 "host-a does not allow new sessions: run dch serve --allow-create there"),
                (7, ["dch: host-a: unreachable: busy"], "Can't reach host-a"),
            ]
            for (status, text, line) in cases {
                XCTAssertTrue(m.startNewSession(), line)
                calls.done?(DchActionResult(status: status, text: text))
                rows.spin { m.newSession?.starting == nil }
                XCTAssertTrue(m.newSession != nil, "the form stays: \(line)")
                XCTAssertEqual(m.newSessionStatus, line)
            }
            XCTAssertEqual(calls.verbs.count, cases.count)
        }
    }

    // MARK: 4. success

    @MainActor
    func testSuccessSelectsTheNewRemoteRowAndArmsExactlyOneAttach() throws {
        try withPrefs {
            let lister = Lister(AgentWindowRemoteRowsTests.fixture)
            let (m, log, calls) = model(lister)
            defer { m.close() }
            m.setNewSessionHost("host-a")
            m.setNewSessionFolder("/Users/example/site")
            m.setNewSessionName("site")   // #1731: the name is typed, not derived from the folder
            let n = log.spawns.count
            XCTAssertTrue(m.startNewSession())
            calls.done?(DchActionResult(status: 0))
            rows.spin { m.pendingSpawn != nil }
            XCTAssertTrue(m.newSession?.starting != nil, "Starting... until the row lists")
            XCTAssertEqual(log.spawns.count, n)
            let site = #"{"name":"site","alias":"","host":"host-a","state":"idle","stale":false,"cwd":"/Users/example/site"}"#
            lister.answer("[" + site + "," + AgentWindowRemoteRowsTests.fixture.dropFirst())
            log.clock += AgentWindowModel.remoteEvery
            m.refresh()
            XCTAssertEqual(m.selection, .remote(host: "host-a", name: "site"))
            XCTAssertTrue(m.newSession == nil, "the form closed")
            XCTAssertEqual(log.spawns.count, n + 1, "exactly one attach")
            XCTAssertEqual(log.spawns.last?.args, ["-E", "--host", "host-a", "-a", "site", "--scrollback", "2000"])
            log.clock += AgentWindowModel.remoteEvery
            m.refresh()
            XCTAssertEqual(log.spawns.count, n + 1, "the next refresh keeps the one attach")
        }
    }

    // MARK: the local start unchanged

    @MainActor
    func testTheLocalStartIsUnchangedWithRemoteHostsListed() throws {
        try withPrefs {
            let (m, _, calls) = model()
            defer { m.close() }
            XCTAssertEqual(m.newSessionHosts, ["host-a", "host-b"])
            XCTAssertTrue(m.newSession?.host == nil, "This Mac first")
            m.setNewSessionHost("host-b")
            m.setNewSessionHost(nil)
            m.setNewSessionFolder("~/proj")
            m.setNewSessionName("proj")   // #1731: the name is typed, not derived from the folder
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(calls.local.count, 1)
            XCTAssertEqual(calls.local.last?.folder, "/Users/example/proj")
            XCTAssertEqual(calls.local.last?.argv, ["make", "test"])
            XCTAssertEqual(calls.local.last?.name, "proj")
            XCTAssertEqual(calls.verbs.count, 0, "never the remote verb")
        }
    }

    // MARK: display through OutsideText, argv raw

    @MainActor
    func testHostIsShownThroughOutsideTextAndArgvKeepsItRaw() throws {
        try withPrefs {
            let json = #"[{"name":"api","alias":"","host":"host-\u202ea","state":"idle","stale":false,"cwd":"/Users/example/api"}]"#
            let raw = "host-\u{202E}a"
            let (m, _, calls) = model(Lister(json), history: "[]")
            defer { m.close() }
            XCTAssertEqual(m.newSessionHosts, [raw])
            XCTAssertEqual(m.newSessionHostLabel(raw), "host-a", "the picker's label")
            m.setNewSessionHost(raw)
            m.setNewSessionFolder("/Users/example/site")
            m.setNewSessionName("site")   // #1731: the name is typed, not derived from the folder
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(calls.verbs.last?.args.prefix(4), ["--host", raw, "--spawn", "site"], "argv keeps the raw host")
            calls.done?(DchActionResult(status: 7, text: ["dch: " + raw + ": unreachable: down"]))
            rows.spin { m.newSession?.starting == nil }
            XCTAssertEqual(m.newSessionStatus, "Can't reach host-a")
        }
    }
}
