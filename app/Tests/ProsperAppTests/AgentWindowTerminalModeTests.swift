import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #822 P1: Transcript | Terminal in the Agent Sessions window. Terminal is the default for a live session,
/// Transcript remembered per session name, rows with nothing to attach shown as Transcript,
/// the terminal attached only to a visible, selected, live session in Terminal mode, the window's
/// key routing, and offscreen renders showing a toggle moves neither the header nor the sidebar.
/// No dch runs: the terminal's spawn is a recorder. Windows are never shown, keys are built events.
extension AgentWindowD1Tests {

    static let modePref = "agentWindowTranscriptSessions"

    func mapped(_ name: String, _ state: AgentState = .idle, ago: TimeInterval = 60) -> AgentSession {
        session(name, state, ago: ago, path: "/Users/example/.claude/projects/p/0b7c2f3e-1111-2222-3333-444455556666.jsonl")
    }

    /// The window model's terminal on recorders; the grid known, as if its view had laid out.
    @MainActor
    func fakeTerminal(_ m: AgentWindowModel) -> (spawned: () -> [AgentTerminalSpawn], children: () -> [AgentTerminalTests.FakeChild]) {
        final class Log { var spawns: [AgentTerminalSpawn] = []; var children: [AgentTerminalTests.FakeChild] = [] }
        let log = Log()
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { req, _ in
            log.spawns.append(req)
            let c = AgentTerminalTests.FakeChild()
            log.children.append(c)
            return c
        }
        m.terminal.makeScreen = { [weak t = m.terminal] events in
            // The screen runs at the view's grid at once (libghostty reports it from its IO thread).
            if let t, let g = t.grid { t.gridChanged(cols: g.cols, rows: g.rows, generation: t.generation) }
            return AgentTerminalTests.FakeScreen(events)
        }
        m.terminal.after = { _, _ in }
        m.terminal.clientVersion = { _ in [1, 40, 0] }
        m.terminal.gridChanged(cols: 80, rows: 24)
        return ({ log.spawns }, { log.children })
    }

    @MainActor
    func withModePref(_ body: () throws -> Void) rethrows {
        let saved = Preferences.defaults.object(forKey: Self.modePref)
        defer { Preferences.defaults.set(saved, forKey: Self.modePref) }
        Preferences.defaults.removeObject(forKey: Self.modePref)
        try body()
    }

    // MARK: Terminal by default, Transcript remembered by session name

