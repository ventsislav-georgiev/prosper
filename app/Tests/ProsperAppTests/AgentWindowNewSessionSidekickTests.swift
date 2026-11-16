import XCTest
@testable import ProsperApp

/// #907 (#847 P1d part 1): the New session form's sidekick and first prompt, on the model. No dch runs: both spawns
/// go to the `spawnSession` recorder, the first messages to a `sayFirst` recorder (its `then` is run by the test, as
/// the controller would). Preferences are the XCTest in-memory store, saved and restored per test.
extension AgentWindowD1Tests {

    final class SayCalls {
        var calls: [(key: AgentSessionKey, text: String, then: (@MainActor () -> Void)?)] = []
    }

    @MainActor
    func sidekickModel(_ st: AgentIslandStore, _ spawns: SpawnCalls, _ says: SayCalls) -> AgentWindowModel {
        let m = newSessionModel(st, spawns)
        m.sayFirst = { key, text, then in says.calls.append((key, text, then)) }
        return m
    }

    func spawnKey(_ name: String) -> AgentSessionKey { AgentSessionKey(dir: "/tmp/dch-test", name: name) }

    /// No spawn argv ever carries the prompt (S4, D7.1).
    func assertNoPrompt(_ spawns: SpawnCalls, _ prompt: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(spawns.calls.contains { $0.argv.contains { $0.contains(prompt) } }, "prompt in an argv", file: file, line: line)
    }

    /// T19: box off, one spawn (P1a); box on, main then main + suffix, same folder and argv, one after the other.
    @MainActor
    func testAgentWindowNewSessionSidekickSpawnsMainThenSidekickSameFolderAndArgv() throws {
        try withNewSessionPrefs {
            do {
                let st = store([]), spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(st, spawns, says)
                defer { m.close() }
                m.openNewSession(folder: "/Users/example/api")
                XCTAssertEqual(m.newSession?.sidekick, false, "off on every open")
                XCTAssertTrue(m.startNewSession())
                spawns.done.first?(spawnKey("api"), nil)
                XCTAssertEqual(spawns.calls.map(\.name), ["api"], "box off: one spawn")
                XCTAssertEqual(m.pendingSpawn?.key, spawnKey("api"))
                XCTAssertTrue(says.calls.isEmpty, "no prompt, no sidekick: no first message")
            }
            let st = store([]), spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(st, spawns, says)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude --chrome")
            m.setNewSessionSidekick(true)
            m.setNewSessionPrompt("fix the login bug")
            XCTAssertEqual(m.newSession?.sidekick, true)
            XCTAssertEqual(m.newSessionSidekickName, "api-qa", "the main name and the default suffix")
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(spawns.calls.map(\.name), ["api"], "the main first, alone")
            XCTAssertEqual(m.newSessionStatus, "Starting api\u{2026}")
            spawns.done.first?(spawnKey("api"), nil)
            XCTAssertEqual(spawns.calls.map(\.name), ["api", "api-qa"], "then the sidekick")
            XCTAssertEqual(spawns.calls.first?.folder, "/Users/example/api")
            XCTAssertEqual(spawns.calls.last?.folder, "/Users/example/api", "same folder")
            XCTAssertEqual(spawns.calls.first?.argv, ["claude", "--chrome"])
            XCTAssertEqual(spawns.calls.last?.argv, ["claude", "--chrome"], "same argv")
            XCTAssertEqual(m.newSessionStatus, "Starting api-qa\u{2026}")
            XCTAssertFalse(m.canStartNewSession, "fields stay off until both answer")
            XCTAssertTrue(m.pendingSpawn == nil, "nothing lands before the sidekick answers")
            XCTAssertTrue(says.calls.isEmpty, "no message before both answered")
            spawns.done.last?(spawnKey("api-qa"), nil)
            XCTAssertEqual(m.pendingSpawn?.key, spawnKey("api"), "the MAIN row is the one selected")
            XCTAssertEqual(spawns.calls.count, 2)
            assertNoPrompt(spawns, "login bug")
            st.sessions = [mapped("api"), mapped("api-qa")]
            XCTAssertTrue(m.newSession == nil, "the main's row lands: the form closes")
            XCTAssertEqual(m.selection, .live(spawnKey("api")))
        }
    }

