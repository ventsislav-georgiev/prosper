import XCTest
@testable import ProsperApp

/// #298: a huge finite delay/interval must clamp, not trap in `DispatchTime + Double`.
final class TimerSchedulerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "TimerSchedulerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func persisted() -> [[String: Any]] {
        guard let d = defaults.data(forKey: "ext.timers.v1") else { return [] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []
    }

    /// Polls until the serial queue has persisted the entry with id `id`.
    private func waitFor(_ id: String) -> [String: Any]? {
        for _ in 0..<200 {
            if let e = persisted().first(where: { $0["id"] as? String == id }) { return e }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    func testHugeSecondsClampAndArm() {
        let s = TimerScheduler(defaults: defaults)
        for (i, secs) in [1e12, 1e308].enumerated() {
            for every in [false, true] {
                let id = "t\(i)\(every)"
                s.schedule(extID: "x", id: id, every: every, seconds: secs, handler: "h")
                let e = waitFor(id)
                XCTAssertEqual(e?["interval"] as? Double, TimerScheduler.maxDelay)
            }
        }
    }

    func testRestoreWithHugePersistedFireAtDoesNotTrap() throws {
        let bomb: [[String: Any]] = [
            ["extID": "x", "id": "a", "handler": "h", "every": false, "interval": 1e300, "fireAt": 1e300],
            ["extID": "x", "id": "b", "handler": "h", "every": true, "interval": 1e300, "fireAt": 1e300],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: bomb), forKey: "ext.timers.v1")
        let s = TimerScheduler(defaults: defaults)
        s.restore()
        // Serial queue: once this lands, restore has armed both bombs.
        s.schedule(extID: "x", id: "sentinel", every: false, seconds: 1, handler: "h")
        XCTAssertNotNil(waitFor("sentinel"))
        XCTAssertEqual(Set(persisted().compactMap { $0["id"] as? String }), ["a", "b", "sentinel"])
    }
}
