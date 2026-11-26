import XCTest
@testable import ProsperApp

/// #907 (#847 P1d part 1): the New session form's first prompt, on the model (#1820: the sidekick box is gone). No dch
/// runs: the spawn goes to the `spawnSession` recorder, the first message to a `sayFirst` recorder. Preferences are the
/// XCTest in-memory store, saved and restored per test.
extension AgentWindowD1Tests {

    final class SayCalls {
        var calls: [(key: AgentSessionKey, text: String, codex: Bool, then: (@MainActor (String?) -> Void)?)] = []
    }

    @MainActor
    func sidekickModel(_ st: AgentIslandStore, _ spawns: SpawnCalls, _ says: SayCalls) -> AgentWindowModel {
        let m = newSessionModel(st, spawns)
        m.sayFirst = { key, text, codex, then in says.calls.append((key, text, codex, then)) }
        return m
    }

    func spawnKey(_ name: String) -> AgentSessionKey { AgentSessionKey(dir: "/tmp/dch-test", name: name) }

    /// No spawn argv ever carries the prompt (S4, D7.1).
    func assertNoPrompt(_ spawns: SpawnCalls, _ prompt: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(spawns.calls.contains { $0.argv.contains { $0.contains(prompt) } }, "prompt in an argv", file: file, line: line)
    }

    /// T19/T22 (#1820): one spawn, never a second one; a typed prompt is the main's first message, nothing after it; a
    /// blank prompt says nothing. The prompt is in no argv. Red at base with the box on: two spawns ("api", "api-qa").
    @MainActor
    func testAgentWindowNewSessionOneSpawnAndThePromptIsTheOnlyFirstMessage() throws {
        try withNewSessionPrefs {
            @MainActor func run(prompt: String, _ check: (SpawnCalls, SayCalls) -> Void) {
                let spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(store([]), spawns, says)
                defer { m.close() }
                m.openNewSessionNamed(folder: "/Users/example/api")
                m.setNewSessionPrompt(prompt)
                XCTAssertTrue(m.startNewSession())
                spawns.done.first?(spawnKey("api"), nil)
                XCTAssertEqual(spawns.calls.map(\.name), ["api"], "one spawn")
                XCTAssertEqual(m.pendingSpawn?.key, spawnKey("api"), "it lands at once")
                check(spawns, says)
            }
            run(prompt: "fix the login bug") { spawns, says in
                XCTAssertEqual(says.calls.count, 1)
                XCTAssertEqual(says.calls.first?.key, spawnKey("api"))
                XCTAssertEqual(says.calls.first?.text, "fix the login bug")
                XCTAssertTrue(says.calls.first?.then == nil, "nothing after it")
                assertNoPrompt(spawns, "login bug")
            }
            run(prompt: " \n ") { _, says in XCTAssertTrue(says.calls.isEmpty, "blank prompt: no first message") }
        }
    }