    /// T20: the main fails: one spawn, the form re-enabled with dch's line and its text, no first message.
    @MainActor
    func testAgentWindowNewSessionSidekickMainFailureSpawnsNothingElse() throws {
        try withNewSessionPrefs {
            let st = store([]), spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(st, spawns, says)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionSidekick(true)
            m.setNewSessionPrompt("fix the login bug")
            XCTAssertTrue(m.startNewSession())
            let failed = "New session failed: dch: api: claude: No such file or directory"
            spawns.done.first?(nil, failed)
            XCTAssertEqual(spawns.calls.map(\.name), ["api"], "nothing else runs")
            XCTAssertTrue(m.newSession?.starting == nil, "the form re-enables")
            XCTAssertEqual(m.newSessionStatus, failed)
            XCTAssertEqual(m.newSession?.prompt, "fix the login bug", "the text stays")
            XCTAssertEqual(m.newSession?.sidekick, true)
            XCTAssertEqual(m.lastPrompt, "fix the login bug")
            XCTAssertTrue(m.canStartNewSession)
            XCTAssertTrue(says.calls.isEmpty)
            XCTAssertTrue(m.pendingSpawn == nil)
        }
    }

    /// T21: the sidekick fails: the main runs on and is selected, its prompt still goes out, the dir line names
    /// which one failed; a refused (busy) sidekick is the same failure at once.
    @MainActor
    func testAgentWindowNewSessionSidekickFailureKeepsTheMainAndSaysWhichFailed() throws {
        try withNewSessionPrefs {
            let st = store([]), spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(st, spawns, says)
            defer { m.close() }
            let line = AgentSessionKey(dir: m.island().spawnDir(), name: "")
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionSidekick(true)
            m.setNewSessionPrompt("fix the login bug")
            XCTAssertTrue(m.startNewSession())
            spawns.done.first?(spawnKey("api"), nil)
            spawns.done.last?(nil, "New session failed: dch: api-qa: exists")
            XCTAssertEqual(st.actions[line], "api started; sidekick api-qa failed: dch: api-qa: exists")
            XCTAssertEqual(m.pendingSpawn?.key, spawnKey("api"))
            XCTAssertEqual(says.calls.count, 1, "the main's message only")
            XCTAssertEqual(says.calls.first?.key, spawnKey("api"))
            XCTAssertEqual(says.calls.first?.text, "fix the login bug")
            XCTAssertTrue(says.calls.first?.then == nil, "no sidekick message after it")
            st.sessions = [mapped("api")]
            XCTAssertTrue(m.newSession == nil, "the form closes")
            XCTAssertEqual(m.selection, .live(spawnKey("api")))
            assertNoPrompt(spawns, "login bug")
            // The runner refuses the second spawn (busy): the same line at once, the form still goes the main's way.
            let spawns2 = SpawnCalls(), says2 = SayCalls(), m2 = sidekickModel(store([]), spawns2, says2)
            defer { m2.close() }
            m2.openNewSession(folder: "/Users/example/web")
            m2.setNewSessionSidekick(true)
            XCTAssertTrue(m2.startNewSession())
            spawns2.accept = false
            spawns2.done.first?(spawnKey("web"), nil)
            XCTAssertEqual(spawns2.calls.map(\.name), ["web", "web-qa"])
            XCTAssertEqual(m2.store?.actions[line], "web started; sidekick web-qa failed: web-qa is busy: try again")
            XCTAssertEqual(m2.pendingSpawn?.key, spawnKey("web"))
            XCTAssertTrue(m2.newSession?.startingSidekick == nil)
            XCTAssertTrue(says2.calls.isEmpty, "blank prompt, no sidekick: nothing to say")
        }
    }

