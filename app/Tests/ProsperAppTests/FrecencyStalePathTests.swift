import XCTest
@testable import ProsperApp

/// #1153: a frecency entry whose file is gone and that was last used more than the 30-day window before a
/// record is pruned (off main, after that record); within the window it is kept; a path that cannot be
/// checked is kept; the 2000 cap is unchanged.
/// Every store is a scratch suite and every path lives in the row's own tempDir().
final class FrecencyStalePathTests: XCTestCase {

    private let now: TimeInterval = 1_700_000_000

    private func store(_ pathState: (@Sendable (String) -> Bool?)? = FrecencyStore.livePathState) -> FrecencyStore {
        FrecencyStore(defaults: scratchDefaults("frecency-stale"), storageKey: "k", pathState: pathState)
    }

    private func touch(_ url: URL) {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
    }

    /// 30 days in seconds, literal (the window is `FrecencyStore.decayDays` days).
    private let window: TimeInterval = 2_592_000
    private let day: TimeInterval = 86_400

    func testRemovedFileUsedWithinWindowKeepsItsRanking() throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        touch(a); touch(b)
        let s = store()
        s.record(path: a.path, now: now)
        s.record(path: a.path, now: now)
        try FileManager.default.removeItem(at: a)
        s.record(path: b.path, now: now + 29 * day)   // sweeps; a is gone but used 29 days ago
        s.waitForPrune()
        touch(a)                                      // a new file at the old path inherits
        XCTAssertEqual(s.boost(path: a.path, now: now), 2, accuracy: 0.0001)
        s.record(path: a.path, now: now + 29 * day)   // its next record continues the count
        XCTAssertEqual(s.boost(path: a.path, now: now + 29 * day), 3, accuracy: 0.0001)
    }

    func testRemovedFileUnusedPastWindowIsDropped() throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        touch(a); touch(b)
        let s = store()
        s.record(path: a.path, now: now)
        s.record(path: a.path, now: now)
        try FileManager.default.removeItem(at: a)
        s.record(path: b.path, now: now + 31 * day)
        s.waitForPrune()
        touch(a)
        XCTAssertEqual(s.boost(path: a.path, now: now), 0)
        XCTAssertGreaterThan(s.boost(path: b.path, now: now + 31 * day), 0)
        s.record(path: a.path, now: now + 31 * day)   // starts at one
        XCTAssertEqual(s.boost(path: a.path, now: now + 31 * day), 1, accuracy: 0.0001)
    }

    func testWindowBoundaryKeepsExactlyAtAndDropsJustPast() {
        let dir = tempDir()
        let edge = dir.appendingPathComponent("edge.txt").path   // never made: gone
        let past = dir.appendingPathComponent("past.txt").path   // never made: gone
        let b = dir.appendingPathComponent("b.txt")
        touch(b)
        let s = store()
        s.record(path: edge, now: now)
        s.record(path: past, now: now - 1)
        s.record(path: b.path, now: now + window)   // edge is exactly the window old, past one second more
        s.waitForPrune()
        XCTAssertEqual(s.boost(path: edge, now: now), 1, accuracy: 0.0001)
        XCTAssertEqual(s.boost(path: past, now: now), 0)
    }

    func testOnlyEntriesPastTheWindowAreChecked() {
        let dir = tempDir()
        let old = dir.appendingPathComponent("old.txt").path       // never made: gone
        let fresh = dir.appendingPathComponent("fresh.txt").path   // never made: gone
        let b = dir.appendingPathComponent("b.txt")
        touch(b)
        let asked = AskedPaths()
        let s = store { asked.add($0); return FrecencyStore.livePathState($0) }
        s.record(path: old, now: now)
        s.record(path: fresh, now: now + 30 * day)
        s.record(path: b.path, now: now + 31 * day)
        s.waitForPrune()
        XCTAssertTrue(asked.contains(old))
        XCTAssertFalse(asked.contains(fresh), "a gone path used within the window is never read from disk")
        XCTAssertEqual(s.boost(path: old, now: now), 0)
        XCTAssertEqual(s.boost(path: fresh, now: now + 30 * day), 1, accuracy: 0.0001)
    }

    func testExistingFileKeepsItsBoost() {
        let dir = tempDir()
        let a = dir.appendingPathComponent("kept.txt"), b = dir.appendingPathComponent("b.txt")
        touch(a); touch(b)
        let s = store()
        s.record(path: a.path, now: now)
        s.record(path: a.path, now: now)
        s.record(path: b.path, now: now + 31 * day)   // a is past the window, so it is checked
        s.waitForPrune()
        XCTAssertEqual(s.boost(path: a.path, now: now), 2, accuracy: 0.0001)
    }

    func testPathThatCannotBeCheckedIsKept() {
        let dir = tempDir()
        let offline = dir.appendingPathComponent("offline.txt").path   // never made: the live check says gone
        let b = dir.appendingPathComponent("b.txt")
        touch(b)
        XCTAssertTrue(FrecencyStore.livePathState(offline) == false)
        // Simulated unmounted volume: the injected check cannot tell for this one path.
        let s = store { $0 == offline ? nil : FrecencyStore.livePathState($0) }
        s.record(path: offline, now: now)
        s.record(path: b.path, now: now + 31 * day)
        s.waitForPrune()
        XCTAssertGreaterThan(s.boost(path: offline, now: now), 0)
    }

    func testLivePathStateReadsExistsGoneAndUnknown() throws {
        let dir = tempDir()
        let f = dir.appendingPathComponent("f.txt")
        touch(f)
        XCTAssertTrue(FrecencyStore.livePathState(f.path) == true)
        try FileManager.default.removeItem(at: f)
        XCTAssertTrue(FrecencyStore.livePathState(f.path) == false)   // folder there, file not: gone
        let underMissingFolder = dir.appendingPathComponent("never/x.txt").path
        XCTAssertTrue(FrecencyStore.livePathState(underMissingFolder) == nil)  // folder missing: unknown
        // The prefix test answers before any file-system call: nothing under /Volumes is read.
        XCTAssertTrue(FrecencyStore.livePathState("/Volumes/prosper-test-absent") == nil)
        XCTAssertTrue(FrecencyStore.livePathState("/Volumes/prosper-test-absent/dir/f") == nil)
    }

    /// The 2000 cap still keeps the best 1000 by score (no row covered it before).
    func testCapStillKeepsTheBestThousand() throws {
        let defaults = scratchDefaults("frecency-cap")
        var seed: [String: FrecencyStore.Entry] = [:]
        for i in 1...2000 { seed["/Users/example/p\(i)"] = .init(count: i, lastUsed: now) }
        defaults.set(try JSONEncoder().encode(seed), forKey: "k")
        let s = FrecencyStore(defaults: defaults, storageKey: "k")
        s.record(path: "/Users/example/new", now: now)   // 2001 entries -> pruned to 1000
        let all = s.boosts(for: Array(seed.keys) + ["/Users/example/new"], now: now)
        XCTAssertEqual(all.count, 1000)
        XCTAssertNotNil(all["/Users/example/p2000"])
        XCTAssertNotNil(all["/Users/example/p1001"])
        XCTAssertTrue(all["/Users/example/p1000"] == nil)
        XCTAssertTrue(all["/Users/example/new"] == nil)
    }
}

/// Paths the injected check was asked about (it runs on the store's prune queue).
private final class AskedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []
    func add(_ p: String) { lock.lock(); paths.insert(p); lock.unlock() }
    func contains(_ p: String) -> Bool { lock.lock(); defer { lock.unlock() }; return paths.contains(p) }
}
