import XCTest
@testable import ProsperApp

/// Covers the pure expansion planner `SnippetExpander.plan` — backspace counts,
/// `{cursor}` left-arrow math, word-boundary delimiter re-append, rich routing,
/// and the `{argument}` fill-in request (#842; the flow itself is SnippetFillInTests).
final class SnippetExpanderTests: XCTestCase {

    private func lookup(_ hits: [SnippetHit]) -> (String) -> SnippetHit? {
        { name in hits.first { $0.name == name } }
    }

    func testNoMatch() {
        let d = SnippetExpander.plan(
            buffer: "nothing", keywords: [(";;a", "A")],
            lookup: lookup([]), context: PlaceholderContext(), wordBoundaryMode: false)
        XCTAssertEqual(d, .none)
    }

    func testPlainExpansionBackspacesKeyword() {
        let hit = SnippetHit(name: "A", keyword: "a", text: "Hello")
        let d = SnippetExpander.plan(
            buffer: "x;;a", keywords: [(";;a", "A")],
            lookup: lookup([hit]), context: PlaceholderContext(), wordBoundaryMode: false)
        // ";;a" is 3 chars; the final 'a' is swallowed in-flight → backspace 2.
        XCTAssertEqual(d, .insertPlain(name: "A", backspaces: 2, insertText: "Hello", leftArrows: 0))
    }

    func testCursorProducesLeftArrows() {
        let hit = SnippetHit(name: "A", keyword: ";c", text: "ab{cursor}cd")
        let d = SnippetExpander.plan(
            buffer: ";c", keywords: [(";c", "A")],
            lookup: lookup([hit]), context: PlaceholderContext(), wordBoundaryMode: false)
        // ";c" is 2 chars; final 'c' swallowed → backspace 1. insertText "abcd"
        // (4 chars), cursor at offset 2 → 2 left arrows.
        XCTAssertEqual(d, .insertPlain(name: "A", backspaces: 1, insertText: "abcd", leftArrows: 2))
    }

    func testWordBoundaryReappendsDelimiterAndBackspacesIt() {
        let hit = SnippetHit(name: "S", keyword: "sig", text: "Signed")
        let d = SnippetExpander.plan(
            buffer: "sig ", keywords: [("sig", "S")],
            lookup: lookup([hit]), context: PlaceholderContext(), wordBoundaryMode: true)
        // The delimiter (final key) is swallowed in-flight, so only the keyword(3)
        // is in the field → backspace 3; the delimiter is re-appended after the text.
        XCTAssertEqual(d, .insertPlain(name: "S", backspaces: 3, insertText: "Signed ", leftArrows: 0))
    }

    func testRichRoutesToInsertRich() {
        let hit = SnippetHit(name: "R", keyword: ";r", text: "{rtf}", richText: true)
        let d = SnippetExpander.plan(
            buffer: ";r", keywords: [(";r", "R")],
            lookup: lookup([hit]), context: PlaceholderContext(), wordBoundaryMode: false)
        XCTAssertEqual(d, .insertRich(name: "R", backspaces: 1))
    }

    func testRequiredArgumentAsksForIt() {
        let hit = SnippetHit(name: "A", keyword: ";a", text: "Hi {argument}")
        let d = SnippetExpander.plan(
            buffer: ";a", keywords: [(";a", "A")],
            lookup: lookup([hit]), context: PlaceholderContext(), wordBoundaryMode: false)
        // #842: the trigger 'a' goes through to the field, so the whole keyword (2) is erased on submit.
        XCTAssertEqual(d, .needsArguments(name: "A", backspaces: 2, delimiter: ""))
    }

    func testSatisfiedArgumentExpands() {
        let hit = SnippetHit(name: "A", keyword: ";a", text: "Hi {argument}")
        var ctx = PlaceholderContext()
        ctx.arguments = ["argument": "there"]
        let d = SnippetExpander.plan(
            buffer: ";a", keywords: [(";a", "A")],
            lookup: lookup([hit]), context: ctx, wordBoundaryMode: false)
        XCTAssertEqual(d, .insertPlain(name: "A", backspaces: 1, insertText: "Hi there", leftArrows: 0))
    }

    func testDefaultedArgumentAsksToo() {
        // #842: a default prefills the field; it still asks (TextExpander fill-in parity).
        let hit = SnippetHit(name: "A", keyword: ";a", text: "Hi {argument default=\"x\"}")
        let d = SnippetExpander.plan(
            buffer: ";a", keywords: [(";a", "A")],
            lookup: lookup([hit]), context: PlaceholderContext(), wordBoundaryMode: false)
        XCTAssertEqual(d, .needsArguments(name: "A", backspaces: 2, delimiter: ""))
    }
}
