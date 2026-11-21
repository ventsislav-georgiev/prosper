import Foundation

/// #1857: textviewer.open {path}: opens a file in Text Viewer's read mode (an already open window for that file is
/// focused as it is). Read-only for the file, but it opens a window, so a path that holds a secret is refused whole:
/// key, credential, .env, keychain and ssh paths, anything under ~/.ssh, ~/.aws, ~/.gnupg or a ~/.config entry named
/// for a token, plus anything that is not a regular file or is over the viewer's own size cap. The path is judged
/// before and after symlinks, so a link into a refused place is refused. On demand only: one stat, no watcher, no poll.
/// #1857 n175: on top of the deny list, only plain-text types open (an allow list; an extensionless file only outside
/// every dot-folder), the resolved path is what opens, and a file with a second name (a hard link) is refused.
/// n176: the check (stat, symlinks) runs off main, so a hung network mount never freezes the app; only the open is on main.
/// n174: the window comes up quietly (on screen, not key, Prosper not activated): the person keeps the keyboard.
/// shortcut: a binary .plist passes the allow list (the viewer shows it as it does any file), sniff it if that matters.
@MainActor
enum ControlTextViewer {
    /// Seam: the viewer's own open (TextViewerWindows.open). The real window never opens under XCTest; rows swap in a recorder.
    static var open: @MainActor (URL) -> Void = { url in
        guard NSClassFromString("XCTestCase") == nil else { return }
        openQuietly(url, in: .shared)
    }
    /// The agent's open: never the person's `present` (n174). Rows call it on a TextViewerWindows with recorder seams.
    static func openQuietly(_ url: URL, in windows: TextViewerWindows) { windows.open(url, quietly: true) }
    /// Seam: the home folder the deny list is rooted at.
    static var home: () -> String = { NSHomeDirectory() }

