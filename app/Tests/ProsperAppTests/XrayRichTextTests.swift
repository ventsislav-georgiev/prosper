import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1760: the ref card's snippets as Markdown runs (parsed once, cleaned after the parse), the inline filter, Mentions
/// first. Pure values and never-shown views only: no window ordered front, no event, no pasteboard.
@MainActor
final class XrayRichTextTests: XCTestCase {
    typealias Run = XrayRich.Run
    func text(_ r: [Run]) -> String { r.map(\.text).joined() }
    func style(_ r: [Run], _ t: String) -> Run.Style? { r.first { $0.text == t }?.style }

    /// Red while the card drew `Text(verbatim: s.before)` (XrayRefPopover.swift:327 at the base): the marks showed raw.
    func testMarkdownRunsAreStyledWithNoLiteralMarks() {
        let r = XrayRich.runs("You **Unthreaded hold:** `decideUnthreadedScope` in [docs](https://example.org) ~~old~~ *it*", max: 400)
        XCTAssertEqual(text(r), "You Unthreaded hold: decideUnthreadedScope in docs old it")
        XCTAssertFalse(text(r).contains("**") || text(r).contains("`"), "no literal ** or backtick")
        XCTAssertEqual(style(r, "Unthreaded hold:"), .bold)
        XCTAssertEqual(style(r, "decideUnthreadedScope"), .code)
        XCTAssertEqual(style(r, "docs"), .link)
        XCTAssertEqual(style(r, "old"), .strike)
        XCTAssertEqual(style(r, "it"), .italic)
    }

