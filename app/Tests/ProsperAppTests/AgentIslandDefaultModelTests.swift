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
            // Item 1 of #1237 closed with a fact: Claude Code's public CLI reference (code.claude.com/docs/en/cli-reference,
            // read 2026-11-14) documents `--model` only, no short form (the documented short forms are -c -n -p -r -v -w).
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

    /// #1237 (N1228-a): a command that continues an existing conversation keeps the model it ran on (literal argv values).
    func testWithModelSkipsACommandThatContinuesAnExistingConversation() {
        let skips: [[String]] = [
            ["claude", "--resume"], ["claude", "--resume", "abc"], ["claude", "--resume=abc"], ["claude", "-r"],
            ["claude", "-r", "abc"], ["claude", "--continue"], ["claude", "-c"], ["claude", "--from-pr"],
            ["claude", "--from-pr", "123"], ["claude", "--from-pr=123"], ["claude", "--teleport"],
            ["claude", "--teleport", "abc"], ["claude", "--teleport=abc"], ["claude", "--chrome", "-c"],
            ["headroom", "wrap", "claude", "--resume", "abc"], ["/usr/bin/env", "FOO=1", "claude", "-c"],
        ]
        for a in skips { XCTAssertEqual(AgentIsland.withModel(a, model: "opus"), a, a.joined(separator: " ")) }
        let adds: [(argv: [String], out: [String], why: String)] = [
            (["claude", "--session-id", "abc"], ["claude", "--model", "opus", "--session-id", "abc"], "a new conversation"),
            (["claude", "--fork-session"], ["claude", "--model", "opus", "--fork-session"], "fork-session alone acts on nothing"),
            (["claude", "--name", "--resume"], ["claude", "--model", "opus", "--name", "--resume"], "a session NAME that looks like an option"),
            (["claude", "--append-system-prompt", "-c"], ["claude", "--model", "opus", "--append-system-prompt", "-c"],
             "a value that looks like -c"),
            (["claude", "--", "-c"], ["claude", "--model", "opus", "--", "-c"], "after -- it is the prompt"),
        ]
        for r in adds { XCTAssertEqual(AgentIsland.withModel(r.argv, model: "opus"), r.out, r.why) }
        // R1237-a: a cluster with c or r up to and including its stop letter continues a conversation (changed row: -cp and
        // -cn x used to get the model, pinned "as is"; real claude continues, so they skip now).
        let clusterSkips: [[String]] = [
            ["claude", "-rabc"], ["claude", "-r=abc"], ["claude", "-cn", "x"], ["claude", "-cw"], ["claude", "-cv"],
            ["claude", "-cp"], ["claude", "--resume", "abc"], ["claude", "--continue"], ["claude", "-r", "abc"], ["claude", "-c"],
        ]
        for a in clusterSkips { XCTAssertEqual(AgentIsland.withModel(a, model: "opus"), a, a.joined(separator: " ")) }
        let clusterAdds: [(argv: [String], out: [String], why: String)] = [
            (["claude", "-nrc"], ["claude", "--model", "opus", "-nrc"], "rc is the name, a value after the stop letter"),
            (["claude", "-n", "rc"], ["claude", "--model", "opus", "-n", "rc"], "two words: rc is n's value"),
            (["claude"], ["claude", "--model", "opus"], "a plain new session"),
            (["claude", ""], ["claude", "--model", "opus", ""], "an empty element is an operand"),
            (["claude", "-"], ["claude", "--model", "opus", "-"], "a lone dash is an operand"),
            (["claude", "--"], ["claude", "--model", "opus", "--"], "a bare -- ends the options"),
            (["claude", "---"], ["claude", "--model", "opus", "---"], "only dashes: an unknown long option"),
        ]
        for r in clusterAdds { XCTAssertEqual(AgentIsland.withModel(r.argv, model: "opus"), r.out, r.why) }
    }

    /// KNOWN LIMIT (#1237 item 2, decided: leave as is): a plain two-word line whose second word is claude, no dashed word
    /// before it, is read as a wrapper for BOTH flags, so an editor opening a file named claude gets them (never run).
    func testKnownLimitATwoWordLineWithClaudeSecondIsReadAsAWrapperForBothFlags() {
        XCTAssertEqual(AgentIsland.withModel(["vim", "claude"], model: "opus"), ["vim", "claude", "--model", "opus"])
        XCTAssertEqual(AgentIsland.naming(["vim", "claude"], name: "api"), ["vim", "claude", "--name", "api"])
        XCTAssertEqual(AgentIsland.withModel(["vim", "-R", "claude"], model: "opus"), ["vim", "-R", "claude"], "a dashed word before it: not read so")
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
            _ = ThemeStore.shared   // its first use (NeonRow's) seeds ThemeRuntime.scale from the prefs: before the scale is set here
            let savedScale = ThemeRuntime.scale
            defer { ThemeRuntime.scale = savedScale }
            let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
            // The hint first, then each refusal as a saved value written from outside shows it (literals).
            let cases: [(stored: String, line: String)] = [
                ("claude-example-1", "Empty: Claude Code's own default"),
                ("op us", "Not used: Only A-Z a-z 0-9 ._:-[]"),
                (String(repeating: "a", count: 129), "Not used: Too long: 128 max"),
                ("-opus", "Not used: Cannot start with -"),
            ]
            XCTAssertEqual(AgentIslandPane.modelHint, cases.first?.line)
            for scale in [0.7, 0.85, 1.0, 1.15, 1.3, 1.45] as [CGFloat] {
                ThemeRuntime.scale = scale
                let size = CGSize(width: sz(560), height: sz(900))
                var hint: (field: CGRect, title: CGRect, sub: CGRect, menu: CGRect)?
                for (stored, line) in cases {
                    Preferences.agentIslandDefaultModel = stored
                    func model(_ t: [AXNode]) -> AXNode? { t.first { $0.label == "Default model" && $0.role == "AXTextField" } }
                    func command(_ t: [AXNode]) -> AXNode? {   // #1338: not the Pairs field either
                        t.first { $0.role == "AXTextField" && !["Default model", "Sidekick suffix", "Sidekick prompt"].contains($0.label) }
                    }
                    // Settled at THIS scale: the menu and the subtitle on the tree, and both fields laid out at this
                    // scale's widths (a pass right after another scale's could read a frame of the old layout).
                    func settled(_ t: [AXNode]) -> Bool {
                        t.contains { $0.named("Model aliases") } && t.contains { $0.named(line) }
                            && abs((model(t)?.frame.width ?? 0) - sz(200)) <= 1 && abs((command(t)?.frame.width ?? 0) - sz(260)) <= 1
                            && abs((model(t)?.frame.height ?? 0) - (command(t)?.frame.height ?? 100_000)) <= 1   // not mid-layout
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
                    XCTAssertEqual(tree.filter { $0.role == "AXTextField" && $0.label != "Sidekick prompt" }.count, 3,
                                   "Command, Default model and (#1338) Sidekick suffix at \(scale)")
                    XCTAssertEqual(tree.filter { ["AXTextField", "AXTextArea"].contains($0.role) && $0.label == "Sidekick prompt" }.count, 1,
                                   "#907: the Sidekick prompt field, named, once at \(scale)")
                    XCTAssertTrue(tree.contains { $0.role == "AXTextField" && $0.label == "Sidekick suffix" }, "#1338: the Pairs field, named, at \(scale)")
                    guard let f = field?.frame, let o = other?.frame, let m = menu?.frame, let ti = title?.frame, let s = sub?.frame
                    else { continue }
                    XCTAssertEqual(f.height, o.height, accuracy: 1, "same control height at \(scale)")
                    XCTAssertEqual(f.width, sz(200), accuracy: 1, "the field's width follows the scale at \(scale)")
                    XCTAssertGreaterThan(m.width, 0, "the menu keeps its natural width at \(scale)")
                    XCTAssertLessThanOrEqual(m.maxX, size.width + 1, "the menu is inside the pane at \(scale)")
                    XCTAssertLessThanOrEqual(f.maxX, m.minX + 1, "the field before the menu, no overlap at \(scale)")
                    // Fixed slots: a refusal in the subtitle moves and resizes nothing (one line, as the hint).
                    if let h = hint {
                        func same(_ a: CGRect, _ b: CGRect, _ what: String) {   // one device pixel per component: a sub-pixel layout difference is not a move
                            XCTAssertEqual(a.minX, b.minX, accuracy: pixel, "\(what) minX with \(line) at \(scale)")
                            XCTAssertEqual(a.minY, b.minY, accuracy: pixel, "\(what) minY with \(line) at \(scale)")
                            XCTAssertEqual(a.width, b.width, accuracy: pixel, "\(what) width with \(line) at \(scale)")
                            XCTAssertEqual(a.height, b.height, accuracy: pixel, "\(what) height with \(line) at \(scale)")
                        }
                        same(f, h.field, "the field's frame")
                        same(ti, h.title, "the row's title")
                        same(m, h.menu, "the menu")
                        XCTAssertEqual(s.minY, h.sub.minY, accuracy: pixel, "the subtitle's place with \(line) at \(scale)")
                        XCTAssertEqual(s.height, h.sub.height, accuracy: pixel, "one line, as the hint: \(line) at \(scale)")
                    } else {
                        hint = (f, ti, s, m)
                    }
                }
            }
        }
    }

    /// #1237 item 4: the subtitle is passed to NeonRow (SettingsTheme.swift, closed) as a plain string, so no line limit
    /// can be set here; this pins every text of the slot. The four refusals as literals, a fifth fails this row.
    func testTheFourRefusalsAreTheseAndNoFifth() {
        let literal = ["Type a model name", "Only A-Z a-z 0-9 ._:-[]", "Too long: 128 max", "Cannot start with -"]
        let probes = ["", "op us", String(repeating: "a", count: 129), "-x"]
        XCTAssertEqual(probes.map { AgentIsland.modelRefusal($0) }, literal)
        XCTAssertEqual(AgentIsland.modelMax, 128)
        // "Type a model name" never reaches the slot (an empty field clears the key); the other three do, as "Not used: ...".
    }

    /// #1237 items 3 and 4 on the real tree at 0.7, 0.85 and 1.0: the Aliases menu is not taller than the field, it sits
    /// inside the row, and the row's extent (title, subtitle, field, menu) is the same with the hint and with each
    /// refusal (one subtitle line each). The menu still reads Aliases and is enabled. No menu is opened.
    @MainActor
    func testAliasesMenuFollowsTheScaleAndTheRowKeepsOneFrameInEveryState() {
        withSavedModel {
            _ = ThemeStore.shared   // its first use (NeonRow's) seeds ThemeRuntime.scale from the prefs: before the scale is set here
            let savedScale = ThemeRuntime.scale
            defer { ThemeRuntime.scale = savedScale }
            let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
            let states: [(stored: String, line: String)] = [
                ("claude-example-1", AgentIslandPane.modelHint),
                ("op us", "Not used: Only A-Z a-z 0-9 ._:-[]"),
                (String(repeating: "a", count: 129), "Not used: Too long: 128 max"),
                ("-opus", "Not used: Cannot start with -"),
            ]
            for scale in [0.7, 0.85, 1.0, 1.15, 1.3, 1.45] as [CGFloat] {
                ThemeRuntime.scale = scale
                let size = CGSize(width: sz(560), height: sz(900))
                var rowHeights: [CGFloat] = [], subHeights: [CGFloat] = []
                for (stored, line) in states {
                    Preferences.agentIslandDefaultModel = stored
                    func field(_ t: [AXNode]) -> AXNode? { t.first { $0.label == "Default model" && $0.role == "AXTextField" } }
                    func settled(_ t: [AXNode]) -> Bool {
                        t.contains { $0.named("Model aliases") } && t.contains { $0.named(line) }
                            && abs((field(t)?.frame.width ?? 0) - sz(200)) <= 1
                    }
                    let tree = axTree(size, until: settled)
                    guard let f = field(tree)?.frame, let menuNode = tree.first(where: { $0.named("Model aliases") }),
                          let ti = tree.first(where: { $0.role == "AXStaticText" && $0.named("Default model") })?.frame,
                          let s = tree.first(where: { $0.named(line) })?.frame
                    else { XCTFail("the row's nodes at \(scale): \(line)"); continue }
                    let m = menuNode.frame
                    print("#1237 FRAMES at \(scale) \(line): field \(NSStringFromRect(f)) menu \(NSStringFromRect(m)) title \(NSStringFromRect(ti)) sub \(NSStringFromRect(s))")
                    XCTAssertLessThanOrEqual(m.height, f.height + 1, "the menu is not taller than the field at \(scale)")
                    let row = f.union(ti).union(s)
                    XCTAssertGreaterThanOrEqual(m.minY, row.minY - 1, "the menu inside the row, top, at \(scale)")
                    XCTAssertLessThanOrEqual(m.maxY, row.maxY + 1, "the menu inside the row, bottom, at \(scale)")
                    XCTAssertTrue(menuNode.enabled, "the menu is enabled at \(scale)")
                    XCTAssertTrue(tree.contains { $0.named("Aliases") || $0.named("Model aliases") }, "it reads Aliases at \(scale)")
                    rowHeights.append(row.union(m).height)
                    subHeights.append(s.height)
                }
                XCTAssertEqual(rowHeights.count, 4, "all four states read at \(scale)")
                for h in rowHeights { XCTAssertEqual(h, rowHeights.first ?? 0, accuracy: pixel, "the row's height is the same in every state at \(scale)") }
                for h in subHeights { XCTAssertEqual(h, subHeights.first ?? 0, accuracy: pixel, "one subtitle line in every state at \(scale)") }
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
