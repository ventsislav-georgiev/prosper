import AppKit
import XCTest
@testable import ProsperApp

/// #1118 (design #1105 D6, section 3 N3, rider R4): the action for each literal link target. Pure:
/// nothing is opened, stat'ed or read. The paths are fakes under /Users/example.
final class LinkPolicyTests: XCTestCase {

    private let document = URL(fileURLWithPath: "/Users/example/docs/README.md")

    private func describe(_ a: LinkPolicy.Action) -> String {
        switch a {
        case .open(let u): "open \(u.absoluteString)"
        case .view(let u): "view \(u.path)"
        case .reveal(let u): "reveal \(u.path)"
        case .scroll(let s): "scroll \(s)"
        case .none: "none"
        }
    }

    func testEveryTargetHasItsStatedAction() throws {
        let expected: [(String, String)] = [
            // Every other scheme is plain text, whatever its case.
            ("javascript:alert(1)", "none"),
            ("JavaScript:alert(1)", "none"),
            ("data:text/html,x", "none"),
            ("prosper://sleep", "none"),
            ("vbscript:msgbox(1)", "none"),
            ("ssh://h", "none"),
            ("smb://h/s", "none"),
            ("afp://h/x", "none"),
            ("ftp://h/x", "none"),
            ("x-foo:bar", "none"),
            // A host where there should be none, a control character, an encoded slash.
            ("https:", "none"),
            ("file://server/share/a.md", "none"),
            ("//example.com/x", "none"),
            ("a%2Fb.md", "none"),
            ("a%2fb.md", "none"),
            ("a%09b.md", "none"),
            ("https://example.com/%0Aspoof", "none"),
            // Round 2: "%FF" fails decoding the whole link; URL.path is then "" (fact, macOS 27), refused.
            ("a%FF%0Ab.md", "none"),
            ("a%00b.md", "none"),
            ("%FF.md", "none"),
            // On a click only: the browser or the mail app.
            ("https://example.com", "open https://example.com"),
            ("HTTPS://example.com", "open HTTPS://example.com"),
            ("http://example.com/a?b=c", "open http://example.com/a?b=c"),
            ("mailto:a@example.com", "open mailto:a@example.com"),
            // R4: a text document, a script included, is viewed in Read mode and never run.
            ("other.md", "view /Users/example/docs/other.md"),
            ("Notes.MD", "view /Users/example/docs/Notes.MD"),
            ("../up.md", "view /Users/example/up.md"),
            ("run.sh", "view /Users/example/docs/run.sh"),
            ("run.command", "view /Users/example/docs/run.command"),
            ("file:///Users/example/docs/notes.txt", "view /Users/example/docs/notes.txt"),
            // Anything else local is revealed, never opened.
            ("file:///Applications/Calculator.app", "reveal /Applications/Calculator.app"),
            ("docs/", "reveal /Users/example/docs/docs"),
            ("/etc/passwd", "reveal /etc/passwd"),
            ("LICENSE", "reveal /Users/example/docs/LICENSE"),
            ("img.png", "reveal /Users/example/docs/img.png"),
            ("page.html", "reveal /Users/example/docs/page.html"),
            // A fragment scrolls.
            ("#install", "scroll install"),
            ("#Install", "scroll install"),
        ]
        var got: Set<String> = []
        for (target, _) in expected {
            let url = try XCTUnwrap(URL(string: target), target)
            got.insert("\(target) => \(describe(LinkPolicy.action(url, document: document)))")
        }
        XCTAssertEqual(got, Set(expected.map { "\($0.0) => \($0.1)" }))
        XCTAssertEqual(got.count, expected.count)
    }

    /// Round 2 item 4, the facts: what URL gives for a link whose percent-decoding fails.
    func testPercentFacts() throws {
        for raw in ["a%FF%0Ab.md", "%FF", "%FF.md", "a%00b.md"] {
            let url = try XCTUnwrap(URL(string: raw), raw)
            let path = url.path
            fputs("tv1b fact URL(string: \"\(raw)\").path = \(path.debugDescription) \(Array(path.utf8)); removingPercentEncoding = \(raw.removingPercentEncoding.debugDescription)\n", stderr)
        }
    }

