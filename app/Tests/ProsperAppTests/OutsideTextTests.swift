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

    // MARK: #1251: at most two combining marks (Mn, Me) per character

    /// Compared scalar by scalar: String == is canonical equivalence and would hide a dropped or reordered mark.
    private static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
    private static func marks(_ c: Character) -> Int {
        c.unicodeScalars.filter { let g = $0.properties.generalCategory; return g == .nonspacingMark || g == .enclosingMark }.count
    }
    private static func stack(_ base: String, _ mark: String, _ n: Int = 24) -> String { base + String(repeating: mark, count: n) }

    func testCapMarksKeepsTwoPerCharacter() {
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(Self.stack("a", "\u{0323}"))), Self.scalars("a\u{0323}\u{0323}"), "below")
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(Self.stack("a", "\u{0301}"))), Self.scalars("a\u{0301}\u{0301}"), "above")
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(Self.stack("a", "\u{20DD}"))), Self.scalars("a\u{20DD}\u{20DD}"), "enclosing")
        // marks with no base are one character: bounded the same way, not emptied
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(String(repeating: "\u{0323}", count: 24))), Self.scalars("\u{0323}\u{0323}"))
        for s in ["", "Fake Kit 2.0", "Caf\u{0065}\u{0301}", "Vi\u{0065}\u{0323}\u{0302}t"] {
            XCTAssertEqual(Self.scalars(OutsideText.capMarks(s)), Self.scalars(s), "unchanged: \(Self.scalars(s))")
        }
        // a spacing mark (Mc, U+0903 DEVANAGARI SIGN VISARGA) is not counted: one character, every scalar kept
        let spacing = Self.stack("\u{0915}", "\u{0903}", 3)
        XCTAssertEqual(spacing.count, 1)
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(spacing)), Self.scalars(spacing))
    }

    func testShownCapsMarksAfterTheDropAndBeforeTheCut() {
        for m in ["\u{0323}", "\u{0301}", "\u{20DD}"] {
            XCTAssertEqual(Self.scalars(OutsideText.shown(Self.stack("a", m) + Self.stack("b", m))), Self.scalars("a\(m)\(m)b\(m)\(m)"))
        }
        // the order: a dropped control between two groups of marks joins them on one letter, which then keeps two
        XCTAssertEqual(Self.scalars(OutsideText.shown("a\u{0323}\u{0323}\u{0007}\u{0323}\u{0323}\u{0323}b")), Self.scalars("a\u{0323}\u{0323}b"))
        // the cut still counts characters: 200 stacked letters give 120, the last the ellipsis, each bounded
        let long = String(repeating: Self.stack("a", "\u{0323}"), count: 200)
        let cut = OutsideText.shown(long, max: 120)
        XCTAssertEqual(cut.count, 120)
        XCTAssertTrue(cut.hasSuffix("\u{2026}"))
        XCTAssertTrue(cut.allSatisfy { $0.unicodeScalars.count <= 3 && Self.marks($0) <= 2 })
        // no cut at all does not trap and still caps
        let whole = OutsideText.shown(long, max: .max)
        XCTAssertEqual(whole.count, 200)
        XCTAssertTrue(whole.allSatisfy { Self.scalars(String($0)) == Self.scalars("a\u{0323}\u{0323}") })
        XCTAssertEqual(Self.scalars(CCPoolStore.shown(Self.stack("a", "\u{0323}"))), Self.scalars("a\u{0323}\u{0323}"), "the CCPool forward caps too")
    }
}
