import Combine
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
        // Rider R899-5: a line lands while suspended; nothing reads it until start().
        try append(url, line(say("two")))
        let arms = t.watchArms
        t.tick()
        XCTAssertEqual(t.generation, gen, "suspended: the tick does nothing")
        XCTAssertEqual(t.blocks.count, 1, "suspended: the new line is not read")
        XCTAssertEqual(t.watchArms, arms, "suspended: no watch armed")
        t.start()
        XCTAssertTrue(t.running)
        XCTAssertFalse(t.suspended)
        XCTAssertEqual(t.generation, gen, "a catch-up poll from the kept offset, not a re-open")
        XCTAssertEqual(t.blocks.count, 2, "start() caught up on the line written while suspended")
        XCTAssertGreaterThan(t.watchArms, arms, "start() re-armed the watch")
        t.stop()
        XCTAssertTrue(t.blocks.isEmpty, "stop() still frees everything")
        XCTAssertFalse(t.suspended)
    }

    // MARK: - #831 B1 step 2: one runtime per pane (model only; the split gate set by the row, restored after)

    /// 15.0: multi-pane layouts exist only under the gate, which the row sets and restores to its saved value.
    @MainActor
    func splitsOn() {
        let saved = AgentPaneLayout.splitsEnabled
        AgentPaneLayout.splitsEnabled = true
        addTeardownBlock { @MainActor in AgentPaneLayout.splitsEnabled = saved }
    }

    /// A fixture layout: up to 3 panes in one row, else two rows of up to 3; the first pane focused.
    func paneLayout(_ targets: [PaneTarget?]) -> PaneLayout {
        func columns(_ ps: [Pane]) -> PaneNode {
            guard let first = ps.first else { return .leaf(Pane(id: UUID(), target: nil)) }
            if ps.count == 1 { return .leaf(first) }
            return .split(.columns, ratio: 1 / Double(ps.count), .leaf(first), columns(Array(ps.dropFirst())))
        }
        let ps = targets.map { Pane(id: UUID(), target: $0) }
        let tree: PaneNode = ps.count <= 3 ? columns(ps) : .split(.rows, ratio: 0.5, columns(Array(ps.prefix(3))), columns(Array(ps.dropFirst(3))))
        return PaneLayout(id: UUID(), name: nil, tree: tree, focused: ps.first?.id ?? UUID(), zoomed: nil)
    }

    func paneTarget(_ name: String) -> PaneTarget { .session(dir: "/tmp/dch-test", name: name) }

    /// Every pane fits (3 columns of 1000 x 500 at most): with the gate on, every pane is shown.
    static let wideArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)

    /// A transcript file under tempDir() with one line.
    func transcriptFile(_ name: String, _ entries: [[String: Any]]? = nil) throws -> URL {
        let url = tempDir().appendingPathComponent("\(name).jsonl")
        try write(url, entries ?? [say("from \(name)")])
        return url
    }

    /// The pane id showing `name`'s session in `m`'s layout.
    @MainActor
    func paneID(_ m: AgentWindowModel, _ name: String) throws -> UUID {
        try XCTUnwrap(m.layout.panes.first { $0.target == paneTarget(name) }?.id)
    }

    @MainActor
    func runtime(_ m: AgentWindowModel, _ name: String) throws -> AgentPaneRuntime {
        let id = try paneID(m, name)
        return try XCTUnwrap(m.runtimes[id])
    }

    @MainActor
    func focus(_ m: AgentWindowModel, _ name: String) throws {
        m.adopt(try m.layout.focus(try paneID(m, name)).get())
        XCTAssertEqual(m.layout.focused, try paneID(m, name))
    }

    /// R2.1 transcript rows (model half), 11.2 per pane: a shown `.live` pane of a visible window runs, a pane the
    /// gate does not show and a hidden window run nothing and hold no blocks; a History pane tails nothing. A literal
    /// table; a fresh model per row.
    @MainActor
    func testAgentWindowPanesTruthTableRunsEachShownLivePane() throws {
        let a = try transcriptFile("a"), b = try transcriptFile("b")
        let rows: [(why: String, gate: Bool, visible: Bool, running: [String: Bool])] = [
            ("gate on, visible: both live panes run, History tails nothing", true, true, ["a": true, "b": true, "h": false]),
            ("gate off (15.0): the focused pane alone", false, true, ["a": true, "b": false, "h": false]),
            ("window hidden: nothing runs", true, false, ["a": false, "b": false, "h": false]),
        ]
        splitsOn()   // saves the gate; restored after the row
        for row in rows {
            AgentPaneLayout.splitsEnabled = row.gate
            let h = record("h", ago: 600)
            let st = store([session("a", .idle, path: a.path), session("b", .idle, path: b.path)], history: [h])
            let m = windowModel(st)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b"), .history(dir: "/tmp/dch-test", id: h.id.name, seen: h.lastSeen)]))
            m.setVisible(row.visible)
            XCTAssertEqual(m.runtimes.count, 3, "one runtime per pane: \(row.why)")
            for (name, run) in row.running.sorted(by: { $0.key < $1.key }) {
                let pane = try name == "h" ? XCTUnwrap(m.layout.panes.last?.id) : paneID(m, name)
                let t = try XCTUnwrap(m.runtimes[pane]?.transcript)
                XCTAssertEqual(t.running, run, "\(name): \(row.why)")
                XCTAssertFalse(t.suspended, "\(name): nothing Ended: \(row.why)")
                XCTAssertEqual(t.blocks.isEmpty, !run, "\(name): a pane that does not run holds no blocks: \(row.why)")
            }
            m.close()
        }
    }

    /// 11.2 "focused first" and the Ended column per pane: the focused pane starts first on a show; an unfocused shown
    /// pane whose session ends keeps its blocks suspended (0 IO) while shown, not shown (the gate's reduction leaves it
    /// out) and hidden, and the other panes run on.
    @MainActor
    func testAgentWindowPanesStartFocusedFirstAndAnUnfocusedEndedPaneKeepsItsBlocks() throws {
        splitsOn()
        let a = try transcriptFile("a"), b = try transcriptFile("b")
        let st = store([session("a", .idle, path: a.path), session("b", .idle, path: b.path)])
        let m = windowModel(st)
        defer { m.close() }
        m.paneArea = Self.wideArea
        m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
        final class Log { var armed: [String] = [] }
        let log = Log()
        for name in ["a", "b"] {
            let t = try runtime(m, name).transcript
            t.makeWatch = { _, _ in log.armed.append(name); return NSObject() }
        }
        try focus(m, "b")
        m.setVisible(true)
        XCTAssertEqual(log.armed, ["b", "a"], "the focused pane starts first")
        try focus(m, "a")
        st.sessions = st.sessions   // a poll while both show: their last live sights (4.1a)
        let rb = try runtime(m, "b"), tb = rb.transcript
        XCTAssertEqual(tb.blocks.count, 1)
        st.sessions = [session("a", .idle, path: a.path)]
        XCTAssertTrue(rb.ended != nil, "the unfocused pane is Ended (4.4)")
        XCTAssertFalse(m.focusedEnded, "the focused pane is not")
        XCTAssertEqual(m.selection, .live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        let arms = tb.watchArms, gen = tb.generation
        try append(b, line(say("after the end")))
        for step in ["shown", "not shown", "hidden", "shown again"] {
            switch step {
            case "not shown": m.paneArea = .zero   // too small for two: the focused pane alone
            case "hidden": m.setVisible(false)
            case "shown again": m.paneArea = Self.wideArea; m.setVisible(true)
            default: break
            }
            tb.tick()
            XCTAssertTrue(rb.ended != nil, step)
            XCTAssertFalse(tb.running, step)
            XCTAssertTrue(tb.suspended, "kept, 0 IO: \(step)")
            XCTAssertEqual(tb.blocks.count, 1, "the kept blocks, nothing read after the end: \(step)")
            XCTAssertEqual(tb.watchArms, arms, step)
            XCTAssertEqual(tb.generation, gen, step)
        }
        XCTAssertTrue(try runtime(m, "a").transcript.running, "the live pane runs on")
    }

    /// R2.3: six shown panes; the window hides: 0 running, 0 suspended, 0 blocks; close(): no pane model alive.
    @MainActor
    func testAgentWindowSixPanesHiddenRunNothingAndCloseFreesEveryModel() throws {
        splitsOn()
        let names = ["p1", "p2", "p3", "p4", "p5", "p6"]
        let urls = try names.map { try transcriptFile($0) }
        let st = store(zip(names, urls).map { session($0, .idle, path: $1.path) })
        let m = windowModel(st)
        m.paneArea = Self.wideArea
        m.adopt(paneLayout(names.map { paneTarget($0) }))
        m.setVisible(true)
        XCTAssertEqual(m.shownPanes.count, 6)
        XCTAssertEqual(m.runtimes.values.filter { $0.transcript.running }.count, 6)
        XCTAssertEqual(m.runtimes.values.map { $0.transcript.watchArms }.reduce(0, +), 6, "one watch each")
        m.setVisible(false)
        XCTAssertEqual(m.runtimes.count, 6)
        XCTAssertTrue(m.runtimes.values.allSatisfy { !$0.transcript.running && !$0.transcript.suspended })
        XCTAssertTrue(m.runtimes.values.allSatisfy { $0.transcript.blocks.isEmpty }, "hidden: blocks freed")
        m.setVisible(true)
        XCTAssertEqual(m.runtimes.values.filter { $0.transcript.running }.count, 6)
        let refs: [() -> AnyObject?] = m.runtimes.values.flatMap { r -> [() -> AnyObject?] in
            let t = r.transcript
            return [{ [weak r] in r }, { [weak t] in t }]
        }
        XCTAssertEqual(refs.count, 12)
        m.close()
        XCTAssertTrue(m.runtimes.isEmpty)
        XCTAssertEqual(refs.filter { $0() != nil }.count, 0, "close(): no pane runtime or model alive")
        XCTAssertFalse(m.transcript.running, "a late reader gets a model that never runs")
    }

    /// R6.2 (5.2): pane A's transcript, pane B's pending plan. Focus B: the plan is B's, and a question that appears in
    /// A afterwards never reaches the input; B's plan answered: gone. Focus A: A's question, no plan. Rewrite 11 per
    /// pane: the focused pane's model is `m.transcript`, the other pane's is another object. The rebind's mutant needs
    /// both models: with one, the sinks never point elsewhere.
    @MainActor
    func testAgentWindowAskAndPlanRebindToTheFocusedPane() throws {
        splitsOn()
        let a = try transcriptFile("a")
        let b = try transcriptFile("b", [toolUse("plan_b", "ExitPlanMode", ["plan": "Plan B"])])
        let st = store([session("a", .blocked, path: a.path), session("b", .blocked, path: b.path)])
        let m = windowModel(st)
        defer { m.close() }
        m.paneArea = Self.wideArea
        m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
        m.setVisible(true)
        let ta = try runtime(m, "a").transcript, tb = try runtime(m, "b").transcript
        XCTAssertTrue(ta !== tb, "one model per pane")
        XCTAssertTrue(m.transcript === ta, "focused A: A's model")
        XCTAssertTrue(ta.running && tb.running)
        XCTAssertEqual(tb.pendingPlan?.id, "plan_b")
        XCTAssertTrue(m.interaction.ask == nil && m.interaction.plan == nil, "A has neither")

        try focus(m, "b")
        XCTAssertTrue(m.transcript === tb, "focused B: B's model")
        XCTAssertEqual(m.interaction.plan?.id, "plan_b")
        XCTAssertTrue(m.interaction.ask == nil)
        let ask: [String: Any] = ["questions": [["question": "Which colors?", "header": "Colors", "multiSelect": false,
                                                 "options": [["label": "Red", "description": "Red"],
                                                             ["label": "Blue", "description": "Blue"]]]]]
        try append(a, line(toolUse("ask_a", "AskUserQuestion", ask)))
        ta.tick()
        XCTAssertEqual(ta.pendingAsk?.id, "ask_a", "A's model has its question")
        XCTAssertTrue(m.interaction.ask == nil, "B focused: A's question never reaches the input")
        try append(b, line(toolResult("plan_b", "approved")))
        tb.tick()
        XCTAssertTrue(tb.pendingPlan == nil)
        XCTAssertTrue(m.interaction.plan == nil, "B's plan answered: the input follows B's model")

        try focus(m, "a")
        XCTAssertTrue(m.transcript === ta)
        XCTAssertEqual(m.interaction.ask?.id, "ask_a", "focused A: its question")
        XCTAssertTrue(m.interaction.plan == nil)
    }

    /// R6.3 (5.2, 4.3): a send racing a focus change goes to the focused pane's session only: the input still following
    /// A after B took the focus sends nothing; back on A it reaches A's state check (control).
    @MainActor
    func testAgentWindowSendRacingAFocusChangeGoesToTheFocusedPaneOnly() throws {
        splitsOn()
        let st = store([session("a", .working), session("b", .idle)])
        let m = windowModel(st)
        defer { m.close() }
        m.paneArea = Self.wideArea
        m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
        m.setVisible(true)
        let sa = try XCTUnwrap(st.sessions.first { $0.name == "a" })
        try focus(m, "b")
        m.interaction.follow(sa)   // the race: the input still on A
        m.interaction.draft = "typed in a"
        m.interaction.send()
        XCTAssertTrue(m.interaction.notice == nil, "B is focused: nothing of A's is checked or sent")
        try focus(m, "a")
        m.interaction.follow(sa)
        m.interaction.send()
        XCTAssertEqual(m.interaction.notice, AgentWindowText.working, "control: focused A reaches A's state check")
    }

    /// R2.5 (11.2 interaction reads): a blocked session in an unfocused shown pane: 0 screen reads. #1471: the
    /// "focusing it: exactly 1" half was the Transcript input box's read; a focused terminal pane reads none either.
    @MainActor
    func testAgentWindowUnfocusedBlockedPaneReadsNothingUntilFocused() throws {
        splitsOn()
        let st = store([session("a", .idle), session("b", .blocked)])
        let m = windowModel(st)
        defer { m.close() }
        let c = AgentIslandController()
        c.io = AgentPromptIO(read: { _ in "" }, status: { _ in "blocked" }, send: { _, _ in })
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: Self.geometry)
        c.autoAllowOn = { false }
        c.after = { _, _ in }
        c.onSessions = { _ in }
        m.interaction.controller = c
        m.interaction.readQueue = { $0() }
        showTranscript(m)   // the input (and its reads) is Transcript mode's
        m.paneArea = Self.wideArea
        m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
        m.setVisible(true)
        st.sessions = st.sessions
        XCTAssertEqual(m.interaction.reads, 0, "B blocked but unfocused: no screen read")
        try focus(m, "b")
        XCTAssertEqual(m.interaction.reads, 0, "focused, a terminal: no input box, no screen read (#1471)")
        st.sessions = st.sessions
        XCTAssertEqual(m.interaction.reads, 0)
        try focus(m, "a")
        XCTAssertEqual(m.interaction.reads, 0, "back on A (idle): nothing")
    }

    /// Step 1 review (a): an UNFOCUSED pane's runtime tells the view itself: entering Ended and its one swap to the
    /// record each publish a change while `selection` (the focused pane's) stays; a publish that changes nothing in
    /// the pane publishes nothing.
    @MainActor
    func testAgentWindowUnfocusedPaneRuntimePublishesItsEndedState() throws {
        splitsOn()
        let b = try transcriptFile("b")
        let st = store([session("a", .idle), session("b", .idle, path: b.path)])
        let m = windowModel(st)
        defer { m.close() }
        m.paneArea = Self.wideArea
        m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
        m.setVisible(true)
        st.sessions = st.sessions   // stamps both shown panes (R899-3: every shown pane)
        let rb = try runtime(m, "b")
        let sel = m.selection
        XCTAssertEqual(sel, .live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        XCTAssertEqual(m.lastLive.count, 2, "every shown pane stamped")
        final class Count { var n = 0 }
        let sends = Count()
        let sub = rb.objectWillChange.sink { _ in sends.n += 1 }
        defer { sub.cancel() }
        st.sessions = st.sessions
        XCTAssertEqual(sends.n, 0, "nothing changed in B: nothing published")
        st.sessions = [session("a", .idle)]
        XCTAssertTrue(rb.ended != nil)
        XCTAssertGreaterThan(sends.n, 0, "B's entry into Ended is published by B's runtime")
        XCTAssertEqual(m.selection, sel, "the focused pane's selection did not change")
        let entered = sends.n
        st.sessions = st.sessions
        XCTAssertEqual(sends.n, entered, "still Ended: nothing published")
        st.history = [record("b", ago: 0)]
        XCTAssertTrue(rb.ended == nil, "its own record: the one swap")
        XCTAssertTrue(rb.transcript.blocks.isEmpty, "the swap frees the kept blocks")
        XCTAssertGreaterThan(sends.n, entered, "the swap is published by B's runtime")
        XCTAssertEqual(m.selection, sel)
    }

    /// R3.3 c: a pane's last live sight outlives its runtime: the session ends (Ended), then (1) the window closes and
    /// a new model of the same owner shows the layout, (2) a layout switch away and back; with an earlier instance's
    /// record present the pane shows the placeholder, never that record; its own record lands: one swap to it.
    @MainActor
    func testAgentWindowLastLiveOutlivesACloseAndALayoutSwitch() throws {
        for path in ["close and reopen", "layout switch"] {
            let a = try transcriptFile("a")
            var old = record("a", ago: 7200)
            old.file = "a.1700000000"   // the earlier instance's, moved aside
            let st = store([session("a", .idle, path: a.path), session("b", .idle)], history: [old])
            let home = AgentLastLiveHome()
            let fixture = paneLayout([paneTarget("a")])
            var m = windowModel(st, lastLive: home)
            m.adopt(fixture)
            m.setVisible(true)
            st.sessions = st.sessions   // a poll while a shows: its last live sight, in the owner's map
            XCTAssertEqual(home.map.count, 1, path)
            st.sessions = [session("b", .idle)]
            XCTAssertTrue(m.focusedEnded, path)
            let kept = m.transcript
            XCTAssertEqual(kept.blocks.count, 1, path)
            if path == "close and reopen" {
                m.close()
                m = windowModel(st, lastLive: home)
                m.adopt(fixture)
                m.setVisible(true)
            } else {
                // Away to a Duplicate (another layout id, the same pane ids and targets, 4.1a INFO-N7): every runtime of
                // the old layout goes, none is reused under a pane id the two share.
                let dup = PaneLayout(id: UUID(), name: nil, tree: fixture.tree, focused: fixture.focused, zoomed: nil)
                m.adopt(dup)
                XCTAssertTrue(kept.blocks.isEmpty && !kept.suspended, "the layout went inactive: its runtime freed")
                XCTAssertTrue(m.transcript !== kept)
                XCTAssertFalse(m.focusedEnded, "the Duplicate's pane has no last sight: the placeholder")
                m.adopt(fixture)
            }
            XCTAssertFalse(m.focusedEnded, "nothing kept: the placeholder (\(path))")
            XCTAssertEqual(m.content, .notRunning(AgentSessionKey(dir: "/tmp/dch-test", name: "a")), path)
            XCTAssertTrue(m.selection == nil, "never the earlier instance's record (\(path))")
            let own = record("a", ago: 0)
            XCTAssertNotEqual(own.id, old.id)
            st.history = [old, own]
            XCTAssertEqual(m.selection, .history(own.id), "its own record: one swap (\(path))")
            m.close()
        }
    }

    /// R3.4 (no record): a layout whose session is gone, switched to 10 times with no record of the name: the
    /// placeholder each time, 0 spawns of any kind (no open, no restart, no attach, no read).
    @MainActor
    func testAgentWindowLayoutWithAGoneSessionSpawnsNothing() throws {
        var opened = 0
        let st = store([session("b", .idle)])
        let m = windowModel(st, opened: { _ in opened += 1 })
        let calls = Calls()
        calls.wire(m)
        defer { m.close() }
        m.setVisible(true)
        let gone = paneLayout([paneTarget("a")]), other = paneLayout([paneTarget("b")])
        for _ in 0..<10 {
            m.adopt(gone)
            XCTAssertEqual(m.content, .notRunning(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
            XCTAssertFalse(m.focusedEnded)
            XCTAssertTrue(m.selection == nil)
            XCTAssertFalse(m.transcript.running)
            XCTAssertFalse(m.openSelected())
            XCTAssertTrue(m.terminal.key == nil, "no attach")
            XCTAssertTrue(m.interaction.session == nil, "the input follows nothing")
            m.adopt(other)
        }
        XCTAssertEqual(opened, 0, "no open (no `dch -n a`)")
        XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no restart, stop, kill or History verb")
    }
}