    /// T24: no Claude to name or brief (empty, another program, a batch run): the prompt is ignored at Start (kept for later).
    @MainActor
    func testAgentWindowNewSessionPromptNeedsAnInteractiveClaude() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(store([]), spawns, says)
            defer { m.close() }
            m.openNewSessionNamed(folder: "/Users/example/api")
            for c in ["", "node x.js", "claude -p hi", "claude mcp list"] {
                m.setNewSessionCommand(c)
                XCTAssertFalse(m.newSessionClaude, c)
            }
            m.setNewSessionCommand("headroom wrap claude --chrome")
            XCTAssertTrue(m.newSessionClaude)
            m.setNewSessionPrompt("fix the login bug")
            m.setNewSessionCommand("node x.js")
            XCTAssertTrue(m.startNewSession())
            spawns.done.first?(spawnKey("api"), nil)
            XCTAssertEqual(spawns.calls.map(\.name), ["api"])
            XCTAssertTrue(says.calls.isEmpty, "no first message")
            XCTAssertEqual(m.lastPrompt, "fix the login bug", "not taken by this start: kept")
            assertNoPrompt(spawns, "login bug")
        }
    }

    /// #1992: the form's prompt gate for codex vs a shell vs claude: an interactive Codex takes the prompt (sayFirst with
    /// codex true, no --name in its argv), a Claude takes it with codex false, a shell, `codex exec` and `env X=1 codex`
    /// (no Codex TUI by dch's rule) do not. New shell is refused while a Codex's prompt holds. Red at base: newSessionCodex is new, and a
    /// codex Start said nothing (prompt: newSessionClaude ? f.prompt : "").
    @MainActor
    func testAgentWindowNewSessionCodexTakesTheFirstPrompt() throws {
        try withNewSessionPrefs {
            @MainActor func start(_ command: String) -> (SpawnCalls, SayCalls, AgentWindowModel) {
                let spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(store([]), spawns, says)
                m.openNewSessionNamed(folder: "/Users/example/api")
                m.setNewSessionCommand(command)
                m.setNewSessionPrompt("fix the login bug")
                XCTAssertTrue(m.startNewSession(), command)
                spawns.done.first?(spawnKey("api"), nil)
                return (spawns, says, m)
            }
            for (command, says, codex) in [("codex", 1, true), ("headroom wrap codex --full-auto", 1, true), ("claude", 1, false),
                                           ("codex exec hi", 0, false), ("/bin/zsh", 0, false), ("env X=1 codex", 0, false)] {
                let (sp, sa, m) = start(command)
                defer { m.close() }
                XCTAssertEqual(sa.calls.count, says, command)
                XCTAssertEqual(sa.calls.first?.codex, says == 1 ? codex : nil, command)
                XCTAssertEqual(sa.calls.first?.text, says == 1 ? "fix the login bug" : nil, command)
                if codex { XCTAssertFalse(sp.calls.first?.argv.contains("--name") ?? true, "no --name for a Codex: \(command)") }
                assertNoPrompt(sp, "login bug")
            }
            let spawns = SpawnCalls(), m = sidekickModel(store([]), spawns, SayCalls())
            defer { m.close() }
            m.openNewSessionNamed(folder: "/Users/example/api")
            m.setNewSessionCommand("codex")
            XCTAssertTrue(m.newSessionCodex && m.newSessionTakesPrompt && !m.newSessionClaude)
            m.setNewSessionPrompt("x")
            XCTAssertEqual(m.newSessionShellRefusal, AgentWindowModel.plainShellRefusal, "a Codex's prompt would be dropped too")
            m.setNewSessionCommand("/bin/zsh")
            XCTAssertFalse(m.newSessionTakesPrompt)
            XCTAssertTrue(m.newSessionShellRefusal == nil)
        }
    }

    /// T25: the form's New shell would drop a typed prompt: refused while it holds (#1820: the words name the prompt only).
    @MainActor
    func testAgentWindowNewSessionNewShellRefusedWhilePromptHolds() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = sidekickModel(store([]), spawns, SayCalls())
            defer { m.close() }
            m.openNewSessionNamed(folder: "/Users/example/api")
            XCTAssertTrue(m.newSessionShellRefusal == nil)
            m.setNewSessionPrompt("x")
            XCTAssertEqual(m.newSessionShellRefusal, "Clear the prompt to start a plain shell")
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(spawns.calls.count, 0)
            m.setNewSessionPrompt("")
            XCTAssertTrue(m.startShell())
            XCTAssertEqual(spawns.calls.first?.argv, ["/bin/fish", "-l"])
        }
    }

    /// T26: Cancel keeps the prompt for the next open; a Start that takes it drops it. #1822: no collapse state to check.
    @MainActor
    func testAgentWindowNewSessionLastPromptSurvivesCancelNotAStart() throws {
        try withNewSessionPrefs {
            let st = store([]), spawns = SpawnCalls(), m = sidekickModel(st, spawns, SayCalls())
            defer { m.close() }
            m.openNewSessionNamed(folder: "/Users/example/api")
            XCTAssertEqual(m.newSession?.prompt, "", "nothing kept")
            m.setNewSessionPrompt("two\nlines")
            m.cancelNewSession()
            XCTAssertEqual(m.lastPrompt, "two\nlines")
            m.openNewSessionNamed(folder: "/Users/example/api")
            XCTAssertEqual(m.newSession?.prompt, "two\nlines")
            XCTAssertTrue(m.startNewSession())
            spawns.done.first?(spawnKey("api"), nil)
            XCTAssertEqual(m.lastPrompt, "", "taken by the start")
            st.sessions = [mapped("api")]
            m.openNewSessionNamed(folder: "/Users/example/api")
            XCTAssertEqual(m.newSession?.prompt, "")
        }
    }

    /// T27: after any Start the command setting holds neither --name nor prompt text, and no prompt is stored; #1820: an
    /// old stored sidekick suffix and prompt (keys no longer read) neither crash the form nor start a second session.
    @MainActor
    func testAgentWindowNewSessionSettingNeverHoldsNameOrPromptAndOldPairKeysAreIgnored() throws {
        try withNewSessionPrefs {
            Preferences.defaults.set("-qa", forKey: "agentIslandSidekickSuffix")
            Preferences.defaults.set("check $name", forKey: "agentIslandSidekickPrompt")
            let spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(store([]), spawns, says)
            defer { m.close() }
            m.openNewSessionNamed(folder: "/Users/example/api")
            m.setNewSessionCommand("claude --name x --chrome")
            m.setNewSessionPrompt("secret task text")
            XCTAssertTrue(m.startNewSession())
            spawns.done.first?(spawnKey("api"), nil)
            XCTAssertEqual(spawns.calls.map(\.name), ["api"], "no sidekick from an old stored suffix")
            XCTAssertEqual(says.calls.map(\.text), ["secret task text"], "no sidekick brief")
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --chrome")
            XCTAssertEqual(Preferences.defaults.string(forKey: "agentIslandSidekickPrompt"), "check $name", "left as stored")
            for k in Self.newSessionPrefs where !k.hasPrefix("agentIslandSidekick") {
                let v = Preferences.defaults.object(forKey: k) as? String ?? ""
                XCTAssertFalse(v.contains("secret task") || v.contains("--name"), k)
            }
            assertNoPrompt(spawns, "secret task")
        }
    }
}
