import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1930: the window's confirmation (Remove from History, Stop, Kill, Restart) is a card centred over its subject's pane,
/// that pane dimmed behind it, a clear layer over the pane area that cancels; Return confirms and Escape cancels from any
/// responder, which keeps the keys. Offscreen only: the window is never shown, ordered in or made key (its raise is a
/// recorder), events are built values handed to its sendEvent, the session verbs are recorders and no dch runs.
extension AgentWindowD1Tests {
    /// Two panes, web | api (gate on), api's pane focused; Stop asked on api. The stop is a recorder.
    @MainActor
    func confirmCardModel() throws -> (m: AgentWindowModel, web: UUID, api: UUID, stops: () -> Int) {
        let st = store([mapped("web"), mapped("api")])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st, layouts: layoutSuite())
        var stops = 0
        m.stopSession = { _ in stops += 1; return true }
        _ = splitTerminals(m)   // every pane terminal on recorders (no dch, no pty)
        m.setVisible(true)
        m.adopt(paneLayout([paneTarget("web"), paneTarget("api")]))
        let web = try XCTUnwrap(m.layout.order.first), api = try XCTUnwrap(m.layout.order.last)
        m.focusPane(api)
        return (m, web, api, { stops })
    }

    @MainActor
    func confirmCardAsk(_ m: AgentWindowModel) throws {
        let s = try XCTUnwrap(m.store?.sessions.first { $0.name == "api" })
        m.ask(.stop, s)
        XCTAssertEqual(m.confirming, AgentWindowConfirm(verb: .stop, key: s.key), "premise: Stop asked")
    }

    /// The pane-area probe frames of a fresh host of `m`: kind -> pane -> frame.
    @MainActor
    func confirmCardFrames(_ m: AgentWindowModel) -> (frames: [String: [UUID: CGRect]], win: AgentsNSWindow, host: NSView) {
        var seen: [String: [UUID: CGRect]] = [:]
        AgentPaneArea.probe = { seen[$0, default: [:]][$1] = $2 }
        defer { AgentPaneArea.probe = nil }
        let (win, host) = focusWindow(m)
        win.raise = { _ in }   // QA 1092's belt: the real makeKeyAndOrderFront never runs
        settle(host)
        return (seen, win, host)
    }

    /// The card sits centred over api's pane (the subject's), that pane alone dimmed, the outside layer over the whole
    /// area; closed, none of it exists. Red at base: no card (the question was a strip in the pane's top overlay).
    @MainActor
    func testAgentWindowConfirmCardSitsOverTheSubjectPane() throws {
        try withModePref {
            try withPaneMenu(true) {
                let (m, web, api, _) = try confirmCardModel()
                defer { m.close() }
                try confirmCardAsk(m)
                let (seen, win, _) = confirmCardFrames(m)
                defer { win.close() }
                let pane = try XCTUnwrap(seen["pane"]?[api]), other = try XCTUnwrap(seen["pane"]?[web])
                XCTAssertEqual(seen["confirm"].map { Array($0.keys) }, [api], "one card, over api's pane")
                let card = try XCTUnwrap(seen["confirm"]?[api]), dim = try XCTUnwrap(seen["confirmDim"]?[api])
                XCTAssertEqual(card.midX, pane.midX, accuracy: 1, "centred across the pane")
                XCTAssertEqual(card.midY, pane.midY, accuracy: 1, "centred down the pane")
                XCTAssertTrue(pane.contains(card), "inside the pane: \(card) in \(pane)")
                XCTAssertFalse(card.intersects(other), "never over web's pane")
                for (x, y) in [(dim.minX, pane.minX), (dim.minY, pane.minY), (dim.width, pane.width), (dim.height, pane.height)] {
                    XCTAssertEqual(x, y, accuracy: 0.5, "the dim is api's pane exactly: \(dim) vs \(pane)")
                }
                let whole = pane.union(other), out = try XCTUnwrap(seen["confirmOutside"]?[api])
                XCTAssertTrue(out.insetBy(dx: -0.5, dy: -0.5).contains(whole), "the outside layer covers the area: \(out)")
                m.confirm(false)
                XCTAssertTrue(m.confirming == nil)
                let (closed, win2, _) = confirmCardFrames(m)
                defer { win2.close() }
                XCTAssertEqual(closed["pane"]?.count, 2, "premise: the panes reported")
                XCTAssertTrue(closed["confirm"] == nil && closed["confirmDim"] == nil && closed["confirmOutside"] == nil,
                              "no question: no card, no dim, no layer")
                XCTAssertFalse(win.isVisible || win2.isVisible, "never shown")
            }
        }
    }

    /// The rule: the pane whose content is the asked row, in tiling order; none shows it: the focused pane. A History
    /// record and a live session of the same key are different subjects (#580).
    func testAgentWindowConfirmCardPaneRule() {
        let a = UUID(), b = UUID(), c = UUID()
        let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")
        let live = PaneContent.live(session("api", .idle)), rec = PaneContent.history(record("api"))
        let panes: [(UUID, PaneContent?)] = [(a, nil), (b, live), (c, rec)]
        XCTAssertEqual(AgentWindowModel.confirmPane(.live(key), focused: a, panes: panes), b, "the live session's pane, not the focused one")
        XCTAssertEqual(AgentWindowModel.confirmPane(.history(key), focused: a, panes: panes), c, "the record's pane")
        XCTAssertEqual(AgentWindowModel.confirmPane(.live(key), focused: c, panes: [(a, nil), (c, rec)]), c,
                       "no pane shows it: the focused pane")
        XCTAssertEqual(AgentWindowModel.confirmPane(.history(key), focused: a, panes: []), a, "no pane at all: the focused one")
    }

    /// Escape cancels and Return confirms with api's terminal first responder, through sendEvent and through
    /// performKeyEquivalent; the terminal keeps the keys. With the sidebar's keys, Return confirms instead of moving in.
    /// A typed key, a Command-Return and keys with no question are not the card's. Red at base: sendEvent hands Escape and
    /// Return to the terminal (the question stays, nothing stops).
    @MainActor
    func testAgentWindowConfirmCardReturnAndEscapeFromAnyResponder() throws {
        try withModePref {
            try withPaneMenu(true) {
                let (m, _, _, stops) = try confirmCardModel()
                defer { m.close() }
                let (_, win, host) = confirmCardFrames(m)
                defer { win.close() }
                let term = try XCTUnwrap(m.terminal.view)
                XCTAssertTrue(AgentsNSWindow.focus(term), "premise: the terminal has the keys")
                XCTAssertFalse(AgentsNSWindow.confirmKey(focusKey(53, win), m), "no question: Escape is not taken")
                XCTAssertFalse(AgentsNSWindow.confirmKey(focusKey(36, win, "\r"), m), "no question: Return is not taken")
                try confirmCardAsk(m)
                XCTAssertFalse(AgentsNSWindow.confirmKey(focusKey(7, win, "x"), m), "a typed key goes on")
                let cmdReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                 windowNumber: win.windowNumber, context: nil, characters: "\r",
                                                 charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                XCTAssertFalse(AgentsNSWindow.confirmKey(cmdReturn, m), "Command-Return is not the card's")
                XCTAssertTrue(m.confirming != nil, "premise: still asking")
                win.sendEvent(focusKey(53, win, "\u{1b}"))
                XCTAssertTrue(m.confirming == nil, "Escape cancelled")
                XCTAssertEqual(stops(), 0, "nothing stopped")
                XCTAssertTrue(win.firstResponder === term, "the keys are back in the terminal")
                try confirmCardAsk(m)
                XCTAssertTrue(win.performKeyEquivalent(with: focusKey(53, win, "\u{1b}")), "Escape as a key equivalent: taken")
                XCTAssertTrue(m.confirming == nil, "cancelled")
                try confirmCardAsk(m)
                win.sendEvent(focusKey(36, win, "\r"))
                XCTAssertTrue(m.confirming == nil, "Return answered")
                XCTAssertEqual(stops(), 1, "Return confirmed: api stopped once")
                XCTAssertTrue(win.firstResponder === term, "the keys stay in the terminal")
                settle(host)
                try confirmCardAsk(m)
                sidebarKeys(win)
                let selected = m.selection
                win.sendEvent(focusKey(76, win, "\u{3}"))
                XCTAssertTrue(m.confirming == nil, "keypad Enter from the sidebar answered")
                XCTAssertEqual(stops(), 2, "confirmed")
                XCTAssertEqual(m.selection, selected, "the sidebar's Return did not run")
                XCTAssertTrue(win.sidebarFocused && !(win.firstResponder is AgentTerminalHostView), "the sidebar keeps the keys")
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }

    /// A down on another pane while the card shows (outside it): the question closes and nothing runs. Red when the card's
    /// clicks are swallowed before the panes (the question would stay).
    @MainActor
    func testAgentWindowConfirmCardClickOnAnotherPaneCancels() throws {
        try withModePref {
            try withPaneMenu(true) {
                let (m, web, _, stops) = try confirmCardModel()
                defer { m.close() }
                try confirmCardAsk(m)
                let (seen, win, host) = confirmCardFrames(m)
                defer { win.close() }
                let other = try XCTUnwrap(seen["pane"]?[web])
                let r = win.contentLayoutRect
                let area = try XCTUnwrap(m.paneAreaFrame(in: r.size))
                let p = CGPoint(x: area.minX + other.midX, y: area.minY + other.midY)
                for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                    win.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: r.minX + p.x, y: r.maxY - p.y),
                                                     modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: pressure)!)
                }
                settle(host)
                XCTAssertEqual(m.layout.focused, web, "premise: the click reached web's pane")
                XCTAssertTrue(m.confirming == nil, "the click outside the card cancelled")
                XCTAssertEqual(stops(), 0, "nothing stopped")
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }

    /// #1937: a first responder that records the keys it is handed and answers hasMarkedText as told (a fake input client:
    /// no input source is touched).
    final class KeyRecorderView: NSView, @preconcurrency NSTextInputClient {
        var downs = 0, ups = 0, marked = false
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { downs += 1 }
        override func keyUp(with event: NSEvent) { ups += 1 }
        func insertText(_ string: Any, replacementRange: NSRange) {}
        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
        func unmarkText() {}
        func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func hasMarkedText() -> Bool { marked }
        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
        func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
        func characterIndex(for point: NSPoint) -> Int { 0 }
    }

    @MainActor
    func confirmCardKey(_ type: NSEvent.EventType, _ code: UInt16, _ win: NSWindow, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeating, keyCode: code)!
    }

    /// #1937 f1: the Return (or keypad Enter) that confirmed is held: its repeats reach no responder, even with a new
    /// question open (the held key must not answer it), until its keyUp (which does reach the responder); then a fresh
    /// Return confirms and, with no question, goes to the responder. A resign key ends the hold too. Red at base: the
    /// repeat reaches the responder (downs 1) and answers the next question.
    @MainActor
    func testAgentWindowConfirmCardHeldReturnNeverRepeatsIntoTheResponder() throws {
        try withModePref {
            try withPaneMenu(true) {
                let (m, _, _, stops) = try confirmCardModel()
                defer { m.close() }
                let (_, win, _) = confirmCardFrames(m)
                defer { win.close() }
                let rec = KeyRecorderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                win.contentView?.addSubview(rec)
                XCTAssertTrue(win.makeFirstResponder(rec), "premise: the recorder has the keys")
                for code: UInt16 in [36, 76] {
                    let before = stops()
                    try confirmCardAsk(m)
                    win.sendEvent(confirmCardKey(.keyDown, code, win))
                    XCTAssertEqual(stops(), before + 1, "\(code): confirmed")
                    XCTAssertEqual(win.heldConfirmKey, code, "\(code): held")
                    try confirmCardAsk(m)
                    for _ in 0..<3 { win.sendEvent(confirmCardKey(.keyDown, code, win, repeating: true)) }
                    XCTAssertEqual(rec.downs, 0, "\(code): the repeats reached no responder")
                    XCTAssertEqual(stops(), before + 1, "\(code): the repeats answered nothing")
                    XCTAssertTrue(m.confirming != nil, "\(code): the new question stays")
                    win.sendEvent(confirmCardKey(.keyUp, code, win))
                    XCTAssertEqual(rec.ups, 1, "\(code): the keyUp reached the responder")
                    XCTAssertTrue(win.heldConfirmKey == nil, "\(code): released")
                    win.sendEvent(confirmCardKey(.keyDown, code, win))
                    XCTAssertEqual(stops(), before + 2, "\(code): a fresh Return after the keyUp confirms")
                    win.sendEvent(confirmCardKey(.keyUp, code, win))
                    win.sendEvent(confirmCardKey(.keyDown, code, win))
                    XCTAssertEqual(rec.downs, 1, "\(code): no question: Return passes")
                    win.sendEvent(confirmCardKey(.keyUp, code, win))
                    rec.downs = 0; rec.ups = 0
                }
                // a keyUp of the other key does not release; a resign key does
                try confirmCardAsk(m)
                win.sendEvent(confirmCardKey(.keyDown, 36, win))
                win.sendEvent(confirmCardKey(.keyUp, 76, win))
                XCTAssertEqual(win.heldConfirmKey, 36, "the other key's keyUp leaves the hold")
                win.resignKey()
                XCTAssertTrue(win.heldConfirmKey == nil, "resign key ended the hold")
                win.sendEvent(confirmCardKey(.keyDown, 36, win, repeating: true))
                XCTAssertEqual(rec.downs, 1, "after the hold ended a repeat passes")
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }

    /// #1937 i1: Return while the first responder has marked text (an IME composition) commits the composition: it
    /// passes on (the recorder gets it), the question stays, nothing is held; keypad Enter the same. Escape still
    /// cancels, and with no marked text Return confirms. Red at base: Return confirmed under the composition.
    @MainActor
    func testAgentWindowConfirmCardReturnWithMarkedTextPassesThrough() throws {
        try withModePref {
            try withPaneMenu(true) {
                let (m, _, _, stops) = try confirmCardModel()
                defer { m.close() }
                let (_, win, _) = confirmCardFrames(m)
                defer { win.close() }
                let rec = KeyRecorderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                win.contentView?.addSubview(rec)
                XCTAssertTrue(win.makeFirstResponder(rec), "premise: the recorder has the keys")
                try confirmCardAsk(m)
                rec.marked = true
                for code: UInt16 in [36, 76] {
                    win.sendEvent(confirmCardKey(.keyDown, code, win))
                    XCTAssertTrue(m.confirming != nil, "\(code): the question stays")
                    XCTAssertEqual(stops(), 0, "\(code): nothing stopped")
                }
                XCTAssertEqual(rec.downs, 2, "both reached the responder")
                XCTAssertTrue(win.heldConfirmKey == nil, "nothing held")
                rec.marked = false
                win.sendEvent(confirmCardKey(.keyDown, 36, win))
                XCTAssertTrue(m.confirming == nil, "no composition: Return confirms")
                XCTAssertEqual(stops(), 1, "confirmed once")
                XCTAssertEqual(rec.downs, 2, "and was not passed on")
                try confirmCardAsk(m)
                rec.marked = true
                win.sendEvent(confirmCardKey(.keyDown, 53, win, repeating: false))
                XCTAssertTrue(m.confirming == nil, "Escape still cancels")
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }
}