    nonisolated static let secretSuffixes = [".pem", ".key", ".p12", ".pfx", ".p8", ".keychain", ".keychain-db", ".kdbx"]
    nonisolated static let secretDirs: Set<String> = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".ccpool"]
    nonisolated static let secretWords = ["credential", "keychain", "secret", "password", "bitwarden", "lastpass", "keepass"]
    nonisolated static let sshKeyNames = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    nonisolated static let secretFiles: Set<String> = [".netrc", ".npmrc", ".pgpass", ".pypirc", ".git-credentials", "auth.json",
                                                       "supporter.dat"]
    /// Folders under home refused whole (lowercased components): app tokens, browser profiles, Prosper's own state.
    nonisolated static let secretHomePaths: [[String]] = [
        [".config", "gh"], [".config", "gcloud"], [".config", "dch"], [".config", "prosper"], ["personal", "ccpool"],
        ["library", "application support", "google", "chrome"], ["library", "application support", "firefox"],
        ["library", "application support", "safari"], ["library", "safari"],
        ["library", "application support", "prosper"], ["library", "preferences"],
    ]
    /// n175: the plain-text types that open (lowercased extensions).
    nonisolated static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "json", "jsonl", "yaml", "yml", "toml", "csv", "tsv", "xml", "html", "css", "js", "ts",
        "swift", "py", "rb", "go", "rs", "c", "h", "m", "cpp", "hpp", "java", "kt", "sh", "zsh", "lua", "sql", "ini", "conf",
        "cfg", "plist", "diff", "patch",
    ]

    /// Why `path` is not a plain-text type, or nil: its extension is on the allow list, or it has none and no component
    /// (the name included) starts with a dot.
    nonisolated static func typeRefusal(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let name = parts.last else { return "not a file" }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return textExtensions.contains(name[name.index(after: dot)...].lowercased()) ? nil : "not a plain-text file type"
        }
        return parts.contains(where: { $0.hasPrefix(".") }) ? "an extensionless file in a hidden folder" : nil
    }

    /// Why `path` (absolute, standardized) is off limits by name, or nil.
    nonisolated static func nameRefusal(_ rawPath: String, home: String) -> String? {
        // The APFS firmlink spells the same file with this prefix and would skip the home-anchored rules (n182); only the judged name is stripped, never the path that opens.
        let path = rawPath.hasPrefix("/System/Volumes/Data/") ? String(rawPath.dropFirst("/System/Volumes/Data".count)) : rawPath
        let parts = path.split(separator: "/").map { String($0).lowercased() }
        let homeParts = home.split(separator: "/").map { String($0).lowercased() }
        let under = parts.starts(with: homeParts) ? Array(parts.dropFirst(homeParts.count)) : []
        if parts.contains(where: secretDirs.contains) { return "a key or credential folder (.ssh, .aws, .gnupg)" }
        if under.first == "library", under.dropFirst().first == "keychains" { return "the keychain" }
        if under.first == ".config", under.dropFirst().first?.contains("token") == true { return "a token" }
        if secretHomePaths.contains(where: { under.starts(with: $0) }) { return "an app's token, browser or settings folder" }
        for p in parts {
            if p.hasPrefix(".env") { return "an .env file" }
            if secretSuffixes.contains(where: p.hasSuffix) { return "a key file" }
            if secretWords.contains(where: p.contains) { return "a credential or keychain path" }
            if sshKeyNames.contains(where: p.hasPrefix) { return "an ssh key" }
            if secretFiles.contains(p) { return "a credential file" }
        }
        return nil
    }

    /// The resolved URL to open, or the refusal. `home` is the folder the deny list is rooted at. Off main (n176).
    nonisolated static func check(_ raw: String, home: String) throws -> URL {
        guard raw.unicodeScalars.allSatisfy({ !OutsideText.isUnseen($0) }) else {
            throw ControlError("the path has a control or hidden character")
        }
        let expanded = raw == "~" || raw.hasPrefix("~/") ? home + raw.dropFirst() : raw
        guard expanded.hasPrefix("/") else { throw ControlError("give an absolute path (or one starting with ~/)") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        let homes = [home, URL(fileURLWithPath: home).resolvingSymlinksInPath().path]
        for (p, h) in [(url.path, homes[0]), (url.path, homes[1]), (resolved.path, homes[0]), (resolved.path, homes[1])] {
            if let why = nameRefusal(p, home: h) { throw ControlError("refused: \(why); open it yourself") }
        }
        for p in [url.path, resolved.path] {
            if let why = typeRefusal(p) { throw ControlError("refused: \(why) (plain text only); open it yourself") }
        }
        var st = stat()
        guard stat(resolved.path, &st) == 0 else { throw ControlError("no such file: \(OutsideText.shown(raw, max: 200))") }
        guard st.st_mode & S_IFMT == S_IFREG else { throw ControlError("not a regular file") }
        // A second name may sit in a refused place: the deny list only saw this one.
        guard st.st_nlink <= 1 else { throw ControlError("refused: the file has another name (a hard link); open it yourself") }
        guard st.st_size >= 0, st.st_size <= Int64(TextViewerDocument.maxBytes) else {
            throw ControlError("the file is over \(TextViewerDocument.maxBytes >> 20) MiB, the viewer's limit")
        }
        return resolved
    }

    /// A visible effect (a window), so it goes through `.change`: refused while the Settings switch is off, with a notice
    /// and a log line. No undo: closing the person's view is not one we offer.
    static func run(_ args: [String: ControlJSON]) async throws -> ControlChange {
        let raw = try ControlSessions.required(args, "path"), home = home()
        let url = try await Task.detached(priority: .userInitiated) { try check(raw, home: home) }.value
        // The switch was checked before the await: a flip during the off-main check lands here, before the window.
        guard Preferences.agentControlEnabled else { throw ControlError(ControlChanges.offError) }
        open(url)
        let shown = OutsideText.shown(url.path, max: 200)
        return ControlChange(summary: shown, result: .object(["opened": .string(shown)]), verb: "opened a file in Text Viewer")
    }

    /// As ControlCommand.change (switch-gated, notice, log line, no undo), awaited: reply(to:) calls runAsync, never run.
    nonisolated static let command = ControlCommand(
        name: "textviewer.open", summary: "Open a plain-text file in Text Viewer's read mode, without taking focus (refuses key, credential, token, browser and settings paths, other file types, hard links, non-regular files and files over the viewer's size cap).",
        args: ["path": ControlArg(type: "string", required: true, summary: "Absolute path (or ~/...) of the file to read.")],
        mutates: true, run: { _, _ in throw ControlError("textviewer.open checks the file off main: send it through the control channel") },
        runAsync: { reg, a in
            let c = try await run(a)
            reg.changes.record(command: "textviewer.open", summary: c.summary, verb: c.verb, undo: c.undo)
            return c.result
        })
}
