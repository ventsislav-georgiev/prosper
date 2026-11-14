import Foundation
import os

// Phase 6 §Q — filesystem reads + path watching for extensions. Reads (`FSReads`)
// are pure FileManager queries. Watching (`ExtensionFSWatch`) owns per-extension
// FSEventStreams and, on change, re-invokes a NAMED Lua handler with a JSON payload
// — the same stateless event model as timers/menus. Streams are torn down when the
// extension is disabled/reset (via `removeAll`).

/// Pure filesystem reads (no watching). nonisolated — safe from the worker lane.
enum FSReads {
    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }

    /// { exists, isDir, size, mtime (epoch seconds) } for `path`; { exists=false }
    /// when missing. JSON string.
    static func attributesJSON(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else {
            return #"{"exists":false}"#
        }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: p)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let obj: [String: Any] = [
            "exists": true, "isDir": isDir.boolValue, "size": size, "mtime": Int(mtime),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return #"{"exists":true}"# }
        return s
    }

    /// UTF-8 contents of a text file, or nil (missing / too big / not UTF-8).
    /// Capped so a stray huge file can't blow the VM's memory — an init.lua and its
    /// requires are kilobytes.
    static func read(_ path: String, maxBytes: Int = 1 << 20) -> String? {
        let p = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)), data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// #921 (operator ruling OQ-70): secret paths an extension below the system tier cannot read,
/// list, stat, watch or find through the host. The extension host asks `denies` before each such
/// call and answers a refused one exactly like a missing path. The system tier is never checked.
enum SecretPaths {
    /// Relative to the home dir; each covers the path itself and everything below it.
    /// Adding a path is one line.
    static let listed = [
        ".ssh",
        "Library/Keychains",
        ".ccpool",
        ".config/mcpbridge",
        ".claude/settings.json",
        ".aws",
        ".gnupg",
        ".netrc",
        ".git-credentials",
        ".npmrc",
        ".config/gh",
        ".config/gcloud",
        ".kube",
        ".docker/config.json",
        ".claude.json",
        ".claude/.credentials.json",
        ".config/prosper/device.key",
        ".config/prosper/supporter.dat",
    ]

    /// Seam: tests point it at a temp home. Under XCTest the default is a path that does not
    /// exist, so no test stats a real secret path by accident.
    nonisolated(unsafe) static var home: String = NSClassFromString("XCTestCase") != nil
        ? (NSTemporaryDirectory() as NSString).appendingPathComponent("prosper-xctest-no-home")
        : NSHomeDirectory()

    /// The variable naming ccpool's vault folder. Kept here so this filter does not depend on the
    /// pool module; ExtensionSecretPathsTests pins it to the pool's own name.
    static let ccpoolHomeVariable = "CCPOOL_HOME"

    /// Seam for `ccpoolHomeVariable`. The process environment in the app, empty under XCTest.
    nonisolated(unsafe) static var environment: [String: String] = NSClassFromString("XCTestCase") != nil
        ? [:] : ProcessInfo.processInfo.environment

    private static let logger = Logger(subsystem: "com.prosper.app", category: "extension")

    /// Seam: where a refusal line goes. A test captures the lines; the app logs a notice.
    nonisolated(unsafe) static var log: (String) -> Void = { SecretPaths.logger.notice("\($0, privacy: .public)") }

    /// Seam: called with each path `canonical` resolves (the unit of the filter's cost). Nil in the app.
    nonisolated(unsafe) static var onCanonical: ((String) -> Void)?

    /// Distinct refused paths that get a notice line in one VM; past it refusals stay silent.
    static let noticeCap = 64

    /// The secret roots and the volume's case rule, resolved once for a batch of paths (the roots
    /// are case-folded here, once). Never kept across calls: a root can become a symlink later.
    struct Matcher {
        let roots: [String]
        let caseInsensitive: Bool

        init(roots: [String], caseInsensitive: Bool) {
            self.caseInsensitive = caseInsensitive
            self.roots = caseInsensitive ? roots.map { $0.lowercased() } : roots
        }

        /// True when `path` is a root or below one, judged on the file the kernel would open:
        /// tilde expanded, then symlinks and ".." resolved, case-folded on a case-insensitive volume.
        func denies(_ path: String) -> Bool {
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { return false }
            let real = SecretPaths.canonical(expanded)
            let p = caseInsensitive ? real.lowercased() : real
            return roots.contains { SecretPaths.isAtOrBelow(p, $0) }
        }
    }

