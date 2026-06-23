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

    /// The blocking SMAppService registration logic. OFF-MAIN ONLY (run via the
    /// detached task in `ensureRegistered`). Pure status/register IPC — no UI.
    nonisolated private static func registerIfNeeded() -> RegisterOutcome {
        let svc = service
        switch svc.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .needsApproval
        default:
            do {
                try svc.register()
            } catch {
                log.error("lid helper register failed: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
            switch svc.status {
            case .enabled: return .enabled
            case .requiresApproval: return .needsApproval
            default: return .failed
            }
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

    // MARK: - Coalesced apply (last-writer-wins, ordered on the VM thread)

    nonisolated private static let genLock = NSLock()
    nonisolated(unsafe) private static var generation = 0

    /// Bump and return the request generation. Called SYNCHRONOUSLY on the Lua VM
    /// thread (single-threaded → strictly ordered) before dispatching the apply, so
    /// a later request always wins over an earlier one even though the applies run
    /// as independent main-actor tasks with no scheduling order guarantee.
    nonisolated static func nextGeneration() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        generation += 1
        return generation
    }

    /// True iff `gen` is still the most recent request (no later one superseded it).
    nonisolated static func isCurrentGeneration(_ gen: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return gen == generation
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
            if !ok {
                // XPC error: the connection may be dead. Drop it so the next
                // attempt builds a fresh one instead of reusing a corpse (the
                // invalidation handler may not have fired yet).
                c.invalidate()
                if connection === c { connection = nil }
            }
            return ok
        } else {
            guard let c = connection else { return true } // already off
            let ok = await call(c, on: false)
            c.invalidate()
            connection = nil
            return ok
        }
    }

    private static func call(_ c: NSXPCConnection, on: Bool) async -> Bool {
        await withCheckedContinuation { cont in
            let proxy = c.remoteObjectProxyWithErrorHandler { err in
                Self.log.error("lid helper set(\(on)) failed: \(err.localizedDescription, privacy: .public)")
                cont.resume(returning: false)
            } as? LidHelperProtocol
            guard let proxy else { cont.resume(returning: false); return }
            proxy.setLidSleepDisabled(on) { ok in cont.resume(returning: ok) }
        }
    }
}
