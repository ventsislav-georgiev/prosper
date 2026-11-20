import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #938: the Sidekick pattern is an ICU regex (AgentIsland.sidekickRegex: NSRegularExpression, case-insensitive, LF-only lines).
/// The pure decision and the escape on literal tables, the escape through the product's own split, the Settings row offscreen
/// at three UI scales on the accessibility tree of a never-shown window. Preferences are the XCTest scratch suite only
/// (saved and restored per test); nothing spawns, nothing is clicked, no event is posted.
final class SidekickPatternHintTests: XCTestCase {
    private static let patternKey = "agentIslandSidekickPattern", tabsKey = "agentIslandSidekickTabs"

    @MainActor
    private func withSavedKeys(_ body: () throws -> Void) rethrows {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let saved = [Self.patternKey, Self.tabsKey].map { ($0, Preferences.defaults.object(forKey: $0)) }
        defer { for (k, v) in saved { Preferences.defaults.set(v, forKey: k) } }
        try body()
    }

    // MARK: The decision

    func testDecisionTable() {
        typealias H = AgentIsland.SidekickHint
        let rows: [(pattern: String, hint: H, text: String?, why: String)] = [
            ("-qa", .plain, nil, "plain text with a hyphen"),
            ("-", .plain, nil, "a hyphen alone is no syntax"),
            ("reviewer", .plain, nil, "plain text"),
            ("", .plain, nil, "empty"),
            ("   ", .plain, nil, "blanks only"),
            ("a.b", .regex(first: "."), "Read as a regex: . matches any character", "a dot"),
            ("-(qa|reviewer)$", .regex(first: "("), "Read as a regex: ( groups part of it", "a group: the FIRST syntax character"),
            ("[xy]", .regex(first: "["), "Read as a regex: [ picks one of a set", "a bracket set"),
            ("c++", .regex(first: "+"), "Read as a regex: + repeats the one before", "c++ is a valid possessive quantifier for ICU"),
            ("qa?", .regex(first: "?"), "Read as a regex: ? may skip the one before", "a question mark"),
            ("^qa", .regex(first: "^"), "Read as a regex: ^ means start of the text", "an anchor"),
            ("a|b", .regex(first: "|"), "Read as a regex: | means either side", "an alternation"),
            ("a{2}", .regex(first: "{"), "Read as a regex: { sets a repeat count", "a repeat count"),
            ("a\\d", .regex(first: "\\"), "Read as a regex: \\ starts a special code", "a backslash code that is not an escaped syntax character"),
            ("  a.b  ", .regex(first: "."), "Read as a regex: . matches any character", "trimmed as the matcher trims"),
            ("x(", .invalid, nil, "an open group is not a valid pattern: matched as text"),
            ("[abc", .invalid, nil, "an open set is not valid"),
            ("a\\.b", .exact, nil, "the escaped form of a.b"),
            ("c\\+\\+", .exact, nil, "the escaped form of c++"),
            ("\\(x\\)", .exact, nil, "the escaped form of (x)"),
            ("a\\\\b", .exact, nil, "the escaped form of a backslash"),
        ]
        for r in rows {
            let h = AgentIsland.sidekickHint(r.pattern)
            XCTAssertEqual(h, r.hint, r.why)
            XCTAssertEqual(h.text, r.text, r.why)
        }
    }

    func testLengthBoundIsTheDchLineBoundAndNothingIsDoneBeyondIt() {
        let bound = DchConfigWriter.maxPatternBytes
        XCTAssertEqual(bound, 255)
        let at = String(repeating: "a", count: bound - 1) + ".", over = String(repeating: "a", count: bound) + "."
        XCTAssertEqual(at.utf8.count, bound)
        XCTAssertEqual(AgentIsland.sidekickHint(at), .regex(first: "."), "at the bound")
        XCTAssertEqual(AgentIsland.sidekickHint(over), .tooLong, "one byte over")
        XCTAssertNil(AgentIsland.sidekickHint(over).text)
        // Two-byte scalars count as bytes: 128 of them are 256 bytes.
        XCTAssertEqual(AgentIsland.sidekickHint(String(repeating: "\u{00E9}", count: 128)), .tooLong)
        XCTAssertEqual(AgentIsland.sidekickMatchExactly(over), over, "no button action on outside data past the bound")
    }

