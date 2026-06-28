import XCTest
import Darwin
@testable import StatsCore

final class ProcSamplerTests: XCTestCase {
    func testFindsRunningProcesses() {
        var s = ProcSampler()
        let (byCPU, byMem) = s.sample(limit: 5)
        XCTAssertFalse(byMem.isEmpty, "should enumerate at least this test process")
        XCTAssertLessThanOrEqual(byMem.count, 5)
        XCTAssertLessThanOrEqual(byCPU.count, 5)
        for i in 1..<byMem.count { XCTAssertGreaterThanOrEqual(byMem[i-1].memory, byMem[i].memory) }
        XCTAssertTrue(byMem.allSatisfy { $0.memory > 0 })
    }

    func testCPUDeltaNonNegativeAcrossTwoSamples() {
        var t = 100.0
        var s = ProcSampler(now: { t })
        _ = s.sample(limit: 5)
        t = 101.0
        let (byCPU, _) = s.sample(limit: 5)
        for p in byCPU { XCTAssertGreaterThanOrEqual(p.cpu, 0); XCTAssert(p.cpu.isFinite) }
    }

    func testRepeatedSamplingStable() {
        var s = ProcSampler()
        _ = s.sample(limit: 5)
        _ = s.sample(limit: 5)
        let (_, m) = s.sample(limit: 3)
        XCTAssertLessThanOrEqual(m.count, 3)
    }

    func testSampleUnderSlowTierBudget() {
        var s = ProcSampler()
        _ = s.sample(limit: 5)   // warm
        let start = NetworkReader.monotonicSeconds()
        _ = s.sample(limit: 5)
        let dt = NetworkReader.monotonicSeconds() - start
        XCTAssertLessThan(dt, 0.050, "proc sample \(dt * 1000)ms > 50ms slow-tier budget")
        print("proc sample: \(String(format: "%.2f", dt * 1000))ms (\(ProcSampler.allPIDs().count) pids)")
    }
}
