import XCTest
@testable import ProsperApp

final class CompletionStatsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CompletionStats.reset()
    }

    override func tearDown() {
        CompletionStats.reset()
        super.tearDown()
    }

    func testRecordAccumulates() {
        CompletionStats.recordAccept("hello world")
        XCTAssertEqual(CompletionStats.totalCompletions, 1)
        XCTAssertEqual(CompletionStats.totalWords, 2)
        XCTAssertEqual(CompletionStats.totalChars, 11)
    }

    func testMultipleAccepts() {
        CompletionStats.recordAccept("one")
        CompletionStats.recordAccept("two three")
        XCTAssertEqual(CompletionStats.totalCompletions, 2)
        XCTAssertEqual(CompletionStats.totalWords, 3)
        XCTAssertEqual(CompletionStats.todayCount, 2)
    }

    func testEmptyIgnored() {
        CompletionStats.recordAccept("   ")
        XCTAssertEqual(CompletionStats.totalCompletions, 0)
    }

    func testResetClears() {
        CompletionStats.recordAccept("x")
        CompletionStats.reset()
        XCTAssertEqual(CompletionStats.totalCompletions, 0)
        XCTAssertEqual(CompletionStats.todayCount, 0)
    }

    func testDayKeyFormat() {
        // 2026-06-07 → "2026-06-07"
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 7
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(CompletionStats.dayKey(for: date), "2026-06-07")
    }
}
