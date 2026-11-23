import AppKit
import XCTest
@testable import ProsperApp

/// #1658: an empty pane (no session yet) closes: ⌘W closes the focused pane whatever it shows (the New session form
/// included: the form goes with it, nothing starts), and the empty pane has the placeholder's Close Pane pill with more
/// than one pane. Offscreen only: events are built with NSEvent.keyEvent and handed to a never-shown window's
/// performKeyEquivalent (nothing posted, no window ordered in or made key); a window close is recorded and refused by
/// its delegate; the pills are read from the built view values and their actions called (no host, no click).
extension AgentWindowD1Tests {
    /// Every AgentPillButton in a built view value, depth first (classes are not walked).
    func emptyPanePills(_ v: Any, depth: Int = 0) -> [AgentPillButton] {
        if let p = v as? AgentPillButton { return [p] }
        let m = Mirror(reflecting: v)
        guard depth < 80, m.displayStyle != .class else { return [] }
        return m.children.flatMap { emptyPanePills($0.value, depth: depth + 1) }
    }

    /// The pills pane `id` builds: the focused pane's AgentDetailView body, else the unfocused pane's.
    @MainActor
    func emptyPanePills(_ m: AgentWindowModel, _ id: UUID) throws -> [AgentPillButton] {
        let view = AgentPaneArea(model: m, scrolls: false).pane(id, compact: m.layout.panes.count > 1)
        if let d = paneRiderFind(view, AgentDetailView.self) { return emptyPanePills(d.body) }
        return emptyPanePills(try XCTUnwrap(paneRiderFind(view, AgentUnfocusedPane.self), "a pane view: \(type(of: view))").body)
    }

    /// ⌘W with two panes closes the focused EMPTY pane (the sidebar holding the keys), never the window.
    @MainActor
    func testEmptyPaneCloseCommandWClosesTheFocusedEmptyPane() throws {
        try withTreeGate(true) {
            let (win, m, rec) = treeWindow()
            defer { win.close(); m.close() }
            let first = m.layout.focused
            XCTAssertTrue(press(win, "⌘D"))
            let empty = m.layout.focused
            XCTAssertTrue(m.layout.panes.first { $0.id == empty }?.target == nil, "the new pane is empty")
            m.keyFocus = .sidebar
            XCTAssertTrue(press(win, "⌘W"))
            XCTAssertEqual(rec.asks, 0, "never the window")
            XCTAssertEqual(m.layout.order, [first], "the empty pane closed")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// ⌘W with two panes and the New session form open in the focused pane: the pane closes, the form is gone, nothing
    /// starts (the spawn seam fails the row), the window is never asked to close. ⌘D under the form keeps today's route.
    @MainActor
    func testEmptyPaneCloseCommandWUnderTheFormClosesThePaneAndStartsNothing() throws {
        try withTreeGate(true) {
            try withNewSessionPrefs {
                Preferences.agentIslandNewSessionCommand = "claude"   // typed: the island is asked nothing
                let (win, m, rec) = treeWindow()
                defer { win.close(); m.close() }
                m.store?.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])   // a value, never run
                m.home = "/Users/example"
                m.spawnSession = { _, _, _, _ in XCTFail("no spawn"); return nil }
                let first = m.layout.focused
                XCTAssertTrue(press(win, "⌘D"))
                m.openNewSession()
                XCTAssertTrue(m.newSession != nil, "the form is open in the new pane")
                let two = m.layout
                _ = press(win, "⌘D")
                XCTAssertTrue(m.layout == two, "⌘D under the form: no split, as today")
                XCTAssertTrue(press(win, "⌘W"))
                XCTAssertEqual(rec.asks, 0, "never the window")
                XCTAssertEqual(m.layout.order, [first], "the form's pane closed")
                XCTAssertTrue(m.newSession == nil, "the form went with its pane")
            }
        }
    }

