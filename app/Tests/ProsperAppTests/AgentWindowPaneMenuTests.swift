import AppKit
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 6a; spec 3.3, 7.3, 7.4, 7.5, 15.0): the pane items of the header "⋯". Menus are BUILT as entry
/// lists and never popped up, tracked or performed; a choice is the run function called directly. No window, no event,
/// no session verb run (the session entries are compared as values only). Sessions are fakes; layouts save to a private
/// XCTestDefaults suite; the split gate and the UI scale are saved, set and restored in a defer by every row.
extension AgentWindowD1Tests {
    @MainActor
    func withPaneMenu(_ gate: Bool, _ body: () throws -> Void) rethrows {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(gate, body)
    }

    /// A model on a private layout suite with sessions "api", "web", "db", the pane area `area` and `layout` adopted.
    @MainActor
    func paneMenuModel(_ layout: PaneLayout, area: CGSize = CGSize(width: 3000, height: 1000)) -> AgentWindowModel {
        let m = windowModel(store([session("api", .idle), session("web", .idle), session("db", .idle)]), layouts: layoutSuite())
        m.paneArea = CGRect(origin: .zero, size: area)
        m.adopt(layout)
        return m
    }

    /// Three panes, api | (web over db), with uneven ratios (0.7 and 0.4), api focused.
    func paneMenuThree() -> (l: PaneLayout, api: UUID, web: UUID, db: UUID) {
        let a = Pane(id: UUID(), target: paneTarget("api")), w = Pane(id: UUID(), target: paneTarget("web")),
            d = Pane(id: UUID(), target: paneTarget("db"))
        let tree = PaneNode.split(.columns, ratio: 0.7, .leaf(a), .split(.rows, ratio: 0.4, .leaf(w), .leaf(d)))
        return (PaneLayout(id: UUID(), name: nil, tree: tree, focused: a.id, zoomed: nil), a.id, w.id, d.id)
    }

    /// The tree as text with the known ids named and any other (a pane a split made) "new", plus focus and zoom: two
    /// splits on twin models compare as values though each new pane has its own UUID.
    func paneMenuShape(_ l: PaneLayout, _ names: [UUID: String]) -> String {
        func node(_ n: PaneNode) -> String {
            switch n {
            case let .leaf(p): names[p.id] ?? "new"
            case let .split(axis, ratio, a, b): "\(axis.rawValue)(\(ratio), \(node(a)), \(node(b)))"
            }
        }
        return "\(node(l.tree)) focused \(names[l.focused] ?? "new") zoomed \(l.zoomed.map { names[$0] ?? "new" } ?? "none")"
    }

    /// The (title, enabled) of each pane item, in order.
    func paneMenuItems(_ e: [AgentWindowMenuEntry]) -> [String] {
        e.compactMap { (x: AgentWindowMenuEntry) -> String? in
            guard case let .pane(t, on, _) = x else { return nil }
            return on ? t : t + " [off]"
        }
    }

    /// The verb of the pane item titled `title` (the menu's own mapping).
    func paneMenuVerb(_ e: [AgentWindowMenuEntry], _ title: String) throws -> AgentPaneVerb {
        try XCTUnwrap(e.lazy.compactMap { (x: AgentWindowMenuEntry) -> AgentPaneVerb? in
            guard case let .pane(t, _, v) = x, t == title else { return nil }
            return v
        }.first, title)
    }

