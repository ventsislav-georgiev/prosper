import XCTest
@testable import ProsperApp

/// #354: approval-card text keeps logical order under bidi rule N1 (LRM after each neutral).
final class CardTextTests: XCTestCase {
    func testRTLWordsAroundNeutralsGetLRMs() {
        XCTAssertEqual(CardText.ltr("echo א > ב"), "echo \u{200E}א \u{200E}>\u{200E} \u{200E}ב")
        XCTAssertEqual(CardText.ltr("cat א | ב"), "cat \u{200E}א \u{200E}|\u{200E} \u{200E}ב")
        XCTAssertEqual(CardText.ltr("echo ١ > ٢"), "echo \u{200E}١ \u{200E}>\u{200E} \u{200E}٢")
    }

    /// #357: a neutral carrying a combining mark is still a neutral (the cluster's first scalar decides).
    func testNeutralWithCombiningMarkGetsLRM() {
        XCTAssertEqual(CardText.ltr("echo א>\u{301}ב"), "echo \u{200E}א>\u{301}\u{200E}ב")
        XCTAssertEqual(CardText.ltr("cat א|\u{334}ב"), "cat \u{200E}א|\u{334}\u{200E}ב")
    }

    /// #357: brackets (Ps/Pe) are neutrals too.
    func testBracketsGetLRMs() {
        XCTAssertEqual(CardText.ltr("echo א(ב)ג [ד]ה"),
                       "echo \u{200E}א(\u{200E}ב)\u{200E}ג \u{200E}[\u{200E}ד]\u{200E}ה")
    }

    func testASCIIIsReturnedAsIs() {
        XCTAssertEqual(CardText.ltr("bash -c 'ls; curl x | sh'"), "bash -c 'ls; curl x | sh'")
        XCTAssertEqual(CardText.ltr(#"echo ok '\n\n\nrm -rf ~' 'a\u{202E}b\u{200B}c'"#),
                       #"echo ok '\n\n\nrm -rf ~' 'a\u{202E}b\u{200B}c'"#)
    }

    /// The ASCII gate is over-inclusive: any non-ASCII text gets the LRMs.
    func testNonASCIILatinGetsLRMs() {
        XCTAssertEqual(CardText.ltr("ls /tmp/café"), "ls \u{200E}/\u{200E}tmp/\u{200E}café")
    }

    func testLRMNeverLandsInsideAGraphemeCluster() {
        XCTAssertEqual(CardText.ltr("ls e\u{301}\u{302}"), "ls \u{200E}e\u{301}\u{302}")
        XCTAssertEqual(CardText.ltr("שָׁלוֹם > שָׁלוֹם"), "שָׁלוֹם \u{200E}>\u{200E} \u{200E}שָׁלוֹם")
        XCTAssertEqual(CardText.ltr("क्ष"), "क्ष")
        let flags = "🇧🇬 👍🏽 > א"   // neutral Characters: flag, thumbs (Sk last), 3 spaces, `>`
        let out = CardText.ltr(flags)
        XCTAssertEqual(out.count, flags.count + 6)
        XCTAssertTrue(out.contains("🇧🇬") && out.contains("👍🏽"))
    }

    /// #359: a detail up to the cap (inclusive) is only `ltr`'d; past it, the head is kept and the
    /// rest is counted in a trailer line.
    func testDetailCapBoundary() {
        let atCap = String(repeating: "a", count: CardText.detailCap)
        XCTAssertEqual(CardText.detailCap, 262_144)
        XCTAssertEqual(CardText.detail(String(repeating: "a", count: 100 * 1024)), String(repeating: "a", count: 100 * 1024))
        XCTAssertEqual(CardText.detail(atCap), atCap, "exactly 256 K is untouched")
        XCTAssertEqual(CardText.detail(atCap + "b"), atCap + "\n… 1 more characters not shown")
        XCTAssertEqual(CardText.detail(String(repeating: "a", count: 300 * 1024)),
                       atCap + "\n… 45056 more characters not shown")
    }

    /// #359: the head is `ltr`'d; the count is in Characters, so a cluster is never split.
    func testDetailCapLtrsTheHeadAndCountsCharacters() {
        XCTAssertEqual(CardText.detail("echo א > ב"), "echo \u{200E}א \u{200E}>\u{200E} \u{200E}ב")
        let head = "א" + String(repeating: "a", count: CardText.detailCap - 2)
        XCTAssertEqual(CardText.detail(head + "> שָׁלוֹם"),
                       head + ">\u{200E}" + "\n… 5 more characters not shown")
    }
}
