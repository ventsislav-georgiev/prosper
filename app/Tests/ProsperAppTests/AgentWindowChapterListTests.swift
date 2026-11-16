import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1319 (#832 X1 step B, spec v2.1 8.3 and the 13.4 Command-L key rows): Command-L in the Agent Sessions window. Keys
/// are built events handed to the pure `route` or to a never-shown window's performKeyEquivalent (nothing is posted;
/// no window is ordered front or made key); the list's surface is FakeCardPresenter (never shown). No dch runs: the
/// terminal's spawn is a recorder and the transcripts are never read.
extension AgentWindowD1Tests {

    @MainActor
    func chapterKey(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags, window: Int = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// "a" (Terminal mode) and "b" (Transcript), b selected with its input box holding the keys; the fake presenter in.
    @MainActor
    func withChapterWindow(_ body: (AgentWindowModel, AgentsNSWindow, NSView, FakeCardPresenter) throws -> Void) throws {
        try withModePref {
            let b = mapped("b", .done, ago: 2)
            let m = windowModel(store([mapped("a", .done, ago: 1), b]))
            _ = fakeTerminal(m)
            m.setMode(.transcript, for: b)
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            let fake = FakeCardPresenter()
            win.cards = fake
            m.select(live("a"))
            settle(host)
            sidebarKeys(win)
            clickRow("b", m, win, host)
            try body(m, win, host, fake)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: 13.4: the route, by key code

    @MainActor
    func testChapterListRouteIsByKeyCodeWithExactlyCommand() {
        typealias R = AgentsNSWindow.KeyRoute
        func route(_ e: NSEvent, _ r: AgentsNSWindow.ResponderKind = .text, sidebar: Bool = false, terminal: Bool = false,
                   renaming: Bool = false, form: Bool = false) -> R {
            AgentsNSWindow.route(e, responder: r, sidebarFocused: sidebar, terminalMode: terminal, renaming: renaming, form: form)
        }
        let cyrillic = chapterKey(37, "\u{0434}", .command)
        XCTAssertEqual(route(cyrillic), .chapters, "keyCode 37 with Command typing a Cyrillic letter opens the list")
        XCTAssertEqual(route(chapterKey(37, "l", .command)), .chapters, "the composer")
        XCTAssertEqual(route(chapterKey(37, "l", .command), .other, sidebar: true), .chapters, "the sidebar")
        XCTAssertEqual(route(chapterKey(37, "l", [.command, .capsLock])), .chapters, "Caps Lock is not a modifier here")
        XCTAssertEqual(route(chapterKey(37, "l", .command), .terminal, terminal: true), .swallow, "a terminal pane: consumed, no action")
        XCTAssertEqual(route(cyrillic, .other, terminal: true), .swallow)
        XCTAssertEqual(route(chapterKey(37, "L", [.command, .shift])), .pass, "Shift-Command-L passes through")
        XCTAssertEqual(route(chapterKey(37, "\u{00AC}", [.command, .option])), .pass, "Option-Command-L passes through")
        XCTAssertEqual(route(chapterKey(37, "\u{000C}", [.command, .control])), .pass, "Control-Command-L passes through")
        XCTAssertEqual(route(chapterKey(37, "l", [])), .pass, "plain L types")
        XCTAssertEqual(route(chapterKey(35, "l", .command)), .pass, "an L typed on another key (Dvorak): the key code decides")
        XCTAssertEqual(route(chapterKey(37, "l", .command), form: true), .swallow, "under the New session form: swallowed")
        XCTAssertEqual(route(chapterKey(37, "l", .command), renaming: true), .pass, "the rename field keeps it")
    }

    // MARK: 13.4: from the composer, then Esc

    @MainActor
    func testChapterListFromTheComposerEscLeavesTheDraftAndSelection() throws {
        try withChapterWindow { m, win, host, fake in
            let tv = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first)
            XCTAssertTrue(win.firstResponder === tv, "b's input box has the keys")
            win.sendEvent(focusKey(7, win, "x"))
            tv.setSelectedRange(NSRange(location: 0, length: 1))
            let draft = m.interaction.draft, text = tv.string, range = tv.selectedRange()
            let focus = m.keyFocus, selection = m.selection, layout = m.layout
            XCTAssertEqual(draft, "x")
            XCTAssertTrue(win.performKeyEquivalent(with: chapterKey(37, "\u{0434}", .command, window: win.windowNumber)))
            XCTAssertEqual(fake.presents, 1, "the list opened")
            let list = try XCTUnwrap(win.chapterList)
            let rt = try XCTUnwrap(m.focusedRuntime)
            XCTAssertTrue(list.jumper === TranscriptJumper.of(rt.transcript), "the focused pane's jumper")
            XCTAssertEqual(fake.size, TranscriptChapterList.size)
            let anchor = try XCTUnwrap(fake.anchor)
            XCTAssertTrue(anchor === XrayCardAnchor.view(for: m.layout.focused, in: win), "hung from the header's anchor")
            XCTAssertFalse(anchor === win.contentView, "not the window's content")
            let editor = try XCTUnwrap(fake.editor, "the field is first responder while open")
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertEqual(fake.closes, 1, "Esc closed it")
            XCTAssertTrue(win.chapterList == nil)
            XCTAssertTrue(win.firstResponder === tv, "the keys are back in the input box")
            XCTAssertEqual(tv.string, text, "the draft is unchanged")
            XCTAssertEqual(tv.selectedRange(), range, "and its selection")
            XCTAssertEqual(m.interaction.draft, draft)
            XCTAssertEqual(m.keyFocus, focus)
            XCTAssertEqual(m.selection, selection)
            XCTAssertEqual(m.layout, layout)
            // Command-L twice: the second closes.
            XCTAssertTrue(win.performKeyEquivalent(with: chapterKey(37, "l", .command, window: win.windowNumber)))
            XCTAssertTrue(win.performKeyEquivalent(with: chapterKey(37, "l", .command, window: win.windowNumber)))
            XCTAssertEqual(fake.presents, 2)
            XCTAssertEqual(fake.closes, 2, "Command-L again closes")
            XCTAssertTrue(win.firstResponder === tv)
        }
    }

    // MARK: 13.4: from the sidebar, then Esc

    @MainActor
    func testChapterListFromTheSidebarEscReturnsToTheSidebar() throws {
        try withChapterWindow { m, win, host, fake in
            sidebarKeys(win)
            XCTAssertEqual(m.keyFocus, .sidebar)
            let responder = win.firstResponder, selection = m.selection
            XCTAssertTrue(win.performKeyEquivalent(with: chapterKey(37, "l", .command, window: win.windowNumber)))
            XCTAssertEqual(fake.presents, 1)
            let editor = try XCTUnwrap(fake.editor)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertEqual(fake.closes, 1)
            XCTAssertEqual(m.keyFocus, .sidebar, "the sidebar has the keys again")
            XCTAssertTrue(win.sidebarFocused)
            XCTAssertTrue(win.firstResponder === responder, "nothing that types took the keys")
            XCTAssertEqual(m.selection, selection)
            win.sendEvent(focusKey(126, win, "\u{F700}"))
            XCTAssertEqual(m.selection, live("a"), "an arrow selects in the sidebar again")
        }
    }

    // MARK: 10.1: a terminal pane, the pass-through chords and the "..." item

    @MainActor
    func testChapterListTerminalPaneConsumesTheKeyAndTheItemIsOff() throws {
        try withChapterWindow { m, win, host, fake in
            let chords: [(UInt16, String, NSEvent.ModifierFlags)] = [(37, "L", [.command, .shift]), (37, "\u{00AC}", [.command, .option]),
                                                                      (37, "\u{000C}", [.command, .control])]
            for (code, chars, flags) in chords {
                _ = win.performKeyEquivalent(with: chapterKey(code, chars, flags, window: win.windowNumber))
            }
            XCTAssertEqual(fake.presents, 0, "Shift, Option or Control added: not the list")
            XCTAssertEqual(AgentsNSWindow.chaptersItem(m), .chapters(enabled: true, pane: m.layout.focused), "Transcript: on")
            AgentsNSWindow.chaptersChosen(pane: m.layout.focused)
            XCTAssertEqual(fake.presents, 1, "the item opens it")
            fake.close()
            clickRow("a", m, win, host)
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertEqual(AgentsNSWindow.chaptersItem(m), .chapters(enabled: false, pane: m.layout.focused), "a terminal pane: off")
            XCTAssertTrue(win.performKeyEquivalent(with: chapterKey(37, "l", .command, window: win.windowNumber)), "consumed")
            AgentsNSWindow.chaptersChosen(pane: m.layout.focused)
            XCTAssertEqual(fake.presents, 1, "a terminal pane: no list")
            XCTAssertTrue(win.chapterList == nil)
        }
    }

    // MARK: 13.4 / #904 r1: the focused pane only; a jump keeps focus and selection

    @MainActor
    func testChapterListReachesTheFocusedPaneOnlyAndItsJumpKeepsFocusAndSelection() throws {
        splitsOn()
        try withModePref {
            let a = mapped("a", .done, ago: 1), b = mapped("b", .done, ago: 2)
            let m = windowModel(store([a, b]))
            _ = fakeTerminal(m)
            m.setMode(.transcript, for: a)
            m.setMode(.transcript, for: b)
            m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            let fake = FakeCardPresenter()
            win.cards = fake
            settle(host)
            let focused = try XCTUnwrap(m.focusedRuntime)
            let other = try XCTUnwrap(m.runtimes.values.first { $0.pane != focused.pane })
            m.keyFocus = .pane
            let selection = m.selection, layout = m.layout, responder = win.firstResponder
            XCTAssertTrue(win.performKeyEquivalent(with: chapterKey(37, "l", .command, window: win.windowNumber)))
            let list = try XCTUnwrap(win.chapterList)
            XCTAssertTrue(list.jumper === TranscriptJumper.of(focused.transcript), "the focused pane's list")
            XCTAssertFalse(list.jumper === TranscriptJumper.of(other.transcript), "not the other pane's")
            list.chapters = { [TranscriptOutline.Chapter(id: 3, ordinal: 1, title: "Prompt 1", kind: .prompt, hasError: false)] }
            list.select(0)
            XCTAssertTrue(list.command(#selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(TranscriptJumper.of(focused.transcript).request?.block, 3, "the focused pane jumps")
            XCTAssertTrue(TranscriptJumper.of(other.transcript).request == nil, "the other pane gets nothing")
            XCTAssertEqual(fake.closes, 1, "Return closes")
            settle(host)
            XCTAssertEqual(m.keyFocus, .pane, "the jump leaves keyFocus")
            XCTAssertEqual(m.selection, selection, "and the selection")
            XCTAssertEqual(m.layout, layout, "and the focused pane")
            XCTAssertTrue(win.firstResponder === responder)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }
}