    /// 15.0: gate off, no pane entry whatever the layout holds (one pane, a restored two-pane layout, a zoomed one), and
    /// the header's whole "⋯" list equals today's sessionMenu, as values; the button's help is today's.
    @MainActor
    func testPaneMenuGateOffAddsNothing() throws {
        try withPaneMenu(false) {
            let t = paneMenuThree()
            let two = try t.l.close(t.db).get()
            for (why, l) in [("one pane", paneLayout([paneTarget("api")])), ("two panes", two), ("zoomed", two.toggleZoom())] {
                let m = paneMenuModel(l)
                defer { m.close() }
                XCTAssertEqual(m.layout, l, why)
                XCTAssertEqual(AgentWindowControls.paneMenu(m, pane: m.layout.focused), [], why)
                for id in m.layout.order { XCTAssertEqual(AgentWindowControls.paneMenu(m, pane: id), [], why) }
                let a = session("api", .idle), st = store([a])
                st.controlDch = bin([1, 38, 0])
                let button = AgentSessionMenuButton(store: st, session: a, ask: { _ in }, open: {},
                                                    panes: AgentWindowControls.paneMenu(m, pane: m.layout.focused))
                XCTAssertEqual(button.entries, AgentWindowControls.sessionMenu(a, store: st, ended: false), why)
                XCTAssertEqual(button.help, "Open in terminal, rename, restart, stop or end this session", why)
            }
            // The pure builder: the gate first, whatever else it is given.
            XCTAssertEqual(AgentWindowControls.paneMenu(splits: false, panes: 6, right: .cap, down: nil), [])
            XCTAssertEqual(AgentWindowControls.paneMenu(splits: false, panes: 1, right: nil, down: nil), [])
        }
    }

    /// 7.3 / 15.0: gate on, one pane: exactly Split Right and Split Down, on, after one divider behind the session's.
    @MainActor
    func testPaneMenuGateOnOnePaneSplitsOnly() throws {
        try withPaneMenu(true) {
            let m = paneMenuModel(paneLayout([paneTarget("api")]))
            defer { m.close() }
            let e = AgentWindowControls.paneMenu(m, pane: m.layout.focused)
            XCTAssertEqual(e, [.divider, .pane("Split Right", enabled: true, verb: .action(.split(.columns))),
                               .pane("Split Down", enabled: true, verb: .action(.split(.rows)))])
            let a = session("api", .idle), st = store([a])
            st.controlDch = bin([1, 38, 0])
            let button = AgentSessionMenuButton(store: st, session: a, ask: { _ in }, open: {}, panes: e)
            XCTAssertEqual(button.entries, AgentWindowControls.sessionMenu(a, store: st, ended: false) + e)
        }
    }

    /// 7.3 / 7.4: gate on, more than one pane: the five items in order; zoomed, the zoom item still reads "Zoom" (the
    /// spec names no "Unzoom"); too small (one pane drawn, two in the layout): the five still, as the keys count.
    @MainActor
    func testPaneMenuGateOnTwoPanesFiveItems() throws {
        try withPaneMenu(true) {
            let five = ["Split Right", "Split Down", "Zoom", "Equalize", "Close Pane (the session keeps running)"]
            let m = paneMenuModel(paneLayout([paneTarget("api"), paneTarget("web")]))
            defer { m.close() }
            let e = AgentWindowControls.paneMenu(m, pane: m.layout.focused)
            XCTAssertEqual(e.first, .divider)
            XCTAssertEqual(e.count, 6)
            XCTAssertEqual(paneMenuItems(e), five)
            XCTAssertEqual(try paneMenuVerb(e, "Zoom"), .action(.zoom))
            XCTAssertEqual(try paneMenuVerb(e, "Equalize"), .equalize)
            XCTAssertEqual(try paneMenuVerb(e, "Close Pane (the session keeps running)"), .action(.closePane))
            m.adopt(m.layout.toggleZoom())
            XCTAssertTrue(m.layout.zoomed != nil)
            XCTAssertEqual(paneMenuItems(AgentWindowControls.paneMenu(m, pane: m.layout.focused)), five, "zoomed")
            m.adopt(m.layout.toggleZoom())
            m.paneArea = CGRect(x: 0, y: 0, width: 400, height: 300)
            XCTAssertEqual(m.shownPanes.count, 1, "too small: one pane drawn")
            XCTAssertEqual(paneMenuItems(AgentWindowControls.paneMenu(m, pane: m.layout.focused)), five, "too small")
        }
    }

