import XCTest
@testable import StatsCore

final class CPUReaderTests: XCTestCase {
    func testFirstReadIsBaseline() throws {
        var r = CPUReader()
        let s = try r.read()
        XCTAssertEqual(s.total, 0)          // no prior delta
        XCTAssertEqual(s.perCore.count, SystemFacts.current.logicalCores)
    }

    func testSecondReadInRange() throws {
        var r = CPUReader()
        _ = try r.read()
        var x = 0.0; for i in 0..<2_000_000 { x += Double(i).squareRoot() }
        _ = x
        let s = try r.read()
        XCTAssertGreaterThanOrEqual(s.total, 0)
        XCTAssertLessThanOrEqual(s.total, 1)
        for c in s.perCore { XCTAssert(c >= 0 && c <= 1, "core load out of range: \(c)") }
        if SystemFacts.current.isAppleSilicon {
            XCTAssert(s.efficiency >= 0 && s.efficiency <= 1)
            XCTAssert(s.performance >= 0 && s.performance <= 1)
        }
    }
}

final class MemoryReaderTests: XCTestCase {
    func testReadIsSane() throws {
        var r = MemoryReader()
        let s = try r.read()
        XCTAssertGreaterThan(s.total, 0)
        XCTAssertLessThanOrEqual(s.used, s.total)
        XCTAssertEqual(s.used, s.app + s.wired + s.compressed)
        XCTAssert(s.pressure >= 0 && s.pressure <= 1)
        XCTAssertEqual(s.used + s.free, s.total)   // free is the remainder
    }
}

final class NetworkReaderTests: XCTestCase {
    func testFirstReadIsZeroRate() throws {
        var r = NetworkReader()
        let s = try r.read()
        XCTAssertEqual(s.downloadBytesPerSec, 0)
        XCTAssertEqual(s.uploadBytesPerSec, 0)
    }

    func testRateUsesInjectedClock() throws {
        var t = 1000.0
        var r = NetworkReader(now: { t })
        _ = try r.read()       // seed at t=1000
        t = 1002.0
        let s = try r.read()
        XCTAssertGreaterThanOrEqual(s.downloadBytesPerSec, 0)
        XCTAssert(s.downloadBytesPerSec.isFinite)
        XCTAssert(s.uploadBytesPerSec.isFinite)
    }

    func testNoDivideByZeroOnSameInstant() throws {
        let t = 5.0
        var r = NetworkReader(now: { t })
        _ = try r.read()
        let s = try r.read()   // same instant → dt clamped, no inf/nan
        XCTAssert(s.downloadBytesPerSec.isFinite)
    }
}

final class HotPathBudgetTests: XCTestCase {
    // Budgets from plan §2. Generous CI margins; these catch regressions
    // (e.g. an accidental allocation-per-core), not absolute hardware timing.
    func testCPUReadUnderBudget() throws {
        var r = CPUReader()
        _ = try r.read()
        let iters = 200
        let start = NetworkReader.monotonicSeconds()
        for _ in 0..<iters { _ = try r.read() }
        let perRead = (NetworkReader.monotonicSeconds() - start) / Double(iters)
        XCTAssertLessThan(perRead, 0.002, "CPU read \(perRead * 1e6)µs > 2ms budget")
        print("CPU read: \(String(format: "%.1f", perRead * 1e6))µs/read")
    }

    func testMemoryReadUnderBudget() throws {
        var r = MemoryReader()
        let iters = 500
        let start = NetworkReader.monotonicSeconds()
        for _ in 0..<iters { _ = try r.read() }
        let perRead = (NetworkReader.monotonicSeconds() - start) / Double(iters)
        XCTAssertLessThan(perRead, 0.001, "RAM read \(perRead * 1e6)µs > 1ms budget")
        print("RAM read: \(String(format: "%.1f", perRead * 1e6))µs/read")
    }

    func testNetworkReadUnderBudget() throws {
        var r = NetworkReader()
        _ = try r.read()
        let iters = 200
        let start = NetworkReader.monotonicSeconds()
        for _ in 0..<iters { _ = try r.read() }
        let perRead = (NetworkReader.monotonicSeconds() - start) / Double(iters)
        XCTAssertLessThan(perRead, 0.005, "net read \(perRead * 1e6)µs > 5ms budget")
        print("net read: \(String(format: "%.1f", perRead * 1e6))µs/read")
    }
}
