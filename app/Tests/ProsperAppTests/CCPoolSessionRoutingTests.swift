import Combine
import XCTest
@testable import ProsperApp

/// #914 (#871 P2b-2, spec 3.6 and 6.1): new Agent Sessions start through the pool when the person turned it on.
/// Every row goes through a fake runner that records the env handed to --spawn: no process is spawned, no dch,
/// claude or headroom runs, and no port is bound or dialled (the proxy status is injected as a literal).
@MainActor
final class CCPoolSessionRoutingTests: XCTestCase {
    private static let folder = "/Users/example/api"

    /// What `controlEnv` hands the spawn path here: a PATH, the socket dir, a Claude Code identity (spawnEnv
    /// strips it today) and two credentials. #1890: no base URL of the person's own (one keeps the session unrouted:
    /// the foreign-URL rows below add it).
    nonisolated private static func controlEnv(_ dir: String) -> [String: String] {
        ["PATH": "/Users/example/bin:/usr/bin", "DCH_SOCKET_DIR": dir, "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
         "ANTHROPIC_API_KEY": "example-key", "ANTHROPIC_AUTH_TOKEN": "example-auth"]
    }

    /// The env every --spawn got before P2b-2 (spawnEnv over controlEnv), literally: the env when routing does not apply.
    private let today = ["PATH": "/Users/example/bin:/usr/bin", "DCH_SOCKET_DIR": "/d", "ANTHROPIC_API_KEY": "example-key",
                         "ANTHROPIC_AUTH_TOKEN": "example-auth"]
    /// claude routed (OQ-132): `today` with the pool's base URL; the credentials kept.
    private let routedClaude = ["PATH": "/Users/example/bin:/usr/bin", "DCH_SOCKET_DIR": "/d", "ANTHROPIC_API_KEY": "example-key",
                                "ANTHROPIC_AUTH_TOKEN": "example-auth", "ANTHROPIC_BASE_URL": "http://127.0.0.1:41234"]

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
    private func controller(_ rec: Recorder, routing: CCPool.Routing?, version: [Int] = [1, 24, 1]) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        c.controlDch = { nil }
        c.readHistory = { _, _ in [] }
        c.historyDirs = { ["/d"] }
        c.controlEnv = { Self.controlEnv($0) }
        c.runner = rec.runner()
        c.store = AgentIslandStore(geometry: geometry)
        c.store?.controlDch = DchCommand.Binary(path: "/fake/dch", version: version)
        if let routing {
            c.sessionEnvContributors = { [routing.contributor] }
            c.reviveEnvFlags = { routing.reviveFlags }
            c.reviveCodexFlags = { routing.reviveCodexFlags }
        }
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

