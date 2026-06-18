import XCTest
@testable import ProsperApp

final class UnitConvertTests: XCTestCase {

    private func value(_ s: String) -> Double? { UnitConvert.convert(s)?.value }

    func testDuration() {
        // 1 year (Julian, 31557600 s) → minutes = 525960.
        XCTAssertEqual(value("1 year to minutes")!, 525960, accuracy: 0.001)
        XCTAssertEqual(value("2 hours to minutes")!, 120, accuracy: 0.001)
        XCTAssertEqual(value("1 day to hours")!, 24, accuracy: 0.001)
    }

    func testLength() {
        XCTAssertEqual(value("1 km to m")!, 1000, accuracy: 0.001)
        XCTAssertEqual(value("12 in to cm")!, 30.48, accuracy: 0.001)
        XCTAssertEqual(value("1 mile to km")!, 1.609344, accuracy: 0.0001)
    }

    func testMassAndData() {
        XCTAssertEqual(value("1 kg to g")!, 1000, accuracy: 0.001)
        XCTAssertEqual(value("1 lb to oz")!, 16, accuracy: 0.01)
        XCTAssertEqual(value("1 gb to mb")!, 1000, accuracy: 0.001)
    }

    func testTemperature() {
        XCTAssertEqual(value("100 c to f")!, 212, accuracy: 0.001)
        XCTAssertEqual(value("32 f to c")!, 0, accuracy: 0.001)
    }

    func testSynonymsAndSeparators() {
        XCTAssertEqual(value("60 min in s")!, 3600, accuracy: 0.001)   // "in" separator
        XCTAssertEqual(value("1 metre to cm")!, 100, accuracy: 0.001)  // British spelling
    }

    func testRejectsIncompatibleOrUnknown() {
        XCTAssertNil(value("1 kg to m"))        // mass → length: incompatible
        XCTAssertNil(value("1 foo to bar"))     // unknown units
        XCTAssertNil(value("hello to world"))   // no number
        XCTAssertNil(value("128*24"))           // math, not a conversion
    }

    func testFormattedString() {
        XCTAssertEqual(UnitConvert.convert("1 year to minutes")?.formatted, "525960 minutes")
        XCTAssertEqual(UnitConvert.convert("1 km to m")?.formatted, "1000 m")
    }
}
