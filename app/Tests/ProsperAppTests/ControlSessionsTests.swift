import Foundation
import AppKit
import XCTest
@testable import ProsperApp

/// #1809: Agent Sessions over the control channel. Every row runs on the window model's own seams (AgentWindowD1Tests'
/// fakes): no dch, no window shown, no terminal attached, no real island controller. ControlSessions' seams are set per
/// row and put back after it.
final class ControlSessionsTests: XCTestCase {
    let base = AgentWindowD1Tests()
    /// The show seam's calls in the current withSeams (the window's open through the menu's path, recorded, never shown).
    var shows = 0

    @MainActor
    func withSeams(model: AgentWindowModel? = nil, store: AgentIslandStore? = nil, show: AgentWindowModel? = nil,
                   _ body: () throws -> Void) rethrows {
        let saved = (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow)
        defer { (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow) = saved }
        ControlSessions.model = { model }
        ControlSessions.islandStore = { store }
        shows = 0
        ControlSessions.showWindow = { self.shows += 1; return show }
        try body()
    }

    @MainActor
    func withGate(_ on: Bool, _ body: () throws -> Void) rethrows {
        let saved = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = saved }
        AgentPaneLayout.splitsEnabled = on
        try body()
    }

    func args(_ d: [String: String]) -> [String: ControlJSON] { d.mapValues { .string($0) } }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    func rows(_ j: ControlJSON) -> [String: [String: ControlJSON]] {
        guard case .object(let o) = j, case .array(let a)? = o["sessions"] else { return [:] }
        var out: [String: [String: ControlJSON]] = [:]
        for case .object(let r) in a { if case .string(let n)? = r["name"] { out[n] = r } }
        return out
    }

    // MARK: - sessions.list

    /// Name, title, state, agent, cwd, pane (1-based in the active layout) and the row's action
    /// text; with no window the island's store alone (pane null).
    @MainActor
    func testSessionsListReportsStateAgentCwdAndPane() throws {
        try withGate(true) {
            var api = base.session("api", .working, alias: "API")
            api.claudeSessionID = "0b7c2f3e-1111-2222-3333-444455556666"
            api.cwd = "/Users/example/api"
            let qa = base.session("api-qa", .idle), web = base.session("web", .blocked)
            let st = base.store([api, qa, web])
            st.actions[web.key] = "Restarting\u{2026}"
            let m = base.windowModel(st, layouts: base.layoutSuite())
            defer { m.close() }
            m.paneArea = AgentWindowD1Tests.wideArea
            m.adopt(base.paneLayout([base.paneTarget("web"), base.paneTarget("api")]))
            try withSeams(model: m) {
                let r = rows(try ControlSessions.list())
                _ = try ControlSessions.list()
                XCTAssertEqual(r.count, 3)
                XCTAssertEqual(r["api"]?["title"], .string("API"))
                XCTAssertEqual(r["api"]?["state"], .string("Working"))
                XCTAssertEqual(r["api"]?["agent"], .string("claude"))
                XCTAssertEqual(r["api"]?["cwd"], .string("/Users/example/api"))
                XCTAssertEqual(r["api"]?["pane"], .number(2))
                XCTAssertEqual(r["web"]?["pane"], .number(1))
                XCTAssertEqual(r["api-qa"]?["pane"], .null, "not in the layout")
                XCTAssertEqual(r["web"]?["action"], .string("Restarting\u{2026}"))
                XCTAssertEqual(r["web"]?["agent"], .null)
                XCTAssertEqual(r["web"]?["cwd"], .null)
            }
            try withSeams(store: st) {
                XCTAssertEqual(rows(try ControlSessions.list())["api"]?["pane"], .null, "no window: no pane")
            }
            try withSeams { refused(try ControlSessions.list(), ControlSessions.islandOff) }
        }
    }

    /// #2001: `agent` is dch's --ls-json `agent` when the row has one ("" is dch's null: neither runs); a row from an
    /// older dch (nil) keeps the claudeSessionID/harness rule. Red at base: the Codex row lists its harness title, the
    /// Claude row null, the shell row "claude" (its claudeSessionID).
    @MainActor
    func testSessionsListAgentComesFromDch() throws {
        let sid = "0b7c2f3e-1111-2222-3333-444455556666"
        var cx = base.session("cx", .idle), cl = base.session("cl", .idle), sh = base.session("sh", .idle)
        var old = base.session("old", .idle), oldC = base.session("old-c", .idle)
        cx.agent = "codex"; cx.harness = "fix tests"
        cl.agent = "claude"
        sh.agent = ""; sh.claudeSessionID = sid
        old.harness = "fix tests"
        oldC.claudeSessionID = sid
        try withSeams(store: base.store([cx, cl, sh, old, oldC])) {
            let r = rows(try ControlSessions.list())
            XCTAssertEqual(r["cx"]?["agent"], .string("codex"))
            XCTAssertEqual(r["cl"]?["agent"], .string("claude"))
            XCTAssertEqual(r["sh"]?["agent"], .null, "dch's null wins over the claudeSessionID rule")
            XCTAssertEqual(r["old"]?["agent"], .string("fix tests"), "older dch: the harness title")
            XCTAssertEqual(r["old-c"]?["agent"], .string("claude"), "older dch: a mapped Claude")
        }
    }

    // MARK: - sessions.stop / sessions.restart

    /// The confirm strip's path without the question: the menu's gate, then the model's Stop/Restart seam once with that
    /// session. Busy, unknown, ambiguous and a closed gate are errors and run nothing; neither verb has an undo.
    @MainActor
    func testSessionsStopAndRestartTakeTheWindowsGateAndSeams() throws {
        let st = base.store([base.session("api", .idle), base.session("web", .working)])
        st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
        let m = base.windowModel(st)
        defer { m.close() }
        var calls: [String] = [], started = true
        m.restartSession = { calls.append("restart \($0.name)"); return started }
        m.stopSession = { calls.append("stop \($0.name)"); return started }
        try withSeams(model: m) {
            let stop = try ControlSessions.run(.stop, args(["name": "api"]))
            XCTAssertEqual(calls, ["stop api"])
            XCTAssertEqual(stop.result, .string("api"))
            XCTAssertNil(stop.undo, "no inverse")
            XCTAssertEqual(stop.verb, "stopped")
            let restart = try ControlSessions.run(.restart, args(["name": "web"]))
            XCTAssertEqual(calls, ["stop api", "restart web"])
            XCTAssertNil(restart.undo, "no inverse")
            XCTAssertEqual(restart.verb, "restarted")
            started = false
            refused(try ControlSessions.run(.restart, args(["name": "web"])), "web is busy: try again")
            started = true
            refused(try ControlSessions.run(.stop, args(["name": "nope"])), "no live session named nope (sessions.list lists them)")
            st.controlDch = nil
            calls = []
            XCTAssertThrowsError(try ControlSessions.run(.stop, args(["name": "api"]))) {
                XCTAssertTrue(($0 as? ControlError)?.message.hasPrefix("Not run: ") == true, "\($0)")
            }
            XCTAssertEqual(calls, [], "a closed gate runs nothing")
        }
        let twins = base.store([base.session("api", .idle), base.session("api", .idle, dir: "/tmp/dch-other")])
        refused(try ControlSessions.session("api", in: twins), "2 sessions are named api: rename one first")
        XCTAssertEqual(try ControlSessions.session("api", in: base.store([base.session("x", .idle, alias: "API")])).name, "x",
                       "the shown title, case folded, when no dch name matches")
    }

    // MARK: - sessions.focus

    /// The window shown (seam) and the row clicked; undo selects the row selected before. No island: nothing shown.
    @MainActor
    func testSessionsFocusSelectsTheSessionAndUndoSelectsTheOneBefore() throws {
        let st = base.store([base.session("api", .idle), base.session("web", .idle)])
        let m = base.windowModel(st)
        m.setVisible(true)   // #1846: the sidebar's rows built, so a click would move the keys (focusSelection)
        defer { m.close() }
        _ = base.fakeTerminal(m)
        m.select(.live(base.paneKey("api")))
        try withSeams(show: m) {
            let ch = try ControlSessions.focus(args(["name": "web"]))
            XCTAssertEqual(m.selection, .live(base.paneKey("web")))
            XCTAssertFalse(m.terminal.focusPending, "#1846 n133: selected, the keys not moved into its terminal")
            ch.undo?()
            XCTAssertEqual(m.selection, .live(base.paneKey("api")))
        }
        try withSeams { refused(try ControlSessions.focus(args(["name": "web"])), ControlSessions.islandOff) }
    }

    /// #1864 n181: ControlNavTests.withOnePaneKeys for sessions.focus: one stored layout of one pane (api), web shown by
    /// no pane, the keys in api's terminal (a fake-client terminal in a never-shown window). `body` gets the model, api's
    /// view, the window and its host.
    @MainActor
    func withOnePaneKeys(_ body: (AgentWindowModel, AgentTerminalHostView, AgentsNSWindow, NSView) throws -> Void) throws {
        try base.withPaneMenu(true) {
            let a = base.paneLayout([base.paneTarget("api")]), d = base.layoutSuite()
            d.set(try PaneLayoutStore(layouts: [a], active: a.id, mru: [a.id]).encode(), forKey: "agentWindowLayouts")   // the one stored layout, before the model reads it
            let m = base.windowModel(base.store([base.session("api", .idle), base.session("web", .idle)]), layouts: d)
            let log = base.splitTerminals(m)
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = base.focusWindow(m)
            defer { win.close() }
            base.endRests(log)
            base.paneFocusSettle(host) { m.terminal.phase == .live && m.terminal.view?.window === win }
            let apiView = try XCTUnwrap(m.terminal.view)
            XCTAssertEqual(m.layout.panes.count, 1)
            XCTAssertTrue(m.focusSelection())
            base.paneFocusSettle(host) { win.firstResponder === apiView }
            XCTAssertTrue(win.firstResponder === apiView, "the keys in api's terminal")
            try withSeams(model: m, show: m) { try body(m, apiView, win, host) }
            XCTAssertFalse(win.isVisible, "never shown")
            XCTAssertFalse(win.isKeyWindow, "never key")
        }
    }

    @MainActor
    func focusedName(_ m: AgentWindowModel) -> String? {
        guard case let .session(_, n)? = m.layout.panes.first(where: { $0.id == m.layout.focused })?.target else { return nil }
        return n
    }

    /// #1864 n181: no pane shows web and the keys are in the one pane's terminal, so the focus is refused (its select would
    /// put web into that pane, whose swapped-in view AgentTerminalHostSlot.hold hands the keys): target, layout, row, writes
    /// and keys unchanged. The session the pane already shows is still focused, the keys left in its terminal.
    @MainActor
    func testSessionsFocusRefusedWhenItWouldRetargetThePaneWithTheKeys() throws {
        try withOnePaneKeys { m, apiView, win, host in
            let layout = m.layout, selection = m.selection, keys = m.keyFocus, writes = m.layoutWrites
            refused(try ControlSessions.focus(args(["name": "web"])), ControlSessions.keysInPane)
            base.paneFocusSettle(host) { false }
            XCTAssertEqual(focusedName(m), "api", "the focused pane is not retargeted")
            XCTAssertEqual(m.layout, layout)
            XCTAssertTrue(m.selection == selection, "the row is unchanged")
            XCTAssertEqual(m.keyFocus, keys)
            XCTAssertEqual(m.layoutWrites, writes)
            XCTAssertTrue(win.firstResponder === apiView, "the keys stay in api's terminal")
            let ch = try ControlSessions.focus(args(["name": "api"]))
            XCTAssertEqual(ch.verb, "focused", "a session the pane shows: allowed")
            base.paneFocusSettle(host) { false }
            XCTAssertEqual(focusedName(m), "api")
            XCTAssertFalse(m.keysStay)
            XCTAssertTrue(win.firstResponder === apiView, "the keys still in api's terminal")
        }
    }

    /// #1864 n181: with no keys in the pane the focus retargets it (web) and moves no keys; the person then clicks into
    /// web's terminal. The undo's restore (api) would now retarget the pane under the keys: skipped, web and its keys kept.
    @MainActor
    func testSessionsFocusUndoNeverRetargetsThePaneWithTheKeys() throws {
        try withOnePaneKeys { m, apiView, win, host in
            XCTAssertTrue(win.makeFirstResponder(nil))
            base.paneFocusSettle(host) { win.firstResponder !== apiView }
            let pane = m.layout.focused
            let before = try XCTUnwrap(m.selection)
            let ch = try ControlSessions.focus(args(["name": "web"]))
            base.paneFocusSettle(host) { m.terminal.phase == .live && m.terminal.view?.window === win && m.terminal.view !== apiView }
            XCTAssertEqual(m.layout.focused, pane)
            XCTAssertEqual(focusedName(m), "web", "no keys in the pane: the focus retargets it")
            let webView = try XCTUnwrap(m.terminal.view)
            XCTAssertFalse(win.firstResponder === webView, "#1846 n133: the keys not moved into web's terminal")
            XCTAssertTrue(m.focusSelection(), "the person's click")
            base.paneFocusSettle(host) { win.firstResponder === webView }
            XCTAssertTrue(win.firstResponder === webView, "the keys in web's terminal")
            XCTAssertTrue(m.wouldRetargetFocusedPane(before), "the restore would retarget the focused pane")
            ch.undo?()
            base.paneFocusSettle(host) { false }
            XCTAssertEqual(focusedName(m), "web", "the undo leaves the pane under the keys")
            XCTAssertTrue(win.firstResponder === webView, "the keys stay in web's terminal")
        }
    }

    // MARK: - layout.set

    /// side-by-side: a new layout, two columns, left then right, saved and locked; undo deletes it and the layout before is
    /// active again. No room, the gate off and one session twice are refused, and a refusal leaves no layout behind.
    @MainActor
    func testLayoutSetPutsTwoSessionsSideBySideAndUndoBringsTheLayoutBack() throws {
        let st = base.store([base.session("api", .idle), base.session("web", .idle)])
        let m = base.windowModel(st, layouts: base.layoutSuite())
        defer { m.close() }
        let a = args(["layout": "side-by-side", "left": "api", "right": "web"])
        try withSeams(model: m) {
            try withGate(true) {
                let before = m.layout.id, count = m.layouts?.layouts.count ?? 0
                m.paneArea = CGRect(x: 0, y: 0, width: 400, height: 300)
                refused(try ControlSessions.setLayout(a), PaneRefusal.noRoom.notice ?? "")
                XCTAssertEqual(m.layout.id, before, "a refusal brings the layout before back")
                XCTAssertEqual(m.layouts?.layouts.count, count, "and leaves no layout behind")
                refused(try ControlSessions.setLayout(a), PaneRefusal.noRoom.notice ?? "")
                XCTAssertEqual(m.layouts?.layouts.count, count, "#1895: a second refusal leaves none either")
                m.paneArea = AgentWindowD1Tests.wideArea
                let ch = try ControlSessions.setLayout(a)
                XCTAssertEqual(m.layout.panes.compactMap(\.target), [base.paneTarget("api"), base.paneTarget("web")])
                guard case let .split(axis, _, _, _) = m.layout.tree else { return XCTFail("two panes: one split") }
                XCTAssertEqual(axis, .columns, "side by side")
                XCTAssertTrue(m.layouts?.activeLayout == m.layout, "#1895: saved at once")
                XCTAssertEqual(m.layouts?.layouts.count, count + 1)
                XCTAssertEqual(ch.result, .string(m.layout.id.uuidString))
                ch.undo?()
                XCTAssertEqual(m.layout.id, before)
                XCTAssertEqual(m.layouts?.layouts.count, count)
                refused(try ControlSessions.setLayout(args(["layout": "side-by-side", "left": "api", "right": "API"])),
                        "left and right are the same session")
            }
            try withGate(false) { refused(try ControlSessions.setLayout(a), "split panes are off in this build") }
            XCTAssertEqual(shows, 0, "a model already: the window is not shown")
        }
        // #1809 (b): never opened: opened through the show path (seam: recorded), then laid out.
        try withGate(true) {
            try withSeams(show: m) {
                let ch = try ControlSessions.setLayout(a)
                XCTAssertEqual(shows, 1, "the window opened once")
                XCTAssertEqual(m.layout.panes.compactMap(\.target), [base.paneTarget("api"), base.paneTarget("web")])
                ch.undo?()
            }
        }
        try withSeams { refused(try ControlSessions.setLayout(a), ControlSessions.islandOff) }
    }

    // MARK: - sessions.new

    /// The New session form filled and started: folder, name, agent's command and the first message reach the spawn seam;
    /// a refusal closes the form and spawns nothing; an open form is never taken over. Undo stops it once listed.
    @MainActor
    func testSessionsNewStartsTheFormAndUndoStopsTheListedSession() throws {
        try base.withNewSessionPrefs {
            let st = base.store([]), spawns = AgentWindowD1Tests.SpawnCalls()
            let m = base.newSessionModel(st, spawns)
            defer { m.close() }
            try withSeams(model: m) {
                refused(try ControlSessions.new(args(["agent": "shell", "prompt": "hi"])), "a prompt needs agent claude or codex")
                XCTAssertTrue(m.newSession == nil, "refused before the form opens")
                // QA n145: the agent's first message is outside text: refused whole, the form never opens, nothing spawns.
                for bad in ["/x", "!x", "a\u{202E}b"] {
                    XCTAssertThrowsError(try ControlSessions.new(args(["agent": "claude", "cwd": "/Users/example/api", "prompt": bad])), bad)
                    XCTAssertTrue(m.newSession == nil, bad)
                }
                XCTAssertEqual(spawns.calls.count, 0)
                XCTAssertThrowsError(try ControlSessions.new(args(["agent": "claude", "name": "api", "cwd": "/Users/example/missing"])))
                XCTAssertTrue(m.newSession == nil, "a refusal closes the form")
                XCTAssertEqual(spawns.calls.count, 0)
                let ch = try ControlSessions.new(args(["agent": "claude", "name": "api", "cwd": "/Users/example/api", "prompt": "hello"]))
                XCTAssertEqual(ch.result, .string("api"))
                XCTAssertEqual(spawns.calls.count, 1)
                XCTAssertEqual(spawns.calls.last?.folder, "/Users/example/api")
                XCTAssertEqual(spawns.calls.last?.name, "api")
                XCTAssertEqual(spawns.calls.last?.argv.first, "claude")
                XCTAssertEqual(m.newSession?.prompt, "hello")
                refused(try ControlSessions.new(args(["agent": "codex"])),
                        "the New session form is open in Agent Sessions: finish or cancel it first")
                m.cancelNewSession()
                let codex = try ControlSessions.new(args(["agent": "codex", "cwd": "/Users/example/web"]))
                XCTAssertEqual(spawns.calls.count, 2)
                XCTAssertEqual(spawns.calls.last?.argv.first, "codex")
                XCTAssertEqual(codex.result, .string(spawns.calls.last?.name ?? "?"), "a free name from the folder")
                m.cancelNewSession()
                var stopped: [String] = []
                m.stopSession = { stopped.append($0.name); return true }
                ch.undo?()
                XCTAssertEqual(stopped, [], "not listed yet: nothing to stop")
                st.sessions = [base.session("api", .idle)]
                ch.undo?()
                XCTAssertEqual(stopped, ["api"])
                // #1809 (a): a draft the person kept after Cancel survives an agent's sessions.new and its start's answer.
                m.openNewSession()
                m.setNewSessionPrompt("my draft")
                m.cancelNewSession()
                m.sayFirst = { _, _, _, _ in }
                _ = try ControlSessions.new(args(["agent": "claude", "name": "docs", "cwd": "/Users/example/docs", "prompt": "hello"]))
                XCTAssertEqual(m.newSession?.prompt, "hello", "the agent's message in the form")
                spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "docs"), nil)
                XCTAssertEqual(m.lastPrompt, "my draft", "the kept draft is not the agent's and not taken")
                m.cancelNewSession()
                m.openNewSession()
                XCTAssertEqual(m.newSession?.prompt, "my draft", "the next form opens with the draft")
                m.cancelNewSession()
                // #1846 n132: an agent's start and its answer leave the person's saved command and folder as they are.
                Preferences.agentIslandNewSessionCommand = "claude --model example"
                Preferences.agentWindowNewSessionFolder = "/Users/example/saved"
                _ = try ControlSessions.new(args(["agent": "codex", "name": "web2", "cwd": "/Users/example/web"]))
                XCTAssertEqual(spawns.calls.last?.name, "web2")
                spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web2"), nil)
                XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --model example")
                XCTAssertEqual(Preferences.agentWindowNewSessionFolder, "/Users/example/saved")
                m.cancelNewSession()
                XCTAssertEqual(shows, 0, "a model already: the window is not shown")
            }
            // #1809 (b): never opened: opened through the show path (seam: recorded), then the form started.
            try withSeams(show: m) {
                _ = try ControlSessions.new(args(["agent": "codex", "cwd": "/Users/example/api"]))
                XCTAssertEqual(shows, 1, "the window opened once")
                XCTAssertEqual(spawns.calls.last?.argv.first, "codex")
                m.cancelNewSession()
            }
            try withSeams { refused(try ControlSessions.new(args(["agent": "claude"])), ControlSessions.islandOff) }
        }
    }

    /// #1992: sessions.new with agent codex and a prompt starts codex and its first prompt reaches sayFirst (codex true);
    /// a shell's prompt is still refused before the form opens. Red at base: "a prompt needs agent claude".
    @MainActor
    func testSessionsNewCodexPromptReachesSayFirst() throws {
        try base.withNewSessionPrefs {
            let st = base.store([]), spawns = AgentWindowD1Tests.SpawnCalls()
            let m = base.newSessionModel(st, spawns)
            defer { m.close() }
            var said: [(String, String, Bool)] = []
            m.sayFirst = { key, text, codex, _ in said.append((key.name, text, codex)) }
            try withSeams(model: m) {
                refused(try ControlSessions.new(args(["agent": "shell", "prompt": "hi"])), "a prompt needs agent claude or codex")
                XCTAssertTrue(m.newSession == nil, "refused before the form opens")
                let ch = try ControlSessions.new(args(["agent": "codex", "name": "web", "cwd": "/Users/example/web", "prompt": "hello"]))
                XCTAssertEqual(ch.result, .string("web"))
                XCTAssertEqual(spawns.calls.last?.argv.first, "codex")
                spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
                XCTAssertEqual(said.count, 1)
                XCTAssertEqual(said.last?.0, "web")
                XCTAssertEqual(said.last?.1, "hello")
                XCTAssertEqual(said.last?.2, true, "a Codex: firstRun skips Claude's screen check")
                m.cancelNewSession()
            }
        }
    }

    /// #1997: sessions.new with agent codex runs the Codex command setting, else plain codex; it saves nothing.
    /// Red at base: a bare codex whatever the setting.
    @MainActor
    func testSessionsNewCodexRunsTheCodexCommandSetting() throws {
        try base.withNewSessionPrefs {
            let st = base.store([]), spawns = AgentWindowD1Tests.SpawnCalls()
            let m = base.newSessionModel(st, spawns)
            defer { m.close() }
            try withSeams(model: m) {
                Preferences.agentIslandCodexCommand = "headroom wrap codex --search"
                _ = try ControlSessions.new(args(["agent": "codex", "name": "web", "cwd": "/Users/example/web"]))
                XCTAssertEqual(Array(spawns.calls.last?.argv.prefix(4) ?? []), ["headroom", "wrap", "codex", "--search"])
                spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
                XCTAssertEqual(Preferences.agentIslandCodexCommand, "headroom wrap codex --search", "unchanged")
                m.cancelNewSession()
                Preferences.agentIslandCodexCommand = ""
                _ = try ControlSessions.new(args(["agent": "codex", "name": "web2", "cwd": "/Users/example/web"]))
                XCTAssertEqual(spawns.calls.last?.argv.first, "codex", "unset: plain codex")
                XCTAssertEqual(spawns.calls.count, 2)
                m.cancelNewSession()
            }
        }
    }

    /// #1997 L1: a Codex setting that is not a Codex argv (`env K=V codex`) would drop the prompt, so sessions.new
    /// falls back to a bare codex and the prompt is delivered; a Codex-shaped setting is kept as is.
    /// Red without `if !m.newSessionCodex { m.setNewSessionCommand("codex") }`: argv starts with env, no prompt said.
    @MainActor
    func testSessionsNewCodexNonCodexSettingFallsBackToBareCodex() throws {
        try base.withNewSessionPrefs {
            let st = base.store([]), spawns = AgentWindowD1Tests.SpawnCalls()
            let m = base.newSessionModel(st, spawns)
            defer { m.close() }
            var said: [String] = []
            m.sayFirst = { _, text, _, _ in said.append(text) }
            try withSeams(model: m) {
                Preferences.agentIslandCodexCommand = "env K=V codex"
                _ = try ControlSessions.new(args(["agent": "codex", "name": "web", "cwd": "/Users/example/web", "prompt": "hello"]))
                XCTAssertEqual(spawns.calls.last?.argv.first, "codex")
                spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
                XCTAssertEqual(said, ["hello"])
                XCTAssertEqual(Preferences.agentIslandCodexCommand, "env K=V codex", "unchanged")
                m.cancelNewSession()
                Preferences.agentIslandCodexCommand = "codex --search"
                _ = try ControlSessions.new(args(["agent": "codex", "name": "web2", "cwd": "/Users/example/web"]))
                XCTAssertEqual(Array(spawns.calls.last?.argv.prefix(2) ?? []), ["codex", "--search"], "kept as is")
                m.cancelNewSession()
            }
        }
    }

    /// #1846 n135: sessions.focus and layout.set refuse over an open New session form, as sessions.new does (a pick
    /// would close it); the form stays open and nothing is selected or laid out.
    @MainActor
    func testSessionsFocusAndLayoutSetRefuseOverAnOpenForm() throws {
        try base.withNewSessionPrefs {
            let st = base.store([base.session("api", .idle), base.session("web", .idle)])
            let m = base.newSessionModel(st, AgentWindowD1Tests.SpawnCalls())
            defer { m.close() }
            m.select(.live(base.paneKey("api")))
            m.openNewSession()
            XCTAssertTrue(m.newSession != nil)
            try withSeams(model: m, show: m) {
                try withGate(true) {
                    refused(try ControlSessions.focus(args(["name": "web"])), ControlSessions.formOpen)
                    refused(try ControlSessions.setLayout(args(["layout": "side-by-side", "left": "api", "right": "web"])),
                            ControlSessions.formOpen)
                }
            }
            XCTAssertTrue(m.newSession != nil, "the form stays open")
            m.cancelNewSession()
        }
    }

    /// #1846 n133: an agent's show (AgentsWindow.show(quietly:), DockPolicy.presentQuietly) never activates an inactive
    /// Prosper: ordered front only, no activation, no re-assert, no `.regular` flip. Active: the normal present. Every
    /// DockPolicy seam faked; the window is never put on screen.
    @MainActor
    func testAgentShowNeverActivatesAnInactiveProsper() throws {
        var log: [String] = [], active = false
        DockPolicy.resetForTesting(setPolicy: { log.append("policy \($0.rawValue)") }, order: { _ in log.append("order") },
                                   orderQuietly: { _ in log.append("quiet") }, isActive: { active },
                                   frontmostPid: { 1 }, reactivate: { log.append("reactivate") },
                                   after: { _, f in log.append("after"); f() })
        defer { DockPolicy.resetForTesting() }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        DockPolicy.presentQuietly(win)
        XCTAssertEqual(log, ["quiet"], "inactive: ordered front only")
        XCTAssertFalse(DockPolicy.isShown(win), "not registered: the .regular flip would activate")
        log = []
        active = true
        DockPolicy.presentQuietly(win)
        XCTAssertTrue(log.contains("order"), "active: the normal present")
        XCTAssertFalse(log.contains("quiet"))
        // The window's own path: show(quietly: true) takes presentQuietly, show() the person's present.
        let r = AgentWindowD1Tests.HideRig(base.store([base.session("api", .idle)]))
        let w = r.w
        addTeardownBlock { @MainActor in w.window?.close(); w.grace?.fire() }
        var quiet = 0
        w.presentQuietly = { _ in quiet += 1 }
        w.show(quietly: true)
        XCTAssertEqual(quiet, 1)
        XCTAssertEqual(r.presented, 0)
        w.show()
        XCTAssertEqual(quiet, 1)
        XCTAssertEqual(r.presented, 1)
    }

    // MARK: - Registration and the wire

    /// registerSessions adds the eight commands (list and history reads, the rest mutating; #1833 added history and resume); over reply() the args are validated
    /// before the handler and a handler's refusal is the error reply.
    @MainActor
    func testRegisterSessionsDescribesTheCommandsAndRepliesOnTheWire() async throws {
        var reg = ControlRegistry()
        ControlRegistry.registerSessions(&reg)
        XCTAssertEqual(reg.commands.keys.sorted(),
                       ["layout.set", "sessions.focus", "sessions.history", "sessions.list", "sessions.new", "sessions.restart", "sessions.resume",
                        "sessions.stop"])
        XCTAssertEqual(reg.commands.values.filter(\.mutates).count, 6)
        XCTAssertEqual(reg.commands["sessions.list"]?.mutates, false)
        // #2001: not Claude only (a Codex session stops too).
        XCTAssertEqual(reg.commands["sessions.stop"]?.summary, "Stop a session (its agent is paused, the session ends; no undo).")
        let st = base.store([base.session("api", .idle)])
        let saved = (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow)
        defer { (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow) = saved }
        ControlSessions.model = { nil }
        ControlSessions.islandStore = { st }
        ControlSessions.showWindow = { nil }
        let registry = reg
        func send(_ json: String) async -> ControlReply { await registry.reply(to: Data(json.utf8)) }
        let stop = await send(#"{"cmd":"sessions.stop","args":{"name":"nope"}}"#)
        XCTAssertEqual(stop, .failure("no live session named nope (sessions.list lists them)"))
        let grid = await send(#"{"cmd":"layout.set","args":{"layout":"grid","left":"a","right":"b"}}"#)
        XCTAssertEqual(grid, .failure("argument 'layout' must be one of side-by-side"))
        let list = await send(#"{"cmd":"sessions.list"}"#)
        XCTAssertTrue(list.ok)
        XCTAssertEqual(list.result.map { rows($0) }?["api"]?["state"], .string("Idle"))
    }
}
