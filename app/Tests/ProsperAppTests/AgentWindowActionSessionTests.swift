import Combine
import XCTest
@testable import ProsperApp

/// #1202 (R899-7, R1193-2): Agent Sessions panes. An action runs on the focused pane resolved at action time, never on
/// the session the input last followed; a dropped transcript model starts the next session clean; the focused pane
/// leaving Ended with its row unchanged tells the window model's observers.
/// Fakes only: /tmp/dch-test sessions, a fake dch recorder, no window shown, no event posted.
extension AgentWindowD1Tests {
    /// A visible model whose focused pane shows "a", Ended (a ended while shown), and whose input last followed the
    /// OTHER live session "b" in `bState` (a stale follow, as `testAgentWindowResolveSendUsesTheFocusedPaneNow` does).
    /// `io` is the fake dch under the island controller the interaction acts through.
    @MainActor
    private func endedPaneStaleFollow(_ bState: AgentState, io: AgentPromptIO) throws
        -> (AgentWindowModel, AgentIslandController) {
        let url = tempDir().appendingPathComponent("a.jsonl")
        try write(url, [say("from a")])
        let st = store([session("a", .idle, path: url.path), session("b", bState)])
        let m = windowModel(st)
        m.setVisible(true)
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        st.sessions = st.sessions   // a poll while a shows
        st.sessions = [session("b", bState)]
        XCTAssertTrue(m.focusedEnded)
        let c = AgentIslandController()
        c.io = io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: Self.geometry)
        c.autoAllowOn = { false }
        c.after = { _, _ in }
        c.onSessions = { _ in }
        m.interaction.controller = c
        m.interaction.pause = { _ in }
        m.interaction.readQueue = { $0() }
        m.interaction.follow(session("b", bState))   // the stale follow: the focused pane is the Ended a
        return (m, c)
    }

    /// A choose prompt on the last followed "b" while the focused pane is Ended: an answer goes nowhere (the fake dch
    /// sees no verb); the control with the resolve seam off reaches b, so the setup does answer.
    @MainActor
    func testAgentWindowAnswerNeverGoesToTheLastFollowedSessionWhenTheFocusedPaneIsEnded() throws {
        let f = AgentWindowInteractionTests.FormSim(.plain(AgentWindowInteractionTests.permission()))
        let (m, _) = try endedPaneStaleFollow(.blocked, io: f.io)
        defer { m.close() }
        let i = m.interaction
        guard case .prompt(let w) = i.panel else { return XCTFail("\(i.panel)") }
        let option = try XCTUnwrap(w.buttons.first)
        XCTAssertTrue(w.enabled.contains(option.digit))
        i.answer(option)
        XCTAssertFalse(i.busy, "nothing was sent for the last followed session")
        XCTAssertEqual(f.lock.withLock { f.log }, [], "the fake dch got no verb")
        let resolve = i.resolveFocused
        i.resolveFocused = nil   // control: the followed session as is
        i.answer(option)
        let deadline = Date().addingTimeInterval(5)
        while f.lock.withLock({ f.log.isEmpty }), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(f.lock.withLock { f.log }, ["send \(option.digit)"], "control: the answer reaches b")
        i.resolveFocused = resolve
    }

    /// Interrupt with the focused pane Ended and the last followed "b" working: nothing is sent; the control reaches b.
    @MainActor
    func testAgentWindowInterruptNeverGoesToTheLastFollowedSessionWhenTheFocusedPaneIsEnded() throws {
        let f = AgentWindowInteractionTests.MessageFake(statuses: ["working", "working", "idle"])
        let (m, _) = try endedPaneStaleFollow(.working, io: f.io)
        defer { m.close() }
        let i = m.interaction
        i.interrupt()
        XCTAssertFalse(i.busy, "nothing was started for the last followed session")
        XCTAssertEqual(f.lock.withLock { f.keys }, [], "the fake dch got no key")
        let resolve = i.resolveFocused
        i.resolveFocused = nil   // control: the followed session as is
        i.interrupt()
        let deadline = Date().addingTimeInterval(5)
        while f.lock.withLock({ f.keys.isEmpty }), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(f.lock.withLock { f.keys }, [["esc"]], "control: the Esc reaches b")
        i.resolveFocused = resolve
    }

    /// S2: drop() resets the per-session view state, so the next session started on the model reads the initial values.
    /// `nullSince` is private and no view-facing value differs after a drop (the mode of a model with no tail reads the
    /// same with or without it), so only `showAnyway` and `todosOpen` are observed; see left.txt.
    @MainActor
    func testAgentTranscriptDropResetsShowAnywayAndTodosOpenForTheNextSession() {
        let t = AgentTranscriptModel()
        t.offMain = { $0() }
        t.makeWatch = { _, _ in nil }
        func source(_ name: String) -> AgentTranscriptSource {
            AgentTranscriptSource(key: AgentSessionKey(dir: "/tmp/dch-test", name: name), dchVersion: "1.30.0",
                                  dchState: "idle", sessionId: nil, transcriptPath: nil)
        }
        t.update(source("a"))
        t.showAnyway = true
        t.todosOpen = true
        t.drop()
        t.update(source("b"))   // the model had no source: update() resets nothing itself
        XCTAssertFalse(t.showAnyway, "the next session starts terminal-first again")
        XCTAssertFalse(t.todosOpen, "the next session starts with the task list closed")
    }

    /// R1193-2: the focused pane leaves Ended with its row unchanged (an emptying select(nil): the row is nil before and
    /// after): the model's observers are told (the view reads focusedEnded), once.
    @MainActor
    func testAgentWindowTheFocusedPaneLeavingEndedWithTheRowUnchangedTellsTheModelsObservers() throws {
        let url = tempDir().appendingPathComponent("a.jsonl")
        try write(url, [say("from a")])
        let st = store([session("a", .idle, path: url.path), session("b", .idle)])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        st.sessions = st.sessions
        st.sessions = [session("b", .idle)]
        XCTAssertTrue(m.focusedEnded)
        XCTAssertNil(m.selection, "an Ended pane resolves to no row")
        var notices = 0
        let sub = m.objectWillChange.sink { notices += 1 }
        m.select(nil, manual: false)   // manual would write the @Published newSession and notice by itself
        sub.cancel()
        XCTAssertFalse(m.focusedEnded)
        XCTAssertNil(m.selection, "the row is unchanged")
        XCTAssertEqual(notices, 1, "told, once, even though no @Published value of the model changed")
    }
}
