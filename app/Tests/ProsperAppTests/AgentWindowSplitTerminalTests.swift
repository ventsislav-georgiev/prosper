import XCTest
@testable import ProsperApp

/// #1477 (spec 15 C, 11.2): local terminal panes in splits, model half. Every pane terminal is on recorders (no dch, no
/// pty, no libghostty surface); the attach rest's delay is recorded and run by hand; no window is made, no event posted.
/// The split gate is set by `splitsOn()` (restored at teardown); the Transcript-mode list by `withModePref`.
extension AgentWindowD1Tests {
    final class SplitTerminalLog {
        var made: [AgentTerminalController] = []
        var spawned: [String] = []
        var children: [String: AgentTerminalTests.FakeChild] = [:]
        var exits: [String: (Int32) -> Void] = [:]
        var rests: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    }

    /// Every pane terminal the model makes is on recorders, its grid known; every rest is recorded, not run.
    @MainActor
    func splitTerminals(_ m: AgentWindowModel) -> SplitTerminalLog {
        let log = SplitTerminalLog()
        m.paneAfter = { log.rests.append(($0, $1)) }
        m.makeTerminal = {
            let t = AgentTerminalController()
            t.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
            t.spawn = { [weak t] _, io in
                let name = t?.key?.name ?? "?"
                let c = AgentTerminalTests.FakeChild()
                log.spawned.append(name)
                log.children[name] = c
                log.exits[name] = io.exit
                return c
            }
            t.makeScreen = { [weak t] events in
                if let g = t?.grid { events.resize(g.cols, g.rows) }
                return AgentTerminalTests.FakeScreen(events)
            }
            t.after = { _, _ in }
            t.clientVersion = { _ in [1, 40, 0] }
            t.gridChanged(cols: 80, rows: 24)
            log.made.append(t)
            return t
        }
        return log
    }

    /// Runs every rest recorded so far (as if 250 ms passed), then one main turn so the screens' grid reports land.
    @MainActor
    func endRests(_ log: SplitTerminalLog) {
        let due = log.rests
        log.rests = []
        for r in due { r.work() }
        Self.drainMain()
    }

    /// Panes stacked top to bottom, the first focused.
    func stackedLayout(_ names: [String]) -> PaneLayout {
        let ps = names.map { Pane(id: UUID(), target: paneTarget($0)) }
        func rows(_ rest: ArraySlice<Pane>) -> PaneNode {
            guard let first = rest.first else { return .leaf(Pane(id: UUID(), target: nil)) }
            if rest.count == 1 { return .leaf(first) }
            return .split(.rows, ratio: 1 / Double(rest.count), .leaf(first), rows(rest.dropFirst()))
        }
        return PaneLayout(id: UUID(), name: nil, tree: rows(ps[...]), focused: ps.first?.id ?? UUID(), zoomed: nil)
    }

    static let tallArea = CGRect(x: 0, y: 0, width: 3000, height: 3000)

    /// Spec 15 C Done: two and three local terminal panes side by side and stacked, each attached to its own session
    /// through its own controller (no singleton); the window's terminal is the focused pane's; closing frees each client.
    @MainActor
    func testAgentWindowSplitTerminalPanesAttachEachToItsOwnSession() throws {
        splitsOn()
        try withModePref {
            let cases: [(String, [String], Bool)] = [("side by side 2", ["a", "b"], false), ("side by side 3", ["a", "b", "c"], false),
                                                    ("stacked 2", ["a", "b"], true), ("stacked 3", ["a", "b", "c"], true)]
            for (c, names, stacked) in cases {
                let st = store(names.map { session($0, .idle) })
                let m = windowModel(st)
                let log = splitTerminals(m)
                m.paneArea = Self.tallArea
                m.adopt(stacked ? stackedLayout(names) : paneLayout(names.map(paneTarget)))
                m.setVisible(true)
                Self.drainMain()
                XCTAssertEqual(log.spawned, ["a"], "\(c): the focused pane attaches at once, the others wait out the rest")
                XCTAssertEqual(log.rests.count, names.count - 1, c)
                endRests(log)
                XCTAssertEqual(Set(log.spawned), Set(names), c)
                XCTAssertEqual(log.spawned.count, names.count, "\(c): one client per pane")
                var seen = Set<ObjectIdentifier>()
                for n in names {
                    let t = try XCTUnwrap(try runtime(m, n).terminal, "\(c) \(n)")
                    XCTAssertEqual(t.key?.name, n, "\(c): \(n)'s pane on its own session")
                    XCTAssertEqual(t.phase, .live, "\(c) \(n)")
                    seen.insert(ObjectIdentifier(t))
                }
                XCTAssertEqual(seen.count, names.count, "\(c): one controller per pane")
                XCTAssertFalse(seen.contains(ObjectIdentifier(m.windowTerminal)), "\(c): the window's own terminal is unused")
                XCTAssertTrue(try m.terminal === runtime(m, "a").terminal, "\(c): the window's terminal is the focused pane's")
                m.close()
                for n in names { XCTAssertGreaterThanOrEqual(log.children[n]?.terminated ?? 0, 1, "\(c): \(n)'s client ended on close") }
            }
        }
    }

