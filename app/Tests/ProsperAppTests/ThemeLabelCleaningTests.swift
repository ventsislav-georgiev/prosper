import XCTest
@testable import ProsperApp

/// #928: a theme's labels and title come from an extension's files and are shown and read aloud.
/// Every label here is a literal passed to the function: no theme is installed, nothing is shown.
final class ThemeLabelCleaningTests: XCTestCase {
    private func clean(_ s: String) -> String? { ThemeVariant.cleanLabel(s) }

    /// What the rule reads from the standard library, for the scalars in the rows below.
    func testThePropertiesTheRuleReadsAnswerAsTheRowsAssume() {
        func p(_ v: UInt32) -> Unicode.Scalar.Properties { Unicode.Scalar(v)!.properties }
        // Caught only by isDefaultIgnorableCodePoint: a letter and a combining mark.
        XCTAssertEqual(p(0x3164).generalCategory, .otherLetter)
        XCTAssertEqual(p(0x034F).generalCategory, .nonspacingMark)
        XCTAssertTrue(p(0x3164).isDefaultIgnorableCodePoint && p(0x034F).isDefaultIgnorableCodePoint)
        // Caught by the format category (and also default-ignorable).
        XCTAssertEqual(p(0x200B).generalCategory, .format)
        XCTAssertEqual(p(0x202E).generalCategory, .format)
        // The joiners and VS16: format / nonspacing, default-ignorable, so kept only by the emoji arm.
        XCTAssertTrue(p(0x200D).isJoinControl && p(0x200C).isJoinControl)
        XCTAssertTrue(p(0xFE0F).isVariationSelector && p(0xFE0F).isDefaultIgnorableCodePoint)
        XCTAssertFalse(p(0xFE0F).isEmoji)
        // isEmoji: the ASCII keycap bases too; isEmojiPresentation: false for text-style emoji.
        XCTAssertTrue(p(0x31).isEmoji && !p(0x31).isEmojiPresentation)
        XCTAssertTrue(p(0x2764).isEmoji && !p(0x2764).isEmojiPresentation)
        XCTAssertTrue(p(0x1F3F3).isEmoji && !p(0x1F3F3).isEmojiPresentation)
        XCTAssertTrue(p(0x1F468).isEmojiPresentation && p(0x1F600).isEmojiPresentation)
        XCTAssertTrue(p(0x1F1FA).isEmoji && p(0x1F3FD).isEmoji)
    }

    /// 928-4 and 928-7: scalars only the default-ignorable test catches, apart from a format scalar.
    func testDefaultIgnorableArmIsHeldApartFromTheFormatArm() {
        XCTAssertEqual(clean("Li\u{3164}me"), "Lime")
        XCTAssertEqual(clean("Cy\u{034F}an"), "Cyan")
        XCTAssertEqual(clean("Red\u{FE0F}"), "Red")
        XCTAssertTrue(clean("\u{3164}") == nil)
        XCTAssertEqual(clean("Li\u{200B}me"), "Lime")
    }

