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
}
