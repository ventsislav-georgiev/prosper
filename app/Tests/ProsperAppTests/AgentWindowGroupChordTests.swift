import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1111, #1820: the pair groups are gone, and with them the group's one Command number and the Control-Tab member step
/// (the Go menu's Next / Previous in Group too). Control-Tab is no route of the window: it goes on as before #1111 (#901's
/// previous layout with the split gate on, the terminal's Tab). Offscreen only: key events are built and handed to the
/// pure `route` or to a never-shown window's own sendEvent (nothing is posted, no window is ordered in or made key, no
/// monitor is installed); the terminal's spawn is a recorder. Session names are generic.
@MainActor
final class AgentWindowGroupChordTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()
    private let g = AgentSidebarGroupRowTests()

    func key(_ name: String) -> AgentSidebar.RowID { g.key(name) }

    func tab(_ flags: NSEvent.ModifierFlags = .control, code: UInt16 = 48, window: Int = 0,
             type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window, context: nil,
                         characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: code)!
    }

    /// The sidebar mode, the split gate, the scale (withRow) and the folded sections (withDigitPrefs) put back after.
    func withPrefs(_ body: () throws -> Void) rethrows {
        try g.withRow { try d1.withDigitPrefs(body) }
    }

    // MARK: The route, as a literal table

    /// Key code, modifiers, responder, renaming, the form, the route: Control-Tab is the window's nowhere (#1820).
    /// Red with #1111's line in paneRoute (it gave `.member` for the first seven rows).
    func testControlTabIsNoWindowRoute() {
        typealias R = AgentsNSWindow.KeyRoute
        let c: NSEvent.ModifierFlags = .control, cs: NSEvent.ModifierFlags = [.control, .shift]
        let table: [(UInt16, NSEvent.ModifierFlags, AgentsNSWindow.ResponderKind, Bool, Bool, R, String)] = [
            (48, c, .terminal, false, false, .pass, "Control-Tab from the terminal"),
            (48, c, .text, false, false, .pass, "Control-Tab from the composer (a text view)"),
            (48, c, .other, false, false, .pass, "Control-Tab from the sidebar"),
            (48, cs, .terminal, false, false, .pass, "Control-Shift-Tab from the terminal"),
            (48, cs, .text, false, false, .pass, "Control-Shift-Tab from a text view"),
            (48, cs, .other, false, false, .pass, "Control-Shift-Tab from the sidebar"),
            (48, [.control, .capsLock], .terminal, false, false, .pass, "Caps Lock is no modifier here"),
            (48, c, .text, true, false, .pass, "the rename field keeps it"),
            // #1602 (QA #1486 B9): the form's (its prompt is a text view where Tab types a tab: Control-Tab is the way out).
            (48, c, .text, false, true, .pass, "under the New session form: the form's, not swallowed"),
            (48, cs, .text, false, true, .pass, "under the New session form: Control-Shift-Tab the form's"),
            (48, [], .terminal, false, false, .pass, "Tab is the terminal's"),
            (48, .shift, .text, false, false, .pass, "Shift-Tab is the responder's"),
            (50, c, .terminal, false, false, .pass, "Control-` is not Tab"),
        ]
        for (code, flags, responder, renaming, form, want, tag) in table {
            for terminal in [true, false] {
                for sidebar in [true, false] {
                    XCTAssertEqual(AgentsNSWindow.route(tab(flags, code: code), responder: responder, sidebarFocused: sidebar,
                                                        terminalMode: terminal, renaming: renaming, form: form), want,
                                   "\(tag) (terminal \(terminal), sidebar \(sidebar))")
                }
            }
        }
        XCTAssertEqual(AgentsNSWindow.route(tab(type: .keyUp), responder: .terminal, sidebarFocused: false, terminalMode: true),
                       .pass, "a key up is nobody's chord")
        XCTAssertFalse(AgentsNSWindow.keyTable.contains { $0.keyCode == 48 }, "no Tab chord in the window's table")
        XCTAssertFalse(AgentGoMenu.entries(splits: true, panes: 2).contains { $0?.key == "\t" }, "no Go menu item on Tab")
    }

    // MARK: The window's key path (a never-shown window, built events)

    /// #1602 (QA #1486 B9), #1820: with the split gate on, Control-Tab through the window's sendEvent runs #901's previous
    /// layout (the MRU pair) and selects no other session. Red if sendEvent consumes Control-Tab before layoutKey.
    func testControlTabRunsThePreviousLayout() throws {
        try withPrefs {
            AgentPaneLayout.splitsEnabled = true   // withRow puts it back
            let a = d1.paneLayout([d1.paneTarget("web")]), b = d1.paneLayout([d1.paneTarget("web")])
            let d = d1.layoutSuite()
            d.set(try PaneLayoutStore(layouts: [a, b], active: a.id, mru: [a.id]).encode(), forKey: "agentWindowLayouts")
            let st = d1.store([d1.session("api", .working), d1.session("api-qa", .blocked), d1.session("web", .idle)])
            let m = d1.windowModel(st, layouts: d)
            m.setVisible(true)
            _ = d1.fakeTerminal(m)
            defer { m.close() }
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            var raised = 0
            win.raise = { _ in raised += 1 }   // the recorder first: the real key-and-front never runs
            m.click(key("web"))
            XCTAssertTrue(m.switchLayout(number: 2) == nil, "layout 2 active, the MRU pair is 2 then 1")
            XCTAssertEqual(m.layout.id, b.id)
            win.sendEvent(tab())
            XCTAssertEqual(m.layout.id, a.id, "Control-Tab: #901's previous layout")
            XCTAssertEqual(m.selection, key("web"), "no session step")
            XCTAssertEqual(raised, 0, "a key asks no key and front")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: The shared keycap (R1111-1)

    /// The sidebar chip is Clipboard History's keycap with the Command glyphs: the same size as the keycap given those
    /// glyphs; the keycap with no glyph reads the clipboard's setting as before.
    func testDigitChipIsTheSharedKeycap() {
        for (n, glyph) in [(1, "\u{2318}"), (9, "\u{2318}"), (10, "\u{2325}\u{2318}"), (18, "\u{2325}\u{2318}")] {
            XCTAssertEqual(AgentDigitChip.glyphs(n), glyph)
            let chip = NSHostingView(rootView: AgentDigitChip(number: n)).fittingSize
            let cap = NSHostingView(rootView: PositionKeyCap(digit: "\(AgentDigitChip.digit(n))", active: false, glyph: glyph)
                .fixedSize()).fittingSize
            XCTAssertEqual(chip.width, cap.width, accuracy: 0.01, "\(n)")
            XCTAssertEqual(chip.height, cap.height, accuracy: 0.01, "\(n)")
        }
        let clip = NSHostingView(rootView: PositionKeyCap(digit: "1", active: true).fixedSize()).fittingSize
        let same = NSHostingView(rootView: PositionKeyCap(digit: "1", active: true, glyph: Preferences.quickSelectModifier.glyph)
            .fixedSize()).fittingSize
        XCTAssertEqual(clip, same, "Clipboard History's keycap: the setting's glyph, as before")
    }
}
