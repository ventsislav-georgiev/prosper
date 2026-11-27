import XCTest
@testable import ProsperApp

/// The field label is read over cross-process AX calls: each attribute at most once.
final class AXCaretFieldLabelTests: XCTestCase {
    private func run(_ values: [String: String]) -> (label: String?, reads: [String]) {
        var reads: [String] = []
        let label = AXCaret.firstLabel(["d", "p", "t"]) { reads.append($0); return values[$0] }
        return (label, reads)
    }

    func testWinnerIsReadOnce() {
        let r = run(["d": "Subject line", "p": "Other"])
        XCTAssertTrue(r.label == "Subject line")
        XCTAssertTrue(r.reads == ["d"])
    }

    func testNilThenHitReadsExactlyTwo() {
        let r = run(["d": " x ", "p": "Search mail", "t": "Title"])
        XCTAssertTrue(r.label == "Search mail")
        XCTAssertTrue(r.reads == ["d", "p"])
    }

    func testNoHitReadsEachOnceAndReturnsNil() {
        let r = run([:])
        XCTAssertTrue(r.label == nil)
        XCTAssertTrue(r.reads == ["d", "p", "t"])
    }
}
