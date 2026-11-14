import XCTest
@testable import ProsperApp

final class OutsideTextTests: XCTestCase {
    func testUnseenScalarsAreDropped() {
        for u in ["\u{202E}", "\u{200B}", "\u{0}", "\u{7}", "\t", "\u{2800}", "\u{3164}", "\u{FE0F}", "\u{A0}", "\u{2028}"] {
            XCTAssertEqual(OutsideText.shown("a\(u)b"), "ab", "U+\(String(u.unicodeScalars.first!.value, radix: 16))")
        }
    }

    func testSpaceLettersAccentsAndEmojiStay() {
        for s in ["a b", "caf\u{E9} \u{FC}ber", "ok \u{1F600}"] { XCTAssertEqual(OutsideText.shown(s), s) }
    }

    func testCutAtMax() {
        let s = String(repeating: "a", count: 10)
        XCTAssertEqual(OutsideText.shown(s, max: 10), s)
        XCTAssertEqual(OutsideText.shown(s, max: 9), String(repeating: "a", count: 8) + "\u{2026}")
        XCTAssertEqual(OutsideText.shown(s, max: 1), "\u{2026}")
        XCTAssertEqual(OutsideText.shown(s, max: 0), "\u{2026}")
        XCTAssertEqual(OutsideText.shown(String(repeating: "a", count: 200)).count, 160)
    }

    func testCCPoolForwardGivesTheSameString() {
        for s in ["../x\u{202E}y\u{7}z\u{200B}", "a\u{2800}b\u{3164}c", "plain \u{1F600}", String(repeating: "z", count: 300)] {
            XCTAssertEqual(CCPoolStore.shown(s), OutsideText.shown(s))
            XCTAssertEqual(CCPoolStore.shown(s, max: 5), OutsideText.shown(s, max: 5))
        }
    }
}
