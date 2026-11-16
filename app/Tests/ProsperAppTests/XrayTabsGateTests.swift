import XCTest
@testable import ProsperApp

final class XrayTabsGateTests: XCTestCase {
    private func gate(_ v: [Int]) -> DchCommand.Gate { XrayTabs.gate(DchCommand.Binary(path: "/opt/example/dch", version: v)) }

    func testMinimumIs178() { XCTAssertEqual(XrayTabs.minimumDch, [1, 78, 0]) }

    func testOneSeventySevenNineIsRefused() {
        XCTAssertEqual(gate([1, 77, 9]), .refused("needs dch 1.78.0"))
        XCTAssertEqual(gate([1, 9, 99]), .refused("needs dch 1.78.0"))
    }

    func testOneSeventyEightIsAccepted() {
        XCTAssertEqual(gate([1, 78, 0]), .ok("/opt/example/dch"))
        XCTAssertEqual(gate([1, 100, 0]), .ok("/opt/example/dch"))
        XCTAssertEqual(gate([2, 0, 0]), .ok("/opt/example/dch"))
    }

    func testShortFormIsCompared() {   // isAtLeast pads missing components with 0
        XCTAssertEqual(gate([1, 78]), .ok("/opt/example/dch"))
        XCTAssertEqual(gate([1, 77]), .refused("needs dch 1.78.0"))
    }

    func testNoBinaryIsRefused() { XCTAssertEqual(XrayTabs.gate(nil), .refused("needs dch 1.78.0")) }

    func testVersionOutputParse() {   // the probe's own parse: "dch 1.78" has no short form, so it never reaches the gate
        XCTAssertEqual(DchCommand.parseVersion("dch 1.78.0\n"), [1, 78, 0])
        XCTAssertTrue(DchCommand.parseVersion("dch 1.78") == nil)
    }
}
