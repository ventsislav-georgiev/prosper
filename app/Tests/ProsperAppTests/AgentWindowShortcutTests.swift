import AppKit
import XCTest
@testable import ProsperApp

/// #1289 (#829 Phase 4b): the sidebar row's PR chips open through the model's openURL seam (G5), and Cmd-Backspace on the
/// selected row asks Stop (live) or Remove from History in the strip, never acting (G2/G8). Offscreen only: the window
/// is never shown, ordered or made key; keys are built with NSEvent.keyEvent and handed to the route function or to
/// performKeyEquivalent, never posted. No URL opens (openURL is a recorder), no real dch (the runner records), no menu.
extension AgentWindowSidebarMenuTests {

    @MainActor
    func shortcutWindow(_ m: AgentWindowModel?) -> AgentsNSWindow {
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                 backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        win.model = m
        return win
    }

    @MainActor
    func cmdBackspace(_ win: NSWindow, _ flags: NSEvent.ModifierFlags = [.command]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber,
                         context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false,
                         keyCode: 51)!
    }

    // MARK: G5

    @MainActor
    func testShortcutPRChipOpensItsLiteralURLThroughTheModelSeam() {
        let pr = { (n: Int) in DchSessionMeta.PR(url: "https://github.com/acme/api/pull/\(n)", repo: "acme/api", num: n, title: "t\(n)") }
        let labelOnly = DchSessionMeta.PR(url: "https://example.com/acme/api/pull/9", repo: "acme/api", num: 9, title: "x")
        var s = session("api")
        s.meta = DchSessionMeta(openPRs: [pr(12), labelOnly, pr(14)], merged: 0)
        let row = AgentSidebar.row(s, details: .all, now: Self.now)
        XCTAssertEqual(row.prs, ["api#12", "api#9", "+1"])
        XCTAssertEqual(row.prLinks.map(\.label), ["api#12", "api#9"], "the shown chips' values; +1 has none")
        XCTAssertEqual(row.prLinks.map { $0.url?.absoluteString }, ["https://github.com/acme/api/pull/12", nil])

        let st = store([s], dch: bin([1, 30, 0])), rec = Launches(), m = model(st, controller(st, rec))
        defer { m.close() }
        var opened: [String] = []
        m.openURL = { opened.append($0.absoluteString) }
        guard let first = row.prLinks.first, let last = row.prLinks.last else { return XCTFail("two chips") }
        m.openPR(first)
        XCTAssertEqual(opened, ["https://github.com/acme/api/pull/12"], "the chip's own URL, once")
        m.openPR(last)
        XCTAssertEqual(opened, ["https://github.com/acme/api/pull/12"], "a label chip (no allowlisted URL) opens nothing")
        XCTAssertEqual(AgentWindowControls.openPRLabel(first), "Open pull request acme/api#12")
        XCTAssertTrue(rec.args.isEmpty, "no dch")
    }

    // MARK: Cmd-Backspace

    /// The route: the window's only with the sidebar focused and no text field, composer or terminal holding the keys;
    /// a rename field keeps it; under the New session form it is swallowed; other modifiers and plain Backspace pass.
    @MainActor
    func testShortcutCmdBackspaceRoutesOnlyFromTheFocusedSidebar() {
        let win = shortcutWindow(nil)
        defer { win.close() }
        let e = cmdBackspace(win)
        XCTAssertEqual(AgentsNSWindow.route(e, responder: .other, sidebarFocused: true, terminalMode: false), .stopOrRemove)
        XCTAssertEqual(AgentsNSWindow.route(e, responder: .other, sidebarFocused: true, terminalMode: true), .stopOrRemove)
        for r: AgentsNSWindow.ResponderKind in [.text, .terminal] {
            XCTAssertEqual(AgentsNSWindow.route(e, responder: r, sidebarFocused: true, terminalMode: false), .pass, "\(r)")
        }
        XCTAssertEqual(AgentsNSWindow.route(e, responder: .other, sidebarFocused: false, terminalMode: false), .pass, "pane focused")
        XCTAssertEqual(AgentsNSWindow.route(e, responder: .other, sidebarFocused: true, terminalMode: false, renaming: true), .pass)
        XCTAssertEqual(AgentsNSWindow.route(e, responder: .other, sidebarFocused: true, terminalMode: false, form: true), .swallow)
        for flags: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertEqual(AgentsNSWindow.route(cmdBackspace(win, flags), responder: .other, sidebarFocused: true,
                                                terminalMode: false), .pass, "\(flags)")
        }
    }

    /// A live row: the key asks Stop in the strip (its literal text); nothing stops, before or after Cancel.
    @MainActor
    func testShortcutCmdBackspaceAsksStopOnALiveRowAndNeverStops() {
        let st = store([session("api")], dch: bin([1, 30, 0])), rec = Launches(), m = model(st, controller(st, rec))
        defer { m.close() }
        var stops = 0
        m.stopSession = { _ in stops += 1; return true }
        let win = shortcutWindow(m)
        defer { win.close() }
        m.setVisible(true)   // the rows are built while the window shows
        settle { !m.sections.isEmpty }   // the rows come with the store's publish
        m.select(.live(AgentSessionKey(dir: Self.dir, name: "api")))
        XCTAssertTrue(m.selectedRow?.session != nil, "premise: the live row is selected")
        m.keyFocus = .sidebar
        XCTAssertEqual(win.responderKind, .other, "premise: nothing that types has the keys")
        XCTAssertTrue(win.performKeyEquivalent(with: cmdBackspace(win)))
        XCTAssertEqual(m.confirming?.verb, .stop)
        XCTAssertEqual(m.confirmingSession.map { AgentWindowControls.question(.stop, $0) },
                       "Stop api? Claude Code is paused and the session ends. Resume it later from History.")
        XCTAssertEqual(stops, 0, "asked, not stopped")
        m.confirm(false)
        XCTAssertEqual(stops, 0, "Cancel runs nothing")
        XCTAssertTrue(rec.args.isEmpty, "no dch")
    }

    /// A History row: the key asks Remove in the strip (its literal text); nothing is removed.
    @MainActor
    func testShortcutCmdBackspaceAsksRemoveOnAHistoryRowAndNeverRemoves() {
        let r = crashed("old")
        let st = store([], history: [r], dch: bin([1, 30, 0])), rec = Launches(), m = model(st, controller(st, rec))
        defer { m.close() }
        var removes = 0
        m.removeRecord = { _ in removes += 1 }
        let win = shortcutWindow(m)
        defer { win.close() }
        m.setVisible(true)   // the rows are built while the window shows
        settle { !m.sections.isEmpty }
        m.select(.history(r.id))
        XCTAssertTrue(m.selectedRow?.record != nil, "premise: the History row is selected")
        m.keyFocus = .sidebar
        XCTAssertTrue(win.performKeyEquivalent(with: cmdBackspace(win)))
        XCTAssertEqual(m.confirming?.verb, .remove)
        XCTAssertEqual(m.confirmingRecord.map { AgentWindowControls.removeQuestion($0, in: st.history) },
                       "Remove old from History? Resume won't be able to bring it back. Its Claude Code conversation stays on disk.")
        XCTAssertEqual(removes, 0, "asked, not removed")
        XCTAssertTrue(rec.args.isEmpty, "no dch")
    }

    /// A text field with the keys: the key is the field's; nothing is asked or run.
    @MainActor
    func testShortcutCmdBackspaceIsIgnoredWhileATextFieldHasTheKeys() {
        let st = store([session("api")], dch: bin([1, 30, 0])), rec = Launches(), m = model(st, controller(st, rec))
        defer { m.close() }
        var stops = 0
        m.stopSession = { _ in stops += 1; return true }
        let win = shortcutWindow(m)
        defer { win.close() }
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 22))
        win.contentView?.addSubview(field)
        m.setVisible(true)   // the rows are built while the window shows
        settle { !m.sections.isEmpty }   // the rows come with the store's publish
        m.select(.live(AgentSessionKey(dir: Self.dir, name: "api")))
        XCTAssertTrue(m.selectedRow?.session != nil, "premise: the live row is selected")
        XCTAssertTrue(win.makeFirstResponder(field))
        m.keyFocus = .sidebar   // the sidebar's flag set too: only the text responder keeps the key
        XCTAssertEqual(win.responderKind, .text, "premise: the field editor has the keys")
        _ = win.performKeyEquivalent(with: cmdBackspace(win))
        XCTAssertTrue(m.confirming == nil, "nothing asked")
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(rec.args.isEmpty, "no dch")
    }
}

extension AgentWindowD1Tests {

    /// #1289: Cmd-N reaches New session (the window's form since #847) and its Choose folder goes through the island's
    /// chooseFolder seam once (no NSOpenPanel); the picked folder fills the form. The #847 harness: prefs saved and
    /// restored, a typed command (no inference), the spawn a recorder.
    @MainActor
    func testShortcutCmdNOpensNewSessionAndItsFolderChoiceUsesTheSeamOnce() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
            defer { m.close() }
            var asked = 0
            m.island().chooseFolder = { done in asked += 1; done("/Users/example/web") }
            let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                     backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.model = m
            defer { win.close() }
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)))
            XCTAssertTrue(m.newSession != nil, "the New session form is open")
            XCTAssertEqual(asked, 0, "no chooser before Choose")
            m.chooseNewSessionFolder()
            XCTAssertEqual(asked, 1, "the folder seam, once")
            XCTAssertEqual(m.newSession?.folder, "~/web")
        }
    }
}
