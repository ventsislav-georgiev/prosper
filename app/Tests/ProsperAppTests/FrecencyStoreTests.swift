import XCTest
@testable import ProsperApp

/// Coverage for the file frecency store: the pure recency-decayed score, the
/// record→boost round-trip (isolated `UserDefaults` suite), and clearing.
final class FrecencyStoreTests: XCTestCase {

    private func freshStore() -> (FrecencyStore, String) {
        let suite = "frecency-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (FrecencyStore(defaults: defaults, storageKey: "k"), suite)
    }

    // MARK: pure scoring

    func testScoreZeroForNoUse() {
        XCTAssertEqual(FrecencyStore.score(.init(count: 0, lastUsed: 0), now: 0), 0)
    }

    func testScoreGrowsWithCountAndDecaysWithAge() {
        let now: TimeInterval = 1_000_000
        let fresh = FrecencyStore.score(.init(count: 3, lastUsed: now), now: now)
        XCTAssertEqual(fresh, 3, accuracy: 0.0001)  // no decay today
        // Same usage 30 days ago decays to ~e^-1 of the count.
        let aged = FrecencyStore.score(.init(count: 3, lastUsed: now - 30 * 86_400), now: now)
        XCTAssertLessThan(aged, fresh)
        XCTAssertEqual(aged, 3 * exp(-1.0), accuracy: 0.01)
    }

    func testFrequentRecentBeatsOnceLongAgo() {
        let now: TimeInterval = 2_000_000
        let recent = FrecencyStore.score(.init(count: 5, lastUsed: now - 86_400), now: now)
        let stale = FrecencyStore.score(.init(count: 5, lastUsed: now - 120 * 86_400), now: now)
        XCTAssertGreaterThan(recent, stale)
    }

    // MARK: record / boost / clear

    func testRecordAccumulatesAndBoostsRankedPath() {
        let (store, _) = freshStore()
        let now: TimeInterval = 1_700_000_000
        store.record(path: "/a/x.txt", now: now)
        store.record(path: "/a/x.txt", now: now)
        store.record(path: "/a/y.txt", now: now)

        let bx = store.boost(path: "/a/x.txt", now: now)
        let by = store.boost(path: "/a/y.txt", now: now)
        XCTAssertGreaterThan(bx, by)               // two uses beat one
        XCTAssertEqual(store.boost(path: "/a/none.txt", now: now), 0)  // never used
    }

    func testBoostsForReturnsOnlyKnownPaths() {
        let (store, _) = freshStore()
        let now: TimeInterval = 1_700_000_000
        store.record(path: "/a/x.txt", now: now)
        let map = store.boosts(for: ["/a/x.txt", "/a/missing.txt"], now: now)
        XCTAssertNotNil(map["/a/x.txt"])
        XCTAssertNil(map["/a/missing.txt"])
    }

    func testRecordIgnoresEmptyPath() {
        let (store, _) = freshStore()
        store.record(path: "")
        XCTAssertEqual(store.boost(path: ""), 0)
    }

    func testClearForgetsEverything() {
        let (store, _) = freshStore()
        let now: TimeInterval = 1_700_000_000
        store.record(path: "/a/x.txt", now: now)
        store.clear()
        XCTAssertEqual(store.boost(path: "/a/x.txt", now: now), 0)
    }

    func testPersistsAcrossInstancesOnSameSuite() {
        let suite = "frecency-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let now: TimeInterval = 1_700_000_000

        FrecencyStore(defaults: defaults, storageKey: "k").record(path: "/a/x.txt", now: now)
        let reopened = FrecencyStore(defaults: defaults, storageKey: "k")
        XCTAssertGreaterThan(reopened.boost(path: "/a/x.txt", now: now), 0)
    }
}
