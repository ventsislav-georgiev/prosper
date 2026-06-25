import Foundation
import ServiceManagement
import LidHelperProtocol
import os

/// Client for the privileged lid-sleep helper daemon (`ProsperLidHelper`). It is
/// what makes "keep awake with the lid closed" work with NO sudoers entry: the
/// daemon flips `pmset -a disablesleep` as root, and this type registers it via
/// SMAppService and drives it over XPC.
///
/// Everything here is LAZY and opt-in. Nothing is registered at app launch — the
/// daemon is installed only the first time the openlid extension actually asks to
/// disable lid sleep (`set_disable_lid_sleep(true)`). If that never happens (user
/// disabled openlid, or never toggled it on), no background item is ever created.
/// The connection's lifetime mirrors the override: turning it off tears the
/// connection down, the daemon resets the setting and idle-exits → zero resident
/// memory when unused. A crash drops the connection, so the daemon never leaves
/// the lid wedged awake.
///
/// THREADING: every `SMAppService` call here (`.status`, `.register()`) is a
/// SYNCHRONOUS IPC to `smd` that can block for many seconds when the service
/// database is busy or the item awaits approval. Those calls must NEVER run on
/// the main thread or the Lua VM thread — doing so froze the whole app (settings
/// spinner stuck, openlid toast/shortcut dead). So: status reads are served from
/// a persisted cache (`isEnabled`, instant + non-blocking, refreshed off-main),
/// and registration runs on a detached background task.
@MainActor
enum LidSleepHelper {
    nonisolated private static let log = Logger(subsystem: "eu.illegible.prosper", category: "lidhelper")
    private static var connection: NSXPCConnection?

    // nonisolated: stateless (a fresh SMAppService each call, touches no shared
    // mutable state), so it can run on any background thread.
    nonisolated private static var service: SMAppService {
        SMAppService.daemon(plistName: "\(lidHelperLabel).plist")
    }

    // MARK: - Cached status (never blocks the caller)

    nonisolated private static let cacheKey = "prosper.lidHelper.enabled"
    nonisolated private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cacheLoaded = false
    nonisolated(unsafe) private static var cachedEnabled = false
    nonisolated(unsafe) private static var refreshInFlight = false

    /// Whether the background item is approved + enabled. Drives the openlid
    /// settings "Background Helper" permission row.
    ///
    /// Returns the last-known value INSTANTLY (persisted across launches) and kicks
    /// a single background refresh of the real `smd` status. It never blocks — the
    /// `.status` IPC that used to stall the settings row for ~a minute now happens
    /// off-main, and the row reads the cache. A first-ever launch reads `false`
    /// until the first refresh lands; the Re-check button forces a fresh read.
    nonisolated static var isEnabled: Bool {
        cacheLock.lock()
        if !cacheLoaded {
            cachedEnabled = UserDefaults.standard.bool(forKey: cacheKey)
            cacheLoaded = true
        }
        let value = cachedEnabled
        let kick = !refreshInFlight
        if kick { refreshInFlight = true }
        cacheLock.unlock()
        if kick { Task.detached(priority: .utility) { _ = refreshEnabled() } }
        return value
    }

    /// Blocking `SMAppService.status` read. OFF-MAIN ONLY. Updates + persists the
    /// cache. Returns the fresh value.
    @discardableResult
    nonisolated static func refreshEnabled() -> Bool {
        let v = (service.status == .enabled)
        storeCache(v)
        return v
    }

    nonisolated private static func storeCache(_ v: Bool) {
        cacheLock.lock()
        cachedEnabled = v
        cacheLoaded = true
        refreshInFlight = false
        cacheLock.unlock()
        UserDefaults.standard.set(v, forKey: cacheKey)
    }

    // MARK: - Registration (off-main)

    private enum RegisterOutcome { case enabled, needsApproval, failed }

