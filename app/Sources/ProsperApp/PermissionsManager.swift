import AppKit
import ApplicationServices
import IOKit
import IOKit.hidsystem
import UserNotifications

/// Accessibility trust + System Settings deep links.
enum PermissionsManager {

    /// Returns whether the process is currently trusted for Accessibility.
    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Returns whether the process is granted Input Monitoring (CGEventTap /
    /// keystroke listening). Uses the HID access API; `.granted` means allowed.
    /// `.unknown`/`.denied` both read as not-yet-granted for the onboarding gate.
    static func isInputMonitoringTrusted() -> Bool {
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Prompts for Input Monitoring access (shows the system dialog once).
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
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
        case "input-monitoring": return isInputMonitoringTrusted()
        default: return false
        }
    }

    /// Opens System Settings to the pane for a named extension permission.
    static func openSettings(forPermission permission: String) {
        switch permission {
        case "full-disk-access": openFullDiskAccessSettings()
        case "accessibility": openAccessibilitySettings()
        case "input-monitoring": openInputMonitoringSettings()
        case "screen-recording": openScreenRecordingSettings()
        default: break
        }
    }

    /// Human-readable label for a permission key (for the Settings UI).
    static func label(forPermission permission: String) -> String {
        switch permission {
        case "full-disk-access": return "Full Disk Access"
        case "accessibility": return "Accessibility"
        case "input-monitoring": return "Input Monitoring"
        case "screen-recording": return "Screen Recording"
        default: return permission
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
    /// and a fresh grant binds to the current binary. `service` is the TCC key:
    /// "Accessibility" or "ListenEvent" (Input Monitoring). No-op (returns
    /// false) in unbundled CLI runs with no bundle identifier.
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

    /// Opens the Input Monitoring privacy pane in System Settings.
    static func openInputMonitoringSettings() {
        openSettings("com.apple.preference.security?Privacy_ListenEvent")
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
