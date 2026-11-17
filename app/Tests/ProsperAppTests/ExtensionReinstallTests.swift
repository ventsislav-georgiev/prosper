import XCTest
@testable import ProsperApp

/// Records host.notify titles, every prevent_idle_sleep take and release, and each resetResources (the one
/// release of what an id holds: assertions, lid flag, menu bar items, key rules, watches). Can park the
/// lane inside host.notify until the row lets go. No native side effect.
private final class ReinstallRecordingServices: ExtensionHostServices, @unchecked Sendable {
    private let lock = NSLock()
    private var _titles: [String] = []
    private var _events: [String] = []
    private var _calls: [String: [String]] = [:]
    private var _held: [String: Set<String>] = [:]
    private var _resets: [String: Int] = [:]
    private var expectations: [String: XCTestExpectation] = [:]
    /// Set before the call to park: fulfilled inside host.notify, which then waits for `release`.
    var blockEntered: XCTestExpectation?
    let release = DispatchSemaphore(value: 0)

    var titles: [String] { lock.lock(); defer { lock.unlock() }; return _titles }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    func calls(_ id: String) -> [String] { lock.lock(); defer { lock.unlock() }; return _calls[id] ?? [] }
    func held(_ id: String) -> Set<String> { lock.lock(); defer { lock.unlock() }; return _held[id] ?? [] }
    func resets(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return _resets[id] ?? 0 }
    func expect(_ title: String, _ e: XCTestExpectation) { lock.lock(); expectations[title] = e; lock.unlock() }

    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
    func notify(title: String, body: String) {
        lock.lock(); let block = blockEntered; blockEntered = nil; lock.unlock()
        if let block {
            block.fulfill()
            _ = release.wait(timeout: .now() + 30)   // a ceiling, not a wait: the row signals
        }
        lock.lock(); _titles.append(title); _events.append(title); let e = expectations.removeValue(forKey: title); lock.unlock()
        e?.fulfill()
    }
    func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool) {
        lock.lock()
        _calls[extensionID, default: []].append((on ? "+" : "-") + kind)
        if on { _held[extensionID, default: []].insert(kind) } else { _held[extensionID]?.remove(kind) }
        lock.unlock()
    }
    func resetResources(extensionID: String) {
        lock.lock(); _held[extensionID] = nil; _resets[extensionID, default: 0] += 1
        _events.append("release \(extensionID)"); lock.unlock()
    }
}

/// #1241: an install over an installed, live extension tears the old record down after the copy and before
/// discover (as reset does), then the launch replay brings the new code up (as a re-enable does). Every row's
/// registry, install sources and user folder live in its own tempDir(); nothing is fetched.
@MainActor
final class ExtensionReinstallTests: XCTestCase {

    private let id = "com.example.reinstall"

    /// The old generation: on_hold takes "system"; on_take says "wait" (where a row parks it), then takes "system".
    private static let oldLua = """
        function on_hold() host.caffeinate.prevent_idle_sleep("system", true) end
        function on_take() host.notify("wait", ""); host.caffeinate.prevent_idle_sleep("system", true) end
        function on_launch() host.notify("launch-old", "") end
        """
    /// The new generation: its launch takes "display" and says "launch-new".
    private static let newLua = """
        function on_launch() host.caffeinate.prevent_idle_sleep("display", true); host.notify("launch-new", "") end
        function on_marker() host.notify("marker-new", "") end
        """