    @MainActor
    func testAgentWindowTerminalModeIsTheDefaultAndTranscriptIsRememberedPerSessionName() throws {
        try withModePref {
            let one = mapped("one"), two = mapped("two")
            let m = windowModel(store([one, two]))
            m.setVisible(true)
            defer { m.close() }
            XCTAssertEqual(m.mode(one), .terminal, "a live session opens in Terminal (operator, 2026-11-10)")
            m.select(.live(one.key))
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertNil(Preferences.defaults.stringArray(forKey: Self.modePref), "nothing written for the default")
            m.setMode(.transcript, for: one)
            XCTAssertEqual(m.paneMode, .transcript)
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), ["/tmp/dch-test\tone"],
                           "written through Preferences.defaults as <dir>\\t<name>")
            XCTAssertEqual(m.mode(two), .terminal, "per session")
            XCTAssertFalse(SyncedKeys.isSynced(Self.modePref), "per Mac, not synced")
            // A new window, and a later session reusing the name, inherit the choice.
            let again = windowModel(store([mapped("one", .working, ago: 5)]))
            XCTAssertEqual(again.mode(mapped("one", .working, ago: 5)), .transcript)
            XCTAssertEqual(again.mode(session("one", .idle, dir: "/tmp/other-dir")), .terminal, "the dir is part of the key")
            m.setMode(.transcript, for: two)
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), ["/tmp/dch-test\ttwo", "/tmp/dch-test\tone"],
                           "newest first")
            m.setMode(.transcript, for: two)
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), ["/tmp/dch-test\ttwo", "/tmp/dch-test\tone"],
                           "set again: still once")
            m.setMode(.terminal, for: one)
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), ["/tmp/dch-test\ttwo"], "Terminal removes it")
            XCTAssertEqual(m.paneMode, .terminal)
            // The 65th evicts the oldest.
            Preferences.defaults.set((0..<64).map { "/tmp/dch-test\tk\($0)" }, forKey: Self.modePref)
            let full = windowModel(store([one]))
            full.setMode(.transcript, for: one)
            let keys = try XCTUnwrap(Preferences.defaults.stringArray(forKey: Self.modePref))
            XCTAssertEqual(keys.count, 64)
            XCTAssertEqual(keys.first, "/tmp/dch-test\tone")
            XCTAssertEqual(keys.last, "/tmp/dch-test\tk62", "k63, the oldest, went")
            full.close()
            again.close()
        }
    }

    @MainActor
    func testAgentWindowTerminalModeIsTheDefaultForSessionsWithNoTranscriptToo() throws {
        try withModePref {
            let raw = session("raw", .idle)   // no claude_session_id: nothing to show as a transcript
            let old = AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: "old"), alias: "", activity: 1, state: .idle,
                                   agents: 0, version: "1.29.9", claudeSessionID: "0b7c2f3e-1111-2222-3333-444455556666",
                                   transcriptPath: "/Users/example/.claude/projects/p/0b7c2f3e-1111-2222-3333-444455556666.jsonl")
            let m = windowModel(store([raw, old, mapped("ok")]))
            defer { m.close() }
            XCTAssertEqual(m.mode(raw), .terminal)
            XCTAssertEqual(m.mode(old), .terminal)
            XCTAssertEqual(m.mode(mapped("ok")), .terminal, "mapped or not")
            XCTAssertNil(Preferences.defaults.stringArray(forKey: Self.modePref), "nothing written for the default")
            m.setMode(.transcript, for: raw)
            XCTAssertEqual(m.mode(raw), .transcript, "Transcript anyway (the terminal-first card), remembered like any other")
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), ["/tmp/dch-test\traw"])
            XCTAssertEqual(windowModel(store([raw])).mode(raw), .transcript)
            m.setMode(.terminal, for: raw)
            XCTAssertEqual(m.mode(raw), .terminal)
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), [])
        }
    }

    /// History, an ended session's held row, a session gone, nothing selected: Transcript, nothing remembered,
    /// no client, and the toggle off (⌘T passes).
    @MainActor
    func testAgentWindowTerminalModeNeverShowsWhereNothingCanAttach() throws {
        try withModePref {
            let a = mapped("a"), b = mapped("b")
            let st = store([a, b], history: [record("h")])
            st.controlDch = bin([1, 38, 0])
            let m = windowModel(st)
            let t = fakeTerminal(m)
            Calls().wire(m)
            m.setVisible(true)
            defer { m.close() }
            XCTAssertEqual(t.spawned().count, 1, "shown: the first row is selected, in Terminal")
            m.select(nil)
            XCTAssertEqual(t.children().map(\.terminated), [1], "nothing selected: detached")
            XCTAssertEqual(m.paneMode, .transcript, "nothing selected")
            XCTAssertFalse(m.toggleMode())
            m.select(.history(AgentSessionKey(dir: "/tmp/dch-test", name: "h")))
            XCTAssertEqual(m.paneMode, .transcript, "a History row")
            XCTAssertFalse(m.toggleMode(), "a History row: nothing to toggle")
            XCTAssertEqual(t.spawned().count, 1, "a History row: nothing attached")
            m.select(.live(a.key))
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertEqual(t.spawned().count, 2)
            // Stopped from the window: the row goes before its record, the selection is held (QA #668 F1).
            m.ask(.stop, a)
            m.confirm(true)
            st.sessions = [b]
            XCTAssertTrue(m.selectionIsHeld)
            XCTAssertEqual(m.paneMode, .transcript, "ended: Transcript, no terminal card")
            XCTAssertEqual(m.mode(a), .terminal, "the session's own choice is untouched")
            XCTAssertEqual(t.children().last?.terminated, 1, "held: the client goes")
            XCTAssertFalse(m.toggleMode(), "ended: nothing to toggle")
            m.setMode(.transcript, for: a)
            XCTAssertNil(Preferences.defaults.stringArray(forKey: Self.modePref), "ended: nothing remembered")
            m.setMode(.terminal, for: a)
            XCTAssertEqual(m.paneMode, .transcript)
            XCTAssertEqual(t.spawned().count, 2, "and nothing attaches to an ended session")
            XCTAssertNil(m.interaction.session, "nor takes input")
            // The header toggle on the held row: off, with the reason as its help (offscreen render for review).
            XCTAssertEqual(AgentPaneModeToggle.endedReason, "This session ended: there is no terminal to attach to")
            try save(render(AgentWindowRootView(model: m, scrolls: false), size: CGSize(width: 1000, height: 680), dark: true),
                     "822-ended-1.0")
            // QA #681 INFO-7: the held row's header hands the toggle the reason, its tooltip in every style; a live
            // row's toggle has none (the view's dump: no accessibility tree is built offscreen).
            let reason = "\"\(AgentPaneModeToggle.endedReason)\""
            for style in [AgentVerbosityPicker.Style.labels, .icons, .menu] {
                for ended in [true, false] {
                    var out = ""
                    let h = AgentSessionHeader(row: try XCTUnwrap(m.selectedRow), session: a, cwd: nil, open: {},
                                               ended: ended, mode: .transcript, setMode: { _ in })
                    dump(h.shownLine(picker: style), to: &out)
                    XCTAssertTrue(out.contains("AgentPaneModeToggle"), "\(style)")
                    XCTAssertEqual(out.contains(reason), ended, "\(style) ended: \(ended)")
                }
            }
            XCTAssertFalse(m.terminal.isSelected(a.key), "OQ-66: a held (ended) row is no selection a write can use")
            // The session gone with no hold: the selection clears, Transcript (the empty state).
            m.select(.live(b.key))
            st.sessions = []
            XCTAssertNil(m.selection)
            XCTAssertEqual(m.paneMode, .transcript)
        }
    }

    // MARK: Attach conditions

    @MainActor
    func testAgentWindowTerminalAttachesOnlyToAVisibleSelectedLiveSessionInTerminalMode() throws {
        try withModePref {
            let one = mapped("one"), two = mapped("two")
            let st = store([one, two], history: [record("h")])
            let m = windowModel(st)
            let t = fakeTerminal(m)
            func terminated() -> [Int] { t.children().map(\.terminated) }
            m.setMode(.transcript, for: two)   // two in Transcript, one in the default Terminal
            m.setVisible(true)
            m.select(.live(one.key))
            XCTAssertEqual(t.spawned().map(\.args), [["-E", "-a", "one"]], "the default Terminal attaches")
            XCTAssertTrue(m.terminal.isSelected(one.key), "OQ-66: the selection is the session a write may come from")
            XCTAssertFalse(m.terminal.isSelected(two.key))
            XCTAssertEqual(m.terminal.phase, .live)
            XCTAssertNil(m.interaction.session, "Terminal mode: no input box, no prompt reads")
            XCTAssertTrue(m.transcript.running, "the transcript keeps the header's cwd and todos")
            m.setVisible(false)
            XCTAssertEqual(terminated(), [1], "hidden: detached")
            XCTAssertEqual(m.terminal.phase, .idle)
            m.setVisible(true)
            XCTAssertEqual(t.spawned().count, 2, "shown again: attached again")
            m.select(.live(two.key))
            XCTAssertEqual(m.interaction.session?.key, two.key, "Transcript mode: the input box is its")
            XCTAssertEqual(terminated(), [1, 1], "another session in Transcript mode: detached")
            XCTAssertEqual(t.spawned().count, 2)
            m.select(.live(one.key))
            XCTAssertEqual(t.spawned().count, 3)
            m.select(.history(AgentSessionKey(dir: "/tmp/dch-test", name: "h")))
            XCTAssertEqual(terminated(), [1, 1, 1], "a History row: nothing attached")
            XCTAssertEqual(t.spawned().count, 3)
            m.select(.live(one.key))
            m.refresh()
            m.select(.live(one.key))
            XCTAssertEqual(t.spawned().count, 4, "a refresh or the same selection does not reattach")
            st.sessions = [two]
            XCTAssertNil(m.selection)
            XCTAssertEqual(terminated(), [1, 1, 1, 1], "the session ended: detached")
            m.select(.live(two.key))
            XCTAssertEqual(m.toggleMode(), true, "two: Transcript to Terminal")
            XCTAssertEqual(t.spawned().last?.args, ["-E", "-a", "two"])
            m.toggleMode()
            XCTAssertEqual(terminated().last, 1, "back to Transcript: detached")
            XCTAssertEqual(m.interaction.session?.key, two.key)
            m.toggleMode()
            m.close()
            XCTAssertEqual(terminated().last, 1, "closed: detached")
            XCTAssertEqual(m.terminal.phase, .idle)
            XCTAssertEqual(t.spawned().count, 6)
            m.select(nil)
            XCTAssertFalse(m.toggleMode(), "nothing selected: nothing to toggle")
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref) ?? [], [], "toggled back: none remembered")
            // The held row (an ended session): testAgentWindowTerminalModeNeverShowsWhereNothingCanAttach.
        }
    }

    // MARK: Keys (spec 5.3, QA #669)

    @MainActor
    func testAgentWindowKeyRoutesForEveryResponder() {
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        typealias R = AgentsNSWindow.KeyRoute
        func route(_ e: NSEvent, _ r: AgentsNSWindow.ResponderKind, sidebar: Bool = false, terminal: Bool = true) -> R {
            AgentsNSWindow.route(e, responder: r, sidebarFocused: sidebar, terminalMode: terminal)
        }
        let all: [AgentsNSWindow.ResponderKind] = [.text, .terminal, .other]
        let up = key(126, "\u{F700}", [.command, .numericPad, .function])
        let down = key(125, "\u{F701}", [.command, .numericPad, .function])
        for r in all {
            XCTAssertEqual(route(key(13, "w", .command), r), .close)
            XCTAssertEqual(route(key(17, "t", .command), r), .toggleMode, "⌘T from anywhere (\(r))")
            XCTAssertEqual(route(key(17, "t", .command), r, terminal: false), .toggleMode)
            XCTAssertEqual(route(key(3, "f", .command), r), .find)
            XCTAssertEqual(route(key(3, "f", .command), r, terminal: false), .pass, "no find bar over the transcript")
            XCTAssertEqual(route(key(5, "g", .command), r), .findNext(true))
            XCTAssertEqual(route(key(5, "g", [.command, .shift]), r), .findNext(false))
            XCTAssertEqual(route(key(18, "1", [.command, .option]), r), .swallow, "⌥⌘1 does nothing in Terminal mode")
            XCTAssertEqual(route(key(18, "1", [.command, .option]), r, terminal: false), .verbosity(.focused))
        }
        // QA #669: ⌘↑/⌘↓ move between sessions, except in a text view (start / end of the text there).
        XCTAssertEqual(route(up, .text), .pass)
        XCTAssertEqual(route(down, .text, terminal: false), .pass)
        XCTAssertEqual(route(up, .terminal), .session(-1))
        XCTAssertEqual(route(down, .terminal), .session(1))
        XCTAssertEqual(route(up, .other, terminal: false), .session(-1))
        XCTAssertEqual(route(down, .other, sidebar: true), .session(1))
        XCTAssertEqual(route(key(126, "\u{F700}", [.command, .shift]), .other), .pass, "⇧⌘↑ is not the window's")
        // The program's keys: Esc, Tab, ⇧Tab, ⌃C, arrows, Return, ⇧Return, function keys.
        for e in [key(53, "\u{1b}"), key(48, "\t"), key(48, "\t", .shift), key(8, "c", .control), key(126, "\u{F700}"),
                  key(36, "\r"), key(36, "\r", .shift), key(122, "\u{F704}", .function), key(0, "a"), key(14, "é", .option)] {
            XCTAssertEqual(route(e, .terminal, sidebar: true), .pass, "key \(e.keyCode) goes to the terminal")
            XCTAssertEqual(route(e, .text, sidebar: true), .pass)
        }
        // The sidebar's plain keys: only while it has the focus and nothing that types does.
        for code: UInt16 in [126, 125, 123, 124, 36, 76] {
            XCTAssertEqual(route(key(code), .other, sidebar: true), .sidebar)
            XCTAssertEqual(route(key(code), .other, sidebar: false), .pass)
            XCTAssertEqual(route(key(code), .terminal, sidebar: true), .pass, "the terminal keeps its arrows and Return")
            XCTAssertEqual(route(key(code), .text, sidebar: true), .pass)
        }
        let keyUp = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17)!
        XCTAssertEqual(route(keyUp, .other), .pass)
    }

    @MainActor
    func testAgentWindowCommandArrowsSkipATextViewAndTheTerminalKeepsItsKeys() throws {
        try withModePref {
            var opened: [String] = []
            let m = windowModel(store([mapped("a", ago: 1), mapped("b", ago: 2), mapped("c", ago: 3)]), opened: { opened.append($0.name) })
            _ = fakeTerminal(m)
            m.setMode(.transcript, for: mapped("b", ago: 2))
            m.setVisible(true)
            defer { m.close() }
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.model = m
            func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            let cmdDown = key(125, "\u{F701}", [.command, .numericPad, .function])
            let cmdUp = key(126, "\u{F700}", [.command, .numericPad, .function])
            m.select(live("a"))
            // A text view (the composer, a field) first: ⌘↓ is its own (end of text).
            let tv = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 20))
            tv.string = "draft"
            win.contentView?.addSubview(tv)
            XCTAssertTrue(win.makeFirstResponder(tv))
            XCTAssertFalse(win.performKeyEquivalent(with: cmdDown))
            XCTAssertEqual(m.selection, live("a"), "⌘↓ stayed in the text view")
            // Nothing that types: previous / next session.
            XCTAssertTrue(win.makeFirstResponder(nil))
            XCTAssertTrue(win.performKeyEquivalent(with: cmdDown))
            XCTAssertEqual(m.selection, live("b"))
            XCTAssertTrue(win.performKeyEquivalent(with: cmdUp))
            XCTAssertEqual(m.selection, live("a"))
            // ⌘T: Transcript, remembered; ⌘T again: Terminal, and the focus goes to the terminal once its
            // view is in the window.
            XCTAssertEqual(m.paneMode, .terminal, "the default")
            XCTAssertTrue(win.performKeyEquivalent(with: key(17, "t", .command)))
            XCTAssertEqual(m.paneMode, .transcript)
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), ["/tmp/dch-test\ta", "/tmp/dch-test\tb"])
            XCTAssertTrue(win.performKeyEquivalent(with: key(17, "t", .command)))
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), ["/tmp/dch-test\tb"])
            XCTAssertTrue(m.terminal.focusPending)
            let host = AgentTerminalHostView(frame: .init(x: 0, y: 0, width: 200, height: 100))
            host.owner = m.terminal
            m.terminal.view = host
            win.contentView?.addSubview(host)
            XCTAssertTrue(win.firstResponder === host, "the pending focus landed when the view joined the window")
            XCTAssertFalse(m.terminal.focusPending)
            XCTAssertEqual(win.responderKind, .terminal)
            // The terminal keeps plain arrows and Tab even with the sidebar focused; ⌘↓ is still the window's.
            win.sidebarFocused = true
            win.sendEvent(key(125, "\u{F701}", [.numericPad, .function]))
            XCTAssertEqual(m.selection, live("a"), "↓ went to the terminal, not the sidebar")
            win.sendEvent(key(48, "\t"))
            XCTAssertTrue(win.sidebarFocused, "Tab is the program's (mode cycle): the focus did not move on")
            XCTAssertTrue(win.performKeyEquivalent(with: cmdDown))
            XCTAssertEqual(m.selection, live("b"), "⌘↓ from the terminal")
            XCTAssertEqual(m.paneMode, .transcript, "b was set to Transcript")
            XCTAssertTrue(win.performKeyEquivalent(with: cmdUp))
            XCTAssertEqual(m.paneMode, .terminal)
            // ⌥⌘1 in Terminal mode: taken, nothing changes.
            let level = m.verbosity
            XCTAssertTrue(win.performKeyEquivalent(with: key(18, "1", [.command, .option])))
            XCTAssertEqual(m.verbosity, level)
            // Return on the sidebar row in Terminal mode: into the terminal, Ghostty not opened.
            XCTAssertTrue(win.makeFirstResponder(nil))
            win.sidebarFocused = true
            win.sendEvent(key(36, "\r"))
            XCTAssertEqual(opened, [], "Terminal mode: Return does not open Ghostty")
            XCTAssertTrue(win.firstResponder === host)
            // A click beside the sidebar leaves the keys with the terminal; a sidebar click takes them back,
            // so the arrows select again. (y 250: above the host view, so neither click lands on it.)
            func click(_ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 250), modifierFlags: [], timestamp: 0,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            win.sendEvent(click(sz(350)))
            XCTAssertFalse(win.sidebarFocused)
            XCTAssertTrue(win.firstResponder === host, "a click outside the sidebar keeps the terminal's keys")
            win.sendEvent(click(sz(100)))
            XCTAssertTrue(win.sidebarFocused)
            XCTAssertFalse(win.firstResponder === host, "a sidebar click resigns the terminal")
            win.sendEvent(key(125, "\u{F701}", [.numericPad, .function]))
            XCTAssertEqual(m.selection, live("b"), "the sidebar's down again")
            win.sendEvent(key(126, "\u{F700}", [.numericPad, .function]))
            XCTAssertEqual(m.selection, live("a"))
            // Transcript mode: #845 Return moves into the input box (pending: no pane builds it here), no app opens.
            XCTAssertTrue(win.performKeyEquivalent(with: key(17, "t", .command)))
            XCTAssertEqual(m.paneMode, .transcript)
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.modePref), ["/tmp/dch-test\ta", "/tmp/dch-test\tb"])
            XCTAssertTrue(win.makeFirstResponder(nil))
            win.sendEvent(key(36, "\r"))
            XCTAssertTrue(m.interaction.composerFocusPending)
            XCTAssertEqual(opened, [])
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: Offscreen: a toggle moves nothing (spec 5.5)

    @MainActor
    func testAgentWindowToggleMovesNeitherHeaderNorSidebar() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        try withModePref {
            let convo = Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl")
            let (m, st) = demoModel(convo)
            _ = fakeTerminal(m)
            defer { m.close() }
            let s = try XCTUnwrap(st.sessions.first { $0.name == "prosper" })
            for scale: CGFloat in [1.0, 0.85, 0.7] {
                ThemeRuntime.scale = scale
                for (label, size) in [("min", CGSize(width: 640 * scale, height: 420 * scale)),
                                      ("default", CGSize(width: 1000 * scale, height: 680 * scale))] {
                    m.setMode(.transcript, for: s)
                    let a = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                    m.setMode(.terminal, for: s)
                    let b = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                    let tag = "\(label)-\(scale)"
                    try save(a, "822-transcript-\(tag)")
                    try save(b, "822-terminal-\(tag)")
                    let px = CGFloat(a.pixelsWide) / (size.width + 24)
                    let side = Int((sz(290) * px).rounded(.down))
                    let headerBottom = { (rep: NSBitmapImageRep) in self.headerBottom(rep, x: side + Int(sz(8) * px)) }
                    let hb = try XCTUnwrap(headerBottom(a))
                    // #1103: one header height per mode: Terminal mode's one line, Transcript mode's title and folder lines.
                    XCTAssertLessThan(try XCTUnwrap(headerBottom(b)), hb, "Terminal mode's header is the lower one (\(tag))")
                    let line = 0..<Int((AgentSessionHeader.padTop + AgentSessionHeader.lineHeight) * px)   // the title line
                    XCTAssertEqual(differing(a, b, x: 0..<side, y: 0..<Int(size.height * px)), 0, "sidebar unchanged (\(tag))")
                    // The title (left) and the "⋯" (right) did not move on the title line. #1103: the title's first 60 pt (a
                    // cut title shows a different length of itself per mode: the picker in one, the folder and the todo
                    // chip in the other); the toggle's place: AgentWindowHeaderTests. At the minimum window below 1.0 the
                    // title keeps only its first letters, so that pair is not compared (report: a supervisor decision).
                    let detail = side + Int(sz(4) * px)   // past the sidebar's divider at every scale
                    let width = Int(size.width * px)
                    if label == "default" || scale == 1.0 {
                        XCTAssertEqual(differing(a, b, x: detail..<(detail + Int(sz(16 + 60) * px)), y: line), 0, "title unmoved (\(tag))")
                    }
                    let menuLeft = width - Int(sz(16 + 18 + 2) * px)   // the "⋯" Menu: 18 pt, 16 pt from the edge
                    // The "⋯" is an AppKit Menu (20 pt minimum, framed to 18): at 0.85 its glyph lands one device
                    // pixel apart depending on the pane below (Color.black there does it too), so ±1 px only.
                    XCTAssertEqual([-1, 0, 1].map { differing(a, b, x: menuLeft..<width, y: line, dx: $0, tolerance: 0.06) }.min(), 0,
                                   "\"⋯\" unmoved (\(tag))")
                    // Terminal mode: the terminal runs to the window's bottom (no input box under it).
                    let bottom = (Int(size.height * px) - Int(sz(30) * px))..<Int(size.height * px)
                    XCTAssertEqual(unlike(b, x: detail..<width, y: bottom), 0, "only the terminal background at the bottom (\(tag))")
                    XCTAssertGreaterThan(unlike(a, x: detail..<width, y: bottom), 0, "Transcript mode has its input box there (\(tag))")
                }
            }
        }
    }

    /// The first row under the header's top where the colour steps (the header's bottom edge).
    /// #860: the header sits on the window's backdrop gradient, so each row is compared with the
    /// row above it, not with the top row: a gradient drifts past 0.03 without any edge. Its dither
    /// steps up to ~0.031 row to row; the header's edge steps 0.19 or more (dark and light), so 0.1.
    func headerBottom(_ rep: NSBitmapImageRep, x: Int) -> Int? {
        guard var above = rep.colorAt(x: x, y: 4)?.usingColorSpace(.sRGB) else { return nil }
        for y in 5..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if abs(c.redComponent - above.redComponent) + abs(c.greenComponent - above.greenComponent)
                + abs(c.blueComponent - above.blueComponent) > 0.1 { return y }
            above = c
        }
        return nil
    }

    /// Pixels in the box that differ between `a` and `b` (`b` read `dx` pixels to the right).
    /// Reps of one layout compare raw bytes first, a row at a time: equal bytes are the same colour,
    /// so only a pixel whose bytes differ goes through colorAt and same() (#829 P3 r3: the per-pixel
    /// NSColors made the rename render test take 292 s).
    /// `tolerance`: see same(); the "⋯" ±1 px compares pass 0.06 (#860: shifted 1 px, the backdrop
    /// gradient's dither differs by up to ~0.035 where the glyph does not).
    func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, x: Range<Int>, y: Range<Int>, dx: Int = 0,
                   tolerance: CGFloat = 0.03) -> Int {
        let raw = RawPixels.pair(a, b)
        // The boxes colorAt answers for: in both reps, `b` shifted by dx.
        let lo = max(x.lowerBound, 0, -dx), hi = min(x.upperBound, a.pixelsWide, b.pixelsWide, b.pixelsWide - dx)
        guard lo < hi else { return 0 }
        var n = 0
        for yy in max(y.lowerBound, 0)..<max(y.lowerBound, 0, min(y.upperBound, a.pixelsHigh, b.pixelsHigh)) {
            if let r = raw, r.0.equal(lo, yy, r.1, lo + dx, yy, count: hi - lo) { continue }
            // colorAt and usingColorSpace autorelease 4 NSColors a pixel: drained per row, or a
            // whole-window compare loop holds them all (#829 P3 grew one xctest to 34 GB).
            autoreleasepool {
                for xx in lo..<hi {
                    if let r = raw, r.0.equal(xx, yy, r.1, xx + dx, yy) { continue }
                    if let c = a.colorAt(x: xx, y: yy), let d = b.colorAt(x: xx + dx, y: yy), !same(c, d, tolerance: tolerance) { n += 1 }
                }
            }
        }
        return n
    }

    /// Pixels in the box unlike its top-left one (the same raw bytes as it: alike, no colorAt).
    func unlike(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Int {
        guard let ref = rep.colorAt(x: x.lowerBound, y: y.lowerBound) else { return -1 }
        let raw = RawPixels(rep)
        var n = 0
        for yy in y where yy < rep.pixelsHigh {
            autoreleasepool {
                for xx in x where xx < rep.pixelsWide {
                    if let raw, xx >= 0, yy >= 0, raw.equal(xx, yy, raw, x.lowerBound, y.lowerBound) { continue }
                    if let p = rep.colorAt(x: xx, y: yy), !same(p, ref) { n += 1 }
                }
            }
        }
        return n
    }

    func same(_ p: NSColor, _ q: NSColor, tolerance: CGFloat = 0.03) -> Bool {
        guard let p = p.usingColorSpace(.sRGB), let q = q.usingColorSpace(.sRGB) else { return false }
        return abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
            + abs(p.blueComponent - q.blueComponent) <= tolerance
    }
}

