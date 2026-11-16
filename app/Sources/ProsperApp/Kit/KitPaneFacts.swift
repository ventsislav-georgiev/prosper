import Foundation

// #918 S2 (spec 4.6, 4.12 row 8, errata A12): the facts the kit pane shows, as pure functions. Nothing here runs,
// sources or writes anything; file system reads go through the caller's KitDir, arrive as values, or (R1422-i1) are a
// stat/access probe and one bounded read.

enum KitPaneFacts {
    struct Requirement: Equatable, Sendable {
        var name: String
        var found: Bool
    }

    /// Each `requires` name looked up on `path` (the login PATH) through `isExecutable(<dir>/<name>)`: lookup only,
    /// nothing is executed. Only absolute PATH entries are tried (an empty or relative one would be the cwd); a name
    /// that is empty, "." or "..", or holds a "/" is never looked up and reads as not found. R1422-i1: the name is
    /// outside text, so the row holds it as OutsideText shows it (the lookup uses the name as written).
    static func requirements(_ names: [String], path: String, isExecutable: (String) -> Bool) -> [Requirement] {
        let dirs = path.split(separator: ":").filter { $0.hasPrefix("/") }
        return names.map { name in
            let shown = OutsideText.shown(name, max: KitManifest.maxValue)
            guard KitPOSIXDir.isName(name) else { return Requirement(name: shown, found: false) }
            return Requirement(name: shown, found: dirs.contains { isExecutable(String($0) + "/" + name) })
        }
    }

    /// R1422-i1: the production `isExecutable` of requirements: a regular file (a link is followed) the caller may
    /// execute, by stat and access(X_OK) alone; nothing is opened or run.
    static func isExecutable(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

    struct Override: Equatable, Sendable {
        enum Point: String, Sendable { case pre, post }
        /// the tool or hook name (the runner's $3)
        var name: String
        var point: Point
        /// nil: the runner runs it; else why the runner skips it
        var skipped: String?
    }

    /// The `<name>.pre` / `<name>.post` files in the user's hooks dir (`hooks`, opened O_NOFOLLOW by the caller), sorted,
    /// each judged by the runner's own rule: a regular file (a link is not), owned by `uid`, owner-executable, not group-
    /// or world-writable. A name the runner never asks for (its stem not [A-Za-z0-9._-], ".", "..") is not listed.
    /// nil when the dir cannot be listed.
    static func overrides(_ hooks: any KitDir, uid: uid_t) -> [Override]? {
        guard let names = hooks.names() else { return nil }
        return names.compactMap { n in
            let point: Override.Point
            if n.hasSuffix(".pre") { point = .pre } else if n.hasSuffix(".post") { point = .post } else { return nil }
            let stem = String(n.dropLast(point.rawValue.count + 1))
            guard !stem.isEmpty, stem != ".", stem != "..",
                  stem.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) })
            else { return nil }
            return Override(name: stem, point: point, skipped: skipReason(hooks.kind(n), owner: hooks.owner(n), uid: uid))
        }
    }

    private static func skipReason(_ kind: KitFileKind, owner: uid_t?, uid: uid_t) -> String? {
        guard case .file(let mode, _) = kind else { return "not a regular file" }
        guard owner == uid else { return "not yours" }
        guard mode & 0o022 == 0 else { return "group- or world-writable" }
        guard mode & 0o100 != 0 else { return "not executable" }
        return nil
    }

    /// The statusline piece counts as running when it fired within this long (spec 4.6)
    static let hudWindow: TimeInterval = 120

    /// The in-use line from the `fired/<piece>` mtime: nil for a claude-md piece (no runtime signal) or one that never
    /// fired; "HUD running" for a statusline piece that fired within hudWindow; else "last fired N min ago" (a future
    /// mtime reads as 0).
    static func inUse(_ kind: KitManifest.Piece.Kind, fired: Date?, now: Date) -> String? {
        guard kind != .claudeMD, let fired else { return nil }
        let age = now.timeIntervalSince(fired)
        if kind == .statusline, age < hudWindow { return "HUD running" }
        guard age.isFinite else { return nil }
        return "last fired \(Int(min(max(age, 0), 1e12) / 60)) min ago"
    }

    /// Errata A12: `disableAllHooks: true` at the top of a settings.json (the caller passes the user-scope file's bytes).
    /// Read only; anything else (false, absent, not a bool, malformed, not an object) is false.
    static func hooksDisabled(_ settingsJSON: Data) -> Bool {
        let top = (try? JSONSerialization.jsonObject(with: settingsJSON)) as? [String: Any]
        return top?["disableAllHooks"] as? Bool == true
    }

    /// R1422-i1: the user-scope settings.json's cap for hooksDisabled; a larger file reads as false.
    static let settingsJSONMaxBytes = 1 << 20

    /// R1422-i1: hooksDisabled of the file at `url`, read through BoundedFileRead (a regular file, at most
    /// settingsJSONMaxBytes, never a pipe or device). Unreadable, missing or over the cap: false.
    static func hooksDisabled(settingsAt url: URL) -> Bool {
        guard let d = try? BoundedFileRead.data(url, maxBytes: settingsJSONMaxBytes) else { return false }
        return hooksDisabled(d)
    }
}
