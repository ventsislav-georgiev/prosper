import XCTest
@testable import ProsperApp

/// #1332 (N937-a, b, c): the signal sender's command as outside data. Fake end strings only; no dch runs, no row is
/// hosted or shown (the tooltip is read by value and its modifier is pinned in the source).
final class AgentIslandSenderCommandTests: XCTestCase {
    private func end(_ command: String) -> String { "signal 15 from 4242 " + command }

    /// N937-a: the cap counts Unicode scalars, cut between whole characters: piled combining marks are bounded too.
    func testSenderCommandIsCappedAtOneHundredTwentyScalars() throws {
        // 6 + 40 * 4 = 166 scalars in 46 characters: 28 whole groups fit (118 scalars), the 29th would make 122.
        let piled = "/bin/k" + String(repeating: "e\u{301}\u{301}\u{301}", count: 40)
        let cut = try XCTUnwrap(AgentIsland.signalSender(end(piled))?.command)
        XCTAssertEqual(cut, "/bin/k" + String(repeating: "e\u{301}\u{301}\u{301}", count: 28))
        XCTAssertEqual(cut.unicodeScalars.count, 118)
        XCTAssertEqual(cut.utf8.count, 6 + 28 * 7)
        // One character longer than the cap alone leaves nothing: no sender.
        XCTAssertTrue(AgentIsland.signalSender(end("a" + String(repeating: "\u{301}", count: 130)))?.command == nil)
        XCTAssertEqual(AgentIsland.endLabel(end("a" + String(repeating: "\u{301}", count: 130))), "ended (signal 15)")
        // ASCII: 120 kept whole, 121 cut to 120.
        XCTAssertEqual(AgentIsland.signalSender(end(String(repeating: "k", count: 121)))?.command, String(repeating: "k", count: 120))
        XCTAssertEqual(AgentIsland.signalSender(end(String(repeating: "k", count: 120)))?.command, String(repeating: "k", count: 120))
    }

    /// N937-b: the Agent Sessions window's History row says the island's end label after "Ended" and a middle dot.
    func testWindowHistoryRowDetailIsTheIslandEndLabel() {
        let r = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "api"), cwd: "/Users/example/api", ended: 100,
                                 end: "signal 15 from 4242 /usr/bin/pkill -f api")
        XCTAssertEqual(AgentSidebar.row(r, now: 200).detail, "Ended \u{00B7} ended (signal 15) from /usr/bin/pkill -f api")
    }

    /// N937-c: the end text's tooltip is the whole capped command (the label cuts it at 48), as outside text: each
    /// base keeps at most three marks; with no sender it is the row's own tooltip.
    @MainActor
    func testEndTextTooltipIsTheWholeCommandAsOutsideText() {
        func row(_ end: String, enabled: Bool = true) -> AgentIslandHistoryRow {
            AgentIslandHistoryRow(record: DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "api"), cwd: "/src",
                                                           ended: 100, end: end),
                                  now: 0, status: nil, enabled: enabled, action: {})
        }
        let long = "/usr/bin/pkill -f " + String(repeating: "k", count: 60)
        XCTAssertEqual(AgentIsland.endLabel(end(long)), "ended (signal 15) from /usr/bin/pkill -f " + String(repeating: "k", count: 30) + "\u{2026}")
        XCTAssertEqual(row(end(long)).endHelp, long)
        XCTAssertEqual(row(end(long), enabled: false).endHelp, long)
        XCTAssertEqual(row(end("/bin/ke\u{301}\u{301}\u{301}\u{301}\u{301} x")).endHelp, "/bin/ke\u{301}\u{301}\u{301} x")
        XCTAssertEqual(row("exit 1").endHelp, AgentIsland.resumeWithMessageHelp)
        XCTAssertEqual(row("signal 15 from 4242", enabled: false).endHelp, "")
    }

    /// N937-c: the tooltip is attached to the end text itself (a SwiftUI help tag cannot be read without a hover).
    func testEndTextCarriesTheTooltip() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AgentIsland/AgentIslandView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let at = try XCTUnwrap(src.range(of: "Text(verbatim: end)"), "the end text")
        let tail = src[at.upperBound...]
        let cwd = try XCTUnwrap(tail.range(of: "Text(verbatim: cwd)"), "the cwd text follows")
        XCTAssertTrue(tail[..<cwd.lowerBound].contains(".help(Text(verbatim: endHelp))"), "the end text carries the command")
    }
}
