import XCTest
@testable import ProsperApp

/// Records every remote-wake call that reaches the host seam (never the real helper) and
/// keeps host.prefs in memory. Every other service is a no-op.
private final class RemoteWakeRecorder: ExtensionHostServices, @unchecked Sendable {
    private let lock = NSLock()
    private var prefs: [String: String] = [:]
    private var _calls: [String] = []
    private var launched: XCTestExpectation?

    /// "<extension id> on|off <device id>", in the order they reached the seam.
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    func expectLaunch(_ e: XCTestExpectation) { lock.lock(); launched = e; lock.unlock() }
    func setPref(_ id: String, _ key: String, _ value: String) { prefSet(extensionID: id, key: key, value: value) }

    func caffeinateSetRemoteWake(extensionID: String, enabled: Bool, deviceID: String, intervalAC: Double,
                                 intervalBatt: Double, batteryFloor: Int) async {
        lock.withLock { _calls.append("\(extensionID) \(enabled ? "on" : "off") \(deviceID)") }
    }
    func prefGet(extensionID: String, key: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return prefs["\(extensionID)|\(key)"]
    }
    func prefSet(extensionID: String, key: String, value: String) {
        lock.lock(); prefs["\(extensionID)|\(key)"] = value; lock.unlock()
    }
    func notify(title: String, body: String) {
        lock.lock(); let e = launched; launched = nil; lock.unlock()
        e?.fulfill()
    }

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
    func listDirectories(_ path: String) -> [String] { [] }
}

/// #1072: off means off. A disabled Calculator, Units or Currency extension answers nothing
/// in the launcher (its native fallback included), and turning OpenLid off disarms Remote
/// Wake, which comes back from its saved setting when OpenLid is turned on again.
@MainActor
final class ExtensionOffMeansOffTests: XCTestCase {

    private func install(_ registry: ExtensionRegistry) {
        let previous = CommandRouter.registry
        CommandRouter.registry = registry
        addTeardownBlock { @MainActor in CommandRouter.registry = previous }
    }

