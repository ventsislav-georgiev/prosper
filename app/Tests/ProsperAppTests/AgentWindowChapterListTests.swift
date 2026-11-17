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
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            var raised = 0
            win.raise = { _ in raised += 1 }   // the recorder first: the real key-and-front call never runs
            defer { XCTAssertEqual(raised, 0, "nothing raised the window") }
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

    // MARK: 13.4: from the sidebar, then Esc

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
            clickRow("a", m, win, host)
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertEqual(AgentsNSWindow.chaptersItem(m), .chapters(enabled: false, pane: m.layout.focused), "a terminal pane: off")
            XCTAssertTrue(win.performKeyEquivalent(with: chapterKey(37, "l", .command, window: win.windowNumber)), "consumed")
            AgentsNSWindow.chaptersChosen(pane: m.layout.focused)
            XCTAssertEqual(fake.presents, 0, "a terminal pane: no list")
            XCTAssertTrue(win.chapterList == nil)
        }
    }

    // MARK: 13.4 / #904 r1: the focused pane only; a jump keeps focus and selection

}