    private func writeSource(_ dir: URL, version: String, lua: String, extra: String? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(id)"
        name = "reinstall"
        title = "Reinstall"
        description = "reinstall fixture"
        version = "\(version)"
        author = "Example Org"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.events]]
        event = "system.launch"
        handler = "on_launch"
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try lua.write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        if let extra { try "old".write(to: dir.appendingPathComponent(extra), atomically: true, encoding: .utf8) }
    }

    /// A registry in `root`/user, trusting the fixture id (as an earlier trust would have).
    private func registry(_ root: URL, _ services: ReinstallRecordingServices) -> ExtensionRegistry {
        let defaults = scratchDefaults("reinstall")
        defaults.set([id], forKey: "trustedExtensionIDs")
        let reg = ExtensionRegistry(systemDir: nil, userDir: root.appendingPathComponent("user", isDirectory: true),
                                    hostVersion: "2.0.0", defaults: defaults, services: services)
        reg.discover()
        return reg
    }

    /// Installs version 1 from a folder the row made, then has it take "system" and arm a timer an hour out
    /// (cancelled by the row's defer: nothing fires).
    private func installHoldingOld(_ root: URL, _ services: ReinstallRecordingServices) async throws -> ExtensionRegistry {
        let reg = registry(root, services)
        let v1 = root.appendingPathComponent("v1", isDirectory: true)
        try writeSource(v1, version: "1.0.0", lua: Self.oldLua, extra: "old-only.txt")
        try reg.installLocal(from: v1)
        await reg.deliverEvent(extensionID: id, handler: "on_hold", payloadJSON: "{}")
        TimerScheduler.shared.schedule(extID: id, id: "t1241", every: false, seconds: 3600, handler: "on_t")
        XCTAssertEqual(services.held(id), ["system"], "precondition: the old generation holds its assertion")
        XCTAssertTrue(TimerScheduler.shared.isScheduled(extID: id, id: "t1241"), "precondition: the old generation has its timer")
        XCTAssertEqual(services.resets(id), 0, "precondition: a fresh install releases nothing")
        return reg
    }

    /// Install over a live extension while an old call is parked on its lane: the old call is retired (its take
    /// never reaches the host and it does not release late), what the old one held is released once, its timer is
    /// gone, and the new code's launch runs once and keeps its take. Parent: no release, the old hold and timer
    /// stay, the parked call takes again, and no launch runs.
    func testInstallOverALiveExtensionRetiresReleasesOnceAndLaunchesTheNewCodeOnce() async throws {
        let id = self.id   // captured by the Task below
        let services = ReinstallRecordingServices()
        defer { TimerScheduler.shared.cancelAll(extID: id) }
        let root = tempDir("reinstall-live")
        let reg = try await installHoldingOld(root, services)

        let entered = expectation(description: "old call parked in host.notify")
        services.blockEntered = entered
        let old = Task { @MainActor in await reg.deliverEvent(extensionID: id, handler: "on_take", payloadJSON: "{}") }
        await fulfillment(of: [entered], timeout: 30)
        let launched = expectation(description: "the new code's launch")
        services.expect("launch-new", launched)

        let v2 = root.appendingPathComponent("v2", isDirectory: true)
        try writeSource(v2, version: "2.0.0", lua: Self.newLua)
        try reg.installLocal(from: v2)
        services.release.signal()
        await old.value
        await fulfillment(of: [launched], timeout: 30)
        await Task { @MainActor in }.value   // any second replay Task is on the lane before the marker
        await reg.deliverEvent(extensionID: id, handler: "on_marker", payloadJSON: "{}")

        XCTAssertEqual(services.resets(id), 1, "the old generation's resources must be released exactly once")
        XCTAssertEqual(services.events.filter { $0 == "release \(id)" || $0.hasPrefix("launch-") },
                       ["release \(id)", "launch-new"], "release first, then one launch of the new code")
        XCTAssertEqual(services.calls(id), ["+system", "+display"], "the retired call's take reached the host")
        XCTAssertEqual(services.held(id), ["display"], "the old hold must be gone and the new launch's take kept")
        XCTAssertFalse(TimerScheduler.shared.isScheduled(extID: id, id: "t1241"), "the old generation kept its timer")
        XCTAssertEqual(services.titles.filter { $0.hasSuffix("-new") }, ["launch-new", "marker-new"])
        XCTAssertTrue(reg.record(id: id)?.isLive == true, "a reinstall must keep the extension enabled and trusted")
        XCTAssertEqual(reg.record(id: id)?.manifest.extension.version, "2.0.0")
    }

    /// A copy that fails (a folder in the new source nobody can read, inside this row's tempDir) leaves the old
    /// record live and holding: no release, the timer armed, no launch. #1430: the old folder's own file stays and
    /// no stage is left beside it.
    func testFailedCopyLeavesTheOldExtensionLiveAndHolding() async throws {
        let services = ReinstallRecordingServices()
        defer { TimerScheduler.shared.cancelAll(extID: id) }
        let root = tempDir("reinstall-failed")
        let reg = try await installHoldingOld(root, services)

        let v2 = root.appendingPathComponent("v2", isDirectory: true)
        try writeSource(v2, version: "2.0.0", lua: Self.newLua)
        let locked = v2.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "x".write(to: locked.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let lockedFile = v2.appendingPathComponent("locked.txt")   // unreadable too: a copy cannot open or clone it
        try "x".write(to: lockedFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedFile.path)
        let user = root.appendingPathComponent("user", isDirectory: true)
        addTeardownBlock {   // runs before tempDir's removal: the source and any copy of it (in a stage) may be unreadable
            let names = (try? FileManager.default.contentsOfDirectory(atPath: user.path)) ?? []
            let copies = names.map { user.appendingPathComponent("\($0)/locked", isDirectory: true) }
            for dir in [locked] + copies where FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            }
        }

        XCTAssertThrowsError(try reg.installLocal(from: v2), "the copy must fail for this row to mean anything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("\(id)/old-only.txt").path),
                      "a failed copy removed the old folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user.path), [id], "a failed copy left a stage")
        await Task { @MainActor in }.value   // a stray replay Task would have run by now

        XCTAssertEqual(services.resets(id), 0, "a failed copy released the old generation's resources")
        XCTAssertEqual(services.held(id), ["system"], "a failed copy dropped the old generation's assertion")
        XCTAssertTrue(TimerScheduler.shared.isScheduled(extID: id, id: "t1241"), "a failed copy dropped the old timer")
        XCTAssertFalse(services.titles.contains("launch-new"), "a failed copy launched the new code")
        XCTAssertTrue(reg.record(id: id)?.isLive == true, "a failed copy must leave the old record live")
        XCTAssertEqual(reg.record(id: id)?.manifest.extension.version, "1.0.0")
    }

    /// A first install (no record with that id) releases nothing and replays no launch: the marker is the only
    /// title. Parent: the same; a replay not tied to an existing record would say "launch-new" first.
    func testFirstInstallReleasesNothingAndLaunchesNothing() async throws {
        let services = ReinstallRecordingServices()
        defer { TimerScheduler.shared.cancelAll(extID: id) }
        let root = tempDir("reinstall-first")
        let reg = registry(root, services)
        let v2 = root.appendingPathComponent("v2", isDirectory: true)
        try writeSource(v2, version: "2.0.0", lua: Self.newLua)

        try reg.installLocal(from: v2)
        await Task { @MainActor in }.value   // a replay Task would be on the lane before the marker
        await reg.deliverEvent(extensionID: id, handler: "on_marker", payloadJSON: "{}")

        XCTAssertEqual(services.resets(id), 0, "a first install released resources")
        XCTAssertEqual(services.titles, ["marker-new"], "a first install ran the launch handler")
        XCTAssertTrue(reg.record(id: id)?.isLive == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("user").path), [id],
                       "a first install left a stage")
    }

    // MARK: - #1430: stage, then swap

    private struct ForcedCopyFailure: Error {}

    /// A copy that finishes and then fails: the stage exists when the error lands, so a stage left behind shows.
    private static let failingCopy: (URL, URL) throws -> Void = { src, dst in
        try FileManager.default.copyItem(at: src, to: dst)
        throw ForcedCopyFailure()
    }

    /// Every member under `dir` (hidden ones too) by relative path, with a file's bytes; a folder maps to empty data.
    private func snapshot(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let base = dir.resolvingSymlinksInPath().path
        let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for url in all {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            out[path] = (try? Data(contentsOf: url)) ?? Data()
        }
        return out
    }

    /// A forced copy failure on an install over a live extension leaves its folder byte-identical, the record live
    /// and holding, nothing torn down, and no stage. Parent: the old folder was removed before the copy.
    func testForcedCopyFailureOnInstallLeavesTheOldFolderAndRecord() async throws {
        let services = ReinstallRecordingServices()
        defer { TimerScheduler.shared.cancelAll(extID: id) }
        let root = tempDir("stage-install-failed")
        let reg = try await installHoldingOld(root, services)
        let user = root.appendingPathComponent("user", isDirectory: true)
        let before = snapshot(user.appendingPathComponent(id))
        XCTAssertTrue(before.keys.contains("/old-only.txt"), "precondition: the old folder's own file is there")
        let v2 = root.appendingPathComponent("v2", isDirectory: true)
        try writeSource(v2, version: "2.0.0", lua: Self.newLua)

        reg.copyFolder = Self.failingCopy
        XCTAssertThrowsError(try reg.installLocal(from: v2)) { XCTAssertTrue($0 is ForcedCopyFailure, "\($0)") }
        await Task { @MainActor in }.value   // a stray replay Task would have run by now

        XCTAssertEqual(snapshot(user.appendingPathComponent(id)), before, "a failed copy changed the old folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user.path), [id], "a failed copy left a stage")
        XCTAssertEqual(services.resets(id), 0, "a failed copy released the old generation's resources")
        XCTAssertEqual(services.held(id), ["system"], "a failed copy dropped the old generation's assertion")
        XCTAssertTrue(reg.record(id: id)?.isLive == true, "a failed copy must leave the old record live")
        XCTAssertEqual(reg.record(id: id)?.manifest.extension.version, "1.0.0")
    }

    /// A good install over a live extension swaps the folder in (the old-only file is gone), tears the old code down
    /// once, and leaves no stage or old folder beside it.
    func testGoodInstallSwapsTheFolderAndTearsDownOnce() async throws {
        let services = ReinstallRecordingServices()
        defer { TimerScheduler.shared.cancelAll(extID: id) }
        let root = tempDir("stage-install-good")
        let reg = try await installHoldingOld(root, services)
        let user = root.appendingPathComponent("user", isDirectory: true)
        let v2 = root.appendingPathComponent("v2", isDirectory: true)
        try writeSource(v2, version: "2.0.0", lua: Self.newLua)

        try reg.installLocal(from: v2)

        XCTAssertEqual(Set(snapshot(user.appendingPathComponent(id)).keys), ["/extension.toml", "/init.lua"],
                       "the installed folder must be the new source's, nothing of the old one")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user.path), [id], "an install left a stage")
        XCTAssertEqual(services.resets(id), 1, "the old generation must be torn down exactly once")
        XCTAssertEqual(reg.record(id: id)?.manifest.extension.version, "2.0.0")
    }

    /// Reset with a forced copy failure leaves the edited copy byte-identical, its record in place, nothing torn
    /// down and no stage; a reset after that (the real copy) swaps the pristine copy in and tears down once.
    /// Parent: the edited folder was removed before the copy.
    func testForcedCopyFailureOnResetLeavesTheEditedFolderThenAGoodResetSwaps() throws {
        let sid = "com.example.stage-reset"
        let services = ReinstallRecordingServices()
        let root = tempDir("stage-reset")
        let pristine = root.appendingPathComponent("system/\(sid)", isDirectory: true)
        try FileManager.default.createDirectory(at: pristine, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(sid)"
        name = "stage-reset"
        title = "Stage reset"
        description = "reset fixture"
        version = "1.0.0"
        author = "Example Org"
        system = true

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: pristine.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- pristine".write(to: pristine.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let user = root.appendingPathComponent("user", isDirectory: true)
        let reg = ExtensionRegistry(systemDir: root.appendingPathComponent("system", isDirectory: true), userDir: user,
                                    hostVersion: "2.0.0", defaults: scratchDefaults("stage-reset"), services: services)
        reg.discover()
        XCTAssertTrue(reg.record(id: sid)?.isSystem == true, "precondition: the fixture is a built-in")
        let edited = user.appendingPathComponent(sid, isDirectory: true)
        try "-- edited".write(to: edited.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        try "mine".write(to: edited.appendingPathComponent("edited.txt"), atomically: true, encoding: .utf8)
        let before = snapshot(edited)

        reg.copyFolder = Self.failingCopy
        XCTAssertThrowsError(try reg.reset(id: sid)) { XCTAssertTrue($0 is ForcedCopyFailure, "\($0)") }
        XCTAssertEqual(snapshot(edited), before, "a failed reset changed the edited folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user.path), [sid], "a failed reset left a stage")
        XCTAssertEqual(services.resets(sid), 0, "a failed reset tore the extension down")
        XCTAssertTrue(reg.record(id: sid) != nil, "a failed reset dropped the record")

        reg.copyFolder = { try FileManager.default.copyItem(at: $0, to: $1) }
        try reg.reset(id: sid)
        XCTAssertEqual(snapshot(edited), snapshot(pristine), "a good reset must leave the pristine copy")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user.path), [sid], "a good reset left a stage")
        XCTAssertEqual(services.resets(sid), 1, "a good reset tears the old code down once")
    }

    /// A stage and a replaced copy left beside the real folder (a crash mid-install, a failed remove), each with a
    /// valid manifest of the same id, and a partial stage with no manifest: none is loaded or refused; the real
    /// folder's record is the one loaded. Parent: ".old-x" sorts first and loads in place of the real folder, and
    /// the partial stage is listed as refused.
    func testDotNamedLeftoversAreNeitherLoadedNorRefused() throws {
        let services = ReinstallRecordingServices()
        defer { TimerScheduler.shared.cancelAll(extID: id) }
        let root = tempDir("stage-leftovers")
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeSource(user.appendingPathComponent(id, isDirectory: true), version: "1.0.0", lua: Self.newLua)
        try writeSource(user.appendingPathComponent(".stage-x", isDirectory: true), version: "9.0.0", lua: Self.newLua)
        try writeSource(user.appendingPathComponent(".old-x", isDirectory: true), version: "8.0.0", lua: Self.newLua)
        let partial = user.appendingPathComponent(".stage-partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Self.newLua.write(to: partial.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)

        let reg = registry(root, services)

        XCTAssertEqual(reg.records.filter { $0.id == id }.count, 1, "one record for the id")
        XCTAssertEqual(reg.record(id: id)?.manifest.extension.version, "1.0.0", "a dot-named leftover was loaded")
        XCTAssertEqual(reg.record(id: id)?.loaded.directory.lastPathComponent, id)
        XCTAssertTrue(reg.refused.isEmpty, "a dot-named leftover was refused: \(reg.refused.map(\.folder))")
    }
}
