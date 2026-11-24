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
            XCTAssertEqual(alone.map(\.title), ["New shell", "New session"], "one pane: no Close Pane")

            let two = paneLayout([nil, nil])
            let a = try XCTUnwrap(two.order.first), b = try XCTUnwrap(two.order.last)
            let m = sideOpenModel(two)
            defer { m.close() }
            m.select(nil)
            XCTAssertTrue(m.layout.panes.allSatisfy { $0.target == nil }, "both panes empty")
            XCTAssertEqual(m.layout.focused, a)
            let focused = try emptyPanePills(m, a)
            XCTAssertEqual(focused.map(\.title), ["Close Pane", "New shell", "New session"], "the focused empty pane")
            let other = try emptyPanePills(m, b)
            XCTAssertEqual(other.map(\.title), ["Close Pane", "New shell", "New session"], "the unfocused empty pane: the same pills (#1928)")
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

    /// #1920: New shell on the empty card, both sites (the focused pane's, with New session; the unfocused pane's, without):
    /// its press starts ⇧⌘N's login shell at once (no form) named shellName(folder) in the default folder through the spawn
    /// seam; the session lands in the PRESSED pane, in one pane and in two (the unfocused pane's card focuses it first); the
    /// gate off disables it with the sidebar's refusal. Old line that makes it red: no newShellPill at the call sites (no
    /// pill), `model.focusPane(pane)` missing (lands in the focused a, not b), `pane: model.layout.focused` at the
    /// unfocused site (same), enabled: true (the disabled row).
    @MainActor
    func testEmptyPaneNewShellPillStartsAShellIntoItsOwnPane() throws {
        try withPaneMenu(true) { try withNewSessionPrefs {
            Preferences.agentWindowNewSessionFolder = "/Users/example/last"
            @MainActor func pane(_ layout: PaneLayout, _ spawns: SpawnCalls, _ st: AgentIslandStore) -> AgentWindowModel {
                let m = newSessionModel(st, spawns, layouts: layoutSuite())
                m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
                m.adopt(layout)
                m.select(nil)
                return m
            }
            @MainActor func target(_ m: AgentWindowModel, _ id: UUID) -> PaneTarget? { m.layout.panes.first { $0.id == id }?.target }
            let key = AgentSessionKey(dir: "/tmp/dch-test", name: "last")
            // One pane.
            let st1 = store([]), s1 = SpawnCalls(), one = pane(paneLayout([nil]), s1, st1)
            defer { one.close() }
            let solo = try XCTUnwrap(try emptyPanePills(one, one.layout.focused).first { $0.title == "New shell" })
            XCTAssertEqual(solo.icon, "apple.terminal")
            XCTAssertTrue(solo.enabled)
            solo.action()
            XCTAssertTrue(one.newSession == nil, "no form")
            XCTAssertEqual(s1.calls.count, 1)
            XCTAssertEqual(s1.calls.last?.folder, "/Users/example/last")
            XCTAssertEqual(s1.calls.last?.argv, ["/bin/fish", "-l"])
            XCTAssertEqual(s1.calls.last?.name, "last")
            s1.done[0](key, nil)
            st1.sessions = [mapped("last")]
            XCTAssertEqual(target(one, one.layout.focused), paneTarget("last"), "the single pane took the shell")
            // Two panes, the unfocused b's card pressed: b is focused and takes the shell.
            let two = paneLayout([nil, nil])
            let a = try XCTUnwrap(two.order.first), b = try XCTUnwrap(two.order.last)
            let st2 = store([]), s2 = SpawnCalls(), m = pane(two, s2, st2)
            defer { m.close() }
            XCTAssertEqual(m.layout.focused, a)
            XCTAssertEqual(try emptyPanePills(m, a).map(\.title), ["Close Pane", "New shell", "New session"])
            XCTAssertEqual(try emptyPanePills(m, b).map(\.title), ["Close Pane", "New shell", "New session"])
            let other = try XCTUnwrap(try emptyPanePills(m, b).first { $0.title == "New shell" })
            other.action()
            XCTAssertEqual(m.layout.focused, b, "the press focused its own pane first")
            XCTAssertEqual(s2.calls.count, 1)
            s2.done[0](key, nil)
            st2.sessions = [mapped("last")]
            XCTAssertEqual(target(m, b), paneTarget("last"), "the unfocused pane's card: the shell landed in b")
            XCTAssertTrue(target(m, a) == nil, "a stays empty")
            // Gate off: disabled (the sidebar's refusal text).
            st2.controlDch = nil
            let off = try XCTUnwrap(try emptyPanePills(m, a).first { $0.title == "New shell" })
            XCTAssertFalse(off.enabled)
            XCTAssertNotNil(st2.resumeGate.refusal)
        } }
    }

    /// The (title, detail) of the AgentEmptyState card in a built view value (nil: none).
    func emptyCardText(_ v: Any, depth: Int = 0) -> (String, String)? {
        let m = Mirror(reflecting: v)
        if "\(type(of: v))".hasPrefix("AgentEmptyState<") {
            let f = Dictionary(m.children.compactMap { c in c.label.map { ($0, c.value) } }, uniquingKeysWith: { a, _ in a })
            if let t = f["title"] as? String, let d = f["detail"] as? String { return (t, d) }
        }
        guard depth < 80, m.displayStyle != .class else { return nil }
        return m.children.lazy.compactMap { self.emptyCardText($0.value, depth: depth + 1) }.first
    }

    @MainActor
    func emptyCardText(_ m: AgentWindowModel, _ id: UUID) throws -> (String, String)? {
        let view = AgentPaneArea(model: m, scrolls: false).pane(id, compact: m.layout.panes.count > 1)
        if let d = paneRiderFind(view, AgentDetailView.self) { return emptyCardText(d.body) }
        return emptyCardText(try XCTUnwrap(paneRiderFind(view, AgentUnfocusedPane.self), "a pane view: \(type(of: view))").body)
    }

    /// #1928: the empty pane card is one view: the focused and the unfocused pane show the same title and text (no
    /// keyboard instruction) and the same pills; New session pressed on the unfocused card focuses that pane first, so
    /// its form opens in it. Old line that makes it red: the two call sites' own texts (focused "Up and down move...",
    /// unfocused "Pick another session..."), no New session pill on the unfocused card, `model.focusPane(pane)` missing in
    /// the New session action (the focused stays a).
    @MainActor
    func testEmptyPaneCardIsTheSameFocusedOrNotAndNewSessionFocusesItsPane() throws {
        try withPaneMenu(true) { try withNewSessionPrefs {
            let two = paneLayout([nil, nil])
            let a = try XCTUnwrap(two.order.first), b = try XCTUnwrap(two.order.last)
            let m = newSessionModel(store([]), SpawnCalls(), layouts: layoutSuite())
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            m.adopt(two)
            m.select(nil)
            defer { m.close() }
            XCTAssertEqual(m.layout.focused, a)
            let focused = try XCTUnwrap(try emptyCardText(m, a), "the focused card"), other = try XCTUnwrap(try emptyCardText(m, b), "the unfocused card")
            XCTAssertEqual(focused.0, "Select a session")
            XCTAssertEqual(focused.1, "Pick a session from the list, or start one here.")
            XCTAssertTrue(focused == other, "the same title and text: \(focused) vs \(other)")
            XCTAssertEqual(try emptyPanePills(m, a).map(\.title), try emptyPanePills(m, b).map(\.title))
            XCTAssertTrue(m.newSession == nil)
            try XCTUnwrap(try emptyPanePills(m, b).first { $0.title == "New session" }).action()
            XCTAssertEqual(m.layout.focused, b, "the press focused its own pane first")
            XCTAssertTrue(m.newSession != nil, "the form is open, in b")
        } }
    }

    /// #1906: the Close Pane pills of the History card pane `id` draws (the card's own body; the buttons are not pills here).
    @MainActor
    func historyCardClosePills(_ m: AgentWindowModel, _ id: UUID) throws -> [AgentPillButton] {
        let view = AgentPaneArea(model: m, scrolls: false).pane(id, compact: m.layout.panes.count > 1)
        let root: Any = try paneRiderFind(view, AgentDetailView.self)?.body
            ?? (XCTUnwrap(paneRiderFind(view, AgentUnfocusedPane.self), "a pane view: \(type(of: view))")).body
        let card = try XCTUnwrap(paneRiderFind(root, AgentHistoryDetail.self), "a History card")
        return emptyPanePills(card.body).filter { $0.title == "Close Pane" }
    }

    /// #1906: a pane showing an ended session's History card has the Close Pane pill with more than one pane (the focused
    /// card with full actions, the unfocused card with a nil store), none with one pane; each closes ITS pane (captured at
    /// draw), never the focused one. Old line that makes it red: no `close:` at the call site (no pill) or
    /// `pane: model.layout.focused` at the unfocused one (closes a, not b).
    @MainActor
    func testHistoryCardClosePillOnlyWithSeveralPanesAndClosesItsOwnPane() throws {
        try withPaneMenu(true) {
            // Two records: the unfocused pane holds "older", the pick fills the focused empty pane with "old".
            @MainActor func model(_ layout: PaneLayout) -> AgentWindowModel {
                let m = windowModel(store([session("api", .idle)], history: [record("old"), record("older")]), layouts: layoutSuite())
                m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
                m.adopt(layout)
                m.setVisible(true)
                return m
            }
            let older = PaneTarget.history(dir: "/tmp/dch-test", id: "older", seen: nil)
            let single = model(paneLayout([nil]))
            defer { single.close() }
            single.select(.history(record("old").id))
            XCTAssertTrue(single.selectedRow?.record != nil, "the focused pane shows the History card")
            XCTAssertTrue(try historyCardClosePills(single, single.layout.focused).isEmpty, "one pane: no Close Pane")

            let two = paneLayout([nil, older])
            let a = try XCTUnwrap(two.order.first), b = try XCTUnwrap(two.order.last)
            let m = model(two)
            defer { m.close() }
            // The first show filled a with "api" (#828); a pick on a made layout with a filled focused pane parks it for the
            // single-pane view (#1538 lockedShowing). Emptied first, the pick goes into a (#1895: an empty focused pane takes it).
            m.select(nil)
            m.select(.history(record("old").id))
            XCTAssertEqual(m.layout.focused, a)
            XCTAssertTrue(m.selectedRow?.record != nil, "the focused pane a shows the History card")
            let focused = try historyCardClosePills(m, a)
            XCTAssertEqual(focused.count, 1, "the focused History card")
            let other = try historyCardClosePills(m, b)
            XCTAssertEqual(other.count, 1, "the unfocused History card")
            m.focusPane(b)
            for l in m.layouts?.layouts ?? [] where l.id != m.layout.id { m.deleteLayout(l.id) }
            try XCTUnwrap(focused.first).action()
            XCTAssertEqual(m.layout.order, [b], "the focused card's pill closed its own pane (a), not the focused one (b)")

            let m2 = model(two)
            defer { m2.close() }
            m2.select(nil)
            m2.select(.history(record("old").id))
            let pill = try XCTUnwrap(try historyCardClosePills(m2, b).first)
            XCTAssertEqual(m2.layout.focused, a)
            for l in m2.layouts?.layouts ?? [] where l.id != m2.layout.id { m2.deleteLayout(l.id) }
            pill.action()
            XCTAssertEqual(m2.layout.order, [a], "the unfocused card's pill closed b, not the focused a")
        }
    }
}
