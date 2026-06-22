import AppKit

/// A single installed application discovered by `AppIndex`.
struct AppEntry: Identifiable, Sendable, Equatable {
    /// Absolute path to the `.app` bundle (stable identity).
    var id: String { url.path }
    let name: String       // display name without the ".app" extension
    let url: URL           // the bundle URL
    let bundleId: String?  // CFBundleIdentifier if readable

    static func == (lhs: AppEntry, rhs: AppEntry) -> Bool { lhs.url == rhs.url }
}

/// Indexes installed applications across the standard macOS locations and ranks
/// them against a query so the runner can surface apps Raycast-style (type a few
/// letters → the app appears, Enter launches it).
///
/// Why an explicit index instead of `NSWorkspace.urlForApplication(...)`: that API
/// resolves a *bundle identifier* or an exact file name, so a user typing a human
/// app name ("System Preferences", "settings", "calc") gets nothing. We enumerate
/// the bundles ourselves, keep their display names, fuzzy-match, and apply an alias
/// table for renamed/aliased system apps (e.g. the old "System Preferences" is now
/// "System Settings" on macOS 13+).
@MainActor
final class AppIndex {
    static let shared = AppIndex()

    private(set) var apps: [AppEntry] = []
    /// Lowercased display names, parallel to `apps`. Precomputed once per index
    /// build so the per-keystroke unified search never re-lowercases ~hundreds of
    /// names (hot path: see `CommandRouter.unifiedSearch`).
    private(set) var appsLower: [String] = []
    private var built = false
    private var lastBuild = Date.distantPast

    /// Directories scanned for `.app` bundles. Top level of each plus the
    /// `Utilities` subfolders — deep recursion is avoided (large apps bundle
    /// dozens of helper `.app`s inside `Contents/`, which must not appear here).
    nonisolated static let searchDirs: [String] = {
        let home = NSHomeDirectory()
        return [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
            (home as NSString).appendingPathComponent("Applications"),
        ]
    }()

    /// Roots whose immediate sub-folders are also scanned one level deep, so apps
    /// that vendors nest in a folder (Setapp, JetBrains Toolbox, Adobe, …) are
    /// found. Only a single level is descended and `.app` bundles are never
    /// entered, so this stays cheap and never surfaces helper apps from inside a
    /// bundle's `Contents/`.
    nonisolated static let nestedRoots: [String] = {
        let home = NSHomeDirectory()
        return [
            "/Applications",
            (home as NSString).appendingPathComponent("Applications"),
        ]
    }()

    /// Individual `.app` bundles that live outside the scanned directories but
    /// users still expect to launch. `/System/Library/CoreServices` itself is not
    /// scanned wholesale — it holds dozens of internal helper apps (Dock,
    /// Spotlight, loginwindow, …) that must not flood the launcher — so the few
    /// user-facing ones are listed explicitly.
    nonisolated static let extraAppPaths: [String] = [
        "/System/Library/CoreServices/Finder.app",
    ]

    /// Maps lowercased human/legacy names to the canonical app name that actually
    /// ships, so familiar terms still resolve. Matched as a whole-query alias.
    nonisolated static let aliases: [String: String] = [
        "system preferences": "System Settings",
        "preferences": "System Settings",
        "settings": "System Settings",
        "control panel": "System Settings",
        "terminal": "Terminal",
        "activity monitor": "Activity Monitor",
        "calculator": "Calculator",
        "calc": "Calculator",
        "files": "Finder",
        "browser": "Safari",
        "mail": "Mail",
        "music": "Music",
        "photos": "Photos",
        "messages": "Messages",
        "notes": "Notes",
        "screenshot": "Screenshot",
        "screen capture": "Screenshot",
    ]

    /// Builds (or rebuilds, if older than `maxAge`) the app index.
    @discardableResult
    func ensureBuilt(maxAge: TimeInterval = 300) -> [AppEntry] {
        if built, Date().timeIntervalSince(lastBuild) < maxAge { return apps }
        apps = Self.scan()
        appsLower = apps.map { $0.name.lowercased() }
        built = true
        lastBuild = Date()
        return apps
    }

    /// Ranked app matches for `query` (best first). Empty when nothing matches.
    func search(_ query: String, limit: Int = 6) -> [AppEntry] {
        Self.rank(query: query, in: ensureBuilt(), limit: limit)
    }

    /// The single best match for `query`, or nil.
    func best(_ query: String) -> AppEntry? { search(query, limit: 1).first }

