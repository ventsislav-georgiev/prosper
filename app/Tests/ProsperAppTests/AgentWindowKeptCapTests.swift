import XCTest
@testable import ProsperApp

/// #1790: the window's kept clients (#1782) under one cap across its panes, held through the hide (#1784's grace) at zero
/// CPU and ended by the close. Pane terminals on recorders (splitTerminals: no dch, no pty, no libghostty surface, no
/// window made); the attach rests are run by hand.
extension AgentWindowD1Tests {
    final class KeptIOLog {
        var ios: [String: AgentTerminalIO] = [:]
        var screens: [String: AgentTerminalTests.FakeScreen] = [:]
    }

    /// splitTerminals plus each client's IO and screen, by session name.
    @MainActor
    func keptRecorders(_ m: AgentWindowModel) -> (SplitTerminalLog, KeptIOLog) {
        let log = splitTerminals(m), rec = KeptIOLog()
        let make = m.makeTerminal
        m.makeTerminal = {
            let t = make()
            let spawn = t.spawn, screen = t.makeScreen
            t.spawn = { [weak t] r, io in
                rec.ios[t?.key?.name ?? "?"] = io
                return try spawn(r, io)
            }
            t.makeScreen = { [weak t] e in
                let s = screen(e)
                rec.screens[t?.key?.name ?? "?"] = s as? AgentTerminalTests.FakeScreen
                return s
            }
            return t
        }
        return (log, rec)
    }

