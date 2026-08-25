import XCTest

@testable import ProsperApp
@testable import SMCKit
@testable import StatsCore

/// Hot-path compute budgets for the System Stats pipeline. The poller ticks every
/// 1–2 s on a utility queue and hands a value snapshot to the main thread — every
/// per-tick cost here must stay µs-scale so an accidental O(n²), a per-tick regex,
/// or a vocab-wide allocation regression fails loudly instead of showing up as a
/// warm menu bar. Ceilings are generous (guarding shape, not jitter); each test's
/// comment states the requirement it encodes.
final class StatsHotPathBudgetTests: XCTestCase {

    // MARK: - RingBuffer (touched once per metric per tick, snapshotted per deliver)

    /// REQUIREMENT: append is O(1) and snapshot O(capacity) with a single
    /// allocation — the poller snapshots ~6 rings of 120 Doubles EVERY tick.
    /// 10k append+snapshot rounds ≈ 10k ticks ≫ hours of runtime.
    func testRingBufferAppendSnapshotBudget() {
        var ring = RingBuffer<Double>(capacity: 120)
        let clock = ContinuousClock()
        var sink = 0.0
        let elapsed = clock.measure {
            for i in 0..<10_000 {
                ring.append(Double(i))
                let snap = ring.snapshot()
                sink += snap.last ?? 0
            }
        }
        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(elapsed, .milliseconds(500), "RingBuffer hot path regressed: \(elapsed)")
    }

