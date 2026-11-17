import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1418 (#1356 step 4): clickable refs in Transcript mode, gate B. Literal JSON, a fake dch runner, an injected clock,
/// a fake presenter (XrayRefPopoverTests.Cards); views laid out in NSHostingViews that are never in a window. No click,
/// no popover, no URL opened, no dch.
@MainActor
enum XrayRefLinkFixture {
    static let refs = #"""
    [{"key":"issue:#12","shape":"issue","text":"#12","count":2,"title":"Login retries","underline":true},\#
    {"key":"ticket:API-7","shape":"ticket","text":"API-7","count":1,"underline":false},\#
    {"key":"issue:#1","shape":"issue","text":"#1","count":1,"underline":true}]
    """#
    /// The session_id XrayRefsParseTests.object answers with.
    static let sessionID = "0b1f6a52-4c1e-4d7a-9a51-2f6d8c3e7a10"

    static func parsed() throws -> XrayRefs { try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs: refs))) }

    /// Gate B on for `body`, restored after.
    static func gateOn<R>(_ body: () throws -> R) rethrows -> R {
        let old = XrayRefLink.decorate
        XrayRefLink.decorate = { true }
        defer { XrayRefLink.decorate = old }
        return try body()
    }

    static func links(_ a: AttributedString) -> [URL] { a.runs.compactMap(\.link) }
}

@MainActor
final class XrayRefLinkTests: XCTestCase {
    typealias F = XrayRefLinkFixture

    /// Red if url() put the text or title in the link, or key(from:) misread it.
    func testKeyFromAGoodLinkIsTheKey() throws {
        let refs = try F.parsed()
        let url = try XCTUnwrap(XrayRefLink.url("issue:#12"))
        XCTAssertEqual(url.absoluteString, "prosper-xray://ref?k=issue%3A%2312")
        XCTAssertEqual(XrayRefLink.key(from: url, in: refs), "issue:#12")
    }

    /// Each forged link refused. Red with any of key(from:)'s checks removed (scheme, host, one k, the name k, a
    /// non-empty k, the key in the cache).
    func testForgedLinksAreRefused() throws {
        let refs = try F.parsed()
        let forged = [
            "prosper://ref?k=issue%3A%2312",                  // another scheme
            "prosper-xray://card?k=issue%3A%2312",            // another host
            "prosper-xray://ref?k=issue%3A%2312&x=1",         // an extra query item
            "prosper-xray://ref?k=issue%3A%2312&k=issue%3A%2312",   // two k
            "prosper-xray://ref?key=issue%3A%2312",           // not k
            "prosper-xray://ref?k=issue%3A%2399",             // a key not in the cache
            "prosper-xray://ref?k=issue%3A%2312%E2%80%AE",    // a percent-encoded bidi override after a good key
            "prosper-xray://ref?k=",                          // an empty k
        ]
        for s in forged {
            let url = try XCTUnwrap(URL(string: s), s)
            XCTAssertTrue(XrayRefLink.key(from: url, in: refs) == nil, s)
        }
        let good = try XCTUnwrap(XrayRefLink.url("issue:#12"))
        XCTAssertTrue(XrayRefLink.key(from: good, in: nil) == nil, "no cache: nothing is a key")
    }
}

@MainActor
final class XrayRefSpansTests: XCTestCase {
    typealias F = XrayRefLinkFixture

    func texts(_ s: String, _ spans: [XrayRefSpans.Span]) -> [String] { spans.map { String(s[$0.range]) } }

    /// Red if find decorated a ref dch did not mark underline (M4a).
    func testUnderlineFalseOrUnlistedGivesNoSpan() throws {
        let refs = try F.parsed().entries
        XCTAssertEqual(XrayRefSpans.find("see API-7 and #99", refs), [])
        XCTAssertEqual(texts("API-7 and #12", XrayRefSpans.find("API-7 and #12", refs)), ["#12"], "the underlined one only")
    }

    /// Red with an ASCII-only word boundary (M4f): a letter outside ASCII ends no ref.
    func testAUnicodeWordNeighbourGivesNoSpan() throws {
        let refs = try F.parsed().entries
        for s in ["#12\u{E9}", "\u{E9}#12", "#12_x", "#123", "x#12", "#12e\u{301}"] {
            XCTAssertEqual(XrayRefSpans.find(s, refs), [], s)
        }
        XCTAssertEqual(texts("(#12).", XrayRefSpans.find("(#12).", refs)), ["#12"])
        XCTAssertEqual(texts("#1, #12", XrayRefSpans.find("#1, #12", refs)), ["#1", "#12"], "#1 never inside #12")
    }

    /// Red without the code-span skip, in raw text (find) and in Markdown code runs (decorate).
    func testInsideACodeSpanGivesNone() throws {
        let refs = try F.parsed().entries
        let s = "`#12` and `see #12` but #12"
        let spans = XrayRefSpans.find(s, refs)
        XCTAssertEqual(texts(s, spans), ["#12"])
        XCTAssertEqual(spans.first?.range.lowerBound, s.range(of: "but #12").map { s.index($0.lowerBound, offsetBy: 4) })
        var a = try XCTUnwrap(transcriptMarkdown("`#12` then #12"))
        XrayRefSpans.decorate(&a, refs: refs, color: .white)
        XCTAssertEqual(F.links(a).count, 1)
        let code = a.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertTrue(code?.link == nil, "the code run keeps no link")
    }

    /// Red if a tool output, bash or thinking clip is decorated (M4d), or a prose clip is not.
    func testToolOutputGivesNoneProseDoes() throws {
        let refs = try F.parsed().entries.filter(\.underline)
        var drawn: [String] = []
        XrayRefLink.drawn = { drawn.append($0) }
        defer { XrayRefLink.drawn = nil }
        func lay(_ body: BlockBody) {
            let b = TranscriptBlock(id: 1, body: body, tier: .specific, version: "2.1.300", source: nil)
            let h = NSHostingView(rootView: TranscriptBlockView(block: b, expanded: true)
                .environment(\.xrayRefEntries, refs).frame(width: 420))
            _ = h.fittingSize
        }
        F.gateOn {
            lay(.bash(command: "git log #12", description: nil, output: Clip("#12 fixed in bash", cap: 400), isError: false))
            lay(.thinking(Clip("#12 thinking", cap: 400)))
            lay(.compaction(trigger: nil, preTokens: nil, summary: Clip("#12 summary", cap: 400)))
        }
        XCTAssertEqual(drawn, [], "tool output, bash, thinking and summaries are never decorated")
        F.gateOn {
            lay(.user(Clip("#12 user", cap: 400)))
            lay(.assistant(Clip("#12 assistant", cap: 400)))
        }
        XCTAssertEqual(Set(drawn), ["#12 user", "#12 assistant"], "positive control: prose clips are")
    }

    /// Red if a second occurrence is lost.
    func testTwoOccurrencesGiveTwoSpans() throws {
        let refs = try F.parsed().entries
        let spans = XrayRefSpans.find("#12 then #12.", refs)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.map(\.key), ["issue:#12", "issue:#12"])
    }

    /// Spec 5.1, P0 (c): the decorated text keeps every run but the link and the underline, links carry the key only
    /// (M4b), and lays out to the same size.
    func testDecorationKeepsRunsAndRects() throws {
        let refs = try F.parsed().entries.filter(\.underline)
        let s = "Fix **#12** now; the login retries in #12 were the cause, see `#12` and https://example.org/acme for more."
        let plain = try XCTUnwrap(transcriptMarkdown(s))
        let decorated = try XCTUnwrap(F.gateOn { XrayRefSpans.attributed(s, markdown: true, refs: refs, color: .white) })
        let key = try XCTUnwrap(XrayRefLink.url("issue:#12"))
        XCTAssertEqual(F.links(decorated).filter { $0.scheme == "prosper-xray" }, [key, key])
        let underlined = decorated.runs.filter { $0[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] != nil }
        XCTAssertEqual(underlined.count, 2)
        // the https link Markdown made stays; the plain text has no underline of its own
        var stripped = decorated.transformingAttributes(\.link) { if $0.value?.scheme == "prosper-xray" { $0.value = nil } }
        stripped[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = nil
        XCTAssertEqual(F.links(stripped), [try XCTUnwrap(URL(string: "https://example.org/acme"))])
        XCTAssertEqual(stripped, plain, "every other run and attribute as before")
        func size(_ a: AttributedString) -> CGSize {
            NSHostingView(rootView: Text(a).font(Neon.font(12.5)).fixedSize(horizontal: false, vertical: true)
                .frame(width: 220)).fittingSize
        }
        XCTAssertEqual(size(decorated), size(plain))
    }
}

@MainActor
final class XrayRefCacheTests: XCTestCase {
    typealias F = XrayRefLinkFixture
    let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")

    func cache(_ run: XrayRefRunTests.Run, _ clock: @escaping () -> Date, _ focus: @escaping @MainActor () -> XrayRefCache.Focus?) -> XrayRefCache {
        run.answer = (0, XrayRefsParseTests.object(refs: F.refs))
        let c = XrayRefCache()
        (c.dch, c.run, c.now, c.focus) = ({ "/fake/dch" }, run.run, clock, focus)
        return c
    }

    func focus(active: Bool = true, session: String = F.sessionID, mark: Int) -> XrayRefCache.Focus {
        XrayRefCache.Focus(active: active, target: XrayRefRunTests.local, key: key, sessionID: session, mark: mark)
    }

    /// Red if a tick reads while blurred or hidden (M4e) or reads again with no growth.
    func testOneReadOnFocusNoneWhileBlurredOrHidden() async throws {
        let run = XrayRefRunTests.Run()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var f: XrayRefCache.Focus? = focus(active: false, mark: 5)
        let c = cache(run, { clock }, { f })
        for _ in 0..<3 { c.tick() }
        f = nil   // another pane or Terminal mode
        c.tick()
        XCTAssertEqual(run.calls.count, 0, "blurred, hidden or not a Transcript pane: no read")
        f = focus(mark: 5)
        c.tick()
        await c.reading?.value
        XCTAssertEqual(run.calls, [["--xray", "api", "--json"]])
        XCTAssertEqual(c.refs(key, sessionID: F.sessionID)?.entries.count, 3)
        clock += 60
        c.tick()
        XCTAssertEqual(run.calls.count, 1, "no growth: no read")
        f = focus(active: false, mark: 9)
        c.tick()
        XCTAssertEqual(run.calls.count, 1, "grown and 60 s on, but blurred: no read")
    }

    /// Red if a growth inside 30 s, or 30 s without growth, reads again.
    func testRereadOnlyAfterGrowthAnd30s() async throws {
        let run = XrayRefRunTests.Run()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var f: XrayRefCache.Focus? = focus(mark: 5)
        let c = cache(run, { clock }, { f })
        c.tick()
        await c.reading?.value
        f = focus(mark: 6)
        clock += 29
        c.tick()
        XCTAssertEqual(run.calls.count, 1, "grown, 29 s: no read")
        f = focus(mark: 5)
        clock += 1
        c.tick()
        XCTAssertEqual(run.calls.count, 1, "30 s, not grown: no read")
        f = focus(mark: 6)
        c.tick()
        await c.reading?.value
        XCTAssertEqual(run.calls.count, 2, "grown and 30 s: one read")
    }

    /// Red if another session_id (a /clear or resume) keeps the old refs.
    func testASessionIDChangeDropsTheEntry() async throws {
        let run = XrayRefRunTests.Run()
        let clock = Date(timeIntervalSince1970: 1_000_000)
        var f: XrayRefCache.Focus? = focus(mark: 5)
        let c = cache(run, { clock }, { f })
        c.tick()
        await c.reading?.value
        XCTAssertNotNil(c.refs(key, sessionID: F.sessionID))
        f = focus(session: "1c2d3e4f-0000-4000-8000-000000000002", mark: 5)
        c.tick()
        XCTAssertTrue(c.entries[key]?.sessionID == nil, "dropped at once")
        XCTAssertTrue(c.refs(key, sessionID: F.sessionID) == nil)
        await c.reading?.value
        XCTAssertEqual(run.calls.count, 2, "the new conversation is read")
        XCTAssertEqual(c.entries[key]?.sessionID, "1c2d3e4f-0000-4000-8000-000000000002")
        XCTAssertTrue(c.refs(key, sessionID: "1c2d3e4f-0000-4000-8000-000000000002") == nil,
                      "dch answered for the old conversation: nothing drawn")
    }

    /// Red if the window's close leaves the cache or its entries.
    func testWindowCloseEmptiesTheCache() async throws {
        let run = XrayRefRunTests.Run()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let f = focus(mark: 5)
        let c = XrayRefCache.of(w) { f }
        (c.dch, c.run) = ({ "/fake/dch" }, run.run)
        run.answer = (0, XrayRefsParseTests.object(refs: F.refs))
        c.tick()
        await c.reading?.value
        XCTAssertEqual(c.entries.count, 1)
        XCTAssertTrue(XrayRefCache.of(w) { nil } === c, "one cache per window")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: w)   // never shown: no close runs
        let end = Date().addingTimeInterval(2)
        while !c.entries.isEmpty, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(c.entries.count, 0)
        let next = XrayRefCache.of(w) { nil }
        XCTAssertFalse(next === c, "a closed window's cache is gone")
        next.clear()
    }
}

@MainActor
final class XrayRefOpenTests: XCTestCase {
    typealias F = XrayRefLinkFixture

    /// Red if a prosper-xray link does not reach the card, or reaches it twice.
    func testAProsperXrayLinkPresentsOnce() async throws {
        let refs = try F.parsed()
        let run = XrayRefRunTests.Run()
        let cards = XrayRefPopoverTests.Cards()
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
        (p.dch, p.run, p.refs, p.panels) = ("/fake/dch", run.run, refs, XrayPanels())
        p.presentRef = { cards.present($0, $1, $2) }
        p.dismiss = { cards.close() }
        let url = try XCTUnwrap(XrayRefLink.url("issue:#12"))
        XCTAssertEqual(XrayRefLink.open(url, refs: refs) { p.openRef($0) }, .handled)
        XCTAssertEqual(cards.views.count, 1)
        XCTAssertEqual(cards.sizes.first, XrayRefPopover.size)
        XCTAssertEqual(p.refCard?.key, "issue:#12")
        cards.close()
        await p.panels?.refReading?.value
    }

    /// Red if http/https leave today's opener, or another scheme or a forged link is followed.
    func testHttpsIsTheSystemsOtherSchemesAreDiscarded() throws {
        let refs = try F.parsed()
        var shown = 0
        for s in ["https://example.org/acme/api/pull/7", "http://example.org/acme"] {
            XCTAssertEqual(XrayRefLink.open(try XCTUnwrap(URL(string: s)), refs: refs) { _ in shown += 1 }, .system, s)
        }
        for s in ["javascript:alert(1)", "file:///Users/example/notes.md", "mailto:a@example.org", "prosper://sleep",
                  "prosper-xray://ref?k=issue%3A%2399"] {
            XCTAssertEqual(XrayRefLink.open(try XCTUnwrap(URL(string: s)), refs: refs) { _ in shown += 1 }, .discarded, s)
        }
        XCTAssertEqual(shown, 0)
    }

    /// Red if gate B off still links: no attributed text, no decoration seen, no prosper-xray link in the drawn clip.
    func testGateOffMakesNoLink() throws {
        let refs = try F.parsed().entries.filter(\.underline)
        XCTAssertFalse(XrayRefLink.ships, "gate B ships off until the click check")
        let old = XrayRefLink.decorate
        XrayRefLink.decorate = { false }
        defer { XrayRefLink.decorate = old }
        XCTAssertTrue(XrayRefSpans.attributed("#12 here", markdown: true, refs: refs, color: .white) == nil)
        var drawn = 0
        XrayRefLink.drawn = { _ in drawn += 1 }
        defer { XrayRefLink.drawn = nil }
        let b = TranscriptBlock(id: 1, body: .user(Clip("#12 here", cap: 400)), tier: .specific, version: "2.1.300", source: nil)
        _ = NSHostingView(rootView: TranscriptBlockView(block: b).environment(\.xrayRefEntries, refs).frame(width: 420)).fittingSize
        XCTAssertEqual(drawn, 0)
    }
}
