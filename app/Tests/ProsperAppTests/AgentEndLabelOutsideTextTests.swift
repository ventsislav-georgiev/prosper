import XCTest
@testable import ProsperApp

/// #1313 step b: AgentIsland.endLabel shows dch's outside text through OutsideText.shown (unseen scalars dropped, capped).
/// Fake strings only; pure value rows.
final class AgentEndLabelOutsideTextTests: XCTestCase {
    private let dirty = "x\u{202E}y\u{0007}z\nw"

    private func assertClean(_ label: String, cap: Int, _ what: String, line: UInt = #line) {
        XCTAssertTrue(!label.unicodeScalars.contains { OutsideText.isUnseen($0) }, "\(what): unseen scalar in \(label.debugDescription)", line: line)
        XCTAssertLessThanOrEqual(label.count, cap, what, line: line)
    }

    func testExitBranchDropsUnseenScalarsAndCaps() {
        XCTAssertEqual(AgentIsland.endLabel("exit " + dirty), "exited (xyzw)")
        let long = AgentIsland.endLabel("exit " + String(repeating: "k", count: 200) + dirty)
        XCTAssertEqual(long, "exited (" + String(repeating: "k", count: 39) + "\u{2026})")
        assertClean(String(long.dropFirst(8).dropLast()), cap: 40, "exit")
    }

    func testSignalBranchDropsUnseenScalarsAndCaps() {
        XCTAssertEqual(AgentIsland.endLabel("signal " + dirty), "crashed (signal xyzw)")
        let long = AgentIsland.endLabel("signal " + String(repeating: "k", count: 200) + dirty)
        XCTAssertEqual(long, "crashed (signal " + String(repeating: "k", count: 32) + "\u{2026})")
        assertClean(String(long.dropFirst(9).dropLast()), cap: 40, "signal")
    }

    func testDefaultBranchDropsUnseenScalarsAndCaps() {
        XCTAssertEqual(AgentIsland.endLabel("gone " + dirty), "gone xyzw")
        let long = AgentIsland.endLabel(String(repeating: "k", count: 200) + dirty)
        XCTAssertEqual(long, String(repeating: "k", count: 59) + "\u{2026}")
        assertClean(long, cap: 60, "default")
    }

    func testOrdinaryEndsReadAsBefore() {
        for (end, label) in [("exit 0", "exited"), ("exit 1", "exited (1)"), ("signal 9", "crashed (signal 9)"),
                             ("signal 15", "ended (signal 15)"), ("paused", "paused"), ("", "vanished")] {
            XCTAssertEqual(AgentIsland.endLabel(end), label, end)
        }
    }
}
