import CryptoKit
import Foundation

/// Installs an extension from a GitHub URL pointing at a repo (or a sub-directory
/// of a repo) that contains an `extension.toml`. Downloads the repo tarball via
/// codeload, extracts it to a temp dir, locates the manifest, and hands the
/// directory to `ExtensionRegistry.installLocal`. No git binary required.
/// See docs/ADR-002-extensibility.md (D9 — remote install).
enum RemoteInstaller {

    enum InstallError: Error, LocalizedError, Equatable {
        case unsupportedURL(String)
        case downloadFailed(String)
        case extractFailed(String)
        case manifestNotFound(subdir: String)
        case integrityFailed(String)
        case unsafeArchive(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedURL(let u):
                return "Not a recognized GitHub repository URL: \(u)"
            case .downloadFailed(let m):
                return "Download failed: \(m)"
            case .extractFailed(let m):
                return "Could not unpack the download: \(m)"
            case .manifestNotFound(let sub):
                return "No extension.toml found\(sub.isEmpty ? " in the repo root" : " under \(sub)")."
            case .integrityFailed(let m):
                return "Integrity check failed: \(m)"
            case .unsafeArchive(let m):
                return "Refused to extract an unsafe archive: \(m)"
            }
        }
    }

    /// A parsed GitHub location: which repo, which ref (branch/tag/HEAD), and the
    /// optional sub-directory inside it holding the extension.
    struct Source: Equatable {
        let owner: String
        let repo: String
        let ref: String      // branch / tag, or "HEAD"
        let subdir: String   // "" = repo root
    }

    /// Parse the GitHub URL forms we accept:
    ///   https://github.com/owner/repo
    ///   https://github.com/owner/repo.git
    ///   https://github.com/owner/repo/tree/<ref>/<path/to/ext>
    ///   git@github.com:owner/repo.git
    static func parse(_ raw: String) -> Source? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Normalize scp-style SSH remotes to a path we can split.
        s = s.replacingOccurrences(of: "git@github.com:", with: "https://github.com/")

        guard let host = URL(string: s)?.host, host == "github.com" || host == "www.github.com",
              let comps = URL(string: s)?.pathComponents else { return nil }

        // pathComponents starts with "/"; drop it.
        let parts = comps.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        // The subdir becomes a path under the extraction dir: no "..", ".", empty part,
        // or "/" inside a part (pathComponents decodes %2e%2e and %2F per part).
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") }) else {
            return nil
        }

        let owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }

        // /tree/<ref>/<subdir...>
        if parts.count >= 4, parts[2] == "tree" {
            let ref = parts[3]
            let subdir = parts.dropFirst(4).joined(separator: "/")
            return Source(owner: owner, repo: repo, ref: ref, subdir: subdir)
        }
        return Source(owner: owner, repo: repo, ref: "HEAD", subdir: "")
    }

    /// Download + extract the repo, returning the local directory that contains
    /// `extension.toml`. The caller owns the returned directory's parent temp
    /// tree and should remove it after copying the extension out.
    static func fetch(_ raw: String) async throws -> URL {
        guard let source = parse(raw) else { throw InstallError.unsupportedURL(raw) }

        // codeload serves a gzipped tarball for any ref. HEAD resolves to the
        // default branch.
        let tarURL = URL(string:
            "https://codeload.github.com/\(source.owner)/\(source.repo)/tar.gz/\(source.ref)")!

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: tarURL)
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.downloadFailed("HTTP \(http.statusCode)")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("prosper-ext-\(source.repo)-\(abs(raw.hashValue))", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let tarball = work.appendingPathComponent("download.tar.gz")
        try data.write(to: tarball)

        // Extract with the system tar (no Foundation gzip/tar reader). Strip the
        // top-level "<repo>-<ref>/" directory codeload always prepends.
        let extractDir = work.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        // Same zip-slip/symlink guards as the market path — a GitHub repo is just as
        // untrusted. assertSafeArchive checks RAW entries for `..` (conservative: also
        // covers `repo-ref/../../x`, which --strip-components 1 would turn into `../x`).
        return try unpack(tarball, into: extractDir, stripTopLevel: true, subdir: source.subdir)
    }

    // MARK: - Marketplace install

    /// The exact message the server's Ed25519 signature covers. Must match
    /// `server/src/market.ts` `claimMessage` byte-for-byte.
    static func marketClaimMessage(
        id: String, version: String, sha256: String, publisherEmail: String, publishedAt: Int
    ) -> String {
        ["prosper-market-v1", id, version, sha256, publisherEmail, String(publishedAt)]
            .joined(separator: "\n")
    }

    /// Download an extension from the marketplace, verify its integrity (sha256)
    /// and authenticity (Ed25519 signature over the claim, bound to id/version),
    /// then extract it to a temp dir and return that dir for `installLocal`. The
    /// caller owns the returned directory's parent temp tree.
    static func fetchFromMarket(id: String, version: String) async throws -> URL {
        let dl: MarketClient.Download
        do {
            dl = try await MarketClient.download(id: id, version: version)
        } catch {
            throw InstallError.downloadFailed((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription)
        }

        // The signed claim must describe the listing we actually asked for —
        // otherwise a swap could serve another package's bytes under this id.
        guard dl.id == id, dl.version == version else {
            throw InstallError.integrityFailed("served \(dl.id)@\(dl.version), expected \(id)@\(version)")
        }
        // Bound the encoded payload before decoding so a hostile/huge response
        // can't force a multi-MB allocation (base64 expands ~4/3 over raw).
        guard dl.blob.utf8.count <= 6 * 1_048_576 else {
            throw InstallError.unsafeArchive("encoded artifact too large (\(dl.blob.utf8.count) bytes)")
        }
        guard let bytes = Data(base64Encoded: dl.blob), !bytes.isEmpty else {
            throw InstallError.integrityFailed("empty or undecodable artifact")
        }
        // Bound size before doing any work with the bytes (defense-in-depth; the
        // server already caps publishes far below this).
        guard bytes.count <= 4 * 1_048_576 else {
            throw InstallError.unsafeArchive("artifact too large (\(bytes.count) bytes)")
        }

        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard sha == dl.sha256.lowercased() else {
            throw InstallError.integrityFailed("sha256 mismatch")
        }

        let message = marketClaimMessage(
            id: dl.id, version: dl.version, sha256: dl.sha256,
            publisherEmail: dl.publisher_email, publishedAt: dl.published_at)
        guard SupporterToken.verifyDetached(signatureB64URL: dl.signature, message: message) else {
            throw InstallError.integrityFailed("bad signature")
        }

        // Write + extract. Market tarballs are packaged from the extension dir's
        // contents (extension.toml at the archive root), so no strip is needed.
        let fm = FileManager.default
        // ponytail: stable temp path per (id,version) — the caller's defer cleans it
        // on success; on a mid-fetch throw the next install of the same id+version
        // wipes it here. Worst case is one stale dir per failed (id,version), in
        // NSTemporaryDirectory (OS-reaped). Not worth clean-on-throw plumbing.
        let work = fm.temporaryDirectory.appendingPathComponent("prosper-market-\(id)-\(version)", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let tarball = work.appendingPathComponent("download.tar.gz")
        try bytes.write(to: tarball)

        let extractDir = work.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        return try unpack(tarball, into: extractDir, stripTopLevel: false)
    }

    /// The extraction both install paths share: zip-slip check, extract, refuse a
    /// symlink anywhere, resolve the extension dir (`subdir` under the root), confirm
    /// its manifest, then drop the hidden members inside that dir only (a GitHub
    /// subdir may itself sit under ".config/"). `stripTopLevel` drops codeload's
    /// `<repo>-<ref>/` dir. Hidden members are skipped, not refused: a repo holds
    /// .gitignore/.github, and Marketplace archives packed by Prosper before #1131
    /// carry .DS_Store, "._" metadata or agent state: clutter, not an attack.
    static func unpack(_ tarball: URL, into dir: URL, stripTopLevel: Bool, subdir: String = "") throws -> URL {
        try assertSafeArchive(tarball)
        try runTar(["-xzf", tarball.path, "-C", dir.path] + (stripTopLevel ? ["--strip-components", "1"] : []))
        try assertNoSymlinks(dir)
        let extDir = try extensionDir(in: dir, subdir: subdir)
        try removeHiddenMembers(extDir)
        return extDir
    }

    /// `root` or `root/<subdir>`, holding a manifest and really under `root`. The second
    /// line behind assertNoSymlinks: a link anywhere on the way would resolve outside.
    static func extensionDir(in root: URL, subdir: String) throws -> URL {
        let extDir = subdir.isEmpty ? root : root.appendingPathComponent(subdir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: extDir.appendingPathComponent(ExtensionLoader.manifestFileName).path) else {
            throw InstallError.manifestNotFound(subdir: subdir)
        }
        let r = root.resolvingSymlinksInPath().path, e = extDir.resolvingSymlinksInPath().path
        guard e == r || e.hasPrefix(r + "/") else {
            throw InstallError.unsafeArchive("extension folder leads outside the download: \(subdir)")
        }
        return extDir
    }

    /// The one hidden-name rule (publish and install): true when any component of
    /// the relative path starts with "." (".omc/x", "a/.DS_Store", "._x", "...").
    /// The root "." alone is not a hidden name.
    static func isHiddenMember(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 != "." && $0.hasPrefix(".") }
    }

    /// Every name in `dir` with its lstat file type: a link reads as a link, never
    /// followed. readdir, not FileManager: FileManager listings omit "._*" names.
    private static func entries(_ dir: URL) throws -> [(name: String, type: mode_t)] {
        guard let d = opendir(dir.path) else {
            throw InstallError.extractFailed("cannot read \(dir.lastPathComponent)")
        }
        defer { closedir(d) }
        var out: [(name: String, type: mode_t)] = []
        while let e = readdir(d) {
            let ent = e.pointee
            let len = Int(ent.d_namlen)
            let name = withUnsafeBytes(of: ent.d_name) { String(decoding: $0.prefix(len), as: UTF8.self) }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard lstat(dir.appendingPathComponent(name).path, &st) == 0 else {
                throw InstallError.extractFailed("cannot stat \(name)")
            }
            out.append((name, st.st_mode & S_IFMT))
        }
        return out
    }

    /// Removes every hidden file and folder under `dir`, at any depth; recurses into
    /// real folders only (a link is removed or left, never entered).
    static func removeHiddenMembers(_ dir: URL) throws {
        for (name, type) in try entries(dir) {
            let url = dir.appendingPathComponent(name)
            if isHiddenMember(name) {
                try FileManager.default.removeItem(at: url)
            } else if type == S_IFDIR {
                try removeHiddenMembers(url)
            }
        }
    }

    /// List the archive entries and refuse any that would escape the extraction
    /// directory (absolute paths or `..` traversal — zip-slip guard).
    private static func assertSafeArchive(_ tarball: URL) throws {
        let listing = try runTarCapture(["-tzf", tarball.path])
        for raw in listing.split(whereSeparator: \.isNewline) {
            let entry = String(raw)
            if let reason = unsafeEntryReason(entry) {
                throw InstallError.unsafeArchive("\(reason): \(entry)")
            }
        }
    }

    /// Pure zip-slip predicate (no I/O, unit-testable): an entry that would escape
    /// the extraction root via an absolute path, `~`, or `..` traversal. Returns
    /// nil for safe entries, else a human-readable reason.
    static func unsafeEntryReason(_ entry: String) -> String? {
        if entry.hasPrefix("/") || entry.hasPrefix("~") { return "absolute path" }
        if entry.split(separator: "/").contains("..") { return "path traversal" }
        return nil
    }

    /// Defense-in-depth on the one attack surface (extraction): reject any
    /// symlink in the extracted tree. A symlink pointing outside the extension
    /// dir could later be written-through to escape it; `assertSafeArchive`
    /// blocks `..` entries pre-extraction, this blocks the symlink vector.
    private static func assertNoSymlinks(_ root: URL) throws {
        // Every name, "._*" included (a FileManager walk missed those).
        for (name, type) in try entries(root) {
            if type == S_IFLNK { throw InstallError.unsafeArchive("symlink: \(name)") }
            if type == S_IFDIR { try assertNoSymlinks(root.appendingPathComponent(name)) }
        }
    }

    /// Package an extension directory's CONTENTS (extension.toml at the archive
    /// root) into a gzipped tarball, base64-encoded — the publish payload. Mirrors
    /// `fetchFromMarket`'s extraction (`-xzf` with no strip).
    /// An explicit member list, not tar patterns: `--exclude '.*'` matches the root
    /// "." and empties the archive. --no-mac-metadata/--no-xattrs keep macOS from
    /// adding "._x" AppleDouble members and xattr records (provenance, quarantine).
    static func packageForPublish(_ dir: URL) throws -> String {
        // Fixed owner fields: by default every header names the publisher's account.
        // paxr = bsdtar's default (restricted pax), named so a default change cannot bring
        // GNU @LongLink headers (they carry an owner name).
        try runTarData(["-czf", "-", "--format", "paxr", "-n", "--no-mac-metadata", "--no-xattrs",
                        "--uid", "0", "--gid", "0", "--uname", "", "--gname", "", "-C", dir.path]
                       + publishMembers(dir)).base64EncodedString()
    }

    /// The files a publish packs, as "./<relative path>", sorted. The "./" prefix
    /// keeps a name like "-x" or "@x" from reading as a tar option or archive.
    /// shortcut: members go as arguments (ARG_MAX 1 MB); a publish is capped at
    /// 256 KB, so thousands of files never get here — switch to --null -T - if it must.
    static func publishMembers(_ dir: URL) -> [String] {
        guard let en = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        var members: [String] = []
        for case let rel as String in en
        where !isLeftOutOfPublish(rel) && en.fileAttributes?[.type] as? FileAttributeType != .typeDirectory {
            members.append("./" + rel)
        }
        return members.sorted()
    }

    /// Hidden files and folders at any depth, plus the dev-only test files
    /// (scripts/test-extensions.sh): *.test.lua and any `tests` folder.
    static func isLeftOutOfPublish(_ path: String) -> Bool {
        isHiddenMember(path) || path.hasSuffix(".test.lua") || path.split(separator: "/").contains("tests")
    }

    /// Run `tar` and return its raw stdout bytes (binary-safe, for packaging).
    private static func runTarData(_ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw InstallError.extractFailed(error.localizedDescription)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "tar exited \(process.terminationStatus)"
            throw InstallError.extractFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    /// Run `tar` and return its stdout (used for listing entries).
    private static func runTarCapture(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw InstallError.extractFailed(error.localizedDescription)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "tar exited \(process.terminationStatus)"
            throw InstallError.extractFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Lossy, never "": one non-UTF-8 name used to blank the whole listing and
        // let every entry past assertSafeArchive.
        return String(decoding: data, as: UTF8.self)
    }

    private static func runTar(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InstallError.extractFailed(error.localizedDescription)
        }
        if process.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar exited \(process.terminationStatus)"
            throw InstallError.extractFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
