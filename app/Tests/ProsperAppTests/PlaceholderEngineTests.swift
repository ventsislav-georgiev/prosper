import XCTest
@testable import ProsperApp

/// Covers `PlaceholderEngine`: token resolution, modifiers, dates with offsets
/// (deterministic injected clock), `{cursor}` offset, recursion, and arguments.
final class PlaceholderEngineTests: XCTestCase {

    /// A context with a fixed clock in UTC + POSIX locale for stable date output.
    private func fixedContext(date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> PlaceholderContext {
        var ctx = PlaceholderContext()
        ctx.now = { date }
        ctx.locale = Locale(identifier: "en_US_POSIX")
        ctx.timeZone = TimeZone(identifier: "UTC")!
        return ctx
    }

    func testLiteralPassThrough() {
        let (text, cursor) = PlaceholderEngine.render("hello world", PlaceholderContext())
        XCTAssertEqual(text, "hello world")
        XCTAssertNil(cursor)
    }

    func testEscapedBraces() {
        XCTAssertEqual(PlaceholderEngine.render("{{a}} {{b}}", PlaceholderContext()).text, "{a} {b}")
    }

    func testUnknownTokenLeftLiteral() {
        XCTAssertEqual(PlaceholderEngine.render("x {weather} y", PlaceholderContext()).text, "x {weather} y")
    }

    func testCustomResolver() {
        var ctx = PlaceholderContext()
        ctx.custom = { name, _ in name == "weather" ? "sunny" : nil }
        XCTAssertEqual(PlaceholderEngine.render("It is {weather}", ctx).text, "It is sunny")
    }

    func testClipboard() {
        var ctx = PlaceholderContext()
        ctx.clipboard = { "pasted" }
        XCTAssertEqual(PlaceholderEngine.render("[{clipboard}]", ctx).text, "[pasted]")
    }

    func testClipboardHistoryIndex() {
        var ctx = PlaceholderContext()
        ctx.clipboardHistory = { n in ["zero", "one", "two"][safe: n] }
        XCTAssertEqual(PlaceholderEngine.render("{clipboard:2}", ctx).text, "two")
    }

    func testModifierUppercaseAndChain() {
        var ctx = PlaceholderContext()
        ctx.clipboard = { "  raycast  " }
        XCTAssertEqual(PlaceholderEngine.render("{clipboard | trim | uppercase}", ctx).text, "RAYCAST")
    }

    func testPercentEncodeModifier() {
        XCTAssertEqual(
            PlaceholderEngine.render("{argument default=\"a b&c\" | percent-encode}", PlaceholderContext()).text,
            "a%20b%26c")
    }

    func testCursorOffset() {
        let (text, cursor) = PlaceholderEngine.render("ab{cursor}cd", PlaceholderContext())
        XCTAssertEqual(text, "abcd")
        XCTAssertEqual(cursor, 2)
    }

    func testCursorFirstWins() {
        let (_, cursor) = PlaceholderEngine.render("a{cursor}b{cursor}", PlaceholderContext())
        XCTAssertEqual(cursor, 1)
    }

    func testUUIDShape() {
        let text = PlaceholderEngine.render("{uuid}", PlaceholderContext()).text
        XCTAssertEqual(text.count, 36)
        XCTAssertEqual(text.filter { $0 == "-" }.count, 4)
    }

    func testArgumentDefaultAndOverride() {
        let template = "Feeling {argument name=\"tone\" default=\"happy\"}"
        XCTAssertEqual(PlaceholderEngine.render(template, PlaceholderContext()).text, "Feeling happy")
        var ctx = PlaceholderContext()
        ctx.arguments = ["tone": "sad"]
        XCTAssertEqual(PlaceholderEngine.render(template, ctx).text, "Feeling sad")
    }

    func testArgumentsExtraction() {
        let specs = PlaceholderEngine.arguments(in: "{argument name=\"a\"} {argument name=\"b\" default=\"x\"} {argument name=\"a\"}")
        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs[0].name, "a")
        XCTAssertTrue(specs[0].required)
        XCTAssertEqual(specs[1].name, "b")
        XCTAssertFalse(specs[1].required)
        XCTAssertEqual(specs[1].defaultValue, "x")
    }

    func testSnippetEmbedIgnoresInnerCursor() {
        var ctx = PlaceholderContext()
        ctx.snippetByKeyword = { $0 == "sig" ? "Best,{cursor} Me" : nil }
        let (text, cursor) = PlaceholderEngine.render("--\n{snippet:sig}!", ctx)
        XCTAssertEqual(text, "--\nBest, Me!")
        XCTAssertNil(cursor)
    }

    func testSnippetRecursionDepthGuardTerminates() {
        var ctx = PlaceholderContext()
        ctx.snippetByKeyword = { $0 == "a" ? "{snippet:a}" : nil }  // self-referential
        // Must terminate (depth guard) and not hang.
        XCTAssertEqual(PlaceholderEngine.render("{snippet:a}", ctx).text, "")
    }

    func testDateCustomFormatWithOffset() {
        // 2023-11-14 22:13:20 UTC; +1d → 2023-11-15.
        let ctx = fixedContext()
        XCTAssertEqual(PlaceholderEngine.render("{date:yyyy-MM-dd}", ctx).text, "2023-11-14")
        XCTAssertEqual(PlaceholderEngine.render("{date:yyyy-MM-dd +1d}", ctx).text, "2023-11-15")
        XCTAssertEqual(PlaceholderEngine.render("{date:yyyy-MM-dd -1w}", ctx).text, "2023-11-07")
    }

    func testTimeCustomFormat() {
        XCTAssertEqual(PlaceholderEngine.render("{time:HH:mm}", fixedContext()).text, "22:13")
    }

    func testCustomTokensExcludesBuiltins() {
        let tokens = PlaceholderEngine.customTokens(in: "{date} {weather} {clipboard} {weather} {git:branch}")
        // Built-ins (date, clipboard) excluded; {weather} de-duped; {git:branch} kept.
        XCTAssertEqual(tokens.map(\.name), ["weather", "git"])
        XCTAssertEqual(tokens.map(\.raw), ["weather", "git:branch"])
    }

    func testCustomResolverReceivesRawAndModifiersApplied() {
        var ctx = PlaceholderContext()
        ctx.custom = { name, raw in name == "git" ? "main(\(raw))" : nil }
        // The handler gets the raw body; the engine applies trailing modifiers once.
        XCTAssertEqual(PlaceholderEngine.render("{git:branch | uppercase}", ctx).text, "MAIN(GIT:BRANCH | UPPERCASE)")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
