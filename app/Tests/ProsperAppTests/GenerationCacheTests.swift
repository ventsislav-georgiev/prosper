import XCTest
@testable import ProsperApp

/// #236: a refresh started before a newer one must not publish over it.
final class GenerationCacheTests: XCTestCase {
    func testOnlyTheNewestRefreshPublishes() {
        var cache = GenerationCache(0)
        let stale = cache.begin()
        let fresh = cache.begin()
        XCTAssertTrue(cache.publish(2, from: fresh))
        XCTAssertFalse(cache.publish(1, from: stale), "stale walk landing last must be rejected")
        XCTAssertEqual(cache.value, 2)
    }

    func testStaleRefreshRejectedEvenBeforeTheNewerLands() {
        var cache = GenerationCache("seed")
        let stale = cache.begin()
        _ = cache.begin()
        XCTAssertFalse(cache.publish("old", from: stale))
        XCTAssertEqual(cache.value, "seed")
    }
}
