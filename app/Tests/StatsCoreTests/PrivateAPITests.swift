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
        XCTAssert(s.renderUtil.isNaN || (s.renderUtil >= 0 && s.renderUtil <= 1), "render \(s.renderUtil)")
        XCTAssert(s.tilerUtil.isNaN || (s.tilerUtil >= 0 && s.tilerUtil <= 1), "tiler \(s.tilerUtil)")
        XCTAssertGreaterThanOrEqual(s.coreCount, 0)
        if SystemFacts.current.isAppleSilicon { XCTAssertGreaterThan(s.coreCount, 0, "AS GPU has cores") }
        print("GPU cores=\(s.coreCount)")
        print("GPU: \(s.name) util=\(String(format: "%.1f", s.utilization * 100))% mem=\(s.usedMemory / 1_048_576)MB")
    }
}

final class CPUFrequencyTests: XCTestCase {
    func testFreqTablesDecodeToSaneGHz() throws {
        guard SystemFacts.current.isAppleSilicon else { throw XCTSkip("freq tables Apple-Silicon only") }
        let (e, p) = CPUFrequency.readFreqTables()
        XCTAssertFalse(e.isEmpty && p.isEmpty, "expected E or P DVFS table on Apple Silicon")
        for (label, tbl) in [("E", e), ("P", p)] where !tbl.isEmpty {
            // Monotonic-ish, all in a plausible per-state range.
            for f in tbl { XCTAssert(f > 0.3 && f < 8.0, "\(label) state \(f)GHz out of range") }
            XCTAssert(tbl.max()! > 1.5, "\(label) max \(tbl.max()!)GHz too low")
        }
        print("Freq tables: E maxGHz=\(String(format: "%.2f", e.max() ?? 0)) P maxGHz=\(String(format: "%.2f", p.max() ?? 0))")
    }

    func testResidencyWeightedFreqInRange() throws {
        guard let f = CPUFrequency(minInterval: 0) else { throw XCTSkip("CPU Stats / DVFS unavailable") }
        _ = f.read()                       // seed
        Thread.sleep(forTimeInterval: 0.3)
        let (e, p) = f.read()
        // NaN allowed (cluster parked all interval); any number must be sane GHz.
        for (label, v) in [("E", e), ("P", p)] where !v.isNaN {
            XCTAssert(v > 0.3 && v < 8.0, "\(label) weighted \(v)GHz out of range")
        }
        print("Weighted freq: E=\(String(format: "%.2f", e)) P=\(String(format: "%.2f", p)) GHz")
    }

    // Hot path: CPUReader.read() runs every fast tick and calls freq.read().
    // The throttle must keep that amortized cost near-zero (cached between
    // ~1.5s samples) — a regression that removed it would jump to ~7ms/tick.
    func testThrottledReadIsCheapOnHotPath() throws {
        guard let f = CPUFrequency() else { throw XCTSkip("CPU Stats unavailable") }
        _ = f.read()                                   // seed + arm throttle
        let start = Date()
        for _ in 0..<1000 { _ = f.read() }             // all within the throttle window
        let ms = Date().timeIntervalSince(start) * 1000 / 1000
        print("CPUFrequency.read (throttled) avg \(String(format: "%.4f", ms))ms")
        XCTAssert(ms < 0.5, "throttled freq read \(ms)ms — throttle regressed?")
    }

    // A forced fresh sample is IOReport-bound (samples the whole CPU Stats group).
    // Documented ceiling, not a hot-path number — it only runs ~every 1.5s.
    func testFreshSampleBounded() throws {
        guard let f = CPUFrequency(minInterval: 0) else { throw XCTSkip("CPU Stats unavailable") }
        _ = f.read(); Thread.sleep(forTimeInterval: 0.05)
        let start = Date()
        _ = f.read()
        let ms = Date().timeIntervalSince(start) * 1000
        print("CPUFrequency fresh sample \(String(format: "%.2f", ms))ms")
        XCTAssert(ms < 20.0, "fresh IOReport sample \(ms)ms implausibly slow")
    }
}

final class GPUFrameRateTests: XCTestCase {
    func testFrameRateInRange() throws {
        guard let fr = GPUFrameRate(minInterval: 0) else { throw XCTSkip("DCP IOReport unavailable") }
        _ = fr.read()                      // seed
        Thread.sleep(forTimeInterval: 0.5)
        let fps = fr.read()
        // 0 (static screen, no swaps) up to a generous multi-display ceiling.
        XCTAssert(fps.isNaN || (fps >= 0 && fps < 1000), "fps \(fps) implausible")
        print("GPU fps: \(String(format: "%.1f", fps))")
    }

    // GPUReader.read() runs every fast tick; the throttle keeps fps amortized cheap.
    func testThrottledReadIsCheap() throws {
        guard let fr = GPUFrameRate() else { throw XCTSkip("DCP unavailable") }
        _ = fr.read()
        let start = Date()
        for _ in 0..<1000 { _ = fr.read() }
        let ms = Date().timeIntervalSince(start) * 1000 / 1000
        print("GPUFrameRate.read (throttled) avg \(String(format: "%.4f", ms))ms")
        XCTAssert(ms < 0.5, "throttled fps read \(ms)ms — throttle regressed?")
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