    // MARK: The escape

    func testEscapeTable() {
        let rows: [(text: String, escaped: String)] = [
            ("abc", "abc"), ("-qa", "-qa"), ("a b", "a b"),
            ("\\", "\\\\"), ("^", "\\^"), ("$", "\\$"), (".", "\\."), ("|", "\\|"), ("?", "\\?"), ("*", "\\*"), ("+", "\\+"),
            ("(", "\\("), (")", "\\)"), ("[", "\\["), ("]", "\\]"), ("{", "\\{"), ("}", "\\}"),
            ("c++", "c\\+\\+"), ("a.b", "a\\.b"),
        ]
        for r in rows { XCTAssertEqual(AgentIsland.sidekickEscaped(r.text), r.escaped, r.text) }
        XCTAssertEqual(AgentIsland.sidekickSyntax.map { String($0.char) }.sorted(), "\\^$.|?*+()[]{}".map(String.init).sorted(),
                       "the table is the engine's syntax set: dch's portable() lists the same")
    }

    /// For each syntax character: the escaped pattern is a valid regex that finds the original text and no other name, through
    /// the same split the island and Settings use; and what the button leaves is read as exact text.
    func testEscapeRoundTripThroughTheProductMatcher() {
        func session(_ name: String) -> AgentSession {
            AgentSession(key: AgentSessionKey(dir: "/d", name: name), alias: "", activity: 0, state: .idle, agents: 0)
        }
        for c in "\\^$.|?*+()[]{}-" {
            let text = "a\(c)b", escaped = AgentIsland.sidekickEscaped(text)
            let others = ["axb", "ab", "a\(c)\(c)b", "b\(c)a", "aab"]
            let list = ([text] + others).map(session)
            XCTAssertEqual(AgentIsland.sidekickMatch(escaped), .regex, "\(text): matched as a regex, not through the text fallback")
            XCTAssertEqual(AgentIsland.split(list, pattern: escaped).firstGroup.map(\.key.name), [text], "\(text) via \(escaped): only the text")
            if c != "-" { XCTAssertEqual(AgentIsland.sidekickHint(escaped), .exact, "\(escaped) is read as exact") }
            XCTAssertEqual(DchConfigWriter.sidekickValue(escaped), escaped, "\(escaped) goes to the dch line unchanged (R938-1)")
        }
        // The case folding is the matcher's, as for a plain pattern.
        XCTAssertEqual(AgentIsland.split(["A.B", "axb"].map(session), pattern: AgentIsland.sidekickEscaped("a.b")).firstGroup.map(\.key.name), ["A.B"])
        // And the dot unescaped is the very difference the hint is about.
        XCTAssertEqual(AgentIsland.split(["a.b", "axb"].map(session), pattern: "a.b").firstGroup.count, 2)
    }

    func testMatchExactlyOnlyChangesAPatternReadAsARegex() {
        XCTAssertEqual(AgentIsland.sidekickMatchExactly("a.b"), "a\\.b")
        XCTAssertEqual(AgentIsland.sidekickMatchExactly("  c++ "), "c\\+\\+", "trimmed, as the matcher reads it")
        XCTAssertEqual(AgentIsland.sidekickMatchExactly("-qa"), "-qa", "plain")
        XCTAssertEqual(AgentIsland.sidekickMatchExactly("x("), "x(", "invalid: left as it is")
        XCTAssertEqual(AgentIsland.sidekickMatchExactly("a\\.b"), "a\\.b", "already exact")
        XCTAssertEqual(AgentIsland.sidekickMatchExactly(""), "")
        XCTAssertEqual(AgentIsland.sidekickHint(AgentIsland.sidekickMatchExactly("a.b")), .exact, "the button leaves no hint behind")
    }

