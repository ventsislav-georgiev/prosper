import SwiftUI
import XCTest
@testable import ProsperApp

/// #1471: Terminal is the only pane mode, for a restored layout and for an Ended pane. Every pane terminal is on the
/// split recorders (no dch, no pty); the view is read as a value (Mirror over structs only), never drawn or shown.
extension AgentWindowD1Tests {
    /// Every String and type name in `v`'s value tree, class instances skipped (the models are not the view).
    /// A generic wrapper's name spells both branches of an `if`: a drawn view is a name that starts with its type.
    static func viewWords(_ v: Any) -> [String] {
        var out: [String] = []
        func walk(_ x: Any, _ depth: Int) {
            guard depth < 60 else { return }
            let m = Mirror(reflecting: x)
            if m.displayStyle == .class { return }
            out.append(String(describing: type(of: x)))
            if let s = x as? String { out.append(s) }
            for c in m.children { walk(c.value, depth + 1) }
        }
        walk(v, 0)
        return out
    }

    /// Red at base: a stored Transcript choice put the restored panes in Transcript (AgentWindowModel mode(_:) read
    /// agentWindowTranscriptSessions), so neither attached and paneMode was .transcript.
    @MainActor
    func testAgentWindowNoModeRestoredLayoutOpensEveryPaneInTerminal() throws {
        splitsOn()
        let saved = Preferences.defaults.object(forKey: Self.modePref)
        defer { Preferences.defaults.set(saved, forKey: Self.modePref) }
        Preferences.defaults.set(["/tmp/dch-test\ta", "/tmp/dch-test\tb"], forKey: Self.modePref)
        let st = store([session("a", .idle), session("b", .idle)])
        let m = windowModel(st)
        defer { m.close() }
        let log = splitTerminals(m)
        m.paneArea = Self.wideArea
        m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
        m.setVisible(true)
        Self.drainMain()
        XCTAssertTrue(m.paneHasTerminal, "the restored focused pane: Terminal")
        XCTAssertEqual(log.spawned, ["a"], "the focused pane attaches at once")
        endRests(log)
        XCTAssertEqual(Set(log.spawned), ["a", "b"], "every restored pane attaches its own session")
        for n in ["a", "b"] {
            XCTAssertEqual(try runtime(m, n).terminal?.key?.name, n, n)
            XCTAssertEqual(try runtime(m, n).terminal?.phase, .live, n)
        }
        try focus(m, "b")
        XCTAssertTrue(m.paneHasTerminal, "the other restored pane: Terminal too")
        XCTAssertNil(m.interaction.session, "no input box")
    }

    /// An Ended pane whose terminal never attached (it ended during the attach rest) has no kept frame: it draws the
    /// ended card, not a terminal. Red at base: such a pane was Transcript (`ended ? .transcript`) and drew the
    /// transcript pane (AgentsWindow.swift AgentUnfocusedPane `transcriptPane`), no "Session ended" card.
    @MainActor
    func testAgentWindowNoModeEndedPaneWithoutKeptFrameDrawsTheEndedCard() throws {
        splitsOn()
        try withModePref {
            let fa = try transcriptFile("a"), fb = try transcriptFile("b")
            let sa = session("a", .idle, path: fa.path), sb = session("b", .idle, path: fb.path)
            let st = store([sa, sb])
            let m = windowModel(st)
            defer { m.close() }
            let log = splitTerminals(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
            m.setVisible(true)
            Self.drainMain()
            XCTAssertEqual(log.spawned, ["a"], "b still waits out its rest")
            st.sessions = st.sessions   // a poll while both show: their last live sights (4.1a)
            @MainActor func words(_ n: String) throws -> [String] {
                let r = try runtime(m, n)
                return Self.viewWords(AgentUnfocusedPane(model: m, runtime: r, transcript: r.transcript,
                                                         interaction: m.interaction, scrolls: false).body)
            }
            // #1645: gate on, AgentPaneArea.pane draws a terminal pane as AgentPaneTerminalColumn (focused or not): same rule.
            @MainActor func column(_ n: String) throws -> [String] {
                let r = try runtime(m, n)
                let shown = try XCTUnwrap(AgentPaneTerminalColumn.shown(m, r, focused: false), "\(n): a terminal pane")
                return Self.viewWords(AgentPaneTerminalColumn(model: m, runtime: r, transcript: r.transcript, shown: shown,
                                                              focused: false, scrolls: false, compact: true).body)
            }
            for live in [try words("a"), try column("a")] {
                XCTAssertTrue(live.contains { $0.hasPrefix("AgentTerminalPane") }, "control: a live pane draws its terminal")
                XCTAssertFalse(live.contains("Session ended"), "control: no ended card on a live pane")
            }
            st.sessions = [sa]
            XCTAssertTrue(try runtime(m, "b").ended != nil, "b is Ended")
            XCTAssertTrue(m.keptFrame(try paneID(m, "b")) == nil, "it never attached: no kept frame")
            for ended in [try words("b"), try column("b")] {
                XCTAssertTrue(ended.contains("Session ended"), "the ended card")
                XCTAssertFalse(ended.contains { $0.hasPrefix("AgentTerminalPane") }, "no terminal under it")
            }
            endRests(log)
            XCTAssertFalse(log.spawned.contains("b"), "nothing attaches to the ended session")
        }
    }
}
