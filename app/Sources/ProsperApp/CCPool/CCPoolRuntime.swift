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

    init(service: CCPoolService) { self.service = service }

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
            return service.status
        }
        if restart { return service.restart() }
        if case .running = service.status { return service.status }
        // A port another program holds is probed again on each event (an add, an enable, a click):
        // one GET of the health path, never a retry loop (the bind retry is for a free port only).
        return service.start(bindRetry: 3)
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

    init(directory: URL, secrets: CCPoolSecrets, config: CCPoolServiceConfig, vaultURL: URL,
         defaults: UserDefaults = Preferences.defaults, probeBase: URL = CCPoolService.productionUpstream,
         logger: CCPoolLogger = CCPoolOSLog(), trash: @escaping CCPoolMigration.Trash = CCPoolMigration.moveToTrash) {
        store = CCPoolStore(directory: directory, logger: logger)
        self.secrets = secrets
        service = CCPoolService(config: config, store: store, secrets: secrets, logger: logger)
        lifecycle = CCPoolLifecycle(service: service)
        model = CCPoolPaneModel(store: store, secrets: secrets, service: service, logger: logger, defaults: defaults,
                                probeBase: probeBase, vaultURL: vaultURL, trash: trash, lifecycle: lifecycle)
        // UserDefaults is thread-safe; held the way Preferences.defaults is.
        nonisolated(unsafe) let routeDefaults = defaults
        routeOn = { routeDefaults.bool(forKey: CCPoolPaneModel.routeKey) }
    }

    /// Launch, enable and disable: the proxy follows the extension (and the account list).
    @discardableResult
    func setLive(_ live: Bool) -> Task<Void, Never>? {
        lifecycle.live = live
        return model.reconcileProxy()
    }

    /// P2b-2: what new Agent Sessions route on (AgentIslandController.sessionEnvContributors, the New session
    /// form's hint): the pane's toggle, this proxy's status and this pool's accounts, read at each call.
    var routing: CCPool.Routing { service.routing(on: routeOn) }

    /// The app quits: the stop runs on the life cycle's queue, after any start in flight (#1190
    /// INFO-1), and no queued start binds again. Waits at most `timeout` on main; past it the
    /// published listener is stopped here as before and the queued stop catches a late one.
    func quit(timeout: TimeInterval = 2) {
        if !lifecycle.quit(timeout: timeout) { service.stop() }
    }

    // MARK: The app's instance

    /// Built by the first live push (AppDelegate), kept for the life of the process.
    private(set) static var shared: CCPoolRuntime?

    /// AppDelegate's push of the extension's live flag, at launch and on every enable/disable.
    static func setExtensionLive(_ live: Bool) { push(live, into: &shared, build: production) }

    /// #1190 INFO-5 (b): the push, on a slot a test owns. The first live push builds; a push while
    /// nothing is built and the extension is off builds nothing.
    @discardableResult
    static func push(_ live: Bool, into slot: inout CCPoolRuntime?, build: () -> CCPoolRuntime?) -> Task<Void, Never>? {
        if slot == nil, live { slot = build() }
        return slot?.setLive(live)
    }

    /// The production objects, or nil under XCTest: no test run builds them, reads the real
    /// Application Support store, or reaches the Keychain through them.
    static func production() -> CCPoolRuntime? {
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        return CCPoolRuntime(directory: CCPoolStore.defaultDirectory, secrets: CCPoolKeychainSecrets(),
                             config: CCPoolServiceConfig(),
                             vaultURL: CCPoolMigration.vaultURL(home: FileManager.default.homeDirectoryForCurrentUser,
                                                                environment: ProcessInfo.processInfo.environment))
    }
}
