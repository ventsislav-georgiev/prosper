import XCTest
@testable import ProsperApp

final class SystemCommandsTests: XCTestCase {

    func testBase64Encode() {
        let r = Base64Tool.run("base64 hi")
        XCTAssertEqual(r?.label, "Base64 encode")
        XCTAssertEqual(r?.value, "aGk=")
    }

    func testBase64EncodeShortAlias() {
        XCTAssertEqual(Base64Tool.run("b64 hi")?.value, "aGk=")
    }

    func testBase64Decode() {
        let r = Base64Tool.run("unbase64 aGk=")
        XCTAssertEqual(r?.label, "Base64 decode")
        XCTAssertEqual(r?.value, "hi")
    }

    func testBase64DecodeRoundTrip() {
        let enc = Base64Tool.run("base64 Hello, World!")!.value
        XCTAssertEqual(Base64Tool.run("base64d \(enc)")?.value, "Hello, World!")
    }

    func testBase64DecodeInvalid() {
        XCTAssertEqual(Base64Tool.run("unbase64 not-valid!!!")?.value, "(invalid base64)")
    }

    func testBase64NoPrefixReturnsNil() {
        XCTAssertNil(Base64Tool.run("hello world"))
    }

    func testMetaQuit() {
        XCTAssertEqual(MetaCommand.parse(":q"), .quit)
        XCTAssertEqual(MetaCommand.parse(":quit"), .quit)
    }

    func testMetaClear() {
        XCTAssertEqual(MetaCommand.parse(":c"), .clearClipboard)
        XCTAssertEqual(MetaCommand.parse(":clear"), .clearClipboard)
    }

    func testMetaUnknownReturnsNil() {
        XCTAssertNil(MetaCommand.parse(":x"))
        XCTAssertNil(MetaCommand.parse("hello"))
    }

    func testEmojiExact() {
        XCTAssertEqual(Emoji.best(forPrefix: "smile")?.emoji, "😄")
        XCTAssertEqual(Emoji.best(forPrefix: "fire")?.emoji, "🔥")
    }

    func testEmojiPrefix() {
        // "thumb" → first alpha match among thumbsdown/thumbsup is thumbsdown.
        let m = Emoji.best(forPrefix: "thumb")
        XCTAssertNotNil(m)
        XCTAssertTrue(m!.name.hasPrefix("thumb"))
    }

    func testEmojiNoMatch() {
        XCTAssertNil(Emoji.best(forPrefix: "zzzznope"))
        XCTAssertNil(Emoji.best(forPrefix: ""))
    }

    func testEmojiMatchesLimit() {
        let ms = Emoji.matches(forPrefix: "s", limit: 5)
        XCTAssertEqual(ms.count, 5)
    }

    func testEmojiTriggerMatches() {
        let t = AutocompleteEngine.emojiTrigger("I am on :fire")
        XCTAssertEqual(t?.emoji, "🔥")
        XCTAssertEqual(t?.length, 5) // ":fire"
    }

    func testEmojiTriggerNoColon() {
        XCTAssertNil(AutocompleteEngine.emojiTrigger("no colon here"))
    }

    func testEmojiTriggerWhitespaceAfterColon() {
        XCTAssertNil(AutocompleteEngine.emojiTrigger("ratio is 3: "))
    }

    func testEmojiTriggerInvalidScheme() {
        // A URL's "//" after the colon is not a valid shortcode.
        XCTAssertNil(AutocompleteEngine.emojiTrigger("http://x"))
    }
}