    /// Set a `Preferences.defaults` key (the XCTest in-memory store) for the test only.
    private func setPref(_ value: Any, _ key: String) {
        let d = Preferences.defaults
        let old = d.object(forKey: key)
        d.set(value, forKey: key)
        addTeardownBlock {
            if let old { d.set(old, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }

    // MARK: answers (fixtures contribute no command, so only the native fallback can answer)

    func testCalcAnswerStopsWithTheExtension() async throws {
        let reg = try gateFixture([(CommandRouter.calcID, [])]).registry()
        install(reg)
        func isCalc(_ o: RunnerOutcome) -> Bool { if case .calc = o { return true }; return false }
        let on = await CommandRouter.run("2+3")
        XCTAssertTrue(isCalc(on), "live: the native calculator answers")
        try reg.setEnabled(false, id: CommandRouter.calcID)
        let off = await CommandRouter.run("2+3")
        XCTAssertFalse(isCalc(off), "disabled: no calculator answer")
        try reg.setEnabled(true, id: CommandRouter.calcID)
        let back = await CommandRouter.run("2+3")
        XCTAssertTrue(isCalc(back), "re-enabled: the answer is back")
    }

    func testUnitAnswerStopsWithTheExtension() async throws {
        let reg = try gateFixture([(CommandRouter.unitsID, [])]).registry()
        install(reg)
        func isUnit(_ o: RunnerOutcome) -> Bool { if case .unit = o { return true }; return false }
        let on = await CommandRouter.run("1 km to m")
        XCTAssertTrue(isUnit(on), "live: the native unit conversion answers")
        try reg.setEnabled(false, id: CommandRouter.unitsID)
        let off = await CommandRouter.run("1 km to m")
        XCTAssertFalse(isUnit(off), "disabled: no unit answer")
        try reg.setEnabled(true, id: CommandRouter.unitsID)
        let back = await CommandRouter.run("1 km to m")
        XCTAssertTrue(isUnit(back), "re-enabled: the answer is back")
    }

    func testCurrencyAnswerStopsWithTheExtension() async throws {
        // Today's rates in the in-memory store, so CurrencyService never fetches.
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        setPref(["EUR": 0.5], "fxRates")
        setPref(f.string(from: Date()), "fxRatesDay")
        let reg = try gateFixture([(CommandRouter.currencyID, [])]).registry()
        install(reg)
        func isCurrency(_ o: RunnerOutcome) -> Bool { if case .currency = o { return true }; return false }
        let on = await CommandRouter.run("2 usd to eur")
        XCTAssertTrue(isCurrency(on), "live: the native currency conversion answers")
        try reg.setEnabled(false, id: CommandRouter.currencyID)
        let off = await CommandRouter.run("2 usd to eur")
        XCTAssertFalse(isCurrency(off), "disabled: no currency answer")
        try reg.setEnabled(true, id: CommandRouter.currencyID)
        let back = await CommandRouter.run("2 usd to eur")
        XCTAssertTrue(isCurrency(back), "re-enabled: the answer is back")
    }

    // MARK: OpenLid Remote Wake

    /// An OpenLid stand-in (system, `system.launch` subscriber) whose on_launch re-arms Remote
    /// Wake from its saved setting the way openlid's does, plus a second system extension.
    private func openLidRegistry(_ services: RemoteWakeRecorder) throws -> ExtensionRegistry {
        let root = tempDir("offmeans-openlid")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let lua = """
            function on_launch()
              if host.prefs.get("remote_wake") == "true" then
                host.caffeinate.set_remote_wake{ enabled = true, device_id = host.prefs.get("rw_device_id") or "" }
              end
              host.notify("launched", "")
            end
            """
        for id in [ExtensionRegistry.openLidID, "com.test.other"] {
            let dir = root.appendingPathComponent("system/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try """
            [extension]
            id = "\(id)"
            name = "fixture"
            title = "Fixture"
            description = "remote wake fixture"
            version = "1.0.0"
            author = "tester"
            system = true

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
        }
        let registry = ExtensionRegistry(
            systemDir: root.appendingPathComponent("system", isDirectory: true),
            userDir: root.appendingPathComponent("user", isDirectory: true),
            hostVersion: "2.0.0", defaults: scratchDefaults("offmeans-openlid"), services: services)
        registry.discover()
        XCTAssertTrue(registry.record(id: ExtensionRegistry.openLidID) != nil, "openlid fixture not discovered")
        return registry
    }

    /// Every remote-wake call queued so far has reached the seam (the apply chain is serial).
    private func drainApplyChain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            LidSleepHelper.enqueueApply { c.resume() }
        }
    }

    func testDisablingOpenLidDisarmsRemoteWakeAndEnablingRestoresIt() async throws {
        let services = RemoteWakeRecorder()
        services.setPref(ExtensionRegistry.openLidID, "remote_wake", "true")
        services.setPref(ExtensionRegistry.openLidID, "rw_device_id", "api-host")
        let reg = try openLidRegistry(services)
        let id = ExtensionRegistry.openLidID

        try reg.setEnabled(false, id: id)
        try reg.setEnabled(false, id: id)   // already off: no second disarm
        await drainApplyChain()
        XCTAssertEqual(services.calls, ["\(id) off api-host"], "one disarm on disable")
        XCTAssertEqual(services.prefGet(extensionID: id, key: "remote_wake"), "true", "the saved setting is kept")

        let launched = expectation(description: "on_launch replayed")
        services.expectLaunch(launched)
        try reg.setEnabled(true, id: id)
        await fulfillment(of: [launched], timeout: 10)
        await drainApplyChain()
        XCTAssertEqual(services.calls, ["\(id) off api-host", "\(id) on api-host"], "one restore on enable")
    }

    func testRemoteWakeLeftAloneWhenItWasOffOrAnotherExtensionTurnsOff() async throws {
        let services = RemoteWakeRecorder()
        services.setPref("com.test.other", "remote_wake", "true")   // not OpenLid: never disarms
        let reg = try openLidRegistry(services)
        try reg.setEnabled(false, id: "com.test.other")
        try reg.setEnabled(false, id: ExtensionRegistry.openLidID)   // Remote Wake saved off
        await drainApplyChain()
        XCTAssertEqual(services.calls, [], "nothing armed, nothing to disarm")

        let launched = expectation(description: "on_launch replayed")
        services.expectLaunch(launched)
        try reg.setEnabled(true, id: ExtensionRegistry.openLidID)
        await fulfillment(of: [launched], timeout: 10)
        await drainApplyChain()
        XCTAssertEqual(services.calls, [], "saved off stays off on enable")
    }
}
