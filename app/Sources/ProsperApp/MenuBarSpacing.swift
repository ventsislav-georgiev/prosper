import AppKit
import Foundation

/// Controls the global menu-bar icon spacing via the two hidden `NSStatusItem`
/// UserDefaults keys (current-host, global domain). The values are only read by
/// each app when it *builds* its status item, so a change only takes effect when
/// an app next launches — applying live means relaunching menu-bar apps, which is
/// data-loss-class and therefore strictly opt-in (see `relaunchOwners`).
@MainActor
enum MenuBarSpacing {
    /// macOS stock value for both keys. Writing this == removing the override.
    /// Nonisolated: pure constants referenced from the nonisolated `MenuBarStore`
    /// / `MenuBarLogic` math (which has no business hopping to the main actor).
    nonisolated static let defaultSpacing = 16
    nonisolated static let minSpacing = 0
    nonisolated static let maxSpacing = 32

    private static let spacingKey = "NSStatusItemSpacing"
    private static let paddingKey = "NSStatusItemSelectionPadding"

    /// Whether a non-default spacing override is currently written.
    static func isOverridden() -> Bool {
        readCurrentHostGlobal(spacingKey) != nil
    }

    /// Write (or clear) the override for the requested absolute spacing. Returns
    /// the value written, or nil if it cleared the override (spacing == default).
    /// Does NOT relaunch anything — the change applies as apps next launch.
    @discardableResult
    static func apply(spacing: Int) -> Int? {
        let value = MenuBarLogic.spacingDefaultsValue(forSpacing: spacing)
        if let value {
            writeCurrentHostGlobal(spacingKey, value)
            writeCurrentHostGlobal(paddingKey, value)
        } else {
            deleteCurrentHostGlobal(spacingKey)
            deleteCurrentHostGlobal(paddingKey)
        }
        return value
    }

    /// Apps that own a menu-bar item right now AND that we can actually relaunch, for
    /// the relaunch UI to enumerate. On macOS 26 (Tahoe) the window server attributes
    /// every item to Control Center (pid 800), so this collapses to nothing
    /// relaunchable — the caller detects the empty result and tells the user to log
    /// out / relaunch apps themselves instead of silently doing nothing.
    static func owningApps() -> [NSRunningApplication] {
        let selfPID = getpid()
        let skip: Set<String> = ["com.apple.controlcenter", "com.apple.Spotlight"]
        let pids = Set(MenuBarBridge.items(onDisplay: CGMainDisplayID()).map(\.pid))
        return pids.filter { $0 != 0 && $0 != selfPID }
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { !skip.contains($0.bundleIdentifier ?? "") }
    }

    /// DATA-LOSS-SAFE live apply (opt-in only, explicit confirm in the UI).
    /// Gracefully asks each owning app to quit and relaunches the ones that
    /// comply. NEVER force-terminates a third-party app — an app with unsaved
    /// work that refuses to quit is SKIPPED and reported back via `onSkipped`,
    /// so the user can quit it themselves. Control Center / Spotlight self-relaunch.
    static func relaunchOwners(_ apps: [NSRunningApplication],
                               onSkipped: @escaping ([String]) -> Void) {
        let skipManaged: Set<String> = ["com.apple.controlcenter", "com.apple.Spotlight"]
        var skipped: [String] = []
        let group = DispatchGroup()

        for app in apps {
            let bid = app.bundleIdentifier ?? ""
            if app.processIdentifier == getpid() { continue }
            if skipManaged.contains(bid) { continue }      // self-relaunches; leave it
            guard let url = app.bundleURL else { continue }

            group.enter()
            let terminated = app.terminate()               // graceful only — never forceTerminate
            if !terminated {
                skipped.append(app.localizedName ?? bid)
                group.leave()
                continue
            }
            // Poll for clean exit, then relaunch. Bounded async checks (no spin).
            waitForExit(app, attempts: 20, interval: 0.1) { exited in
                if exited {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = false
                    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
                } else {
                    skipped.append(app.localizedName ?? bid)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { onSkipped(skipped) }
    }

    // MARK: - Private

    private static func waitForExit(_ app: NSRunningApplication, attempts: Int, interval: TimeInterval,
                                    done: @escaping (Bool) -> Void) {
        if app.isTerminated { done(true); return }
        guard attempts > 0 else { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            waitForExit(app, attempts: attempts - 1, interval: interval, done: done)
        }
    }

    private static func readCurrentHostGlobal(_ key: String) -> Int? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
    }

    private static func writeCurrentHostGlobal(_ key: String, _ value: Int) {
        CFPreferencesSetValue(key as CFString, value as CFNumber, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                 kCFPreferencesCurrentHost)
    }

    private static func deleteCurrentHostGlobal(_ key: String) {
        CFPreferencesSetValue(key as CFString, nil, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                 kCFPreferencesCurrentHost)
    }
}