/// #829 P3 r3: a rep's pixel bytes. Within one rep, or two of one layout, equal bytes are the same
/// colour, so a compare skips colorAt for them; any other pixel still goes through colorAt and same().
/// nil for a planar or not 8-bit rep (colorAt only).
struct RawPixels {
    let base: UnsafeMutablePointer<UInt8>, row: Int, size: Int

    init?(_ rep: NSBitmapImageRep) {
        guard !rep.isPlanar, rep.bitsPerSample == 8, rep.bitsPerPixel % 8 == 0, let d = rep.bitmapData else { return nil }
        base = d; row = rep.bytesPerRow; size = rep.bitsPerPixel / 8
    }

    /// Both, when `a` and `b` lay their bytes out alike (format, depth, colour space); else nil.
    static func pair(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (RawPixels, RawPixels)? {
        guard a.bitmapFormat == b.bitmapFormat, a.bitsPerPixel == b.bitsPerPixel, a.samplesPerPixel == b.samplesPerPixel,
              a.colorSpace == b.colorSpace, let p = RawPixels(a), let q = RawPixels(b) else { return nil }
        return (p, q)
    }

    /// `count` pixels from (x, y) here equal, byte for byte, those from (ox, oy) in `o`.
    func equal(_ x: Int, _ y: Int, _ o: RawPixels, _ ox: Int, _ oy: Int, count: Int = 1) -> Bool {
        memcmp(base + y * row + x * size, o.base + oy * o.row + ox * o.size, count * size) == 0
    }
}

extension XCTestCase {
    /// #822: a live session opens in Terminal. A test of Transcript behavior (the input box, the prompt
    /// panel, Return moving the keys into the input box) shows its sessions as Transcript, the store's by default;
    /// the per-Mac pref is put back at teardown so no later test inherits the choice.
    @MainActor
    func showTranscript(_ m: AgentWindowModel, _ sessions: [AgentSession]? = nil) {
        let key = "agentWindowTranscriptSessions"
        let saved = Preferences.defaults.stringArray(forKey: key)
        addTeardownBlock { Preferences.defaults.set(saved, forKey: key) }
        for s in sessions ?? m.store?.sessions ?? [] { m.setMode(.transcript, for: s) }
    }
}