    /// Red without untag: "<summary>" showed raw (the operator's screenshot).
    func testTranscriptTagsAreDroppedOrStyled() {
        XCTAssertEqual(text(XrayRich.runs(#"<summary>Monitor "PR #23997" script failed (exit 3)</summary>"#, max: 400)),
                       #"Monitor "PR #23997" script failed (exit 3)"#)
        let b = XrayRich.runs("<details><b>bold</b> and <code>x()</code></details>", max: 400)
        XCTAssertEqual(text(b), "bold and x()")
        XCTAssertEqual(style(b, "bold"), .bold)
        XCTAssertEqual(style(b, "x()"), .code)
        XCTAssertEqual(text(XrayRich.runs("a < b and c>d", max: 400)), "a < b and c>d", "a < that opens no tag stays")
        XCTAssertEqual(text(XrayRich.runs("`<div>` stays code", max: 400)), "<div> stays code", "inside code a tag is code")
    }

    /// Red if the runs were not cleaned after the parse: an entity or a Markdown wrap must not bring back what
    /// OutsideText drops (bidi, controls), and marks joined across a run stay capped at three.
    func testOutsideTextRunsAfterTheParse() {
        XCTAssertEqual(text(XrayRich.runs("**a\u{202E}b**", max: 400)), "ab")
        XCTAssertEqual(text(XrayRich.runs("**x&#x202E;y&#x200B;z**", max: 400)), "xyz", "a decoded entity is cleaned")
        let marks = text(XrayRich.runs("a\u{301}\u{301}\u{301}**\u{301}\u{301}\u{301}**", max: 400))
        XCTAssertEqual(marks.unicodeScalars.count, 4, "one base, three marks across the join")
        XCTAssertEqual(text(XrayRich.runs(String(repeating: "x", count: 50), max: 10)).count, 10, "cut at max")
    }

    /// Red without the hit marks: a ref wrapped in Markdown lost its highlight (or the marks showed).
    func testRefStaysHighlightedInsideMarkdown() {
        let r = XrayRich.runs(before: "Fix **", hit: "#12", after: "** now", max: 400)
        XCTAssertEqual(text(r), "Fix #12 now")
        XCTAssertEqual(style(r, "#12"), [.bold, .hit])
        let s = XrayRefStreamTests.parse([XrayRefStreamTests.first,
                                          XrayRefTurnTests.mention(offset: 0, sentence: "Fix **#12** now", span: [6, 9])])
        XCTAssertEqual(s.mentions.first.map { style($0.rich, "#12") }, [.bold, .hit])
        XCTAssertEqual(s.mentions.first?.fold, "fix #12 now")
    }

    func testBlockMarkdownIsOneCompactLineEach() {
        XCTAssertEqual(text(XrayRich.runs("## Heading", max: 400)), "Heading")
        XCTAssertEqual(text(XrayRich.runs("- item", max: 400)), "\u{2022} item")
        XCTAssertEqual(text(XrayRich.runs("> quoted", max: 400)), "quoted")
        XCTAssertEqual(text(XrayRich.runs("```swift\nlet a = 1\n```", max: 400)), "let a = 1")
    }

    /// Work count (not time): one parse per snippet when the data lands; drawing and filtering parse nothing.
    func testParsedOncePerSnippetNeverPerDraw() {
        let lines = [XrayRefStreamTests.first] + (0..<5).map { XrayRefTurnTests.mention(turn: 2, offset: $0, sentence: "**Work** on #12", span: [12, 15]) }
        let before = XrayRich.parses
        let s = XrayRefStreamTests.parse(lines)
        XCTAssertEqual(XrayRich.parses - before, 5)
        let c = XrayRefContext(s, ref: "#12", tasks: nil, memory: nil)
        let mid = XrayRich.parses
        for q in ["", "w", "wo", "work"] {
            _ = XrayRefPopover.filtered(c.turns ?? [], q)
            _ = s.mentions.map { XrayRich.attributed($0.rich, size: 12, match: q) }
        }
        XCTAssertEqual(XrayRich.parses, mid, "no parse per keystroke or per draw")
    }

    /// Red with the cache-hit path parsing in takeRef: a cache-hit open adds no XrayRich parse on the main thread.
    func testACacheHitOpenParsesNothingOnMain() async throws {
        let t = XrayRefPopoverTests()
        let run = XrayRefRunTests.Run(), cards = XrayRefPopoverTests.Cards(), panels = XrayPanels()
        let p = t.panel(run, cards, panels)
        let cache = XrayRefResults()
        p.refResults = { cache }
        let data = Data([XrayRefStreamTests.first, XrayRefTurnTests.mention(turn: 2, offset: 0, sentence: "**Work** on #12", span: [12, 15]),
                         XrayRefStreamTests.done].joined(separator: "\n").utf8)
        let parsed = await Task.detached { XrayRefStream.parse(data) }.value
        cache.put(XrayRefResults.Key(target: p.target, ref: "#12", light: false, scope: "project"), data, parsed: parsed)
        let main = XrayRich.mainParses
        p.openRef(try t.entry("#12"))
        XCTAssertEqual(p.refContext?.groups.first?.mentions.first?.fold, "work on #12", "the hit served the parsed stream")
        let titles = (p.refContext?.taskRich.count ?? 0) + (p.refContext?.memoryRich.count ?? 0)
        XCTAssertEqual(XrayRich.mainParses - main, titles, "no mention parsed on main (the capped task and memory titles only)")
        XCTAssertLessThanOrEqual(titles, 2 * XrayRefContext.richCap)
        XCTAssertEqual(run.calls.count, 0, "no read ran")
    }

    // MARK: the card

    func context() -> (XrayPanelModel, XrayRefContext) {
        let T = XrayRefStreamTests.self
        let s = T.parse([T.first,
                         XrayRefTurnTests.mention(turn: 3, offset: 1, sentence: "Fix **login** for #12", span: [18, 21]),
                         XrayRefTurnTests.mention(turn: 2, offset: 0, sentence: "Deploy #12 tonight", span: [7, 10], who: "assistant"),
                         T.done])
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
        let c = XrayRefContext(s, ref: "#12", tasks: nil, memory: nil)
        p.refContext = c
        return (p, c)
    }

    /// Red without the filter (no count of matches) or with a filter on the raw line (** would match).
    func testFilterNarrowsTheTabAndCountsMatches() {
        let (p, c) = context()
        XCTAssertEqual(XrayRefPopover.count(.mentions, p), 2)
        XCTAssertEqual(XrayRefPopover.count(.mentions, p, XrayRefPopover.query(" LOGIN ")), 1, "case-insensitive, on the snippet")
        XCTAssertEqual(XrayRefPopover.title(.mentions, p, "login"), "Mentions 1/2")
        XCTAssertEqual(XrayRefPopover.count(.mentions, p, "reply"), 1, "the speaker matches")
        XCTAssertEqual(XrayRefPopover.count(.mentions, p, "api"), 2, "the session matches")
        XCTAssertEqual(XrayRefPopover.count(.mentions, p, "**"), 0, "the Markdown marks are not in the text")
        XCTAssertEqual(XrayRefPopover.filtered(c.turns ?? [], "deploy").flatMap(\.mentions).count, 1)
        let hl = XrayRich.attributed(c.turns?.first?.mentions.first?.rich ?? [], size: 12, match: "login")
        XCTAssertTrue(hl.runs.contains { String(hl[$0.range].characters) == "login" && $0.backgroundColor != nil }, "the match is highlighted")
    }

    /// Red with the old escape (dismiss at once): Esc clears a filter first, a second Esc closes.
    func testEscapeClearsTheFilterThenCloses() {
        var f = "log", closes = 0
        XrayRefPopover.escape(&f) { closes += 1 }
        XCTAssertEqual(f, "")
        XCTAssertEqual(closes, 0, "the card stays open")
        XrayRefPopover.escape(&f) { closes += 1 }
        XCTAssertEqual(closes, 1)
    }

    /// Typing filters in the card: nothing closes it and the old Search path (searchRef) is never taken.
    func testTypingNeverClosesTheCardOrSearches() async throws {
        let run = XrayRefRunTests.Run(), cards = XrayRefPopoverTests.Cards(), panels = XrayPanels()
        let t = XrayRefPopoverTests()
        let p = t.panel(run, cards, panels)
        p.searchable = true
        p.openRef(try t.entry("#12"))
        await panels.refReading?.value
        for typed in ["#", "#1", "#12", "#1", ""] { _ = XrayRefPopover.count(.mentions, p, XrayRefPopover.query(typed)) }
        XCTAssertEqual(cards.closes, 0, "the card is still open")
        XCTAssertEqual(p.tab, .refs, "never moved to Search")
        XCTAssertEqual(p.query, "")
    }

    /// Red with the old order or default (.definition).
    func testMentionsIsTheFirstAndDefaultTab() throws {
        let (p, _) = context()
        XCTAssertEqual(XrayRefPopover.Tab.allCases.first, .mentions)
        XCTAssertEqual(XrayRefPopover.Tab.allCases, [.mentions, .definition, .tasks, .memory])
        let e = try XrayRefPopoverTests().entry("#12")
        XCTAssertEqual(XrayRefPopover(panel: p, entry: e, complete: true).tab, .mentions)
        XCTAssertEqual(XrayRefPopover(panel: p, entry: e, complete: true, tab: .memory).tab, .memory, "an opener's tab is honoured")
        XCTAssertTrue(XrayRefPopover.selectable, "the snippet text is selectable (Command-C copies its plain text)")
    }
}
