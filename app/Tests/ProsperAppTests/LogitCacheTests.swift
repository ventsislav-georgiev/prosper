import XCTest
@testable import ProsperApp

/// B5 (SC) — bounded LRU logit-distribution cache.
final class LogitCacheTests: XCTestCase {

    func testGetMissThenHit() {
        let c = LogitCache(maxEntries: 4)
        XCTAssertNil(c.get([1, 2]))
        c.put([1, 2], logits: [0.1, 0.2])
        XCTAssertEqual(c.get([1, 2]), [0.1, 0.2])
    }

    func testKeyIsSequenceSensitive() {
        let c = LogitCache(maxEntries: 4)
        c.put([1, 2], logits: [1])
        c.put([2, 1], logits: [2])
        XCTAssertEqual(c.get([1, 2]), [1])
        XCTAssertEqual(c.get([2, 1]), [2])
    }

    func testEvictsLeastRecentlyUsed() {
        let c = LogitCache(maxEntries: 2)
        c.put([1], logits: [1])
        c.put([2], logits: [2])
        _ = c.get([1])                 // touch 1 → 2 now oldest
        c.put([3], logits: [3])        // evicts 2
        XCTAssertNotNil(c.get([1]))
        XCTAssertNil(c.get([2]))
        XCTAssertNotNil(c.get([3]))
        XCTAssertEqual(c.count, 2)
    }

    func testPutSameKeyUpdatesWithoutGrowing() {
        let c = LogitCache(maxEntries: 2)
        c.put([1], logits: [1])
        c.put([1], logits: [9])
        XCTAssertEqual(c.get([1]), [9])
        XCTAssertEqual(c.count, 1)
    }

    func testClear() {
        let c = LogitCache(maxEntries: 4)
        c.put([1], logits: [1])
        c.clear()
        XCTAssertEqual(c.count, 0)
        XCTAssertNil(c.get([1]))
    }
}
