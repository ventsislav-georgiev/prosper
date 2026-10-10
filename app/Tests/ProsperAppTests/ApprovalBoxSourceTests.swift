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
        let command = String(bar[cmd.upperBound..<other.lowerBound])
        XCTAssertNil(command.range(of: #"\.lineLimit\s*\("#, options: .regularExpression),
                     "the command summary scrolls whole: a lineLimit hides its tail (#323)")
        // #368: the cue compares the text with its box's own laid-out height (the box is shorter
        // than 160 pt near the window's minimum height); unmeasured box (0) = no cue.
        let summaryCue = "if approvalSummaryBoxHeight > 0 && approvalSummaryHeight > approvalSummaryBoxHeight + 0.5 { scrollCue }"
        let detailCue = "if approvalDetailBoxHeight > 0 && approvalDetailHeight > approvalDetailBoxHeight + 0.5 { scrollCue }"
        XCTAssertEqual(command.components(separatedBy: summaryCue).count - 1, 1, "summary cue, in the command branch")
        XCTAssertEqual(bar[other.upperBound...].components(separatedBy: detailCue).count - 1, 1,
                       "detail cue, after the command branch, reading only the detail heights")
        XCTAssertEqual(bar.components(separatedBy: "{ scrollCue }").count - 1, 2, "exactly the two pinned cues")
        XCTAssertEqual(bar.components(separatedBy: "$0.size.height").count - 1, 4,
                       "text and box height measured for both boxes")
        XCTAssertFalse(bar.contains("$0.size.width"), "the cue is about height")
        XCTAssertFalse(bar.contains("CardText."), "text is display-ready at construction, not per render")
    }

    func testOverflowCharCountGuessIsGone() throws {
        XCTAssertFalse(try source("Sources/ProsperApp/Harness/CodingHarness.swift").contains("summary.count > 300"))
        XCTAssertFalse(try source("Sources/ProsperApp/ChatWindow.swift").contains("count > 300"))
    }
}
