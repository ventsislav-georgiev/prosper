import XCTest
@testable import ProsperApp

/// #914 (#871 P2b-2, spec 3.6 and 6.1): new Agent Sessions start through the pool when the person turned it on.
/// Every row goes through a fake runner that records the env handed to --spawn: no process is spawned, no dch,
/// claude or headroom runs, and no port is bound or dialled (the proxy status is injected as a literal).
@MainActor
final class CCPoolSessionRoutingTests: XCTestCase {
    private static let folder = "/Users/example/api"

    /// What `controlEnv` hands the spawn path here: a PATH, the socket dir, a Claude Code identity (spawnEnv
    /// strips it today), two credentials and a base URL of the person's own.
    nonisolated private static func controlEnv(_ dir: String) -> [String: String] {
        ["PATH": "/Users/example/bin:/usr/bin", "DCH_SOCKET_DIR": dir, "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
         "ANTHROPIC_API_KEY": "example-key", "ANTHROPIC_AUTH_TOKEN": "example-auth", "ANTHROPIC_BASE_URL": "http://example.invalid"]
    }

    /// The env every --spawn got before P2b-2 (spawnEnv over controlEnv), literally: the env when routing does not apply.
    private let today = ["PATH": "/Users/example/bin:/usr/bin", "DCH_SOCKET_DIR": "/d", "ANTHROPIC_API_KEY": "example-key",
                         "ANTHROPIC_AUTH_TOKEN": "example-auth", "ANTHROPIC_BASE_URL": "http://example.invalid"]
    /// claude routed: the credentials stripped, the base URL the pool's.
    private let routedClaude = ["PATH": "/Users/example/bin:/usr/bin", "DCH_SOCKET_DIR": "/d",
                                "ANTHROPIC_BASE_URL": "http://127.0.0.1:41234"]

    private var geometry: AgentIslandGeometry {
        AgentIslandGeometry.make(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
            safeTop: 32)
    }

    /// The fake --spawn runner: records each launch's argv and env (the runner calls the env closure on its own
    /// global queue, as in production) and ends at once with status 0.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _args: [[String]] = []
        private var _envs: [[String: String]] = []
        let launched = DispatchSemaphore(value: 0)

        var args: [[String]] { lock.withLock { _args } }
        var envs: [[String: String]] { lock.withLock { _envs } }

