import XCTest
@testable import ProsperApp

/// dch's VT mirror is cell contents only, so a phone painting it guessed the caret
/// and drew the input row a line off its box. `--read --cursor` reports the caret on
/// stderr; we hand it to the client as a CUP appended to the screen.
final class DchCursorReportTests: XCTestCase {

    func testCursorLineBecomesACUP() {
        XCTAssertEqual(DchCommand.cursorCUP("cursor 7 12 1 0\n"), "\u{1b}[7;12H")
        XCTAssertEqual(DchCommand.cursorCUP("dch: some warning\ncursor 1 1 1 0\n"), "\u{1b}[1;1H")
    }

    /// dch too old for the flag, a master that predates it, or a garbled line: send
    /// the screen alone and let the client keep its own caret.
    func testNoCursorReportedYieldsNothing() {
        XCTAssertNil(DchCommand.cursorCUP(""))
        XCTAssertNil(DchCommand.cursorCUP("dch: session master predates --cursor\n"))
        XCTAssertNil(DchCommand.cursorCUP("cursor\n"))
        XCTAssertNil(DchCommand.cursorCUP("cursor x y 1 0\n"))
        XCTAssertNil(DchCommand.cursorCUP("cursor 0 0 1 0\n"), "1-based — 0 means no report")
    }
}
