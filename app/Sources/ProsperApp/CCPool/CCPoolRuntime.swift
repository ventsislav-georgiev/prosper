import Combine
import Foundation

/// #871 P2b-1, spec 3.2: the proxy runs while the bundled ccpool extension is live AND the pool
/// lists an account. Every start, stop and restart runs on one serial queue, and each one reads
/// the wanted state when it runs, so the last event wins in whatever order the callers' tasks
/// reach the queue.
///
/// Isolation: none. The closures handed to `queue` are formed here, in nonisolated code, never in
/// @MainActor code (errata C7, the beta.1 Agent Island trap).
final class CCPoolLifecycle: @unchecked Sendable {
    let service: CCPoolService
    private let queue = DispatchQueue(label: "com.prosper.ccpool.lifecycle")
    private let lock = NSLock()
    private var _live = false
    private var _relaunching = false

    init(service: CCPoolService) { self.service = service }

    /// #1676: Sparkle said it relaunches the app (an update): the stop at quit leaves the port keeper holding the port.
    var relaunching: Bool {
        get { lock.withLock { _relaunching } }
        set { lock.withLock { _relaunching = newValue } }
    }

    /// The extension's live flag, as AppDelegate last pushed it.
    var live: Bool {
        get { lock.withLock { _live } }
        set { lock.withLock { _live = newValue } }
    }

    var shouldRun: Bool { live && service.store.hasAccounts }

    /// Start or stop to match `shouldRun`; `restart` also restarts a running listener. Blocks up to
    /// a few seconds (port probe + bind): only ever called on `queue`.
    @discardableResult
    private func settleNow(restart: Bool) -> CCPoolService.Status {
        guard shouldRun else {
            if service.status != .stopped { service.stop() }
            // #1676: ccpool off, or a quit that is not an update's relaunch: the keeper closes the port and exits.
            if !relaunching { service.config.keeper?.exit() }
            return service.status
        }
        // #1672 (R1665e n7): a toggle-off or quit queued behind a retry is seen per tick, before any bind.
        if restart { return service.restart(stillWanted: { [self] in shouldRun }) }
        if case .running = service.status { return service.status }
        // A port another program holds is probed again on each event (an add, an enable, a click):
        // one GET of the health path, never a retry loop (the bind retry is for a free port only).
        return service.start(bindRetry: CCPoolService.timeWaitRetry, stillWanted: { [self] in shouldRun })
    }

    /// Queue one settle and wait for it, off the caller's thread.
    func settle(restart: Bool = false) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                settleNow(restart: restart)
                done.resume()
            }
        }
    }

    /// #1660: "Stop ccpool and start" on the same queue as every start and stop; only while the proxy
    /// should run (otherwise a settle, which never signals). `pid` nil: whichever ccpool holds the port (#1665).
    func takeOver(pid: Int?) async -> CCPoolService.TakeOver {
        await withCheckedContinuation { (done: CheckedContinuation<CCPoolService.TakeOver, Never>) in
            queue.async { [self] in
                done.resume(returning: shouldRun ? service.takeOver(pid: pid, stillWanted: { [self] in shouldRun }) : .started(settleNow(restart: false)))
            }
        }
    }

    /// #1190 INFO-1: the app quits. Not live any more, and a stop queued behind any start or restart
    /// in flight, so a listener that start publishes late is stopped too. Blocks the caller (main, at
    /// quit) up to `timeout`; false when that ran out (a start still in its probe or bind): the stop
    /// stays queued and runs when that start returns, if the process is still alive.
    @discardableResult
    func quit(timeout: TimeInterval) -> Bool {
        live = false
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            settleNow(restart: false)
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }
}

