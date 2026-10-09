import XCTest

@testable import ProsperApp
@testable import StatsCore

/// #189: a value tick must not force a width re-measure (layoutSubtreeIfNeeded +
/// fittingSize) for widgets that reserve a fixed width sample.
final class StatsWidthGateTests: XCTestCase {
    private let style = StatsWidgetStyle.default

    private func battery(_ charge: Double) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.battery = BatterySample(charge: charge, isCharging: false, isPluggedIn: false,
                                  timeToEmpty: 10, timeToFull: -1, cycleCount: 1,
                                  health: 0.9, powerWatts: -5, temperature: 30)
        return s
    }

    func testValueTickDoesNotResizeFixedWidthWidget() {
        var gate = StatsWidthGate()
        let k1 = StatsWidthGate.key(.battery, battery(0.07), showUnit: true)
        let k2 = StatsWidthGate.key(.battery, battery(1.0), showUnit: true)
        XCTAssertEqual(k1, k2, "7% and 100% fit the reserved \"100%\" sample")
        XCTAssertTrue(gate.needsResize(.battery, key: k1, style: style, scale: 1), "first sight measures")
        XCTAssertFalse(gate.needsResize(.battery, key: k2, style: style, scale: 1), "value tick must not resize")
    }

    func testPowerOverflowingSampleStillResizes() {
        var lo = StatsSnapshot(), hi = StatsSnapshot()
        lo.power = PowerSample(cpuWatts: 5, gpuWatts: 0, aneWatts: 0, totalWatts: 12.3)
        hi.power = PowerSample(cpuWatts: 90, gpuWatts: 30, aneWatts: 0, totalWatts: 123.4)
        var gate = StatsWidthGate()
        _ = gate.needsResize(.power, key: StatsWidthGate.key(.power, lo, showUnit: true), style: style, scale: 1)
        XCTAssertTrue(gate.needsResize(.power, key: StatsWidthGate.key(.power, hi, showUnit: true),
                                       style: style, scale: 1), "\"123.4W\" is wider than the \"99.9W\" sample")
    }

    func testNetworkKeysOnRates() {
        var a = StatsSnapshot(), b = StatsSnapshot()
        a.network = NetworkSample(uploadBytesPerSec: 10, downloadBytesPerSec: 10, totalUploaded: 0, totalDownloaded: 0)
        b.network = NetworkSample(uploadBytesPerSec: 10, downloadBytesPerSec: 50_000_000,
                                  totalUploaded: 0, totalDownloaded: 0)
        var gate = StatsWidthGate()
        XCTAssertTrue(gate.needsResize(.network, key: StatsWidthGate.key(.network, a, showUnit: true), style: style, scale: 1))
        XCTAssertTrue(gate.needsResize(.network, key: StatsWidthGate.key(.network, b, showUnit: true), style: style, scale: 1))
        XCTAssertFalse(gate.needsResize(.network, key: StatsWidthGate.key(.network, b, showUnit: true), style: style, scale: 1))
    }

    func testStyleScaleAndForgetReprobe() {
        var gate = StatsWidthGate()
        XCTAssertTrue(gate.needsResize(.cpu, key: "", style: style, scale: 1))
        XCTAssertTrue(gate.needsResize(.cpu, key: "", style: style, scale: 2), "theme scale change")
        var other = style
        other.alignment = style.alignment == .leading ? .trailing : .leading
        XCTAssertTrue(gate.needsResize(.cpu, key: "", style: other, scale: 2), "style change")
        XCTAssertFalse(gate.needsResize(.cpu, key: "", style: other, scale: 2))
        gate.forget(.cpu)
        XCTAssertTrue(gate.needsResize(.cpu, key: "", style: other, scale: 2), "re-created item measures once")
    }

    /// #240: syncItems creates items via admit(); a module measured, torn down and
    /// re-created must be measured again (teardown leaves the gate untouched).
    func testReCreatedItemMeasuresAgain() {
        var gate = StatsWidthGate()
        XCTAssertEqual(gate.admit([.cpu, .memory], live: []), [.cpu, .memory])
        XCTAssertTrue(gate.needsResize(.cpu, key: "", style: style, scale: 1))
        XCTAssertFalse(gate.needsResize(.cpu, key: "", style: style, scale: 1))
        XCTAssertEqual(gate.admit([.cpu, .memory], live: [.cpu, .memory]), [], "live items are not re-created")
        XCTAssertFalse(gate.needsResize(.cpu, key: "", style: style, scale: 1), "live item keeps its memo")
        XCTAssertEqual(gate.admit([.cpu], live: []), [.cpu], "after teardown the item is re-created")
        XCTAssertTrue(gate.needsResize(.cpu, key: "", style: style, scale: 1), "re-created item measures once")
    }
}
