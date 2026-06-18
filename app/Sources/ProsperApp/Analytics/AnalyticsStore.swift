import Foundation

/// Persistent state for opt-out usage analytics: per-system-extension usage
/// counters, a stable anonymous id, and the last-sent timestamp.
///
/// The anonymous id is a random UUID kept in `~/.config/prosper/analytics.id` —
/// deliberately SEPARATE from the SQLCipher `device.key` so the database key never
/// leaves the machine. It identifies a device across days for "distinct users"
/// counts; it is not derived from and cannot be linked to any personal data.
enum AnalyticsStore {
    private static var defaults: UserDefaults { .standard }

    private enum Keys {
        static let usage = "analyticsExtUsage"      // [extId: Int]
        static let lastSent = "analyticsLastSent"   // Date
    }

    // MARK: - Per-extension usage counters

    /// Bump the usage counter for a system extension. No-op tolerated to be called
    /// from the MainActor command path. Persisted immediately (UserDefaults batches
    /// the disk write).
    /// ponytail: counted per invoke-with-result, so live per-keystroke commands
    /// (calc) over-count vs submit-once ones; relative-usage signal only. Upgrade
    /// path: move the bump to result-accept in CommandRouter if exactness matters.
    static func bumpUsage(extensionID: String) {
        var dict = usageCounts()
        dict[extensionID, default: 0] += 1
        defaults.set(dict, forKey: Keys.usage)
    }

    /// Current per-extension usage counts (system extensions only by construction).
    static func usageCounts() -> [String: Int] {
        defaults.dictionary(forKey: Keys.usage) as? [String: Int] ?? [:]
    }

    // MARK: - Anonymous id

    private static var idFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/prosper/analytics.id")
    }

    /// Stable random anonymous id, created on first read. Lowercased UUID string.
    static func anonID() -> String {
        let url = idFileURL
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fresh.write(to: url, atomically: true, encoding: .utf8)
        return fresh
    }

    // MARK: - Send throttle

    static var lastSent: Date? {
        get { defaults.object(forKey: Keys.lastSent) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastSent) }
    }
}