/// #871 P2b-1: the one owner of the production ccpool objects: the store (state.json, 0600 in a
/// 0700 directory), the Keychain secrets, the proxy service, its life cycle and the pane model.
///
/// The app's instance (`shared`) is built by the first push of a live extension and never before:
/// a disabled extension builds nothing, opens no file, touches no Keychain item and binds nothing.
/// Under XCTest `production()` builds nothing at all; tests build their own instance on a temp
/// directory, memory secrets and an ephemeral port.
///
/// Isolation: @MainActor (AppDelegate and Settings use it). It hands no closure to a queue: the
/// blocking work goes through the model's detached tasks and `CCPoolLifecycle`.
@MainActor
final class CCPoolRuntime {
    let store: CCPoolStore
    let secrets: CCPoolSecrets
    let service: CCPoolService
    let lifecycle: CCPoolLifecycle
    let model: CCPoolPaneModel
    /// P2b-2: the person's toggle as the pane writes it (the model's defaults), readable off main.
    private let routeOn: @Sendable () -> Bool
    /// #1890: the session's inherited ANTHROPIC_BASE_URL (CCPool.InheritedBaseURL); always nil without a probe (XCTest).
    private let inherited: @Sendable (_ wait: Bool) -> String?
    /// #1892: Prosper's own ANTHROPIC_BASE_URL, read once at init (the spawn env's source).
    private let own: @Sendable () -> String?
    private var relaunchObserver: NSObjectProtocol?

    init(directory: URL, secrets: CCPoolSecrets, config: CCPoolServiceConfig, vaultURL: URL,
         defaults: UserDefaults = Preferences.defaults, probeBase: URL = CCPoolService.productionUpstream,
         logger: CCPoolLogger = CCPoolOSLog(), trash: @escaping CCPoolMigration.Trash = CCPoolMigration.moveToTrash,
         launcherPath: String? = nil, baseURLProbe: CCPool.InheritedBaseURL.Probe? = CCPool.InheritedBaseURL.live) {
        store = CCPoolStore(directory: directory, logger: logger)
        self.secrets = secrets
        config.exhaustedThreshold = CCPoolPaneModel.exhaustedValue(in: defaults)
        service = CCPoolService(config: config, store: store, secrets: secrets, logger: logger)
        lifecycle = CCPoolLifecycle(service: service)
        let made = CCPoolPaneModel(store: store, secrets: secrets, service: service, logger: logger, defaults: defaults,
                                   probeBase: probeBase, vaultURL: vaultURL, trash: trash, launcherPath: launcherPath,
                                   lifecycle: lifecycle)
        model = made
        // #1890: a background probe that lands redraws the pane line and the form's hint (both watch the model).
        let processValue = CCPool.processBaseURL()
        let found = baseURLProbe.map { probe in
            CCPool.InheritedBaseURL(probe: probe, process: processValue) { [weak made] in
                DispatchQueue.main.async { MainActor.assumeIsolated { made?.objectWillChange.send() } }
            }
        }
        found?.start() // #1891: probe now, off main, so no spawn waits for the login shell
        let read: @Sendable (_ wait: Bool) -> String? = { found?.read(wait: $0) }
        inherited = read
        made.inheritedBaseURL = read
        let ownRead: @Sendable () -> String? = { processValue }
        own = ownRead
        made.ownBaseURL = ownRead
        // UserDefaults is thread-safe; held the way Preferences.defaults is.
        nonisolated(unsafe) let routeDefaults = defaults
        routeOn = { CCPoolPaneModel.routeValue(in: routeDefaults) }
    }

    /// Launch, enable and disable: the proxy follows the extension (and the account list).
    @discardableResult
    func setLive(_ live: Bool) -> Task<Void, Never>? {
        lifecycle.live = live
        return model.reconcileProxy()
    }

    /// P2b-2: what new Agent Sessions route on (AgentIslandController.sessionEnvContributors, the New session
    /// form's hint): the pane's toggle, this proxy's status and this pool's accounts, read at each call.
    var routing: CCPool.Routing { service.routing(on: routeOn, inherited: inherited, own: own) }