        func runner() -> DchActionRunner {
            DchActionRunner(bound: 60, launch: { _, args, env, _, onPid, _ in
                self.lock.withLock { self._args.append(args); self._envs.append(env) }
                onPid(4242)
                self.launched.signal()
                return (0, Data())
            }, signal: { _ in })
        }
    }

    /// The pool as the spawn reads it, with every read counted: values change between spawns.
    private final class Pool: @unchecked Sendable {
        private let lock = NSLock()
        private var _on = true, _status = CCPoolService.Status.running(port: 41234), _accounts = true
        private var _statusReads = 0, _mainReads = 0

        var statusReads: Int { lock.withLock { _statusReads } }
        /// Reads made on the main thread (the hint's); a spawn's reads are the runner queue's.
        var mainReads: Int { lock.withLock { _mainReads } }

        func set(on: Bool? = nil, status: CCPoolService.Status? = nil, accounts: Bool? = nil) {
            lock.withLock {
                if let on { _on = on }
                if let status { _status = status }
                if let accounts { _accounts = accounts }
            }
        }

        private func read<T>(_ isStatus: Bool = false, _ get: (Pool) -> T) -> T {
            lock.withLock {
                if Thread.isMainThread { _mainReads += 1 }
                if isStatus { _statusReads += 1 }
                return get(self)
            }
        }

        var routing: CCPool.Routing {
            CCPool.Routing(on: { self.read { $0._on } }, status: { self.read(true) { $0._status } },
                           hasAccounts: { self.read { $0._accounts } })
        }
    }

    /// A panel-less island whose control binary, history and runner are fakes; `routing` nil keeps the default
    /// contributors (no ccpool runtime under XCTest).
    private func controller(_ rec: Recorder, routing: CCPool.Routing?) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        c.controlDch = { nil }
        c.readHistory = { _, _ in [] }
        c.historyDirs = { ["/d"] }
        c.controlEnv = { Self.controlEnv($0) }
        c.runner = rec.runner()
        c.store = AgentIslandStore(geometry: geometry)
        c.store?.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 24, 1])
        if let routing { c.sessionEnvContributors = { [routing.contributor] } }
        return c
    }

    private func settle(until done: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// One spawn through the island's one --spawn path (the window form's call); the env the runner was handed.
    private func spawnedEnv(_ c: AgentIslandController, _ rec: Recorder, _ command: [String], name: String,
                            file: StaticString = #filePath, line: UInt = #line) -> [String: String]? {
        let before = rec.envs.count
        guard let key = c.spawn(in: Self.folder, command: command, name: name) else {
            XCTFail("the spawn was refused", file: file, line: line)
            return nil
        }
        XCTAssertEqual(rec.launched.wait(timeout: .now() + 5), .success, file: file, line: line)
        settle { !c.runner.isBusy(key) }
        let envs = rec.envs
        XCTAssertEqual(envs.count, before + 1, "one launch", file: file, line: line)
        return envs.last
    }

    private func runtime() -> CCPoolRuntime {
        let dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let defaults: UserDefaults = XCTestDefaults(suiteName: "prosper-ccpool-routing-\(UUID().uuidString)")!
        XCTAssertTrue(defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        return CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                             vaultURL: dir.appendingPathComponent("old"), defaults: defaults, probeBase: cfg.upstream,
                             logger: CCPoolCapturingLogger())
    }

    // MARK: - Applies

    /// The window form's spawn: claude gets the pool's base URL and loses the credentials; headroom is never routed (#1200).
    func testCCPoolSpawnRoutesClaudeAndNeverHeadroomAtTheRecorder() {
        let rec = Recorder(), pool = Pool()
        let c = controller(rec, routing: pool.routing)
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api"), routedClaude)
        XCTAssertEqual(spawnedEnv(c, rec, ["/opt/homebrew/bin/claude", "--chrome"], name: "api-2"), routedClaude)
        XCTAssertEqual(spawnedEnv(c, rec, ["/opt/homebrew/bin/headroom", "wrap", "claude"], name: "api-qa"), today,
                       "headroom is never routed: environment equal to the input")
        XCTAssertEqual(rec.args.last, ["--spawn", "api-qa", "--", "/opt/homebrew/bin/headroom", "wrap", "claude", "--name", "api-qa"],
                       "the argv is untouched: only the env changes")
        XCTAssertEqual(pool.mainReads, 0, "the spawn reads the pool on the runner's queue, never main")
    }

    /// The island's own New session (no name, the stored command) goes through the same seam.
    func testCCPoolIslandNewSessionRoutesThroughTheSameSeam() {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let rec = Recorder(), pool = Pool()
        let c = controller(rec, routing: pool.routing)
        Preferences.agentIslandNewSessionCommand = "claude"
        defer { Preferences.agentIslandNewSessionCommand = "" }
        c.newSession(in: Self.folder)
        XCTAssertEqual(rec.launched.wait(timeout: .now() + 5), .success)
        let name = rec.args.last.flatMap { $0.count > 1 ? $0[1] : nil } ?? ""
        settle { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: name)) }
        XCTAssertEqual(rec.args.last?.first, "--spawn")
        XCTAssertEqual(rec.envs.last, routedClaude)
    }

    // MARK: - Does not apply: the env is exactly today's

    func testCCPoolSpawnEnvIsTodaysWhenRoutingDoesNotApply() {
        XCTAssertEqual(AgentIsland.spawnEnv(Self.controlEnv("/d")), today, "today's env, literally")
        let rec = Recorder(), pool = Pool()
        let c = controller(rec, routing: pool.routing)
        var n = 0
        func check(_ why: String, _ command: [String], line: UInt = #line) {
            n += 1
            XCTAssertEqual(spawnedEnv(c, rec, command, name: "api-\(n)", line: line), today, why, line: line)
        }
        check("a shell (the quick shell)", ["/bin/zsh", "-l"])
        check("a wrapper: argv[0] is direnv", ["direnv", "exec", ".", "claude"])
        check("another program", ["/usr/bin/vim"])
        pool.set(on: false)
        check("toggle off", ["claude"])
        check("toggle off, headroom", ["headroom", "wrap", "claude"])
        pool.set(on: true, status: .stopped)
        check("proxy stopped", ["claude"])
        pool.set(status: .heldByCCPool(pid: 4242))
        check("the port held by another ccpool", ["claude"])
        pool.set(status: .heldByOther)
        check("the port held by another program", ["claude"])
        pool.set(status: .failed("the port could not be bound"))
        check("proxy failed", ["claude"])
        pool.set(status: .running(port: 41234), accounts: false)
        check("no accounts", ["claude"])
        XCTAssertEqual(pool.mainReads, 0)

        // No ccpool runtime (the extension never went live; always so under XCTest): no contributor at all.
        let bare = Recorder()
        let d = controller(bare, routing: nil)
        XCTAssertTrue(d.sessionEnvContributors().isEmpty, "no runtime: no contributor")
        XCTAssertEqual(spawnedEnv(d, bare, ["claude"], name: "api"), today)
    }

    /// Turning the toggle off holds for the next spawn, and decides it before any status or account read.
    func testCCPoolToggleOffHoldsForTheNextSpawnWithoutAStatusRead() {
        let rt = runtime(), pool = Pool()
        let routing = CCPool.Routing(on: rt.routing.on, status: pool.routing.status, hasAccounts: pool.routing.hasAccounts)
        let rec = Recorder()
        let c = controller(rec, routing: routing)
        XCTAssertFalse(rt.model.routeAgentSessions, "off by default")
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api"), today, "default off")
        XCTAssertEqual(pool.statusReads, 0, "off: the status is never read")
        rt.model.routeAgentSessions = true
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api-2"), routedClaude, "on: routed")
        XCTAssertEqual(pool.statusReads, 1)
        rt.model.routeAgentSessions = false
        pool.set(status: .failed("the listener stopped after it started"))
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api-3"), today, "off again: the next spawn is today's")
        XCTAssertEqual(pool.statusReads, 1, "the off decision needed no status read")
    }

    // MARK: - Isolation

    /// The contributors are asked on main and run on a real background queue: none of them is main-actor
    /// isolated (the runtime's toggle reader is formed in @MainActor init).
    func testCCPoolContributorsRunOnABackgroundQueue() {
        let rt = runtime(), pool = Pool()
        rt.model.routeAgentSessions = true
        let c = controller(Recorder(), routing: nil)
        c.sessionEnvContributors = { [rt.routing.contributor, pool.routing.contributor] }
        let contributors = c.sessionEnvContributors(), runtimeRouting = rt.routing
        final class Out: @unchecked Sendable {
            var env: [String: String] = [:]
            var on = false
            var onMain = true
        }
        let out = Out(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            out.on = runtimeRouting.on()
            out.env = AgentIslandController.spawnEnv(Self.controlEnv("/d"), argv: ["claude"], contributors)
            out.onMain = Thread.isMainThread
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(out.onMain)
        XCTAssertTrue(out.on, "the runtime's toggle reader answered off main")
        XCTAssertEqual(out.env, routedClaude, "the runtime's proxy is stopped (no change), the injected pool routes")
        XCTAssertEqual(pool.mainReads, 0)
    }

    // MARK: - The form's hint

    /// One routing value feeds both the "via ccpool" hint and the spawn env: they agree on every row.
    func testCCPoolHintAndSpawnEnvComeFromOneRule() {
        let rec = Recorder(), pool = Pool()
        let c = controller(rec, routing: pool.routing)
        let claude = AgentNewSession.argv("claude --chrome", shell: "/bin/zsh")
        let headroom = AgentNewSession.argv("headroom wrap claude", shell: "/bin/zsh")
        let shell = AgentNewSession.argv("", shell: "/bin/zsh")
        XCTAssertEqual(AgentNewSession.viaPoolHint, "via ccpool")

        XCTAssertEqual(AgentNewSession.poolHint(claude, routing: pool.routing), "via ccpool")
        XCTAssertEqual(spawnedEnv(c, rec, claude, name: "api"), routedClaude)
        XCTAssertTrue(AgentNewSession.poolHint(headroom, routing: pool.routing) == nil, "headroom is never routed: no hint")
        XCTAssertEqual(spawnedEnv(c, rec, headroom, name: "api-2"), today)
        XCTAssertNil(AgentNewSession.poolHint(shell, routing: pool.routing), "an empty command is the login shell")
        XCTAssertEqual(spawnedEnv(c, rec, shell, name: "api-3"), today)

        pool.set(status: .stopped)
        XCTAssertNil(AgentNewSession.poolHint(claude, routing: pool.routing), "proxy stopped: no hint")
        XCTAssertEqual(spawnedEnv(c, rec, claude, name: "api-4"), today)
        pool.set(on: false, status: .running(port: 41234))
        XCTAssertNil(AgentNewSession.poolHint(claude, routing: pool.routing), "toggle off: no hint")
        XCTAssertEqual(spawnedEnv(c, rec, claude, name: "api-5"), today)

        XCTAssertNil(AgentNewSession.poolHint(claude, routing: nil), "no ccpool runtime: no hint")
    }
}
