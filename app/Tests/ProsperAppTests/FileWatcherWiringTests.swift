import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #1144: the app-long watchers are wired to their reloads. AppDelegate's MCP and hooks config
/// watchers (through `makeMCPConfigWatcher` / `makeHooksConfigWatcher`, the store's `fileURL`
/// pointed at the row's tempDir) and BunHarness's events watcher (`watchEvents(at:)` on a fresh
/// BunHarness, never `shared`, never `start`). Every `apply` is a recorder: no agent harness, no
/// process. Every wait polls a condition to a stated deadline.
final class FileWatcherWiringTests: XCTestCase {

    /// Touched on main only: FileWatcher calls back on the main queue, `apply` runs in a
    /// main-actor Task, the notification observers are on `.main`.
    final class Recorder: @unchecked Sendable {
        var applied = 0
        var notified: [[String]] = []
    }

    /// Polls `cond` until it holds or `seconds` pass, spinning the main run loop so main-queue
    /// callbacks and main-actor Tasks run. Returns whether it held.
    private func poll(_ seconds: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() >= end { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// How many of this process's descriptors point under `dir` (fcntl F_GETPATH over /dev/fd).
    private func openDescriptors(under dir: URL) -> Int {
        let marker = "/" + dir.lastPathComponent + "/"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else { return 0 }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return names.filter { name in
            guard let fd = Int32(name), fd >= 0, fcntl(fd, F_GETPATH, &buf) != -1 else { return false }
            return String(cString: buf).contains(marker)
        }.count
    }

    private func rewriteInPlace(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    /// Stops `watcher` and returns once nothing it fired can still reach main: the stop block has
    /// run when its descriptor is closed (after that the debounce sends nothing), and a marker
    /// queued on main after that point runs after any callback already queued.
    @MainActor private func stopAndDrain(_ watcher: FileWatcher, dir: URL) {
        watcher.stop()
        XCTAssertTrue(poll(10) { openDescriptors(under: dir) == 0 }, "descriptor closed within 10 s of stop()")
        let drained = Recorder()
        DispatchQueue.main.async { drained.applied = 1 }
        XCTAssertTrue(poll(10) { drained.applied == 1 }, "main queue drained within 10 s")
    }

    private func observe(_ name: Notification.Name, into rec: Recorder,
                         ids: @escaping @Sendable (Any?) -> [String]?) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            if let list = ids(note.object) { rec.notified.append(list) }
        }
    }

    private static func mcpJSON(_ id: String) -> String {
        #"{"mcpServers":{"\#(id)":{"command":"/usr/bin/true"}}}"#
    }

    private static func hooksJSON(_ command: String) -> String {
        #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(command)"}]}]}}"#
    }

    // MARK: AppDelegate

    @MainActor func testMCPConfigWriteAndAtomicReplaceReachTheReload() throws {
        let dir = tempDir("wire-mcp")
        let savedURL = MCPConfigStore.fileURL, savedPrefs = Preferences.mcpServers
        let savedMirror = Preferences.defaults.string(forKey: "agentMCPDiskMirror")
        let file = dir.appendingPathComponent("mcp.json")
        MCPConfigStore.fileURL = file
        let start = Self.mcpJSON("start")
        try Data(start.utf8).write(to: file)
        Preferences.defaults.set(start, forKey: "agentMCPDiskMirror")   // as after bootstrap: nothing new yet

        let rec = Recorder()
        let token = observe(.mcpServersReloadedExternally, into: rec) { ($0 as? [MCPServer])?.map { $0.id } }
        let watcher = AppDelegate.makeMCPConfigWatcher(apply: { rec.applied += 1 })
        defer {
            stopAndDrain(watcher, dir: dir)   // before fileURL goes back to the real path
            NotificationCenter.default.removeObserver(token)
            MCPConfigStore.fileURL = savedURL
            Preferences.mcpServers = savedPrefs
            Preferences.defaults.set(savedMirror, forKey: "agentMCPDiskMirror")
        }
        XCTAssertTrue(poll(10) { openDescriptors(under: dir) == 1 }, "armed within 10 s")

        try rewriteInPlace(Self.mcpJSON("api"), to: file)
        XCTAssertTrue(poll(10) { rec.applied >= 1 }, "a write reaches apply within 10 s")
        XCTAssertEqual(rec.notified.last, ["api"], "the reload posted the servers it read")
        XCTAssertEqual(Preferences.mcpServers.map { $0.id }, ["api"], "the reload committed the file")

        let before = rec.applied
        try Data(Self.mcpJSON("api-qa").utf8).write(to: file, options: .atomic)
        XCTAssertTrue(poll(10) { rec.applied > before }, "an atomic replace reaches apply within 10 s")
        XCTAssertEqual(rec.notified.last, ["api-qa"])
        XCTAssertTrue(poll(10) { openDescriptors(under: dir) == 1 }, "re-armed within 10 s")
        XCTAssertEqual(Preferences.mcpServers.map { $0.id }, ["api-qa"])
    }

    @MainActor func testHooksConfigWriteAndAtomicReplaceReachTheReload() throws {
        let dir = tempDir("wire-hooks")
        let savedURL = HooksConfigStore.fileURL, savedPrefs = Preferences.hooks
        let savedMirror = Preferences.defaults.string(forKey: "agentHooksDiskMirror")
        let file = dir.appendingPathComponent("hooks.json")
        HooksConfigStore.fileURL = file
        let start = Self.hooksJSON("echo start")
        try Data(start.utf8).write(to: file)
        Preferences.defaults.set(start, forKey: "agentHooksDiskMirror")

        let rec = Recorder()
        let token = observe(.hooksReloadedExternally, into: rec) { ($0 as? [HookRule])?.map { $0.command } }
        let watcher = AppDelegate.makeHooksConfigWatcher(apply: { rec.applied += 1 })
        defer {
            stopAndDrain(watcher, dir: dir)
            NotificationCenter.default.removeObserver(token)
            HooksConfigStore.fileURL = savedURL
            Preferences.hooks = savedPrefs
            Preferences.defaults.set(savedMirror, forKey: "agentHooksDiskMirror")
        }
        XCTAssertTrue(poll(10) { openDescriptors(under: dir) == 1 }, "armed within 10 s")

        try rewriteInPlace(Self.hooksJSON("echo api"), to: file)
        XCTAssertTrue(poll(10) { rec.applied >= 1 }, "a write reaches apply within 10 s")
        XCTAssertEqual(rec.notified.last, ["echo api"], "the reload posted the hooks it read")
        XCTAssertEqual(Preferences.hooks.map { $0.command }, ["echo api"], "the reload committed the file")

        let before = rec.applied
        try Data(Self.hooksJSON("echo api-qa").utf8).write(to: file, options: .atomic)
        XCTAssertTrue(poll(10) { rec.applied > before }, "an atomic replace reaches apply within 10 s")
        XCTAssertEqual(rec.notified.last, ["echo api-qa"])
        XCTAssertTrue(poll(10) { openDescriptors(under: dir) == 1 }, "re-armed within 10 s")
        XCTAssertEqual(Preferences.hooks.map { $0.command }, ["echo api-qa"])
    }

    // MARK: BunHarness

    /// A write and an atomic replace of the events file reach apply; shutdown (given the row's own
    /// socket path, never the live one) drops the watcher, and a later write reaches nothing
    /// within a 2 s ceiling (ten times the watcher's 0.2 s debounce).
    @MainActor func testBunEventsWatcherFiresAndShutdownDropsIt() throws {
        let dir = tempDir("wire-bun")
        let events = dir.appendingPathComponent(".events.json")
        let socket = dir.appendingPathComponent(".host.sock")
        try Data("[]".utf8).write(to: events)
        try Data().write(to: socket)   // a plain file standing in for the socket shutdown unlinks

        let rec = Recorder()
        let harness = BunHarness()
        harness.watchEvents(at: events, apply: { rec.applied += 1 })
        defer { if let w = harness.eventsWatcher { stopAndDrain(w, dir: dir) } }   // only on a red row
        XCTAssertTrue(harness.eventsWatcher != nil, "watchEvents made a watcher")
        XCTAssertTrue(poll(10) { openDescriptors(under: dir) == 1 }, "armed within 10 s")

        try rewriteInPlace(#"["PreToolUse"]"#, to: events)
        XCTAssertTrue(poll(10) { rec.applied >= 1 }, "a write reaches apply within 10 s")

        let before = rec.applied
        try Data(#"["PostToolUse"]"#.utf8).write(to: events, options: .atomic)
        XCTAssertTrue(poll(10) { rec.applied > before }, "an atomic replace reaches apply within 10 s")
        XCTAssertTrue(poll(10) { openDescriptors(under: dir) == 1 }, "re-armed within 10 s")

        harness.shutdown(socket: socket)
        XCTAssertTrue(harness.eventsWatcher == nil, "shutdown dropped the watcher")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path), "shutdown unlinked the given socket")
        XCTAssertTrue(poll(10) { openDescriptors(under: dir) == 0 }, "descriptor closed within 10 s of shutdown")

        let afterShutdown = rec.applied
        try rewriteInPlace(#"["PermissionRequest"]"#, to: events)
        XCTAssertFalse(poll(2) { rec.applied != afterShutdown }, "a write after shutdown reached apply")
    }
}