    /// #1537: the Agent Island's plan usage line: the current account's last usage sample (relayed replies or a
    /// Refresh) and its reset stamps, as a plain island value. nil without a current account or a sample.
    func planUsage(now: Double) -> AgentPlanUsage? {
        let st = store.snapshot
        guard let label = st.current, let account = st.accounts[label], let sample = store.usageSample(label) else { return nil }
        return AgentPlanUsage(util: sample.util, at: sample.at, reset: account.reset, now: now)
    }

    /// The app quits: the stop runs on the life cycle's queue, after any start in flight (#1190
    /// INFO-1), and no queued start binds again. Waits at most `timeout` on main; past it the
    /// published listener is stopped here as before and the queued stop catches a late one.
    func quit(timeout: TimeInterval = 2) {
        if !lifecycle.quit(timeout: timeout) { service.stop() }
    }

    /// #1665: prosper://ccpool/takeover (AppDelegate's prosper switch), for a person away from the pane. The pane
    /// button's own path (model.takeOverProxy, on the life cycle's queue): a free port starts, a recognized ccpool
    /// holder is taken over, another program's port is left alone (start logs it), a running proxy stays as it is.
    /// Only while the proxy should run (the extension live, an account in the pool). No window, no activation.
    @discardableResult
    static func openLink(_ url: URL, runtime: CCPoolRuntime? = shared) -> Task<Void, Never>? {
        guard url.path == "/takeover" else {
            CCPoolOSLog().note(nil, "prosper://ccpool: unknown path; nothing done")
            return nil
        }
        guard let runtime else {
            CCPoolOSLog().note(nil, "prosper://ccpool/takeover: the ccpool extension is off; nothing done")
            return nil
        }
        guard runtime.lifecycle.shouldRun else {
            runtime.service.logger.note(nil, "prosper://ccpool/takeover: the extension is off or the pool has no account; nothing done")
            return nil
        }
        runtime.service.logger.note(nil, "prosper://ccpool/takeover")
        return runtime.model.takeOverProxy(pid: nil)
    }

    // MARK: The app's instance

    /// Built by the first live push (AppDelegate), kept for the life of the process.
    private(set) static var shared: CCPoolRuntime?

    /// AppDelegate's push of the extension's live flag, at launch and on every enable/disable.
    /// #915: and host.ccpool.status() reads this instance's service from then on (the off answer while none is built).
    static func setExtensionLive(_ live: Bool) {
        push(live, into: &shared, build: production)
        ExtensionPoolStatus.source = CCPoolService.statusSource(shared?.service)
    }

    /// #1190 INFO-5 (b): the push, on a slot a test owns. The first live push builds; a push while
    /// nothing is built and the extension is off builds nothing.
    /// #1219 (R1205-2): each instance push() builds, sent on main right after it is stored (an open New session form
    /// attaches its hint to it). Main-actor isolated, as push() is.
    static let built = PassthroughSubject<CCPoolRuntime, Never>()

    @discardableResult
    static func push(_ live: Bool, into slot: inout CCPoolRuntime?, build: () -> CCPoolRuntime?) -> Task<Void, Never>? {
        if slot == nil, live, let made = build() {
            slot = made
            built.send(made)
        }
        return slot?.setLive(live)
    }

