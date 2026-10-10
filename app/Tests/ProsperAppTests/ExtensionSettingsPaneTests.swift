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
    }
}
