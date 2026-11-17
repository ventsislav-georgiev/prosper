import AppKit
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 6b2a): six riders of the pane menu, the sidebar row click and the divider nudge, each gate-on only
/// with a gate-off row that shows today's behaviour. Events are BUILT (NSEvent.mouseEvent / NSEvent.keyEvent) and handed
/// to the function under test as values: never posted, never sent. Menus are entry lists, never popped up; the header
/// values are a view's `body` built as a value (no window, no host); no session verb runs. Sessions are fakes; layouts
/// save to a private XCTestDefaults suite; the split gate and the UI scale are saved, set and restored in a defer
/// (withPaneMenu). Every row runs on the main actor.
extension AgentWindowD1Tests {
    @MainActor
    func paneRiderMouse(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor
    func paneRiderKey(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                       keyCode: code))
    }

    /// The first value of type `T` among `v`'s stored properties, depth first; never into a class instance (the model,
    /// the store), so the walk stays inside the view values.
    func paneRiderFind<T>(_ v: Any, _ t: T.Type, depth: Int = 0) -> T? {
        if let x = v as? T { return x }
        let m = Mirror(reflecting: v)
        guard depth < 80, m.displayStyle != .class else { return nil }
        for c in m.children { if let x = paneRiderFind(c.value, t, depth: depth + 1) { return x } }
        return nil
    }

    /// Item 1 (R900-6b1-a): the flags come only from a left mouse down or up; a flagsChanged, a key down (Space, Full
    /// Keyboard Access), a right mouse up and nil give none.
    @MainActor
    func testPaneRiderClickFlagsOnlyFromAMouseEvent() throws {
        let up = try paneRiderMouse(.leftMouseUp, .option), down = try paneRiderMouse(.leftMouseDown, .option)
        XCTAssertEqual(AgentWindowModel.clickFlags(up).intersection(.deviceIndependentFlagsMask), .option)
        XCTAssertEqual(AgentWindowModel.clickFlags(down).intersection(.deviceIndependentFlagsMask), .option)
        XCTAssertEqual(AgentWindowModel.clickFlags(try paneRiderKey(.flagsChanged, 58, "", .option)), [])
        XCTAssertEqual(AgentWindowModel.clickFlags(try paneRiderKey(.keyDown, 49, " ", .option)), [])
        XCTAssertEqual(AgentWindowModel.clickFlags(try paneRiderMouse(.rightMouseUp, .option)), [])
        XCTAssertEqual(AgentWindowModel.clickFlags(nil), [])
    }

    /// Item 1 through click, gate on: a key event's Option is the plain click; a mouse up's Option opens to the side.
    @MainActor
    func testPaneRiderGateOnKeyEventFlagsNeverOpenToTheSide() throws {
        try withPaneMenu(true) {
            let l = paneLayout([paneTarget("api")])
            let plain = sideOpenModel(l), key = sideOpenModel(l), changed = sideOpenModel(l), mouse = sideOpenModel(l)
            defer { plain.close(); key.close(); changed.close(); mouse.close() }
            let space = try paneRiderKey(.keyDown, 49, " ", .option), option = try paneRiderKey(.flagsChanged, 58, "", .option)
            let up = try paneRiderMouse(.leftMouseUp, .option)
            plain.click(live("web"))
            key.click(live("web"), flags: AgentWindowModel.clickFlags(space))
            changed.click(live("web"), flags: AgentWindowModel.clickFlags(option))
            mouse.click(live("web"), flags: AgentWindowModel.clickFlags(up))
            XCTAssertEqual(sideOpenState(key), sideOpenState(plain), "Space with Option: the plain click")
            XCTAssertEqual(sideOpenState(changed), sideOpenState(plain), "a stale flagsChanged: the plain click")
            XCTAssertEqual(plain.layout.panes.count, 1)
            XCTAssertEqual(mouse.layout.panes.count, 2, "an Option mouse up opens to the side")
        }
    }

    /// Item 1, gate off: the Button's value is never even read; a click with an Option mouse up is the plain click.
    @MainActor
    func testPaneRiderGateOffClickFlagsUnreadPlainClick() throws {
        try withPaneMenu(false) {
            let l = paneLayout([paneTarget("api")])
            let plain = sideOpenModel(l), option = sideOpenModel(l)
            defer { plain.close(); option.close() }
            let up = try paneRiderMouse(.leftMouseUp, .option)
            var read = false
            @MainActor func flags() -> NSEvent.ModifierFlags { read = true; return AgentWindowModel.clickFlags(up) }
            plain.click(live("web"))
            option.click(live("web"), flags: flags())
            XCTAssertFalse(read, "the gate off never reads the flags")
            XCTAssertEqual(sideOpenState(option), sideOpenState(plain))
            XCTAssertEqual(option.layout.panes.count, 1)
        }
    }

    /// Item 2 (R900-6b1-5): every verb of an UNFOCUSED pane's menu focuses that pane in one write, refused or not; a
    /// refused verb on the focused pane writes nothing.
    @MainActor
    func testPaneRiderRefusedVerbFocusesItsPaneOnce() throws {
        try withPaneMenu(true) {
            let t = paneMenuThree()
            let names = [t.api: "api", t.web: "web", t.db: "db"]
            // web is 300x240 in 1000x600: both splits have no room.
            for axis in [PaneNode.Axis.columns, .rows] {
                let m = paneMenuModel(t.l, area: CGSize(width: 1000, height: 600))
                defer { m.close() }
                let writes = m.layoutWrites
                AgentWindowControls.runPane(.action(.split(axis)), pane: t.web, in: m)
                XCTAssertEqual(paneMenuShape(m.layout, names), "columns(0.7, api, rows(0.4, web, db)) focused web zoomed none",
                               "\(axis)")
                XCTAssertEqual(m.layoutWrites, writes + 1, "\(axis): refused, the focus alone, one write")
                XCTAssertEqual(m.paneRefusal, .noRoom)
            }
            // Close Pane and Zoom are never refused on an unfocused pane (two or more panes): one write each.
            let never: [(AgentPaneVerb, String)] = [(.action(.closePane), "columns(0.7, api, web) focused web zoomed none"),
                                                    (.action(.zoom), "columns(0.7, api, rows(0.4, web, db)) focused db zoomed db")]
            for (verb, shape) in never {
                let m = paneMenuModel(t.l)
                defer { m.close() }
                let writes = m.layoutWrites
                AgentWindowControls.runPane(verb, pane: t.db, in: m)
                XCTAssertEqual(paneMenuShape(m.layout, names), shape)
                XCTAssertEqual(m.layoutWrites, writes + 1)
            }
            // Equalize is refused only on a leaf root: a one-pane layout whose focus names no pane of it.
            let lone = Pane(id: UUID(), target: paneTarget("api"))
            let stale = PaneLayout(id: UUID(), name: nil, tree: .leaf(lone), focused: UUID(), zoomed: nil)
            let m = paneMenuModel(stale)
            defer { m.close() }
            let writes = m.layoutWrites
            AgentWindowControls.runPane(.equalize, pane: lone.id, in: m)
            XCTAssertEqual(m.layout.focused, lone.id, "a refused Equalize focuses its pane")
            XCTAssertEqual(m.layoutWrites, writes + 1, "one write")
            XCTAssertTrue(m.layout.tree == stale.tree)
            // Nothing differs: a refused split and a refused Equalize on the focused pane write nothing.
            let one = paneLayout([paneTarget("api")])
            let f = paneMenuModel(one, area: CGSize(width: 500, height: 350))
            defer { f.close() }
            let w0 = f.layoutWrites
            AgentWindowControls.runPane(.action(.split(.columns)), pane: one.focused, in: f)
            AgentWindowControls.runPane(.equalize, pane: one.focused, in: f)
            XCTAssertEqual(f.paneRefusal, .noRoom)
            XCTAssertTrue(f.layout == one)
            XCTAssertEqual(f.layoutWrites, w0, "nothing differs: no write")
        }
    }

    /// Item 2, gate off: no pane offers a pane verb, so nothing reaches runPane; the header's list is today's.
    @MainActor
    func testPaneRiderGateOffNoPaneVerbToRun() throws {
        try withPaneMenu(false) {
            let t = paneMenuThree()
            let m = paneMenuModel(t.l)
            defer { m.close() }
            for id in m.layout.order { XCTAssertEqual(AgentWindowControls.paneMenu(m, pane: id), [], "no pane item") }
            XCTAssertTrue(m.layout == t.l)
        }
    }

    /// Item 3 (R900-6a-2), gate on: an ended session's "⋯" opens when it holds pane items; Open in terminal stays off,
    /// the pane items keep their own state; with no pane items (or not ended) today's rule.
    @MainActor
    func testPaneRiderGateOnEndedMenuOpensForPaneItems() throws {
        try withPaneMenu(true) {
            let t = paneMenuThree()
            let m = paneMenuModel(t.l)
            defer { m.close() }
            let panes = AgentWindowControls.paneMenu(m, pane: t.web)
            XCTAssertFalse(AgentSessionMenuButton.disabled(ended: true, entries: panes), "pane items: on")
            XCTAssertTrue(AgentSessionMenuButton.disabled(ended: true, entries: []), "no pane items: off as today")
            XCTAssertTrue(AgentSessionMenuButton.disabled(ended: true, entries: [.open(enabled: false)]))
            XCTAssertFalse(AgentSessionMenuButton.disabled(ended: false, entries: panes))
            XCTAssertFalse(AgentSessionMenuButton.disabled(ended: false, entries: []))
            let a = session("api", .idle)
            let button = AgentSessionMenuButton(store: nil, session: a, ask: { _ in }, open: {}, ended: true, panes: panes)
            XCTAssertEqual(button.entries, [.open(enabled: false)] + panes, "Open in terminal off; pane items as built")
            XCTAssertEqual(paneMenuItems(button.entries), ["Split Right", "Split Down", "Zoom", "Equalize",
                                                           AgentWindowControls.closePaneLabel])
        }
    }

    /// Item 3, gate off: disabled(ended) exactly, whatever list it is given.
    @MainActor
    func testPaneRiderGateOffEndedMenuDisabledAsToday() throws {
        try withPaneMenu(false) {
            let items: [AgentWindowMenuEntry] = [.divider, .pane("Split Right", enabled: true, verb: .action(.split(.columns)))]
            for ended in [false, true] {
                XCTAssertEqual(AgentSessionMenuButton.disabled(ended: ended, entries: []), ended)
                XCTAssertEqual(AgentSessionMenuButton.disabled(ended: ended, entries: items), ended, "the gate read off")
                XCTAssertEqual(AgentSessionMenuButton.disabled(ended: ended, entries: items, splits: false), ended)
            }
            let m = paneMenuModel(paneMenuThree().l)
            defer { m.close() }
            XCTAssertTrue(AgentSessionMenuButton.disabled(ended: true, entries: AgentWindowControls.paneMenu(m, pane: m.layout.focused)))
        }
    }

    /// Item 4 (R900-6a-3), gate on: the help names the pane items after today's sentence (an ended session's too).
    @MainActor
    func testPaneRiderGateOnHelpNamesThePaneItems() throws {
        try withPaneMenu(true) {
            let a = session("api", .idle), dash = session("-x", .idle)
            let one = paneMenuModel(paneLayout([paneTarget("api")])), three = paneMenuModel(paneMenuThree().l)
            defer { one.close(); three.close() }
            let split = AgentWindowControls.paneMenu(one, pane: one.layout.focused)
            let all = AgentWindowControls.paneMenu(three, pane: three.layout.focused)
            XCTAssertEqual(AgentSessionMenuButton.help(a, ended: false, panes: split),
                           "Open in terminal, rename, restart, stop or end this session; split this pane")
            XCTAssertEqual(AgentSessionMenuButton.help(a, ended: false, panes: all),
                           "Open in terminal, rename, restart, stop or end this session; split, zoom, equalize or close this pane")
            XCTAssertEqual(AgentSessionMenuButton.help(dash, ended: false, panes: all),
                           "Open in terminal or rename this session; split, zoom, equalize or close this pane")
            XCTAssertEqual(AgentSessionMenuButton(store: nil, session: a, ask: { _ in }, ended: true, panes: all).help,
                           "This session ended: there is no terminal to attach to; split, zoom, equalize or close this pane")
            XCTAssertEqual(AgentSessionMenuButton.help(a, ended: false, panes: []),
                           "Open in terminal, rename, restart, stop or end this session")
        }
    }

    /// Item 4, gate off: today's three texts exactly, whatever list is given.
    @MainActor
    func testPaneRiderGateOffHelpIsTodaysThreeTexts() throws {
        try withPaneMenu(false) {
            let a = session("api", .idle), dash = session("-x", .idle)
            let items: [AgentWindowMenuEntry] = [.divider, .pane("Split Right", enabled: true, verb: .action(.split(.columns))),
                                                 .pane("Equalize", enabled: true, verb: .equalize)]
            for panes in [[], items] {
                XCTAssertEqual(AgentSessionMenuButton.help(a, ended: false, panes: panes),
                               "Open in terminal, rename, restart, stop or end this session")
                XCTAssertEqual(AgentSessionMenuButton.help(dash, ended: false, panes: panes), "Open in terminal or rename this session")
                XCTAssertEqual(AgentSessionMenuButton.help(a, ended: true, panes: panes),
                               "This session ended: there is no terminal to attach to")
                XCTAssertEqual(AgentSessionMenuButton(store: nil, session: a, ask: { _ in }, ended: true, panes: panes).help,
                               "This session ended: there is no terminal to attach to")
            }
        }
    }

    /// Item 5 (R900-6a-4), gate on: the header each pane view BUILDS (AgentPaneArea.pane's view, its body read as a
    /// value: no window, no host) carries that pane's id: its Close Pane closes THAT pane and not the other.
    @MainActor
    func testPaneRiderEachHeaderCarriesItsOwnPane() throws {
        try withPaneMenu(true) {
            let two = paneLayout([paneTarget("api"), paneTarget("web")])
            for (i, id) in two.order.enumerated() {
                let m = sideOpenModel(two)
                defer { m.close() }
                XCTAssertTrue(m.layout == two)
                let view = AgentPaneArea(model: m, scrolls: false).pane(id, compact: true)
                let body: Any = try { () throws -> Any in
                    if let d = paneRiderFind(view, AgentDetailView.self) { return d.body }
                    return try XCTUnwrap(paneRiderFind(view, AgentUnfocusedPane.self), "pane \(i): a pane view").body
                }()
                let button = try XCTUnwrap(paneRiderFind(body, AgentSessionMenuButton.self), "pane \(i): a header \"⋯\"")
                button.pane(try paneMenuVerb(button.panes, AgentWindowControls.closePaneLabel))
                XCTAssertFalse(m.layout.order.contains(id), "pane \(i): its own pane closed")
                XCTAssertEqual(m.layout.order, two.order.filter { $0 != id }, "pane \(i): the other pane kept")
            }
        }
    }

    /// Item 5, gate off: the same built headers carry no pane item (the "⋯" is today's).
    @MainActor
    func testPaneRiderGateOffBuiltHeaderHasNoPaneItem() throws {
        try withPaneMenu(false) {
            let m = sideOpenModel(paneLayout([paneTarget("api")]))
            defer { m.close() }
            let view = AgentPaneArea(model: m, scrolls: false).pane(m.layout.focused, compact: false)
            let detail = try XCTUnwrap(paneRiderFind(view, AgentDetailView.self))
            // One pane: the full header, whose "⋯" is built in its own body (menuButton).
            let header = try XCTUnwrap(paneRiderFind(detail.body, AgentSessionHeader.self))
            // #1471: no Jump to Chapter item (the transcript is gone) and no pane split item with the gate off.
            XCTAssertEqual(header.menuButton.panes, [.divider])
            XCTAssertEqual(header.menuButton.help, "Open in terminal, rename, restart, stop or end this session")
        }
    }

    /// Item 6 (R900-5b-q1), gate on: a divider captured before a tree change and nudged after it writes nothing (another
    /// split is at its path now); the same path with the identity drawn now writes once.
    @MainActor
    func testPaneRiderNudgeComparesTheSplitIdentity() throws {
        try withPaneMenu(true) {
            let t = paneMenuThree()
            let size = CGSize(width: 3000, height: 1000)
            let m = paneMenuModel(t.l, area: size)
            defer { m.close() }
            let old = try XCTUnwrap(m.dividers(in: size).first { $0.path == [] })
            XCTAssertEqual(old.sides, [[t.api], [t.web, t.db]])
            m.adopt(try m.layout.close(t.api).get())   // the root is now web over db
            let after = m.layout, writes = m.layoutWrites
            m.nudge(old.path, up: true, in: size, sides: old.sides)
            XCTAssertTrue(m.layout == after, "another split at that path: nothing")
            XCTAssertEqual(m.layoutWrites, writes)
            let now = try XCTUnwrap(m.dividers(in: size).first { $0.path == [] })
            XCTAssertEqual(now.sides, [[t.web], [t.db]])
            m.nudge(now.path, up: true, in: size, sides: now.sides)
            XCTAssertEqual(m.layoutWrites, writes + 1, "its own split: one write")
            XCTAssertEqual(m.dividerPercent([]), 45)
        }
    }

    /// Item 6, gate off: no divider, so a nudge with or without an identity writes nothing.
    @MainActor
    func testPaneRiderGateOffNudgeWritesNothing() throws {
        try withPaneMenu(false) {
            let t = paneMenuThree()
            let size = CGSize(width: 3000, height: 1000)
            let m = paneMenuModel(t.l, area: size)
            defer { m.close() }
            let writes = m.layoutWrites
            XCTAssertEqual(m.dividers(in: size), [])
            m.nudge([], up: true, in: size)
            m.nudge([], up: true, in: size, sides: [[t.api], [t.web, t.db]])
            XCTAssertTrue(m.layout == t.l)
            XCTAssertEqual(m.layoutWrites, writes)
        }
    }
}
