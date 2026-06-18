import Foundation

/// App version, read from the bundle's `Info.plist` (stamped at bundle time by
/// `scripts/bundle.sh`). Returns "dev" for unbundled `swift run` builds where no
/// `Info.plist` version is present.
enum AppInfo {

    /// Marketing version, e.g. "2.19.0". "dev" when unbundled.
    static var shortVersion: String {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !v.isEmpty else { return "dev" }
        return v
    }

    /// Build number (monotonic integer), or nil when unbundled.
    static var buildNumber: String? {
        guard let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              !b.isEmpty else { return nil }
        return b
    }

    /// Display string, e.g. "2.19.0 (1234)" or just "2.19.0" / "dev".
    static var displayVersion: String {
        if let build = buildNumber, shortVersion != "dev" {
            return "\(shortVersion) (\(build))"
        }
        return shortVersion
    }
}
