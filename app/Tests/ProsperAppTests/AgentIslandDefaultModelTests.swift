import SwiftUI
import XCTest
@testable import ProsperApp

/// #1228: the Default model setting. The pure function and the validation on literal tables; the settings row
/// offscreen at three UI scales and on the accessibility tree of a never-shown window. Preferences are the XCTest
/// in-memory suite (saved and restored per test); nothing spawns, no menu pops up (its items are read as values).
final class AgentIslandDefaultModelTests: XCTestCase {
    private static let key = "agentIslandDefaultModel"

    @MainActor
    private func withSavedModel(_ body: () throws -> Void) rethrows {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let saved = Preferences.defaults.object(forKey: Self.key)
        defer { Preferences.defaults.set(saved, forKey: Self.key) }
        try body()
    }

    // MARK: The pure function

    func testWithModelAddsTheFlagOnlyToAClaudeProgramWithoutOne() {
        let rows: [(argv: [String], out: [String], why: String)] = [
            (["claude"], ["claude", "--model", "opus"], "plain claude"),
            (["/opt/homebrew/bin/claude", "--chrome"], ["/opt/homebrew/bin/claude", "--model", "opus", "--chrome"], "a path"),
            (["headroom", "wrap", "claude", "--chrome"], ["headroom", "wrap", "claude", "--model", "opus", "--chrome"],
             "behind a wrapper: right after the claude word"),
            (["/usr/bin/env", "FOO=1", "claude"], ["/usr/bin/env", "FOO=1", "claude", "--model", "opus"], "after env"),
            (["env", "-i", "claude"], ["env", "-i", "claude", "--model", "opus"], "env's own flag (claudeRuns)"),
            (["claude", "--model", "sonnet"], ["claude", "--model", "sonnet"], "a typed --model wins"),
            (["claude", "--chrome", "--model=sonnet"], ["claude", "--chrome", "--model=sonnet"], "a typed --model= wins"),
            (["claude", "-m", "sonnet"], ["claude", "--model", "opus", "-m", "sonnet"],
             "the flag table has no short form for --model: -m is not a model flag"),
            (["claude", "--agent", "--model"], ["claude", "--model", "opus", "--agent", "--model"],
             "a --model that is another option's value is no model flag"),
            (["claude", "--", "--model", "x"], ["claude", "--model", "opus", "--", "--model", "x"], "after -- it is the prompt"),
            (["claude", "--agent", "claude"], ["claude", "--model", "opus", "--agent", "claude"],
             "a claude that is a flag's value is not the program: the first one is"),
            (["/bin/zsh", "-l"], ["/bin/zsh", "-l"], "a shell"),
            ([], [], "an empty argv"),
            (["codex"], ["codex"], "another agent"),
            (["codex", "--model", "claude"], ["codex", "--model", "claude"], "claude as another program's flag value"),
            (["ssh", "-t", "example-host", "claude"], ["ssh", "-t", "example-host", "claude"],
             "claude as a plain argument after a different program"),
            (["/bin/zsh", "-c", "claude"], ["/bin/zsh", "-c", "claude"], "claude as sh -c's argument"),
            (["vim", "/Users/example/claude.md"], ["vim", "/Users/example/claude.md"], "a substring is no claude word"),
            (["claude", "-p", "hi"], ["claude", "-p", "hi"], "a batch run is not a session"),
            (["claude", "mcp", "list"], ["claude", "mcp", "list"], "a claude command is not a session"),
        ]
        for r in rows { XCTAssertEqual(AgentIsland.withModel(r.argv, model: "opus"), r.out, r.why) }
    }

    func testWithModelAddsNothingForASavedValueThatFailsTheRule() {
        let rows: [(model: String, why: String)] = [
            ("", "unset"), ("op us", "a space"), (" opus", "untrimmed from outside"), ("-p", "a leading hyphen"),
            ("op\u{0}us", "a NUL"), ("op\nus", "a newline"), ("op\"us", "a quote"), ("op$us", "a dollar sign"),
            (String(repeating: "a", count: 129), "129 characters"), ("op\u{FC}s", "a non-ASCII letter"),
        ]
        for r in rows { XCTAssertEqual(AgentIsland.withModel(["claude"], model: r.model), ["claude"], r.why) }
        XCTAssertEqual(AgentIsland.withModel(["claude"], model: "claude-example-1"), ["claude", "--model", "claude-example-1"],
                       "one argv element for the value, as is")
    }

    // MARK: Validation

