import Foundation

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

/// Live registry of extension path watchers. A watch fires the named handler with
/// payload `{ paths = [changed…] }`. MainActor-bound; streams scheduled on the main
/// run loop. The `invoke` hook is wired by the app to `ExtensionRegistry.deliverEvent`.
@MainActor
final class ExtensionFSWatch {
    static let shared = ExtensionFSWatch()

    /// (extensionID, handler, payloadJSON) — set by the app.
    var invoke: ((String, String, String) -> Void)?

    private final class Entry {
        let extensionID: String
        let handler: String
        var stream: FSEventStreamRef?
        init(extensionID: String, handler: String) {
            self.extensionID = extensionID
            self.handler = handler
        }
    }

    // keyed by "extensionID\u{1}path" so one extension can watch several paths.
    private var entries: [String: Entry] = [:]

    private func key(_ extID: String, _ path: String) -> String { "\(extID)\u{1}\(path)" }

    /// Start (or replace) a watch on `path` for `extensionID`, firing `handler`.
    func watch(extensionID: String, path: String, handler: String) {
        let p = (path as NSString).expandingTildeInPath
        let k = key(extensionID, p)
        unwatch(extensionID: extensionID, path: p) // replace any existing watch on this path

        let entry = Entry(extensionID: extensionID, handler: handler)
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(entry).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let entry = Unmanaged<Entry>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let payload = ExtensionFSWatch.payloadJSON(paths)
            Task { @MainActor in ExtensionFSWatch.shared.invoke?(entry.extensionID, entry.handler, payload) }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [p] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
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

    nonisolated static func payloadJSON(_ paths: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["paths": paths]),
              let s = String(data: data, encoding: .utf8) else { return #"{"paths":[]}"# }
        return s
    }
}
