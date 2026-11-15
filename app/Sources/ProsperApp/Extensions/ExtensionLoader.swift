import Foundation
import TOMLDecoder

/// A manifest parsed + validated against the host, paired with its on-disk
/// location. Produced by `ExtensionLoader`; the Lua entry point is not yet run.
struct LoadedExtension: Sendable, Equatable {
    let manifest: ExtensionManifest
    let directory: URL
    let isSystem: Bool

    var id: String { manifest.extension.id }
    /// Absolute path to the Lua entry file (loaded lazily on first activation).
    var entryURL: URL { directory.appendingPathComponent(manifest.extension.entry.main) }
}

enum ExtensionLoadError: Error, Equatable {
    case manifestMissing(URL)
    /// Opening or reading the file failed (local, can be transient: not remembered as a refusal of a package).
    case unreadable(String)
    /// The bytes are not valid UTF-8 (a property of the package itself).
    case invalidUTF8(String)
    case parse(String)
    /// Extension requires a newer host than we are.
    case incompatibleHost(need: String, have: String)
    /// Extension targets an API level this host does not implement.
    case unsupportedAPILevel(need: Int, max: Int)
    case entryMissing(String)
}

/// Reads + validates `extension.toml` from a directory. Static-first: this runs
/// at discovery time, before any Lua executes (see docs/ADR-002-extensibility.md).
enum ExtensionLoader {

    /// Highest extension API level this host implements.
    static let supportedAPILevel = 1

    static let manifestFileName = "extension.toml"

    static func load(
        directory: URL,
        isSystem: Bool,
        hostVersion: String
    ) throws -> LoadedExtension {
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExtensionLoadError.manifestMissing(manifestURL)
        }
        let text = try readManifest(manifestURL)
        let manifest: ExtensionManifest
        do {
            manifest = try TOMLDecoder().decodeGuarded(ExtensionManifest.self, from: text)
        } catch {
            throw ExtensionLoadError.parse(String(describing: error))
        }
        try validate(manifest, hostVersion: hostVersion)

        let loaded = LoadedExtension(manifest: manifest, directory: directory, isSystem: isSystem)
        guard FileManager.default.fileExists(atPath: loaded.entryURL.path) else {
            throw ExtensionLoadError.entryMissing(manifest.extension.entry.main)
        }
        return loaded
    }

    /// #883: the one way an extension.toml is read. At most `TOMLGuard.maxBytes + 1` bytes are
    /// read, so a larger file (a 4 MiB market tarball can inflate to any size) is refused with a
    /// reason naming the size limit without being held whole; the nesting cap is `decodeGuarded`.
    /// #1082: through `BoundedFileRead`, so a pipe, socket, device or folder is refused without blocking.
    static func readManifest(_ url: URL) throws -> String {
        let bytes: Data
        do {
            bytes = try BoundedFileRead.data(url, maxBytes: TOMLGuard.maxBytes)
        } catch let failure as BoundedFileRead.Failure {
            if case .tooLarge = failure { throw ExtensionLoadError.parse(failure.description) }
            throw ExtensionLoadError.unreadable(failure.description)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ExtensionLoadError.invalidUTF8("extension.toml is not valid UTF-8")
        }
        return text
    }

    static func validate(_ manifest: ExtensionManifest, hostVersion: String) throws {
        let host = manifest.extension.host
        let hostVer = SemanticVersion(hostVersion)
        // Development / unstamped bundles report 0.0.0 (the scripts/Info.plist
        // placeholder used when PROSPER_VERSION is unset, e.g. a local bundle.sh
        // run). Treat that as a dev host that satisfies any floor so local bundles
        // load every extension; released builds carry a real version and still
        // enforce each extension's min_version.
        let isDevHost = hostVer == SemanticVersion("0.0.0")
        if !isDevHost, hostVer < SemanticVersion(host.min_version) {
            throw ExtensionLoadError.incompatibleHost(need: host.min_version, have: hostVersion)
        }
        if host.api_level > supportedAPILevel {
            throw ExtensionLoadError.unsupportedAPILevel(need: host.api_level, max: supportedAPILevel)
        }
    }
}

/// Minimal semver (major.minor.patch) for host-compatibility checks. Ignores
/// pre-release/build metadata — sufficient for a min-version floor.
struct SemanticVersion: Comparable, Equatable {
    let major: Int, minor: Int, patch: Int

    init(_ string: String) {
        // Strip any pre-release/build suffix, then split numeric components.
        let core = string.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? string
        let parts = core.split(separator: ".").map { Int($0) ?? 0 }
        major = parts.count > 0 ? parts[0] : 0
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}

/// #1082: the one bounded read of a file an extension ships or names. The path is resolved and must be a
/// regular file (a pipe, socket, device or folder is refused without blocking: the open is O_NONBLOCK and the
/// type is checked again on the open descriptor); at most `maxBytes + 1` bytes are read, so a larger file is
/// refused with a reason naming it and the limit, never held whole. One cap per kind:
enum BoundedFileRead {
    /// An extension's entry Lua (ExtensionRegistry's two VM spawns). The largest built-in is 54 KB.
    static let entryLuaMaxBytes = 4 << 20
    /// A contributed theme.json (the marketplace preview). The largest built-in is 1.1 KB.
    static let themeJSONMaxBytes = 1 << 20
    /// host.fs.read (FSReads.read), the cap it already had.
    static let fsReadMaxBytes = 1 << 20
    /// A snippets JSON the user picks to import.
    static let snippetImportMaxBytes = 16 << 20

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case notRegularFile(String)
        case tooLarge(String, limit: Int)
        case invalidUTF8(String)

        var description: String {
            switch self {
            case .unreadable(let why): why
            case .notRegularFile(let name): "\(name) is not a regular file"
            case .tooLarge(let name, let limit): "\(name) is over the \(limit)-byte size limit"
            case .invalidUTF8(let name): "\(name) is not valid UTF-8"
            }
        }
    }

    static func data(_ url: URL, maxBytes: Int) throws -> Data {
        precondition(maxBytes >= 0 && maxBytes < Int.max, "cap out of range")
        let name = url.lastPathComponent, path = url.path
        func unreadable() -> Failure { .unreadable("\(name) can't be read: \(String(cString: strerror(errno)))") }
        var st = stat()
        // stat follows links, so a link to a pipe is refused here too and a device is never opened.
        guard stat(path, &st) == 0 else { throw unreadable() }
        guard st.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile(name) }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw unreadable() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        // Swapped for a pipe between stat and open: the non-blocking open returned at once, refuse it here.
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile(name) }
        let bytes: Data
        do { bytes = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch {
            throw Failure.unreadable("\(name) can't be read: \(error.localizedDescription)")
        }
        guard bytes.count <= maxBytes else { throw Failure.tooLarge(name, limit: maxBytes) }
        return bytes
    }

    static func text(_ url: URL, maxBytes: Int) throws -> String {
        guard let text = String(data: try data(url, maxBytes: maxBytes), encoding: .utf8) else {
            throw Failure.invalidUTF8(url.lastPathComponent)
        }
        return text
    }
}
