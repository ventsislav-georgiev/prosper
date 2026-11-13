import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #887 (QA #747 INFO-1 to INFO-7): the New session form's follow-ups. Offscreen only: models on fake stores, windows
/// built and never shown, ordered or made key; keys are built NSEvents handed to performKeyEquivalent or the pure
/// route. No dch runs (the spawn is `spawnSession`'s recorder), no panel, menu, pasteboard or real defaults.
extension AgentWindowD1Tests {

    /// A built key event for the pure route (window number 0, never posted).
    @MainActor
    func formKey(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    // MARK: INFO-1: a start that is answered but never listed

    /// dch --spawn answers 0 for a program that exec'd and already exited (dch.c v1.58.0 :5540-5545). The answer arms a
    /// deadline of its own just past spawnSlack (not the 30 s age clock); when it fires with no row, the form stays,
    /// re-enabled, with one fixed sentence. A quick shell's says it on the window's dir line.
    @MainActor
    func testAgentWindowNewSessionUnlistedStartSaysWhyAtItsOwnDeadline() throws {
        try withNewSessionPrefs {
            final class Clock { var t = AgentWindowD1Tests.now }
            let other = mapped("other"), clock = Clock(), st = store([other]), spawns = SpawnCalls()
            let m = newSessionModel(st, spawns)
            defer { m.close() }
            m.now = { clock.t }
            m.select(.live(other.key))   // a first listed row is otherwise selected as the window fills (#828)
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            XCTAssertTrue(m.spawnDeadline == nil, "no answer yet: no deadline")
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            let deadline = try XCTUnwrap(m.spawnDeadline, "the answer arms its own deadline")
            XCTAssertEqual(deadline.fireDate.timeIntervalSinceNow, AgentWindowModel.spawnSlack + 0.5, accuracy: 1,
                           "just past the slack, not the next refresh")
            XCTAssertGreaterThan(m.ageInterval, AgentWindowModel.spawnSlack + 0.5, "the age clock would come later")
            XCTAssertEqual(m.newSessionStatus, "Starting web…")
            clock.t += AgentWindowModel.spawnSlack + 1
            let rebuilt = m.refreshes
            deadline.fire()
            XCTAssertGreaterThan(m.refreshes, rebuilt, "the deadline rebuilds and decides")
            XCTAssertNotNil(m.newSession, "the form stays")
            XCTAssertTrue(m.newSession?.starting == nil, "re-enabled")
            XCTAssertEqual(m.newSessionStatus, "web ended at once or never started: check the command")
            XCTAssertEqual(m.newSessionStatus, AgentWindowModel.notListedText("web"))
            XCTAssertTrue(m.canStartNewSession, "Start can run again")
            XCTAssertTrue(m.pendingSpawn == nil)
            XCTAssertTrue(m.spawnDeadline == nil, "one-shot")
            st.sessions = [other, mapped("web")]
            XCTAssertEqual(m.selection, .live(other.key), "a late row selects nothing")
            XCTAssertNotNil(m.newSession)
            // A quick shell: the dir line the window draws under its sidebar.
            m.cancelNewSession()
            st.sessions = [other]
            XCTAssertTrue(m.startShell())
            let shell = try XCTUnwrap(spawns.calls.last?.name)
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: shell), nil)
            clock.t += AgentWindowModel.spawnSlack + 1
            try XCTUnwrap(m.spawnDeadline).fire()
            XCTAssertEqual(st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "")], AgentWindowModel.notListedText(shell))
            XCTAssertEqual(st.dirStatus, AgentWindowModel.notListedText(shell))
            XCTAssertNil(m.newSession, "no form opened for it")
            // Closing the window drops a pending deadline.
            XCTAssertTrue(m.startShell())
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: spawns.calls.last?.name ?? "?"), nil)
            let last = try XCTUnwrap(m.spawnDeadline)
            XCTAssertTrue(m.startShell())   // its answer comes after the close
            let late = spawns.done.last, lateName = spawns.calls.last?.name ?? "?"
            m.close()
            XCTAssertFalse(last.isValid, "a closed window leaves no timer")
            late?(AgentSessionKey(dir: "/tmp/dch-test", name: lateName), nil)
            XCTAssertTrue(m.spawnDeadline == nil, "an answer after the close arms no deadline")
            m.spawnDeadline?.invalidate()
        }
    }

    // MARK: INFO-2: the row first

    /// Start, then the window hides (another Space) past the slack: its row was listed meanwhile. Shown again, the
    /// row lands (selected, Terminal) instead of the expiry closing the form.
    @MainActor
    func testAgentWindowNewSessionHiddenPastTheSlackStillLandsAListedRow() throws {
        try withNewSessionPrefs {
            final class Clock { var t = AgentWindowD1Tests.now }
            let clock = Clock(), other = mapped("other"), st = store([other]), spawns = SpawnCalls()
            let m = newSessionModel(st, spawns)
            defer { m.close() }
            m.now = { clock.t }
            m.select(.live(other.key))
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            m.setVisible(false)
            clock.t += AgentWindowModel.spawnSlack + 5
            st.sessions = [other, mapped("web")]   // listed while hidden: nothing is rebuilt
            m.spawnDeadline?.fire()                // hidden: the deadline decides nothing
            XCTAssertNotNil(m.pendingSpawn, "hidden: still pending")
            XCTAssertEqual(m.newSessionStatus, "Starting web…")
            m.setVisible(true)
            XCTAssertEqual(m.selection, live("web"), "shown again: the listed row lands")
            XCTAssertNil(m.newSession, "the form closed by the landing")
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertTrue(m.pendingSpawn == nil)
        }
    }

    // MARK: INFO-3: the window says why

    /// ⇧⌘N (and ⌘N) refused by the gate with no form open: the window's dir strip under the sidebar says why, in a
    /// fixed slot; nothing starts or opens. (A refusal by name or runner, and the runner's failure, already land on
    /// that line: testAgentWindowNewSessionRefusalNamesItsCause, AgentIslandControlsTests.)
    @MainActor
    func testAgentWindowNewSessionRefusedQuickShellSaysWhyInTheWindow() throws {
        try withNewSessionPrefs {
            let st = store([mapped("a")]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            let size = CGSize(width: sz(290), height: AgentWindowControls.stripHeight)
            XCTAssertNil(ink(try wiringRender(AgentDirStatusStrip(store: st), size, backing: 2), CGRect(origin: .zero, size: size)),
                         "nothing to say yet")
            st.controlDch = nil
            let why = try XCTUnwrap(st.resumeGate.refusal)
            settle(host)
            XCTAssertTrue(win.performKeyEquivalent(with: shiftCmdN(win)), "handled: no beep")
            XCTAssertEqual(spawns.calls.count, 0, "nothing started")
            XCTAssertEqual(st.dirStatus, "Controls \(why)", "⇧⌘N says why")
            XCTAssertNotNil(ink(try wiringRender(AgentDirStatusStrip(store: st), size, backing: 2), CGRect(origin: .zero, size: size)),
                            "drawn in the window's strip")
            XCTAssertEqual(NSHostingView(rootView: AgentDirStatusStrip(store: st).frame(width: size.width)).fittingSize.height,
                           AgentWindowControls.stripHeight, accuracy: 1, "the strip's fixed slot")
            st.actions = [:]
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)))
            XCTAssertNil(m.newSession, "⌘N opened nothing")
            XCTAssertEqual(st.dirStatus, "Controls \(why)", "⌘N says why too")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: INFO-4: the chords under the form

    /// Every window chord with the form open: the window's own (⌘W, ⌘N, ⇧⌘N) as before; those that act on the pane
    /// the form covers are swallowed; a text field keeps ⌘↑/⌘↓; the sidebar keys are unchanged.
    @MainActor
    func testAgentWindowKeysWhileTheFormIsOpenRouteRows() {
        typealias R = AgentsNSWindow.KeyRoute
        let up = formKey(126, "\u{F700}", .command), down = formKey(125, "\u{F701}", .command)
        for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
            for terminal in [true, false] {
                let tag = "\(r) terminal \(terminal)"
                func route(_ e: NSEvent, form: Bool = true) -> R {
                    AgentsNSWindow.route(e, responder: r, sidebarFocused: false, terminalMode: terminal, form: form)
                }
                XCTAssertEqual(route(formKey(13, "w", .command)), .close, tag)
                XCTAssertEqual(route(formKey(45, "n", .command)), .newSession, tag)
                XCTAssertEqual(route(formKey(45, "N", [.command, .shift])), .newShell, tag)
                XCTAssertEqual(route(formKey(17, "t", .command)), .swallow, "⌘T \(tag)")
                XCTAssertEqual(route(formKey(17, "t", .command), form: false), .toggleMode, "no form: ⌘T toggles \(tag)")
                XCTAssertEqual(route(formKey(3, "f", .command)), terminal ? .swallow : .pass, "⌘F \(tag)")
                XCTAssertEqual(route(formKey(5, "g", .command)), terminal ? .swallow : .pass, "⌘G \(tag)")
                XCTAssertEqual(route(formKey(5, "G", [.command, .shift])), terminal ? .swallow : .pass, "⇧⌘G \(tag)")
                for v in AgentVerbosity.allCases {
                    XCTAssertEqual(route(formKey(v.keyCode, "", [.command, .option])), .swallow, "⌥⌘ \(v) \(tag)")
                }
                XCTAssertEqual(route(up), r == .text ? .pass : .swallow, "⌘↑ \(tag)")
                XCTAssertEqual(route(down), r == .text ? .pass : .swallow, "⌘↓ \(tag)")
                XCTAssertEqual(route(down, form: false), r == .text ? .pass : .session(1), "no form: ⌘↓ moves \(tag)")
            }
        }
        XCTAssertEqual(AgentsNSWindow.route(formKey(125, "\u{F701}", []), responder: .other, sidebarFocused: true,
                                            terminalMode: true, form: true), .sidebar, "a sidebar arrow is the sidebar's")
    }

    /// The form open over a Terminal-mode session, the sidebar holding the keys: ⌘T and ⌘↓ are handled (no
    /// beep) and change nothing (no mode pref written, no pick); Return's focusSelection stands down.
    @MainActor
    func testAgentWindowNewSessionChordsStandDownUnderTheForm() throws {
        try withNewSessionPrefs {
            let a = mapped("a", ago: 1), b = mapped("b", ago: 2), st = store([a, b]), spawns = SpawnCalls()
            let m = wiringModel(st, spawns)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(.live(a.key))
            settle(host)
            m.openNewSession()
            settle(host)
            sidebarKeys(win)
            XCTAssertEqual(win.responderKind, .other)
            let keys = m.transcriptKeys
            XCTAssertTrue(win.performKeyEquivalent(with: wiringKey(win, 17, "t", .command)), "⌘T handled")
            XCTAssertEqual(m.transcriptKeys, keys, "no mode written for the hidden session")
            XCTAssertEqual(m.mode(a), .terminal)
            XCTAssertTrue(win.performKeyEquivalent(with: wiringKey(win, 125, "\u{F701}", .command)), "⌘↓ handled")
            XCTAssertEqual(m.selection, .live(a.key), "no pick")
            XCTAssertNotNil(m.newSession, "the form stays")
            XCTAssertFalse(m.focusSelection(), "Return or Right in the sidebar: the covered session takes no keys")
            XCTAssertFalse(m.terminal.focusPending)
            XCTAssertNotNil(m.newSession)
            XCTAssertEqual(formFields(host).count, 3)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: INFO-5: the keys back where they were, Transcript and pending

    /// QA #747 M7: the form took the keys from the Transcript input box: Cancel puts them back in it. A focus still
    /// pending when the form opened counts as the keys (the terminal's, which the detach drops; the input box's,
    /// dropped meanwhile by a sidebar mouse-down): Cancel asks again.
    @MainActor
    func testAgentWindowNewSessionKeysComeBackToTheInputBoxOrAPendingFocus() throws {
        try withNewSessionPrefs {
            let a = mapped("a"), st = store([a]), m = wiringModel(st, SpawnCalls())
            defer { m.close() }
            m.setMode(.transcript, for: a)
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(.live(a.key))
            settle(host)
            sidebarKeys(win)
            clickRow("a", m, win, host)
            let box = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first)
            XCTAssertTrue(win.firstResponder === box, "the keys in a's input box")
            m.openNewSession()
            settle(host)
            XCTAssertEqual(formFields(host).count, 3)
            XCTAssertTrue(focusViews(host, AgentComposerTextView.self).isEmpty, "the input box left with the pane")
            m.cancelNewSession()
            settle(host)
            let again = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first)
            XCTAssertTrue(win.firstResponder === again, "Cancel: the keys back in the input box")
            // Opened from the sidebar: Cancel leaves the keys there.
            sidebarKeys(win)
            m.openNewSession()
            settle(host)
            m.cancelNewSession()
            settle(host)
            XCTAssertFalse(win.firstResponder is AgentComposerTextView, "the sidebar keeps them")
            XCTAssertFalse(win.isVisible, "never shown")

            // The terminal's pending focus (no view yet): the detach drops it, Cancel asks again.
            let b = mapped("b"), mt = newSessionModel(store([b]), SpawnCalls())
            defer { mt.close() }
            mt.select(.live(b.key))
            XCTAssertTrue(mt.focusSelection())
            XCTAssertTrue(mt.terminal.focusPending, "pending: no terminal view in a window")
            mt.openNewSession()
            XCTAssertFalse(mt.terminal.focusPending, "the form detached the terminal")
            mt.cancelNewSession()
            XCTAssertTrue(mt.terminal.focusPending, "Cancel asks for the keys again")

            // The input box's pending focus, dropped while the form is open (a sidebar mouse-down): Cancel asks again.
            let c = mapped("c"), mc = newSessionModel(store([c]), SpawnCalls())
            defer { mc.close() }
            mc.setMode(.transcript, for: c)
            mc.select(.live(c.key))
            XCTAssertTrue(mc.focusSelection())
            XCTAssertTrue(mc.interaction.composerFocusPending, "pending: no input box in a window")
            mc.openNewSession()
            mc.dropPendingFocus()
            XCTAssertFalse(mc.interaction.composerFocusPending)
            mc.cancelNewSession()
            XCTAssertTrue(mc.interaction.composerFocusPending, "Cancel asks for the keys again")
        }
    }

    // MARK: INFO-6, INFO-7

    /// Every element under `e` in an AX client's walk (accessibilityChildren), depth first: role, label (AXDescription)
    /// and title (AXTitle). Read through KVC because a SwiftUI button's title is an attributed string.
    @MainActor
    func axWalk(_ e: Any, _ out: inout [(role: String, label: String, title: String)], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        out.append((text("accessibilityRole"), text("accessibilityLabel"), text("accessibilityTitle")))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { axWalk(k, &out, depth: depth + 1) }
    }

    /// QA #747 INFO-6, QA #826: VoiceOver reads the form's fields by name, not by placeholder (their label), and the
    /// recents menu by its title. Read off the real accessibility tree: SwiftUI builds it in a never-shown window once
    /// this process (only) is asked to, as an AX client's attribute write would; both attributes are put back after.
    /// Named to run first in AgentWindowD1Tests.
    @MainActor
    func testAccessibilityTreeReadsTheNewSessionFormByName() {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        // NSApp is nil until something creates the application; this test may run first in the process.
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        withNewSessionPrefs {
            let m = wiringModel(store([mapped("a", ago: 1)]), SpawnCalls())
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
            m.openNewSession()
            XCTAssertFalse(m.newSessionRecents.isEmpty, "the menu is enabled")
            // The tree fills in on the run loop: poll for the form's four controls, with a deadline.
            var tree: [(role: String, label: String, title: String)] = []
            let deadline = Date().addingTimeInterval(5)
            repeat {
                settle(host)
                tree = []
                axWalk(host, &tree)
            } while (tree.filter { $0.role == "AXTextField" }.count < 3 || !tree.contains { $0.role == "AXMenuButton" })
                && Date() < deadline
            print("#887 a11y tree:\n" + tree.map { "  \($0.role) label=\($0.label) title=\($0.title)" }.joined(separator: "\n"))
            XCTAssertEqual(tree.filter { $0.role == "AXTextField" }.map(\.label), ["Folder", "Name", "Command"])
            XCTAssertEqual(tree.filter { $0.role == "AXMenuButton" }.map(\.title), ["Recent folders"])
        }
    }

    /// QA #747 INFO-7 (b): the empty sidebar names + and ⌘N only while they work.
    @MainActor
    func testAgentWindowNoSessionsHintFollowsTheGate() {
        XCTAssertEqual(AgentNoSessionsState.detail(canStart: true),
                       "Sessions started with dch show up here. Press + or ⌘N to start one.")
        XCTAssertEqual(AgentNoSessionsState.detail(canStart: false), "Sessions started with dch show up here.")
    }
}
