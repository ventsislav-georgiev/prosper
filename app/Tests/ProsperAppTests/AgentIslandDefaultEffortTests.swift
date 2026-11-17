import SwiftUI
import XCTest
@testable import ProsperApp

/// #1454 (OQ-138): the Default effort beside the Default model. The pure function on literal tables; the settings row
/// offscreen on the accessibility tree of a never-shown window. Preferences are the XCTest in-memory suite (saved and
/// restored per test); nothing spawns, no menu pops up (the picker's levels are read as values).
final class AgentIslandDefaultEffortTests: XCTestCase {
    private static let keys = ["agentIslandDefaultEffort", "agentIslandDefaultModel"]

    @MainActor
    private func withSavedPrefs(_ body: () throws -> Void) rethrows {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let saved = Self.keys.map { Preferences.defaults.object(forKey: $0) }
        defer { for (k, v) in zip(Self.keys, saved) { Preferences.defaults.set(v, forKey: k) } }
        try body()
    }

    // MARK: The pure function

    func testWithModelAddsTheEffortOnlyWhenSetAndNotTyped() {
        let rows: [(argv: [String], model: String, effort: String, out: [String], why: String)] = [
            (["claude"], "", "", ["claude"], "both empty: Claude Code picks, today's argv"),
            (["claude"], "opus", "", ["claude", "--model", "opus"], "effort empty: the model alone, as #1228"),
            (["claude"], "", "high", ["claude", "--effort", "high"], "effort set"),
            (["claude", "--chrome"], "opus", "high", ["claude", "--model", "opus", "--effort", "high", "--chrome"],
             "both, the model first, right after the claude word"),
            (["headroom", "wrap", "claude"], "", "max", ["headroom", "wrap", "claude", "--effort", "max"], "behind a wrapper"),
            (["claude", "--effort", "low"], "", "high", ["claude", "--effort", "low"], "a typed --effort wins"),
            (["claude", "--effort=low"], "", "high", ["claude", "--effort=low"], "a typed --effort= wins"),
            (["claude", "--effort", "low"], "opus", "high", ["claude", "--model", "opus", "--effort", "low"],
             "a typed effort keeps the Default model"),
            (["claude", "--model", "sonnet"], "opus", "high", ["claude", "--effort", "high", "--model", "sonnet"],
             "a typed model keeps the Default effort"),
            (["claude", "--agent", "--effort"], "", "high", ["claude", "--effort", "high", "--agent", "--effort"],
             "an --effort that is another option's value is no effort flag"),
            (["claude", "--", "--effort", "low"], "", "high", ["claude", "--effort", "high", "--", "--effort", "low"],
             "after -- it is the prompt"),
            (["claude", "--resume", "abc"], "opus", "high", ["claude", "--resume", "abc"], "Resume keeps what it has"),
            (["claude", "-c"], "", "high", ["claude", "-c"], "continue keeps what it has"),
            (["/bin/zsh", "-l"], "", "high", ["/bin/zsh", "-l"], "a shell"),
            (["codex"], "", "high", ["codex"], "another agent"),
            (["claude", "-p", "hi"], "", "high", ["claude", "-p", "hi"], "a batch run"),
        ]
        for r in rows { XCTAssertEqual(AgentIsland.withModel(r.argv, model: r.model, effort: r.effort), r.out, r.why) }
    }

    /// A saved value outside the levels (the key can be written from outside) adds nothing.
    func testWithModelAddsNoEffortOutsideTheLevels() {
        for e in ["HIGH", " high", "high ", "-p", "--chrome", "medium\nx", "hi\u{0}gh", "ultra", "h\u{EF}gh"] {
            XCTAssertEqual(AgentIsland.withModel(["claude"], model: "", effort: e), ["claude"], e.debugDescription)
        }
        XCTAssertEqual(AgentIsland.effortLevels, ["low", "medium", "high", "xhigh", "max"], "the menu's order")
        XCTAssertEqual(Set(AgentIsland.effortLevels), AgentModelEffort.levels, "the transcript's set, word for word")
        for e in AgentIsland.effortLevels {
            XCTAssertEqual(AgentIsland.withModel(["claude"], model: "", effort: e), ["claude", "--effort", e], e)
        }
    }

