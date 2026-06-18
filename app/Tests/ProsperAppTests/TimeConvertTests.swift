import XCTest
@testable import ProsperApp

final class TimeConvertTests: XCTestCase {

    /// Fixed instants so DST is deterministic: one summer, one winter day.
    private let summer = ISO8601DateFormatter().date(from: "2026-06-11T10:00:00Z")!
    private let winter = ISO8601DateFormatter().date(from: "2026-01-15T10:00:00Z")!

    func testAbbreviationToCity() throws {
        // 14:30 HKT (UTC+8) = 6:30 UTC = 8:30 CEST (Numi parity screenshot).
        let r = try XCTUnwrap(TimeConvert.convert("2:30 pm HKT in Berlin", now: summer))
        XCTAssertEqual(r.value, "8:30")
        XCTAssertEqual(r.detail, "2:30 pm HKT → Berlin")
    }

    func testWinterDST() throws {
        // Berlin is CET (UTC+1) in January → 7:30.
        let r = try XCTUnwrap(TimeConvert.convert("2:30 pm HKT in Berlin", now: winter))
        XCTAssertEqual(r.value, "7:30")
    }

    func test24HourSourceAndToSeparator() throws {
        // 14:30 UTC = 22:30 in Hong Kong, regardless of season.
        let r = try XCTUnwrap(TimeConvert.convert("14:30 UTC to Hong Kong", now: summer))
        XCTAssertEqual(r.value, "22:30")
    }

    func testMeridiemEdgeCases() throws {
        XCTAssertEqual(TimeConvert.convert("12 am UTC in UTC", now: summer)?.value, "0:00")
        XCTAssertEqual(TimeConvert.convert("12 pm UTC in UTC", now: summer)?.value, "12:00")
        XCTAssertEqual(TimeConvert.convert("9pm UTC in UTC", now: summer)?.value, "21:00")
    }

    func testAliases() throws {
        // NYC is EDT (UTC-4) in June: 16:00 UTC = 12:00.
        let r = try XCTUnwrap(TimeConvert.convert("16:00 UTC in NYC", now: summer))
        XCTAssertEqual(r.value, "12:00")
    }

    func testNowQueryResolves() throws {
        // "time in <city>" uses the current instant; 10:00 UTC = 18:00 HKT.
        let r = try XCTUnwrap(TimeConvert.convert("time in Hong Kong", now: summer))
        XCTAssertEqual(r.value, "18:00")
        XCTAssertEqual(r.detail, "now → Hong Kong")
    }

    func testRejectsNonTimeQueries() {
        XCTAssertNil(TimeConvert.convert("100 USD in EUR", now: summer))  // currency
        XCTAssertNil(TimeConvert.convert("12 USD in EUR", now: summer))   // unresolvable zones
        XCTAssertNil(TimeConvert.convert("10 m in ft", now: summer))      // units
        XCTAssertNil(TimeConvert.convert("2+3", now: summer))             // calc
        XCTAssertNil(TimeConvert.convert("30 in berlin", now: summer))    // invalid hour
        XCTAssertNil(TimeConvert.convert("", now: summer))
    }
}
