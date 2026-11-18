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

    /// The Go menu's Edit Layout: with the split gate on only.
    @MainActor
    func testAgentWindowLayoutEditGoMenuItem() {
        XCTAssertTrue(AgentGoMenu.layoutEntries(splits: true).contains { $0?.action == .editLayout })
        XCTAssertTrue(AgentGoMenu.layoutEntries(splits: false).isEmpty)
    }

    /// Supervisor rider (operator 2026-11-18, "a lot of empty space in the top?"): one layout of one pane, no band
    /// height and the pane area from y 0; two layouts, or two panes zoomed, the band and the area under it.
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
            XCTAssertTrue(AgentWindowBand.shows(m), "two layouts: the band")
            XCTAssertEqual(m.paneAreaFrame(in: size)?.minY, AgentWindowBand.height, "the area under it")
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
}
