import AppKit
import ApplicationServices
import ServiceManagement
import UserNotifications

/// Accessibility trust + System Settings deep links.
enum PermissionsManager {

    /// Returns whether the process is currently trusted for Accessibility.
    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Whether the app currently holds Full Disk Access. There is no preflight API
    /// for FDA, so we probe a known TCC-protected path. `isReadableFile`/`access()`
    /// only sees POSIX permission bits — it does NOT reflect TCC, so it lies (a
    /// 0644 user file reads "readable" with no grant). The only reliable signal is
    /// ATTEMPTING THE READ: TCC blocks `open()` with EPERM until FDA is granted, so
    /// a handle we can actually read a byte from means the grant is live. The user
    /// TCC.db exists on every real account; Safari's bookmarks file is the fallback.
    /// Read-only and cheap; safe on any thread.
    static func hasFullDiskAccess() -> Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory() as NSString
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Safari/Bookmarks.plist"),
        ]
        for path in probes where fm.fileExists(atPath: path) {
            guard let fh = FileHandle(forReadingAtPath: path) else { continue } // EPERM → no FDA
            defer { try? fh.close() }
            if (try? fh.read(upToCount: 1)) != nil { return true }
        }
        return false
    }

    /// Opens the Full Disk Access privacy pane in System Settings.
    static func openFullDiskAccessSettings() {
        openSettings("com.apple.preference.security?Privacy_AllFiles")
    }

    // MARK: - Extension-declared permissions

    /// Whether a named extension permission (manifest / settings `permission`
    /// control) is currently granted. Unknown names read as not granted.
    static func isGranted(_ permission: String) -> Bool {
        switch permission {
        case "full-disk-access": return hasFullDiskAccess()
        case "accessibility": return isAccessibilityTrusted()
        // openlid's privileged lid-sleep daemon: "granted" == the SMAppService
        // background item is approved + enabled (System Settings → Login Items).
        case "lid-helper": return LidSleepHelper.isEnabled
        default: return false
        }
    }

    /// Opens System Settings to the pane for a named extension permission.
    static func openSettings(forPermission permission: String) {
        switch permission {
        case "full-disk-access": openFullDiskAccessSettings()
        case "accessibility": openAccessibilitySettings()
        case "screen-recording": openScreenRecordingSettings()
        // Registers the daemon if needed (first time) and opens Login Items so the
        // user can approve it. ensureRegistered() opens the pane itself when the
        // status is .requiresApproval; do it unconditionally here too in case it
        // is already registered but the user toggled it off.
        case "lid-helper":
            // ensureRegistered runs the blocking SMAppService work off-main and
            // opens Login Items itself when approval is needed; always surface the
            // pane so the user can manage it even when already registered.
            Task { @MainActor in
                _ = await LidSleepHelper.ensureRegistered()
                SMAppService.openSystemSettingsLoginItems()
            }
        default: break
        }
    }

    /// Human-readable label for a permission key (for the Settings UI).
    static func label(forPermission permission: String) -> String {
        switch permission {
        case "full-disk-access": return "Full Disk Access"
        case "accessibility": return "Accessibility"
        case "screen-recording": return "Screen Recording"
        case "lid-helper": return "Background Helper"
        default: return permission
        }
    }

    /// Why an extension needs this permission — shown as the row subtitle
    /// regardless of grant state (the badge reports granted/not). Extensions can
    /// override with their own `subtitle`.
    static func reason(forPermission permission: String) -> String {
        switch permission {
        case "full-disk-access": return "Lets Prosper read the Safari bookmarks file; other browsers import without it."
        case "accessibility": return "Lets Prosper read the focused window and post the keystrokes that drive shortcuts."
        case "screen-recording": return "Lets Prosper capture on-screen text for OCR-based features."
        case "lid-helper": return "A privileged login item applies the lid-closed sleep override (needs a one-time approval)."
        default: return "Required for this extension to function."
        }
    }

    /// Reports whether the app may currently post user notifications. `.authorized`
    /// and `.provisional` both count as granted; `.denied`/`.notDetermined` do not.
    static func notificationStatus() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Returns whether trusted, optionally prompting the user with the system
    /// dialog if not yet trusted.
    @discardableResult
    static func ensureAccessibilityTrust(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt is "AXTrustedCheckOptionPrompt"; referenced
        // by literal to avoid the non-Sendable global under Swift 6 checking.
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The app's bundle identifier, used to target `tccutil` resets.
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "eu.illegible.prosper" }

    /// Clears this app's TCC grant for a privacy service via `tccutil reset`,
    /// so the caller can re-request a fresh grant. Fixes the "toggle is ON but
    /// the app still isn't trusted" state: an ad-hoc-signed rebuild has a new
    /// code signature, so macOS's existing grant (keyed to the old signature)
    /// no longer matches the running binary. Resetting purges the stale entry
    /// and a fresh grant binds to the current binary. `service` is the TCC key
    /// (e.g. "Accessibility"). No-op (returns false) in unbundled CLI runs with
    /// no bundle identifier.
    @discardableResult
    static func resetPrivacyGrant(service: String) -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Opens the Accessibility privacy pane in System Settings.
    static func openAccessibilitySettings() {
        openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    /// Opens the Screen Recording privacy pane (needed for vision context).
    static func openScreenRecordingSettings() {
        openSettings("com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// Opens the Notifications pane in System Settings.
    static func openNotificationSettings() {
        openSettings("com.apple.preference.notifications")
    }

    private static func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
