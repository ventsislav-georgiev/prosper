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
            // #1096 4: the deadline's interval as asked for, on a timer no run loop fires (no wall clock).
            final class Asked { var intervals: [TimeInterval] = [] }
            let asked = Asked()
            m.scheduleDeadline = { t, block in asked.intervals.append(t); return Timer(timeInterval: t, repeats: false, block: block) }
            m.select(.live(other.key))   // a first listed row is otherwise selected as the window fills (#828)
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            XCTAssertTrue(m.spawnDeadline == nil, "no answer yet: no deadline")
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            let deadline = try XCTUnwrap(m.spawnDeadline, "the answer arms its own deadline")
            XCTAssertEqual(asked.intervals, [AgentWindowModel.spawnSlack + 0.5], "just past the slack, not the next refresh")
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
            // #1096 1a: the late row lands; no text stays up and no second Start makes web-2.
            XCTAssertEqual(m.selection, live("web"), "a late row lands")
            XCTAssertNil(m.newSession, "the form and its sentence gone")
            XCTAssertFalse(m.startNewSession(), "no form: no second Start")
            XCTAssertEqual(spawns.calls.count, 1)
            // A quick shell: the dir line the window draws under its sidebar.
            m.cancelNewSession()
            st.sessions = [other]
            XCTAssertTrue(m.startShell())
            let shell = try XCTUnwrap(spawns.calls.last?.name)
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: shell), nil)
            clock.t += AgentWindowModel.spawnSlack + 1
            try XCTUnwrap(m.spawnDeadline).fire()
            XCTAssertEqual(st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "")], "\(shell) ended at once or never started",
                           "#1096 4: nothing typed: no \"check the command\"")
            XCTAssertEqual(st.dirStatus, AgentWindowModel.notListedText(shell, command: false))
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

    // MARK: #1096: the never-started sentence only when it is true

    /// #1096 1b: the island off after the answer (the form goes: it started) drops the pending start too, so the
    /// island back past the slack, before its first poll lists the session, says nothing over a session that runs.
    @MainActor
    func testAgentWindowNewSessionIslandOffDropsThePendingStart() throws {
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
            XCTAssertNotNil(m.pendingSpawn)
            m.bind(nil)
            XCTAssertNil(m.newSession, "answered: it started, the form goes")
            XCTAssertTrue(m.pendingSpawn == nil, "and its pending start")
            XCTAssertTrue(m.spawnDeadline == nil, "with its deadline")
            clock.t += AgentWindowModel.spawnSlack + 5
            m.bind(st)   // back before the poll lists web
            XCTAssertTrue(st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "")] == nil, "no never-started line")
            XCTAssertTrue(m.dirLine == nil)
        }
    }

    /// #1096 1c: hidden (another Space), the store listed the start and then lost it: it ran and ended. Shown again
    /// it is not called never started: the waiting form goes, no sentence anywhere. Never listed while hidden: the
    /// sentence as before.
    @MainActor
    func testAgentWindowNewSessionEndedWhileHiddenIsNotNeverStarted() throws {
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
            st.sessions = [other, mapped("web")]   // the store saw it run
            st.sessions = [other]                  // and end
            clock.t += AgentWindowModel.spawnSlack + 5
            m.setVisible(true)
            XCTAssertNil(m.newSession, "it started: the waiting form goes")
            XCTAssertTrue(m.pendingSpawn == nil)
            XCTAssertTrue(st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "")] == nil, "no never-started line")
            XCTAssertEqual(m.selection, .live(other.key), "nothing picked")
            // Never listed while hidden: never started, as before.
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            let name = try XCTUnwrap(spawns.calls.last?.name)
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: name), nil)
            m.setVisible(false)
            st.sessions = [other]
            clock.t += AgentWindowModel.spawnSlack + 5
            m.setVisible(true)
            XCTAssertEqual(m.newSessionStatus, AgentWindowModel.notListedText(name))
        }
    }

    /// #1096 3: each caller's own button word through the chooser seam (never a real panel): the window's form fills
    /// its Folder field ("Choose"); the island's "Choose folder\u{2026}" starts a session at once ("Start").
    @MainActor
    func testFolderChooserButtonWordIsTheCallersOwn() throws {
        try withNewSessionPrefs {
            final class Words { var all: [String] = [] }
            let words = Words(), st = store([mapped("a")]), m = newSessionModel(st, SpawnCalls())
            defer { m.close() }
            m.island().chooseFolder = { ask in words.all.append(ask.prompt); ask("/Users/example/web") }
            m.openNewSession(folder: "/Users/example")
            m.chooseNewSessionFolder()
            XCTAssertEqual(words.all, [AgentIslandController.FolderAsk.choose])
            XCTAssertEqual(m.newSession?.folder, "~/web", "the form's field filled")
            let c = AgentIslandController()
            c.store = st
            c.chooseFolder = { ask in words.all.append(ask.prompt); ask(nil) }   // cancelled: nothing starts
            c.chooseNewSessionFolder()
            XCTAssertEqual(words.all, ["Choose", "Start"])
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

    // MARK: #1434 (QA R1096-s1, i1): a late row never lands over a form the person is editing

    /// The form's "web" start, answered and expired unlisted (other selected, the deadline on a timer no run loop fires).
    @MainActor
    func lateWebModel(_ st: AgentIslandStore, _ spawns: SpawnCalls, other: AgentSession) throws -> AgentWindowModel {
        final class Clock { var t = AgentWindowD1Tests.now }
        let clock = Clock(), m = newSessionModel(st, spawns)
        m.now = { clock.t }
        m.scheduleDeadline = { t, block in Timer(timeInterval: t, repeats: false, block: block) }
        m.select(.live(other.key))
        m.openNewSession(folder: "/Users/example/web")
        XCTAssertTrue(m.startNewSession())
        spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
        clock.t += AgentWindowModel.spawnSlack + 1
        try XCTUnwrap(m.spawnDeadline).fire()
        XCTAssertEqual(m.newSessionStatus, AgentWindowModel.notListedText("web"), "expired unlisted")
        XCTAssertTrue(m.lateSpawn?.name == "web")
        return m
    }

    /// Expiry, then the person edits the command, then the row lists: the form and its edit stay, the keys stay in it,
    /// nothing is selected, and the status says the session started after all.
    @MainActor
    func testAgentWindowNewSessionLateRowKeepsAnEditedForm() throws {
        try withNewSessionPrefs {
            let other = mapped("other"), st = store([other]), spawns = SpawnCalls()
            let m = try lateWebModel(st, spawns, other: other)
            defer { m.close() }
            m.setNewSessionCommand("claude --resume")
            let edited = m.newSession
            st.sessions = [other, mapped("web")]
            XCTAssertEqual(m.selection, live("other"), "nothing selected")
            XCTAssertNotNil(m.newSession, "the form stays")
            XCTAssertEqual(m.newSession?.command, "claude --resume", "its edit stays")
            XCTAssertEqual(m.newSession?.folder, edited?.folder)
            XCTAssertFalse(m.terminal.focusPending, "the keys stay in the form")
            XCTAssertFalse(m.interaction.composerFocusPending)
            XCTAssertEqual(m.newSessionStatus, "web started after all: it is in the list")
            XCTAssertEqual(m.newSessionStatus, AgentWindowModel.startedAfterAllText("web"))
            XCTAssertTrue(m.lateSpawn == nil, "said once")
            XCTAssertEqual(spawns.calls.count, 1)
        }
    }

    /// Expiry with the form untouched, then the row lists: it lands as before, selected, Terminal, the keys in it.
    @MainActor
    func testAgentWindowNewSessionLateRowLandsAnUneditedForm() throws {
        try withNewSessionPrefs {
            let other = mapped("other"), st = store([other]), spawns = SpawnCalls()
            let m = try lateWebModel(st, spawns, other: other)
            defer { m.close() }
            st.sessions = [other, mapped("web")]
            XCTAssertEqual(m.selection, live("web"), "the late row lands")
            XCTAssertNil(m.newSession, "the form closed by the landing")
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertTrue(m.terminal.focusPending, "the keys asked into its terminal")
            XCTAssertTrue(m.lateSpawn == nil)
        }
    }

    /// Expiry, Cancel, the form opened again: the late start is forgotten, and its row listing lands nothing.
    @MainActor
    func testAgentWindowNewSessionLateRowForgottenByAReopenedForm() throws {
        try withNewSessionPrefs {
            let other = mapped("other"), st = store([other]), spawns = SpawnCalls()
            let m = try lateWebModel(st, spawns, other: other)
            defer { m.close() }
            m.cancelNewSession()
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.lateSpawn == nil, "R1096-i1: the reopened form drops it")
            st.sessions = [other, mapped("web")]
            XCTAssertEqual(m.selection, live("other"), "nothing lands")
            XCTAssertNotNil(m.newSession, "the new form stays")
            XCTAssertTrue(m.newSessionStatus == nil)
            XCTAssertFalse(m.terminal.focusPending)
            XCTAssertTrue(m.lateSpawn == nil)
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
            let size = CGSize(width: AgentWindowModel.fullSidebarWidth, height: AgentWindowControls.stripHeight)
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
                XCTAssertEqual(route(formKey(17, "t", .command)), .pass, "#1471: Command-T is no window key \(tag)")
                XCTAssertEqual(route(formKey(3, "f", .command)), terminal ? .swallow : .pass, "⌘F \(tag)")
                XCTAssertEqual(route(formKey(5, "g", .command)), terminal ? .swallow : .pass, "⌘G \(tag)")
                XCTAssertEqual(route(formKey(5, "G", [.command, .shift])), terminal ? .swallow : .pass, "⇧⌘G \(tag)")
                // #1470: Option-Command-1, 3 and 9 are rows 10, 12 and 18: swallowed under the form, as Command-1.
                for (code, row) in [(UInt16(18), 10), (20, 12), (25, 18)] {
                    XCTAssertEqual(route(formKey(code, "", [.command, .option])), .swallow, "Option-Command key \(code) \(tag)")
                    XCTAssertEqual(route(formKey(code, "", [.command, .option]), form: false), .jump(row), "no form: row \(row) \(tag)")
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
            XCTAssertFalse(win.performKeyEquivalent(with: wiringKey(win, 17, "t", .command)), "#1471: Command-T is not the window's")
            XCTAssertEqual(m.paneMode, .terminal)
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

    // MARK: INFO-5: the keys back where they were, sidebar and pending

    /// QA #747 M7: opened from the sidebar, Cancel leaves the keys there. A focus still pending when the form opened
    /// counts as the keys (the terminal's, which the detach drops): Cancel asks again. #1471: the Transcript input
    /// box's halves (Cancel back into the box; the box's own pending focus) are gone with the box.
    @MainActor
    func testAgentWindowNewSessionKeysComeBackToTheInputBoxOrAPendingFocus() throws {
        try withNewSessionPrefs {
            let a = mapped("a"), st = store([a]), m = wiringModel(st, SpawnCalls())
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(.live(a.key))
            settle(host)
            // Opened from the sidebar: Cancel leaves the keys there.
            sidebarKeys(win)
            let side = win.firstResponder
            m.openNewSession()
            settle(host)
            XCTAssertEqual(formFields(host).count, 3)
            m.cancelNewSession()
            settle(host)
            XCTAssertTrue(side != nil && win.firstResponder === side && win.sidebarFocused, "the sidebar keeps them")
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

        }
    }

    // MARK: INFO-6, INFO-7

    /// QA #747 INFO-6, QA #826: VoiceOver reads the form's fields by name, not by placeholder (their label), and the
    /// recents menu by its title. Read off the real accessibility tree: SwiftUI builds it in a never-shown window once
    /// this process (only) is asked to, as an AX client's attribute write would; both attributes are put back after.
    /// Named to run first in AgentWindowD1Tests.
    @MainActor
    func testAccessibilityTreeReadsTheNewSessionFormByName() {
        // NSApp is nil until something creates the application; this test may run first in the process.
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        withNewSessionPrefs {
            let m = wiringModel(store([mapped("a", ago: 1)]), SpawnCalls())
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.openNewSession()
            XCTAssertFalse(m.newSessionRecents.isEmpty, "the menu is enabled")
            // The tree fills in on the run loop: poll for the form's three fields and its recents menu (the sidebar's own menu button is no signal), with a deadline.
            let tree = AXTreeSupport.poll(host) { t in
                t.filter { $0.role == "AXTextField" }.count >= 3 && t.contains { $0.role == "AXMenuButton" && $0.title == "Recent folders" }
            }
            print("#887 a11y tree:\n" + tree.map { "  \($0.role) label=\($0.label) title=\($0.title)" }.joined(separator: "\n"))
            XCTAssertEqual(tree.filter { $0.role == "AXTextField" }.map(\.label), ["Folder", "Name", "Command"])
            XCTAssertEqual(tree.filter { $0.role == "AXMenuButton" }.map(\.title), ["Session list actions", "Recent folders"])
            // #1429: the chevron's own symbol text ("go down") is not read after the title.
            let recents = tree.filter { $0.role == "AXMenuButton" && $0.title == "Recent folders" }
            XCTAssertEqual(recents.count, 1)
            XCTAssertTrue(recents.allSatisfy { ["", "Recent folders"].contains($0.label) }, "\(recents.map(\.label))")
            XCTAssertFalse(tree.contains { $0.reads("go down") }, "no node reads the symbol's own text")
        }
    }

    /// QA #747 INFO-7 (b): the empty sidebar names + and ⌘N only while they work.
    @MainActor
    func testAgentWindowNoSessionsHintFollowsTheGate() {
        XCTAssertEqual(AgentNoSessionsState.detail(canStart: true),
                       "Sessions started with dch show up here. Press + or ⌘N to start one.")
        XCTAssertEqual(AgentNoSessionsState.detail(canStart: false), "Sessions started with dch show up here.")
    }

    /// #1096 4: the empty sidebar's body reads the store's gate as it is now.
    @MainActor
    func testAgentWindowNoSessionsStateBodyFollowsTheStoresGate() {
        let st = store([])
        st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
        XCTAssertEqual(AgentNoSessionsState(store: st).detail, AgentNoSessionsState.detail(canStart: true))
        st.controlDch = nil
        XCTAssertEqual(AgentNoSessionsState(store: st).detail, AgentNoSessionsState.detail(canStart: false))
    }
}