    /// T22: sayFirst(main, prompt), then the sidekick's rendered Settings prompt; a blank prompt: the sidekick's only;
    /// no sidekick: the main's only. The prompt is in no argv.
    @MainActor
    func testAgentWindowNewSessionSidekickFirstMessagesChainMainThenSidekick() throws {
        try withNewSessionPrefs {
            @MainActor func run(prompt: String, sidekick: Bool, _ check: (SpawnCalls, SayCalls) -> Void) {
                let spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(store([]), spawns, says)
                defer { m.close() }
                m.openNewSession(folder: "/Users/example/api")
                m.setNewSessionSidekick(sidekick)
                m.setNewSessionPrompt(prompt)
                XCTAssertTrue(m.startNewSession())
                spawns.done.first?(spawnKey("api"), nil)
                if sidekick { spawns.done.last?(spawnKey("api-qa"), nil) }
                check(spawns, says)
            }
            run(prompt: "fix the login bug", sidekick: true) { spawns, says in
                XCTAssertEqual(says.calls.count, 1, "the main's first; the sidekick's waits for it")
                XCTAssertEqual(says.calls.first?.key, spawnKey("api"))
                XCTAssertEqual(says.calls.first?.text, "fix the login bug")
                says.calls.first?.then?()
                XCTAssertEqual(says.calls.count, 2)
                XCTAssertEqual(says.calls.last?.key, spawnKey("api-qa"))
                XCTAssertEqual(says.calls.last?.text, AgentNewSession.render(AgentNewSession.sidekickPromptDefault, name: "api"))
                XCTAssertTrue(says.calls.last?.text.contains("dch --read api --recent 500") == true)
                XCTAssertTrue(says.calls.last?.then == nil)
                assertNoPrompt(spawns, "login bug")
            }
            Preferences.agentIslandSidekickPrompt = "  check $name's work  "
            run(prompt: " \n ", sidekick: true) { _, says in
                XCTAssertEqual(says.calls.count, 1, "blank prompt: the sidekick's only")
                XCTAssertEqual(says.calls.first?.key, spawnKey("api-qa"))
                XCTAssertEqual(says.calls.first?.text, "check api's work", "the Settings prompt, trimmed, rendered")
            }
            run(prompt: "fix the login bug", sidekick: false) { spawns, says in
                XCTAssertEqual(says.calls.count, 1)
                XCTAssertEqual(says.calls.first?.key, spawnKey("api"))
                XCTAssertTrue(says.calls.first?.then == nil, "no sidekick, nothing after")
                assertNoPrompt(spawns, "login bug")
            }
        }
    }

