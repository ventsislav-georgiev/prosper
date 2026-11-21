import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1814: the X-ray drawer's prompt and memory cards draw their text with the ref card's renderer (XrayRich): Markdown
/// styled, the drawer's filter highlighted, refs linked; parsed off main once per text. Pure values and never-shown
/// hosting views only: no window ordered front, no event, no pasteboard.
@MainActor
final class XrayRichBlockTests: XCTestCase {
    typealias Run = XrayRich.Run
    func text(_ r: [Run]) -> String { r.map(\.text).joined() }
    func style(_ r: [Run], _ t: String) -> Run.Style? { r.first { $0.text == t }?.style }

    /// A response shaped as the operator's screenshot (op-1121-35): bold labels, nested bullets, a link, a heading, a fence.
    static let doc = """
        I sent it both things.

        **Colour changes:**
        - **Count pills:** no grey fill
          - Agents: royal purple
        See [#1756](https://example.org/issues/1756) and *this*.
        ## Next steps
        ```
        let x = 1
        ```
        Call `run()` now.
        """

    /// Red at the base: the cards drew `Text(verbatim:)` (XrayChapterCard.swift:87 and :119, XrayPanel.swift:1370), so
    /// no runs; red with mutants fence-not-code, heading-not-bold and list-indent-dropped.
    func testADocumentIsStyledWithNoLiteralMarks() {
        let r = XrayRichBlock.runs(Self.doc)
        let t = text(r)
        XCTAssertEqual(t, "I sent it both things.\n\nColour changes:\n\u{2022} Count pills: no grey fill\n  \u{2022} Agents: royal purple\n"
                       + "See #1756 and this.\nNext steps\n\nlet x = 1\n\nCall run() now.")
        for raw in ["**", "```", "](", "## ", "- "] { XCTAssertFalse(t.contains(raw), "no literal \(raw)") }
        XCTAssertEqual(style(r, "Colour changes:"), .bold)
        XCTAssertEqual(style(r, "Count pills:"), .bold)
        XCTAssertEqual(style(r, "#1756"), .link)
        XCTAssertEqual(style(r, "this"), .italic)
        XCTAssertEqual(style(r, "Next steps"), .bold, "a heading is bold")
        XCTAssertEqual(style(r, "let x = 1"), .code, "a fenced line is code")
        XCTAssertEqual(style(r, "run()"), .code)
    }

    /// Red with mutant no-match (the filter not passed to XrayRich.attributed): nothing highlighted.
    func testTheFilterIsHighlightedInline() {
        let r = XrayRichBlock.runs("The **pills** and the Pills row")
        func hits(_ a: AttributedString) -> [String] {
            a.runs.filter { $0.backgroundColor != nil }.map { String(a[$0.range].characters) }
        }
        XCTAssertEqual(hits(XrayRichBlock.attributed(r, size: 11, match: " pills ")), ["pills", "Pills"],
                       "case-insensitive, inside bold too, the filter's spaces trimmed")
        XCTAssertEqual(hits(XrayRichBlock.attributed(r, size: 11)), [], "no filter: no highlight")
    }

    /// Red with mutant strong-dropped: the prompt and the memory title lose their semibold.
    func testStrongDrawsEveryRunSemibold() {
        let a = XrayRichBlock.attributed(XrayRichBlock.runs("Look at the login bug"), size: 12, strong: true)
        XCTAssertFalse(a.runs.isEmpty)
        XCTAssertTrue(a.runs.allSatisfy { $0.font == Neon.font(12, weight: .semibold) })
        let plain = XrayRichBlock.attributed(XrayRichBlock.runs("Look at the login bug"), size: 12)
        XCTAssertTrue(plain.runs.allSatisfy { $0.font == Neon.font(12, weight: .regular) })
    }

    /// Red with mutant refs-not-linked: the chapter card's refs (gate B) stop being links once the response is rich.
    func testRefsStayLinkedInARichResponse() throws {
        let refs = try XrayRefLinkFixture.parsed()
        let r = XrayRichBlock.runs("Fixed in **#12**, see the notes")
        let on = XrayRefLinkFixture.gateOn { XrayRichBlock.attributed(r, size: 11, refs: refs.entries) }
        XCTAssertEqual(XrayRefLinkFixture.links(on).count, 1)
        let old = XrayRefLink.decorate
        XrayRefLink.decorate = { false }
        defer { XrayRefLink.decorate = old }
        XCTAssertEqual(XrayRefLinkFixture.links(XrayRichBlock.attributed(r, size: 11, refs: refs.entries)).count, 0, "gate off")
    }

    /// Performance (operator, binding): one document parse per text, and none of it on main. Red with mutant parse-on-main.
    func testTheParseRunsOffMainOncePerText() async {
        let (docs, main) = (XrayRichBlock.parses, XrayRich.mainParses)
        let r = await XrayRichBlock.parse(Self.doc)
        XCTAssertFalse(r.isEmpty)
        XCTAssertEqual(XrayRichBlock.parses, docs + 1, "one document parse")
        XCTAssertEqual(XrayRich.mainParses, main, "no line parsed on main")
    }

    /// Both cards draw offscreen with Markdown and a filter (a hosting view never put in a window).
    func testTheCardsDrawOffscreen() {
        let m = XrayMemory.Item(id: "m1", title: "Per-switch calls", note: nil, kind: .feedback, kindWord: "feedback",
                                scope: .project, scopeWord: "project", updated: nil, path: "/Users/example/mem/m1.md",
                                session: nil, sessionWord: nil, chapter: nil,
                                body: "Check it.\n\n**Why:** a bug.\n\n**How to apply:** look first.", cut: false)
        var c = TranscriptOutline.Chapter(id: 0, ordinal: 1, title: "Look at the login bug", kind: .prompt, hasError: false)
        c.response = Self.doc
        for (view, size) in [(AnyView(XrayMemoryCard(item: m, readPrompt: nil, match: "why")), XrayMemoryCard.size),
                             (AnyView(XrayChapterCard(chapter: c, match: "login")), XrayChapterCard.size)] {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }
}