    /// An inferred command drops a recorded effort as it drops a recorded model, so a later Default effort wins.
    func testStrippingModelDropsARecordedEffortToo() {
        XCTAssertEqual(AgentIsland.strippingModel(["claude", "--effort", "high", "--chrome"]), ["claude", "--chrome"])
        XCTAssertEqual(AgentIsland.strippingModel(["claude", "--effort=high", "--model", "opus"]), ["claude"])
        XCTAssertEqual(AgentIsland.strippingModel(["claude", "--agent", "--effort", "--chrome"]), ["claude", "--agent", "--effort", "--chrome"],
                       "another option's value stays")
        XCTAssertEqual(AgentIsland.strippingModel(["claude", "--", "--effort", "x"]), ["claude", "--", "--effort", "x"], "the prompt stays")
    }

    /// AgentNewSession.argv reads the setting; an empty command is the login shell, never given the flag.
    @MainActor
    func testNewSessionArgvReadsTheDefaultEffort() {
        withSavedPrefs {
            Preferences.agentIslandDefaultModel = ""
            Preferences.agentIslandDefaultEffort = ""
            XCTAssertEqual(AgentNewSession.argv("claude", shell: "/bin/zsh"), ["claude"], "unset: today's")
            Preferences.agentIslandDefaultEffort = "xhigh"
            XCTAssertEqual(AgentNewSession.argv("claude", shell: "/bin/zsh"), ["claude", "--effort", "xhigh"])
            XCTAssertEqual(AgentNewSession.argv("", shell: "/bin/zsh"), ["/bin/zsh", "-l"], "the login shell")
            Preferences.agentIslandDefaultEffort = "bogus"   // written from outside
            XCTAssertEqual(AgentNewSession.argv("claude", shell: "/bin/zsh"), ["claude"], "the re-check: nothing added")
        }
    }

    // MARK: The settings row

    /// The pick is saved at once; "Claude Code picks" removes the key; nothing outside the levels is saved.
    @MainActor
    func testCommitEffortSavesThePickAndClearsOnClaudeCodePicks() {
        withSavedPrefs {
            Preferences.agentIslandDefaultEffort = ""
            AgentIslandPane.commitEffort("high")
            XCTAssertEqual(Preferences.agentIslandDefaultEffort, "high")
            for bad in ["HIGH", "ultra", " low", "--x"] {
                AgentIslandPane.commitEffort(bad)
                XCTAssertEqual(Preferences.agentIslandDefaultEffort, "high", "nothing saved: \(bad.debugDescription)")
            }
            AgentIslandPane.commitEffort("")
            XCTAssertTrue(Preferences.defaults.object(forKey: "agentIslandDefaultEffort") == nil, "the key is gone")
            Preferences.agentIslandDefaultEffort = "bogus"
            XCTAssertEqual(AgentIslandPane.shownEffort(), "", "a value from outside shows as Claude Code picks")
            Preferences.agentIslandDefaultEffort = "max"
            XCTAssertEqual(AgentIslandPane.shownEffort(), "max")
            XCTAssertEqual(AgentIslandPane.effortDefaultLabel, "Claude Code picks")
        }
    }