    /// Spec 15 C Done: input only to the focused pane; a focus move sends the next input to the new pane and attaches nothing.
    @MainActor
    func testAgentWindowSplitTerminalInputReachesOnlyTheFocusedPane() throws {
        splitsOn()
        try withModePref {
            let st = store([session("a", .idle), session("b", .idle)])
            let m = windowModel(st)
            defer { m.close() }
            let log = splitTerminals(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            let ca = try XCTUnwrap(log.children["a"]), cb = try XCTUnwrap(log.children["b"])
            m.terminal.input([0x61])
            m.terminal.writer.flush()
            XCTAssertEqual(ca.written, [0x61], "the focused pane gets the input")
            XCTAssertEqual(cb.written, [], "the unfocused pane gets none")
            try focus(m, "b")
            m.terminal.input([0x62])
            m.terminal.writer.flush()
            XCTAssertEqual(cb.written, [0x62], "after the focus move: the new focused pane")
            XCTAssertEqual(ca.written, [0x61], "and nothing more to the old one")
            XCTAssertEqual(log.spawned.count, 2, "a focus move attaches nothing new: both stay attached")
            XCTAssertEqual(ca.terminated, 0)
        }
    }

    /// Spec 15 C: an Ended pane keeps its last frame (the controller's screen, phase .ended, no client), unfocused and
    /// focused, through a refresh and a hide and show.
    @MainActor
    func testAgentWindowSplitTerminalEndedPaneKeepsItsLastFrame() throws {
        splitsOn()
        try withModePref {
            let fa = try transcriptFile("a"), fb = try transcriptFile("b"), fc = try transcriptFile("c")
            let sa = session("a", .idle, path: fa.path), sb = session("b", .idle, path: fb.path), sc = session("c", .idle, path: fc.path)
            let st = store([sa, sb, sc])
            let m = windowModel(st)
            defer { m.close() }
            let log = splitTerminals(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b"), paneTarget("c")]))
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            st.sessions = st.sessions   // a poll while all show: their last live sights (4.1a)
            let tb = try XCTUnwrap(try runtime(m, "b").terminal)
            let frameB = try XCTUnwrap(tb.screen as? AgentTerminalTests.FakeScreen)
            st.sessions = [sa, sc]
            XCTAssertTrue(try runtime(m, "b").ended != nil, "the unfocused pane is Ended (4.4)")
            log.exits["b"]?(0)
            Self.drainMain()
            for step in ["ended", "refresh", "hidden", "shown again"] {
                switch step {
                case "refresh": st.sessions = st.sessions
                case "hidden": m.setVisible(false)
                case "shown again": m.setVisible(true)
                default: break
                }
                XCTAssertEqual(tb.phase, .ended, step)
                XCTAssertTrue((tb.screen as? AgentTerminalTests.FakeScreen) === frameB, "the last frame kept: \(step)")
                XCTAssertTrue(m.keptFrame(try paneID(m, "b")) === tb, step)
            }
            try focus(m, "c")
            Self.drainMain()
            let tc = try XCTUnwrap(try runtime(m, "c").terminal)
            let frameC = try XCTUnwrap(tc.screen as? AgentTerminalTests.FakeScreen)
            let spawns = log.spawned.count
            st.sessions = [sa]
            XCTAssertTrue(m.focusedEnded, "the focused pane is Ended")
            log.exits["c"]?(0)
            Self.drainMain()
            XCTAssertEqual(tc.phase, .ended)
            XCTAssertTrue((tc.screen as? AgentTerminalTests.FakeScreen) === frameC, "the focused Ended pane keeps its frame too")
            XCTAssertTrue(m.keptFrame(try paneID(m, "c")) === tc)
            XCTAssertEqual(log.spawned.count, spawns, "nothing reattaches to an ended session")
            XCTAssertEqual(log.spawned.filter { $0 == "b" }.count, 1, "the Ended pane never attached again")
            XCTAssertTrue(m.keptFrame(try paneID(m, "a")) == nil, "a live pane has no kept frame")
        }
    }

    /// 11.2: an unfocused pane attaches after the 250 ms rest; a refresh during the rest does not restart it; a rest
    /// whose pane left Terminal mode attaches nothing; Transcript detaches at once.
    @MainActor
    func testAgentWindowSplitTerminalUnfocusedPaneAttachesAfterTheRest() throws {
        splitsOn()
        try withModePref {
            let sb = session("b", .idle)
            let st = store([session("a", .idle), sb])
            let m = windowModel(st)
            defer { m.close() }
            let log = splitTerminals(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
            m.setVisible(true)
            Self.drainMain()
            XCTAssertEqual(AgentWindowModel.attachRest, 0.25)
            XCTAssertEqual(log.spawned, ["a"], "only the focused pane before the rest")
            XCTAssertEqual(log.rests.map(\.delay), [0.25], "one rest, for the unfocused pane")
            XCTAssertTrue(try runtime(m, "b").terminal?.key == nil, "nothing attached during the rest")
            st.sessions = st.sessions   // a refresh during the rest
            XCTAssertEqual(log.rests.count, 1, "a rest under way is not restarted")
            endRests(log)
            XCTAssertEqual(log.spawned, ["a", "b"])
            m.setMode(.transcript, for: sb)
            XCTAssertTrue(try runtime(m, "b").terminal?.key == nil, "Transcript: detached at once")
            XCTAssertEqual(log.children["b"]?.terminated, 1)
            m.setMode(.terminal, for: sb)
            XCTAssertEqual(log.rests.count, 1, "back to Terminal: a new rest")
            m.setMode(.transcript, for: sb)
            endRests(log)
            XCTAssertEqual(log.spawned, ["a", "b"], "a rest whose pane left Terminal mode attaches nothing")
        }
    }

    /// 15.0: gate off, today's single pane: the window's one terminal, no pane terminal made, no rest.
    @MainActor
    func testAgentWindowSplitTerminalGateOffKeepsTheWindowsOneTerminal() throws {
        let saved = AgentPaneLayout.splitsEnabled
        AgentPaneLayout.splitsEnabled = false
        addTeardownBlock { @MainActor in AgentPaneLayout.splitsEnabled = saved }
        try withModePref {
            let sa = session("a", .idle), sb = session("b", .idle)
            let m = windowModel(store([sa, sb]))
            defer { m.close() }
            let log = splitTerminals(m)
            let t = fakeTerminal(m)
            m.setVisible(true)
            m.select(.live(sa.key))
            XCTAssertTrue(m.terminal === m.windowTerminal)
            XCTAssertEqual(t.spawned().count, 1)
            m.select(.live(sb.key))
            XCTAssertTrue(m.terminal === m.windowTerminal)
            XCTAssertEqual(t.spawned().count, 2, "the one terminal moves to the new selection")
            XCTAssertEqual(m.windowTerminal.key, sb.key)
            XCTAssertTrue(log.made.isEmpty, "no pane terminal made")
            XCTAssertTrue(log.rests.isEmpty, "no rest")
            XCTAssertTrue(m.runtimes.values.allSatisfy { $0.terminal == nil })
        }
    }
}
