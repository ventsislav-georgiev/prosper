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
@MainActor
enum LidSleepHelper {
    nonisolated private static let log = Logger(subsystem: "eu.illegible.prosper", category: "lidhelper")
    private static var connection: NSXPCConnection?

    // nonisolated: stateless (a fresh SMAppService each call, touches no shared
    // mutable state), so PermissionsManager's settings-row check can read it
    // without hopping to the main actor.
    nonisolated private static var service: SMAppService {
        SMAppService.daemon(plistName: "\(lidHelperLabel).plist")
    }

    /// Whether the background item is approved + enabled. Drives the openlid
    /// settings "Background Helper" permission row.
    nonisolated static var isEnabled: Bool { service.status == .enabled }

    /// Register the daemon if needed. Returns true once it is enabled. When macOS
    /// requires the user to OK the background item, opens the Login Items pane and
    /// returns false (the caller surfaces a "approve, then retry" message). Called
    /// from `setDisabled(true)` (first lid-disable) and from the settings permission
    /// row's Open button — i.e. always on explicit user action.
    @discardableResult
    nonisolated static func ensureRegistered() -> Bool {
        let svc = service
        switch svc.status {
        case .enabled:
            return true
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return false
        default:
            do {
                try svc.register()
            } catch {
                log.error("lid helper register failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
            if svc.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return false
            }
            return svc.status == .enabled
        }
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
            guard ensureRegistered() else { return false }
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
