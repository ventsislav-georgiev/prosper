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
                m.setLayoutEditing(false)   // #1846 n134: the fixture starts in Edit layout; off first, on below
                refused(try ControlSessions.setLayout(a), PaneRefusal.noRoom.notice ?? "")
                XCTAssertEqual(m.layout.id, before, "a refusal brings the layout before back")
                XCTAssertEqual(m.layouts?.layouts.count, count, "and leaves no layout behind")
                XCTAssertFalse(m.layoutEditing, "#1846 n134: and Edit layout as it was (off)")
                m.setLayoutEditing(true)
                refused(try ControlSessions.setLayout(a), PaneRefusal.noRoom.notice ?? "")
                XCTAssertTrue(m.layoutEditing, "#1846 n134: and Edit layout as it was (on)")
                m.paneArea = AgentWindowD1Tests.wideArea
                let ch = try ControlSessions.setLayout(a)
                XCTAssertEqual(m.layout.panes.compactMap(\.target), [base.paneTarget("api"), base.paneTarget("web")])
                guard case let .split(axis, _, _, _) = m.layout.tree else { return XCTFail("two panes: one split") }
                XCTAssertEqual(axis, .columns, "side by side")
                XCTAssertFalse(m.layoutEditing, "Done: saved and locked")
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
                refused(try ControlSessions.new(args(["agent": "shell", "prompt": "hi"])), "a prompt needs agent claude")
                XCTAssertTrue(m.newSession == nil, "refused before the form opens")
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
                m.sayFirst = { _, _, _ in }
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

    /// registerSessions adds the six commands (list a read, the rest mutating); over reply() the args are validated
    /// before the handler and a handler's refusal is the error reply.
    @MainActor
    func testRegisterSessionsDescribesTheCommandsAndRepliesOnTheWire() async throws {
        var reg = ControlRegistry()
        ControlRegistry.registerSessions(&reg)
        XCTAssertEqual(reg.commands.keys.sorted(),
                       ["layout.set", "sessions.focus", "sessions.list", "sessions.new", "sessions.restart", "sessions.stop"])
        XCTAssertEqual(reg.commands.values.filter(\.mutates).count, 5)
        XCTAssertEqual(reg.commands["sessions.list"]?.mutates, false)
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
