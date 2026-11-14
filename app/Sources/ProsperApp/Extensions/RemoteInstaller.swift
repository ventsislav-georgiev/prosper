import CryptoKit
import Foundation
import os

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
        case cannotPublish(String)

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
            case .cannotPublish(let m):
                return m
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
    /// `extension.toml`. The caller removes the work folder holding it with
    /// `removeWorkFolder(holding:)` after copying the extension out.
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

        // Extract with the system tar (no Foundation gzip/tar reader). Strip the
        // top-level "<repo>-<ref>/" directory codeload always prepends.
        // Same zip-slip/symlink guards as the market path — a GitHub repo is just as
        // untrusted. assertSafeArchive checks RAW entries for `..` (conservative: also
        // covers `repo-ref/../../x`, which --strip-components 1 would turn into `../x`).
        return try extract(data, workName: githubWorkName(repo: source.repo, address: raw),
                           stripTopLevel: true, subdir: source.subdir)
    }

    /// The GitHub download's work folder: the same name for the same address in every launch, so a
    /// folder left by a crash is the one the next install of that address clears (hashValue is seeded
    /// per launch). 16 hex digits of the address's SHA-256.
    static func githubWorkName(repo: String, address raw: String) -> String {
        "prosper-ext-\(repo)-" + SHA256.hash(data: Data(raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
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
    /// caller removes its work folder with `removeWorkFolder(holding:)`.
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
        return try extract(bytes, workName: "prosper-market-\(id)-\(version)", stripTopLevel: false)
    }

    // MARK: - Work folder

    /// Every download gets a work folder directly in the temp folder, named with one of these.
    static let workPrefixes = ["prosper-ext-", "prosper-market-"]
    private static let log = Logger(subsystem: "com.prosper.app", category: "extension")

    /// Writes `data` into a fresh `tempRoot/<workName>` and unpacks it there (see `unpack`). On success
    /// the caller removes the work folder with `removeWorkFolder(holding:)`; on a throw it is removed here.
    static func extract(_ data: Data, workName: String, tempRoot: URL = FileManager.default.temporaryDirectory,
                        stripTopLevel: Bool, subdir: String = "") throws -> URL {
        let work = tempRoot.appendingPathComponent(workName, isDirectory: true)
        // One install per work folder at a time: a second one would clear the folder the first still uses.
        guard inUse.withLock({ $0.insert(work.path).inserted }) else {
            throw InstallError.extractFailed("this extension is already being installed")
        }
        // Clears a leftover of the same name; a name the guard refuses is never written either.
        guard removeWorkFolder(work, tempRoot: tempRoot) else {
            release(work)
            throw InstallError.extractFailed("unexpected download folder name")
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let tarball = work.appendingPathComponent("download.tar.gz")
            try data.write(to: tarball)
            let extractDir = work.appendingPathComponent("src", isDirectory: true)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            return try unpack(tarball, into: extractDir, stripTopLevel: stripTopLevel, subdir: subdir)
        } catch {
            removeWorkFolder(work, tempRoot: tempRoot)
            release(work)
            throw error
        }
    }

    /// Work folders an install of this launch is using, from `extract` until `removeWorkFolder(holding:)`.
    private static let inUse = OSAllocatedUnfairLock(initialState: Set<String>())
    private static func release(_ work: URL) { _ = inUse.withLock { $0.remove(work.path) } }

    /// The temp folder's child that holds `extDir`: the work folder a fetch made, at any sub-folder
    /// depth. nil when `extDir` is not below `tempRoot`.
    static func workFolder(of extDir: URL, tempRoot: URL = FileManager.default.temporaryDirectory) -> URL? {
        let root = tempRoot.pathComponents, parts = extDir.pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return nil }
        return tempRoot.appendingPathComponent(parts[root.count], isDirectory: true)
    }

    /// The installers' cleanup: removes the work folder holding a fetched extension folder, then frees
    /// its name for the next install.
    static func removeWorkFolder(holding extDir: URL, tempRoot: URL = FileManager.default.temporaryDirectory) {
        let work = workFolder(of: extDir, tempRoot: tempRoot) ?? extDir
        removeWorkFolder(work, tempRoot: tempRoot)
        release(work)
    }

    /// Removes `work` only when it is a direct child of `tempRoot` named with a download prefix; any
    /// other path is refused (logged, nothing removed, returns false). `remove` is a test seam; it is
    /// called synchronously on the caller's queue.
    @discardableResult
    static func removeWorkFolder(_ work: URL, tempRoot: URL = FileManager.default.temporaryDirectory,
                                 remove: (URL) -> Void = RemoteInstaller.clearWorkFolder) -> Bool {
        let parts = work.pathComponents, root = tempRoot.pathComponents
        guard parts.count == root.count + 1, Array(parts.dropLast()) == root,
              let name = parts.last, workPrefixes.contains(where: { name.hasPrefix($0) }) else {
            log.error("refused to remove \(work.path, privacy: .public): not a download folder in the temp folder")
            return false
        }
        remove(work)
        return true
    }

    /// Opens every folder inside `work` to its owner first (an archive can leave one unlistable or
    /// read-only), then removes it. A missing folder is not an error.
    static func clearWorkFolder(_ work: URL) {
        var st = stat()
        if lstat(work.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { restoreAccess(work) }
        try? FileManager.default.removeItem(at: work)
    }

    /// chmod 0700 on every real folder below `dir`, top down; a link is never followed.
    private static func restoreAccess(_ dir: URL) {
        guard let list = try? entries(dir) else { return }
        for (name, type) in list where type == S_IFDIR {
            let sub = dir.appendingPathComponent(name)
            chmod(sub.path, 0o700)
            restoreAccess(sub)
        }
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
    /// A name that is not valid UTF-8 goes to `notUTF8` (shown with U+FFFD, called synchronously on the
    /// caller's thread) and is left out; without it, such a name throws "cannot stat" as before.
    /// `names` lists the raw names (readNames; a row adds names APFS cannot hold, #1168).
    private static func entries(_ dir: URL, notUTF8: ((String) -> Void)? = nil,
                                names: (URL) throws -> [[UInt8]] = RemoteInstaller.readNames) throws -> [(name: String, type: mode_t)] {
        var out: [(name: String, type: mode_t)] = []
        for bytes in try names(dir) {
            let (name, exact) = listedName(bytes)
            if name == "." || name == ".." { continue }
            if !exact, let notUTF8 { notUTF8(name); continue }
            var st = stat()
            guard lstat(dir.appendingPathComponent(name).path, &st) == 0 else {
                throw InstallError.extractFailed("cannot stat \(name)")
            }
            out.append((name, st.st_mode & S_IFMT))
        }
        return out
    }

    /// The names in `dir` as readdir lists them, as bytes ("." and ".." included). Nothing is opened but the folder.
    static func readNames(_ dir: URL) throws -> [[UInt8]] {
        guard let d = opendir(dir.path) else {
            throw InstallError.extractFailed("cannot read \(dir.lastPathComponent)")
        }
        defer { closedir(d) }
        var out: [[UInt8]] = []
        // Read through the pointer: a record is only as long as its name, so a dirent copy reads past it.
        let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!
        while let e = readdir(d) {
            let len = min(Int(e.pointee.d_namlen), MemoryLayout<dirent>.size - nameOffset)
            out.append(Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(e) + nameOffset, count: len)))
        }
        return out
    }

    /// A listed name's bytes as text, and whether the text is that name: false when the bytes are not
    /// valid UTF-8 (each bad byte reads U+FFFD, so a path built from the text reaches no file).
    static func listedName<C: Collection>(_ bytes: C) -> (text: String, exact: Bool) where C.Element == UInt8 {
        let text = String(decoding: bytes, as: UTF8.self)
        return (text, text.utf8.elementsEqual(bytes))
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
    /// `confirmed` (#1160): the plan the person confirmed; its members and nothing else are packed, and a
    /// member that changed since (`changedMembers`) stops the publish by name. nil walks the folder now.
    static func packageForPublish(_ dir: URL, plan confirmed: PublishPlan? = nil) throws -> String {
        let plan = confirmed ?? publishPlan(dir)
        if let why = plan.refusal ?? changedMembers(plan.members, in: dir) { throw InstallError.cannotPublish(why) }
        // Fixed owner fields: by default every header names the publisher's account.
        // paxr = bsdtar's default (restricted pax), named so a default change cannot bring
        // GNU @LongLink headers (they carry an owner name).
        return try runTarData(["-czf", "-", "--format", "paxr", "-n", "--no-mac-metadata", "--no-xattrs",
                               "--uid", "0", "--gid", "0", "--uname", "", "--gname", "", "-C", dir.path]
                              + plan.members).base64EncodedString()
    }

    /// The files a publish packs, as "./<relative path>", sorted. The "./" prefix
    /// keeps a name like "-x" or "@x" from reading as a tar option or archive.
    /// shortcut: members go as arguments (ARG_MAX 1 MB); a publish is capped at
    /// 256 KB, so thousands of files never get here — switch to --null -T - if it must.
    static func publishMembers(_ dir: URL) -> [String] { publishPlan(dir).members }

    /// Why the confirmed `members` cannot be packed as confirmed, naming each: gone, unreadable, or no longer
    /// a regular file reached through real folders (a link there would pack something else). nil when all are.
    /// shortcut: tar opens the members a moment after this check; a swap in that moment packs a link entry
    /// (no -H/-L), which every install refuses, or fails tar; an open-by-fd packer would close it.
    static func changedMembers(_ members: [String], in dir: URL) -> String? {
        let changed = members.compactMap { member -> String? in
            let name = String(member.dropFirst(2)), parts = name.split(separator: "/")
            var path = dir.path, st = stat()
            for (i, part) in parts.enumerated() {
                path += "/\(part)"
                guard lstat(path, &st) == 0 else { return name + (errno == EACCES ? " (can't be read)" : " (removed)") }
                let type = st.st_mode & S_IFMT
                if type == S_IFLNK { return name + " (now a symbolic link)" }
                if type != (i == parts.count - 1 ? S_IFREG : S_IFDIR) { return name + " (no longer a regular file)" }
            }
            return nil
        }
        return changed.isEmpty ? nil : "The folder changed after you confirmed the list, so nothing was published: "
            + changed.joined(separator: ", ") + ". Publish again to see the new list."
    }

    /// What a publish of a folder sends, and what stops it (#1141). Paths are relative to the folder.
    struct PublishPlan: Equatable, Sendable {
        var members: [String] = []     // "./<path>", sorted: exactly what the packer sends
        var leftOut = 0                // hidden and test entries not sent; a left-out folder counts once
        var links: [String] = []       // symbolic links: every install refuses an archive holding one
        var unreadable: [String] = []  // folders the walk could not list: their files would go missing
        var notUTF8: [String] = []     // names that are not valid UTF-8 (U+FFFD per bad byte): no path made from them reaches the file
        var notFiles: [String] = []    // #1168: neither a file, a folder nor a link (a pipe, socket or device): never opened

        /// Why this folder cannot be published, naming the files; nil when it can.
        var refusal: String? {
            if !links.isEmpty {
                return "Can't publish symbolic links (every install refuses them): " + links.joined(separator: ", ")
            }
            if !notUTF8.isEmpty {
                return "Can't publish file names that are not valid UTF-8 (\u{FFFD} marks the bytes that can't be shown): "
                    + notUTF8.joined(separator: ", ")
            }
            if !notFiles.isEmpty {
                return "Can't publish items that are not files or folders (a pipe, socket or device): "
                    + notFiles.joined(separator: ", ")
            }
            if !unreadable.isEmpty {
                let one = unreadable.count == 1
                return "Can't read the folder\(one ? "" : "s") " + unreadable.joined(separator: ", ")
                    + ", so \(one ? "its" : "their") files would be left out."
            }
            return members.isEmpty ? "There are no files to publish." : nil
        }
    }

    /// Walks `dir` by readdir + lstat (a link is never followed, "._*" names are seen, a folder it
    /// cannot list is reported instead of skipped). Left-out entries are counted and never entered.
    /// `names` is entries' raw listing (#1168: a row feeds names APFS refuses to create).
    static func publishPlan(_ dir: URL, names: (URL) throws -> [[UInt8]] = RemoteInstaller.readNames) -> PublishPlan {
        var plan = PublishPlan()
        func walk(_ url: URL, _ rel: String) {
            // Runs synchronously inside entries, on this walk's thread. A hidden one is left out like any other.
            var bad: [String] = []
            let named = { (name: String) in
                let path = rel.isEmpty ? name : rel + "/" + name
                if isLeftOutOfPublish(path) { plan.leftOut += 1 } else { bad.append(path) }
            }
            // #1168: a folder that fails part way names only the folder: its bad names are a partial list.
            guard let list = try? entries(url, notUTF8: named, names: names) else {
                plan.unreadable.append(rel.isEmpty ? url.lastPathComponent : rel)
                return
            }
            plan.notUTF8 += bad
            for (name, type) in list {
                let path = rel.isEmpty ? name : rel + "/" + name
                if isLeftOutOfPublish(path) {
                    plan.leftOut += 1
                } else if type == S_IFLNK {
                    plan.links.append(path)
                } else if type == S_IFDIR {
                    walk(url.appendingPathComponent(name, isDirectory: true), path)
                } else if type == S_IFREG {
                    plan.members.append("./" + path)
                } else {
                    plan.notFiles.append(path)
                }
            }
        }
        walk(dir, "")
        plan.members.sort()
        plan.links.sort()
        plan.unreadable.sort()
        plan.notUTF8.sort()
        plan.notFiles.sort()
        return plan
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