    /// F938-1: the escape doubles each syntax character, so the button is offered only when the ESCAPED form fits 255 bytes.
    /// Shapes: `n` portable "a" bytes plus `k` dots; escaped = n + 2k bytes.
    private func dots(_ n: Int, _ k: Int) -> String { String(repeating: "a", count: n) + String(repeating: ".", count: k) }

    func testButtonOnlyWhenTheEscapedFormFitsTheBound() {
        let long = dots(240, 10)   // 250 bytes; escaped 260 bytes
        XCTAssertEqual(long.utf8.count, 250)
        XCTAssertEqual(AgentIsland.sidekickEscaped(long).utf8.count, 260)
        XCTAssertEqual(AgentIsland.sidekickHint(long), .regex(first: "."), "still read as a regex: the hint stays")
        XCTAssertFalse(AgentIsland.sidekickCanMatchExactly(long))
        XCTAssertEqual(AgentIsland.sidekickMatchExactly(long), long, "unchanged")
        // The edge: escaped 255 bytes (pattern 250: 245 + 5, escaped 245 + 10) gets the button; escaped 256 (pattern 251) does not.
        let at = dots(245, 5), over = dots(246, 5)
        XCTAssertEqual(AgentIsland.sidekickEscaped(at).utf8.count, 255)
        XCTAssertEqual(AgentIsland.sidekickEscaped(over).utf8.count, 256)
        XCTAssertTrue(AgentIsland.sidekickCanMatchExactly(at))
        XCTAssertEqual(AgentIsland.sidekickMatchExactly(at).utf8.count, 255)
        XCTAssertEqual(AgentIsland.sidekickMatchExactly(at), AgentIsland.sidekickEscaped(at))
        XCTAssertEqual(DchConfigWriter.sidekickValue(AgentIsland.sidekickMatchExactly(at)).utf8.count, 255, "the dch line is not emptied")
        XCTAssertFalse(AgentIsland.sidekickCanMatchExactly(over))
        XCTAssertEqual(AgentIsland.sidekickMatchExactly(over), over)
        // Short regex patterns, plain and exact ones, and a pattern past the bound itself.
        XCTAssertTrue(AgentIsland.sidekickCanMatchExactly("a.b"))
        for p in ["abc", "x(", "a\\.b", "", dots(300, 1)] { XCTAssertFalse(AgentIsland.sidekickCanMatchExactly(p), p) }
        // Bytes, not characters: a two-byte scalar counts twice (pattern 249, escaped 254 fits; pattern 251, escaped 256 does not).
        XCTAssertTrue(AgentIsland.sidekickCanMatchExactly(String(repeating: "\u{00E9}", count: 122) + dots(0, 5)))
        XCTAssertFalse(AgentIsland.sidekickCanMatchExactly(String(repeating: "\u{00E9}", count: 123) + dots(0, 5)))
    }