    /// R886-6: a bidirectional control in a link refuses it (plain text: no link, no tooltip), raw or
    /// percent-encoded, in any scheme the policy acts on; its neighbours do not. A literal table: the scalar,
    /// its UTF-8 percent form, whether it is refused.
    func testBidiControlsRefused() throws {
        let table: [(String, String, Bool)] = [
            ("\u{202A}", "%E2%80%AA", true), ("\u{202B}", "%E2%80%AB", true), ("\u{202C}", "%E2%80%AC", true),
            ("\u{202D}", "%E2%80%AD", true), ("\u{202E}", "%E2%80%AE", true),
            ("\u{2066}", "%E2%81%A6", true), ("\u{2067}", "%E2%81%A7", true), ("\u{2068}", "%E2%81%A8", true),
            ("\u{2069}", "%E2%81%A9", true),
            ("\u{200E}", "%E2%80%8E", true), ("\u{200F}", "%E2%80%8F", true), ("\u{061C}", "%D8%9C", true),
            // Neighbours that stay: ZWJ (emoji names), hyphen, narrow no-break space (screenshot names),
            // the Arabic semicolon and U+061D, superscript zero.
            ("\u{200D}", "%E2%80%8D", false), ("\u{2010}", "%E2%80%90", false), ("\u{202F}", "%E2%80%AF", false),
            ("\u{061B}", "%D8%9B", false), ("\u{061D}", "%D8%9D", false), ("\u{2070}", "%E2%81%B0", false),
        ]
        XCTAssertEqual(table.count, 18)
        XCTAssertEqual(Set(table.filter(\.2).map { $0.0.unicodeScalars.first?.value ?? 0 }), LinkPolicy.bidiControls)
        var got: [String] = []
        for (scalar, encoded, refused) in table {
            XCTAssertEqual(encoded.removingPercentEncoding, scalar, encoded)
            XCTAssertEqual(LinkPolicy.hasControl("a" + scalar + "b"), refused, encoded)
            let name = "a" + encoded + "b.md"
            for (link, shown) in [(name, "view /Users/example/docs/a\(scalar)b.md"),
                                  ("file:///Users/example/docs/" + name, "view /Users/example/docs/a\(scalar)b.md"),
                                  ("a" + encoded + "b", "reveal /Users/example/docs/a\(scalar)b"),
                                  ("https://example.com/" + name, "open https://example.com/" + name)] {
                let url = try XCTUnwrap(URL(string: link), link)
                got.append("\(link) => \(describe(LinkPolicy.action(url, document: document)))")
                XCTAssertEqual(got.last, "\(link) => \(refused ? "none" : shown)")
            }
            // The raw scalar, as Foundation takes it (it may percent-encode it first).
            if let raw = URL(string: "a" + scalar + "b.md") {
                XCTAssertEqual(LinkPolicy.action(raw, document: document) == .none, refused, encoded)
            }
        }
        XCTAssertEqual(got.count, table.count * 4)
    }

    /// R886-6 at the tooltip: a refused link gets no link and no tooltip in the rendered text; its
    /// neighbour keeps both. The loader is a fake that draws nothing; nothing is read.
    func testBidiNameHasNoTooltip() {
        let c = MarkdownRenderer.Style.RGBA.self
        let style = MarkdownRenderer.Style(scale: 1, text: c.init(r: 0, g: 0, b: 0, a: 1), secondary: c.init(r: 0.5, g: 0.5, b: 0.5, a: 1),
                                           accent: c.init(r: 0, g: 0, b: 1, a: 1), card: c.init(r: 0.9, g: 0.9, b: 0.9, a: 1),
                                           stroke: c.init(r: 0.8, g: 0.8, b: 0.8, a: 1))
        let out = MarkdownRenderer.render("[rlo](a%E2%80%AEgpj.md) [zwj](a%E2%80%8Db.md)\n", document: document, style: style,
                                          loader: { _, _, _ in nil })
        var tips: [String: String] = [:]
        out.text.enumerateAttribute(.toolTip, in: NSRange(location: 0, length: out.text.length)) { value, range, _ in
            if let tip = value as? String { tips[(out.text.string as NSString).substring(with: range)] = tip }
        }
        XCTAssertEqual(tips, ["zwj": "/Users/example/docs/a\u{200D}b.md"])
        XCTAssertTrue(out.text.string.contains("rlo zwj"), "the refused link stays as its text")
    }

    func testASCIILowercasingOnly() {
        XCTAssertEqual(LinkPolicy.asciiLowercased("HTTPS"), "https")
        XCTAssertEqual(LinkPolicy.asciiLowercased("FİLE"), "fİle", "no locale or Unicode folding")
        XCTAssertTrue(LinkPolicy.hasControl("a\u{85}b"), "C1 NEL")
        XCTAssertTrue(LinkPolicy.hasControl("a\u{7F}"))
        XCTAssertFalse(LinkPolicy.hasControl("a é b"))
    }
}