    /// 3.3 by menu and by key: six panes; both split items are off with the cap's titles; running a split verb anyway
    /// (a call) adds no pane; the key's split through the model adds none either and its notice is the cap's literal.
    @MainActor
    func testPaneMenuCapSixPanesByMenuAndByKey() throws {
        try withPaneMenu(true) {
            let m = paneMenuModel(paneLayout([paneTarget("api")]), area: CGSize(width: 3000, height: 2000))
            defer { m.close() }
            for axis in [PaneNode.Axis.columns, .rows, .columns, .rows, .columns] { XCTAssertTrue(m.perform(.split(axis))) }
            XCTAssertEqual(m.layout.panes.count, 6)
            let six = m.layout
            let e = AgentWindowControls.paneMenu(m, pane: m.layout.focused)
            XCTAssertEqual(Array(paneMenuItems(e).prefix(2)), ["Split Right (6 panes max) [off]", "Split Down (6 panes max) [off]"])
            XCTAssertEqual(try paneMenuVerb(e, "Split Right (6 panes max)"), .action(.split(.columns)))
            AgentWindowControls.runPane(try paneMenuVerb(e, "Split Down (6 panes max)"), pane: m.layout.focused, in: m)
            XCTAssertEqual(m.layout.panes.count, 6, "menu: no seventh pane")
            XCTAssertTrue(m.layout == six)
            XCTAssertTrue(m.perform(.split(.columns)), "key: refused and shown, so swallowed")
            XCTAssertEqual(m.layout.panes.count, 6, "key: no seventh pane")
            XCTAssertEqual(m.paneRefusal?.notice, "6 panes is the most a layout holds")
            // Every unfocused pane's menu is at the cap too.
            for id in m.layout.order {
                XCTAssertEqual(Array(paneMenuItems(AgentWindowControls.paneMenu(m, pane: id)).prefix(2)),
                               ["Split Right (6 panes max) [off]", "Split Down (6 panes max) [off]"])
            }
        }
    }

    /// 3.3: no room (two 250 columns are under 300): the menu's Split Right stays on with its plain title, and choosing
    /// it gives exactly what the key gives: the no-room notice (literal) and no pane.
    @MainActor
    func testPaneMenuNoRoomMenuAndKeyGiveTheSameNotice() throws {
        try withPaneMenu(true) {
            let l = paneLayout([paneTarget("api")])
            let menu = paneMenuModel(l, area: CGSize(width: 500, height: 600)), key = paneMenuModel(l, area: CGSize(width: 500, height: 600))
            defer { menu.close(); key.close() }
            let e = AgentWindowControls.paneMenu(menu, pane: menu.layout.focused)
            XCTAssertEqual(paneMenuItems(e), ["Split Right", "Split Down"], "no room is not the cap: both on")
            AgentWindowControls.runPane(try paneMenuVerb(e, "Split Right"), pane: menu.layout.focused, in: menu)
            XCTAssertTrue(key.perform(.split(.columns)))
            let notice = "No room for another pane here. Widen the window or hide the sidebar (⌃⌘S)."
            XCTAssertEqual(menu.paneRefusal?.notice, notice)
            XCTAssertEqual(key.paneRefusal?.notice, notice)
            XCTAssertEqual(menu.layout.panes.count, 1)
            XCTAssertTrue(menu.layout == l && key.layout == l)
        }
    }