    /// #1893: the process env's URL is read only outside XCTest, and a runtime() built here never sees it.
    func testProcessBaseURLIsNotReadUnderXCTest() {
        let env = [CCPool.baseURLKey: "http://127.0.0.1:1234"]
        XCTAssertTrue(CCPool.processBaseURL(env: env, underXCTest: true) == nil)
        XCTAssertEqual(CCPool.processBaseURL(env: env, underXCTest: false), "http://127.0.0.1:1234")
        XCTAssertTrue(CCPool.processBaseURL(env: [:], underXCTest: false) == nil)
        XCTAssertTrue(CCPool.processBaseURL() == nil, "the default under this test process")
        XCTAssertTrue(runtime().model.ownBaseURL() == nil, "runtime() takes the gated value")
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

    /// #2009: the --spawn path runs the argv contributors on the runner's queue: a routed codex gets the pool's `-c` words
    /// right after argv[0] and is counted once; claude's argv is untouched and keeps its env routing; a codex with its own
    /// provider gets nothing.
    func testCCPoolSpawnAddsTheCodexWordsAtTheRecorder() {
        let rec = Recorder(), pool = Pool(), reach = CCPool.CodexReach(now: { 0 })
        var routing = pool.routing
        routing.codexOn = { true }
        routing.hasCodexAccounts = { true }
        routing.reach = reach
        let c = controller(rec, routing: routing)
        c.sessionArgvContributors = { [routing.argvContributor] }
        _ = spawnedEnv(c, rec, ["codex", "--no-daemon"], name: "api")
        XCTAssertEqual(rec.args.last, ["--spawn", "api", "--", "codex"] + CCPool.codexArgs(port: 41234) + ["--no-daemon"])
        XCTAssertEqual(reach.routedCount, 1)
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api-2"), routedClaude)
        XCTAssertEqual(rec.args.last, ["--spawn", "api-2", "--", "claude", "--name", "api-2"], "claude's argv as today")
        _ = spawnedEnv(c, rec, ["codex", "--no-daemon", "-p", "work"], name: "api-qa")
        XCTAssertEqual(rec.args.last, ["--spawn", "api-qa", "--", "codex", "--no-daemon", "-p", "work"], "its own profile: unchanged")
        XCTAssertEqual(reach.routedCount, 1, "only the routed spawn counts")
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
        XCTAssertEqual(d.sessionEnvContributors().count, 1, "no runtime: no pool contributor, only the kit one (empty provider, #917 S7)")
        XCTAssertEqual(spawnedEnv(d, bare, ["claude"], name: "api"), today)
    }

    /// Turning the toggle off holds for the next spawn, and decides it before any status or account read.
    func testCCPoolToggleOffHoldsForTheNextSpawnWithoutAStatusRead() {
        let rt = runtime(), pool = Pool()
        let routing = CCPool.Routing(on: rt.routing.on, status: pool.routing.status, hasAccounts: pool.routing.hasAccounts)
        let rec = Recorder()
        let c = controller(rec, routing: routing)
        XCTAssertTrue(rt.model.routeAgentSessions, "#1890: on by default")
        XCTAssertTrue(rt.routing.on(), "#1890: the spawn's own reader agrees")
        rt.model.routeAgentSessions = false
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api"), today, "stored off")
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

    /// #1205 (a), mutants t1, s1, w1: while the form is open its pool watch (the form view's @StateObject) publishes
    /// on every toggle flip and every proxy start or stop, and its hint reads the new value at once. The proxy is
    /// this row's own runtime on an ephemeral loopback port (port 0). Once the watch is dropped it is gone (no
    /// subscription keeps it), and later flips call nothing and do not crash. No view is shown.
    func testCCPoolFormHintFollowsTheToggleAndTheProxyWhileOpen() async throws {
        final class Count { var n = 0 }
        let rt = runtime()
        let service = rt.service
        addTeardownBlock { service.stop() }
        try rt.store.addAccount(label: "Example Org", token: "tok-example", secrets: rt.secrets)
        let claude = AgentNewSession.argv("claude", shell: "/bin/zsh")
        weak var dropped: AgentNewSessionPoolWatch?
        var redraws: AnyCancellable?
        do {
            let watch = AgentNewSessionPoolWatch(rt)
            dropped = watch
            let count = Count()
            redraws = watch.objectWillChange.sink { count.n += 1 }   // main: every publish here is on main
            XCTAssertTrue(watch.hint(claude) == nil, "on by default (#1890), proxy stopped")

            var before = count.n
            rt.model.routeAgentSessions = true
            XCTAssertGreaterThan(count.n, before, "toggle on: the form redraws")
            XCTAssertTrue(watch.hint(claude) == nil, "on, but the proxy is stopped")

            let start = rt.setLive(true)
            before = count.n
            await start?.value
            guard case .running = rt.service.status else { return XCTFail("live with an account: \(rt.service.status)") }
            XCTAssertGreaterThan(count.n, before, "proxy started: the form redraws")
            XCTAssertEqual(watch.hint(claude), AgentNewSession.viaPoolHint)

            before = count.n
            rt.model.routeAgentSessions = false
            XCTAssertGreaterThan(count.n, before, "toggle off: the form redraws")
            XCTAssertTrue(watch.hint(claude) == nil, "off: no hint")

            before = count.n
            rt.model.routeAgentSessions = true
            XCTAssertGreaterThan(count.n, before, "toggle on again: the form redraws")
            XCTAssertEqual(watch.hint(claude), AgentNewSession.viaPoolHint)

            let stop = rt.setLive(false)
            before = count.n
            await stop?.value
            XCTAssertEqual(rt.service.status, .stopped)
            XCTAssertGreaterThan(count.n, before, "proxy stopped: the form redraws")
            XCTAssertTrue(watch.hint(claude) == nil, "stopped: no hint")
        }
        redraws?.cancel()
        redraws = nil
        XCTAssertTrue(dropped == nil, "the form's watch goes with the form: nothing holds it")
        rt.model.routeAgentSessions = false
        await rt.setLive(true)?.value
        await rt.setLive(false)?.value
        XCTAssertEqual(rt.service.status, .stopped, "flips after the form closed: no call into it, no crash")
    }

    /// #1219 (R1205-2), mutants a1 and a2: a form opened before the pool was ever built (no runtime) shows no hint;
    /// the first build through push(into:) is announced and the watch attaches to it, so the hint follows that runtime;
    /// a later build is not attached (no second subscription), and a push into a built slot builds and announces nothing.
    /// This row's own runtimes (port 0 on loopback, scratch suite, memory secrets), never the app's.
    func testCCPoolFormHintAttachesWhenThePoolIsFirstBuilt() async throws {
        final class Count { var n = 0 }
        let claude = AgentNewSession.argv("claude", shell: "/bin/zsh")
        var slot: CCPoolRuntime?
        let watch = AgentNewSessionPoolWatch(slot)
        let count = Count()
        let redraws = watch.objectWillChange.sink { count.n += 1 }   // main: every publish here is on main
        defer { redraws.cancel() }
        XCTAssertTrue(watch.hint(claude) == nil, "no runtime: no hint")

        let rt = runtime()
        let service = rt.service
        addTeardownBlock { service.stop() }
        try rt.store.addAccount(label: "Example Org", token: "tok-example", secrets: rt.secrets)
        rt.model.routeAgentSessions = true
        XCTAssertEqual(count.n, 0, "not built through push yet: nothing attached")

        let start = CCPoolRuntime.push(true, into: &slot) { rt }
        XCTAssertTrue(slot === rt)
        XCTAssertGreaterThan(count.n, 0, "the build is announced: the form redraws")
        await start?.value
        guard case .running = rt.service.status else { return XCTFail("live with an account: \(rt.service.status)") }
        XCTAssertEqual(watch.hint(claude), AgentNewSession.viaPoolHint, "the hint follows the runtime built")

        var other: CCPoolRuntime?
        let rt2 = runtime()
        let service2 = rt2.service
        addTeardownBlock { service2.stop() }
        let start2 = CCPoolRuntime.push(true, into: &other) { rt2 }
        await start2?.value
        var before = count.n
        rt2.model.routeAgentSessions = true
        XCTAssertEqual(count.n, before, "a later build is not attached")

        var calls = 0
        _ = CCPoolRuntime.push(true, into: &slot) { calls += 1; return nil }
        XCTAssertEqual(calls, 0, "a built slot builds nothing")

        before = count.n
        rt.model.routeAgentSessions = false
        XCTAssertGreaterThan(count.n, before, "still attached to the first: the form redraws")
        XCTAssertTrue(watch.hint(claude) == nil, "toggle off: no hint")
    }

    /// Records the thread each status-hook call ran on, then calls the hook the pane model installed.
    private final class HookThreads: @unchecked Sendable {
        private let lock = NSLock()
        private var _onMain: [Bool] = []
        var onMain: [Bool] { lock.withLock { _onMain } }
        func add(_ main: Bool) { lock.withLock { _onMain.append(main) } }
    }

    /// Formed here, nonisolated (never @MainActor): the service calls it on its listener queue.
    nonisolated private static func spy(_ threads: HookThreads, then hook: (@Sendable () -> Void)?) -> @Sendable () -> Void {
        { threads.add(Thread.isMainThread); hook?() }
    }

    /// #1219 (R1205-3), mutant l1: a listener lost after its start (cancelled by nobody the service knows, so Network
    /// delivers .cancelled to the service's own handler on its listener queue) publishes on the pane model and on an
    /// open form's watch, and the hint is gone at that publish. This row's own runtime, port 0 on loopback.
    func testCCPoolLostListenerPublishesAndTheHintGoes() async throws {
        let rt = runtime()
        let service = rt.service
        addTeardownBlock { service.stop() }
        try rt.store.addAccount(label: "Example Org", token: "tok-example", secrets: rt.secrets)
        rt.model.routeAgentSessions = true
        await rt.setLive(true)?.value
        guard case .running = rt.service.status else { return XCTFail("live with an account: \(rt.service.status)") }
        let claude = AgentNewSession.argv("claude", shell: "/bin/zsh")
        let watch = AgentNewSessionPoolWatch(rt)
        XCTAssertEqual(watch.hint(claude), AgentNewSession.viaPoolHint)

        let threads = HookThreads()
        XCTAssertNotNil(rt.service.onStatusChange, "the pane model installed its republisher")
        rt.service.onStatusChange = Self.spy(threads, then: rt.service.onStatusChange)
        let onModel = expectation(description: "the pane model publishes")
        let onWatch = expectation(description: "the form's watch publishes")
        onModel.assertForOverFulfill = false
        onWatch.assertForOverFulfill = false
        var hintAtPublish: [String?] = []
        let subs = [rt.model.objectWillChange.sink { onModel.fulfill() },
                    watch.objectWillChange.sink { hintAtPublish.append(watch.hint(claude)); onWatch.fulfill() }]
        defer { subs.forEach { $0.cancel() } }

        let listener = try XCTUnwrap(rt.service.currentListener)
        listener.cancel()
        await fulfillment(of: [onModel, onWatch], timeout: 10)

        XCTAssertEqual(rt.service.status, .failed(CCPoolService.reasonLost))
        XCTAssertEqual(threads.onMain, [false], "called once, on the listener's queue, not on main")
        XCTAssertTrue(hintAtPublish.first.map { $0 == nil } ?? false, "the hint is gone at the publish: \(hintAtPublish)")
        XCTAssertTrue(watch.hint(claude) == nil)
        XCTAssertEqual(rt.model.routeDisabledReason, "The proxy is not running.")
    }

    // MARK: - Resume (#1219 step 2, OQ-135 A)

    /// An ended record of `argv` in `dir` (Example paths only; nothing on disk: the runner is the recorder).
    private func record(_ name: String, dir: String = "/d", argv: [String]) -> DchHistoryRecord {
        var r = DchHistoryRecord(key: AgentSessionKey(dir: dir, name: name), started: 1_000, updated: 2_000, ended: 2_000, end: "signal 9")
        r.argv = argv
        return r
    }

    /// One job through `start` on `key`; the env the runner was handed for it.
    private func launchedEnv(_ c: AgentIslandController, _ rec: Recorder, key: AgentSessionKey,
                             file: StaticString = #filePath, line: UInt = #line, _ start: () -> Void) -> [String: String]? {
        let before = rec.envs.count
        start()
        XCTAssertEqual(rec.launched.wait(timeout: .now() + 5), .success, file: file, line: line)
        settle { !c.runner.isBusy(key) }
        let envs = rec.envs
        XCTAssertEqual(envs.count, before + 1, "one launch", file: file, line: line)
        return envs.last
    }

    /// The keys an env changed or dropped against the control env of /d: what a spawn's strip and routing touch.
    private static func touched(_ env: [String: String]?) -> Set<String> {
        let control = controlEnv("/d"), e = env ?? [:]
        return Set(control.keys.filter { e[$0] != control[$0] }).union(e.keys.filter { control[$0] == nil })
    }

    /// A single Resume of a local claude record, routing on: --revive gets exactly the env a new session of the
    /// record's command gets at the spawn recorder (dch hands the client's env to the revived command).
    func testCCPoolSingleResumeIsRoutedAsANewSessionOfItsCommand() {
        let rec = Recorder(), pool = Pool()
        let c = controller(rec, routing: pool.routing)
        let command = ["/opt/homebrew/bin/claude", "--chrome"]
        let spawned = spawnedEnv(c, rec, command, name: "api-2")
        let r = record("api", argv: command)
        c.store?.history = [r]
        let resumed = launchedEnv(c, rec, key: r.id) { XCTAssertTrue(c.resume(r), "the Resume started") }
        XCTAssertEqual(rec.args.last?.first, "--revive", "the job is the record's --revive, not a spawn")
        XCTAssertEqual(rec.args.last?.contains("--spawn"), false)
        XCTAssertEqual(resumed, spawned, "the same env as the spawn recorder's for that command")
        XCTAssertEqual(resumed, routedClaude, "literally: the pool's base URL, the credentials kept (OQ-132)")
        XCTAssertEqual(Self.touched(resumed), Self.touched(spawned), "the same set of variables as the spawn")
        // spawnEnv's own CLAUDECODE / CLAUDE_CODE_* strip, plus the base URL: routing touches nothing else.
        XCTAssertEqual(Self.touched(resumed), ["ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"])
        // Against the unrouted spawn env (`today`): the base URL only.
        XCTAssertEqual(Set(today.keys.filter { spawned?[$0] != today[$0] }).union((spawned ?? [:]).keys.filter { today[$0] == nil }),
                       ["ANTHROPIC_BASE_URL"])
        XCTAssertEqual(pool.mainReads, 0, "the Resume reads the pool on the runner's queue, never main")
    }

    /// Routing off: the Resume carries no routing variable (a spawn's unrouted env, the person's keys).
    func testCCPoolSingleResumeWithRoutingOffIsNotRouted() {
        let rec = Recorder(), pool = Pool()
        pool.set(on: false)
        let c = controller(rec, routing: pool.routing)
        let r = record("api", argv: ["claude"])
        c.store?.history = [r]
        let resumed = launchedEnv(c, rec, key: r.id) { XCTAssertTrue(c.resume(r), "the Resume started") }
        XCTAssertEqual(rec.args.last?.first, "--revive")
        XCTAssertEqual(resumed, today, "no routing variable: the person's credentials stay")
        XCTAssertTrue(resumed?["ANTHROPIC_BASE_URL"] == nil)
    }

    /// Resume interrupted (one --revive --all per folder) stays unrouted with routing on: the control env, untouched.
    func testCCPoolResumeInterruptedIsNotRouted() {
        let rec = Recorder(), pool = Pool()
        let c = controller(rec, routing: pool.routing)
        c.store?.history = [record("api", argv: ["claude"])]
        let resumed = launchedEnv(c, rec, key: AgentSessionKey(dir: "/d", name: "")) { c.resumeCrashed() }
        XCTAssertEqual(rec.args.last.map { Array($0.prefix(2)) }, ["--revive", "--all"])
        XCTAssertEqual(resumed, Self.controlEnv("/d"), "the control env as before #1219: no strip, no routing")
        XCTAssertEqual(Self.touched(resumed), [])
    }

    /// Another machine's record ("@" + host) stays unrouted with routing on: the control env, untouched.
    func testCCPoolRemoteRecordResumeIsNotRouted() {
        let rec = Recorder(), pool = Pool()
        let c = controller(rec, routing: pool.routing)
        let r = record("api", dir: "@example-host", argv: ["claude"])
        XCTAssertTrue(AgentWindowModel.isRemote(r))
        c.store?.history = [r]
        let resumed = launchedEnv(c, rec, key: r.id) { XCTAssertTrue(c.resume(r), "the Resume started") }
        XCTAssertEqual(rec.args.last?.first, "--revive")
        XCTAssertEqual(resumed, Self.controlEnv("@example-host"), "the control env as before #1219: no strip, no routing")
    }

    // MARK: - A session's own ANTHROPIC_BASE_URL (#1890)

    /// #1890 (mutant foreign-url-routed): the spawn env already pointing ANTHROPIC_BASE_URL elsewhere (the env dch is
    /// handed; no login probe here) is left byte for byte, and the form's hint says nothing: they agree.
    func testCCPoolForeignBaseURLInTheSpawnEnvIsNotRoutedAndTheHintAgrees() {
        let rec = Recorder(), pool = Pool()
        let c = controller(rec, routing: pool.routing)
        c.controlEnv = { Self.controlEnv($0).merging(["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"]) { $1 } }
        let mine = today.merging(["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"]) { $1 }
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api"), mine, "a foreign base URL: the env as it is")
        c.controlEnv = { Self.controlEnv($0).merging(["ANTHROPIC_BASE_URL": "http://127.0.0.1:41234/"]) { $1 } }
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api-2"), routedClaude, "this pool's own URL: routed (a no-op set)")
        c.controlEnv = { Self.controlEnv($0) }
        XCTAssertEqual(spawnedEnv(c, rec, ["claude"], name: "api-3"), routedClaude, "no base URL: routed")
        XCTAssertEqual(pool.mainReads, 0)
    }

    /// #1890: the login env's value (dch's login shell, the env the session really gets) decides, on the spawn path, the
    /// Resume flags and the form's hint alike; a known "" (unset there) routes whatever the handed env says.
    func testCCPoolForeignBaseURLFromTheLoginEnvIsNotRoutedAnywhere() {
        final class Login: @unchecked Sendable {
            let lock = NSLock()
            var value: String? = "http://127.0.0.1:8787"
            var waits = 0, mainReads = 0
            func read(_ wait: Bool) -> String? {
                lock.withLock {
                    if wait { waits += 1 }
                    if Thread.isMainThread { mainReads += 1 }
                    return value
                }
            }
        }
        let login = Login(), pool = Pool()
        var routing = pool.routing
        routing.inherited = { login.read($0) }
        let claude = AgentNewSession.argv("claude", shell: "/bin/zsh")
        let rec = Recorder()
        let c = controller(rec, routing: routing)
        XCTAssertTrue(AgentNewSession.poolHint(claude, routing: routing) == nil, "foreign: no hint")
        XCTAssertEqual(login.waits, 0, "the hint never waits for the login shell")
        XCTAssertEqual(spawnedEnv(c, rec, claude, name: "api"), today, "foreign: not routed")
        XCTAssertEqual(login.waits, 1, "the spawn asked on the runner's queue")
        XCTAssertEqual(routing.reviveFlags(claude), [], "a Resume carries no flags either")
        login.lock.withLock { login.value = "" }
        c.controlEnv = { Self.controlEnv($0).merging(["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"]) { $1 } }
        routing.own = { "http://127.0.0.1:8787" }
        XCTAssertTrue(AgentNewSession.poolHint(claude, routing: routing) == nil, "#1892: login unset, Prosper's own value foreign: not routed, no hint")
        routing.own = { nil }
        XCTAssertEqual(AgentNewSession.poolHint(claude, routing: routing), AgentNewSession.viaPoolHint)
        let foreignEnv = today.merging(["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"]) { $1 }
        XCTAssertEqual(spawnedEnv(c, rec, claude, name: "api-2"), foreignEnv, "#1891: login unset but the spawn env is foreign: not routed")
        routing.own = { "http://127.0.0.1:8787" }
        XCTAssertEqual(routing.reviveFlags(claude), Self.poolFlags, "#1892: a Resume stays login-only, Prosper's own value is not read")
        routing.own = { nil }
        XCTAssertEqual(routing.reviveFlags(claude), Self.poolFlags, "a Resume has no spawn env: the login env alone decides")
        c.controlEnv = { Self.controlEnv($0) }
        XCTAssertEqual(spawnedEnv(c, rec, claude, name: "api-3"), routedClaude, "the login env says unset, the spawn env none: routed")
        login.lock.withLock { login.value = "http://127.0.0.1:41234" }
        c.controlEnv = { Self.controlEnv($0).merging(["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"]) { $1 } }
        XCTAssertEqual(spawnedEnv(c, rec, claude, name: "api-4"), foreignEnv, "#1891: the login env is this pool's own, the spawn env foreign: not routed")
    }

    /// #1891 (mutant init-start-dropped): CCPoolRuntime.init starts the login probe in the background at once, off main, with no
    /// read at all; the first spawn's waiting read then runs no probe of its own (counts runs).
    func testCCPoolRuntimeInitStartsTheLoginProbeOnce() {
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0, onMain = 0
            let ran = DispatchSemaphore(value: 0)
            func run() -> String? {
                lock.withLock { calls += 1; if Thread.isMainThread { onMain += 1 } }
                ran.signal()
                return ""
            }
        }
        let probe = Probe(), dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old"), defaults: XCTestDefaults(suiteName: "prosper-ccpool-routing-\(UUID().uuidString)")!,
                               probeBase: cfg.upstream, logger: CCPoolCapturingLogger(), baseURLProbe: { probe.run() })
        XCTAssertEqual(probe.ran.wait(timeout: .now() + 5), .success, "the probe ran with no read")
        let end = Date().addingTimeInterval(5) // run() answers after it signals: wait until the value is known (a non-waiting read)
        while rt.routing.inherited(false) != "", Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(rt.routing.inherited(true), "")
        XCTAssertEqual(rt.routing.inherited(true), "")
        XCTAssertEqual(probe.lock.withLock { probe.calls }, 1, "one login shell at init, none per read")
        XCTAssertEqual(probe.lock.withLock { probe.onMain }, 0, "never on main")
    }

