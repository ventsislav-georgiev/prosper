import XCTest
@testable import StatsCore

// These exercise the private-API readers against live hardware. They assert
// invariants (ranges, no NaN) rather than exact values, and print observed
// numbers for manual sanity. Validated to not segfault via scratchpad spikes.

final class IOHIDSensorsTests: XCTestCase {
    func testTemperaturesInPlausibleRange() throws {
        guard let s = IOHIDSensors() else {
            throw XCTSkip("IOHIDEventSystemClient unavailable")
        }
        let temps = s.read()
        XCTAssertFalse(temps.isEmpty, "expected at least one temperature sensor")
        for t in temps {
            XCTAssert(t.celsius > 0 && t.celsius < 150, "\(t.name)=\(t.celsius)°C out of range")
            XCTAssertFalse(t.name.isEmpty)
        }
        let avg = temps.map(\.celsius).reduce(0, +) / Double(temps.count)
        print("IOHID: \(temps.count) sensors, avg \(String(format: "%.1f", avg))°C")
    }
}

final class GPUReaderTests: XCTestCase {
    func testUtilizationInRange() throws {
        var r = GPUReader()
        let s = try r.read()
        XCTAssert(s.utilization >= 0 && s.utilization <= 1, "util \(s.utilization) out of range")
        XCTAssertFalse(s.name.isEmpty)
        print("GPU: \(s.name) util=\(String(format: "%.1f", s.utilization * 100))% mem=\(s.usedMemory / 1_048_576)MB")
    }
}

final class IOReportKitTests: XCTestCase {
    func testPowerNonNegativeAndBounded() throws {
        guard let k = IOReportKit() else { throw XCTSkip("libIOReport unavailable") }
        _ = k.read()                       // seed
        Thread.sleep(forTimeInterval: 0.3)
        guard let p = k.read() else { return XCTFail("nil power sample after seed") }
        // Idle-to-load: bounded sanity. A whole Mac SoC is well under 200W.
        for (label, w) in [("cpu", p.cpuWatts), ("gpu", p.gpuWatts), ("ane", p.aneWatts)] {
            XCTAssert(w >= 0 && w < 200 && w.isFinite, "\(label)=\(w)W implausible (unit-scale bug?)")
        }
        XCTAssertEqual(p.totalWatts, p.cpuWatts + p.gpuWatts + p.aneWatts, accuracy: 0.001)
        print("Power: CPU=\(String(format: "%.2f", p.cpuWatts))W GPU=\(String(format: "%.2f", p.gpuWatts))W ANE=\(String(format: "%.2f", p.aneWatts))W")
    }

    func testFirstReadSeedsZero() throws {
        guard let k = IOReportKit() else { throw XCTSkip("libIOReport unavailable") }
        let p = k.read()
        XCTAssertEqual(p?.totalWatts, 0, "first read is a baseline seed")
    }
}