    func testModelRefusalAcceptsAndRefusesLiteralValues() {
        let accepted = ["opus", "sonnet", "haiku", "claude-example-1", "a.b_c:d[1m]", String(repeating: "a", count: 128)]
        for m in accepted { XCTAssertTrue(AgentIsland.modelRefusal(m) == nil, m) }
        let refused: [(String, String)] = [
            ("", "Type a model name"),
            ("op us", "Only A-Z a-z 0-9 ._:-[]"),
            ("-opus", "Cannot start with -"),
            (String(repeating: "a", count: 129), "Too long: 128 max"),
            ("op\"us", "Only A-Z a-z 0-9 ._:-[]"),
            ("op'us", "Only A-Z a-z 0-9 ._:-[]"),
            ("opus;x", "Only A-Z a-z 0-9 ._:-[]"),
            ("op$us", "Only A-Z a-z 0-9 ._:-[]"),
            ("op\nus", "Only A-Z a-z 0-9 ._:-[]"),
            ("op\u{0}us", "Only A-Z a-z 0-9 ._:-[]"),
            ("op\u{FC}s", "Only A-Z a-z 0-9 ._:-[]"),
            ("e\u{301}", "Only A-Z a-z 0-9 ._:-[]"),
        ]
        for (m, why) in refused { XCTAssertEqual(AgentIsland.modelRefusal(m), why, m.debugDescription) }
    }

    /// The field's commit: trimmed and saved; empty clears; a refused value saves nothing (the previous one stays).
    @MainActor
    func testCommitModelSavesTrimmedRefusesWithAReasonAndKeepsThePrevious() {
        withSavedModel {
            XCTAssertTrue(AgentIslandPane.commitModel("  opus\n") == nil)
            XCTAssertEqual(Preferences.agentIslandDefaultModel, "opus")
            let refused = ["op us", "-x", "op\"us", "a;b", "a$b", "op\nus", "op\u{0}us", String(repeating: "b", count: 129)]
            for m in refused {
                XCTAssertTrue(AgentIslandPane.commitModel(m) != nil, m.debugDescription)
                XCTAssertEqual(Preferences.agentIslandDefaultModel, "opus", "nothing saved: \(m.debugDescription)")
            }
            XCTAssertTrue(AgentIslandPane.commitModel("   ") == nil, "blank: cleared, Claude Code's own default")
            XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil, "the key is gone")
            XCTAssertEqual(AgentIslandPane.modelAliases, ["opus", "sonnet", "haiku"], "the menu's items, read as values")
            for a in AgentIslandPane.modelAliases { XCTAssertTrue(AgentIsland.modelRefusal(a) == nil, a) }
            Preferences.agentIslandDefaultModel = "op us"   // written from outside
            XCTAssertEqual(AgentIslandPane.savedModelRefusal(), "Not used: Only A-Z a-z 0-9 ._:-[]")
            XCTAssertEqual(AgentNewSession.argv("claude", shell: "/bin/zsh"), ["claude"], "the re-check: nothing added")
        }
    }

    // MARK: The settings row: offscreen at three scales, on the real accessibility tree of a never-shown window

    /// A static text carries its words as its value, a button may as its title: `named` is any of them.
    private typealias AXNode = AXTreeNode

    /// The settings pane in a never-shown window: AXTreeSupport's walk, the two AX flags put back to what they were.
    @MainActor
    private func axTree(_ size: CGSize, until done: ([AXNode]) -> Bool) -> [AXNode] {
        AXTreeSupport.tree(AgentIslandPane().frame(width: size.width).preferredColorScheme(.dark), size, until: done)
    }

    @MainActor
    func testSettingsRowAtThreeScalesOnTheAccessibilityTree() {
        withSavedModel {
            let savedScale = ThemeRuntime.scale
            defer { ThemeRuntime.scale = savedScale }
            // The hint first, then each refusal as a saved value written from outside shows it (literals).
            let cases: [(stored: String, line: String)] = [
                ("claude-example-1", "Empty: Claude Code's own default"),
                ("op us", "Not used: Only A-Z a-z 0-9 ._:-[]"),
                (String(repeating: "a", count: 129), "Not used: Too long: 128 max"),
                ("-opus", "Not used: Cannot start with -"),
            ]
            XCTAssertEqual(AgentIslandPane.modelHint, cases.first?.line)
            for scale in [0.7, 0.85, 1.0] as [CGFloat] {
                ThemeRuntime.scale = scale
                let size = CGSize(width: sz(560), height: sz(900))
                var hint: (field: CGRect, title: CGRect, sub: CGRect, menu: CGRect)?
                for (stored, line) in cases {
                    Preferences.agentIslandDefaultModel = stored
                    func model(_ t: [AXNode]) -> AXNode? { t.first { $0.label == "Default model" && $0.role == "AXTextField" } }
                    func command(_ t: [AXNode]) -> AXNode? { t.first { $0.role == "AXTextField" && $0.label != "Default model" } }
                    // Settled at THIS scale: the menu and the subtitle on the tree, and both fields laid out at this
                    // scale's widths (a pass right after another scale's could read a frame of the old layout).
                    func settled(_ t: [AXNode]) -> Bool {
                        t.contains { $0.named("Model aliases") } && t.contains { $0.named(line) }
                            && abs((model(t)?.frame.width ?? 0) - sz(200)) <= 1 && abs((command(t)?.frame.width ?? 0) - sz(260)) <= 1
                    }
                    let tree = axTree(size, until: settled)
                    let field = model(tree), other = command(tree)
                    let menu = tree.first { $0.named("Model aliases") }
                    let title = tree.first { $0.role == "AXStaticText" && $0.named("Default model") }
                    let sub = tree.first { $0.named(line) }
                    if !settled(tree) || title == nil {   // only on failure: every frame the row reads, for the log
                        print("#1228 FRAMES \(line) at \(scale): " + tree.filter { !($0.label + $0.title + $0.value).isEmpty }
                            .map { "\($0.role)|\($0.label)|\($0.title)|\($0.value)|\(NSStringFromRect($0.frame))" }.joined(separator: " ; "))
                    }
                    XCTAssertTrue(field != nil, "the field, named, at \(scale)")
                    XCTAssertEqual(field?.value, stored, "the field shows the saved value at \(scale)")
                    XCTAssertTrue(menu != nil, "the aliases menu, named, at \(scale)")
                    XCTAssertTrue(sub != nil, "\(line) at \(scale)")
                    XCTAssertTrue(title != nil, "the row's title at \(scale)")
                    XCTAssertEqual(tree.filter { $0.role == "AXTextField" }.count, 2, "Command and Default model at \(scale)")
                    guard let f = field?.frame, let o = other?.frame, let m = menu?.frame, let ti = title?.frame, let s = sub?.frame
                    else { continue }
                    XCTAssertEqual(f.height, o.height, accuracy: 1, "same control height at \(scale)")
                    XCTAssertEqual(f.width, sz(200), accuracy: 1, "the field's width follows the scale at \(scale)")
                    XCTAssertGreaterThan(m.width, 0, "the menu keeps its natural width at \(scale)")
                    XCTAssertLessThanOrEqual(m.maxX, size.width + 1, "the menu is inside the pane at \(scale)")
                    XCTAssertLessThanOrEqual(f.maxX, m.minX + 1, "the field before the menu, no overlap at \(scale)")
                    // Fixed slots: a refusal in the subtitle moves and resizes nothing (one line, as the hint).
                    if let h = hint {
                        XCTAssertEqual(f, h.field, "the field's frame with \(line) at \(scale)")
                        XCTAssertEqual(ti, h.title, "the row's title with \(line) at \(scale)")
                        XCTAssertEqual(m, h.menu, "the menu with \(line) at \(scale)")
                        XCTAssertEqual(s.minY, h.sub.minY, accuracy: 0.5, "the subtitle's place with \(line) at \(scale)")
                        XCTAssertEqual(s.height, h.sub.height, accuracy: 0.5, "one line, as the hint: \(line) at \(scale)")
                    } else {
                        hint = (f, ti, s, m)
                    }
                }
            }
        }
    }
}