    /// The row on the real accessibility tree of a never-shown window, at two scales: named "Default effort", showing the
    /// saved level (or "Claude Code picks"), between the Default model field and the Pairs field (the Default model row
    /// was the New session section's last). The Default model field is unchanged (still a text field, named).
    @MainActor
    func testSettingsRowSitsUnderDefaultModelAndShowsTheSavedPick() {
        withSavedPrefs {
            _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
            let savedScale = ThemeRuntime.scale
            defer { ThemeRuntime.scale = savedScale }
            Preferences.agentIslandDefaultModel = "claude-example-1"
            for scale in [0.7, 1.0] as [CGFloat] {
                ThemeRuntime.scale = scale
                for (stored, shown) in [("high", "high"), ("", "Claude Code picks")] {
                    Preferences.agentIslandDefaultEffort = stored
                    func effort(_ t: [AXTreeNode]) -> AXTreeNode? {
                        t.first { $0.named("Default effort") && $0.role != "AXStaticText" && $0.named(shown) }
                    }
                    func model(_ t: [AXTreeNode]) -> AXTreeNode? { t.first { $0.label == "Default model" && $0.role == "AXTextField" } }
                    func pairs(_ t: [AXTreeNode]) -> AXTreeNode? { t.first { $0.label == "Sidekick suffix" && $0.role == "AXTextField" } }
                    let size = CGSize(width: sz(560), height: sz(1000))
                    let tree = AXTreeSupport.tree(AgentIslandPane().frame(width: size.width).preferredColorScheme(.dark), size) {
                        effort($0) != nil && model($0) != nil && pairs($0) != nil
                    }
                    let e = effort(tree), m = model(tree), p = pairs(tree)
                    if e == nil {   // only on failure: what the tree held, for the log
                        print("#1454 FRAMES \(stored) at \(scale): " + tree.filter { !($0.label + $0.title + $0.value).isEmpty }
                            .map { "\($0.role)|\($0.label)|\($0.title)|\($0.value)" }.joined(separator: " ; "))
                    }
                    XCTAssertTrue(e != nil, "the effort picker, named, showing \(shown) at \(scale)")
                    XCTAssertTrue(tree.contains { $0.role == "AXStaticText" && $0.named("Default effort") }, "the row's title at \(scale)")
                    XCTAssertEqual(m?.value, "claude-example-1", "the Default model field as before at \(scale)")
                    guard let ef = e?.frame, let mf = m?.frame, let pf = p?.frame else { continue }
                    XCTAssertGreaterThan((mf.midY - ef.midY) * (ef.midY - pf.midY), 0,
                                         "between Default model and the Pairs field at \(scale)")
                }
            }
        }
    }
}

/// #1454: the window's New session form shows and starts the Default effort; a typed one wins; the sidekick gets it.
extension AgentWindowD1Tests {
    @MainActor
    func testAgentWindowNewSessionShowsAndStartsTheDefaultEffortTypedWins() throws {
        try withNewSessionPrefs {
            Preferences.agentIslandNewSessionCommand = "claude --chrome"
            Preferences.agentIslandDefaultModel = "claude-example-1"
            Preferences.agentIslandDefaultEffort = "high"
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSession?.command, "claude --chrome", "the typed text never gets the flag")
            XCTAssertEqual(m.newSessionRuns, "claude --name api --model claude-example-1 --effort high --chrome")
            m.setNewSessionCommand("claude --effort low")
            XCTAssertEqual(m.newSessionRuns, "claude --name api --model claude-example-1 --effort low", "a typed --effort wins")
            m.setNewSessionCommand("claude --effort=max")
            XCTAssertEqual(m.newSessionRuns, "claude --name api --model claude-example-1 --effort=max", "a typed --effort= wins")
            m.setNewSessionCommand("claude --chrome")
            let runs = m.newSessionRuns
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(spawns.calls.count, 1)
            let argv = spawns.calls.last?.argv ?? []
            XCTAssertEqual(argv, ["claude", "--model", "claude-example-1", "--effort", "high", "--chrome"])
            XCTAssertEqual(argv.filter { $0 == "--effort" }.count, 1, "the flag once")
            XCTAssertEqual(AgentIsland.shellLine(AgentIsland.naming(argv, name: "api")), runs, "what starts is what was shown")
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --chrome", "the saved command never takes the flag")
        }
    }

    @MainActor
    func testAgentWindowNewSessionDefaultEffortReachesTheSidekick() throws {
        try withNewSessionPrefs {
            Preferences.agentIslandDefaultEffort = "max"
            let st = store([]), spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(st, spawns, says)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude --chrome")
            m.setNewSessionSidekick(true)
            XCTAssertTrue(m.startNewSession())
            spawns.done.first?(spawnKey("api"), nil)
            XCTAssertEqual(spawns.calls.map(\.name), ["api", "api-qa"], "the main, then the sidekick")
            XCTAssertEqual(spawns.calls.first?.argv, ["claude", "--effort", "max", "--chrome"], "the main gets it")
            XCTAssertEqual(spawns.calls.last?.argv, ["claude", "--effort", "max", "--chrome"], "the sidekick gets it")
            spawns.done.last?(spawnKey("api-qa"), nil)
        }
    }
}