    /// Nothing invisible, no direction, control or line break survives outside an emoji sequence.
    func testOverridesControlsBreaksAndStrayJoinersAreDropped() {
        XCTAssertEqual(clean("\u{202E}Lime"), "Lime")
        XCTAssertEqual(clean("Li\u{202E}me\u{202C}"), "Lime")
        XCTAssertEqual(clean("Li\u{0007}me\nX\u{2028}"), "LimeX")
        XCTAssertEqual(clean("Li\u{200D}me"), "Lime", "a joiner between letters")
        XCTAssertEqual(clean("Li\u{200C}me"), "Lime")
        XCTAssertEqual(clean("\u{1F600}\u{200C}\u{1F600}"), "\u{1F600}\u{1F600}", "ZWNJ joins no emoji")
        XCTAssertEqual(clean("1\u{200D}2"), "12", "digits are isEmoji but never joined")
        XCTAssertEqual(clean("\u{200D}\u{1F600}"), "\u{1F600}", "a joiner with nothing before it")
        XCTAssertEqual(clean("\u{1F600}\u{200D}"), "\u{1F600}", "a joiner with nothing after it")
        XCTAssertEqual(clean("\u{1F600}\u{200D}\u{200D}\u{1F600}"), "\u{1F600}\u{200D}\u{1F600}", "a run of joiners is one")
        XCTAssertEqual(clean("1\u{FE0F}"), "1", "VS16 on a keycap base without the keycap")
        XCTAssertEqual(clean("\u{1F600}\u{FE0F}"), "\u{1F600}", "VS16 on an emoji-style emoji changes nothing")
        XCTAssertEqual(clean("\u{2764}\u{FE0F}\u{FE0F}"), "\u{2764}\u{FE0F}", "a second VS16")
        XCTAssertEqual(clean("Sky\u{00A0}Blue\u{2800}"), "Sky Blue", "OutsideText's whitespace and blank rule")
        XCTAssertTrue(clean("\u{200D}\u{FE0F}\u{202E}") == nil, "only invisibles: the caller's default")
    }