/// #1228: the window's New session form shows the command with the Default model and starts exactly that argv.
extension AgentWindowD1Tests {
    @MainActor
    func testAgentWindowNewSessionShowsAndStartsTheDefaultModel() throws {
        try withNewSessionPrefs {
            Preferences.agentIslandNewSessionCommand = "claude --chrome"
            Preferences.agentIslandDefaultModel = "claude-example-1"
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSession?.command, "claude --chrome", "the typed text never gets the flag")
            XCTAssertEqual(m.newSessionRuns, "claude --name api --model claude-example-1 --chrome", "the shown command holds it")
            m.setNewSessionCommand("claude --model sonnet")
            XCTAssertEqual(m.newSessionRuns, "claude --name api --model sonnet", "a --model typed into the form wins")
            m.setNewSessionCommand("claude --chrome")
            let runs = m.newSessionRuns
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(spawns.calls.count, 1)
            let argv = spawns.calls.last?.argv ?? []
            XCTAssertEqual(argv, ["claude", "--model", "claude-example-1", "--chrome"])
            XCTAssertEqual(argv.filter { $0 == "--model" }.count, 1, "the flag once")
            XCTAssertEqual(AgentIsland.shellLine(AgentIsland.naming(argv, name: "api")), runs, "what starts is what was shown")
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --chrome", "the saved command never takes the flag")
        }
    }
}
