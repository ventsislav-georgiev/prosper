import Foundation

/// Test-only config isolation. Active ONLY when `PROSPER_HOME` is set in the
/// environment — which the e2e `ProsperAppRunner` does and nothing else. It lets a
/// launched dev build read/write a throwaway `~/.config/prosper` and a throwaway
/// UserDefaults suite instead of the real user's, so e2e can seed snippets without
/// touching real data.
///
/// Why this is needed: on macOS `FileManager.homeDirectoryForCurrentUser` resolves
/// via `getpwuid` and IGNORES the `$HOME` env var, and `UserDefaults.standard` /
/// cfprefsd ignore it too — so an isolated `$HOME` alone does NOT redirect either.
/// An explicit override is the only reliable lever. No-ops in normal runs.
enum E2EConfig {
    /// Throwaway config base when running under e2e, else the real home.
    static let home: URL = {
        if let p = ProcessInfo.processInfo.environment["PROSPER_HOME"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// True when an isolated config is in effect.
    static var isolated: Bool {
        if let p = ProcessInfo.processInfo.environment["PROSPER_HOME"] { return !p.isEmpty }
        return false
    }
}
