import AppKit
import XCTest
@testable import ProsperApp

/// #1319, #1471 b: the Jump to Chapter list is gone with the transcript; Command-L (R1) and Command-T (R1471a-s1, the old
/// mode toggle) are swallowed in a terminal pane. Keys are built events handed to the pure `route` (nothing is posted;
/// no window).
extension AgentWindowD1Tests {

    @MainActor
    func chapterKey(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags, window: Int = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @MainActor
    func testChapterKeyAndCommandTAreSwallowedInATerminalPane() {
        typealias R = AgentsNSWindow.KeyRoute
        func route(_ e: NSEvent, _ r: AgentsNSWindow.ResponderKind = .text, sidebar: Bool = false, terminal: Bool = false,
                   renaming: Bool = false, form: Bool = false) -> R {
            AgentsNSWindow.route(e, responder: r, sidebarFocused: sidebar, terminalMode: terminal, renaming: renaming, form: form)
        }
        let cyrillic = chapterKey(37, "\u{0434}", .command)
        // Command-L (R1): swallowed in a terminal pane, by key code, as on the parent (no bytes, no list); elsewhere it passes.
        XCTAssertEqual(route(chapterKey(37, "l", .command), .terminal, terminal: true), .swallow, "a terminal pane: consumed")
        XCTAssertEqual(route(cyrillic, .other, terminal: true), .swallow, "by key code too")
        XCTAssertEqual(route(chapterKey(37, "l", [.command, .capsLock]), .terminal, terminal: true), .swallow, "Caps Lock is not a modifier here")
        XCTAssertEqual(route(chapterKey(37, "l", .command), .terminal, terminal: true, renaming: true), .pass, "the rename field's")
        XCTAssertEqual(route(chapterKey(37, "L", [.command, .shift]), .terminal, terminal: true), .pass, "Shift-Command-L passes through")
        XCTAssertEqual(route(chapterKey(37, "l", .command)), .pass, "a text field, no terminal: no list now")
        XCTAssertEqual(route(chapterKey(37, "l", .command), .other, sidebar: true), .pass, "the sidebar")
        XCTAssertEqual(route(chapterKey(37, "l", .command), form: true), .pass, "the New session form's field")
        XCTAssertFalse(AgentsNSWindow.keyTable.contains { $0.keyCode == 37 }, "no Command-L chord in the table or the Go menu")
        // Command-T: swallowed in a terminal pane (no bytes, no menu); elsewhere it passes; the rename field keeps it.
        XCTAssertEqual(route(chapterKey(17, "t", .command), .terminal, terminal: true), .swallow, "a terminal pane: swallowed")
        XCTAssertEqual(route(chapterKey(17, "t", .command), .other, terminal: true), .swallow)
        XCTAssertEqual(route(chapterKey(17, "t", .command)), .pass, "no terminal: not the window's")
        XCTAssertEqual(route(chapterKey(17, "t", .command), .terminal, terminal: true, renaming: true), .pass, "the rename field's")
        XCTAssertEqual(route(chapterKey(17, "T", [.command, .shift]), .terminal, terminal: true), .pass, "Shift-Command-T: not a chord now")
    }
}
