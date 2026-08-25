import XCTest

@testable import StatsCore

/// Per-process disk I/O: the two pure pieces — the cumulative-counter → rate delta
/// and the ranking. The libproc enumeration itself needs a live machine, so it gets
/// one tolerant probe at the bottom.
final class ProcDiskIOTests: XCTestCase {

    private func proc(_ pid: Int32, read: Double, write: Double) -> ProcInfo {
        ProcInfo(pid: pid, name: "p\(pid)", cpu: 0, memory: 0, diskRead: read, diskWrite: write)
    }

    // MARK: byteRate

    func testByteRateDividesDeltaByInterval() {
        XCTAssertEqual(ProcSampler.byteRate(from: 1_000, to: 5_000, seconds: 2), 2_000, accuracy: 0.001)
    }

    func testByteRateIsZeroWithoutElapsedTime() {
        // Two readings at the same instant (or a clock that went backwards) can't
        // produce a rate — must not divide by zero into inf/NaN.
        XCTAssertEqual(ProcSampler.byteRate(from: 0, to: 4_096, seconds: 0), 0)
        XCTAssertEqual(ProcSampler.byteRate(from: 0, to: 4_096, seconds: -1), 0)
    }

    func testByteRateIsZeroWhenCounterGoesBackwards() {
        // pid recycled onto a different process between samples: an unsigned wrap
        // would report ~18 EB/s and pin the table forever.
        XCTAssertEqual(ProcSampler.byteRate(from: 9_000, to: 10, seconds: 1), 0)
    }

    func testByteRateIsZeroForIdleProcess() {
        XCTAssertEqual(ProcSampler.byteRate(from: 777, to: 777, seconds: 1), 0)
    }

    // MARK: topByDisk

    func testTopByDiskRanksOnCombinedReadPlusWrite() {
        let ranked = ProcSampler.topByDisk([
            proc(1, read: 100, write: 0),      // 100
            proc(2, read: 0, write: 900),      // 900 — write-only still wins
            proc(3, read: 300, write: 300),    // 600
        ], limit: 5)
        XCTAssertEqual(ranked.map(\.pid), [2, 3, 1])
    }

    func testTopByDiskDropsIdleProcessesAndHonoursLimit() {
        let ranked = ProcSampler.topByDisk([
            proc(1, read: 0, write: 0),
            proc(2, read: 5, write: 0),
            proc(3, read: 50, write: 0),
            proc(4, read: 0, write: 0),
            proc(5, read: 500, write: 0),
        ], limit: 2)
        XCTAssertEqual(ranked.map(\.pid), [5, 3])
    }

    func testTopByDiskOfIdleSystemIsEmptyNotPadded() {
        // Empty (rather than five 0 B/s rows) is what lets the popup say
        // "No disk activity" instead of listing idle daemons.
        XCTAssertTrue(ProcSampler.topByDisk([proc(1, read: 0, write: 0)], limit: 5).isEmpty)
    }

    // MARK: live

    /// Two samples a moment apart on the real machine: rates must be finite and
    /// non-negative, and byDisk must stay ranked. Doesn't assert activity — a quiet
    /// machine legitimately has none.
    func testLiveSampleProducesSaneDiskRates() {
        var s = ProcSampler()
        _ = s.sample(limit: 5)                      // priming pass: no prev, no rates
        // Make some I/O of our own so the second pass has something to see.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prosper-diskio-\(getpid()).bin")
        try? Data(count: 2 << 20).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let out = s.sample(limit: 5)
        XCTAssertLessThanOrEqual(out.byDisk.count, 5)
        for p in out.byDisk {
            XCTAssertTrue(p.diskRead.isFinite && p.diskWrite.isFinite)
            XCTAssertGreaterThan(p.diskTotal, 0)    // zero-rate rows are filtered out
        }
        XCTAssertEqual(out.byDisk.map(\.diskTotal), out.byDisk.map(\.diskTotal).sorted(by: >))
    }
}
