import Foundation

/// #1857: textviewer.open {path}: opens a file in Text Viewer's read mode (an already open window for that file is
/// focused as it is). Read-only for the file, but it opens a window, so a path that holds a secret is refused whole:
/// key, credential, .env, keychain and ssh paths, anything under ~/.ssh, ~/.aws, ~/.gnupg or a ~/.config entry named
/// for a token, plus anything that is not a regular file or is over the viewer's own size cap. The path is judged
/// before and after symlinks, so a link into a refused place is refused. On demand only: one stat, no watcher, no poll.
/// shortcut: the name check is a deny list, extend it when another secret file shows up.
@MainActor
enum ControlTextViewer {
    /// Seam: the viewer's own open (TextViewerWindows.open). The real window never opens under XCTest; rows swap in a recorder.
    static var open: @MainActor (URL) -> Void = { url in
        guard NSClassFromString("XCTestCase") == nil else { return }
        TextViewerWindows.shared.open(url)
    }
    /// Seam: the home folder the deny list is rooted at.
    static var home: () -> String = { NSHomeDirectory() }

    static let secretSuffixes = [".pem", ".key", ".p12", ".pfx", ".p8", ".keychain", ".keychain-db", ".kdbx"]
    static let secretDirs: Set<String> = [".ssh", ".aws", ".gnupg"]
    static let secretWords = ["credential", "keychain", "secret"]
    static let sshKeyNames = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    static let secretFiles: Set<String> = [".netrc", ".npmrc", ".pgpass"]

    /// Why `path` (absolute, standardized) is off limits by name, or nil.
    static func nameRefusal(_ path: String, home: String) -> String? {
        let parts = path.split(separator: "/").map { String($0).lowercased() }
        let homeParts = home.split(separator: "/").map { String($0).lowercased() }
        let under = parts.starts(with: homeParts) ? Array(parts.dropFirst(homeParts.count)) : []
        if parts.contains(where: secretDirs.contains) { return "a key or credential folder (.ssh, .aws, .gnupg)" }
        if under.first == "library", under.dropFirst().first == "keychains" { return "the keychain" }
        if under.first == ".config", under.dropFirst().first?.contains("token") == true { return "a token" }
        for p in parts {
            if p.hasPrefix(".env") { return "an .env file" }
            if secretSuffixes.contains(where: p.hasSuffix) { return "a key file" }
            if secretWords.contains(where: p.contains) { return "a credential or keychain path" }
            if sshKeyNames.contains(where: p.hasPrefix) { return "an ssh key" }
            if secretFiles.contains(p) { return "a credential file" }
        }
        return nil
    }

    /// The URL to open, or the refusal. `home` is the folder the deny list is rooted at.
    static func check(_ raw: String, home: String) throws -> URL {
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
        var st = stat()
        guard stat(resolved.path, &st) == 0 else { throw ControlError("no such file: \(OutsideText.shown(raw, max: 200))") }
        guard st.st_mode & S_IFMT == S_IFREG else { throw ControlError("not a regular file") }
        guard st.st_size >= 0, st.st_size <= Int64(TextViewerDocument.maxBytes) else {
            throw ControlError("the file is over \(TextViewerDocument.maxBytes >> 20) MiB, the viewer's limit")
        }
        return url
    }

    /// A visible effect (a window), so it goes through `.change`: refused while the Settings switch is off, with a notice
    /// and a log line. No undo: closing the person's view is not one we offer.
    static func run(_ args: [String: ControlJSON]) throws -> ControlChange {
        let url = try check(try ControlSessions.required(args, "path"), home: home())
        open(url)
        let shown = OutsideText.shown(url.path, max: 200)
        return ControlChange(summary: shown, result: .object(["opened": .string(shown)]), verb: "opened a file in Text Viewer")
    }

    nonisolated static let command = ControlCommand.change(
        name: "textviewer.open", summary: "Open a file in Text Viewer's read mode (refuses key, credential, .env and ssh paths, non-regular files and files over the viewer's size cap).",
        args: ["path": ControlArg(type: "string", required: true, summary: "Absolute path (or ~/...) of the file to read.")]) { _, a in try run(a) }
}
