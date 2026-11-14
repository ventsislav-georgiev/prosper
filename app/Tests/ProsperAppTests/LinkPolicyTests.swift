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

    func testASCIILowercasingOnly() {
        XCTAssertEqual(LinkPolicy.asciiLowercased("HTTPS"), "https")
        XCTAssertEqual(LinkPolicy.asciiLowercased("FİLE"), "fİle", "no locale or Unicode folding")
        XCTAssertTrue(LinkPolicy.hasControl("a\u{85}b"), "C1 NEL")
        XCTAssertTrue(LinkPolicy.hasControl("a\u{7F}"))
        XCTAssertFalse(LinkPolicy.hasControl("a é b"))
    }
}
