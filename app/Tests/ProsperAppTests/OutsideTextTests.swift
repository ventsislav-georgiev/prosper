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

    // MARK: #1251: at most three combining marks (Mn, Me) per base (R1251-s1a)

    /// Compared scalar by scalar: String == is canonical equivalence and would hide a dropped or reordered mark.
    private static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
    private static func marks(_ c: Character) -> Int {
        c.unicodeScalars.filter { let g = $0.properties.generalCategory; return g == .nonspacingMark || g == .enclosingMark }.count
    }
    private static func stack(_ base: String, _ mark: String, _ n: Int = 24) -> String { base + String(repeating: mark, count: n) }

    func testCapMarksKeepsThreePerBase() {
        XCTAssertEqual(OutsideText.maxMarks, 3)
        XCTAssertEqual(AgentPrompt.maxMarks, OutsideText.maxMarks, "one number for the card and the cap")
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(Self.stack("a", "\u{0323}"))), Self.scalars("a\u{0323}\u{0323}\u{0323}"), "below")
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(Self.stack("a", "\u{0301}"))), Self.scalars("a\u{0301}\u{0301}\u{0301}"), "above")
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(Self.stack("a", "\u{20DD}"))), Self.scalars("a\u{20DD}\u{20DD}\u{20DD}"), "enclosing")
        // the fourth mark is the first one dropped
        XCTAssertEqual(Self.scalars(OutsideText.capMarks("a\u{0323}\u{0301}\u{0302}\u{0304}b")), Self.scalars("a\u{0323}\u{0301}\u{0302}b"), "four")
        // marks with no base are one character: bounded the same way, not emptied
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(String(repeating: "\u{0323}", count: 24))), Self.scalars("\u{0323}\u{0323}\u{0323}"))
        // three marks on one letter: unchanged
        for s in ["", "Fake Kit 2.0", "Caf\u{0065}\u{0301}", "Vi\u{0065}\u{0323}\u{0302}t", "a\u{0323}\u{0301}\u{0302}"] {
            XCTAssertEqual(Self.scalars(OutsideText.capMarks(s)), Self.scalars(s), "unchanged: \(Self.scalars(s))")
        }
        // a spacing mark (Mc, U+0903 DEVANAGARI SIGN VISARGA) is not counted: one character, every scalar kept
        let spacing = Self.stack("\u{0915}", "\u{0903}", 3)
        XCTAssertEqual(spacing.count, 1)
        XCTAssertEqual(Self.scalars(OutsideText.capMarks(spacing)), Self.scalars(spacing))
    }

    func testShownCapsMarksAfterTheDropAndBeforeTheCut() {
        for m in ["\u{0323}", "\u{0301}", "\u{20DD}"] {
            XCTAssertEqual(Self.scalars(OutsideText.shown(Self.stack("a", m) + Self.stack("b", m))), Self.scalars("a\(m)\(m)\(m)b\(m)\(m)\(m)"))
        }
        // the order: a dropped control between two groups of marks joins them on one letter, which then keeps three
        XCTAssertEqual(Self.scalars(OutsideText.shown("a\u{0323}\u{0323}\u{0007}\u{0323}\u{0323}\u{0323}b")), Self.scalars("a\u{0323}\u{0323}\u{0323}b"))
        // the cut still counts characters: 200 stacked letters give 120, the last the ellipsis, each bounded
        let long = String(repeating: Self.stack("a", "\u{0323}"), count: 200)
        let cut = OutsideText.shown(long, max: 120)
        XCTAssertEqual(cut.count, 120)
        XCTAssertTrue(cut.hasSuffix("\u{2026}"))
        XCTAssertTrue(cut.allSatisfy { $0.unicodeScalars.count <= 4 && Self.marks($0) <= 3 })
        // no cut at all does not trap and still caps
        let whole = OutsideText.shown(long, max: .max)
        XCTAssertEqual(whole.count, 200)
        XCTAssertTrue(whole.allSatisfy { Self.scalars(String($0)) == Self.scalars("a\u{0323}\u{0323}\u{0323}") })
        XCTAssertEqual(Self.scalars(CCPoolStore.shown(Self.stack("a", "\u{0323}"))), Self.scalars("a\u{0323}\u{0323}\u{0323}"), "the CCPool forward caps too")
    }

    // MARK: B1251-2: the marks are counted per base, so ordinary conjuncts keep theirs

    /// QA 1064's words: one conjunct is one character, and its viramas are marks. Then QA r1092's four (R1251-s1a), each
    /// with three marks on one base: whole and approvable at three.
    static let words = [
        "\u{0935}\u{0938}\u{094D}\u{0924}\u{094D}\u{0930}\u{094B}\u{0902}",         // Hindi "garments" (oblique plural)
        "\u{0936}\u{093E}\u{0938}\u{094D}\u{0924}\u{094D}\u{0930}\u{094B}\u{0902}", // Hindi "scriptures" (oblique plural)
        "\u{0938}\u{094D}\u{0924}\u{094D}\u{0930}\u{0948}\u{0923}",                 // Hindi "feminine"
        "\u{092E}\u{0928}\u{094D}\u{0924}\u{094D}\u{0930}\u{0902}",                 // Hindi, a mantra form
        // Hindi "I will read": dha with nukta, vowel sign uu and candrabindu (three marks on one base)
        "\u{092A}\u{0922}\u{093C}\u{0942}\u{0901}\u{0917}\u{093E}",
        // Hindi "zen": ja with nukta, vowel sign e and anusvara (three marks on one base)
        "\u{091C}\u{093C}\u{0947}\u{0902}",
        // Tibetan "sgrub": sa, subjoined ga, subjoined ra, vowel sign u (three marks on one base)
        "\u{0F56}\u{0F66}\u{0F92}\u{0FB2}\u{0F74}\u{0F56}\u{0F66}",
        // pointed Hebrew bet with dagesh, qamats and meteg (three marks on one base)
        "\u{05D1}\u{05BC}\u{05B8}\u{05BD}",
    ]
    /// Bengali "with a weapon": a three-consonant conjunct with a vowel sign.
    static let bengali = "\u{0985}\u{09B8}\u{09CD}\u{09A4}\u{09CD}\u{09B0}\u{09C7}"

    func testOrdinaryConjunctsKeepEveryMark() {
        for w in Self.words + [Self.bengali] {
            XCTAssertEqual(Self.scalars(OutsideText.shown(w)), Self.scalars(w), "\(Self.scalars(w))")
        }
    }

    func testEachBaseKeepsThreeMarks() {
        // two letters, 24 marks each: three kept on each letter
        let pile = "a" + String(repeating: "\u{0323}", count: 24) + "b" + String(repeating: "\u{0301}", count: 24)
        XCTAssertEqual(Self.scalars(OutsideText.shown(pile)), Self.scalars("a\u{0323}\u{0323}\u{0323}b\u{0301}\u{0301}\u{0301}"))
        // a two-consonant conjunct, four marks on each consonant: three kept on each
        let conjunct = "\u{0938}\u{093C}\u{094D}\u{0951}\u{0952}\u{0924}\u{093C}\u{0902}\u{0951}\u{0952}"
        XCTAssertEqual(Self.scalars(OutsideText.shown(conjunct)),
                       Self.scalars("\u{0938}\u{093C}\u{094D}\u{0951}\u{0924}\u{093C}\u{0902}\u{0951}"))
        // two marks, a spacing mark (Mc), two marks: one character with two bases, so four marks on it and every one kept
        let restarted = "\u{0915}\u{0951}\u{0952}\u{0903}\u{0951}\u{0952}"
        XCTAssertEqual(restarted.count, 1)
        XCTAssertEqual(Self.scalars(OutsideText.shown(restarted)), Self.scalars(restarted))
    }

    func testShownCutsAfterACapThatDropsAFourthMarkVirama() {
        // per base the fourth mark on a consonant can be its virama: the conjunct splits, so the cut still comes after the cap
        let s = String(repeating: "\u{0915}\u{093C}\u{0951}\u{0952}\u{094D}", count: 3) + "\u{0915}"
        XCTAssertLessThanOrEqual(OutsideText.shown(s, max: 2).count, 2)
    }

    func testShownCutsAfterACapThatSplitsACharacter() {
        // R1251-a: the cap can split a character (a dropped fourth mark ends a conjunct), so the cut must come after the cap
        XCTAssertLessThanOrEqual(OutsideText.shown(String(repeating: "\u{915}\u{94D}\u{93C}\u{900}\u{951}", count: 3) + "\u{915}", max: 2).count, 2)
    }
}