    /// 7.3 / 7.4 / 7.5 / 8.1: each item through the menu's run path equals the key's action on a twin model (the trees
    /// compared as values), saved once like the key; Equalize (no key) equals the layout's whole-tree equalize.
    @MainActor
    func testPaneMenuEachVerbEqualsTheKeysAction() throws {
        try withPaneMenu(true) {
            let t = paneMenuThree()
            let names = [t.api: "api", t.web: "web", t.db: "db"]
            let keys: [(String, PaneAction?)] = [("Split Right", .split(.columns)), ("Split Down", .split(.rows)),
                                                 ("Zoom", .zoom), ("Equalize", nil),
                                                 ("Close Pane (the session keeps running)", .closePane)]
            for (title, action) in keys {
                let menu = paneMenuModel(t.l), twin = paneMenuModel(t.l)
                defer { menu.close(); twin.close() }
                let e = AgentWindowControls.paneMenu(menu, pane: t.api)
                let writes = menu.layoutWrites
                AgentWindowControls.runPane(try paneMenuVerb(e, title), pane: t.api, in: menu)
                if let action {
                    XCTAssertTrue(twin.perform(action), title)
                } else {
                    twin.adopt(try t.l.equalize(path: [], deep: true).get())
                }
                XCTAssertTrue(menu.layout != t.l, "\(title) changed the layout")
                XCTAssertEqual(paneMenuShape(menu.layout, names), paneMenuShape(twin.layout, names), title)
                XCTAssertEqual(menu.layoutWrites, writes + 1, "\(title): saved once")
                XCTAssertTrue(menu.paneRefusal == nil, title)
            }
            // The literal results, so a twin that went wrong the same way cannot pass.
            let eq = paneMenuModel(t.l)
            defer { eq.close() }
            AgentWindowControls.runPane(.equalize, pane: t.api, in: eq)
            XCTAssertEqual(paneMenuShape(eq.layout, names), "columns(\(1.0 / 3), api, rows(0.5, web, db)) focused api zoomed none")
            let split = paneMenuModel(t.l)
            defer { split.close() }
            AgentWindowControls.runPane(.action(.split(.columns)), pane: t.api, in: split)
            XCTAssertEqual(paneMenuShape(split.layout, names),
                           "columns(0.7, columns(0.5, api, new), rows(0.4, web, db)) focused new zoomed none")
        }
    }

    /// Item 3: every drawn pane has its own header and "⋯"; the menu of an UNFOCUSED pane acts on that pane (focused
    /// first through focusPane, then perform), never on the focused one. A pane closed since its menu was built: nothing.
    @MainActor
    func testPaneMenuUnfocusedPanesMenuActsOnThatPane() throws {
        try withPaneMenu(true) {
            let t = paneMenuThree()
            let names = [t.api: "api", t.web: "web", t.db: "db"]
            let close = paneMenuModel(t.l)
            defer { close.close() }
            XCTAssertEqual(close.layout.focused, t.api)
            let e = AgentWindowControls.paneMenu(close, pane: t.db)
            AgentWindowControls.runPane(try paneMenuVerb(e, "Close Pane (the session keeps running)"), pane: t.db, in: close)
            XCTAssertEqual(paneMenuShape(close.layout, names), "columns(0.7, api, web) focused web zoomed none", "db closed, not api")

            let split = paneMenuModel(t.l)
            defer { split.close() }
            AgentWindowControls.runPane(try paneMenuVerb(AgentWindowControls.paneMenu(split, pane: t.web), "Split Right"),
                                        pane: t.web, in: split)
            XCTAssertEqual(paneMenuShape(split.layout, names),
                           "columns(0.7, api, rows(0.4, columns(0.5, web, new), db)) focused new zoomed none")

            let zoom = paneMenuModel(t.l)
            defer { zoom.close() }
            AgentWindowControls.runPane(.action(.zoom), pane: t.web, in: zoom)
            XCTAssertEqual(zoom.layout.zoomed, t.web)

            let stale = paneMenuModel(t.l)
            defer { stale.close() }
            AgentWindowControls.runPane(.action(.closePane), pane: UUID(), in: stale)
            XCTAssertTrue(stale.layout == t.l, "a pane no longer in the layout: nothing runs")
        }
    }
}