    /// 2 panes: the focused one switches a -> c -> d (a, c kept), b shown beside it. The hide keeps d and b too, so the
    /// window's cap of 3 ends exactly the oldest (a; a per-pane cap would keep it). While hidden nothing is fed, no rest
    /// or new client runs; the show inside the grace swaps d and b back with no new client; the close ends every one.
    @MainActor
    func testAgentWindowKeptClientsSurviveTheHideUnderOneCapAndEndAtTheClose() throws {
        splitsOn()
        try withModePref {
            let ss = ["a", "b", "c", "d"].map { session($0, .idle) }
            let m = windowModel(store(ss))
            let (log, rec) = keptRecorders(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            XCTAssertEqual(log.spawned, ["a", "b"])
            for s in ss.suffix(2) {
                m.select(.live(s.key))
                Self.drainMain()
            }
            @MainActor func kept() -> [String] { log.made.flatMap { $0.keptKeys.map(\.name) } }
            XCTAssertEqual(log.spawned, ["a", "b", "c", "d"], "the focused pane switched a -> c -> d")
            XCTAssertEqual(Set(kept()), ["a", "c"])
            m.setVisible(false)
            XCTAssertEqual(kept().count, AgentTerminalController.keptSessions - 1, "hidden: the window holds 3 kept")
            XCTAssertEqual(Set(kept()), ["b", "c", "d"], "the shown d and b kept with c")
            XCTAssertEqual(log.children["a"]?.terminated, 1, "the oldest kept (a) ended: one cap for the window")
            for n in ["b", "c", "d"] { XCTAssertEqual(log.children[n]?.terminated, 0, "\(n) held through the hide") }
            XCTAssertTrue(log.made.allSatisfy { $0.key == nil && $0.screen == nil }, "nothing shown while hidden")
            @MainActor func fed() -> Int { rec.screens.values.reduce(0) { $0 + $1.fed.count } }
            let before = fed()
            for n in ["b", "d"] { rec.ios[n]?.output(Array("late|".utf8)) }
            Self.drainMain()
            XCTAssertEqual(fed(), before, "hidden: nothing parsed or drawn")
            XCTAssertEqual(log.made.reduce(0) { $0 + $1.keptInboxBytes }, 10, "the bytes wait in the kept inboxes")
            XCTAssertLessThanOrEqual(log.made.reduce(0) { $0 + $1.keptDrains }, 2, "one main hop per kept client at most")
            XCTAssertTrue(log.rests.isEmpty, "no rest while hidden")
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            XCTAssertEqual(log.spawned, ["a", "b", "c", "d"], "shown again inside the grace: no new client")
            XCTAssertEqual(m.terminal.key?.name, "d")
            XCTAssertEqual(try runtime(m, "b").terminal?.key?.name, "b")
            XCTAssertEqual(String(decoding: rec.screens["d"]?.fed.suffix(5) ?? [], as: UTF8.self), "late|", "fed once shown")
            XCTAssertEqual(kept(), ["c"])
            m.close()
            for n in ["a", "b", "c", "d"] { XCTAssertEqual(log.children[n]?.terminated, 1, "\(n): the close ends it") }
            XCTAssertTrue(kept().isEmpty)
        }
    }

    /// QA n109: a History row leaves the kept clients alone (only the shown one detaches); 4 panes hidden keep at most 3
    /// across the window, every other client ended.
    @MainActor
    func testAgentWindowKeptClientsStayAcrossHistoryAndFourPanesHideUnderTheCap() throws {
        splitsOn()
        try withModePref {
            let names = ["a", "b", "c", "d", "e"]
            let ss = names.map { session($0, .idle) }
            let m = windowModel(store(ss, history: [record("h")]))
            defer { m.close() }
            let (log, _) = keptRecorders(m)
            m.paneArea = Self.tallArea
            m.adopt(stackedLayout(["a", "b", "c", "d"]))
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            XCTAssertEqual(Set(log.spawned), ["a", "b", "c", "d"])
            @MainActor func kept() -> [String] { log.made.flatMap { $0.keptKeys.map(\.name) } }
            m.select(.live(ss[4].key))   // the focused pane a -> e: a kept
            Self.drainMain()
            XCTAssertEqual(kept(), ["a"])
            m.select(.history(AgentSessionKey(dir: "/tmp/dch-test", name: "h")))
            XCTAssertEqual(log.children["e"]?.terminated, 1, "a History row: the shown client detaches")
            XCTAssertEqual(kept(), ["a"], "and the kept one stays")
            m.select(.live(ss[0].key))
            Self.drainMain()
            XCTAssertEqual(log.spawned.filter { $0 == "a" }.count, 1, "a comes back kept: no new client")
            XCTAssertEqual(log.children["a"]?.terminated, 0)
            m.setVisible(false)
            XCTAssertLessThanOrEqual(kept().count, AgentTerminalController.keptSessions - 1, "4 panes hidden: 3 kept at most")
            XCTAssertEqual(kept().count, 3)
            let live = names.filter { (log.children[$0]?.terminated ?? 1) == 0 }
            XCTAssertEqual(Set(live), Set(kept()), "every client still running is a kept one, no more")
        }
    }

    /// #1796: an unfocused pane (b) is retargeted to another session (c) while its old client is live: the old client is
    /// kept, not ended (followUnfocusedTerminals leaves it `.keep`), under the window's cap; the new one starts after the rest.
    @MainActor
    func testAgentWindowUnfocusedPaneSwitchingSessionKeepsItsOldClient() throws {
        splitsOn()
        try withModePref {
            let ss = ["a", "b", "c"].map { session($0, .idle) }
            let m = windowModel(store(ss))
            defer { m.close() }
            let (log, _) = keptRecorders(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            XCTAssertEqual(log.spawned, ["a", "b"])
            @MainActor func kept() -> [String] { log.made.flatMap { $0.keptKeys.map(\.name) } }
            let pb = try paneID(m, "b"), l = m.layout
            let moved = l.tree.replacing(pb) { .leaf(Pane(id: $0.id, target: self.paneTarget("c"))) }
            m.adopt(PaneLayout(id: l.id, name: l.name, tree: moved, focused: l.focused, zoomed: nil))   // b's pane now shows c
            XCTAssertEqual(kept(), ["b"], "the unfocused pane's old client is kept")
            XCTAssertEqual(log.children["b"]?.terminated, 0, "not ended by the switch")
            endRests(log)
            XCTAssertEqual(log.spawned, ["a", "b", "c"], "the new session attached after the rest")
            XCTAssertEqual(kept(), ["b"])
            XCTAssertEqual(log.children["b"]?.terminated, 0)
            XCTAssertLessThanOrEqual(kept().count, AgentTerminalController.keptSessions - 1, "kept window-wide <= 3")
        }
    }

    /// #1889: the window closes on a (kept), a session is picked while it is hidden (the island's show-in-Sessions before
    /// the occlusion turns visible), the window shows again on c (a new client), then a is picked: a comes back kept and
    /// a key typed on its surface reaches its client. The bug: c's attach detached the idle terminal, whose writer was
    /// still a's, so a showed output and dropped every key until a fifth session evicted it.
    @MainActor
    func testAgentWindowKeysReachAKeptSessionAfterTheWindowClosesAndReopensOnAnother() throws {
        splitsOn()
        try withModePref {
            let ss = ["a", "b", "c"].map { session($0, .idle) }
            let m = windowModel(store(ss))
            defer { m.close() }
            let (log, rec) = keptRecorders(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            XCTAssertEqual(log.spawned, ["a", "b"])
            m.setVisible(false)   // the close (AgentsWindow.hide)
            m.select(.live(ss[2].key))   // picked while hidden
            Self.drainMain()
            m.setVisible(true)   // the reopen
            Self.drainMain()
            endRests(log)
            XCTAssertEqual(m.terminal.key?.name, "c")
            m.select(.live(ss[0].key))
            Self.drainMain()
            XCTAssertEqual(m.terminal.key?.name, "a")
            XCTAssertEqual(log.spawned.filter { $0 == "a" }.count, 1, "a came back kept: no new client")
            XCTAssertEqual(log.children["a"]?.terminated, 0)
            rec.screens["a"]?.events.write(Data("x".utf8))   // the key path: libghostty -> a's screen -> its writer
            m.terminal.writer.flush()
            XCTAssertEqual(log.children["a"]?.written, Array("x".utf8), "the key reaches a's client")
            XCTAssertEqual(log.children["c"]?.written, [], "never c's")
        }
    }

    /// #1796: the New session form over a pane with kept clients: only the shown client detaches; the kept ones stay.
    @MainActor
    func testAgentWindowNewSessionFormLeavesTheKeptClientsAlone() throws {
        splitsOn()
        try withNewSessionPrefs {
            let ss = ["a", "b", "c"].map { session($0, .idle) }
            let st = store(ss)
            st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
            let m = windowModel(st)
            defer { m.close() }
            let island = AgentIslandController()
            island.historyDirs = { ["/tmp/dch-test"] }
            island.io = AgentPromptIO(read: { _ in "" }, status: { _ in "" }, send: { _, _ in }, noMirror: { _ in true })
            m.island = { island }
            m.home = "/Users/example"
            let (log, _) = keptRecorders(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            m.select(.live(ss[2].key))   // the focused pane a -> c: a kept
            Self.drainMain()
            @MainActor func kept() -> [String] { log.made.flatMap { $0.keptKeys.map(\.name) } }
            XCTAssertEqual(kept(), ["a"])
            m.openNewSession()
            XCTAssertTrue(m.newSession != nil, "the form is open")
            XCTAssertEqual(log.children["c"]?.terminated, 1, "the shown client detaches")
            XCTAssertEqual(kept(), ["a"], "the kept one stays")
            XCTAssertEqual(log.children["a"]?.terminated, 0)
            XCTAssertLessThanOrEqual(kept().count, AgentTerminalController.keptSessions - 1)
        }
    }
}
