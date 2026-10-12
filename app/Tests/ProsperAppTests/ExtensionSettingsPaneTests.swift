import XCTest
@testable import ProsperApp

final class ExtensionSettingsPaneTests: XCTestCase {
    func testNumberRowFormat() {
        XCTAssertEqual(NumberRow.format(text: "1e19", min: nil, max: nil), String(1e19))
        XCTAssertEqual(NumberRow.format(text: "inf", min: nil, max: nil), "0")
        XCTAssertEqual(NumberRow.format(text: "nan", min: 2, max: nil), "2")
        XCTAssertEqual(NumberRow.format(text: "7", min: nil, max: nil), "7")
        XCTAssertEqual(NumberRow.format(text: "7.5", min: nil, max: nil), "7.5")
        XCTAssertEqual(NumberRow.format(text: "-3", min: 0, max: nil), "0")
        XCTAssertEqual(NumberRow.format(text: "abc", min: -5, max: nil), "-5")
        // Non-finite min/max (TOML inf/nan) is ignored, not stored as "nan"/"-inf".
        XCTAssertEqual(NumberRow.format(text: "abc", min: .nan, max: nil), "0")
        XCTAssertEqual(NumberRow.format(text: "5", min: nil, max: -.infinity), "5")
        XCTAssertEqual(NumberRow.format(text: "5", min: .infinity, max: nil), "5")
        XCTAssertEqual(NumberRow.format(text: "9", min: -.infinity, max: 3), "3")
        // #385 (QA #168): garbage input with a -inf min saves 0, never the text "-inf".
        XCTAssertEqual(NumberRow.format(text: "abc", min: -.infinity, max: nil), "0")
    }
}
