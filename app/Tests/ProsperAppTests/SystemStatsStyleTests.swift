import XCTest
import SwiftUI
@testable import ProsperApp
@testable import StatsCore

/// Pure-logic coverage for the System Stats widget model and formatters — the
/// branchy bits (threshold ramp, ramp-value normalization, menu-bar order
/// filtering, compact number formatting) that have a wrong answer if broken.
final class SystemStatsStyleTests: XCTestCase {

    // MARK: - Threshold ramp

    func testRampColorBands() {
        var cfg = ModuleWidgetConfig.defaultFor(.cpu)   // med 0.5, high 0.8
        cfg.low = RGBAColor(0, 0, 0); cfg.med = RGBAColor(0.5, 0.5, 0.5); cfg.high = RGBAColor(1, 1, 1)
        XCTAssertEqual(RGBAColor(cfg.rampColor(0.10)).r, 0.0, accuracy: 0.01, "below med → low")
        XCTAssertEqual(RGBAColor(cfg.rampColor(0.49)).r, 0.0, accuracy: 0.01)
        XCTAssertEqual(RGBAColor(cfg.rampColor(0.50)).r, 0.5, accuracy: 0.01, "at med threshold → med")
        XCTAssertEqual(RGBAColor(cfg.rampColor(0.79)).r, 0.5, accuracy: 0.01)
        XCTAssertEqual(RGBAColor(cfg.rampColor(0.80)).r, 1.0, accuracy: 0.01, "at high threshold → high")
        XCTAssertEqual(RGBAColor(cfg.rampColor(2.0)).r, 1.0, accuracy: 0.01, "over-range clamps to high")
    }

    // MARK: - Defaults

    func testDefaultsOnlyCPUandRAMEnabled() {
        for m in StatsModule.allCases {
            let on = ModuleWidgetConfig.defaultFor(m).enabled
            if m == .cpu || m == .memory { XCTAssertTrue(on, "\(m) should default on") }
            else { XCTAssertFalse(on, "\(m) should default off") }
        }
    }

    func testDefaultStyleOrderCoversAllModules() {
        let order = Set(StatsWidgetStyle.default.order)
        XCTAssertEqual(order, Set(StatsModule.allCases.map(\.rawValue)), "every module placed in order")
    }

    // MARK: - enabledModules (order + filter)

    func testEnabledModulesRespectsOrderAndFilter() {
        var style = StatsWidgetStyle.default
        // Enable only GPU and CPU; assert order follows `order`, not insertion.
        for k in style.modules.keys { style.modules[k]?.enabled = false }
        style.modules[StatsModule.gpu.rawValue]?.enabled = true
        style.modules[StatsModule.cpu.rawValue]?.enabled = true
        style.order = [StatsModule.gpu.rawValue, StatsModule.cpu.rawValue]
        XCTAssertEqual(style.enabledModules, [.gpu, .cpu])
    }

    func testEnabledModulesDropsUnknownKeys() {
        var style = StatsWidgetStyle.default
        style.order = ["bogus", StatsModule.cpu.rawValue]
        style.modules[StatsModule.cpu.rawValue]?.enabled = true
        XCTAssertEqual(style.enabledModules, [.cpu], "unknown rawValue ignored")
    }

    // MARK: - ramp value normalization

    func testRampValueNormalization() {
        var snap = StatsSnapshot()
        // sensors: (t-30)/70 clamped 0…1
        snap.temperatures = [TempSensor(name: "x", celsius: 30), TempSensor(name: "y", celsius: 100)]
        XCTAssertEqual(StatsModule.sensors.rampValue(snap)!, 1.0, accuracy: 0.001, "100°C → 1.0")
        snap.temperatures = [TempSensor(name: "x", celsius: 30)]
        XCTAssertEqual(StatsModule.sensors.rampValue(snap)!, 0.0, accuracy: 0.001, "30°C → 0")
        snap.temperatures = [TempSensor(name: "x", celsius: 10)]
        XCTAssertEqual(StatsModule.sensors.rampValue(snap)!, 0.0, accuracy: 0.001, "below band clamps to 0")

        // battery ramp reddens as it drains: 1 - charge
        snap.battery = BatterySample(charge: 0.2, isCharging: false, isPluggedIn: false,
                                     timeToEmpty: 10, timeToFull: -1, cycleCount: 1,
                                     health: 0.9, powerWatts: -5, temperature: 30)
        XCTAssertEqual(StatsModule.battery.rampValue(snap)!, 0.8, accuracy: 0.001)

        // power clamps at 60W
        snap.power = PowerSample(cpuWatts: 30, gpuWatts: 40, aneWatts: 0, totalWatts: 70)
        XCTAssertEqual(StatsModule.power.rampValue(snap)!, 1.0, accuracy: 0.001)

        XCTAssertNil(StatsModule.network.rampValue(snap), "network is channel-coloured, no ramp")
    }

    func testPrimaryTextPlaceholderWhenNoSample() {
        let empty = StatsSnapshot()
        XCTAssertEqual(StatsModule.cpu.primaryText(empty, showUnit: true), "—")
        XCTAssertEqual(StatsModule.network.primaryText(empty, showUnit: true), "", "network has no single text")
    }

    // MARK: - Formatters

    func testRateFormat() {
        XCTAssertEqual(StatsFormat.rate(2_500_000_000), "2.5G")
        XCTAssertEqual(StatsFormat.rate(1_500_000), "1.5M")
        XCTAssertEqual(StatsFormat.rate(840_000), "840K")
        XCTAssertEqual(StatsFormat.rate(12), "12B")
        XCTAssertEqual(StatsFormat.rate(-5), "0B", "negative clamps to 0")
    }

    func testScalarFormats() {
        XCTAssertEqual(StatsFormat.percent(0.126), "13%")
        XCTAssertEqual(StatsFormat.temp(40.4), "40°")
        XCTAssertEqual(StatsFormat.watts(2.34), "2.3W")
        XCTAssertEqual(StatsFormat.bytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(StatsFormat.bytes(1_048_576), "1 MB")
    }

    // MARK: - Persistence round-trip

    func testStyleCodableRoundTrip() throws {
        var style = StatsWidgetStyle.default
        style.alignment = .trailing
        style.modules[StatsModule.gpu.rawValue]?.high = RGBAColor(0.1, 0.2, 0.3, 0.5)
        let data = try JSONEncoder().encode(style)
        let back = try JSONDecoder().decode(StatsWidgetStyle.self, from: data)
        XCTAssertEqual(style, back)
    }
}
