import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #845: a sidebar row's click, Return and Right move the keyboard into the session (its terminal in
/// Terminal mode once the client is live, its input box in Transcript); arrows keep the sidebar; the rename
/// field and the model's own selection changes are never disturbed. The window is never shown or made key:
/// the whole root view is hosted in an AgentsNSWindow, clicks and keys are built events handed to its
/// sendEvent, and the checks read its firstResponder. No dch runs: the terminal's spawn is a recorder.
extension AgentWindowD1Tests {

    /// The window's root view in its own NSWindow subclass, never shown.
    @MainActor
    func focusWindow(_ m: AgentWindowModel) -> (AgentsNSWindow, NSHostingView<AgentWindowRootView>) {
        let size = CGSize(width: 1000, height: 680)
        // Not deferred: a window number for the built events (it is still never ordered in).
        let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                                 backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.model = m
        let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        settle(host)
        return (win, host)
    }

    @MainActor
    func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    func focusViews<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] {
        ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { focusViews($0, t) }
    }

    /// A click (down, then up) delivered to the window, never posted.
    @MainActor
    func focusClick(_ p: NSPoint, _ win: NSWindow, _ host: NSView) {
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
            win.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: pressure)!)
        }
        settle(host)
    }

    @MainActor
    func focusKey(_ code: UInt16, _ win: NSWindow, _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// A click on `name`'s row: the mouse-down as the window sees it (sidebarFocused, the #822/#845 resign), then
    /// the row Button's action, `model.click` (a built mouse event never reaches a SwiftUI button, nor does its
    /// accessibility tree exist, in a window that was never shown).
    @MainActor
    func clickRow(_ name: String, _ m: AgentWindowModel, _ win: AgentsNSWindow, _ host: NSView) {
        win.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: sz(120), y: host.bounds.height - sz(200)),
                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        m.click(live(name))
        settle(host)
    }

    /// The sidebar has the keys again (as after a click on its empty part): nothing that types is first responder.
    @MainActor
    func sidebarKeys(_ win: AgentsNSWindow) {
        XCTAssertTrue(win.makeFirstResponder(nil))
        win.sidebarFocused = true
    }

    /// A terminal whose client goes live only when the test delivers the screen's grid report.
    @MainActor
    func slowTerminal(_ m: AgentWindowModel) {
        m.terminal.makeScreen = { AgentTerminalTests.FakeScreen($0) }
    }

    @MainActor
    func reportGrid(_ m: AgentWindowModel) {
        m.terminal.gridChanged(cols: 80, rows: 24, generation: m.terminal.generation)
    }

    // MARK: A click

    @MainActor
    func testAgentWindowRowClickMovesTheKeysIntoTheTerminal() throws {
        try withModePref {
            let m = windowModel(store([mapped("a", .done, ago: 1), mapped("b", .done, ago: 2)]))
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(live("a"))
            settle(host)
            sidebarKeys(win)
            let term = try XCTUnwrap(m.terminal.view)
            XCTAssertFalse(win.firstResponder === term)
            clickRow("b", m, win, host)
            XCTAssertEqual(m.selection, live("b"))
            XCTAssertEqual(m.terminal.key?.name, "b")
            XCTAssertTrue(win.firstResponder === term, "the click moved the keys into b's terminal")
            XCTAssertFalse(win.sidebarFocused, "#822 P1: never a focused sidebar with the terminal first responder")
            win.sendEvent(focusKey(126, win, "\u{F700}"))
            XCTAssertEqual(m.selection, live("b"), "up went to the terminal, not the sidebar")
            // A click on the sidebar's empty part takes the keys back (#822), and the arrows select again.
            focusClick(NSPoint(x: sz(120), y: 120), win, host)
            XCTAssertTrue(win.sidebarFocused)
            XCTAssertFalse(win.firstResponder === term)
            win.sendEvent(focusKey(126, win, "\u{F700}"))
            XCTAssertEqual(m.selection, live("a"))
            XCTAssertFalse(win.firstResponder === term, "an arrow keeps the sidebar")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    @MainActor
    func testAgentWindowRowClickMovesTheKeysIntoTheInputBox() throws {
        try withModePref {
            let b = mapped("b", .done, ago: 2)
            let m = windowModel(store([mapped("a", .done, ago: 1), b]))
            _ = fakeTerminal(m)
            m.setMode(.transcript, for: b)   // a stays Terminal: b's input box is built by the click
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(live("a"))
            settle(host)
            sidebarKeys(win)
            XCTAssertTrue(focusViews(host, AgentComposerTextView.self).isEmpty, "Terminal mode: no input box")
            clickRow("b", m, win, host)
            XCTAssertEqual(m.selection, live("b"))
            let tv = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first)
            XCTAssertTrue(win.firstResponder === tv, "the input box built for b took the keys")
            XCTAssertFalse(m.interaction.composerFocusPending)
            XCTAssertFalse(win.sidebarFocused)
            win.sendEvent(focusKey(7, win, "x"))
            XCTAssertEqual(m.interaction.draft, "x", "typing lands in b's input box with no click on it")
            // Clicking b again (the box already there): the keys stay in it.
            clickRow("b", m, win, host)
            XCTAssertTrue(win.firstResponder === tv)
            // A click on the sidebar's empty part takes the keys back from the box; the arrows select again.
            focusClick(NSPoint(x: sz(120), y: 120), win, host)
            XCTAssertTrue(win.sidebarFocused)
            XCTAssertFalse(win.firstResponder === tv)
            win.sendEvent(focusKey(126, win, "\u{F700}"))
            XCTAssertEqual(m.selection, live("a"))
            XCTAssertEqual(m.interaction.draft, "", "a's draft: the x stayed b's")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: The header's Transcript | Terminal toggle

    @MainActor
    func testAgentWindowHeaderToggleMovesTheKeysIntoTheShownModesInput() throws {
        try withModePref {
            let a = mapped("a", .done, ago: 1)
            let m = windowModel(store([a, mapped("b", .done, ago: 2)]))
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            XCTAssertEqual(m.selection, live("a"))
            sidebarKeys(win)
            // Terminal -> Transcript: the box built for the pane takes the keys.
            m.switchMode(.transcript, for: a)
            settle(host)
            XCTAssertEqual(m.paneMode, .transcript)
            let tv = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first)
            XCTAssertTrue(win.firstResponder === tv, "Transcript: the keys are in the input box")
            XCTAssertFalse(win.sidebarFocused)
            // Transcript -> Terminal while the client attaches: the keys wait, then land once it is live.
            sidebarKeys(win)
            slowTerminal(m)
            m.switchMode(.terminal, for: a)
            settle(host)
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertEqual(m.terminal.phase, .attaching)
            let term = try XCTUnwrap(m.terminal.view)
            XCTAssertTrue(term.window === win)
            XCTAssertFalse(win.firstResponder === term, "attaching: no keys into a terminal that drops them")
            XCTAssertTrue(m.terminal.focusPending)
            reportGrid(m)
            XCTAssertEqual(m.terminal.phase, .live)
            XCTAssertTrue(win.firstResponder === term, "live: the toggle's focus landed")
            XCTAssertFalse(win.sidebarFocused)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: Keys

    @MainActor
    func testAgentWindowArrowsKeepTheSidebarAndReturnOrRightMoveIn() throws {
        try withModePref {
            let b = mapped("b", .done, ago: 2)
            let m = windowModel(store([mapped("a", .done, ago: 1), b], history: [record("h")]))
            _ = fakeTerminal(m)
            m.setMode(.transcript, for: b)
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(live("a"))
            settle(host)
            sidebarKeys(win)
            // Down: b (Transcript); its box is built, the keys stay in the sidebar.
            win.sendEvent(focusKey(125, win, "\u{F701}"))
            settle(host)
            XCTAssertEqual(m.selection, live("b"))
            let tv = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first)
            XCTAssertFalse(win.firstResponder === tv, "an arrow keeps the sidebar")
            XCTAssertTrue(win.sidebarFocused)
            // Right on a row whose section shows: into the input box.
            win.sendEvent(focusKey(124, win, "\u{F703}"))
            XCTAssertTrue(win.firstResponder === tv, "Right moved in")
            XCTAssertFalse(win.sidebarFocused)
            // Up: a (Terminal), the keys stay in the sidebar; Return: into the terminal.
            sidebarKeys(win)
            win.sendEvent(focusKey(126, win, "\u{F700}"))
            settle(host)
            XCTAssertEqual(m.selection, live("a"))
            let term = try XCTUnwrap(m.terminal.view, "a's terminal, built again for Terminal mode")
            XCTAssertTrue(term.window === win)
            XCTAssertFalse(win.firstResponder === term, "an arrow keeps the sidebar")
            XCTAssertFalse(m.terminal.focusPending)
            win.sendEvent(focusKey(36, win, "\r"))
            XCTAssertTrue(win.firstResponder === term, "Return moved in")
            XCTAssertFalse(win.sidebarFocused)
            // A History row: nothing takes input, Return passes on and the keys stay.
            sidebarKeys(win)
            win.sendEvent(focusKey(125, win, "\u{F701}"))
            win.sendEvent(focusKey(125, win, "\u{F701}"))
            XCTAssertEqual(m.selection, .history(AgentSessionKey(dir: "/tmp/dch-test", name: "h")))
            XCTAssertFalse(AgentsNSWindow.handle(focusKey(36, win, "\r"), m))
            XCTAssertTrue(AgentsNSWindow.handle(focusKey(124, win, "\u{F703}"), m), "Right on History: taken, nothing moves")
            XCTAssertTrue(win.firstResponder === win)
            XCTAssertFalse(m.terminal.focusPending || m.interaction.composerFocusPending)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: The rename field

    @MainActor
    func testAgentWindowRowClickNeverTakesTheKeysFromTheRenameField() throws {
        try withModePref {
            let a = mapped("a", .done, ago: 1)
            let m = windowModel(store([a, mapped("b", .done, ago: 2)]))
            m.renameSession = { _, _ in true }
            showTranscript(m)
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(live("b"))
            settle(host)
            m.ask(.rename, a)
            settle(host)
            let field = try XCTUnwrap(focusViews(host, AgentRenameTextField.self).first)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            XCTAssertTrue(win.firstResponder === editor)
            XCTAssertFalse(m.focusSelection(), "renaming: the focus stays")
            XCTAssertTrue(win.firstResponder === editor)
            clickRow("a", m, win, host)   // the same row
            XCTAssertEqual(m.renaming, a.key, "the field still edits")
            XCTAssertTrue(win.firstResponder === editor, "the click did not move the keys into the input box")
            win.sendEvent(focusKey(36, win, "\r"))
            XCTAssertNil(m.renaming, "Return was the field's")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: Selections the model makes itself

    @MainActor
    func testAgentWindowModelSelectionChangesNeverMoveTheKeys() throws {
        try withModePref {
            let st = store([mapped("a", .done, ago: 1), mapped("b", .done, ago: 2), mapped("c", .done, ago: 3)])
            let m = windowModel(st)
            _ = fakeTerminal(m)
            m.setVisible(true)   // the first fill picks a: no focus
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            let term = try XCTUnwrap(m.terminal.view)
            XCTAssertEqual(m.selection, live("a"))
            XCTAssertFalse(win.firstResponder === term, "the first fill moves no keys")
            sidebarKeys(win)
            m.refresh()
            XCTAssertFalse(win.firstResponder === term, "a rebuild moves no keys")
            // A focus asked for while b attaches is dropped when b ends: c going live later never gets it.
            slowTerminal(m)
            m.select(live("b"))
            XCTAssertEqual(m.terminal.phase, .attaching)
            XCTAssertTrue(m.focusSelection())
            XCTAssertTrue(m.terminal.focusPending)
            st.sessions = [mapped("a", .done, ago: 1), mapped("c", .done, ago: 3)]
            XCTAssertNil(m.selection, "b ended: nothing selected")
            XCTAssertFalse(m.terminal.focusPending)
            win.sendEvent(focusKey(125, win, "\u{F701}"))
            win.sendEvent(focusKey(125, win, "\u{F701}"))
            XCTAssertEqual(m.selection, live("c"))
            reportGrid(m)
            XCTAssertEqual(m.terminal.phase, .live)
            XCTAssertFalse(win.firstResponder === term, "c went live: the keys stayed in the sidebar")
            XCTAssertTrue(win.sidebarFocused)
            // Transcript: a focus asked for before the box exists is dropped when the session ends.
            let t = windowModel(store([mapped("d", .done, ago: 1), mapped("e", .done, ago: 2)]))
            showTranscript(t)
            t.setVisible(true)
            defer { t.close() }
            XCTAssertTrue(t.focusSelection())
            XCTAssertTrue(t.interaction.composerFocusPending)
            t.store?.sessions = [mapped("e", .done, ago: 2)]
            XCTAssertNil(t.selection)
            XCTAssertFalse(t.interaction.composerFocusPending, "d ended: dropped")
            t.select(live("e"))
            let tv = AgentComposerTextView(frame: .init(x: 0, y: 0, width: 100, height: 40))
            tv.owner = t.interaction
            t.interaction.composer = tv
            let w2 = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                    backing: .buffered, defer: true)
            w2.isReleasedWhenClosed = false
            w2.contentView?.addSubview(tv)
            XCTAssertFalse(w2.firstResponder === tv, "e's box joined the window: nothing pending lands")
            XCTAssertFalse(w2.isVisible || win.isVisible, "never shown")
        }
    }

    // MARK: A terminal that is not live yet

    @MainActor
    func testAgentWindowClickWhileAttachingLandsTheKeysOnceLiveAndNeverOnADeadTerminal() throws {
        try withModePref {
            let m = windowModel(store([mapped("a", .done, ago: 1), mapped("b", .done, ago: 2), mapped("c", .done, ago: 3)]))
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(live("a"))
            settle(host)
            sidebarKeys(win)
            let term = try XCTUnwrap(m.terminal.view)
            slowTerminal(m)
            clickRow("b", m, win, host)
            XCTAssertEqual(m.selection, live("b"))
            XCTAssertEqual(m.terminal.phase, .attaching)
            XCTAssertFalse(win.firstResponder === term, "attaching: no keys into a terminal that drops them")
            XCTAssertTrue(win.sidebarFocused)
            XCTAssertTrue(m.terminal.focusPending)
            reportGrid(m)
            XCTAssertEqual(m.terminal.phase, .live)
            XCTAssertTrue(win.firstResponder === term, "live: the click's focus landed")
            XCTAssertFalse(win.sidebarFocused)
            XCTAssertFalse(m.terminal.focusPending)
            // A client that cannot start: Return leaves the keys in the sidebar (no dead terminal).
            sidebarKeys(win)
            m.terminal.spawn = { _, _ in throw AgentTerminalController.SpawnError.underTests }
            win.sendEvent(focusKey(125, win, "\u{F701}"))
            reportGrid(m)
            XCTAssertEqual(m.selection, live("c"))
            guard case .failed = m.terminal.phase else { return XCTFail("\(m.terminal.phase)") }
            win.sendEvent(focusKey(36, win, "\r"))
            XCTAssertFalse(win.firstResponder === term, "failed: the keys stay in the sidebar")
            XCTAssertTrue(win.sidebarFocused)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }
}