    /// 928-5: an emoji sequence the string really forms stays one Character.
    func testEmojiSequencesStayWhole() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let flag = "\u{1F1FA}\u{1F1F8}"
        let keycap = "1\u{FE0F}\u{20E3}"
        let heart = "\u{2764}\u{FE0F}"
        let rainbow = "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"
        for e in [family, flag, keycap, heart, rainbow] {
            XCTAssertEqual(clean(e), e, e.debugDescription)
            XCTAssertEqual(clean(e)?.count, 1, e.debugDescription)
        }
        XCTAssertEqual(clean(" Team \(family)\n"), "Team \(family)")
    }

    /// 928-6: the cut falls on a Character edge, at 32 Characters and at most 128 scalars.
    func testTheCutFallsOnACharacterEdgeUnderTheScalarCeiling() {
        let thumb = "\u{1F44D}\u{1F3FD}"
        XCTAssertEqual(clean(String(repeating: thumb, count: 40)), String(repeating: thumb, count: 32), "40 Characters cut to 32")
        let x31 = String(repeating: "x", count: 31), family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(clean(x31 + family + "y"), x31 + family)
        let families = String(repeating: family, count: 30)   // 30 Characters, 150 scalars
        XCTAssertEqual(clean(families), String(repeating: family, count: 25), "the scalar ceiling: 25 x 5 = 125")
        let c16 = "e" + String(repeating: "\u{0301}", count: 15)   // 16 scalars, one Character
        XCTAssertEqual(clean(String(repeating: c16, count: 9)), String(repeating: c16, count: 8), "128 scalars: eight whole, the ninth gone")
        XCTAssertEqual(clean(String(repeating: c16, count: 7) + "y" + c16), String(repeating: c16, count: 7) + "y", "the total would be crossed inside the next Character: it is left out whole")
        XCTAssertEqual(clean(c16)?.unicodeScalars.count, 16, "kept whole, not cut at 32 scalars")
        XCTAssertEqual(clean("Ab" + "e" + String(repeating: "\u{0301}", count: 200)), "Ab", "a Character over the ceiling is left out whole")
    }

    /// 928-8: a theme's title (spoken in the tint dot's label) is cleaned where the descriptor is made.
    func testThemeTitleIsCleanedLikeALabel() {
        func title(_ t: String) -> String {
            ThemeDescriptor(id: "t.x", title: t, appearance: .dark, extensionID: "e", jsonPath: nil).title
        }
        XCTAssertEqual(title("\u{202E}Ocean\u{200B} Blue\n"), "Ocean Blue")
        XCTAssertEqual(title("Ocean \u{1F30A}\u{FE0F}"), "Ocean \u{1F30A}")
        XCTAssertEqual(title("\u{200B}\u{2028}"), "Untitled theme")
        XCTAssertEqual(title(String(repeating: "x", count: 40)), String(repeating: "x", count: 32))
        XCTAssertEqual(ThemeDescriptor.builtIn.title, "Default")
    }

    /// R928-1: a space separator (general category Zs) is kept as U+0020; nothing that breaks a line is.
    func testSpaceSeparatorsBecomeAPlainSpaceAndBreaksStayDropped() {
        func p(_ v: UInt32) -> Unicode.Scalar.Properties { Unicode.Scalar(v)!.properties }
        for v: UInt32 in [0x00A0, 0x202F, 0x3000, 0x2009] { XCTAssertEqual(p(v).generalCategory, .spaceSeparator) }
        XCTAssertEqual(p(0x2800).generalCategory, .otherSymbol, "the Braille blank is a symbol, not a space")
        XCTAssertEqual(p(0x2028).generalCategory, .lineSeparator)
        XCTAssertEqual(p(0x2029).generalCategory, .paragraphSeparator)
        for sp in ["\u{00A0}", "\u{202F}", "\u{3000}", "\u{2009}"] {
            XCTAssertEqual(clean("Sky\(sp)Blue"), "Sky Blue", sp.debugDescription)
        }
        for br in ["\u{2028}", "\u{2029}", "\u{0009}", "\u{000A}"] {
            XCTAssertEqual(clean("Sky\(br)Blue"), "SkyBlue", br.debugDescription)
        }
        XCTAssertEqual(clean("Sky\u{2800}Blue"), "SkyBlue")
        XCTAssertEqual(clean("Sky\u{00A0}\u{3000}Blue"), "Sky  Blue", "a run is not collapsed, as for U+0020 today")
        XCTAssertEqual(clean("Sky  Blue"), "Sky  Blue")
        XCTAssertEqual(clean("\u{3000}Sky\u{00A0}"), "Sky", "trimmed")
        XCTAssertTrue(clean("\u{3000}") == nil, "only spaces: the caller's default")
        XCTAssertTrue(clean("\u{00A0}\u{2009}\u{3000}") == nil)
        let x30 = String(repeating: "x", count: 30)
        XCTAssertEqual(clean(x30 + "\u{3000}" + "yz"), x30 + " y", "a mapped space counts as one Character")
        func title(_ t: String) -> String {
            ThemeDescriptor(id: "t.x", title: t, appearance: .dark, extensionID: "e", jsonPath: nil).title
        }
        XCTAssertEqual(title("Ocean\u{00A0}Blue"), "Ocean Blue")
        XCTAssertEqual(title("Ocean\u{2028}Blue"), "OceanBlue")
        XCTAssertEqual(title("\u{3000}"), "Untitled theme")
    }

    /// R928-2: a Character over 16 scalars ends the label (never skipped with later text kept).
    func testACharacterOver16ScalarsEndsTheLabel() {
        let family7 = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(family7.unicodeScalars.count, 7)
        let thumb = "\u{1F44D}\u{1F3FD}", flag = "\u{1F1FA}\u{1F1F8}", keycap = "1\u{FE0F}\u{20E3}"
        for e in [family7, flag, keycap, thumb] { XCTAssertEqual(clean("Ab" + e), "Ab" + e, e.debugDescription) }
        let c16 = "e" + String(repeating: "\u{0301}", count: 15), c17 = "e" + String(repeating: "\u{0301}", count: 16)
        XCTAssertEqual(c16.count, 1)
        XCTAssertEqual(c17.count, 1)
        XCTAssertEqual(clean(c16), c16, "exactly 16 scalars is kept")
        XCTAssertEqual(clean("Ab" + c16), "Ab" + c16)
        XCTAssertEqual(clean("Ab" + c17), "Ab")
        XCTAssertEqual(clean("Ab" + c17 + "Cd"), "Ab", "stops: later text is not kept")
        XCTAssertTrue(clean(c17) == nil, "only the oversized Character: the default")
    }
}