    /// The production objects, or nil under XCTest: no test run builds them, reads the real
    /// Application Support store, or reaches the Keychain through them.
    static func production() -> CCPoolRuntime? {
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        var config = CCPoolServiceConfig()
        let keeperDir = CCPoolStore.defaultDirectory.appendingPathComponent("keeper", isDirectory: true)
        let keeperExe = Bundle.main.bundleURL.appending(path: "Contents/MacOS/CCPoolKeeper").path
        config.keeper = CCPoolKeeperLink(directory: keeperDir, port: config.port,
                                         spawner: CCPoolKeeperLink.posixSpawn(executable: keeperExe, directory: keeperDir, port: config.port))
        let made = CCPoolRuntime(directory: CCPoolStore.defaultDirectory, secrets: CCPoolKeychainSecrets(),
                                 config: config,
                                 vaultURL: CCPoolMigration.vaultURL(home: FileManager.default.homeDirectoryForCurrentUser,
                                                                    environment: ProcessInfo.processInfo.environment),
                                 launcherPath: launcherPath(extensionsDir: ExtensionRegistry.bundledSystemDir))
        // #1676: an update's relaunch keeps the port (the keeper holds it until the new app fetches it). Kept for the
        // process's life, like the instance. @Sendable: Sparkle may post off main.
        made.relaunchObserver = NotificationCenter.default.addObserver(forName: LiveStatusPublisher.updateWillRelaunch, object: nil,
                                                                       queue: nil) { @Sendable [lifecycle = made.lifecycle] _ in lifecycle.relaunching = true }
        return made
    }

    /// #915 (spec 3.5): the shipped launcher, inside the bundled ccpool extension in Contents/Resources/extensions
    /// (scripts/bundle.sh copies Resources/extensions there; ExtensionRegistry.bundledSystemDir finds it). nil when
    /// the app has no bundled extensions dir (a bare `swift run`): the pane then names bin/ccpool-launch relatively.
    static func launcherPath(extensionsDir: URL?) -> String? {
        extensionsDir?.appending(path: "ccpool/bin/ccpool-launch").path
    }
}

/// #915 (spec 3.5): host.ccpool.status(), label-level. The keys are running, port, current (absent when none) and
/// accounts, each {label, state, until (absent unless limited or held)}: never a token, a Keychain id, a header value,
/// a usage figure or a pin. Reads the lock-guarded status and store only, so it answers on any thread.
extension CCPoolService {
    /// What host.ccpool.status() reads: this service, or the off answer (not running, the default port, no accounts)
    /// while nothing is built. Formed here, in nonisolated code, never in @MainActor code (errata C7): any thread calls it.
    static func statusSource(_ service: CCPoolService?) -> @Sendable () -> String {
        { service?.statusJSON() ?? statusJSON(running: false, port: defaultPort, state: nil, now: 0) }
    }

    func statusJSON(now: Double = Date().timeIntervalSince1970) -> String {
        if case .running(let port) = status { return Self.statusJSON(running: true, port: port, state: store.snapshot, now: now) }
        return Self.statusJSON(running: false, port: config.port, state: store.snapshot, now: now)
    }

    static func statusJSON(running: Bool, port: UInt16, state: CCPoolState?, now: Double) -> String {
        var obj: [String: Any] = ["running": running, "port": Int(port)]
        if let current = state?.current { obj["current"] = current }
        // #1838: alphabetical, as the pane lists them; `order` is only the membership list.
        obj["accounts"] = (state?.order ?? []).sorted(by: CCPoolCore.labelFirst).compactMap { statusRow(label: $0, state: state, now: now) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return ExtensionPoolStatus.off }
        return String(decoding: data, as: UTF8.self)
    }

    /// One account of the status answer, {label, state, until}; nil for a label the state does not hold.
    /// #1674: the loopback hold / clear answer is this same row.
    static func statusRow(label: String, state: CCPoolState?, now: Double) -> [String: Any]? {
        guard let account = state?.accounts[label] else { return nil }
        // The Refresh-only states (rejected, unverified) live in the pane model, not the store: never reached here.
        let row = CCPoolPaneModel.rowState(label: label, account: account, current: state?.current, now: now,
                                           rejected: [], unverified: [])
        switch row {
        case .active: return ["label": label, "state": "active"]
        case .ready, .rejected, .unverified: return ["label": label, "state": "ready"]
        case .limited(let until, _): return ["label": label, "state": "limited", "until": until]
        case .held(let until): return ["label": label, "state": "held", "until": until]
        case .refused: return ["label": label, "state": "refused"]
        }
    }
}
