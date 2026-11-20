import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1111: in the Agent Sessions sidebar a group (#1342: two live members or more of one stem) takes ONE Command number,
/// which picks the member picked last (its first member, the main, the first time); Control-Tab and Control-Shift-Tab
/// move between the selected group's members. Outside a group nothing changes: every row keeps its own number and
/// Control-Tab goes on to the responder. Offscreen only: key events are built and handed to the pure `route` or to a
/// never-shown window's own performKeyEquivalent / sendEvent (nothing is posted, no window is ordered in or made key, no
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

    /// api (working) + api-2 (idle) + api-qa (blocked): one group at api-qa's place (Needs you); web (idle) alone.
    func grouped(suffix: String = "-qa") -> AgentWindowModel {
        let (m, _) = g.model(g.grouped, suffix: suffix)
        _ = d1.fakeTerminal(m)
        return m
    }

    // MARK: The route, as a literal table

    /// Key code, modifiers, responder, renaming, the form, the route. Red at base: no Control-Tab line in paneRoute
    /// (after AgentsWindow.swift:376, the route fell through to `.pass`).
    func testGroupChordRouteIsALiteralTable() {
        typealias R = AgentsNSWindow.KeyRoute
        let c: NSEvent.ModifierFlags = .control, cs: NSEvent.ModifierFlags = [.control, .shift]
        let table: [(UInt16, NSEvent.ModifierFlags, AgentsNSWindow.ResponderKind, Bool, Bool, R, String)] = [
            (48, c, .terminal, false, false, .member(1), "Control-Tab from the terminal"),
            (48, c, .text, false, false, .member(1), "Control-Tab from the composer (a text view)"),
            (48, c, .other, false, false, .member(1), "Control-Tab from the sidebar"),
            (48, cs, .terminal, false, false, .member(-1), "Control-Shift-Tab from the terminal"),
            (48, cs, .text, false, false, .member(-1), "Control-Shift-Tab from a text view"),
            (48, cs, .other, false, false, .member(-1), "Control-Shift-Tab from the sidebar"),
            (48, [.control, .capsLock], .terminal, false, false, .member(1), "Caps Lock is no modifier here"),
            (48, c, .text, true, false, .pass, "the rename field keeps it"),
            (48, cs, .text, true, false, .pass, "the rename field keeps Control-Shift-Tab"),
            // #1602 (QA #1486 B9): the form's (its prompt is a text view where Tab types a tab: Control-Tab is the way out).
            (48, c, .text, false, true, .pass, "under the New session form: the form's, not swallowed"),
            (48, cs, .text, false, true, .pass, "under the New session form: Control-Shift-Tab the form's"),
            (48, c, .other, false, true, .pass, "under the New session form, from no text view: the form's too"),
            (48, [], .terminal, false, false, .pass, "Tab is the terminal's"),
            (48, .shift, .text, false, false, .pass, "Shift-Tab is the responder's"),
            (48, .option, .terminal, false, false, .pass, "Option-Tab"),
            (48, [.control, .option], .terminal, false, false, .pass, "Control-Option-Tab"),
            (48, [.control, .command], .other, false, false, .pass, "Control-Command-Tab"),
            (123, .option, .text, false, false, .pass, "Option-Left stays a word move (not this chord)"),
            (124, .option, .terminal, false, false, .pass, "Option-Right stays a word move (not this chord)"),
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
        XCTAssertTrue(AgentsNSWindow.keyTable.contains { $0.keyCode == 48 && $0.mods == .control && $0.route == .member(1) })
        XCTAssertTrue(AgentsNSWindow.keyTable.contains { $0.keyCode == 48 && $0.mods == [.control, .shift] && $0.route == .member(-1) })
    }

    // MARK: The numbers, through the model

    /// One number per group, on its first line; no group (the suffix off): every live row its own number, as at #1110.
    /// Red at base: numberedIDs walked `sections` row by row (AgentWindowModel.swift:1980), so api, api-2 and api-qa took
    /// three numbers.
    func testGroupTakesOneNumberAndNoGroupKeepsEveryRowsNumber() throws {
        try withPrefs {
            let m = grouped()
            defer { m.close() }
            XCTAssertEqual(m.numberedIDs, [key("api"), key("web")], "the group (Needs you) is 1, web is 2")
            XCTAssertEqual(m.number(key("api")), 1)
            XCTAssertTrue(m.number(key("api-2")) == nil && m.number(key("api-qa")) == nil, "one chip per group")
            XCTAssertEqual(m.number(key("web")), 2)
            let numbers = m.numbers
            XCTAssertEqual(numbers, [key("api"): 1, key("web"): 2], "the view's one-pass numbers are the model's")

            let plain = grouped(suffix: "")
            defer { plain.close() }
            let live = plain.sections.filter { $0.title != "History" }.flatMap(\.rows).map(\.id)
            XCTAssertEqual(live.count, 4)
            XCTAssertEqual(plain.numberedIDs, live, "no group: every live row numbered, in the sidebar's order")
            XCTAssertEqual(plain.numbers.count, 4)
            for (i, id) in live.enumerated() { XCTAssertEqual(plain.number(id), i + 1) }
        }
    }

    /// Command-1 picks the group's main the first time (the first fill's own pick is not the human's), then the member
    /// picked last; Command-2 is web. Red at base: selectNumbered clicked `ids[n - 1]` (AgentWindowModel.swift:1993), a row, never the group's last pick.
    func testCommandNumberPicksTheGroupMemberPickedLast() throws {
        try withPrefs {
            let m = grouped()
            defer { m.close() }
            XCTAssertTrue(m.selectNumbered(1))
            XCTAssertEqual(m.selection, key("api"), "the first time: the group's first member (the main)")
            m.click(key("api-qa"))
            XCTAssertTrue(m.selectNumbered(2))
            XCTAssertEqual(m.selection, key("web"))
            XCTAssertTrue(m.selectNumbered(1))
            XCTAssertEqual(m.selection, key("api-qa"), "back to the member picked last")
            m.select(key("api-2"))
            m.select(key("web"))
            XCTAssertTrue(m.selectNumbered(1))
            XCTAssertEqual(m.selection, key("api-2"))
            XCTAssertFalse(m.selectNumbered(3), "two numbers only")
            XCTAssertFalse(m.selectNumbered(0))
            XCTAssertEqual(m.selection, key("api-2"), "nothing changed")
            XCTAssertLessThanOrEqual(m.recentSelections.count, AgentWindowModel.recentCap)
        }
    }

    /// Control-Tab walks the group in group order and wraps; Control-Shift-Tab back; outside a group: false, no change.
    /// Red at base: no stepGroupMember (the chord did nothing).
    func testControlTabStepsThroughTheGroupAndWraps() throws {
        try withPrefs {
            let m = grouped()
            defer { m.close() }
            m.click(key("api"))
            XCTAssertEqual(m.selectionGroup, ["api", "api-2", "api-qa"].map(key))
            for want in ["api-2", "api-qa", "api"] {
                XCTAssertTrue(m.stepGroupMember(1))
                XCTAssertEqual(m.selection, key(want))
            }
            XCTAssertTrue(m.stepGroupMember(-1))
            XCTAssertEqual(m.selection, key("api-qa"), "back from the first: the last")
            XCTAssertTrue(m.stepGroupMember(-1))
            XCTAssertEqual(m.selection, key("api-2"))
            m.click(key("web"))
            XCTAssertTrue(m.selectionGroup == nil, "web is in no group")
            XCTAssertFalse(m.stepGroupMember(1))
            XCTAssertFalse(m.stepGroupMember(-1))
            XCTAssertEqual(m.selection, key("web"), "outside a group: nothing")
            XCTAssertTrue(m.selectNumbered(1))
            XCTAssertEqual(m.selection, key("api-2"), "the last step is the member picked last")
        }
    }

    /// No group at all (a user with no sidekick): Control-Tab is false everywhere and the selection stays.
    func testControlTabWithNoGroupDoesNothing() throws {
        try withPrefs {
            let m = grouped(suffix: "")
            defer { m.close() }
            for name in ["api", "api-2", "api-qa", "web"] {
                m.click(key(name))
                XCTAssertTrue(m.selectionGroup == nil, name)
                XCTAssertFalse(m.stepGroupMember(1), name)
                XCTAssertEqual(m.selection, key(name))
            }
        }
    }

    // MARK: The window's key path (a never-shown window, built events)

    /// performKeyEquivalent: Control-Tab in the group moves on (true); on web it is not the window's (false: it goes on
    /// to the responder). sendEvent with the split gate on: the group's step wins over #901's previous layout (a lone MRU,
    /// which layoutKey consumes as a no-op). The Go menu's items are on only in a group.
    /// Red at base: perform had no `.member` case (AgentsWindow.swift:456); sendEvent ran layoutKey first (:631).
    func testControlTabThroughTheWindow() throws {
        try withPrefs {
            let m = grouped()
            defer { m.close() }
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            var raised = 0
            win.raise = { _ in raised += 1 }   // #1586 (QA 1092's belt): the recorder first: the real key-and-front never runs
            m.click(key("api"))
            XCTAssertTrue(win.enabled(.key(.member(1))))
            XCTAssertTrue(win.enabled(.key(.member(-1))))
            XCTAssertTrue(win.performKeyEquivalent(with: tab()))
            XCTAssertEqual(m.selection, key("api-2"))
            XCTAssertTrue(win.performKeyEquivalent(with: tab([.control, .shift])))
            XCTAssertEqual(m.selection, key("api"))
            m.click(key("web"))
            XCTAssertFalse(win.enabled(.key(.member(1))), "off outside a group")
            XCTAssertFalse(win.performKeyEquivalent(with: tab()), "outside a group the key goes on")
            XCTAssertEqual(m.selection, key("web"))

            m.click(key("api"))
            AgentPaneLayout.splitsEnabled = true   // withRow puts it back
            let gateOn = PaneKeys.Context(responder: .other, keyFocus: .pane, panes: 1, splitsEnabled: true)
            XCTAssertEqual(PaneKeys.action(for: tab(), context: gateOn), .previousLayout, "control: #901's chord with the gate on")
            win.sendEvent(tab())
            XCTAssertEqual(m.selection, key("api-2"), "the group's step ran first")
            XCTAssertEqual(raised, 0, "a key asks no key and front")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// #1602 (QA #1486 B9): outside a group, with the split gate on, Control-Tab through the window's sendEvent still runs
    /// #901's previous layout (the MRU pair): the group's step gives false and the key goes on to layoutKey.
    /// Red if `.member` is handled outside a group (perform's `return model.stepGroupMember(step)` at AgentsWindow.swift:472
    /// made a plain call, so it falls to `return true` and sendEvent returns at :654, before layoutKey at :655).
    func testControlTabOutsideAGroupStillRunsThePreviousLayout() throws {
        try withPrefs {
            AgentPaneLayout.splitsEnabled = true   // withRow puts it back
            let a = d1.paneLayout([d1.paneTarget("web")]), b = d1.paneLayout([d1.paneTarget("web")])
            let d = d1.layoutSuite()
            d.set(try PaneLayoutStore(layouts: [a, b], active: a.id, mru: [a.id]).encode(), forKey: "agentWindowLayouts")
            let st = d1.store(g.grouped)
            st.pairSuffix = "-qa"
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
            XCTAssertTrue(m.selectionGroup == nil, "web is in no group")
            XCTAssertTrue(m.switchLayout(number: 2) == nil, "layout 2 active, the MRU pair is 2 then 1")
            XCTAssertEqual(m.layout.id, b.id)
            win.sendEvent(tab())
            XCTAssertEqual(m.layout.id, a.id, "Control-Tab outside a group: #901's previous layout")
            XCTAssertEqual(m.selection, key("web"), "no member step")
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
