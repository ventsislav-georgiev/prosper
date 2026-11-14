import XCTest
@testable import ProsperApp

/// #831 B1 step 1: the focused pane is resolve-driven (4.3), an ended session's pane keeps its blocks (4.4 M1).
/// Fakes only: /tmp/dch-test sessions, transcripts under tempDir(), no dch, no window shown.
extension AgentWindowD1Tests {
    /// A visible model on one session "a" whose transcript holds one block, stamped live by a publish (4.1a).
    @MainActor
    private func endedSetup() throws -> (AgentWindowModel, AgentIslandStore, URL) {
        let url = tempDir().appendingPathComponent("a.jsonl")
        try write(url, [say("from a")])
        let st = store([session("a", .idle, path: url.path), session("b", .idle)])
        let m = windowModel(st)
        m.setVisible(true)
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        st.sessions = st.sessions   // a poll while a shows
        XCTAssertEqual(m.transcript.blocks.count, 1)
        st.sessions = [session("b", .idle)]
        XCTAssertTrue(m.focusedEnded)
        return (m, st, url)
    }

    /// R3.5, 4.4 (b): a new session under the ended one's name is `.live` with a fresh model; the kept blocks are
    /// never started again, even before dch maps the new session's transcript.
    @MainActor
    func testAgentWindowResolveNameReuseNeverStartsTheKeptBlocks() throws {
        let (m, st, _) = try endedSetup()
        defer { m.close() }
        XCTAssertEqual(m.transcript.blocks.count, 1, "Ended: the blocks stay")
        st.sessions = [session("a", .idle), session("b", .idle)]   // same dir and name, no transcript mapped yet
        XCTAssertEqual(m.selection, .live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        XCTAssertFalse(m.focusedEnded)
        XCTAssertTrue(m.transcript.blocks.isEmpty, "none of the old instance's blocks under the new session")
        XCTAssertTrue(m.transcript.tail == nil, "the kept tail went with the kept model")
        XCTAssertTrue(m.openSelected(), "R3.5: the new session's actions work")
        XCTAssertTrue(m.transcript.running, "the new session's model runs")
    }

    /// R3.6 (hide / show half), 4.4 (c): no IO while Ended: no watch armed, no read, the blocks kept.
    @MainActor
    func testAgentWindowResolveEndedPaneDoesNoIOAcrossHideAndShow() throws {
        let (m, _, url) = try endedSetup()
        defer { m.close() }
        let arms = m.transcript.watchArms, gen = m.transcript.generation
        try append(url, line(say("after the end")))
        m.setVisible(false)
        m.setVisible(true)
        m.transcript.tick()
        XCTAssertTrue(m.focusedEnded, "shown again: still Ended")
        XCTAssertFalse(m.transcript.running)
        XCTAssertTrue(m.transcript.suspended)
        XCTAssertEqual(m.transcript.watchArms, arms, "no watch")
        XCTAssertEqual(m.transcript.generation, gen, "no re-open, no last-page read")
        XCTAssertEqual(m.transcript.blocks.count, 1, "the kept blocks, nothing read after the end")
    }

    /// R3.3 b (ids): the record of another Claude session under the name never swaps the pane; its own one does,
    /// once, and frees the kept blocks (4.4 (e)).
    @MainActor
    func testAgentWindowResolveSwapsOnlyToTheEndedInstancesOwnRecord() throws {
        let (m, st, _) = try endedSetup()
        defer { m.close() }
        var other = record("a", ago: 0)
        other.agent = DchHistoryRecord.Agent(kind: "claude", sessionID: "0b7c2f3e-9999-2222-3333-444455556666")
        st.history = [other]
        XCTAssertTrue(m.focusedEnded, "another instance's record: stays Ended")
        XCTAssertNil(m.selection)
        var own = record("a", ago: 0)
        own.agent = DchHistoryRecord.Agent(kind: "claude", sessionID: "0b7c2f3e-1111-2222-3333-444455556666")
        st.history = [own]
        XCTAssertEqual(m.selection, .history(own.id), "its own record: one swap")
        XCTAssertFalse(m.focusedEnded)
        XCTAssertTrue(m.transcript.blocks.isEmpty, "the swap frees the kept blocks")
    }

    /// R3.3 b: the same name ended twice within 65 s. X1 ends and swaps to its record R1; X2 (same dir and name, a new
    /// Claude session id) goes live in the pane with a fresh model and ends before R2 lands: with R1 alone listed the
    /// pane stays Ended with X2's blocks (R1's id differs); R2 lands: one swap, to R2, never R1.
    @MainActor
    func testAgentWindowResolveSameNameEndedTwiceSwapsToEachInstancesOwnRecord() throws {
        let (m, st, _) = try endedSetup()   // X1 ("a", id …1111) ended, its blocks kept
        defer { m.close() }
        var r1 = record("a", ago: 0)
        r1.file = "a.1700000000"   // moved aside by X2's cold start, so its id is not the bare name
        r1.agent = DchHistoryRecord.Agent(kind: "claude", sessionID: "0b7c2f3e-1111-2222-3333-444455556666")
        st.history = [r1]
        XCTAssertEqual(m.selection, .history(r1.id), "X1's own record")
        let url2 = tempDir().appendingPathComponent("a2.jsonl")
        try write(url2, [say("from x2")])
        var x2 = session("a", .idle, path: url2.path)
        x2.claudeSessionID = "0b7c2f3e-2222-2222-3333-444455556666"
        st.sessions = [x2, session("b", .idle)]   // X2 live, stamped by this publish (4.1a)
        XCTAssertEqual(m.selection, .live(x2.key))
        XCTAssertEqual(m.transcript.tail?.path, url2.path, "a fresh model on X2's transcript")
        st.sessions = [session("b", .idle)]
        XCTAssertTrue(m.focusedEnded, "R1 is X1's (its id differs): X2's pane stays Ended")
        XCTAssertNil(m.selection)
        XCTAssertEqual(m.transcript.blocks.count, 1, "X2's blocks kept")
        var r2 = record("a", ago: 0)
        r2.agent = DchHistoryRecord.Agent(kind: "claude", sessionID: "0b7c2f3e-2222-2222-3333-444455556666")
        st.history = [r1, r2]
        XCTAssertEqual(m.selection, .history(r2.id), "one swap, to X2's own record")
        XCTAssertNotEqual(r2.id, r1.id)
        XCTAssertFalse(m.focusedEnded)
    }

    /// 4.5 "ended while hidden": the window hid while the session ran (its blocks freed by `stop()`), the session
    /// ended meanwhile: shown again, nothing is kept, so the pane is not Ended (no IO to re-read it, 4.4 (c)).
    @MainActor
    func testAgentWindowResolveEndedWhileHiddenKeepsNothing() throws {
        let url = tempDir().appendingPathComponent("a.jsonl")
        try write(url, [say("from a")])
        let st = store([session("a", .idle, path: url.path), session("b", .idle)])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        st.sessions = st.sessions   // a poll while a shows
        m.setVisible(false)
        XCTAssertTrue(m.transcript.blocks.isEmpty, "hidden: freed")
        let gen = m.transcript.generation
        st.sessions = [session("b", .idle)]
        m.setVisible(true)
        XCTAssertFalse(m.focusedEnded, "nothing kept: the placeholder, not Ended")
        XCTAssertNil(m.selection)
        XCTAssertTrue(m.selectedRow == nil)
        XCTAssertFalse(m.transcript.running)
        XCTAssertFalse(m.transcript.suspended)
        XCTAssertEqual(m.transcript.generation, gen, "no re-open of the ended session's file")
        XCTAssertFalse(m.openSelected())
    }

    /// R3.3 d: a pane with no last live sight (a fresh model, as after a relaunch) never takes a record of its name.
    @MainActor
    func testAgentWindowResolveNoLastLiveSightNeverTakesARecord() throws {
        let st = store([session("b", .idle)], history: [record("a", ago: 0)])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        XCTAssertNil(m.selection, "not running, no record taken")
        XCTAssertFalse(m.focusedEnded, "nothing kept: the placeholder, not Ended")
        XCTAssertTrue(m.selectedRow == nil)
        XCTAssertFalse(m.openSelected(), "4.3: nothing opens (no `dch -n a`)")
    }

    /// 4.3: Send resolves the focused pane at action time, never the session the input last followed.
    @MainActor
    func testAgentWindowResolveSendUsesTheFocusedPaneNow() throws {
        let st = store([session("a", .idle), session("b", .working)])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        let b = try XCTUnwrap(st.sessions.first { $0.name == "b" })
        m.interaction.follow(b)   // a stale follow: the focused pane is a
        m.interaction.draft = "hi"
        m.interaction.send()
        XCTAssertTrue(m.interaction.notice == nil, "b is not the focused pane's session: nothing is checked or sent")
        let resolve = m.interaction.resolveFocused
        m.interaction.resolveFocused = nil   // control: the followed session as is
        m.interaction.send()
        XCTAssertEqual(m.interaction.notice, AgentWindowText.working, "control: the send reached b's state check")
        m.interaction.resolveFocused = resolve
    }

    /// 11.2: suspend() keeps the blocks and the offset; start() after it catches up without a re-open.
    @MainActor
    func testAgentTranscriptSuspendKeepsTheBlocksAndStartCatchesUp() throws {
        let url = tempDir().appendingPathComponent("s.jsonl")
        try write(url, [say("one")])
        let t = AgentTranscriptModel()
        t.offMain = { $0() }
        t.makeWatch = { _, _ in nil }
        t.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/tmp/dch-test", name: "s"), dchVersion: "1.30.0",
                                       dchState: "idle", sessionId: "s-1", transcriptPath: url.path))
        t.start()
        XCTAssertEqual(t.blocks.count, 1)
        let gen = t.generation
        t.suspend()
        XCTAssertFalse(t.running)
        XCTAssertTrue(t.suspended)
        XCTAssertEqual(t.blocks.count, 1, "kept")
        t.tick()
        XCTAssertEqual(t.generation, gen, "suspended: the tick does nothing")
        t.start()
        XCTAssertTrue(t.running)
        XCTAssertFalse(t.suspended)
        XCTAssertEqual(t.generation, gen, "a catch-up poll from the kept offset, not a re-open")
        XCTAssertEqual(t.blocks.count, 1)
        t.stop()
        XCTAssertTrue(t.blocks.isEmpty, "stop() still frees everything")
        XCTAssertFalse(t.suspended)
    }
}
