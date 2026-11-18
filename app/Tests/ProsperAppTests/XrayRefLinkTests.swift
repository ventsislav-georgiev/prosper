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

    /// Red without the code-span skip in raw text (find).
    func testInsideACodeSpanGivesNone() throws {
        let refs = try F.parsed().entries
        let s = "`#12` and `see #12` but #12"
        let spans = XrayRefSpans.find(s, refs)
        XCTAssertEqual(texts(s, spans), ["#12"])
        XCTAssertEqual(spans.first?.range.lowerBound, s.range(of: "but #12").map { s.index($0.lowerBound, offsetBy: 4) })
    }

    /// #1419 (R1418-i1): find over 2000 underlined refs and a 2 KB clip, as one clip pass draws it, stays under 2 s (the
    /// shortcut note in find: one scan per ref). Written, not measured when it was added: tighten it from a run.
    func testFindOver2000RefsInOneClipStaysUnderTwoSeconds() throws {
        let one = try XCTUnwrap(try F.parsed().entries.first { $0.underline })
        let refs = (0..<2000).map { i -> XrayRefs.Entry in
            var e = one
            (e.key, e.text) = ("issue:#\(10_000 + i)", "#\(10_000 + i)")
            return e
        }
        let text = String(repeating: "Fixed in #10042 and #11999, see the notes; ", count: 48)
        let start = Date()
        let spans = XrayRefSpans.find(text, refs)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(spans.count, 96, "each of the two refs, 48 times")
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
        let s = "Fix #12 now; the login retries in #12 were the cause, see `#12` and https://example.org/acme for more."
        let plain = AttributedString(s)
        let decorated = try XCTUnwrap(F.gateOn { XrayRefSpans.attributed(s, refs: refs, color: .white) })
        let key = try XCTUnwrap(XrayRefLink.url("issue:#12"))
        XCTAssertEqual(F.links(decorated).filter { $0.scheme == "prosper-xray" }, [key, key])
        let underlined = decorated.runs.filter { $0[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] != nil }
        XCTAssertEqual(underlined.count, 2)
        var stripped = decorated.transformingAttributes(\.link) { if $0.value?.scheme == "prosper-xray" { $0.value = nil } }
        stripped[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = nil
        XCTAssertEqual(F.links(stripped), [])
        XCTAssertEqual(stripped, plain, "every other run and attribute as before")
        func size(_ a: AttributedString) -> CGSize {
            NSHostingView(rootView: Text(a).font(Neon.font(12.5)).fixedSize(horizontal: false, vertical: true)
                .frame(width: 220)).fittingSize
        }
        XCTAssertEqual(size(decorated), size(plain))
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

    /// Red if http, https or mailto: stop reaching the system (#1419 R1418-i1), or any other scheme (file:, ssh:, tel:,
    /// script, the app's own), a scheme-less link or a forged one is followed (allowlist). The outcome only: no URL opens.
    func testOnlyHttpHttpsAndMailtoReachTheSystem() throws {
        let refs = try F.parsed()
        var shown = 0
        for s in ["https://example.org/acme/api/pull/7", "http://example.org/acme", "mailto:a@example.org", "MAILTO:a@example.org"] {
            XCTAssertEqual(XrayRefLink.open(try XCTUnwrap(URL(string: s)), refs: refs) { _ in shown += 1 }, .system, s)
        }
        for s in ["file:///Users/example/notes.md", "FILE:///Users/example/x.command", "ssh://example.org", "smb://example.org/share",
                  "x-apple.systempreferences:com.apple.preference.security", "tel:+15550100", "javascript:alert(1)", "data:text/html,x",
                  "prosper://sleep", "PROSPER://sleep", "no-scheme-at-all", "prosper-xray://ref?k=issue%3A%2399"] {
            XCTAssertEqual(XrayRefLink.open(try XCTUnwrap(URL(string: s)), refs: refs) { _ in shown += 1 }, .discarded, s)
        }
        XCTAssertEqual(shown, 0)
    }

    /// #1419: the flip. Red with ships false, or a default that ignores ships: the product draws the links.
    func testGateShipsOnAndTheDefaultFollowsIt() throws {
        let refs = try F.parsed().entries.filter(\.underline)
        XCTAssertTrue(XrayRefLink.ships, "gate B ships on")
        XCTAssertTrue(XrayRefLink.decorate(), "the product default follows ships")
        let a = try XCTUnwrap(XrayRefSpans.attributed("#12 here", refs: refs, color: .white), "no override: linked")
        XCTAssertEqual(F.links(a).count, 1)
    }

    /// #1419: the override keeps the gate-off path covered. Red if gate B off still links: no attributed text, no decoration
    /// seen, no prosper-xray link in the drawn clip.
    func testGateOffMakesNoLink() throws {
        let refs = try F.parsed().entries.filter(\.underline)
        let old = XrayRefLink.decorate
        XrayRefLink.decorate = { false }
        defer { XrayRefLink.decorate = old }
        XCTAssertTrue(XrayRefSpans.attributed("#12 here", refs: refs, color: .white) == nil)
    }

    /// #1419 (R1418-i1): XrayRefLink.panel opens its card on the pane's panel: a new one on the target with the refs and the
    /// Refs tab, and the same one again for the same target; another target gets another. Red if panel never reuses or drops the refs.
    func testPanelMakesOneForTheTargetAndReusesIt() throws {
        let refs = try F.parsed(), pane = UUID(), shared = XrayPanels.shared
        defer { shared.open[pane] = nil }
        let t = XrayRefRunTests.local, m = XrayRefLink.panel(pane, t, refs)
        XCTAssertEqual(m.target, t)
        XCTAssertTrue(m.refs?.entries == refs.entries)
        shared.open[pane] = m
        XCTAssertTrue(XrayRefLink.panel(pane, t, refs) === m, "the open panel on this session")
        XCTAssertTrue(XrayRefLink.panel(pane, XrayTarget(name: "api-qa", dir: t.dir), refs) !== m)
    }
}
