import XCTest

@testable import ProsperApp
@testable import StatsCore

/// #769: fewer Stats wakes — slower defaults for anyone who never picked an interval,
/// and no main-thread publish for a tick nothing on the menu bar would show.
@MainActor
final class StatsEnergyTests: XCTestCase {
    func testDefaultsAreFiveAndTenAndASavedValueStays() {
        let keys = ["statsRefreshInterval", "statsSensorsInterval"]   // Preferences.Keys is private
        let saved = keys.map { Preferences.defaults.object(forKey: $0) }
        defer {
            for (k, v) in zip(keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        keys.forEach { Preferences.defaults.removeObject(forKey: $0) }
        XCTAssertEqual(Preferences.statsRefreshInterval, 5, "fresh base interval")
        XCTAssertEqual(Preferences.statsSensorsInterval, 10, "fresh sensors interval")
        Preferences.statsRefreshInterval = 3
        Preferences.statsSensorsInterval = 3
        XCTAssertEqual(Preferences.statsRefreshInterval, 3, "a saved 3 s stays 3 s")
        XCTAssertEqual(Preferences.statsSensorsInterval, 3, "a saved sensors 3 s stays")
    }

    private func snap(charge: Double, timeToEmpty: Int = 10, cpuHistory: [Double] = [0.1, 0.2]) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.battery = BatterySample(charge: charge, isCharging: false, isPluggedIn: false,
                                  timeToEmpty: timeToEmpty, timeToFull: -1, cycleCount: 1,
                                  health: 0.9, powerWatts: -5, temperature: 30)
        s.histories = ["cpu": cpuHistory]
        return s
    }

    func testUnchangedSampleDoesNotDeliverAndAChangedOneDoes() {
        let style = StatsWidgetStyle.default   // cpu draws a sparkline, battery text + bar
        let shown: [StatsModule] = [.cpu, .battery]
        func key(_ s: StatsSnapshot) -> [AnyHashable] { StatsDeliverGate.key(shown, s, style: style) }
        var gate = StatsDeliverGate()
        XCTAssertTrue(gate.admit(key(snap(charge: 0.5)), popupShown: false), "first tick publishes")
        XCTAssertFalse(gate.admit(key(snap(charge: 0.5)), popupShown: false), "identical tick is skipped")
        XCTAssertFalse(gate.admit(key(snap(charge: 0.5, timeToEmpty: 99)), popupShown: false),
                       "a popup-only field moving is not drawn on the menu bar")
        XCTAssertTrue(gate.admit(key(snap(charge: 0.49, timeToEmpty: 99)), popupShown: false), "battery moved")
        XCTAssertTrue(gate.admit(key(snap(charge: 0.49, timeToEmpty: 99, cpuHistory: [0.2, 0.3])), popupShown: false),
                      "the sparkline moved")
        XCTAssertTrue(gate.admit(key(snap(charge: 0.49, timeToEmpty: 99, cpuHistory: [0.2, 0.3])), popupShown: true),
                      "an open popup always gets the tick")
    }
}