    /// #1659: the rule lives in the model and follows the pane the form is DRAWN in (the focused one): perform(.closePane,
    /// pane:) and closePane(_:) of it cancel the form and start nothing; a close of another pane leaves it; the form
    /// opened in A and moved by focus to B goes when B closes.
    @MainActor
    func testClosePaneCancelsTheFormOnlyWhenItsShownPaneCloses() throws {
        try withTreeGate(true) {
            try withNewSessionPrefs {
                Preferences.agentIslandNewSessionCommand = "claude"
                let (win, m, _) = treeWindow()
                defer { win.close(); m.close() }
                m.store?.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
                m.home = "/Users/example"
                m.spawnSession = { _, _, _, _ in XCTFail("no spawn"); return nil }
                // ⌘D then ⇧⌘D: a 1000x600 area holds 500 | 500/2x300; a second ⌘D (250 wide) is refused for room, and a
                // refused split still answers true (the refusal goes to the notice line), so every split checks its count.
                let a = m.layout.focused
                XCTAssertTrue(press(win, "⌘D"))
                XCTAssertEqual(m.layout.panes.count, 2, "⌘D split a")
                let b = m.layout.focused
                XCTAssertTrue(press(win, "⇧⌘D"))
                XCTAssertEqual(m.layout.panes.count, 3, "⇧⌘D split b")
                let c = m.layout.focused
                m.openNewSession()
                XCTAssertTrue(m.newSession != nil, "the form is open in the focused pane c")
                // (b) another, unfocused pane closes: the form stays
                m.closePane(a)
                XCTAssertEqual(m.layout.panes.count, 2)
                XCTAssertTrue(m.newSession != nil, "closePane of an unfocused pane leaves the form")
                XCTAssertTrue(m.perform(.closePane, pane: b))
                XCTAssertEqual(m.layout.order, [c])
                XCTAssertTrue(m.newSession != nil, "perform on an unfocused pane leaves the form")
                // (a) the focused pane closes through perform (⌘D under the form is not a split, #1658: cancel it first)
                m.cancelNewSession()
                XCTAssertTrue(press(win, "⌘D"))
                XCTAssertEqual(m.layout.panes.count, 2, "⌘D split c")
                let d = m.layout.focused
                m.openNewSession()
                XCTAssertTrue(m.newSession != nil, "the form is open in d")
                XCTAssertTrue(m.perform(.closePane, pane: d))
                XCTAssertEqual(m.layout.order, [c])
                XCTAssertTrue(m.newSession == nil, "perform(.closePane, pane: focused): the form went")
                // (a) through closePane
                XCTAssertTrue(press(win, "⌘D"))
                XCTAssertEqual(m.layout.panes.count, 2, "⌘D split c again")
                let e = m.layout.focused
                m.openNewSession()
                XCTAssertTrue(m.newSession != nil, "the form is open in e")
                m.closePane(e)
                XCTAssertEqual(m.layout.order, [c])
                XCTAssertTrue(m.newSession == nil, "closePane(focused): the form went")
                // (c) opened with c focused, focus moves to f: the form is drawn in f and goes with it
                XCTAssertTrue(press(win, "⌘D"))
                XCTAssertEqual(m.layout.panes.count, 2, "⌘D split c for f")
                let f = m.layout.focused
                m.focusPane(c)
                m.openNewSession()
                XCTAssertTrue(m.newSession != nil, "the form is open, c focused")
                m.focusPane(f)
                XCTAssertEqual(m.layout.focused, f)
                m.closePane(f)
                XCTAssertEqual(m.layout.order, [c])
                XCTAssertTrue(m.newSession == nil, "the form follows focus: closing the pane it is drawn in cancels it")
            }
        }
    }

    /// One pane, the form open: ⌘W routes as before (the window's close, refused here), the layout and form untouched.
    @MainActor
    func testEmptyPaneCloseCommandWWithOnePaneRoutesAsBefore() throws {
        try withTreeGate(true) {
            try withNewSessionPrefs {
                Preferences.agentIslandNewSessionCommand = "claude"
                let (win, m, rec) = treeWindow()
                defer { win.close(); m.close() }
                m.store?.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
                m.home = "/Users/example"
                m.spawnSession = { _, _, _, _ in XCTFail("no spawn"); return nil }
                let one = m.layout
                XCTAssertTrue(press(win, "⌘W"))
                XCTAssertEqual(rec.asks, 1, "one pane, no form: the window's close")
                m.openNewSession()
                XCTAssertTrue(m.newSession != nil)
                XCTAssertTrue(press(win, "⌘W"))
                XCTAssertEqual(rec.asks, 2, "one pane, the form: the window's close, as before")
                XCTAssertTrue(m.layout == one)
                XCTAssertTrue(m.newSession != nil, "the form stays (the window did not close)")
            }
        }
    }

    /// The empty pane's Close Pane pill: none with one pane (New session still there); with two, on the focused and the
    /// unfocused empty pane alike, and each closes ITS pane even after the focus moved (never the focused one).
    @MainActor
    func testEmptyPaneClosePillOnlyWithSeveralPanesAndClosesItsOwnPane() throws {
        try withPaneMenu(true) {
            // The first show fills the focused empty pane with the first row (#828): emptied again, as a person can.
            let single = sideOpenModel(paneLayout([nil]))
            defer { single.close() }
            single.select(nil)
            XCTAssertTrue(single.layout.panes.allSatisfy { $0.target == nil }, "the pane is empty")
            let alone = try emptyPanePills(single, single.layout.focused)
            XCTAssertEqual(alone.map(\.title), ["New session"], "one pane: no Close Pane")

            let two = paneLayout([nil, nil])
            let a = try XCTUnwrap(two.order.first), b = try XCTUnwrap(two.order.last)
            let m = sideOpenModel(two)
            defer { m.close() }
            m.select(nil)
            XCTAssertTrue(m.layout.panes.allSatisfy { $0.target == nil }, "both panes empty")
            XCTAssertEqual(m.layout.focused, a)
            let focused = try emptyPanePills(m, a)
            XCTAssertEqual(focused.map(\.title), ["Close Pane", "New session"], "the focused empty pane")
            let other = try emptyPanePills(m, b)
            XCTAssertEqual(other.map(\.title), ["Close Pane"], "the unfocused empty pane")
            m.focusPane(b)
            XCTAssertEqual(m.layout.focused, b)
            for l in m.layouts?.layouts ?? [] where l.id != m.layout.id { m.deleteLayout(l.id) }   // #1894: the lone layout, so the close to one pane keeps it
            try XCTUnwrap(focused.first { $0.title == "Close Pane" }).action()
            XCTAssertEqual(m.layout.order, [b], "the pill closed its own pane (a), not the focused one (b)")

            let m2 = sideOpenModel(two)
            defer { m2.close() }
            m2.select(nil)
            XCTAssertTrue(m2.layout.panes.allSatisfy { $0.target == nil }, "both panes empty")
            let pill = try XCTUnwrap(try emptyPanePills(m2, b).first { $0.title == "Close Pane" })
            XCTAssertEqual(m2.layout.focused, a)
            for l in m2.layouts?.layouts ?? [] where l.id != m2.layout.id { m2.deleteLayout(l.id) }   // #1894: the lone layout, so the close to one pane keeps it
            pill.action()
            XCTAssertEqual(m2.layout.order, [a], "the unfocused pane's pill closed b, not the focused a")
        }
    }
}