    /// Correctness under wrap-around: snapshot is oldest→newest, exactly `count`
    /// elements, `last` matches the newest append.
    func testRingBufferWrapAroundOrder() {
        var ring = RingBuffer<Double>(capacity: 4)
        for i in 1...6 { ring.append(Double(i)) }   // wraps: holds 3,4,5,6
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.snapshot(), [3, 4, 5, 6])
        XCTAssertEqual(ring.last, 6)
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.snapshot(), [])
    }

    // MARK: - nettop parse (runs once per popup-open tick on the nettop queue)

    /// REQUIREMENT: parse stays linear in the row count — a 600-row nettop dump
    /// (heavy VPN box) must parse in single-digit ms so the reader queue never
    /// backs up behind its own output. 100 parses of 600 rows < 1 s.
    func testNetProcessParseBudget() {
        var text = "time,,interface,state,bytes_in,bytes_out,\n"
        for i in 1...600 {
            text += "proc.name.\(i).\(1000 + i),\(i * 100),\(i * 50),\n"
        }
        let clock = ContinuousClock()
        var rows: [NetProcInfo] = []
        let elapsed = clock.measure {
            for _ in 0..<100 { rows = NetProcessReader.parse(text, limit: 8) }
        }
        XCTAssertEqual(rows.count, 8)
        // Highest total throughput first.
        XCTAssertEqual(rows.first?.pid, 1600)
        XCTAssertLessThan(elapsed, .seconds(1), "nettop parse regressed: \(elapsed)")
    }

    /// Malformed rows (no pid suffix, empty name, zero traffic, short rows) are
    /// skipped, never crash, and dotted process names keep their dots.
    func testNetProcessParseDefensive() {
        let text = """
        time,,interface,state,bytes_in,bytes_out,
        com.apple.WebKit.Networking.512,1000,2000,
        noPidHere,5,5,
        .777,9,9,
        zero.traffic.900,0,0,
        short.5
        """
        let rows = NetProcessReader.parse(text, limit: 8)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "com.apple.WebKit.Networking")
        XCTAssertEqual(rows[0].pid, 512)
    }

    // MARK: - DiskReader (one read per tick; re-enumerates only every 10th)

    /// REQUIREMENT: the per-tick disk read is counter arithmetic, NOT a registry
    /// walk — volume enumeration and driver resolution are gated to every 10th
    /// read. 1 000 reads ≈ 17 min of ticks and must cost ~nothing.
    func testDiskReaderReadBudget() throws {
        final class StubSource: DiskSource {
            let volumes = [DiskVolume(name: "T", mountPath: "/", bsdName: "disk0s1",
                                      fileSystem: "apfs", total: 1_000_000, free: 400_000,
                                      isInternal: true, isRemovable: false)]
            var read: UInt64 = 0
            var refreshes = 0
            func refresh() { refreshes += 1 }
            func counters() -> (read: UInt64, write: UInt64) { read += 1_000; return (read, read) }
        }
        let src = StubSource()
        var t = 0.0
        var reader = DiskReader(now: { t }, source: src)
        let clock = ContinuousClock()
        var sink = 0.0
        let elapsed = try clock.measure {
            for _ in 0..<1_000 { t += 1; sink += try reader.read().readBytesPerSec }
        }
        XCTAssertGreaterThan(sink, 0)
        XCTAssertEqual(src.refreshes, 100, "enumeration stays on the 10-tick tier")
        XCTAssertLessThan(elapsed, .milliseconds(500), "DiskReader hot path regressed: \(elapsed)")
    }

    // MARK: - SMC decode/encode (fan reads each poll; writes on slider commit)

    /// REQUIREMENT: scalar decode is a branch + a load — the sensors tick decodes
    /// dozens of values. 100k decodes ≪ one tick's budget.
    func testSMCScalarDecodeBudget() {
        let flt: [UInt8] = SMCDecode.encodeFloatLE(1350.0)
        let fltType = smcFourCC("flt ")
        let fpe2: [UInt8] = SMCDecode.encodeFPE2(4200)
        let fpe2Type = smcFourCC("fpe2")
        let clock = ContinuousClock()
        var sink = 0.0
        let elapsed = clock.measure {
            for _ in 0..<100_000 {
                sink += SMCDecode.scalar(flt, type: fltType)
                sink += SMCDecode.scalar(fpe2, type: fpe2Type)
            }
        }
        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(elapsed, .milliseconds(500), "SMC scalar decode regressed: \(elapsed)")
    }

    /// Round-trips: the encoders and decoders used on the fan write path must be
    /// exact inverses (clamp math re-decodes what it encoded).
    func testSMCEncodeDecodeRoundTrip() {
        for rpm: Float in [200, 1350, 4200.5, 5777] {
            XCTAssertEqual(SMCDecode.decodeFloatLE(SMCDecode.encodeFloatLE(rpm)), rpm)
        }
        for rpm in [0, 200, 1350, 5777, 16_383] {
            XCTAssertEqual(SMCDecode.decodeFPE2(SMCDecode.encodeFPE2(rpm)), rpm)
        }
        // fpe2 saturates at 14 bits — above that it clamps, never wraps.
        XCTAssertEqual(SMCDecode.decodeFPE2(SMCDecode.encodeFPE2(20_000)), 16_383)
        // Short/garbage buffers decode to sentinel values, never trap.
        XCTAssertTrue(SMCDecode.decodeFloatLE([1, 2]).isNaN)
        XCTAssertEqual(SMCDecode.decodeFPE2([9]), 0)
        XCTAssertTrue(SMCDecode.scalar([], type: smcFourCC("flt ")).isNaN)
    }

    // MARK: - Headline temperature (recomputed on the main thread per delivered tick)

    /// REQUIREMENT: picking the headline sensor scans the sensor list (M-series
    /// exposes ~77) a few times per tick on the MAIN thread — it must stay a
    /// linear scan with no per-call string churn worth noticing. 10k picks over
    /// 77 sensors ≪ a frame.
    func testHeadlineTemperatureBudget() {
        var snap = StatsSnapshot()
        snap.temperatures = (0..<77).map { (i: Int) -> TempSensor in
            let name = i == 40 ? "PMU tcal" : "pACC MTR Temp Sensor\(i)"
            let celsius: Double = i == 40 ? 52 : Double(30 + i % 15)
            return TempSensor(name: name, celsius: celsius)
        }
        let clock = ContinuousClock()
        var sink = 0.0
        let elapsed = clock.measure {
            for _ in 0..<10_000 { sink += snap.headlineTemperature() ?? 0 }
        }
        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(elapsed, .seconds(1), "headlineTemperature regressed: \(elapsed)")
        // The static calibration sensor never wins the headline.
        XCTAssertEqual(snap.headlineTemperature(), 44)
        // A pinned sensor always wins, even a calibration one.
        XCTAssertEqual(snap.headlineTemperature(pinned: "PMU tcal"), 52)
    }

    func testTempAggregates() {
        let temps = [
            TempSensor(name: "CPU performance core 1", celsius: 50),
            TempSensor(name: "CPU efficiency core 1", celsius: 40),
            TempSensor(name: "GPU core 1", celsius: 44),
            TempSensor(name: "GPU core 2", celsius: 52),
            TempSensor(name: "Battery 1", celsius: 33),   // never aggregated
            TempSensor(name: "Airport", celsius: 43),
        ]
        let agg = tempAggregates(temps)
        XCTAssertEqual(agg, [
            TempSensor(name: "Average CPU", celsius: 45),
            TempSensor(name: "Hottest CPU", celsius: 50),
            TempSensor(name: "Average GPU", celsius: 48),
            TempSensor(name: "Hottest GPU", celsius: 52),
        ])
        // A single sensor per group is not an "aggregate" — no synthetic rows.
        XCTAssertTrue(tempAggregates([TempSensor(name: "CPU performance core 1", celsius: 50)]).isEmpty)
        XCTAssertTrue(tempAggregates([]).isEmpty)
    }

    func testChipGenerationParse() {
        XCTAssertEqual(PowerSensorReader.chipGeneration(brand: "Apple M1"), 1)
        XCTAssertEqual(PowerSensorReader.chipGeneration(brand: "Apple M4 Pro"), 4)
        XCTAssertEqual(PowerSensorReader.chipGeneration(brand: "Apple M4 Max"), 4)
        XCTAssertEqual(PowerSensorReader.chipGeneration(brand: "Apple M12 Ultra"), 12)
        XCTAssertNil(PowerSensorReader.chipGeneration(brand: "Intel(R) Core(TM) i9-9980HK"))
        XCTAssertNil(PowerSensorReader.chipGeneration(brand: ""))
        // Every generation's key table must be collision-free WITHIN itself —
        // the same key on two labels would double-list one die.
        for (gen, table) in PowerSensorReader.asTemperatureKeys {
            var keys = Set<String>(), dupes: [String] = []
            for (key, _) in table where !keys.insert(key).inserted { dupes.append(key) }
            XCTAssertTrue(dupes.isEmpty, "M\(gen) table has duplicate keys: \(dupes)")
        }
    }
}
