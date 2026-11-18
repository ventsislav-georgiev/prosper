import XCTest
@testable import ProsperApp

/// #1071: the startup event (system.launch) reaches an extension once per app launch and once per
/// re-enable, and each re-enable only that extension. testReenableLaunchesOnlyThatExtension holds the
/// "enable sends once, to that one" row; these hold the repeat and the launch broadcast.
extension ExtensionReenableLaunchTests {

    private static func launchLua(_ tag: String) -> String {
        """
        function on_launch() host.notify("launch-\(tag)", "") end
        function on_marker() host.notify("marker-\(tag)", "") end
        """
    }

    /// Disable then enable, twice: each enable launches A once more. A marker on A's lane after each
    /// launch lands behind any stray second delivery queued by the same enable.
    func testEachReenableSendsTheLaunchAgain() async throws {
        let services = LaunchRecordingServices()
        let a = "com.test.launch-again"
        let reg = try registry(services, [Fixture(id: a, system: true, launch: true, lua: Self.launchLua("a"))])
        for round in 1...2 {
            let launched = expectation(description: "launch after re-enable \(round)")
            services.expect("launch-a", launched)
            try reg.setEnabled(false, id: a)
            try reg.setEnabled(true, id: a)
            await fulfillment(of: [launched], timeout: 30)
            await Task { @MainActor in }.value   // every replay Task queued above is on the lane now
            await reg.deliverEvent(extensionID: a, handler: "on_marker", payloadJSON: "{}")
        }
        XCTAssertEqual(services.titles, ["launch-a", "marker-a", "launch-a", "marker-a"],
                       "each re-enable must send the launch exactly once")
    }

    /// App launch (AppDelegate's broadcastEvent("system.launch")): every live subscriber once; an
    /// extension that does not subscribe, a disabled one and an untrusted one get nothing.
    func testLaunchBroadcastSendsOnceToEachSubscriber() async throws {
        let services = LaunchRecordingServices()
        let a = "com.test.boot-a", b = "com.test.boot-b", n = "com.test.boot-none"
        let off = "com.test.boot-off", u = "com.test.boot-untrusted"
        let reg = try registry(services, [
            Fixture(id: a, system: true, launch: true, lua: Self.launchLua("a")),
            Fixture(id: b, system: true, launch: true, lua: Self.launchLua("b")),
            Fixture(id: n, system: true, launch: false, lua: Self.launchLua("n")),
            Fixture(id: off, system: true, launch: true, lua: Self.launchLua("off")),
            Fixture(id: u, system: false, launch: true, lua: Self.launchLua("u")),
        ])
        try reg.setEnabled(false, id: off)
        XCTAssertTrue(reg.record(id: u)?.trusted == false, "user fixture must start untrusted")
        let la = expectation(description: "launch-a"), lb = expectation(description: "launch-b")
        services.expect("launch-a", la)
        services.expect("launch-b", lb)

        reg.broadcastEvent("system.launch")
        await fulfillment(of: [la, lb], timeout: 30)
        await Task { @MainActor in }.value   // every delivery Task the broadcast queued is on its lane now
        await reg.deliverEvent(extensionID: a, handler: "on_marker", payloadJSON: "{}")
        await reg.deliverEvent(extensionID: b, handler: "on_marker", payloadJSON: "{}")

        let launches = services.titles.filter { $0.hasPrefix("launch-") }
        XCTAssertEqual(launches.sorted(), ["launch-a", "launch-b"], "one launch to each live subscriber, none to the rest")
        XCTAssertTrue(reg.record(id: n)?.runtime == nil, "a non-subscriber was started by the launch")
        XCTAssertTrue(reg.record(id: u)?.runtime == nil, "an untrusted extension spawned a VM")
    }
}
