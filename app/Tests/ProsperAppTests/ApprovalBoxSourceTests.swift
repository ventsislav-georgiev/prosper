import XCTest

/// #359 (QA #137): the approval card's layout is view code no test renders, so its load-bearing
/// lines are pinned by a source scan: the command summary is never line-limited (#323), both
/// boxes are height-capped, and the scroll cue comes from the laid-out height, not a char count.
final class ApprovalBoxSourceTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    func testApprovalBarKeepsTheCommandWholeInHeightCappedBoxes() throws {
        let chat = try source("Sources/ProsperApp/ChatWindow.swift")
        let start = try XCTUnwrap(chat.range(of: "private func approvalBar("))
        let end = try XCTUnwrap(chat.range(of: "private func", range: start.upperBound..<chat.endIndex))
        let bar = chat[start.upperBound..<end.lowerBound]

        XCTAssertGreaterThanOrEqual(bar.components(separatedBy: ".frame(maxHeight: sz(160))").count - 1, 2,
                                    "the summary box and the detail box are both capped at 160 pt")
        let cmd = try XCTUnwrap(bar.range(of: "if req.kind == .command {"))
        let other = try XCTUnwrap(bar.range(of: "} else {", range: cmd.upperBound..<bar.endIndex))
        XCTAssertFalse(bar[cmd.upperBound..<other.lowerBound].contains(".lineLimit("),
                       "the command summary scrolls whole: a lineLimit hides its tail (#323)")
        XCTAssertGreaterThanOrEqual(bar.components(separatedBy: ".onGeometryChange(").count - 1, 2,
                                    "the cue is driven by the laid-out height of both boxes")
        XCTAssertFalse(bar.contains("CardText."), "text is display-ready at construction, not per render")
    }

    func testOverflowCharCountGuessIsGone() throws {
        XCTAssertFalse(try source("Sources/ProsperApp/Harness/CodingHarness.swift").contains("summary.count > 300"))
    }
}
