import XCTest
@testable import ProsperApp

/// Records every host.notify title and which idle-sleep holds each extension has,
/// as the live ExtensionResources would (acquire per call, all released by
/// resetResources). Can park the lane inside prevent_idle_sleep until the test lets go.
private final class LaunchRecordingServices: ExtensionHostServices, @unchecked Sendable {
    private let lock = NSLock()
    private var _titles: [String] = []
    private var _held: [String: Set<String>] = [:]
    private var expectations: [String: XCTestExpectation] = [:]
    /// Set before the call to block: fulfilled on entry, then waits for `release`.
    var blockEntered: XCTestExpectation?
    let release = DispatchSemaphore(value: 0)

    var titles: [String] { lock.lock(); defer { lock.unlock() }; return _titles }
    func held(_ id: String) -> Set<String> { lock.lock(); defer { lock.unlock() }; return _held[id] ?? [] }
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
    func notify(title: String, body: String) {
        // Each expectation fulfils once (the list assertions catch extras).
        lock.lock(); _titles.append(title); let e = expectations.removeValue(forKey: title); lock.unlock()
        e?.fulfill()
    }
    func listDirectories(_ path: String) -> [String] { [] }
    func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool) {
        lock.lock(); let block = blockEntered; blockEntered = nil; lock.unlock()
        if let block {
            block.fulfill()
            _ = release.wait(timeout: .now() + 30)   // a ceiling, not a wait: the test signals
        }
        lock.lock()
        if on { _held[extensionID, default: []].insert(kind) } else { _held[extensionID]?.remove(kind) }
        lock.unlock()
    }
    func resetResources(extensionID: String) { lock.lock(); _held[extensionID] = nil; lock.unlock() }
}

/// #930: disabling an extension tears down its assertions, timers, menubar items and
/// key rules; only its `system.launch` handler restores them. Re-enabling replays
/// that one-shot to that extension alone, and nothing it runs after its teardown may
/// leave it holding anything.
@MainActor
final class ExtensionReenableLaunchTests: XCTestCase {

    private struct Fixture { let id: String; let system: Bool; let launch: Bool; let lua: String }

    private func registry(_ services: LaunchRecordingServices, _ exts: [Fixture]) throws -> ExtensionRegistry {
        let root = tempDir("reenable-launch")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for e in exts {
            let dir = root.appendingPathComponent("\(e.system ? "system" : "user")/\(e.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let events = e.launch ? "[[contributes.events]]\nevent = \"system.launch\"\nhandler = \"on_launch\"\n" : ""
            try """
            [extension]
            id = "\(e.id)"
            name = "fixture"
            title = "Fixture"
            description = "re-enable launch fixture"
            version = "1.0.0"
            author = "tester"
            \(e.system ? "system = true" : "")

            [extension.host]
            min_version = "2.0.0"
            api_level = 1

            [extension.entry]
            main = "init.lua"

            \(events)
            """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            try e.lua.write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        }
        let defaults = scratchDefaults("reenable-launch")
        // An absent trust list grandfathers every user extension in as trusted on the
        // first discover; an empty one keeps the user fixture untrusted.
        defaults.set([String](), forKey: "trustedExtensionIDs")
        let registry = ExtensionRegistry(
            systemDir: root.appendingPathComponent("system", isDirectory: true),
            userDir: root.appendingPathComponent("user", isDirectory: true),
            hostVersion: "2.0.0", defaults: defaults, services: services)
        registry.discover()
        for e in exts { XCTAssertNotNil(registry.record(id: e.id), "fixture \(e.id) not discovered") }
        return registry
    }

    /// Re-enabling A launches A once; B (another system.launch subscriber) and C
    /// (an untrusted user extension, switched off and on too) get nothing.
    func testReenableLaunchesOnlyThatExtension() async throws {
        let services = LaunchRecordingServices()
        let a = "com.test.relaunch-a", b = "com.test.relaunch-b", c = "com.test.relaunch-c"
        let reg = try registry(services, [
            Fixture(id: a, system: true, launch: true, lua: """
                function on_launch() host.notify("launch-a", "") end
                function on_marker() host.notify("marker-a", "") end
                """),
            Fixture(id: b, system: true, launch: true, lua: """
                function on_launch() host.notify("launch-b", "") end
                function on_marker() host.notify("marker-b", "") end
                """),
            Fixture(id: c, system: false, launch: true, lua: """
                function on_launch() host.notify("launch-c", "") end
                """),
        ])
        XCTAssertTrue(reg.record(id: c)?.trusted == false, "user fixture must start untrusted")
        let launched = expectation(description: "on_launch after re-enable")
        services.expect("launch-a", launched)

        try reg.setEnabled(true, id: a)    // already enabled: no replay
        try reg.setEnabled(false, id: a)   // disable: no replay
        try reg.setEnabled(true, id: a)    // re-enable: exactly one, to A only
        try reg.setEnabled(false, id: c)
        try reg.setEnabled(true, id: c)    // untrusted: never delivered
        await fulfillment(of: [launched], timeout: 30)

        // Later deliveries on A's and B's own serial lanes: a stray replay queued by
        // the calls above has landed on its lane before these.
        await reg.deliverEvent(extensionID: a, handler: "on_marker", payloadJSON: "{}")
        await reg.deliverEvent(extensionID: b, handler: "on_marker", payloadJSON: "{}")
        XCTAssertEqual(services.titles, ["launch-a", "marker-a", "marker-b"])
        XCTAssertTrue(reg.record(id: c)?.runtime == nil, "an untrusted extension spawned a VM")
    }

    /// The mirror of the bug: an invocation running when the extension is disabled
    /// takes its resource AFTER teardown's resetResources. And one queued behind it
    /// must not run at all. Nothing may be held, or have run, once both ended.
    func testDisableDuringInFlightHandlerLeavesNothingHeld() async throws {
        let services = LaunchRecordingServices()
        let id = "com.test.holder"
        let reg = try registry(services, [Fixture(id: id, system: true, launch: false, lua: """
            function on_hold() host.caffeinate.prevent_idle_sleep("system", true) end
            function on_note() host.notify("late", ""); host.caffeinate.prevent_idle_sleep("display", true) end
            """)])
        let entered = expectation(description: "handler parked inside prevent_idle_sleep")
        services.blockEntered = entered

        let first = Task { @MainActor in
            await reg.deliverEvent(extensionID: id, handler: "on_hold", payloadJSON: "{}")
        }
        await fulfillment(of: [entered], timeout: 30)
        // Queue a second call behind the parked one; it is on the lane once this resumes.
        let queued = expectation(description: "second call queued")
        let second = Task { @MainActor in
            queued.fulfill()
            await reg.deliverEvent(extensionID: id, handler: "on_note", payloadJSON: "{}")
        }
        await fulfillment(of: [queued], timeout: 30)

        try reg.setEnabled(false, id: id)  // teardown while on_hold is inside its host call
        services.release.signal()
        await first.value
        await second.value

        XCTAssertEqual(services.held(id), [], "a disabled extension still holds an assertion")
        XCTAssertFalse(services.titles.contains("late"), "a call queued before the disable ran after it")
    }
}
