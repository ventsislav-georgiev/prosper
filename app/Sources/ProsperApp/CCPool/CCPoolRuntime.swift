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

    init(directory: URL, secrets: CCPoolSecrets, config: CCPoolServiceConfig, vaultURL: URL,
         defaults: UserDefaults = Preferences.defaults, probeBase: URL = CCPoolService.productionUpstream,
         logger: CCPoolLogger = CCPoolOSLog(), trash: @escaping CCPoolMigration.Trash = CCPoolMigration.moveToTrash) {
        store = CCPoolStore(directory: directory, logger: logger)
        self.secrets = secrets
        service = CCPoolService(config: config, store: store, secrets: secrets, logger: logger)
        lifecycle = CCPoolLifecycle(service: service)
        model = CCPoolPaneModel(store: store, secrets: secrets, service: service, logger: logger, defaults: defaults,
                                probeBase: probeBase, vaultURL: vaultURL, trash: trash, lifecycle: lifecycle)
    }

    /// Launch, enable and disable: the proxy follows the extension (and the account list).
    @discardableResult
    func setLive(_ live: Bool) -> Task<Void, Never>? {
        lifecycle.live = live
        return model.reconcileProxy()
    }

    /// The app quits: the listener goes now, and no queued start binds again.
    func quit() {
        lifecycle.live = false
        service.stop()
    }

    // MARK: The app's instance

    /// Built by the first live push (AppDelegate), kept for the life of the process.
    private(set) static var shared: CCPoolRuntime?

    /// AppDelegate's push of the extension's live flag, at launch and on every enable/disable.
    static func setExtensionLive(_ live: Bool) {
        if shared == nil, live { shared = production() }
        shared?.setLive(live)
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
