import Darwin
import Foundation

/// #870 (spec 2.1): the three roots. Always injected; tests pass temp dirs.
struct ManagedConfigRoots: Sendable, Equatable {
    /// `claude:` — `$CLAUDE_CONFIG_DIR` from Prosper's login env, else `~/.claude` (errata A11).
    var claude: URL
    /// parent of every `kitconfig:` dir: `~/.config`.
    var configHome: URL
    /// state.json and backups/ (errata C10).
    var stateDir: URL

    /// The only place in ManagedConfig that reads the user's home. `loginEnvironment` is Prosper's
    /// login-shell env (never the process env of a test). Called only by ManagedConfigProvider.live.
    /// A-INFO-12: a set but non-absolute CLAUDE_CONFIG_DIR is refused, never replaced by ~/.claude.
    static func production(loginEnvironment: [String: String]) -> Result<ManagedConfigRoots, ManagedConfigRefusalReason> {
        let dir = loginEnvironment["CLAUDE_CONFIG_DIR"] ?? ""
        guard dir.isEmpty || dir.hasPrefix("/") else { return .failure(.badPath("CLAUDE_CONFIG_DIR is not an absolute path")) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return .success(ManagedConfigRoots(
            claude: dir.isEmpty ? home.appendingPathComponent(".claude", isDirectory: true) : URL(fileURLWithPath: dir, isDirectory: true),
            configHome: home.appendingPathComponent(".config", isDirectory: true),
            stateDir: home.appendingPathComponent("Library/Application Support/Prosper/managed-config", isDirectory: true)))
    }
}

/// A target after the allowlist checks: the file the write goes to (a dotfile-manager symlink is
/// followed, so the link stays a link). Plain value type, no isolation.
struct ManagedConfigResolvedTarget: Sendable, Equatable {
    var root: String
    var rel: String
    var display: String // "claude:CLAUDE.md"
    var url: URL // the real file
    var backupRel: String // "claude/CLAUDE.md", "kitconfig/<slug>/local.md"
    /// `kitconfig:` dir to create (0700, with its `.prosper-kit` owner file) at commit time.
    var kitDir: URL?
}

/// Path allowlist (spec 2.1, errata A8). Pure apart from reading file metadata.
enum ManagedConfigPaths {
    static let kitMarkerFile = ".prosper-kit"
    private static let slugChars = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    private static let idChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    static func isValidID(_ s: String) -> Bool { !s.isEmpty && s.count <= 128 && s.allSatisfy { idChars.contains($0) } }
    static func isValidSlug(_ s: String) -> Bool { !s.isEmpty && s.count <= 64 && s.allSatisfy { slugChars.contains($0) } }

