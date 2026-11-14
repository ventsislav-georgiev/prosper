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
    /// #1238: where the call parks: "idle" (inside prevent_idle_sleep, before its take lands) or "notify"
    /// (inside host.notify, before any take).
    var blockIn = "idle"
    let release = DispatchSemaphore(value: 0)
    private var _calls: [String: [String]] = [:]
    /// #1238: every prevent_idle_sleep that reached the host for `id`, in order: "+kind" take, "-kind" release.
    func calls(_ id: String) -> [String] { lock.lock(); defer { lock.unlock() }; return _calls[id] ?? [] }

    private func parkIfAsked(_ site: String) {
        lock.lock(); let block = blockIn == site ? blockEntered : nil; if block != nil { blockEntered = nil }; lock.unlock()
        if let block {
            block.fulfill()
            _ = release.wait(timeout: .now() + 30)   // a ceiling, not a wait: the test signals
        }
    }

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
        parkIfAsked("notify")
        // Each expectation fulfils once (the list assertions catch extras).
        lock.lock(); _titles.append(title); _events.append(title); let e = expectations.removeValue(forKey: title); lock.unlock()
        e?.fulfill()
    }
    func listDirectories(_ path: String) -> [String] { [] }
    func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool) {
        parkIfAsked("idle")
        lock.lock()
        _calls[extensionID, default: []].append((on ? "+" : "-") + kind)
        if on { _held[extensionID, default: []].insert(kind) } else { _held[extensionID]?.remove(kind) }
        lock.unlock()
    }
    func resetResources(extensionID: String) {
        lock.lock(); _held[extensionID] = nil; _resets[extensionID, default: 0] += 1
        _events.append("release \(extensionID)"); lock.unlock()
    }
    private var _resets: [String: Int] = [:]
    private var _events: [String] = []
    /// Releases and notify titles in the order they happened (#1038).
    var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    /// How many times resetResources ran for `id` (#1038).
    func resets(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return _resets[id] ?? 0 }
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

    // MARK: - #1038: untrust and reset go through the same teardown as disable

    /// on_hold takes "system"; on_launch (the system.launch handler when the fixture subscribes) takes
    /// "display" and says "launch-<tag>"; on_marker says "marker-<tag>".
    private static func lua(_ tag: String) -> String {
        """
        function on_hold() host.caffeinate.prevent_idle_sleep("system", true) end
        function on_launch() host.caffeinate.prevent_idle_sleep("display", true); host.notify("launch-\(tag)", "") end
        function on_marker() host.notify("marker-\(tag)", "") end
        """
    }

    /// Each id takes an idle-sleep hold on its own lane and gets a one-shot timer an hour out on the
    /// shared scheduler (cancelled by the caller's defer before the row ends: nothing fires).
    private func holdAndArm(_ reg: ExtensionRegistry, _ services: LaunchRecordingServices, _ ids: [String]) async {
        for id in ids {
            await reg.deliverEvent(extensionID: id, handler: "on_hold", payloadJSON: "{}")
            TimerScheduler.shared.schedule(extID: id, id: "t1038", every: false, seconds: 3600, handler: "on_t")
            XCTAssertEqual(services.held(id), ["system"], "precondition: \(id) holds its assertion")
            XCTAssertTrue(TimerScheduler.shared.isScheduled(extID: id, id: "t1038"), "precondition: \(id) has its timer")
        }
    }

    /// Untrust releases what the extension holds (one resetResources, its timers) and nothing of another,
    /// and replays no launch. Parent: timers only; the assertion stayed held with no VM left to release it.
    func testUntrustReleasesOnlyThatExtensionsResources() async throws {
        let services = LaunchRecordingServices()
        let u = "com.test.untrust-u", o = "com.test.untrust-o"
        defer { TimerScheduler.shared.cancelAll(extID: u); TimerScheduler.shared.cancelAll(extID: o) }
        let reg = try registry(services, [Fixture(id: u, system: false, launch: true, lua: Self.lua("u")),
                                          Fixture(id: o, system: false, launch: true, lua: Self.lua("o"))])
        try reg.trust(id: u)
        try reg.trust(id: o)
        await holdAndArm(reg, services, [u, o])

        try reg.untrust(id: u)
        await Task { @MainActor in }.value   // a stray replay Task would have run by now

        XCTAssertEqual(services.resets(u), 1, "untrust must release the extension's resources exactly once")
        XCTAssertEqual(services.held(u), [], "an untrusted extension still holds an assertion")
        XCTAssertFalse(TimerScheduler.shared.isScheduled(extID: u, id: "t1038"), "an untrusted extension kept its timer")
        XCTAssertFalse(services.titles.contains("launch-u"), "untrust replayed the launch handler")
        XCTAssertEqual(services.resets(o), 0, "another extension's resources were released")
        XCTAssertEqual(services.held(o), ["system"], "another extension lost its assertion")
        XCTAssertTrue(TimerScheduler.shared.isScheduled(extID: o, id: "t1038"), "another extension lost its timer")
        XCTAssertTrue(reg.record(id: u)?.trusted == false, "untrust did not take")
    }

    /// Reset of an enabled system extension: one release, then one launch replay that re-takes (as a
    /// re-enable does), and nothing of another extension. The copy, the enabled state and trust stay. The
    /// registry lives wholly in this row's tempDir: reset removes <tempDir>/user/<id> and copies
    /// <tempDir>/system/<id> over it. Parent: timers only, no release, no replay.
    func testResetReleasesOnlyThatExtensionsResources() async throws {
        let services = LaunchRecordingServices()
        let s = "com.test.reset-s", o = "com.test.reset-o"
        defer { TimerScheduler.shared.cancelAll(extID: s); TimerScheduler.shared.cancelAll(extID: o) }
        let reg = try registry(services, [Fixture(id: s, system: true, launch: true, lua: Self.lua("s")),
                                          Fixture(id: o, system: true, launch: true, lua: Self.lua("o"))])
        await holdAndArm(reg, services, [s, o])
        let launched = expectation(description: "launch replayed after reset")
        services.expect("launch-s", launched)

        try reg.reset(id: s)
        await fulfillment(of: [launched], timeout: 30)

        XCTAssertEqual(services.events.filter { $0 == "release \(s)" || $0 == "launch-s" }, ["release \(s)", "launch-s"],
                       "reset must release once, then replay the launch once")
        XCTAssertEqual(services.held(s), ["display"], "the old hold must be gone and the replayed launch's take kept")
        XCTAssertFalse(TimerScheduler.shared.isScheduled(extID: s, id: "t1038"), "a reset extension kept its timer")
        XCTAssertEqual(services.resets(o), 0, "another extension's resources were released")
        XCTAssertEqual(services.held(o), ["system"], "another extension lost its assertion")
        XCTAssertFalse(services.titles.contains("launch-o"), "another extension was launched")
        XCTAssertTrue(TimerScheduler.shared.isScheduled(extID: o, id: "t1038"), "another extension lost its timer")
        XCTAssertTrue(reg.record(id: s)?.isLive == true, "reset must keep the extension enabled and trusted")
    }

    /// Reset of a disabled extension: one release, no replay, still off. The re-enable right after (no
    /// await in between) gives it exactly one launch: a replay queued by reset would run then too.
    func testResetOfADisabledExtensionReleasesWithoutReplay() async throws {
        let services = LaunchRecordingServices()
        let s = "com.test.reset-off"
        let reg = try registry(services, [Fixture(id: s, system: true, launch: true, lua: Self.lua("off"))])
        try reg.setEnabled(false, id: s)
        let before = services.resets(s)

        try reg.reset(id: s)
        XCTAssertEqual(services.resets(s), before + 1, "reset of a disabled extension must release once")
        XCTAssertTrue(reg.record(id: s)?.enabled == false, "reset turned a disabled extension on")

        let launched = expectation(description: "the re-enable's launch")
        services.expect("launch-off", launched)
        try reg.setEnabled(true, id: s)
        await fulfillment(of: [launched], timeout: 30)
        await Task { @MainActor in }.value   // every replay Task queued above is on the lane now
        await reg.deliverEvent(extensionID: s, handler: "on_marker", payloadJSON: "{}")
        XCTAssertEqual(services.titles.filter { $0.hasSuffix("-off") }, ["launch-off", "marker-off"],
                       "reset replayed the launch of a disabled extension")
    }

    /// Reset while a call is parked on the lane: the replayed launch queues behind it, so the old call's
    /// late release comes first and the launch's take stays held.
    func testResetDuringAParkedCallKeepsTheReplayedLaunchsTakes() async throws {
        let services = LaunchRecordingServices()
        let s = "com.test.reset-parked"
        let reg = try registry(services, [Fixture(id: s, system: true, launch: true, lua: Self.lua("parked"))])
        let entered = expectation(description: "handler parked inside prevent_idle_sleep")
        services.blockEntered = entered
        let first = Task { @MainActor in
            await reg.deliverEvent(extensionID: s, handler: "on_hold", payloadJSON: "{}")
        }
        await fulfillment(of: [entered], timeout: 30)
        let launched = expectation(description: "launch replayed after reset")
        services.expect("launch-parked", launched)

        try reg.reset(id: s)                  // teardown while on_hold is inside its host call
        await Task { @MainActor in }.value    // the replay is queued on the lane behind the parked call
        services.release.signal()
        await first.value
        await fulfillment(of: [launched], timeout: 30)

        // #1238: reset leaves the extension on, so the old call does not release late; its take, which landed
        // after the teardown, is undone by the host function itself. Was: release, release, launch.
        XCTAssertEqual(services.events, ["release \(s)", "launch-parked"],
                       "teardown, then the replayed launch: no late release once the extension is back")
        XCTAssertEqual(services.calls(s), ["+system", "-system", "+display"], "the old take undone, the launch's kept")
        XCTAssertEqual(services.held(s), ["display"], "the old call's late take must go and the launch's take stay")
    }

    /// An extension that never ran and subscribes to no launch: untrust and reset release once (a no-op
    /// on the host) and do not crash.
    func testUntrustAndResetOfAnIdleExtensionReleaseOnce() throws {
        let services = LaunchRecordingServices()
        let u = "com.test.idle-u", s = "com.test.idle-s"
        let reg = try registry(services, [Fixture(id: u, system: false, launch: false, lua: Self.lua("idle-u")),
                                          Fixture(id: s, system: true, launch: false, lua: Self.lua("idle-s"))])
        try reg.trust(id: u)
        try reg.untrust(id: u)
        try reg.reset(id: s)
        XCTAssertEqual(services.resets(u), 1, "untrust of an idle extension")
        XCTAssertEqual(services.resets(s), 1, "reset of an idle extension")
        XCTAssertEqual(services.held(u), [])
        XCTAssertEqual(services.held(s), [])
    }

    // MARK: - #1238: the late release is tied to the generation; a retired generation's take is refused

    /// on_take says "wait", then takes "system" (it parks inside the notify or inside the take, as the row asks);
    /// on_live takes "display" (run on the main-actor VM: the live generation); on_launch says "launch-gen".
    private static let genLua = """
        function on_take() host.notify("wait", ""); host.caffeinate.prevent_idle_sleep("system", true) end
        function on_live() host.caffeinate.prevent_idle_sleep("display", true) end
        function on_launch() host.notify("launch-gen", "") end
        """

    /// Starts on_take on the extension's lane; returns once it is parked at `site` ("notify" or "idle").
    private func parkedCall(_ reg: ExtensionRegistry, _ services: LaunchRecordingServices, _ id: String,
                            at site: String) async -> Task<Void, Never> {
        let entered = expectation(description: "on_take parked in \(site)")
        services.blockIn = site
        services.blockEntered = entered
        let call = Task { @MainActor in await reg.deliverEvent(extensionID: id, handler: "on_take", payloadJSON: "{}") }
        await fulfillment(of: [entered], timeout: 30)
        return call
    }

    /// The live generation takes "display" on the main-actor VM (a command's path) while the old call is parked.
    private func liveTake(_ reg: ExtensionRegistry, _ id: String) throws {
        guard let record = reg.record(id: id) else { return XCTFail("no record \(id)") }
        _ = try reg.activate(record).callGlobal("on_live")
    }

    private func genRegistry(_ services: LaunchRecordingServices, _ id: String, launch: Bool = false) throws -> ExtensionRegistry {
        try registry(services, [Fixture(id: id, system: true, launch: launch, lua: Self.genLua)])
    }

    /// I1, plan row (ii): disabled while the call is inside its take; it returns while still off. The take that
    /// landed after the teardown is undone by the host function, and the late release still runs.
    func testI1OldCallReturningWhileOffReleasesLate() async throws {
        let services = LaunchRecordingServices()
        let id = "com.test.gen-i1"
        let reg = try genRegistry(services, id)
        let old = await parkedCall(reg, services, id, at: "idle")
        try reg.setEnabled(false, id: id)
        services.release.signal()
        await old.value
        XCTAssertEqual(services.resets(id), 2, "the teardown's release, then the old call's late release")
        XCTAssertEqual(services.calls(id), ["+system", "-system"], "the take that overtook the teardown is undone")
        XCTAssertEqual(services.held(id), [])
    }

    /// A retired generation's take after the teardown is refused: parked before its take, disabled, let go while
    /// still off. The take never reaches the host: nothing held, nothing for a release to catch.
    func testRetiredGenerationsTakeIsRefused() async throws {
        let services = LaunchRecordingServices()
        let id = "com.test.gen-refused"
        let reg = try genRegistry(services, id)
        let old = await parkedCall(reg, services, id, at: "notify")
        try reg.setEnabled(false, id: id)
        services.release.signal()
        await old.value
        XCTAssertEqual(services.calls(id), [], "a retired generation's take reached the host")
        XCTAssertEqual(services.held(id), [])
        XCTAssertEqual(services.resets(id), 2, "the teardown's release, then the late release (still off)")
    }

    /// I2: disable, enable, then the old call (parked before its take) returns: its take is refused, and nothing
    /// is released late because the extension is back.
    func testI2OldCallReturningAfterReenableDoesNotReleaseLate() async throws {
        let services = LaunchRecordingServices()
        let id = "com.test.gen-i2"
        let reg = try genRegistry(services, id)
        let old = await parkedCall(reg, services, id, at: "notify")
        try reg.setEnabled(false, id: id)
        try reg.setEnabled(true, id: id)
        services.release.signal()
        await old.value
        XCTAssertEqual(services.resets(id), 1, "only the disable's own release: the extension was back on")
        XCTAssertEqual(services.calls(id), [], "a retired generation's take reached the host")
        XCTAssertEqual(services.held(id), [])
    }

    /// I3: disable, enable, disable again, then the old call returns: off again, so it releases late.
    func testI3OldCallReturningWhenOffAgainReleasesLate() async throws {
        let services = LaunchRecordingServices()
        let id = "com.test.gen-i3"
        let reg = try genRegistry(services, id)
        let old = await parkedCall(reg, services, id, at: "notify")
        try reg.setEnabled(false, id: id)
        try reg.setEnabled(true, id: id)
        try reg.setEnabled(false, id: id)
        services.release.signal()
        await old.value
        XCTAssertEqual(services.resets(id), 3, "two teardowns, then the late release")
        XCTAssertEqual(services.calls(id), [])
        XCTAssertEqual(services.held(id), [])
    }

    /// I4, plan row (i): disable, enable, the live generation takes "display" on the main-actor VM, then the old
    /// call returns: the live take is kept and the old take refused. Parent: the late release dropped "display".
    func testI4LiveGenerationsTakeSurvivesTheOldCallsReturn() async throws {
        let services = LaunchRecordingServices()
        let id = "com.test.gen-i4"
        let reg = try genRegistry(services, id)
        let old = await parkedCall(reg, services, id, at: "notify")
        try reg.setEnabled(false, id: id)
        try reg.setEnabled(true, id: id)
        try liveTake(reg, id)
        services.release.signal()
        await old.value
        XCTAssertEqual(services.resets(id), 1)
        XCTAssertEqual(services.calls(id), ["+display"], "the old generation's take reached the host")
        XCTAssertEqual(services.held(id), ["display"], "the live generation lost its take")
    }

    /// I5, the residual case: the old call is already inside its take when the disable runs; enable, the live take,
    /// then the take lands and the call returns. The landed take is undone at once; the live one stays.
    func testI5TakeOvertakenByTheTeardownIsUndone() async throws {
        let services = LaunchRecordingServices()
        let id = "com.test.gen-i5"
        let reg = try genRegistry(services, id)
        let old = await parkedCall(reg, services, id, at: "idle")
        try reg.setEnabled(false, id: id)
        try reg.setEnabled(true, id: id)
        try liveTake(reg, id)
        services.release.signal()
        await old.value
        XCTAssertEqual(services.resets(id), 1)
        XCTAssertEqual(services.calls(id), ["+display", "+system", "-system"], "the overtaken take must be undone")
        XCTAssertEqual(services.held(id), ["display"], "a dead generation's take stayed held, or the live one went")
    }

    /// I6: reset during a parked call, then a take of the live generation: reset leaves the extension on, so the
    /// old call neither takes nor releases late; the live take and the replayed launch both stand.
    func testI6ResetDuringAParkedCallKeepsTheLiveGenerationsTake() async throws {
        let services = LaunchRecordingServices()
        let s = "com.test.gen-i6"
        let reg = try genRegistry(services, s, launch: true)
        let old = await parkedCall(reg, services, s, at: "notify")
        let launched = expectation(description: "launch replayed after reset")
        services.expect("launch-gen", launched)
        try reg.reset(id: s)                  // registry inside this row's tempDir: <tempDir>/user/<id> only
        try liveTake(reg, s)
        services.release.signal()
        await old.value
        await fulfillment(of: [launched], timeout: 30)
        XCTAssertEqual(services.events, ["release \(s)", "wait", "launch-gen"], "no late release after a reset")
        XCTAssertEqual(services.calls(s), ["+display"], "the old generation's take reached the host")
        XCTAssertEqual(services.held(s), ["display"], "the live generation lost its take")
        XCTAssertTrue(reg.record(id: s)?.isLive == true)
    }
}
