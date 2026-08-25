import XCTest

@testable import StatsCore

/// Rate math for the disk module. `DiskReader` is IOKit-and-filesystem-bound, so
/// everything hermetic here runs against a stub `DiskSource` plus an injected
/// clock; one tolerant integration test exercises the real machine.
final class DiskReaderTests: XCTestCase {

    /// Scripted counters + volumes. Also records how often the reader re-enumerates,
    /// which is the whole point of the 10-tick tier.
    private final class StubSource: DiskSource {
        var volumes: [DiskVolume]
        var read: UInt64 = 0
        var write: UInt64 = 0
        private(set) var refreshes = 0
        init(volumes: [DiskVolume] = [.stub()]) { self.volumes = volumes }
        func refresh() { refreshes += 1 }
        func counters() -> (read: UInt64, write: UInt64) { (read, write) }
    }

    /// A reader wired to the stub with a manually advanced clock.
    private func makeReader(_ src: StubSource, clock: @escaping () -> Double) -> DiskReader {
        DiskReader(now: clock, source: src)
    }

    // MARK: - Rate math

    func testFirstReadSeedsAtZero() throws {
        let src = StubSource()
        src.read = 5_000_000_000; src.write = 1_000_000_000
        var now = 100.0
        var r = makeReader(src) { now }
        let s = try r.read()
        // A cumulative counter is meaningless without a baseline — the first sample
        // must not divide "everything since boot" by the time since process start.
        XCTAssertEqual(s.readBytesPerSec, 0)
        XCTAssertEqual(s.writeBytesPerSec, 0)
        XCTAssertEqual(s.totalRead, 0)
        XCTAssertEqual(s.totalWritten, 0)

        now = 102.0
        src.read += 4_000_000; src.write += 2_000_000
        let s2 = try r.read()
        XCTAssertEqual(s2.readBytesPerSec, 2_000_000, accuracy: 0.01, "4 MB over 2 s")
        XCTAssertEqual(s2.writeBytesPerSec, 1_000_000, accuracy: 0.01)
        XCTAssertEqual(s2.totalRead, 4_000_000, "session total accumulates deltas, not absolutes")
        XCTAssertEqual(s2.totalWritten, 2_000_000)
    }

    func testStaleSampleReseedsInsteadOfDividingByAHugeGap() throws {
        let src = StubSource()
        var now = 0.0
        var r = makeReader(src) { now }
        _ = try r.read()

        // 20 s > maxGap (15): the machine slept, the counters moved, the "rate" would
        // be an average over a window we never observed.
        now = 20.0
        src.read += 10_000_000
        let stale = try r.read()
        XCTAssertEqual(stale.readBytesPerSec, 0, "gap beyond maxGap reseeds")
        XCTAssertEqual(stale.totalRead, 0, "and contributes nothing to the session total")

        // The reseed leaves a usable baseline: the next in-window sample is a real rate.
        now = 21.0
        src.read += 1_000_000
        XCTAssertEqual(try r.read().readBytesPerSec, 1_000_000, accuracy: 0.01)
    }

    func testGlitchDeltaIsDropped() throws {
        let src = StubSource()
        var now = 0.0
        var r = makeReader(src) { now }
        _ = try r.read()

        now = 1.0
        src.read += 30_000_000_000        // 30 GB/s — above any Mac storage bus
        src.write += 1_000_000
        let s = try r.read()
        XCTAssertEqual(s.readBytesPerSec, 0, "implausible delta dropped, not charted")
        XCTAssertEqual(s.totalRead, 0)
        XCTAssertEqual(s.writeBytesPerSec, 1_000_000, accuracy: 0.01, "the sane channel still reports")

        // Just under the ceiling is kept — the clamp must not swallow real bursts.
        now = 2.0
        src.read += 24_000_000_000
        XCTAssertEqual(try r.read().readBytesPerSec, 24_000_000_000, accuracy: 1)
    }

    func testCounterResetDoesNotUnderflow() throws {
        let src = StubSource()
        src.read = 8_000_000; src.write = 8_000_000
        var now = 0.0
        var r = makeReader(src) { now }
        _ = try r.read()

        // Disk ejected / driver set re-resolved: the summed counter drops. Unsigned
        // subtraction here would wrap to ~1.8e19 bytes and peg the chart forever.
        now = 1.0
        src.read = 10; src.write = 5
        let s = try r.read()
        XCTAssertEqual(s.readBytesPerSec, 0)
        XCTAssertEqual(s.writeBytesPerSec, 0)
        XCTAssertEqual(s.totalRead, 0)
        XCTAssertEqual(s.totalWritten, 0)

        // And it rebaselines on the new, smaller counter rather than staying stuck.
        now = 2.0
        src.read = 1_010
        XCTAssertEqual(try r.read().readBytesPerSec, 1_000, accuracy: 0.01)
    }