    // SMAppService pins the daemon registration to the bundle version present at
    // register() time. A Sparkle in-place update swaps the binary but NOT the
    // registration → launchd refuses to spawn the new daemon (exits EX_CONFIG 78,
    // KeepAlive crash-loops it) and every XPC call dies silently. status stays
    // .enabled, so we'd otherwise never re-register. Track the version we last
    // registered and force a fresh unregister+register on drift.
    nonisolated private static let registeredVersionKey = "prosper.lidHelper.registeredVersion"
    nonisolated private static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
    }
    // Serialize registration: launch-heal, openlid on_launch re-arm, the settings
    // Re-check button, and a feature toggle can all call registerIfNeeded() on
    // separate detached tasks at once. Without this they'd race unregister()+
    // register() on the same item — the loser's register() throws "already
    // registered" → .failed → spurious Login Items popup + cache flicker. The lock
    // makes the second caller re-read the now-healed status (version already stored)
    // and no-op. ponytail: held across the blocking smd IPC (rare, off-main).
    nonisolated private static let registerLock = NSLock()

    /// The blocking SMAppService registration logic. OFF-MAIN ONLY (run via the
    /// detached task in `ensureRegistered`). Pure status/register IPC — no UI.
    nonisolated private static func registerIfNeeded() -> RegisterOutcome {
        registerLock.lock()
        defer { registerLock.unlock() }
        let svc = service
        // Stale-registration self-heal: enabled but registered under a different app
        // version means a Sparkle in-place update swapped the daemon binary out from
        // under launchd's pinned registration → EX_CONFIG crash-loop, both features
        // dead. Drop it and force a fresh register so launchd re-pins to this binary.
        // We do NOT re-read status after unregister() to route — SMAppService status
        // can lag the unregister, and a stale .enabled read would make us record the
        // new version + return enabled WITHOUT re-registering, killing the daemon for
        // good. So the drift path always calls forceRegister.
        if svc.status == .enabled,
           UserDefaults.standard.string(forKey: registeredVersionKey) != currentVersion {
            try? svc.unregister()
            return forceRegister(svc)
        }
        switch svc.status {
        case .enabled:
            UserDefaults.standard.set(currentVersion, forKey: registeredVersionKey)
            return .enabled
        case .requiresApproval:
            return .needsApproval
        default:
            return forceRegister(svc)
        }
    }

    /// register() + classify the resulting status. Records the registered version on
    /// success so the drift check above stays quiet until the next update.
    nonisolated private static func forceRegister(_ svc: SMAppService) -> RegisterOutcome {
        do {
            try svc.register()
        } catch {
            // ponytail: a drift unregister that hasn't landed yet can make this throw
            // "already registered"; we return .failed and retry on the next launch/toggle
            // rather than thrash. The daemon stays as-is (crash-looping but registered).
            log.error("lid helper register failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        switch svc.status {
        case .enabled:
            UserDefaults.standard.set(currentVersion, forKey: registeredVersionKey)
            return .enabled
        case .requiresApproval: return .needsApproval
        default: return .failed
        }
    }

    /// Register the daemon if needed, running the blocking SMAppService work on a
    /// background task so a slow `smd` cannot freeze the app. Returns true once
    /// enabled. When macOS needs the user to OK the background item, opens the
    /// Login Items pane (on main) and returns false. Called from `setDisabled(true)`
    /// and the settings permission row's Open button — always on explicit action.
    @discardableResult
    static func ensureRegistered() async -> Bool {
        let outcome = await Task.detached(priority: .userInitiated) { registerIfNeeded() }.value
        switch outcome {
        case .enabled:
            storeCache(true)
            return true
        case .needsApproval:
            storeCache(false)
            SMAppService.openSystemSettingsLoginItems()
            return false
        case .failed:
            storeCache(false)
            return false
        }
    }

    /// Heal a stale post-update daemon registration at app launch, regardless of
    /// which (if any) feature is re-applied this session. on_launch re-arms lid
    /// sleep — which heals via `ensureRegistered` — but NOT remote-wake, so a
    /// remote-wake-only user would otherwise never self-heal after a Sparkle update
    /// (stale registration → launchd EX_CONFIG crash-loop, both features dead).
    ///
    /// NEVER registers anything for a user who hasn't enabled lid-sleep or
    /// remote-wake: the cached `isEnabled` flag is false for them (instant, no smd
    /// IPC) so we return before touching SMAppService. We only ever re-pin an item
    /// that is ALREADY registered (`.enabled`); an enabled-then-disabled user keeps
    /// their registration (disable doesn't unregister) so it's re-pinned harmlessly
    /// and the daemon just idle-exits. A `.requiresApproval` item is left for the
    /// explicit toggle path to surface. This call never opens Login Items — it
    /// drives `registerIfNeeded` directly, not `ensureRegistered`, so the rare
    /// re-approval case stays silent at launch and surfaces on next settings/toggle.
    nonisolated static func healStaleRegistrationOnLaunch() {
        guard isEnabled else { return }   // cached: false for never-enabled → no IPC, no registration
        Task.detached(priority: .utility) {
            guard service.status == .enabled else { return }   // real status; skip pending-approval / removed
            _ = registerIfNeeded()   // version match → no-op; drift → unregister+register
        }
    }

    // MARK: - Serial apply chain (order-preserving, non-blocking, drops nothing)

    nonisolated private static let chainLock = NSLock()
    nonisolated(unsafe) private static var applyChain: Task<Void, Never> = Task {}

    /// Enqueue a lid-override apply. The chain is appended SYNCHRONOUSLY on the
    /// caller's thread (the single-threaded Lua VM → strict call order), and each op
    /// awaits the previous one, so set(true)/set(false) apply in exactly the order
    /// issued and NONE are dropped. This replaced a last-writer-wins coalescer that
    /// could silently drop a pending set(true) when any set(false) followed it
    /// (launch stale-reset, teardown, a quick unplug/replug) — which left the Mac
    /// sleeping on lid close despite the override being "on". Returns immediately;
    /// the VM never blocks on the privileged XPC / SMAppService IPC.
    nonisolated static func enqueueApply(_ op: @escaping @Sendable () async -> Void) {
        chainLock.lock()
        let prev = applyChain
        applyChain = Task { await prev.value; await op() }
        chainLock.unlock()
    }

    private static func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: lidHelperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: LidHelperProtocol.self)
        let clear: () -> Void = { Task { @MainActor in if connection === c { connection = nil } } }
        c.invalidationHandler = clear
        c.interruptionHandler = clear
        c.resume()
        return c
    }

    /// Set the clamshell-sleep override. `on == true` lazily registers + launches
    /// the daemon and opens the connection; `on == false` clears it and tears the
    /// connection down (daemon resets + idle-exits). Returns whether it took effect.
    @discardableResult
    static func setDisabled(_ on: Bool) async -> Bool {
        if on {
            guard await ensureRegistered() else { return false }
            let c = connection ?? makeConnection()
            connection = c
            let ok = await call(c, on: true)
            if ok {
                holdsLidOverride = true
            } else {
                // XPC error: the connection may be dead. Drop it so the next
                // attempt builds a fresh one instead of reusing a corpse (the
                // invalidation handler may not have fired yet).
                c.invalidate()
                if connection === c { connection = nil }
            }
            return ok
        } else {
            holdsLidOverride = false
            guard let c = connection else { return true } // already off
            let ok = await call(c, on: false)
            // Keep the connection alive if remote-wake still needs the daemon.
            if !remoteWakeEnabled {
                c.invalidate()
                connection = nil
            }
            return ok
        }
    }

    private static func call(_ c: NSXPCConnection, on: Bool) async -> Bool {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            // @Sendable strips @MainActor isolation from these handlers. They run on
            // NSXPCConnection's private dispatch queue; without it they'd inherit the
            // enum's @MainActor isolation and SIGTRAP on Swift's executor check
            // (`dispatch_assert_queue`) when XPC calls them off-main. `once` is the
            // only captured state and is thread-safe.
            let proxy = c.remoteObjectProxyWithErrorHandler { @Sendable err in
                Self.log.error("lid helper set(\(on)) failed: \(err.localizedDescription, privacy: .public)")
                once.resume(false)
            } as? LidHelperProtocol
            guard let proxy else { once.resume(false); return }
            once.armTimeout()
            proxy.setLidSleepDisabled(on) { @Sendable ok in once.resume(ok) }
        }
    }

    /// Resume a checked continuation exactly once, with a hard timeout. A daemon that
    /// has idle-exited (or is mid-relaunch, or speaks an older protocol missing the
    /// called selector) may invoke NEITHER the reply block NOR the error handler — the
    /// `await` would then hang forever and, because these calls run on the serial
    /// `enqueueApply` chain, wedge every later op (re-toggle dead, meta never written).
    /// ponytail: 6s ceiling; bump only if a real daemon legitimately replies slower.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var cont: CheckedContinuation<Bool, Never>?
        init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
        func resume(_ v: Bool) {
            lock.lock(); let c = done ? nil : cont; done = true; cont = nil; lock.unlock()
            c?.resume(returning: v)
        }
        func armTimeout() {
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in self?.resume(false) }
        }
    }

    // MARK: - Remote wake

    /// Push the remote-wake config to the daemon (JSON of a sanitized
    /// `RemoteWakeConfig`). Enabling lazily registers + launches the daemon exactly
    /// like the lid override; disabling sends the disabled config so the daemon
    /// stops polling and idle-exits (no connection teardown needed — the daemon owns
    /// its own residency). Returns whether remote-wake is now resident.
    @discardableResult
    static func setRemoteWake(_ config: RemoteWakeConfig) async -> Bool {
        if config.enabled {
            guard await ensureRegistered() else { return false }
        }
        let c = connection ?? makeConnection()
        connection = c
        let resident = await callRemoteWake(c, json: config.jsonString())
        remoteWakeEnabled = resident
        // When remote-wake is off AND no lid override holds the connection, drop it
        // so we don't pin a corpse; the daemon idle-exits on its side.
        if !resident && !holdsLidOverride {
            c.invalidate()
            if connection === c { connection = nil }
        }
        return resident
    }

    /// Connection-lifetime bookkeeping: the daemon stays resident if EITHER feature
    /// needs it, so turning one off must not tear down a connection the other uses.
    nonisolated(unsafe) private static var holdsLidOverride = false
    nonisolated(unsafe) private static var remoteWakeEnabled = false

    private static func callRemoteWake(_ c: NSXPCConnection, json: String) async -> Bool {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            // @Sendable: same reason as `call(_:on:)` — these fire on the connection's
            // own queue and must not inherit @MainActor isolation.
            let proxy = c.remoteObjectProxyWithErrorHandler { @Sendable err in
                Self.log.error("remote wake set failed: \(err.localizedDescription, privacy: .public)")
                once.resume(false)
            } as? LidHelperProtocol
            guard let proxy else { once.resume(false); return }
            once.armTimeout()
            proxy.setRemoteWake(json) { @Sendable resident in once.resume(resident) }
        }
    }
}
