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
    case unreadable(String)
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
        let text: String
        do {
            text = try String(contentsOf: manifestURL, encoding: .utf8)
        } catch {
            throw ExtensionLoadError.unreadable(error.localizedDescription)
        }
        let manifest: ExtensionManifest
        do {
            manifest = try TOMLDecoder().decode(ExtensionManifest.self, from: text)
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