    @MainActor
    func testNothingIsMigratedUntilTheButton() {
        withSavedKeys {
            Preferences.agentIslandSidekickPattern = "a.b"
            let stamp = Preferences.agentIslandSidekickPatternUpdated
            _ = AgentIsland.sidekickHint("a.b"); _ = AgentIslandListSection.hintLine("a.b")
            XCTAssertEqual(Preferences.agentIslandSidekickPattern, "a.b", "reading a hint writes nothing")
            XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, stamp)
            // The button sets the field; the field's onChange is patternEdited: the row's existing save path.
            AgentIslandListSection.patternEdited(AgentIsland.sidekickMatchExactly("a.b"), now: Date(timeIntervalSince1970: 2_000_000))
            XCTAssertEqual(Preferences.agentIslandSidekickPattern, "a\\.b")
        }
    }

    // MARK: The row: offscreen at three scales, on the real accessibility tree of a never-shown window

    @MainActor
    private func axTree(_ size: CGSize, until done: ([AXTreeNode]) -> Bool) -> [AXTreeNode] {
        AXTreeSupport.tree(AgentIslandListSection().frame(width: size.width).preferredColorScheme(.dark), size, until: done)
    }

    @MainActor
    private func fittingHeight(_ width: CGFloat) -> CGFloat {
        let h = NSHostingView(rootView: AgentIslandListSection().frame(width: width).preferredColorScheme(.dark))
        h.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 10))
        h.frame.size = h.fittingSize
        h.layoutSubtreeIfNeeded()
        return h.fittingSize.height
    }

    @MainActor
    func testRowAtThreeScalesOnTheAccessibilityTree() {
        withSavedKeys {
            let savedScale = ThemeRuntime.scale
            defer { ThemeRuntime.scale = savedScale }
            let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
            func near(_ a: CGRect, _ b: CGRect, _ what: String) {   // per dimension, one device pixel: two drawn frames are not exactly equal
                XCTAssertEqual(a.minX, b.minX, accuracy: pixel, "\(what) minX")
                XCTAssertEqual(a.minY, b.minY, accuracy: pixel, "\(what) minY")
                XCTAssertEqual(a.width, b.width, accuracy: pixel, "\(what) width")
                XCTAssertEqual(a.height, b.height, accuracy: pixel, "\(what) height")
            }
            Preferences.agentIslandSidekickTabs = true
            let button = "Match this text exactly"
            // Plain, regex (the hint and the button), regex again, already exact: the hint line and the button come and go.
            // `same`: the other lines of the section are the same too. "a.b" and "c++" are not portable to dch (DchConfigWriter.portable), so
            // the existing caption under the field (sidekickDchNote, a line that was always variable) adds its own line: only the hint is checked.
            let cases: [(pattern: String, hint: String?, same: Bool)] = [
                ("abc", nil, true), ("a.b", "Read as a regex: . matches any character", false),
                ("c++", "Read as a regex: + repeats the one before", false), ("a\\.b", nil, true),
                ("a?b", "Read as a regex: ? may skip the one before", true), ("a|b", "Read as a regex: | means either side", true),
            ]
            for scale in [0.7, 0.85, 1.0] as [CGFloat] {
                ThemeRuntime.scale = scale
                let size = CGSize(width: sz(560), height: sz(600))
                var first: (title: CGRect, field: CGRect, height: CGFloat)?
                for (pattern, hint, same) in cases {
                    Preferences.agentIslandSidekickPattern = pattern
                    func field(_ t: [AXTreeNode]) -> AXTreeNode? { t.first { $0.role == "AXTextField" && $0.label == "Sidekick pattern" } }
                    func settled(_ t: [AXTreeNode]) -> Bool {
                        abs((field(t)?.frame.width ?? 0) - sz(180)) <= 1 && field(t)?.value == pattern
                            && (hint.map { h in t.contains { $0.named(h) } && t.contains { $0.reads(button) } } ?? true)
                    }
                    let tree = axTree(size, until: settled)
                    if !settled(tree) {   // only on failure: the frames of the row, for the log
                        print("#938 TREE \(pattern) at \(scale): " + tree.filter { !($0.label + $0.title + $0.value).isEmpty }
                            .map { "\($0.role)|\($0.label)|\($0.title)|\($0.value)|\(NSStringFromRect($0.frame))" }.joined(separator: " ; "))
                    }
                    let title = tree.first { $0.role == "AXStaticText" && $0.named("Sidekick pattern") }
                    XCTAssertTrue(title != nil, "the row's title at \(scale)")
                    XCTAssertTrue(field(tree) != nil, "the named field at \(scale) for \(pattern)")
                    XCTAssertTrue(tree.contains { $0.named(prefix: "Read as a regex") } == (hint != nil), "the hint only for a regex: \(pattern) at \(scale)")
                    XCTAssertEqual(tree.contains { $0.reads(button) }, hint != nil, "the button only for a regex: \(pattern) at \(scale)")
                    if let hint {
                        XCTAssertEqual(field(tree)?.help, hint, "the hint is read with the field: \(pattern) at \(scale)")
                        if let b = tree.first(where: { $0.reads(button) }) {
                            XCTAssertTrue(b.enabled, "the button is live at \(scale)")
                            XCTAssertLessThanOrEqual(b.frame.maxX, size.width + 1, "the button is not clipped at the right at \(scale)")
                            XCTAssertGreaterThanOrEqual(b.frame.minX, -1, "nor at the left at \(scale)")
                            XCTAssertGreaterThan(b.frame.width, 0)
                        }
                    } else {
                        XCTAssertEqual(field(tree)?.help ?? "", "", "no hint with the field: \(pattern) at \(scale)")
                    }
                    // Fixed slots: the hint and the button come and go and the row keeps its size.
                    let h = fittingHeight(size.width)
                    if !same {
                        // the hint line itself is one line at this scale, as in the plain row
                        XCTAssertLessThan(tree.first { $0.named(prefix: "Read as a regex") }?.frame.height ?? .infinity, 1.5 * (title?.frame.height ?? 0), "the hint is one line: \(pattern) at \(scale)")
                    } else if let f = first, let t = title?.frame, let fr = field(tree)?.frame {
                        near(t, f.title, "the title's frame with \(pattern) at \(scale)")
                        near(fr, f.field, "the field's frame with \(pattern) at \(scale)")
                        XCTAssertEqual(h, f.height, accuracy: pixel, "the section's height with \(pattern) at \(scale)")
                    } else if let t = title?.frame, let fr = field(tree)?.frame {
                        first = (t, fr, h)
                    }
                }
            }
        }
    }

    @MainActor
    func testRowHidesTheButtonForAnEscapeThatDoesNotFit() {
        withSavedKeys {
            Preferences.agentIslandSidekickTabs = true
            let size = CGSize(width: sz(560), height: sz(600)), button = "Match this text exactly"
            @MainActor func state(_ pattern: String) -> (button: Bool, hint: Bool, height: CGFloat) {
                Preferences.agentIslandSidekickPattern = pattern
                let tree = axTree(size) { $0.contains { $0.role == "AXTextField" && $0.label == "Sidekick pattern" && $0.value == pattern } }
                return (tree.contains { $0.reads(button) }, tree.contains { $0.named(prefix: "Read as a regex") }, fittingHeight(size.width))
            }
            let shown = state(dots(240, 2)), hidden = state(dots(240, 10))   // escaped 244 and 260 bytes
            XCTAssertTrue(shown.button && shown.hint, "a short escape: the button")
            XCTAssertTrue(!hidden.button, "no button when the escape does not fit")
            XCTAssertTrue(hidden.hint, "the hint line still says it is read as a regex")
            XCTAssertEqual(hidden.height, shown.height, accuracy: 0.5, "the row keeps its height")
        }
    }

    @MainActor
    func testButtonIsOffWithTheTabsAndTheFieldStillSaysWhatItReads() {
        withSavedKeys {
            Preferences.agentIslandSidekickTabs = false
            Preferences.agentIslandSidekickPattern = "a.b"
            let tree = axTree(CGSize(width: sz(560), height: sz(600))) { $0.contains { $0.named(prefix: "Read as a regex") } }
            XCTAssertTrue(tree.contains { $0.named(prefix: "Read as a regex") }, "the hint stays: the saved text is still read that way")
            XCTAssertTrue(tree.first { $0.reads("Match this text exactly") }.map { !$0.enabled } ?? true, "the button is off with the tabs")
        }
    }
}