    /// Resolves every listed path under `home`, plus CCPOOL_HOME when it is an absolute path after
    /// tilde expansion (a relative or empty value adds nothing).
    static func matcher() -> Matcher {
        var paths = listed.map { (home as NSString).appendingPathComponent($0) }
        if let pool = environment[ccpoolHomeVariable].map({ ($0 as NSString).expandingTildeInPath }),
           pool.hasPrefix("/") {
            paths.append(pool)
        }
        let fold = (try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames != true
        return Matcher(roots: paths.map(canonical), caseInsensitive: fold)
    }

    /// One path: resolves the roots for this call only. Batches use `matcher()` once.
    static func denies(_ path: String) -> Bool { matcher().denies(path) }

    /// `path` is `root` or below it; a sibling sharing only a prefix (".sshfoo") is not.
    static func isAtOrBelow(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// realpath(3) when the path exists; else realpath of its folder plus the name (a file just
    /// deleted or not yet made: the common FSEvents case, two syscalls); else the longest existing
    /// prefix resolved. Then the two spellings of one file are folded: the data volume's firmlinks
    /// (/System/Volumes/Data/Users is /Users, and realpath keeps that spelling) and /private:
    /// realpath spells /private/var/x while NSURL.resolvingSymlinksInPath (the last branch) drops
    /// /private, so a path two levels missing below an existing root under /private (a home in
    /// /var, e.g. /var/root, and every test home) would not match its root.
    static func canonical(_ path: String) -> String {
        onCanonical?(path)
        let reader = KitPOSIXFileReader(), ns = path as NSString
        var p = reader.realPath(path)
            ?? reader.realPath(ns.deletingLastPathComponent).map { ($0 as NSString).appendingPathComponent(ns.lastPathComponent) }
            ?? FilePaths.existingPrefixResolved(URL(fileURLWithPath: path)).path
        for prefix in ["/System/Volumes/Data", "/private"] where p.hasPrefix(prefix + "/") {
            p.removeFirst(prefix.count)
        }
        return p
    }

    /// Drops the `host.files.search` hits whose "path" is a secret path. Unreadable JSON → "[]".
    static func filterHits(_ json: String) -> String {
        guard let hits = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return "[]" }
        let m = matcher()
        let kept = hits.filter { !m.denies(($0["path"] as? String) ?? "") }
        guard kept.count < hits.count else { return json }
        guard let data = try? JSONSerialization.data(withJSONObject: kept) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The one log line of a refusal: the extension id and the call, never the path or any file data.
    static func logRefusal(extensionID: String, call: String) {
        log("\(extensionID): host.\(call) refused a secret path")
    }
}

/// Live registry of extension path watchers. A watch fires the named handler with
/// payload `{ paths = [changed…] }`. MainActor-bound; streams delivered on the main
/// queue. The `invoke` hook is wired by the app to `ExtensionRegistry.deliverEvent`.
@MainActor
final class ExtensionFSWatch {
    static let shared = ExtensionFSWatch()

    /// (extensionID, handler, payloadJSON) — set by the app.
    var invoke: ((String, String, String) -> Void)?

    private final class Entry {
        let extensionID: String
        let handler: String
        /// A host-side watch (#870 managed-config refresh): called instead of a Lua handler.
        let onChange: (@MainActor () -> Void)?
        /// #921: the watcher is below the system tier, so changes under a secret path are dropped.
        let hideSecrets: Bool
        var stream: FSEventStreamRef?
        init(extensionID: String, handler: String, onChange: (@MainActor () -> Void)? = nil, hideSecrets: Bool = false) {
            self.extensionID = extensionID
            self.handler = handler
            self.onChange = onChange
            self.hideSecrets = hideSecrets
        }
    }

    // keyed by "extensionID\u{1}path" so one extension can watch several paths.
    private var entries: [String: Entry] = [:]

    private func key(_ extID: String, _ path: String) -> String { "\(extID)\u{1}\(path)" }

    /// Start (or replace) a watch on `path` for `extensionID`, firing `handler`.
    func watch(extensionID: String, path: String, handler: String, onChange: (@MainActor () -> Void)? = nil,
               hideSecrets: Bool = false) {
        let p = (path as NSString).expandingTildeInPath
        let k = key(extensionID, p)
        unwatch(extensionID: extensionID, path: p) // replace any existing watch on this path

        let entry = Entry(extensionID: extensionID, handler: handler, onChange: onChange, hideSecrets: hideSecrets)
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(entry).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let entry = Unmanaged<Entry>.fromOpaque(info).takeUnretainedValue()
            guard let paths = ExtensionFSWatch.visiblePaths(
                Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? [],
                hideSecrets: entry.hideSecrets) else { return }
            let payload = ExtensionFSWatch.payloadJSON(paths)
            Task { @MainActor in
                if let onChange = entry.onChange { onChange() } else { ExtensionFSWatch.shared.invoke?(entry.extensionID, entry.handler, payload) }
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [p] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        entry.stream = stream
        entries[k] = entry
    }

    func unwatch(extensionID: String, path: String) {
        let p = (path as NSString).expandingTildeInPath
        guard let entry = entries.removeValue(forKey: key(extensionID, p)) else { return }
        stop(entry)
    }

    func removeAll(extensionID: String) {
        for (k, entry) in entries where entry.extensionID == extensionID {
            stop(entry)
            entries.removeValue(forKey: k)
        }
    }

    private func stop(_ entry: Entry) {
        guard let stream = entry.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        entry.stream = nil
    }

    /// #921: the changed paths a watcher may see; nil (no event at all) when every one of them was
    /// a secret path, so a parent-folder watch below the system tier cannot time a secret change.
    nonisolated static func visiblePaths(_ paths: [String], hideSecrets: Bool) -> [String]? {
        guard hideSecrets else { return paths }
        let m = SecretPaths.matcher()
        let kept = paths.filter { !m.denies($0) }
        return kept.isEmpty && !paths.isEmpty ? nil : kept
    }

    nonisolated static func payloadJSON(_ paths: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["paths": paths]),
              let s = String(data: data, encoding: .utf8) else { return #"{"paths":[]}"# }
        return s
    }
}
