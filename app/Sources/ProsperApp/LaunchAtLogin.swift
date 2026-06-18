import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for "launch at login".
/// Registration only works for a properly bundled, signed `.app`; in a bare
/// `swift run` context it throws/declines, so all calls degrade gracefully.
enum LaunchAtLogin {

    /// Whether the app is currently registered as a login item.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Returns the resulting
    /// state (best-effort: returns the requested value on success, current
    /// status on failure). Persists user intent in `Preferences.launchAtLogin`.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            Preferences.launchAtLogin = enabled
            return enabled
        } catch {
            NSLog("prosper: launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
            return isEnabled
        }
    }

    /// Reconciles the OS registration with the persisted preference on launch.
    static func syncWithPreference() {
        // E2E: never touch the real user's login items (the dev build would
        // register its .build binary, popping a "Login Item Added" notification).
        if E2EConfig.isolated { return }
        let desired = Preferences.launchAtLogin
        if desired != isEnabled {
            setEnabled(desired)
        }
    }
}
