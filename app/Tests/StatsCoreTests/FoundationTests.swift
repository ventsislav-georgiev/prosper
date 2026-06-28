import XCTest
@testable import StatsCore
@testable import SMCKit

final class RingBufferTests: XCTestCase {
    func testAppendUnderCapacity() {
        var rb = RingBuffer<Int>(capacity: 5)
        rb.append(1); rb.append(2); rb.append(3)
        XCTAssertEqual(rb.count, 3)
        XCTAssertEqual(rb.snapshot(), [1, 2, 3])
        XCTAssertEqual(rb.last, 3)
    }

    func testWrapAroundKeepsNewestInOrder() {
        var rb = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { rb.append(i) }     // 4,5 overwrite 1,2
        XCTAssertEqual(rb.count, 3)
        XCTAssertEqual(rb.snapshot(), [3, 4, 5])  // oldest→newest
        XCTAssertEqual(rb.last, 5)
    }

    func testExactlyFull() {
        var rb = RingBuffer<Int>(capacity: 3)
        rb.append(1); rb.append(2); rb.append(3)
        XCTAssertEqual(rb.snapshot(), [1, 2, 3])
    }

    func testEmpty() {
        let rb = RingBuffer<Int>(capacity: 4)
        XCTAssertTrue(rb.isEmpty)
        XCTAssertEqual(rb.snapshot(), [])
        XCTAssertNil(rb.last)
    }

    func testRemoveAll() {
        var rb = RingBuffer<Int>(capacity: 3)
        rb.append(1); rb.append(2)
        rb.removeAll()
        XCTAssertTrue(rb.isEmpty)
        rb.append(9)
        XCTAssertEqual(rb.snapshot(), [9])
    }

    func testCapacityOneRollsEveryAppend() {
        var rb = RingBuffer<Int>(capacity: 1)
        rb.append(1); rb.append(2); rb.append(3)
        XCTAssertEqual(rb.snapshot(), [3])
        XCTAssertEqual(rb.count, 1)
    }
}

final class SystemFactsTests: XCTestCase {
    func testFactsAreSane() {
        let f = SystemFacts.current
        XCTAssertGreaterThanOrEqual(f.logicalCores, f.physicalCores)
        XCTAssertGreaterThan(f.physicalCores, 0)
        XCTAssertGreaterThan(f.pageSize, 0)
        XCTAssertGreaterThan(f.physicalMemory, 0)
        XCTAssertFalse(f.modelIdentifier.isEmpty)
    }

    func testClusterSplitOnAppleSilicon() {
        let f = SystemFacts.current
        if f.isAppleSilicon {
            XCTAssertEqual(f.efficiencyCores + f.performanceCores, f.logicalCores,
                           "E(\(f.efficiencyCores))+P(\(f.performanceCores)) != logical(\(f.logicalCores))")
        }
    }
}

final class SMCDecodeTests: XCTestCase {
    func testFloatLERoundTrip() {
        let bytes = SMCDecode.encodeFloatLE(1350.0)
        let type = smcFourCC("flt ")
        XCTAssertEqual(SMCDecode.scalar(bytes, type: type), 1350.0, accuracy: 0.001)
    }

    func testFPE2RoundTrip() {
        let type = smcFourCC("fpe2")
        for rpm in [0, 1200, 2000, 5777, 16383] {
            let bytes = SMCDecode.encodeFPE2(rpm)
            XCTAssertEqual(SMCDecode.scalar(bytes, type: type), Double(rpm), accuracy: 0.5,
                           "fpe2 round-trip failed for \(rpm)")
        }
    }

    func testFPE2ClampsOverflow() {
        let type = smcFourCC("fpe2")
        let bytes = SMCDecode.encodeFPE2(99999)
        XCTAssertEqual(SMCDecode.scalar(bytes, type: type), 16383.0, accuracy: 0.5)
    }

    func testUI16BigEndian() {
        XCTAssertEqual(SMCDecode.scalar([0x05, 0x39], type: smcFourCC("ui16")), 1337.0)
    }

    func testSP78() {
        XCTAssertEqual(SMCDecode.scalar([0x40, 0x00], type: smcFourCC("sp78")), 64.0, accuracy: 0.001)
    }

    func testUnknownTypeFallsBackNotCrash() {
        XCTAssertEqual(SMCDecode.scalar([0x01, 0x00], type: smcFourCC("zzzz")), 1.0, accuracy: 0.001)
    }

    // The fan-target clamp re-decodes a target with these explicit inverse helpers
    // before re-clamping; round-trip + short-buffer fail-safe must hold or the
    // clamp could mis-read a target and fail open.
    func testExplicitTargetDecodersRoundTrip() {
        for rpm in [200, 1234, 2500, 5777, 16383] {
            XCTAssertEqual(Int(SMCDecode.decodeFloatLE(SMCDecode.encodeFloatLE(Float(rpm))).rounded()), rpm)
            XCTAssertEqual(SMCDecode.decodeFPE2(SMCDecode.encodeFPE2(rpm)), rpm)
        }
    }

    func testTargetDecodersShortBufferFailSafe() {
        XCTAssertTrue(SMCDecode.decodeFloatLE([1, 2]).isNaN, "short flt → NaN → clamp lifts to floor")
        XCTAssertEqual(SMCDecode.decodeFPE2([]), 0, "short fpe2 → 0 → clamp lifts to floor")
    }
}

final class PowerSensorReaderTests: XCTestCase {
    func testRailsPresentAndSane() throws {
        guard let r = PowerSensorReader() else { throw XCTSkip("no SMC") }
        let rails = r.read()
        // On a charging laptop DC In should surface; on others the set may be
        // empty (no labeled rail present) — that's valid, so only assert ranges.
        for s in rails {
            switch s.unit {
            case .volt: XCTAssertTrue(s.value > 0.1 && s.value < 60, "\(s.name) V out of range: \(s.value)")
            case .amp:  XCTAssertTrue(s.value >= 0 && s.value < 100, "\(s.name) A out of range: \(s.value)")
            }
            XCTAssertFalse(s.name.isEmpty)
        }
        // Labels are deduped — no two sensors share a name.
        XCTAssertEqual(Set(rails.map(\.name)).count, rails.count)
    }

    // HOT-PATH REQUIREMENT: runs on the sensors slow tick. After the one-time
    // key resolution, a steady read touches only keys present on this Mac — must
    // stay well under 2 ms (≈6 SMC syscalls). A regression here means the
    // absent-key resolution cache broke and we're re-probing dead keys.
    func testSteadyReadUnderBudget() throws {
        guard let r = PowerSensorReader() else { throw XCTSkip("no SMC") }
        _ = r.read()                       // pay the one-time resolve
        let n = 200
        let t0 = Date()
        for _ in 0..<n { _ = r.read() }
        let ms = Date().timeIntervalSince(t0) / Double(n) * 1000
        print("PowerSensorReader steady read \(String(format: "%.3f", ms))ms/call")
        XCTAssert(ms < 2.0, "steady V/I read \(ms)ms — resolution cache regressed?")
    }
}
