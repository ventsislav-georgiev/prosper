import XCTest
@testable import ProsperApp

/// The session list feeds the phone's UI, including each agent's state. dch 1.4
/// answers `--ls-json`; older binaries only have `-lj`'s TSV, so both shapes must
/// parse and a garbage/empty read must not invent sessions.
final class DchListParseTests: XCTestCase {

    func testParsesLsJson() {
        let json = """
        [{"name":"a","alias":"Agent A","activity_epoch":1784995163,"state":"blocked"},
         {"name":"b","alias":"","activity_epoch":0,"state":"idle"}]
        """
        let rows = DchCommand.parseListJSON(Data(json.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "a")
        XCTAssertEqual(rows[0].alias, "Agent A")
        XCTAssertEqual(rows[0].activityEpoch, 1784995163)
        XCTAssertEqual(rows[0].state, "blocked")
        XCTAssertEqual(rows[1].alias, "")
        XCTAssertEqual(rows[1].state, "idle")
    }

    /// An older dch prints nothing for `--ls-json` — the caller must see "no rows"
    /// and fall back to the TSV list, not a half-built row.
    func testEmptyAndGarbageJsonYieldNoRows() {
        XCTAssertTrue(DchCommand.parseListJSON(Data()).isEmpty)
        XCTAssertTrue(DchCommand.parseListJSON(Data("dch: unknown option\n".utf8)).isEmpty)
        XCTAssertTrue(DchCommand.parseListJSON(Data("[{\"alias\":\"no name\"}]".utf8)).isEmpty)
    }

    func testParsesTsvWithoutState() {
        let rows = DchCommand.parseListTSV("a\tAgent A\t1784995163\nb\t\t0\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "a")
        XCTAssertEqual(rows[0].alias, "Agent A")
        XCTAssertEqual(rows[0].activityEpoch, 1784995163)
        XCTAssertEqual(rows[0].state, "")   // unknown, and the UI shows nothing for it
        XCTAssertEqual(rows[1].name, "b")
    }
}