    /// Check 1: a relative path with no `..`, no leading `/`, no NUL, at most 4 components.
    static func checkRelative(_ rel: String) -> ManagedConfigRefusalReason? {
        if rel.isEmpty { return .badPath("empty") }
        if rel.contains("\0") { return .badPath("NUL in path") }
        if rel.hasPrefix("/") { return .badPath("absolute path") }
        if rel.hasPrefix("~") { return .badPath("home-relative path") }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0 == ".." }) { return .badPath("'..' component") }
        if parts.contains(where: { $0.isEmpty || $0 == "." }) { return .badPath("empty or '.' component") }
        if parts.count > 4 { return .badPath("more than 4 components") }
        return nil
    }

    static func resolve(_ target: String, kind: ManagedConfigPiece.Kind, owner: ManagedConfigOwner,
                        roots: ManagedConfigRoots) -> Result<ManagedConfigResolvedTarget, ManagedConfigRefusalReason> {
        guard let colon = target.firstIndex(of: ":") else { return .failure(.badPath("no root prefix")) }
        let root = String(target[..<colon])
        let rel = String(target[target.index(after: colon)...])
        if let bad = checkRelative(rel) { return .failure(bad) }
        let components = rel.split(separator: "/").count

        // Check 4 (cheap, so first): the kind matches the root and the file.
        var base: URL
        var kitDir: URL?
        var backupRel = "\(root)/\(rel)"
        switch root {
        case "claude":
            if rel == "settings.local.json" { return .failure(.localSettings) }
            switch kind {
            case .json:
                guard rel == "settings.json" else { return .failure(.wrongKind("json pieces target claude:settings.json only")) }
            case .block:
                guard components == 1, rel.lowercased().hasSuffix(".md") else {
                    return .failure(.wrongKind("claude: blocks go in a .md file directly under the root"))
                }
            case .seed:
                return .failure(.wrongKind("seed pieces target kitconfig: only"))
            }
            base = roots.claude
        case "kitconfig":
            // A-INFO-5: the owner marker file is never a target, in any case.
            if rel.split(separator: "/").contains(where: { $0.lowercased() == kitMarkerFile }) { return .failure(.badPath("\(kitMarkerFile) is Prosper's")) }
            guard kind != .json else { return .failure(.wrongKind("json pieces target claude:settings.json only")) }
            guard let slug = owner.kitSlug, isValidSlug(slug) else { return .failure(.wrongKind("kitconfig: needs a kit slug [a-z0-9-]+")) }
            base = roots.configHome.appendingPathComponent(slug, isDirectory: true)
            backupRel = "kitconfig/\(slug)/\(rel)"
            switch ownership(of: base, owner: owner.id) {
            case .ours: break
            case .absent: kitDir = base
            case .foreign: return .failure(.foreignDir)
            }
        case "ext":
            return .failure(.wrongKind("ext: is read-only"))
        default:
            return .failure(.badPath("unknown root \(root):"))
        }

        // Check 2: the logical path stays under the root.
        let logical = base.appendingPathComponent(rel)
        let baseStd = base.standardizedFileURL.path
        guard logical.standardizedFileURL.path.hasPrefix(baseStd + "/") else { return .failure(.outsideRoot) }

        // Check 3: real directories stay under the real root; a symlinked file must be ours.
        let realBase = existingPrefixResolved(base)
        let parentReal = existingPrefixResolved(logical.deletingLastPathComponent())
        guard parentReal.path == realBase.path || parentReal.path.hasPrefix(realBase.path + "/") else { return .failure(.outsideRoot) }
        var file = logical
        var st = stat()
        if lstat(logical.path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK {
                file = logical.resolvingSymlinksInPath()
                guard stat(file.path, &st) == 0 else { return .failure(.notRegularFile) }
                guard st.st_uid == getuid() else { return .failure(.symlinkNotOwned) }
                let ext = kind == .json ? "json" : logical.pathExtension.lowercased()
                guard file.pathExtension.lowercased() == ext else { return .failure(.wrongKind("the symlink points to a different file type")) }
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
            guard st.st_uid == getuid() else { return .failure(.unwritable("not your file")) }
            guard access(file.path, W_OK) == 0 else { return .failure(.unwritable("read-only file")) }
        }
        var dir = file.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" { dir = dir.deletingLastPathComponent() }
        guard access(dir.path, W_OK) == 0 else { return .failure(.unwritable("read-only directory")) }
        if root == "claude", !FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) {
            return .failure(.unwritable("the config dir does not exist"))
        }
        return .success(.init(root: root, rel: rel, display: target, url: file.resolvingSymlinksInPath(), backupRel: backupRel, kitDir: kitDir))
    }

    /// `ext:<rel>` read for a seed's source: under the extension dir after resolving symlinks.
    static func readSource(_ source: String, owner: ManagedConfigOwner) -> Result<String, ManagedConfigRefusalReason> {
        guard source.hasPrefix("ext:"), let dir = owner.extensionDir else { return .failure(.invalidPiece("seed source must be ext:<path>")) }
        let rel = String(source.dropFirst(4))
        if let bad = checkRelative(rel) { return .failure(bad) }
        let realDir = dir.resolvingSymlinksInPath()
        let file = dir.appendingPathComponent(rel).resolvingSymlinksInPath()
        guard file.path.hasPrefix(realDir.path + "/") else { return .failure(.outsideRoot) }
        // #1025: String(data:encoding:) may drop a leading BOM; the round trip keeps the copy byte for byte
        // and still refuses bytes that are not UTF-8 (they decode to U+FFFD and differ).
        guard let data = FileManager.default.contents(atPath: file.path) else {
            return .failure(.invalidPiece("seed source is missing or not UTF-8 text"))
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.elementsEqual(data) else { return .failure(.invalidPiece("seed source is missing or not UTF-8 text")) }
        return .success(text)
    }

    enum Ownership { case absent, ours, foreign }

    /// `kitconfig:` rule (spec 2.1): usable only when Prosper created the dir for this owner.
    static func ownership(of dir: URL, owner: String) -> Ownership {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { return .absent }
        guard isDir.boolValue,
              let data = FileManager.default.contents(atPath: dir.appendingPathComponent(kitMarkerFile).path),
              String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == owner else { return .foreign }
        return .ours
    }

    /// Resolves symlinks in the longest existing prefix of `url` and re-appends the rest.
    static func existingPrefixResolved(_ url: URL) -> URL {
        var head = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: head.path), head.path != "/" {
            tail.insert(head.lastPathComponent, at: 0)
            head = head.deletingLastPathComponent()
        }
        var out = head.resolvingSymlinksInPath()
        for t in tail { out.appendPathComponent(t) }
        return out
    }
}

/// The file-writer seam (spec 2.5 step 3): a test wraps it to count writes or to interleave a
/// concurrent write between plan and rename. Sendable struct, no isolation.
protocol ManagedConfigFileWriter: Sendable {
    /// Writes `.<name>.prosper-<uuid>` next to `target` with `mode`, fsync'd. Returns its URL.
    func writeTemp(_ data: [UInt8], besides target: URL, mode: mode_t) throws -> URL
    /// rename(2) over `target`, then fsync the directory.
    func replace(_ target: URL, with temp: URL) throws
}

struct ManagedConfigPOSIXWriter: ManagedConfigFileWriter {
    struct WriteError: Error, CustomStringConvertible {
        var step: String
        var code: Int32
        var description: String { "\(step) failed: \(String(cString: strerror(code)))" }
    }

    func writeTemp(_ data: [UInt8], besides target: URL, mode: mode_t) throws -> URL {
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).prosper-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw WriteError(step: "create temp", code: errno) }
        defer { _ = close(fd) }
        var failure: WriteError?
        if fchmod(fd, mode) != 0 { failure = WriteError(step: "chmod", code: errno) }
        var off = 0
        while failure == nil, off < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + off, data.count - off) }
            if n < 0 { failure = WriteError(step: "write", code: errno) } else { off += n }
        }
        if failure == nil, fsync(fd) != 0 { failure = WriteError(step: "fsync", code: errno) }
        if let failure {
            _ = unlink(temp.path)
            throw failure
        }
        return temp
    }

    func replace(_ target: URL, with temp: URL) throws {
        guard rename(temp.path, target.path) == 0 else { throw WriteError(step: "rename", code: errno) }
        let dfd = open(target.deletingLastPathComponent().path, O_RDONLY)
        if dfd >= 0 {
            _ = fsync(dfd)
            _ = close(dfd)
        }
    }
}
