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
        try runTar(["-xzf", tarball.path, "-C", extractDir.path, "--strip-components", "1"])

        // Resolve the extension directory (root or declared subdir) and confirm
        // its manifest exists.
        let extDir = source.subdir.isEmpty
            ? extractDir
            : extractDir.appendingPathComponent(source.subdir, isDirectory: true)
        let manifest = extDir.appendingPathComponent(ExtensionLoader.manifestFileName)
        guard fm.fileExists(atPath: manifest.path) else {
            throw InstallError.manifestNotFound(subdir: source.subdir)
        }
        return extDir
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