    /// The full built index plus its parallel lowercased-name array, for callers
    /// that score apps themselves (the unified launcher search merges apps with
    /// quicklinks/bookmarks on one ladder). Both arrays are COW snapshots — cheap
    /// to hand off to an off-main scorer — and the lowercasing is already done.
    func entriesWithLower() -> (apps: [AppEntry], lower: [String]) {
        _ = ensureBuilt()
        return (apps, appsLower)
    }

    /// The canonical app name an alias resolves to (lowercased query in, lowercased
    /// name out), or nil. Lets the unified scorer keep alias hits at the top tier.
    nonisolated static func aliasTarget(for query: String) -> String? {
        aliases[query.trimmingCharacters(in: .whitespaces).lowercased()]?.lowercased()
    }

    // MARK: - Pure helpers (no shared state → unit-testable)

    /// Enumerates `.app` bundles across the standard search directories,
    /// de-duplicating by display name (a user copy in /Applications wins over a
    /// system copy of the same name).
    nonisolated static func scan(dirs: [String] = searchDirs,
                                 nested: [String] = nestedRoots,
                                 extraPaths: [String] = extraAppPaths) -> [AppEntry] {
        let fm = FileManager.default
        var byName: [String: AppEntry] = [:]
        var order: [String] = []

        func add(path: String) {
            guard path.hasSuffix(".app") else { return }
            let url = URL(fileURLWithPath: path)
            let name = String((path as NSString).lastPathComponent.dropLast(4)) // strip ".app"
            let key = name.lowercased()
            guard byName[key] == nil else { return }
            let bundleId = Bundle(url: url)?.bundleIdentifier
            byName[key] = AppEntry(name: name, url: url, bundleId: bundleId)
            order.append(key)
        }

        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                add(path: (dir as NSString).appendingPathComponent(item))
            }
        }
        // One level deep under the nested roots: scan each non-`.app` sub-folder's
        // immediate `.app` children (Setapp, JetBrains Toolbox, vendor folders).
        for root in nested {
            guard let subItems = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for sub in subItems where !sub.hasSuffix(".app") {
                let subDir = (root as NSString).appendingPathComponent(sub)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: subDir, isDirectory: &isDir), isDir.boolValue,
                      let apps = try? fm.contentsOfDirectory(atPath: subDir) else { continue }
                for item in apps where item.hasSuffix(".app") {
                    add(path: (subDir as NSString).appendingPathComponent(item))
                }
            }
        }
        // Explicitly-listed apps outside the scanned dirs (e.g. Finder). Only add
        // ones that actually exist so a removed/renamed bundle is silently skipped.
        for path in extraPaths where fm.fileExists(atPath: path) {
            add(path: path)
        }
        return order.compactMap { byName[$0] }
    }

    /// Ranks `apps` against `query`. Scoring (high → low): whole-query alias hit,
    /// exact name, prefix, word-boundary prefix, substring, fuzzy subsequence.
    /// Non-matches are dropped. Ties break on shorter name (closer match) then
    /// alphabetical for stability.
    nonisolated static func rank(query: String, in apps: [AppEntry], limit: Int) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }

        let aliasTarget = aliases[q]?.lowercased()

        var scored: [(app: AppEntry, score: Int)] = []
        for app in apps {
            let name = app.name.lowercased()
            var score = 0
            if let aliasTarget, name == aliasTarget {
                score = 1000
            } else if name == q {
                score = 900
            } else if name.hasPrefix(q) {
                score = 800 - name.count
            } else if wordPrefixMatch(name: name, query: q) {
                score = 700 - name.count
            } else if name.contains(q) {
                score = 500 - name.count
            } else if isSubsequence(q, of: name) {
                score = 200 - name.count
            } else {
                continue
            }
            scored.append((app, score))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.app.name.count != $1.app.name.count { return $0.app.name.count < $1.app.name.count }
            return $0.app.name < $1.app.name
        }
        return scored.prefix(limit).map(\.app)
    }

    /// True if any space-separated word of `name` starts with `query`
    /// (e.g. "set" → "System **Set**tings"… no; "mid" → "Audio **MID**I Setup").
    nonisolated private static func wordPrefixMatch(name: String, query: String) -> Bool {
        name.split(separator: " ").contains { $0.hasPrefix(query) }
    }

    /// Classic fuzzy subsequence test: are all chars of `needle` found in
    /// `haystack` in order (not necessarily contiguous)?
    nonisolated static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        var next = it.next()
        for ch in needle {
            while let c = next, c != ch { next = it.next() }
            guard next != nil else { return false }
            next = it.next()
        }
        return true
    }
}