    /// T23: the sidekick's slot: a case-folded taken or too long sidekick name, or an unusable suffix (#909's rule),
    /// turns Start off and runs nothing; with the box on the automatic main name leaves its sidekick free (D3.4).
    @MainActor
    func testAgentWindowNewSessionSidekickNameCheckedAtStart() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = sidekickModel(store([mapped("API-QA")]), spawns, SayCalls())
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSessionName, "api", "box off: P1a's name")
            XCTAssertTrue(m.newSessionErrors.sidekick == nil)
            m.setNewSessionSidekick(true)
            XCTAssertEqual(m.newSessionName, "api-2", "box on: api's sidekick API-QA is taken, so the next one")
            XCTAssertTrue(m.newSessionErrors.sidekick == nil)
            m.setNewSessionName("api")
            XCTAssertEqual(m.newSessionErrors.sidekick, "API-QA is taken", "typed: never re-picked, the slot says why")
            XCTAssertTrue(m.newSessionErrors.name == nil)
            XCTAssertFalse(m.canStartNewSession)
            XCTAssertFalse(m.startNewSession())
            m.setNewSessionName(String(repeating: "a", count: 62))
            XCTAssertTrue(m.newSessionErrors.name == nil, "62 fits")
            XCTAssertEqual(m.newSessionErrors.sidekick, "64 characters at most", "65 does not")
            XCTAssertFalse(m.startNewSession())
            m.setNewSessionName("web")
            for bad in ["", "-", "-1", "a/b"] {
                Preferences.agentIslandSidekickSuffix = bad
                XCTAssertEqual(m.newSessionErrors.sidekick, "Sidekick suffix in Settings isn't usable", bad.debugDescription)
                XCTAssertFalse(m.startNewSession(), bad.debugDescription)
            }
            Preferences.agentIslandSidekickSuffix = "-rev2"
            XCTAssertTrue(m.newSessionErrors.sidekick == nil, "#909: digits with a letter are fine")
            XCTAssertEqual(m.newSessionSidekickName, "web-rev2")
            XCTAssertEqual(spawns.calls.count, 0, "an invalid Start runs nothing")
            Preferences.agentIslandSidekickSuffix = "-"
            m.setNewSessionSidekick(false)
            XCTAssertTrue(m.newSessionErrors.sidekick == nil, "box off: the suffix is not read")
            XCTAssertTrue(m.canStartNewSession)
        }
    }

    /// T24: no Claude to name or brief (empty, another program, a batch run): the box stays off, and a box checked
    /// before the command changed is ignored at Start with the prompt (kept for later).
    @MainActor
    func testAgentWindowNewSessionSidekickNeedsAnInteractiveClaude() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), says = SayCalls(), m = sidekickModel(store([]), spawns, says)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            for c in ["", "node x.js", "claude -p hi", "claude mcp list"] {
                m.setNewSessionCommand(c)
                XCTAssertFalse(m.newSessionClaude, c)
                m.setNewSessionSidekick(true)
                XCTAssertEqual(m.newSession?.sidekick, false, c)
            }
            m.setNewSessionCommand("headroom wrap claude --chrome")
            XCTAssertTrue(m.newSessionClaude)
            m.setNewSessionSidekick(true)
            m.setNewSessionPrompt("fix the login bug")
            m.setNewSessionCommand("node x.js")
            Preferences.agentIslandSidekickSuffix = "-"
            XCTAssertTrue(m.newSessionErrors.sidekick == nil, "ignored: not read")
            XCTAssertTrue(m.startNewSession())
            spawns.done.first?(spawnKey("api"), nil)
            XCTAssertEqual(spawns.calls.map(\.name), ["api"], "no sidekick")
            XCTAssertTrue(says.calls.isEmpty, "no first message")
            XCTAssertEqual(m.lastPrompt, "fix the login bug", "not taken by this start: kept")
            assertNoPrompt(spawns, "login bug")
        }
    }

    /// T25: the form's New shell would drop a checked box or a typed prompt: refused while either holds.
    @MainActor
    func testAgentWindowNewSessionSidekickNewShellRefusedWhileBoxOrPromptHolds() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = sidekickModel(store([]), spawns, SayCalls())
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertTrue(m.newSessionShellRefusal == nil)
            m.setNewSessionSidekick(true)
            XCTAssertEqual(m.newSessionShellRefusal, "Clear the prompt and sidekick to start a plain shell")
            XCTAssertFalse(m.startShell())
            m.setNewSessionSidekick(false)
            m.setNewSessionPrompt("x")
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(spawns.calls.count, 0)
            m.setNewSessionPrompt("")
            XCTAssertTrue(m.startShell())
            XCTAssertEqual(spawns.calls.first?.argv, ["/bin/fish", "-l"])
        }
    }

    /// T26: Cancel keeps the prompt for the next open (shown); a Start that takes it drops it.
    @MainActor
    func testAgentWindowNewSessionSidekickLastPromptSurvivesCancelNotAStart() throws {
        try withNewSessionPrefs {
            let st = store([]), spawns = SpawnCalls(), m = sidekickModel(st, spawns, SayCalls())
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSession?.promptShown, false, "collapsed with nothing kept")
            m.toggleNewSessionPrompt()
            XCTAssertEqual(m.newSession?.promptShown, true)
            m.setNewSessionPrompt("two\nlines")
            m.setNewSessionSidekick(true)
            m.cancelNewSession()
            XCTAssertEqual(m.lastPrompt, "two\nlines")
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSession?.prompt, "two\nlines")
            XCTAssertEqual(m.newSession?.promptShown, true, "open with a kept prompt")
            XCTAssertEqual(m.newSession?.sidekick, false, "the box is not remembered")
            XCTAssertTrue(m.startNewSession())
            spawns.done.first?(spawnKey("api"), nil)
            XCTAssertEqual(m.lastPrompt, "", "taken by the start")
            st.sessions = [mapped("api")]
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSession?.prompt, "")
            XCTAssertEqual(m.newSession?.promptShown, false)
        }
    }

    /// T27: after any Start the command setting holds neither --name nor prompt text, and no prompt is stored.
    @MainActor
    func testAgentWindowNewSessionSidekickSettingNeverHoldsNameOrPrompt() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = sidekickModel(store([]), spawns, SayCalls())
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude --name x --chrome")
            m.setNewSessionSidekick(true)
            m.setNewSessionPrompt("secret task text")
            XCTAssertTrue(m.startNewSession())
            spawns.done.first?(spawnKey("api"), nil)
            spawns.done.last?(spawnKey("api-qa"), nil)
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --chrome")
            XCTAssertTrue(Preferences.defaults.object(forKey: "agentIslandSidekickPrompt") == nil, "the Settings prompt untouched")
            for k in Self.newSessionPrefs {
                let v = Preferences.defaults.object(forKey: k) as? String ?? ""
                XCTAssertFalse(v.contains("secret task") || v.contains("--name"), k)
            }
            assertNoPrompt(spawns, "secret task")
        }
    }
}