    func testZeroElapsedTimeProducesNoRate() throws {
        let src = StubSource()
        var r = makeReader(src) { 42.0 }   // frozen clock: two reads in the same instant
        _ = try r.read()
        src.read += 1_000_000
        let s = try r.read()
        XCTAssertEqual(s.readBytesPerSec, 0, "dt == 0 must not divide by zero")
    }

    // MARK: - Tiering

    func testVolumesRefreshEveryTenthRead() throws {
        let src = StubSource()
        var r = makeReader(src) { 0 }
        for _ in 0..<21 { _ = try r.read() }
        XCTAssertEqual(src.refreshes, 3, "ticks 0, 10 and 20 re-enumerate; the rest read counters only")
    }

    func testNoVolumesThrowsUnavailable() {
        let src = StubSource(volumes: [])
        var r = makeReader(src) { 0 }
        XCTAssertThrowsError(try r.read()) { err in
            XCTAssertEqual(err as? StatsError, .unavailable("no mounted volumes"))
        }
    }

    // MARK: - Volume math

    func testUsedFractionClamps() {
        XCTAssertEqual(DiskVolume.stub(total: 0, free: 0).usedFraction, 0, "empty volume → 0, not NaN")
        // `ForImportantUsage` can report more free than the raw capacity (purgeable
        // estimate). Saturating subtraction keeps that at "nothing used".
        let over = DiskVolume.stub(total: 100, free: 250)
        XCTAssertEqual(over.used, 0)
        XCTAssertEqual(over.usedFraction, 0)

        let half = DiskVolume.stub(total: 1_000, free: 250)
        XCTAssertEqual(half.used, 750)
        XCTAssertEqual(half.usedFraction, 0.75, accuracy: 0.0001)
    }

    func testSampleBootIsTheFirstVolume() {
        let boot = DiskVolume.stub(name: "Macintosh HD", mountPath: "/", total: 100, free: 40)
        let ext = DiskVolume.stub(name: "Backup", mountPath: "/Volumes/Backup", total: 100, free: 90)
        let s = DiskSample(readBytesPerSec: 0, writeBytesPerSec: 0, totalRead: 0,
                           totalWritten: 0, volumes: [boot, ext])
        XCTAssertEqual(s.boot, boot)
        XCTAssertEqual(s.usedFraction, 0.6, accuracy: 0.0001, "menu bar shows the BOOT volume")
        XCTAssertEqual(DiskSample(readBytesPerSec: 0, writeBytesPerSec: 0, totalRead: 0,
                                  totalWritten: 0, volumes: []).usedFraction, 0)
    }

    // MARK: - Integration (real host, tolerant)

    func testRealHostReportsABootVolume() throws {
        var r = DiskReader()
        let s: DiskSample
        do { s = try r.read() } catch {
            throw XCTSkip("no mounted volumes on this host: \(error)")
        }
        guard let boot = s.boot else { return XCTFail("a sample with volumes must have a boot volume") }
        XCTAssertEqual(boot.mountPath, "/", "boot volume leads the list")
        XCTAssertGreaterThan(boot.total, 0)
        XCTAssertLessThanOrEqual(boot.free, boot.total + boot.total / 10, "free is in the same order as total")
        XCTAssertFalse(boot.bsdName.isEmpty, "statfs resolved a BSD device")
        XCTAssertFalse(boot.fileSystem.isEmpty)
        XCTAssertTrue((0...1).contains(boot.usedFraction))
        // First read is a seed, so rates are exactly zero — never NaN or negative.
        XCTAssertEqual(s.readBytesPerSec, 0)
        XCTAssertEqual(s.writeBytesPerSec, 0)
    }

    /// The registry walk must terminate and either find a driver or answer nil —
    /// never hang, never return a live handle for a device that does not exist.
    func testResolveDriverOnBogusDeviceIsNil() {
        XCTAssertNil(IOKitDiskSource.resolveDriver(bsdName: "disk9999"))
        XCTAssertNil(IOKitDiskSource.resolveDriver(bsdName: ""))
    }
}

private extension DiskVolume {
    static func stub(name: String = "Test", mountPath: String = "/",
                     total: UInt64 = 1_000, free: UInt64 = 500) -> DiskVolume {
        DiskVolume(name: name, mountPath: mountPath, bsdName: "disk0s1", fileSystem: "apfs",
                   total: total, free: free, isInternal: true, isRemovable: false)
    }
}