    /// #1891: a Resume's flags read the login env on the runner's queue through the real reader: one probe run in all, however many
    /// Resumes follow (counts runs, not time); the init-time start() and the first Resume share that one run.
    func testCCPoolReviveFlagsProbeTheLoginShellOnce() {
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var n = 0
            func bump() -> String? { lock.withLock { n += 1; return "" } }
            var value: Int { lock.withLock { n } }
        }
        let count = Count(), pool = Pool()
        let found = CCPool.InheritedBaseURL(probe: { count.bump() }, process: nil)
        var routing = pool.routing
        routing.inherited = { found.read(wait: $0) }
        let claude = AgentNewSession.argv("claude", shell: "/bin/zsh")
        for _ in 0..<5 { XCTAssertEqual(routing.reviveFlags(claude), Self.poolFlags) }
        XCTAssertEqual(count.value, 1, "one login shell for five Resumes")
        XCTAssertEqual(routing.delta(claude, wait: true, env: nil), CCPool.EnvDelta(set: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:41234"]))
        XCTAssertEqual(count.value, 1, "a spawn after them reads the known value")
    }

    // MARK: - Resume past the login shell's env (#1499, dch 1.94.0 --revive --env/--unset)

    /// The pool's spawn delta as --revive flags, literally: the pool's base URL only, no --unset (OQ-132).
    private static let poolFlags = ["--env", "ANTHROPIC_BASE_URL=http://127.0.0.1:41234"]

    /// One single Resume of `r` on a control dch of `version` through the recorder; the argv it was handed.
    private func resumedArgs(_ r: DchHistoryRecord, version: [Int], pool: Pool,
                             file: StaticString = #filePath, line: UInt = #line) -> [String]? {
        let rec = Recorder()
        let c = controller(rec, routing: pool.routing, version: version)
        c.store?.history = [r]
        _ = launchedEnv(c, rec, key: r.id, file: file, line: line) { XCTAssertTrue(c.resume(r), "the Resume started", file: file, line: line) }
        return rec.args.last
    }

    private static let kitBin = "/Users/example/kits/com.example.kit-a/bin"

    /// #1684: one single Resume with kit bins live; the argv it was handed. `pool` nil: no routing seam (the kit alone).
    private func resumedWithKits(_ r: DchHistoryRecord, version: [Int], bins: [String], pool: Pool?) -> [String]? {
        let rec = Recorder()
        let c = controller(rec, routing: pool?.routing, version: version)
        c.reviveKitBins = { bins }
        c.store?.history = [r]
        _ = launchedEnv(c, rec, key: r.id) { XCTAssertTrue(c.resume(r), "the Resume started") }
        return rec.args.last
    }

    /// Mutant kit-path-dropped: a local routed Resume on 1.94.0 passes the kit bins as --env PATH (control PATH first, bins appended),
    /// after the pool's flags; with no routing the PATH flag stands alone.
    func testResumeOnDch194PassesTheKitBinsAsEnvPath() {
        let path = ["--env", "PATH=/Users/example/bin:/usr/bin:" + Self.kitBin]
        XCTAssertEqual(resumedWithKits(record("api", argv: ["claude"]), version: [1, 94, 0], bins: [Self.kitBin], pool: Pool()),
                       ["--revive", "api", "--json"] + Self.poolFlags + path)
        XCTAssertEqual(resumedWithKits(record("api", argv: ["claude"]), version: [1, 94, 0], bins: [Self.kitBin], pool: nil),
                       ["--revive", "api", "--json"] + path)
    }

    /// Mutants kit-path-below-gate and kit-path-remote: no PATH flag below 1.94.0, none for another machine's record, none
    /// without a live kit bin or when the bin is already on PATH.
    func testResumeKitPathFlagIsLocalAnd194Only() {
        XCTAssertEqual(resumedWithKits(record("api", argv: ["claude"]), version: [1, 93, 9], bins: [Self.kitBin], pool: nil),
                       ["--revive", "api", "--json"])
        XCTAssertEqual(resumedWithKits(record("api", dir: "@example-host", argv: ["claude"]), version: [1, 94, 0], bins: [Self.kitBin], pool: Pool()),
                       ["--revive", "api", "--json"])
        XCTAssertEqual(resumedWithKits(record("api", argv: ["claude"]), version: [1, 94, 0], bins: [], pool: nil), ["--revive", "api", "--json"])
        XCTAssertEqual(resumedWithKits(record("api", argv: ["claude"]), version: [1, 94, 0], bins: ["/usr/bin"], pool: nil),
                       ["--revive", "api", "--json"])
    }

    /// Mutant version-gate-off: below dch 1.94.0 the argv is as before (dch would refuse the flags).
    func testCCPoolResumeOnDch193HasNoEnvFlags() {
        let pool = Pool()
        XCTAssertEqual(resumedArgs(record("api", argv: ["claude"]), version: [1, 93, 9], pool: pool), ["--revive", "api", "--json"])
    }

    /// Mutant resume-env-dropped: on 1.94.0 a routed local Resume carries the spawn delta as flags, read off main.
    func testCCPoolResumeOnDch194CarriesThePoolDelta() {
        let pool = Pool()
        XCTAssertEqual(resumedArgs(record("api", argv: ["/opt/homebrew/bin/claude", "--chrome"]), version: [1, 94, 0], pool: pool),
                       ["--revive", "api", "--json"] + Self.poolFlags)
        XCTAssertEqual(pool.mainReads, 0, "the flags read the pool on the runner's queue, never main")
        XCTAssertEqual(CCPool.Routing(on: { true }, status: { .running(port: 41234) }, hasAccounts: { true }).delta(["claude"]).reviveFlags,
                       Self.poolFlags, "exactly the spawn delta")
    }

    /// Mutant remote-gets-flags: another machine's record gets no flags (dch exits 2 on --env/--unset for host:name).
    func testCCPoolRemoteResumeOnDch194HasNoEnvFlags() {
        let pool = Pool()
        XCTAssertEqual(resumedArgs(record("api", dir: "@example-host", argv: ["claude"]), version: [1, 94, 0], pool: pool),
                       ["--revive", "api", "--json"])
    }

    /// Routing off, or a command the pool does not route: an empty delta, no flags.
    func testCCPoolResumeOnDch194WithRoutingOffOrNotClaudeHasNoEnvFlags() {
        let off = Pool()
        off.set(on: false)
        XCTAssertEqual(resumedArgs(record("api", argv: ["claude"]), version: [1, 94, 0], pool: off), ["--revive", "api", "--json"])
        XCTAssertEqual(resumedArgs(record("api", argv: ["headroom", "wrap", "claude"]), version: [1, 94, 0], pool: Pool()),
                       ["--revive", "api", "--json"])
    }

    // MARK: - Codex Resume and Restart (#2031)

    private static let codexWords = ["--codex-drop-provider"] + stride(from: 1, to: 12, by: 2).flatMap { ["--codex-config", CCPool.codexArgs(port: 41234)[$0]] }

    private func codexPool(on: Bool) -> CCPool.Routing {
        var routing = Pool().routing
        routing.codexOn = { on }
        routing.hasCodexAccounts = { true }
        return routing
    }

    private func resumedCodex(_ r: DchHistoryRecord, version: [Int], on: Bool) -> [String]? {
        let rec = Recorder()
        let c = controller(rec, routing: codexPool(on: on), version: version)
        c.store?.history = [r]
        _ = launchedEnv(c, rec, key: r.id) { XCTAssertTrue(c.resume(r), "the Resume started") }
        return rec.args.last
    }

    /// `argv`: the row's LIVE record (the readLiveRecords seam); `ended`: store.history's ended records, never read by a restart.
    private func restartedCodex(agent: String, version: [Int], on: Bool, argv: [String] = ["codex"],
                                ended: [DchHistoryRecord] = []) -> [String]? {
        let rec = Recorder()
        let c = controller(rec, routing: codexPool(on: on), version: version)
        var s = AgentSession(key: AgentSessionKey(dir: "/d", name: "api"), alias: "", activity: 1, state: .working, agents: 0)
        s.agent = agent
        let live = record("api", argv: argv)
        c.readLiveRecords = { _ in [live] }
        c.store?.history = ended
        _ = launchedEnv(c, rec, key: s.key) { XCTAssertTrue(c.restart(s), "the Restart started") }
        return rec.args.last
    }

    /// Mutant codex-words-dropped-when-on: routing on, a Codex record's Resume carries the drop and the six pool words in order.
    func testCodexResumeOnDch1189CarriesTheDropAndThePoolWords() {
        XCTAssertEqual(resumedCodex(record("api", argv: ["codex"]), version: [1, 189, 0], on: true),
                       ["--revive", "api", "--json"] + Self.codexWords)
        XCTAssertEqual(Self.codexWords.filter { $0 == "--codex-config" }.count, 6)
    }

    /// Rule 3: a plain Codex record with routing off at the revive gets no Codex flag (it holds no pool word to drop).
    func testPlainCodexResumeWithRoutingOffHasNoCodexFlags() {
        XCTAssertEqual(resumedCodex(record("api", argv: ["codex"]), version: [1, 189, 0], on: false), ["--revive", "api", "--json"])
    }

    /// A record routed at spawn (#2009): the pool's words at an older port, so codexKeepsOwn alone would call it the user's.
    private static let routedArgv = ["codex"] + CCPool.codexArgs(port: 40000)
    private static let ownArgv = ["codex", "-c", "model_provider=\"mine\""]

    /// Mutant pool-words-as-own (H2): a routed record's Resume and Restart get the drop and the current words, routing off the drop alone.
    func testRoutedCodexRecordGetsTheDropAndTheCurrentWords() {
        let base = AgentIsland.restartArgs("api") ?? []
        XCTAssertEqual(resumedCodex(record("api", argv: Self.routedArgv), version: [1, 189, 0], on: true),
                       ["--revive", "api", "--json"] + Self.codexWords)
        XCTAssertEqual(resumedCodex(record("api", argv: Self.routedArgv), version: [1, 189, 0], on: false),
                       ["--revive", "api", "--json", "--codex-drop-provider"])
        XCTAssertEqual(restartedCodex(agent: "codex", version: [1, 189, 0], on: true, argv: Self.routedArgv), base + Self.codexWords)
        XCTAssertEqual(restartedCodex(agent: "codex", version: [1, 189, 0], on: false, argv: Self.routedArgv), base + ["--codex-drop-provider"])
    }

    /// Mutant own-provider-dropped (H3): a record with the user's own provider gets nothing, routing on or off.
    func testOwnProviderCodexRecordGetsNoCodexFlags() {
        let base = AgentIsland.restartArgs("api") ?? []
        for on in [true, false] {
            XCTAssertEqual(resumedCodex(record("api", argv: Self.ownArgv), version: [1, 189, 0], on: on), ["--revive", "api", "--json"], "on \(on)")
            XCTAssertEqual(restartedCodex(agent: "codex", version: [1, 189, 0], on: on, argv: Self.ownArgv), base, "on \(on)")
        }
    }

    /// Mutant restart-reads-ended-history: a live own-provider row whose ended history holds an older plain codex record of
    /// the same key: its live record decides, routing on -> no Codex flags.
    func testRestartReadsTheLiveRecordNotAnEndedOne() {
        XCTAssertEqual(restartedCodex(agent: "codex", version: [1, 189, 0], on: true, argv: Self.ownArgv, ended: [record("api", argv: ["codex"])]),
                       AgentIsland.restartArgs("api") ?? [])
    }

    /// No runtime (the island's and the ctl's default): a routed record gets the drop alone, its own provider or plain nothing.
    func testNoRuntimeDefaultDropsOnlyAPoolRecord() {
        let flags = AgentIslandController.poolCodexFlags()
        XCTAssertEqual(flags([Self.routedArgv]), ["--codex-drop-provider"])
        XCTAssertEqual(flags([Self.ownArgv]), [])
        XCTAssertEqual(flags([["codex"]]), [])
        XCTAssertEqual(DchControlOps().codexFlags([Self.routedArgv]), ["--codex-drop-provider"])
        XCTAssertEqual(DchControlOps().codexFlags([Self.ownArgv]), [])
    }

    /// The rule over a Restart all dir's rows: one own provider means none; a routed and a plain row share the words; a
    /// pool word is matched exactly (another provider table is the user's); a headroom-wrapped codex is never given words.
    func testCodexReviveRuleOverSeveralRecords() {
        let words = CCPool.codexArgs(port: 41234)
        XCTAssertEqual(CCPool.codexReviveFlags([Self.routedArgv, Self.ownArgv], words: words), [])
        XCTAssertEqual(CCPool.codexReviveFlags([Self.routedArgv, ["codex"]], words: words), Array(Self.codexWords))
        XCTAssertEqual(CCPool.codexReviveFlags([Self.routedArgv, ["codex"]], words: []), ["--codex-drop-provider"])
        XCTAssertEqual(CCPool.codexReviveFlags([["codex", "-c", "model_providers.mine.base_url=\"x\""]], words: words), [])
        XCTAssertEqual(CCPool.codexReviveFlags([["codex", "-c", "model_provider=\"prosperpool2\""]], words: words), [])
        XCTAssertEqual(CCPool.codexReviveFlags([["headroom", "wrap", "codex"]], words: words), [])
        XCTAssertEqual(CCPool.codexWithoutPoolWords(Self.routedArgv + ["-p", "x"]), ["codex", "-p", "x"])
    }

    /// Mutant codex-check-removed: a Claude record gets nothing new, routing on or off.
    func testClaudeResumeOnDch1189HasNoCodexFlags() {
        for on in [true, false] {
            XCTAssertEqual(resumedCodex(record("api", argv: ["claude"]), version: [1, 189, 0], on: on),
                           ["--revive", "api", "--json"] + Self.poolFlags)
        }
    }

    /// Mutant version-gate-removed: dch 1.188.0 gets no Codex flag.
    func testCodexResumeOnDch1188HasNoCodexFlags() {
        XCTAssertEqual(resumedCodex(record("api", argv: ["codex"]), version: [1, 188, 0], on: true), ["--revive", "api", "--json"])
    }

    /// A remote record is not routed through this Mac's pool: its revive is as before.
    func testCodexResumeOfARemoteRecordIsUnchanged() {
        XCTAssertEqual(resumedCodex(record("api", dir: "@example-host", argv: ["codex"]), version: [1, 189, 0], on: true).map { !$0.contains("--codex-drop-provider") }, true)
    }

    /// Restart --include-agents of a Codex row carries the same words; a Claude row and dch 1.188.0 get none.
    func testCodexRestartCarriesTheSameWords() {
        let base = AgentIsland.restartArgs("api") ?? []
        XCTAssertEqual(restartedCodex(agent: "codex", version: [1, 189, 0], on: true), base + Self.codexWords)
        XCTAssertEqual(restartedCodex(agent: "codex", version: [1, 189, 0], on: false), base, "rule 3: plain codex, routing off")
        XCTAssertEqual(restartedCodex(agent: "claude", version: [1, 189, 0], on: true), base)
        XCTAssertEqual(restartedCodex(agent: "codex", version: [1, 188, 0], on: true), base)
    }
}
