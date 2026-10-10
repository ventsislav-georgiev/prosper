import XCTest
@testable import ProsperApp

/// #354: approval-card text keeps logical order under bidi rule N1 (LRM after each neutral).
final class CardTextTests: XCTestCase {
    func testRTLWordsAroundNeutralsGetLRMs() {
        XCTAssertEqual(CardText.ltr("echo א > ב"), "echo \u{200E}א \u{200E}>\u{200E} \u{200E}ב")
        XCTAssertEqual(CardText.ltr("cat א | ב"), "cat \u{200E}א \u{200E}|\u{200E} \u{200E}ב")
        XCTAssertEqual(CardText.ltr("echo ١ > ٢"), "echo \u{200E}١ \u{200E}>\u{200E} \u{200E}٢")
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
}
