import AppKit
import XCTest
@testable import ProsperApp

/// #895 P2 step 2: in the Agent Sessions window Command-= (Shift-Command-= too), Command-minus and Command-0 size the
/// terminal's text, in Terminal mode only. Pure: key events are built (NSEvent.keyEvent values) and handed to the
/// pure `route`; nothing is posted, no window is built or shown, no keyboard layout is read or switched, no dch runs.
extension AgentWindowD1Tests {
    typealias FontRoute = AgentsNSWindow.KeyRoute
    /// Key code, characters, modifiers, the responder, Terminal mode, renaming, the form, the route, a tag.
    typealias FontRow = (UInt16, String, NSEvent.ModifierFlags, AgentsNSWindow.ResponderKind, Bool, Bool, Bool, FontRoute, String)

    @MainActor
    func assertFontRoutes(_ table: [FontRow], file: StaticString = #filePath, line: UInt = #line) {
        for (code, chars, flags, responder, terminal, renaming, form, want, tag) in table {
            for sidebar in [false, true] {
                XCTAssertEqual(AgentsNSWindow.route(digitKey(code, chars, flags), responder: responder, sidebarFocused: sidebar,
                                                    terminalMode: terminal, renaming: renaming, form: form),
                               want, "\(tag), sidebar focused: \(sidebar)", file: file, line: line)
            }
        }
    }

    static let fontCmd: NSEvent.ModifierFlags = .command
    static let fontPad: NSEvent.ModifierFlags = [.command, .numericPad]

    @MainActor
    func testAgentWindowTerminalFontChordsRouteOnlyInTerminalMode() {
        let cmd = Self.fontCmd, pad = Self.fontPad, shift: NSEvent.ModifierFlags = [.command, .shift]
        assertFontRoutes([
            // Terminal mode, from every responder.
            (24, "=", cmd, .terminal, true, false, false, .font(1), "Command-="),
            (24, "+", shift, .terminal, true, false, false, .font(1), "Shift-Command-= (Command-plus)"),
            (69, "+", pad, .other, true, false, false, .font(1), "keypad Command-plus"),
            (27, "-", cmd, .terminal, true, false, false, .font(-1), "Command-minus"),
            (78, "-", pad, .text, true, false, false, .font(-1), "keypad Command-minus from the find field"),
            (29, "0", cmd, .other, true, false, false, .font(0), "Command-0"),
            (82, "0", pad, .terminal, true, false, false, .font(0), "keypad Command-0"),
            (29, "\u{E0}", cmd, .terminal, true, false, false, .font(0), "AZERTY Command-0 (by key code)"),
            // Transcript mode: they pass, as today.
            (24, "=", cmd, .text, false, false, false, .pass, "Transcript Command-="),
            (24, "+", shift, .other, false, false, false, .pass, "Transcript Shift-Command-="),
            (27, "-", cmd, .text, false, false, false, .pass, "Transcript Command-minus"),
            (29, "0", cmd, .other, false, false, false, .pass, "Transcript Command-0"),
            // Not these chords: other modifiers, or no Command.
            (27, "_", shift, .terminal, true, false, false, .pass, "Shift-Command-minus"),
            (24, "\u{2260}", [.command, .option], .terminal, true, false, false, .pass, "Option-Command-="),
            (24, "=", [.command, .control], .terminal, true, false, false, .pass, "Control-Command-="),
            (24, "=", [], .terminal, true, false, false, .pass, "= typed into the terminal"),
            (27, "-", [], .terminal, true, false, false, .pass, "- typed into the terminal"),
            (29, "0", [], .terminal, true, false, false, .pass, "0 typed into the terminal"),
        ])
    }

    @MainActor
    func testAgentWindowTerminalFontChordsUnderTheFormAndWhileRenaming() {
        let cmd = Self.fontCmd
        assertFontRoutes([
            // The New session form covers the pane: swallowed, as the other chords that act on the session under it.
            (24, "=", cmd, .text, true, false, true, .swallow, "form Command-="),
            (27, "-", cmd, .text, true, false, true, .swallow, "form Command-minus"),
            (29, "0", cmd, .other, true, false, true, .swallow, "form Command-0"),
            (29, "0", cmd, .text, false, false, true, .pass, "form over Transcript: Command-0 passes"),
            // The rename field: every key but Command-W is the field's.
            (24, "=", cmd, .text, true, true, false, .pass, "rename Command-="),
            (27, "-", cmd, .text, true, true, false, .pass, "rename Command-minus"),
            (29, "0", cmd, .text, true, true, false, .pass, "rename Command-0"),
        ])
    }

