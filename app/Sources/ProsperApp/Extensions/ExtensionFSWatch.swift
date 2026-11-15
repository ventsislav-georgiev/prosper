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

    /// Seam: the folder a relative CCPOOL_HOME counts from. The app's working directory; nil under XCTest,
    /// so no test resolves a path outside its own temp folder by accident.
    nonisolated(unsafe) static var workingDirectory: String? = NSClassFromString("XCTestCase") != nil
        ? nil : FileManager.default.currentDirectoryPath

    /// #1201 (R921-4): the folders a CCPOOL_HOME value names. The pool reads the value as a file path:
    /// as given when absolute, else from the app's working directory, a leading "~" included (a file
    /// path does not expand it). A "~" value is protected under the home as well, as before, in case
    /// another reader of the variable expands it. Empty means unset for the pool: nothing to add.
    static func ccpoolFolders(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var folders: [String] = []
        if value.hasPrefix("/") {
            folders.append(value)
        } else if let cwd = workingDirectory {
            folders.append((cwd as NSString).appendingPathComponent(value))
        }
        if value.hasPrefix("~") {
            // `home` for "~" and "~/": the same folder NSString expands to in the app, and the seam in tests.
            let expanded = value == "~" || value.hasPrefix("~/")
                ? home + String(value.dropFirst()) : (value as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { folders.append(expanded) }
        }
        return folders
    }

    private static let logger = Logger(subsystem: "com.prosper.app", category: "extension")

    /// Seam: where a refusal line goes. A test captures the lines; the app logs a notice.
    nonisolated(unsafe) static var log: (String) -> Void = { SecretPaths.logger.notice("\($0, privacy: .public)") }

    /// Seam: called with each path `canonical` resolves (the unit of the filter's cost). Nil in the app.
    nonisolated(unsafe) static var onCanonical: ((String) -> Void)?

    /// Distinct refused paths that get a notice line in one VM; past it refusals stay silent.
    static let noticeCap = 64

    /// The secret roots and the volume's case rule, resolved once for a batch of paths (the roots
    /// are case-folded here, once). Never kept past one batch or one entry into a VM (`EntryRoots`):
    /// a root can become a symlink later.
    struct Matcher {
        let roots: [String]
        let caseInsensitive: Bool

        init(roots: [String], caseInsensitive: Bool) {
            self.caseInsensitive = caseInsensitive
            self.roots = caseInsensitive ? roots.map { $0.lowercased() } : roots
        }

        /// True when `path` is a root or below one, judged on the file the kernel would open:
        /// tilde expanded, then symlinks and ".." resolved, case-folded on a case-insensitive volume.
        func denies(_ path: String) -> Bool { resolve(path).map(covers) ?? false }

        /// `path` tilde expanded and resolved (`canonical`); nil for an empty path.
        func resolve(_ path: String) -> String? { SecretPaths.resolve(path) }

        /// A resolved path is a root or below one.
        func covers(_ real: String) -> Bool {
            let p = caseInsensitive ? real.lowercased() : real
            return roots.contains { SecretPaths.isAtOrBelow(p, $0) }
        }

        /// #1201 (R921-3): a folder `name` listed in the folder that resolved to `real` is covered. Judged
        /// below the resolved folder, with no resolved path per child: the host's listing names real folders
        /// only (ExtensionSecretPathsTests pins that), and a real folder resolves to its folder plus its name.
        func coversChild(_ name: String, of real: String) -> Bool {
            covers(SecretPaths.folded((real as NSString).appendingPathComponent(name)))
        }
    }

    /// Resolves every listed path under `home`, plus the folders a CCPOOL_HOME value names.
    static func matcher() -> Matcher {
        let paths = listed.map { (home as NSString).appendingPathComponent($0) }
            + ccpoolFolders(environment[ccpoolHomeVariable] ?? "")
        let fold = (try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames != true
        return Matcher(roots: paths.map(canonical), caseInsensitive: fold)
    }

    /// #1201: the matcher of one entry into an extension VM, held in `LuaRuntime.entryLocal`, which the
    /// runtime drops when that entry returns or throws. Built and read on the VM's own lane.
    final class EntryRoots {
        let matcher = SecretPaths.matcher()
    }

    /// `path` tilde expanded and resolved (`canonical`); nil for an empty path. The one resolver of the
    /// deny-list and of the watch key (#983).
    static func resolve(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return canonical(expanded)
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
        return folded(reader.realPath(path)
            ?? reader.realPath(ns.deletingLastPathComponent).map { ($0 as NSString).appendingPathComponent(ns.lastPathComponent) }
            ?? FilePaths.existingPrefixResolved(URL(fileURLWithPath: path)).path)
    }

    /// The two spellings `canonical` folds: the data volume's firmlinks and /private.
    static func folded(_ path: String) -> String {
        var p = path
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

/// #983: which watch a handler run came from: its key and the generation of the watch under that key. It rides
/// with the run to the extension's lane, which drops the run unless `ExtensionFSWatch.isCurrent` holds.
struct FSWatchRun: Sendable, Equatable {
    let key: String
    let generation: UInt64
}

/// #983: what the lanes read off the main actor. `generation`: each live watch's generation by key (dropped
/// by host.fs.unwatch on the lane and by the teardown); `keyOfText`: the key `watch` made for each watched text
/// (R983-1-q1), so an unwatch by that text never resolves again. Both hold at most one item per watch.
private struct FSWatchLive {
    var generation: [String: UInt64] = [:]
    var keyOfText: [String: String] = [:]
    var next: UInt64 = 0
}

/// Live registry of extension path watchers. A watch fires the named handler with
/// payload `{ paths = [changed...] }` (plus `more = n` when a burst had more changed paths than one run lists).
/// MainActor-bound; streams delivered on the main queue. The `invoke` hook is wired by the app to
/// `ExtensionRegistry.deliverEvent`.
@MainActor
final class ExtensionFSWatch {
    static let shared = ExtensionFSWatch()

    /// (extensionID, handler, payloadJSON, the watch it came from); set by the app.
    var invoke: ((String, String, String, FSWatchRun) -> Void)?

    /// #983: the stream's latency, and the window a burst is coalesced over: the first callback of a burst
    /// schedules one run this long after it, callbacks inside the window only add paths.
    static let latency: CFTimeInterval = 0.5
    static let streamFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
    /// #983: paths one run lists, and the cap of a watch's pending set; past it paths are only counted.
    static let maxPathsPerRun = 256

    /// #983 seam: runs a watch's coalesced flush after `latency`, on the main actor. Nil:
    /// DispatchQueue.main.asyncAfter. Rows record the work and run it themselves (no wall-clock wait).
    var schedule: ((TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void)?

    @MainActor
    private final class Entry {
        let key: String
        /// #983: the text it was watched under (`textKey`) and its generation (`FSWatchRun`).
        var text = ""
        var generation: UInt64 = 0
        let extensionID: String
        let handler: String
        /// A host-side watch (#870 managed-config refresh): called instead of a Lua handler.
        let onChange: (@MainActor () -> Void)?
        /// #921: the watcher is below the system tier, so changes under a secret path are dropped.
        let hideSecrets: Bool
        var stream: FSEventStreamRef?
        /// #983: the window's changed paths (at most `maxPathsPerRun`, in order, no repeats), the count past
        /// the cap, and whether the window's flush is scheduled.
        var pending: [String] = []
        var seen: Set<String> = []
        var more = 0
        var flushScheduled = false
        init(key: String, extensionID: String, handler: String, onChange: (@MainActor () -> Void)? = nil,
             hideSecrets: Bool = false) {
            self.key = key
            self.extensionID = extensionID
            self.handler = handler
            self.onChange = onChange
            self.hideSecrets = hideSecrets
        }
    }

    // keyed by "extensionID\u{1}resolved path" so one extension can watch several paths.
    private var entries: [String: Entry] = [:]

    var watchCount: Int { entries.count }

    /// #983: the resolved path (SecretPaths.resolve, the deny-list's own resolver), so every spelling of one
    /// folder is one watch.
    nonisolated static func key(_ extID: String, _ path: String) -> String { "\(extID)\u{1}\(resolved(path))" }

    private nonisolated static func resolved(_ path: String) -> String { SecretPaths.resolve(path) ?? path }

    /// #983: keys a host.fs.unwatch marked on the extension's lane and the main actor has not torn down yet.
    private nonisolated static let unwatching = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    private nonisolated static let live = OSAllocatedUnfairLock(initialState: FSWatchLive())

    /// #983 R983-1-q1: the watched text as `keyOfText` holds it (tilde expanded, not resolved).
    private nonisolated static func textKey(_ extID: String, _ path: String) -> String {
        "\(extID)\u{1}\((path as NSString).expandingTildeInPath)"
    }

    /// #983 R983-1-q1: the key `watch` made for this text; resolved now only when the text was never watched,
    /// so a symlink retargeted since the watch cannot make unwatch miss.
    nonisolated static func watchedKey(_ extID: String, _ path: String) -> String {
        let t = textKey(extID, path)
        return live.withLock { $0.keyOfText[t] } ?? key(extID, path)
    }

    /// #983: read at lane start (AsyncExtensionRuntimes.callOnLane) on the extension's lane: one lock read, no
    /// wait on the main actor. False once the watch was unwatched (marked on the lane), replaced or removed.
    nonisolated static func isCurrent(_ run: FSWatchRun) -> Bool {
        live.withLock { $0.generation[run.key] == run.generation }
    }

    /// #983: called by host.fs.unwatch on the extension's lane BEFORE it returns: from here no run of that
    /// watch starts, neither a flush (the mark) nor a run already on its way to the lane (the generation).
    /// Returns the key for `finishUnwatch`, which the caller runs on the main actor.
    nonisolated static func markUnwatch(extensionID: String, path: String) -> String {
        let k = watchedKey(extensionID, path)
        unwatching.withLock { $0[k, default: 0] += 1 }
        live.withLock { _ = $0.generation.removeValue(forKey: k) }
        return k
    }

    /// #983: the main-actor half of host.fs.unwatch: tears the watch down, then clears the lane's mark.
    func finishUnwatch(key k: String) {
        remove(k)
        Self.unwatching.withLock { marks in
            if let n = marks[k] { marks[k] = n > 1 ? n - 1 : nil }
        }
    }

    /// Start (or replace) a watch on `path` for `extensionID`, firing `handler`.
    func watch(extensionID: String, path: String, handler: String, onChange: (@MainActor () -> Void)? = nil,
               hideSecrets: Bool = false) {
        let p = Self.resolved(path), k = "\(extensionID)\u{1}\(p)", t = Self.textKey(extensionID, path)
        // The same text watched before a symlink in it was retargeted is replaced too (R983-1-q1).
        if let old = Self.live.withLock({ $0.keyOfText[t] }) { remove(old) }
        remove(k) // replace any existing watch on this path, under any spelling

        let entry = Entry(key: k, extensionID: extensionID, handler: handler, onChange: onChange, hideSecrets: hideSecrets)
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(entry).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // Runs on the main queue (FSEventStreamSetDispatchQueue below), so it enters the main actor in place.
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let entry = Unmanaged<Entry>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            MainActor.assumeIsolated { ExtensionFSWatch.shared.receive(entry, paths) }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [p] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, Self.streamFlags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        entry.stream = stream
        entry.text = t
        entry.generation = Self.live.withLock { s in
            s.next &+= 1
            s.generation[k] = s.next
            s.keyOfText[t] = k
            return s.next
        }
        entries[k] = entry
    }

    func unwatch(extensionID: String, path: String) {
        remove(Self.watchedKey(extensionID, path))
    }

    private func remove(_ k: String) {
        guard let entry = entries.removeValue(forKey: k) else { return }
        forget(entry)
        stop(entry)
    }

    func removeAll(extensionID: String) {
        for (k, entry) in entries where entry.extensionID == extensionID {
            forget(entry)
            stop(entry)
            entries.removeValue(forKey: k)
        }
    }

    /// #983: the lanes' copy of a watch leaves with it, so `live` never outgrows `entries`.
    private func forget(_ entry: Entry) {
        let k = entry.key, t = entry.text
        Self.live.withLock { s in
            s.generation[k] = nil
            if s.keyOfText[t] == k { s.keyOfText[t] = nil }
        }
    }

    private func stop(_ entry: Entry) {
        guard let stream = entry.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        entry.stream = nil
    }

    /// #983 seam: `paths` as one FSEvents callback of the watch on `path`; false when there is no such watch.
    @discardableResult
    func deliver(_ paths: [String], extensionID: String, path: String) -> Bool {
        guard let entry = entries[Self.key(extensionID, path)] else { return false }
        receive(entry, paths)
        return true
    }

    /// One FSEvents callback: secret paths dropped first (#921), the rest added to the window, the window's
    /// flush scheduled once.
    private func receive(_ entry: Entry, _ paths: [String]) {
        guard let visible = Self.visiblePaths(paths, hideSecrets: entry.hideSecrets) else { return }
        for p in visible where !entry.seen.contains(p) {
            if entry.pending.count < Self.maxPathsPerRun {
                entry.pending.append(p)
                entry.seen.insert(p)
            } else if entry.more < Int.max {
                entry.more += 1
            }
        }
        guard !entry.flushScheduled else { return }
        entry.flushScheduled = true
        let work: @MainActor @Sendable () -> Void = { ExtensionFSWatch.shared.flush(entry) }
        if let schedule {
            schedule(Self.latency, work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.latency) { MainActor.assumeIsolated { work() } }
        }
    }

    /// The window's one run. A watch unwatched, replaced or removed since (on the main actor, or marked by
    /// host.fs.unwatch on the extension's lane) never starts its handler.
    private func flush(_ entry: Entry) {
        entry.flushScheduled = false
        let paths = entry.pending, more = entry.more
        entry.pending = []
        entry.seen = []
        entry.more = 0
        let k = entry.key
        guard entries[k] === entry, !Self.unwatching.withLock({ $0[k] != nil }) else { return }
        if let onChange = entry.onChange { onChange() } else {
            invoke?(entry.extensionID, entry.handler, Self.payloadJSON(paths, more: more),
                    FSWatchRun(key: k, generation: entry.generation))
        }
    }

    /// #921: the changed paths a watcher may see; nil (no event at all) when every one of them was
    /// a secret path, so a parent-folder watch below the system tier cannot time a secret change.
    nonisolated static func visiblePaths(_ paths: [String], hideSecrets: Bool) -> [String]? {
        guard hideSecrets else { return paths }
        let m = SecretPaths.matcher()
        let kept = paths.filter { !m.denies($0) }
        return kept.isEmpty && !paths.isEmpty ? nil : kept
    }

    /// `more`: changed paths past `maxPathsPerRun` in the window; the key is absent when there are none.
    nonisolated static func payloadJSON(_ paths: [String], more: Int = 0) -> String {
        let obj: [String: Any] = more > 0 ? ["paths": paths, "more": more] : ["paths": paths]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return #"{"paths":[]}"# }
        return s
    }
}
