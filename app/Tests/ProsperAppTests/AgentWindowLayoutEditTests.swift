import AppKit
import XCTest
@testable import ProsperApp

/// #1538 (operator 2026-11-18, "Explicit edit mode"): a saved layout is locked; a pick of a session it shows focuses that
/// pane, any other opens the single-pane view and the layout is neither rewritten nor saved (the blob byte-equal); the
/// Layouts row or Control-<n> brings it back as it was left. Edit layout (or "+") is the behaviour before #1538. Structural
/// changes are refused while locked. The band takes no height with nothing to show. The model only: no window is shown,
/// no event is posted, the layouts live in a private XCTestDefaults suite; sessions are fakes ("api", "web", "docs").
final class AgentWindowLayoutEditTests: XCTestCase {
    let base = AgentWindowD1Tests()
    static let blobKey = "agentWindowLayouts"

    /// The split gate set for the row and put back after it (main actor).
    @MainActor
    func withGate(_ on: Bool, _ body: () throws -> Void) rethrows {
        let saved = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = saved }
        AgentPaneLayout.splitsEnabled = on
        try body()
    }

    func t(_ name: String) -> PaneTarget { base.paneTarget(name) }
    func row(_ name: String) -> AgentSidebar.RowID { .live(base.paneKey(name)) }

    /// A two-pane layout (api | web, api focused) saved as the only layout, a visible model over api, web, docs (web
    /// blocked, so Command-J has a target) and the blob's bytes as saved. Locked unless `editing`.
    @MainActor
    func locked(editing: Bool = false) throws -> (m: AgentWindowModel, d: UserDefaults, two: PaneLayout, bytes: Data?) {
        let two = base.paneLayout([t("api"), t("web")])
        let d = base.layoutSuite()
        d.set(try PaneLayoutStore(layouts: [two], active: two.id, mru: [two.id]).encode(), forKey: Self.blobKey)
        let st = base.store([base.session("api", .idle), base.session("web", .blocked), base.session("docs", .idle),
                             base.session("ops", .idle)])
        let m = base.windowModel(st, layouts: d)   // starts in Edit layout (the helper's rule)
        m.setVisible(true)
        m.setLayoutEditing(editing)
        return (m, d, two, d.data(forKey: Self.blobKey))
    }

    /// A fresh window opens locked: no Edit layout, the saved two-pane layout locked. One layout of one pane is never
    /// locked (nothing the person made); the gate off is never locked and a click goes into the pane as before.
    @MainActor
    func testAgentWindowLayoutEditDefaultsToLockedAndTheGateOffIsUnchanged() throws {
        try withGate(true) {
            let two = base.paneLayout([t("api"), t("web")])
            let d = base.layoutSuite()
            d.set(try PaneLayoutStore(layouts: [two], active: two.id, mru: [two.id]).encode(), forKey: Self.blobKey)
            let fresh = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: d)
            defer { fresh.close() }
            XCTAssertFalse(fresh.layoutEditing, "a new window opens locked (the flag is never saved)")
            XCTAssertTrue(fresh.layoutLocked)
            let lone = base.windowModel(base.store([base.session("api", .idle)]), layouts: base.layoutSuite())
            defer { lone.close() }
            lone.setLayoutEditing(false)
            XCTAssertFalse(lone.layoutLocked, "one layout of one pane: never locked")
        }
        try withGate(false) {
            let (m, _, two, _) = try locked()
            defer { m.close() }
            XCTAssertFalse(m.layoutLocked, "gate off: nothing locks")
            m.click(row("docs"))
            XCTAssertTrue(m.parked == nil, "gate off: no single-pane view")
            XCTAssertEqual(m.layout.id, two.id, "gate off: the click goes into the layout as before")
        }
    }

    /// Locked: a click on a session outside the layout shows it in the single-pane view; the saved layout is parked, the
    /// blob byte-equal, no write, no Layouts row active and the view is not a layout (the store still holds one). A second
    /// outside click stays in the same view.
    @MainActor
    func testAgentWindowLayoutEditLockedClickOutsideOpensTheSinglePaneViewBlobByteEqual() throws {
        try withGate(true) {
            let (m, d, two, bytes) = try locked()
            defer { m.close() }
            XCTAssertTrue(m.layoutLocked)
            let writes = m.layoutWrites
            m.click(row("docs"))
            XCTAssertEqual(m.layout.panes.count, 1, "the single-pane view")
            XCTAssertTrue(m.layout.panes.first?.target == t("docs"))
            XCTAssertTrue(m.parked?.id == two.id, "the layout set aside")
            XCTAssertEqual(d.data(forKey: Self.blobKey), bytes, "the blob byte-equal")
            XCTAssertEqual(m.layoutWrites, writes, "nothing written")
            XCTAssertEqual(m.layouts?.layouts.count, 1, "the view is not a saved layout")
            XCTAssertTrue(m.layoutRows?.contains { $0.active } == false, "no Layouts row is active in the view")
            let view = m.layout.id
            m.click(row("ops"))
            XCTAssertEqual(m.layout.id, view, "another outside click stays in the same view")
            XCTAssertTrue(m.layout.panes.first?.target == t("ops"))
            XCTAssertEqual(d.data(forKey: Self.blobKey), bytes, "still byte-equal")
        }
    }

    /// The Layouts row (switchLayout) and Control-1 bring the layout back as it was left: its panes and the focus moved
    /// before the outside click (a focus move while locked writes nothing).
    @MainActor
    func testAgentWindowLayoutEditReturnBringsTheLayoutBackWithItsFocus() throws {
        try withGate(true) {
            let (m, d, two, bytes) = try locked()
            defer { m.close() }
            let second = try XCTUnwrap(two.order.last)
            m.focusPane(second)
            XCTAssertEqual(m.layout.focused, second)
            m.click(row("docs"))
            XCTAssertTrue(m.switchLayout(two.id) == nil, "the Layouts row")
            XCTAssertEqual(m.layout.id, two.id)
            XCTAssertEqual(m.layout.order, two.order, "the same panes")
            XCTAssertEqual(m.layout.panes.map(\.target), two.panes.map(\.target), "the same targets")
            XCTAssertEqual(m.layout.focused, second, "the focus it was left with")
            XCTAssertTrue(m.parked == nil)
            m.click(row("docs"))
            XCTAssertTrue(m.switchLayout(number: 1) == nil, "Control-1")
            XCTAssertEqual(m.layout.id, two.id)
            XCTAssertEqual(m.layout.focused, second, "Control-1 keeps the focus too")
            XCTAssertEqual(d.data(forKey: Self.blobKey), bytes, "never written")
        }
    }

    /// Locked: a click on a session the layout shows focuses its pane (as before); from the single-pane view it returns
    /// to the layout with that pane focused. Command-J from the view to a blocked session in the layout does the same.
    @MainActor
    func testAgentWindowLayoutEditLockedInsideClickFocusesItsPane() throws {
        try withGate(true) {
            let (m, d, two, bytes) = try locked()
            defer { m.close() }
            let second = try XCTUnwrap(two.order.last)
            m.click(row("web"))
            XCTAssertEqual(m.layout.id, two.id)
            XCTAssertEqual(m.layout.focused, second, "its pane focused")
            m.click(row("api"))
            m.click(row("docs"))
            m.click(row("web"))
            XCTAssertEqual(m.layout.id, two.id, "back from the view")
            XCTAssertEqual(m.layout.focused, second, "on the clicked session's pane")
            XCTAssertTrue(m.parked == nil)
            m.click(row("docs"))
            XCTAssertTrue(m.nextNeedsYou(), "Command-J")
            XCTAssertEqual(m.layout.id, two.id, "Command-J returns to the layout")
            XCTAssertEqual(m.layout.focused, second, "on the blocked session's pane")
            XCTAssertEqual(d.data(forKey: Self.blobKey), bytes)
        }
    }

    /// Edit layout is the behaviour before #1538: a click fills the focused pane and is saved once. Done saves and locks.
    @MainActor
    func testAgentWindowLayoutEditModeIsTheOldBehaviour() throws {
        try withGate(true) {
            let (m, d, two, bytes) = try locked(editing: true)
            defer { m.close() }
            XCTAssertFalse(m.layoutLocked)
            let writes = m.layoutWrites
            m.click(row("docs"))
            XCTAssertTrue(m.parked == nil, "no single-pane view while editing")
            XCTAssertEqual(m.layout.id, two.id)
            XCTAssertTrue(m.layout.panes.first?.target == t("docs"), "into the focused pane")
            XCTAssertEqual(m.layoutWrites, writes + 1, "saved once")
            XCTAssertNotEqual(d.data(forKey: Self.blobKey), bytes)
            m.setLayoutEditing(false)
            XCTAssertTrue(m.layoutLocked, "Done locks")
            XCTAssertTrue(m.layouts?.activeLayout == m.layout, "Done leaves the layout saved")
        }
    }

    /// Locked: Split, Close Pane, a pane retarget (title switcher), a drop, Open to the Side and the dividers are refused
    /// with "Edit layout to change it"; the layout and the blob stay. A focus move still works. Editing, Close Pane acts.
    @MainActor
    func testAgentWindowLayoutEditLockedStructuralChangesAreRefused() throws {
        try withGate(true) {
            let (m, d, two, bytes) = try locked()
            defer { m.close() }
            let second = try XCTUnwrap(two.order.last)
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            XCTAssertEqual(PaneRefusal.layoutLocked.notice, "Edit layout to change it")
            XCTAssertTrue(m.perform(.split(.columns)), "the chord is swallowed")
            XCTAssertEqual(m.paneRefusal, .layoutLocked)
            XCTAssertEqual(m.layout.order, two.order, "no split")
            XCTAssertTrue(m.perform(.closePane))
            XCTAssertEqual(m.layout.order, two.order, "no close")
            m.closePane(second)
            XCTAssertEqual(m.layout.order, two.order, "no close from the header")
            m.choose(row("docs"), into: second)
            XCTAssertTrue(m.layout.panes.last?.target == t("web"), "no retarget")
            XCTAssertTrue(m.drop(row("docs"), into: second, zone: .centre))
            XCTAssertTrue(m.layout.panes.last?.target == t("web"), "no drop")
            m.openToTheSide(row("docs"))
            XCTAssertEqual(m.layout.order, two.order, "no side split")
            XCTAssertTrue(m.dividers(in: CGSize(width: 3000, height: 1000)).isEmpty, "no divider to drag")
            XCTAssertEqual(d.data(forKey: Self.blobKey), bytes)
            XCTAssertTrue(m.perform(.cycle(1)), "a focus move still acts")
            XCTAssertEqual(m.layout.focused, second)
            m.setLayoutEditing(true)
            m.closePane(second)
            XCTAssertEqual(m.layout.panes.count, 1, "editing: Close Pane acts")
        }
    }

    /// "+" opens the new layout in Edit layout: a click fills its pane, no single-pane view.
    @MainActor
    func testAgentWindowLayoutEditNewLayoutOpensInEditMode() throws {
        try withGate(true) {
            let (m, _, _, _) = try locked()
            defer { m.close() }
            XCTAssertTrue(m.newLayout() == nil)
            XCTAssertTrue(m.layoutEditing, "a new layout opens in Edit layout")
            let made = m.layout.id
            m.click(row("docs"))
            XCTAssertTrue(m.parked == nil)
            XCTAssertEqual(m.layout.id, made)
            XCTAssertTrue(m.layout.panes.first?.target == t("docs"))
        }
    }

    /// #1617: Command-D (and the Split menu items, the same perform) on the lone one-pane layout opens Edit layout, so the
    /// next sidebar click fills the new empty focused pane and the layout keeps both (saved). A refused split (no room)
    /// changes nothing: still not editing, the click replaces the one pane as before.
    @MainActor
    func testAgentWindowLayoutEditSplitOpensEditModeAndAClickFillsTheNewPane() throws {
        try withGate(true) {
            let d = base.layoutSuite()
            let m = base.windowModel(base.store([base.session("api", .idle), base.session("docs", .idle)]), layouts: d)
            defer { m.close() }
            m.setVisible(true)
            m.setLayoutEditing(false)
            m.click(row("api"))
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            XCTAssertTrue(m.perform(.split(.columns)))
            XCTAssertTrue(m.layoutEditing, "a split opens Edit layout")
            XCTAssertEqual(m.layout.panes.count, 2)
            XCTAssertTrue(m.layouts?.activeLayout == m.layout, "the split itself saved")
            XCTAssertTrue(m.layout.panes.first { $0.id == m.layout.focused }?.target == nil, "the new empty pane focused")
            let made = m.layout.id
            m.click(row("docs"))
            XCTAssertTrue(m.parked == nil, "no single-pane view")
            XCTAssertEqual(m.layout.id, made)
            XCTAssertEqual(m.layout.panes.map(\.target), [t("api"), t("docs")], "the layout keeps both")
            XCTAssertTrue(m.layouts?.activeLayout == m.layout, "saved")
            let small = base.windowModel(base.store([base.session("api", .idle), base.session("docs", .idle)]),
                                         layouts: base.layoutSuite())
            defer { small.close() }
            small.setVisible(true)
            small.setLayoutEditing(false)
            small.click(row("api"))
            small.paneArea = CGRect(x: 0, y: 0, width: 10, height: 10)
            XCTAssertTrue(small.perform(.split(.columns)), "the refusal is swallowed")
            XCTAssertFalse(small.layoutEditing, "a refused split leaves Edit layout off")
            XCTAssertEqual(small.layout.panes.count, 1)
            small.click(row("docs"))
            XCTAssertTrue(small.layout.panes.first?.target == t("docs"), "the click replaces the one pane as before")
        }
    }

    /// #1700 (operator 2026-11-20: "pressing cmd+d in a single session does not do the split, it shows to click edit, but
    /// there is no such button"): Command-D in the single-pane view makes a new layout of the view's session plus an
    /// empty pane, Edit layout on, saved; the parked layout stays saved as it was. The next click fills the new pane. The
    /// Split menu item (runPane, the same perform) from another single-pane view does the same and is drawn enabled.
    @MainActor
    func testAgentWindowLayoutEditCommandDInTheSinglePaneViewMakesANewLayout() throws {
        try withGate(true) {
            let (m, _, two, _) = try locked()
            defer { m.close() }
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            m.click(row("docs"))
            XCTAssertTrue(m.parked != nil, "the single-pane view")
            XCTAssertTrue(m.perform(.split(.columns)), "the chord is swallowed")
            XCTAssertTrue(m.paneRefusal == nil, "no Edit notice")
            XCTAssertTrue(m.parked == nil, "the view became a layout")
            XCTAssertTrue(m.layoutEditing, "Edit layout on (#1617)")
            XCTAssertEqual(m.layout.panes.map(\.target), [t("docs"), nil], "the session in pane 1, an empty pane 2")
            XCTAssertTrue(m.layout.panes.first { $0.id == m.layout.focused }?.target == nil, "the empty pane focused")
            XCTAssertEqual(m.layouts?.layouts.count, 2, "a new layout")
            XCTAssertTrue(m.layouts?.activeLayout == m.layout, "saved and active")
            XCTAssertTrue(m.layouts?.layouts.first { $0.id == two.id } == two, "the parked layout kept as saved")
            m.click(row("ops"))
            XCTAssertEqual(m.layout.panes.map(\.target), [t("docs"), t("ops")], "the next click fills the new pane")
            XCTAssertTrue(m.switchLayout(two.id) == nil)
            m.setLayoutEditing(false)
            m.click(row("ops"))   // not in `two`: the single-pane view again
            XCTAssertTrue(m.parked != nil)
            let pane = m.layout.focused
            XCTAssertEqual(AgentWindowControls.paneMenu(m, pane: pane).filter { if case .pane(_, true, .action(.split)) = $0 { true } else { false } }.count,
                           2, "Split Right and Split Down drawn enabled")
            AgentWindowControls.runPane(.action(.split(.rows)), pane: pane, in: m)
            XCTAssertTrue(m.parked == nil && m.layoutEditing, "the Split menu item makes a layout too")
            XCTAssertEqual(m.layout.panes.map(\.target), [t("ops"), nil])
        }
    }

    /// #1700: the notice never names a control that is not drawn. In the single-pane view (no Edit anywhere) Close Pane,
    /// a pane retarget, a drop and Open to the Side never answer "Edit layout to change it": the retarget takes the pick,
    /// an edge drop and Open to the Side make a new layout as Command-D does. At 9 layouts the split says so instead.
    @MainActor
    func testAgentWindowLayoutEditSinglePaneViewNeverNamesAMissingEdit() throws {
        try withGate(true) {
            @MainActor func view() throws -> AgentWindowModel {
                let m = try locked().m
                m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
                m.click(row("docs"))
                XCTAssertTrue(m.parked != nil && !m.layoutShown, "the single-pane view")
                return m
            }
            let m = try view()
            defer { m.close() }
            let pane = m.layout.focused
            let shownView = m.layout
            XCTAssertTrue(m.perform(.closePane), "Command-W swallowed: it never reaches the window close or the terminal")
            XCTAssertFalse(m.closed, "the window stays open")
            XCTAssertTrue(m.paneRefusal == nil, "Command-W: no notice")
            XCTAssertTrue(m.layout == shownView && m.parked != nil, "the view and its pane stay")
            m.closePane(pane)
            XCTAssertTrue(m.paneRefusal == nil, "Close Pane: no notice")
            m.choose(row("ops"), into: pane)
            XCTAssertTrue(m.paneRefusal == nil, "a retarget: no notice")
            XCTAssertTrue(m.layout.panes.first?.target == t("ops"), "the view's pane takes the pick")
            XCTAssertTrue(m.drop(row("docs"), into: m.layout.focused, zone: .edge(.right)))
            XCTAssertTrue(m.paneRefusal == nil && m.parked == nil && m.layoutEditing, "an edge drop makes a layout")
            XCTAssertEqual(m.layout.panes.map(\.target), [t("ops"), t("docs")])
            let side = try view()
            defer { side.close() }
            side.openToTheSide(row("ops"))
            XCTAssertTrue(side.paneRefusal == nil && side.parked == nil && side.layoutEditing, "Open to the Side makes a layout")
            XCTAssertEqual(side.layout.panes.map(\.target), [t("docs"), t("ops")])
            let full = try locked().m
            defer { full.close() }
            full.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            for _ in 0..<8 { XCTAssertTrue(full.newLayout() == nil) }
            full.setLayoutEditing(false)
            full.click(row("docs"))
            XCTAssertTrue(full.parked != nil)
            XCTAssertTrue(full.perform(.split(.columns)))
            XCTAssertEqual(full.paneRefusal, .layoutCap)
            XCTAssertEqual(full.paneRefusal?.notice, "9 layouts is the most a window holds")
            XCTAssertTrue(full.parked != nil && full.layout.panes.count == 1, "nothing made at 9")
        }
    }

    /// #1722 (QA R1717stack n47): an edge drop of a remote row on the single-pane view at the 9-layout cap is refused whole:
    /// the notice shows, the open New Session form stays, the remote key is not armed (no attach without the #1330 card),
    /// the single-pane view stays. With room (8 layouts) the same drop makes the layout and arms the key, the form closing.
    @MainActor
    func testAgentWindowLayoutEditRemoteEdgeDropRefusedAtTheCapArmsAndClearsNothing() throws {
        try withGate(true) {
            let remote = AgentSidebar.RowID.remote(host: "host-a", name: "api")
            let key = AgentTerminalSpawn.remoteKey(host: "host-a", name: "api")
            let json = #"[{"name":"api","alias":"","host":"host-a","state":"idle","stale":false,"cwd":null}]"#
            // The controller's seams faked: a recording spawn, never a real dch; the form's gate a value, never run.
            @MainActor func gated(_ m: AgentWindowModel) {
                m.store?.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
                m.terminal.request = { AgentTerminalSpawn.attach($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
                m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
                m.terminal.makeScreen = { AgentTerminalTests.FakeScreen($0) }
                m.terminal.after = { _, _ in }
                m.terminal.clientVersion = { _ in [1, 74, 0] }
                m.terminal.gridChanged(cols: 80, rows: 24)
            }
            // At the cap: refused.
            let full = try locked().m
            defer { full.close() }
            gated(full)
            full.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            for _ in 0..<8 { XCTAssertTrue(full.newLayout() == nil) }
            full.setLayoutEditing(false)
            full.remoteListed(Data(json.utf8))
            full.click(row("docs"))
            full.openNewSession()
            XCTAssertTrue(full.parked != nil && full.row(remote) != nil && full.newSession != nil, "set up: view, remote row, open form")
            let shown = full.layout
            XCTAssertTrue(full.drop(remote, into: full.layout.focused, zone: .edge(.right)), "the drop is handled")
            XCTAssertEqual(full.paneRefusal, .layoutCap)
            XCTAssertTrue(full.newSession != nil, "the pending form is kept")
            XCTAssertTrue(full.terminal.armed == nil, "the remote key is not armed")
            XCTAssertTrue(full.parked != nil && full.layout == shown, "nothing made at 9")
            // With room: unchanged.
            let room = try locked().m
            defer { room.close() }
            gated(room)
            room.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            for _ in 0..<7 { XCTAssertTrue(room.newLayout() == nil) }
            room.setLayoutEditing(false)
            room.remoteListed(Data(json.utf8))
            room.click(row("docs"))
            room.openNewSession()
            XCTAssertTrue(room.parked != nil && room.newSession != nil)
            XCTAssertTrue(room.drop(remote, into: room.layout.focused, zone: .edge(.right)))
            XCTAssertTrue(room.paneRefusal == nil && room.parked == nil && room.layoutEditing, "the layout is made")
            XCTAssertTrue(room.newSession == nil, "the form is cleared")
            XCTAssertTrue(room.terminal.armed == key, "the remote key is armed on success")
        }
    }

    /// The Go menu's Edit Layout: with the split gate on only.
    @MainActor
    func testAgentWindowLayoutEditGoMenuItem() {
        XCTAssertTrue(AgentGoMenu.layoutEntries(splits: true).contains { $0?.action == .editLayout })
        XCTAssertTrue(AgentGoMenu.layoutEntries(splits: false).isEmpty)
    }

    /// #1726: the Layout menu's list item for layout 1 does what Control-1 does: from the single-pane view the saved layout
    /// comes back, nothing written; the item is on (gate on, no rename, no form) and checked while that layout is active.
    @MainActor
    func testAgentWindowLayoutMenuListItemSwitchesAsControlDigit() throws {
        try withGate(true) {
            let (m, d, two, bytes) = try locked()
            defer { m.close() }
            let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.model = m
            defer { win.model = nil; win.close() }
            m.click(row("docs"))
            XCTAssertTrue(m.parked != nil, "control: the single-pane view")
            XCTAssertTrue(win.enabled(.pane(.layout(1))))
            XCTAssertTrue(win.perform(pane: .layout(1)))
            XCTAssertEqual(m.layout.id, two.id, "the Layout menu's layout 1, as Control-1")
            XCTAssertTrue(m.parked == nil)
            XCTAssertEqual(d.data(forKey: Self.blobKey), bytes, "never written")
            guard let layoutMenu = win.menus.last, let menu = layoutMenu.item.submenu else { return XCTFail("the Layout menu") }
            XCTAssertEqual(layoutMenu.kind, .layout)
            layoutMenu.menuNeedsUpdate(menu)
            let listed = menu.items.filter { item in layoutMenu.shown.indices.contains(item.tag) && !item.isSeparatorItem
                && layoutMenu.shown[item.tag].action == .pane(.layout(1)) }
            XCTAssertEqual(listed.count, 1, "layout 1 listed once")
            XCTAssertTrue(listed.first?.state == .on, "the active layout checked")
            XCTAssertTrue(listed.first?.keyEquivalent == "1" && listed.first?.keyEquivalentModifierMask == .control)
        }
    }

    /// Supervisor rider (operator 2026-11-18, "a lot of empty space in the top?"): one layout of one pane, no band
    /// height and the pane area from y 0; #1646: two layouts of one pane the same; two panes zoomed, the band and the area
    /// under it.
    @MainActor
    func testAgentWindowLayoutEditBandTakesNoHeightWithNothingToShow() throws {
        let size = CGSize(width: 1600, height: 900)
        try withGate(true) {
            let m = base.windowModel(base.store([base.session("api", .idle)]), layouts: base.layoutSuite())
            defer { m.close() }
            m.setVisible(true)
            XCTAssertFalse(AgentWindowBand.shows(m), "one layout of one pane: nothing to show")
            XCTAssertEqual(m.paneAreaFrame(in: size)?.minY, 0, "the pane area from the top")
            XCTAssertEqual(m.paneAreaFrame(in: size)?.height, 900)
            XCTAssertTrue(m.newLayout() == nil)
            XCTAssertTrue(m.layoutRows != nil, "two layouts: the Layouts section is built")
            XCTAssertFalse(AgentWindowBand.shows(m), "#1646: two layouts of one pane: no band (Edit is on the sidebar row)")
            XCTAssertEqual(m.paneAreaFrame(in: size)?.minY, 0, "#1646: the pane area from the top")
            let z = base.windowModel(base.store([base.session("api", .idle), base.session("web", .idle)]))
            defer { z.close() }
            z.adopt(base.paneLayout([t("api"), t("web")]))
            XCTAssertTrue(z.perform(.zoom))
            XCTAssertTrue(z.layout.zoomed != nil)
            XCTAssertTrue(AgentWindowBand.shows(z), "zoomed: the band (its chip)")
            XCTAssertEqual(z.paneAreaFrame(in: size)?.minY, AgentWindowBand.height)
        }
        try withGate(false) {
            let m = base.windowModel(base.store([base.session("api", .idle)]))
            defer { m.close() }
            XCTAssertFalse(AgentWindowBand.shows(m), "gate off: no band, as before")
        }
    }

    /// #1646 (operator 2026-11-19: "clicking it, goes and opens my saved layout which has nothing to do with the current
    /// session"): in the single-pane view no saved layout is shown, so the Go menu's Edit Layout is off (layoutShown) and
    /// the toggle does nothing: the view stays, the layout stays parked, nothing written. Back on the layout, it toggles.
    @MainActor
    func testAgentWindowLayoutEditToggleInTheSinglePaneViewDoesNothing() throws {
        try withGate(true) {
            let (m, d, two, bytes) = try locked()
            defer { m.close() }
            XCTAssertTrue(m.layoutShown, "the saved layout on screen")
            m.click(row("docs"))
            let view = m.layout.id, writes = m.layoutWrites
            XCTAssertFalse(m.layoutShown, "the single-pane view is not a layout")
            m.toggleLayoutEditing()
            XCTAssertFalse(m.layoutEditing, "no Edit layout from the view")
            XCTAssertEqual(m.layout.id, view, "the view stays (no switch to the parked layout)")
            XCTAssertTrue(m.parked?.id == two.id, "still parked")
            XCTAssertEqual(m.layoutWrites, writes, "nothing written")
            XCTAssertEqual(d.data(forKey: Self.blobKey), bytes, "the blob byte-equal")
            XCTAssertTrue(m.switchLayout(two.id) == nil)
            XCTAssertTrue(m.layoutShown)
            m.toggleLayoutEditing()
            XCTAssertTrue(m.layoutEditing, "on the layout: Edit")
            m.toggleLayoutEditing()
            XCTAssertFalse(m.layoutEditing, "Done")
        }
    }

    /// #1646: the band carries no layout name and no Edit layout in any view. A saved two-pane layout: the band (its
    /// panes) without them; the single-pane view from it with the sidebar shown: no band, the pane area from the top (the
    /// header where it is with no saved layout); the sidebar hidden: the band for the show glyph only, the empty layout
    /// room as with no saved layout.
    @MainActor
    func testAgentWindowLayoutEditBandHasNoLayoutNameOrEditInAnyView() throws {
        let size = CGSize(width: 1600, height: 900)
        let d = Preferences.defaults, hidden = d.object(forKey: AgentWindowD1Tests.sidebarKey)
        defer {
            if let hidden { d.set(hidden, forKey: AgentWindowD1Tests.sidebarKey) } else { d.removeObject(forKey: AgentWindowD1Tests.sidebarKey) }
        }
        for sidebarHidden in [false, true] {
            Preferences.agentWindowSidebarHidden = sidebarHidden
            try withGate(true) {
                let (m, _, _, _) = try locked()
                defer { m.close() }
                XCTAssertEqual(m.sidebarShown, !sidebarHidden, "the preference read (\(sidebarHidden))")
                // #1697: two panes alone: no band but for the hidden sidebar's show glyph
                XCTAssertEqual(AgentWindowBand.shows(m), sidebarHidden, "two panes: the band only for the glyph (\(sidebarHidden))")
                let onLayout = base.bandSnapshot(m, size)
                XCTAssertEqual(onLayout["band"] != nil, sidebarHidden, "\(sidebarHidden)")
                XCTAssertTrue(onLayout["edit"] == nil && onLayout["layoutName"] == nil, "no name, no Edit (\(sidebarHidden)): \(onLayout.keys.sorted())")
                m.click(row("docs"))
                XCTAssertTrue(m.parked != nil && m.layoutRows != nil, "the single-pane view, a saved layout present")
                let single = base.bandSnapshot(m, size)
                XCTAssertTrue(single["edit"] == nil && single["layoutName"] == nil, "no name, no Edit (\(sidebarHidden))")
                if sidebarHidden {
                    XCTAssertTrue(AgentWindowBand.shows(m), "the show glyph keeps the band")
                    XCTAssertTrue(single["sidebar"] != nil && single["layout"] != nil, "the glyph and the empty room: \(single.keys.sorted())")
                } else {
                    XCTAssertFalse(AgentWindowBand.shows(m), "no band in the single-pane view")
                    XCTAssertTrue(single.isEmpty, "nothing built: \(single.keys.sorted())")
                    XCTAssertEqual(m.paneAreaFrame(in: size)?.minY, 0, "the header from the top")
                }
            }
        }
    }
}