    /// Command-0 is the font reset in Terminal mode and never the row jump (digit() stops at slot 8).
    @MainActor
    func testAgentWindowTerminalFontCommandZeroIsNotAJump() {
        XCTAssertTrue(AgentsNSWindow.digit(29) == nil, "the 0 key is no digit")
        XCTAssertTrue(AgentsNSWindow.digit(82) == nil, "keypad 0 is no digit")
        for code: UInt16 in [29, 82] {
            for terminal in [true, false] {
                for responder: AgentsNSWindow.ResponderKind in [.terminal, .text, .other] {
                    let r = AgentsNSWindow.route(digitKey(code, "0", code == 82 ? Self.fontPad : Self.fontCmd),
                                                 responder: responder, sidebarFocused: false, terminalMode: terminal)
                    if case .jump = r { XCTFail("key \(code) jumped") }
                    XCTAssertEqual(r, terminal ? .font(0) : .pass)
                }
            }
        }
    }

    /// The window's other keys route exactly as before this step.
    @MainActor
    func testAgentWindowTerminalFontKeptKeysRouteAsBefore() {
        let cmd = Self.fontCmd, pad = Self.fontPad, opt: NSEvent.ModifierFlags = [.command, .option]
        let shift: NSEvent.ModifierFlags = [.command, .shift]
        let arrows: NSEvent.ModifierFlags = [.command, .numericPad, .function]
        assertFontRoutes([
            // Command 1 to 9: the row jump, both modes.
            (18, "1", cmd, .terminal, true, false, false, .jump(1), "Command-1"),
            (19, "2", cmd, .other, false, false, false, .jump(2), "Command-2"),
            (20, "3", cmd, .text, true, false, false, .jump(3), "Command-3"),
            (21, "4", cmd, .terminal, false, false, false, .jump(4), "Command-4"),
            (23, "5", cmd, .terminal, true, false, false, .jump(5), "Command-5"),
            (22, "6", cmd, .other, true, false, false, .jump(6), "Command-6"),
            (26, "7", cmd, .terminal, true, false, false, .jump(7), "Command-7"),
            (28, "8", cmd, .text, false, false, false, .jump(8), "Command-8"),
            (25, "9", cmd, .terminal, true, false, false, .jump(9), "Command-9"),
            (92, "9", pad, .terminal, true, false, false, .jump(9), "keypad Command-9"),
            // The window's chords.
            (13, "w", cmd, .terminal, true, false, false, .close, "Command-W"),
            (13, "w", cmd, .text, true, true, false, .close, "Command-W while renaming"),
            (17, "t", cmd, .terminal, true, false, false, .toggleMode, "Command-T"),
            (17, "t", cmd, .text, false, false, false, .toggleMode, "Command-T in Transcript"),
            (3, "f", cmd, .terminal, true, false, false, .find, "Command-F"),
            (3, "f", cmd, .text, false, false, false, .pass, "Command-F in Transcript"),
            (5, "g", cmd, .terminal, true, false, false, .findNext(true), "Command-G"),
            (5, "G", shift, .terminal, true, false, false, .findNext(false), "Shift-Command-G"),
            (5, "g", cmd, .other, false, false, false, .pass, "Command-G in Transcript"),
            (45, "n", cmd, .terminal, true, false, false, .newSession, "Command-N"),
            (45, "N", shift, .text, false, false, false, .newShell, "Shift-Command-N"),
            (45, "n", cmd, .text, true, false, true, .newSession, "Command-N under the form"),
            (126, "\u{F700}", arrows, .other, true, false, false, .session(-1), "Command-Up"),
            (125, "\u{F701}", arrows, .text, true, false, false, .pass, "Command-Down in a text view"),
            // Option-Command-1/2/3: the level in Transcript, swallowed in Terminal mode.
            (18, "\u{A1}", opt, .other, false, false, false, .verbosity(.focused), "Option-Command-1"),
            (19, "\u{2122}", opt, .terminal, false, false, false, .verbosity(.default), "Option-Command-2"),
            (20, "\u{A3}", opt, .text, false, false, false, .verbosity(.verbose), "Option-Command-3"),
            (18, "\u{A1}", opt, .terminal, true, false, false, .swallow, "Option-Command-1 in Terminal mode"),
            // The Edit menu's keys pass to the responder and the menu, as today.
            (8, "c", cmd, .terminal, true, false, false, .pass, "Command-C"),
            (9, "v", cmd, .terminal, true, false, false, .pass, "Command-V"),
            (7, "x", cmd, .text, false, false, false, .pass, "Command-X"),
            (6, "z", cmd, .text, false, false, false, .pass, "Command-Z"),
            (6, "Z", shift, .text, false, false, false, .pass, "Shift-Command-Z"),
            (0, "a", cmd, .terminal, true, false, false, .pass, "Command-A"),
        ])
    }
}
