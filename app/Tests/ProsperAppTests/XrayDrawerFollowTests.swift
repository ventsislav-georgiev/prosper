import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2092: the X-ray drawer follows the focused pane from the model (AgentWindowModel.xrayShownChanged, told at the end of
/// the change, before the view update): the follow is done before any layout, the drawer's view stays across the move,
/// the followed pane shows its kept rows at once and the left pane's state is kept. Offscreen: the window is built by
/// AgentsWindow.makeWindow (the product's wiring) and never shown, ordered in or made key; no event is built or posted;
/// every dch read parks until its panel stops (fakes); the terminals spawn a FakeChild.
@MainActor
final class XrayDrawerFollowTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()

    func key(_ n: String) -> AgentSessionKey { AgentSessionKey(dir: "/tmp/dch-test", name: n) }
    func target(_ n: String) -> XrayTarget { XrayTarget(name: n, dir: "/tmp/dch-test") }

    /// 2 panes (api, web, api focused) in a makeWindow window at 1600x900, scale 1, the gate on, the X-ray seams faked;
    /// all put back after.
    func rig(_ body: (AgentWindowModel, AgentsNSWindow, NSView, UUID, UUID) throws -> Void) throws {
        let d = Preferences.defaults, keys = ["agentWindowStyle", "xrayBottomTab", "xrayBottomFraction"]
        XCTAssertFalse(d === UserDefaults.standard, "a private defaults store")
        let saved = keys.map { d.object(forKey: $0) }
        let theme = (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost), gate = AgentPaneLayout.splitsEnabled
        let seams = (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window, XrayPanels.chaptersRead, XrayPanels.keepRows)
        let remembered = XrayPanels.shared.remembered
        defer {
            for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = theme
            AgentPaneLayout.splitsEnabled = gate
            XrayPanels.shared.open = [:]
            (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window, XrayPanels.chaptersRead, XrayPanels.keepRows) = seams
            XrayPanels.shared.remembered = remembered
        }
        (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = (1, 1, false)
        AgentPaneLayout.splitsEnabled = true
        let m = d1.windowModel(d1.store([d1.session("api", .idle), d1.session("web", .idle)]))
        defer { m.close() }
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.setVisible(true)
        m.select(.live(key("api")))
        m.adopt(d1.paneLayout([d1.paneTarget("api"), d1.paneTarget("web")]))
        let api = try XCTUnwrap(m.layout.order.first), web = try XCTUnwrap(m.layout.order.last)
        if m.layout.focused != api { m.focusPane(api) }
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 171, 0])
        XrayPanels.run = { _, _, _ in try? await Task.sleep(for: .seconds(3600)); return (-1, Data()) }   // parks until cancelled
        XrayPanels.model = { [weak m] _ in m }
        XrayPanels.chaptersRead = XrayPanels.fromDch
        XrayPanels.keepRows = { false }
        let win = AgentsWindow.makeWindow(m, autosave: nil)
        defer { XrayPanels.shared.open = [:]; win.contentViewController = nil; win.close() }
        XrayPanels.window = { [weak win] _ in win }
        win.setContentSize(NSSize(width: 1600, height: 900))
        let v = try XCTUnwrap(win.contentView)
        settle(v)
        XCTAssertEqual(m.layout.focused, api, "the fixture's focus")
        try body(m, win, v, api, web)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    func settle(_ v: NSView) {
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            v.layoutSubtreeIfNeeded()
        }
    }

    /// The drawer's registered NSViews (XrayDrawerFrame, a background of the drawer's content) now in `win`.
    func drawerViews(_ win: NSWindow) -> [NSView] {
        XrayDrawerFrame.views.compactMap(\.view).filter { $0.window === win }
    }

    /// Red at base (the follow ran from the pane area's onChange, inside the view update: nothing moved before a layout,
    /// and the drawer was taken down and built again). Mutant follow-on-onchange fails the "before any layout" lines;
    /// drawer-keyed-by-pane fails the "same view" line.
    func testDrawerFollowsFromTheModelBeforeTheViewUpdateAndKeepsItsView() throws {
        try rig { m, win, v, api, web in
            let panels = XrayPanels.shared
            XCTAssertTrue(win.toggleXray(on: .tasks))
            settle(v)
            let before = drawerViews(win)
            XCTAssertEqual(before.count, 1, "control: the window's one drawer is drawn")
            m.focusPane(web)
            XCTAssertTrue(panels.open[api] == nil, "before any layout: api's panel went")
            XCTAssertEqual(panels.open[web]?.target.name, "web", "before any layout: the drawer is web's")
            XCTAssertEqual(panels.open[web]?.tab, .tasks, "on the same tab")
            XCTAssertEqual(panels.remembered[target("api")], true, "api's drawer state is kept (not closed by the person)")
            settle(v)
            let after = drawerViews(win)
            XCTAssertEqual(after.count, 1, "one drawer")
            XCTAssertTrue(after.first != nil && after.first === before.first, "the drawer's view stays across the follow")
            m.focusPane(api)
            XCTAssertEqual(panels.open[api]?.target.name, "api", "back on api: the drawer follows back")
            XCTAssertTrue(panels.open[web] == nil)
        }
    }

    /// Red under mutant follow-on-onchange (sidebar row bodies about 5.4 per move with the drawer vs 1.8 without, #2077):
    /// a focus move with the drawer open draws the sidebar rows no more often than the same move with it closed, give or
    /// take one body per move.
    func testDrawerFollowIsOneUpdatePass() throws {
        try rig { m, win, v, api, web in
            var bodies = 0
            AgentSidebarRowView.bodyProbe = { _ in bodies += 1 }
            defer { AgentSidebarRowView.bodyProbe = nil }
            let moves = 4
            @MainActor func run() -> Int {
                bodies = 0
                for i in 0..<moves { m.focusPane(i % 2 == 0 ? web : api); settle(v) }
                return bodies
            }
            let closed = run()
            XCTAssertTrue(win.toggleXray(on: .tasks))
            settle(v)
            let open = run()
            XCTAssertTrue(XrayPanels.shared.open[m.layout.focused] != nil, "control: the drawer followed")
            XCTAssertLessThanOrEqual(open, closed + moves, "sidebar row bodies: \(open) with the drawer, \(closed) without")
        }
    }

    /// Red at base (no follow from the model). Mutant follow-seed-skipped (read() never seeds from XrayPanels.kept): the
    /// followed pane's panel has no rows until its read answers (here never: the read parks).
    func testFollowedPaneShowsItsKeptRowsAtOnce() throws {
        try rig { m, win, v, _, web in
            XrayPanels.keepRows = { true }   // put back by the rig
            let tasks = XrayTasks.parse(XrayPanelTasksTests.ndjson([XrayPanelTasksTests.header,
                #"{"task":{"id":"1","title":"Kept task","status":"pending","label":"pending","note":"","created":"2026-11-16T09:00:00Z","updated":"2026-11-16T11:00:00Z","blocked_by":[]}}"#,
                #"{"done":true,"count":1,"dropped":0}"#]))
            XCTAssertEqual(tasks.tasks.count, 1, "control: the fixture parses")
            XrayPanels.shared.keep(target("web"), XrayPanels.Kept(tasks: tasks, anchors: [:]))
            XCTAssertTrue(win.toggleXray(on: .tasks))
            settle(v)
            m.focusPane(web)
            XCTAssertEqual(XrayPanels.shared.open[web]?.tasks?.tasks.count, 1, "web's kept rows, before any read answers")
        }
    }

    /// Red at base without the xrayClicked change (the follow opened web's drawer, then the button's toggle closed it).
    /// Mutant xray-click-toggles-after-follow. The drawer open on api, web's header button: the drawer is web's, open.
    func testXrayButtonOnAnotherPaneMovesTheOpenDrawer() throws {
        try rig { m, win, v, api, web in
            XCTAssertTrue(win.toggleXray(on: .tasks))
            settle(v)
            AgentsNSWindow.xrayClicked(pane: web, in: win)
            XCTAssertEqual(m.layout.focused, web)
            XCTAssertEqual(XrayPanels.shared.open[web]?.target.name, "web", "open, now on web")
            XCTAssertTrue(XrayPanels.shared.open[api] == nil)
            AgentsNSWindow.xrayClicked(pane: web, in: win)
            XCTAssertTrue(XrayPanels.shared.open.isEmpty, "a second click on web's button closes it")
        }
    }

    /// The count the hook adds per publish: a store refresh that changes neither the focus nor the session tells nothing;
    /// a focus move tells once; hidden, nothing, and the move is told once on show. Red at base (no hook); mutant
    /// shown-hook-unguarded (the `now != old` check gone) fails the refresh count, shown-hook-hidden (the visible check gone)
    /// the hidden one.
    func testShownChangesAreToldOnceAndNotWhileHidden() throws {
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let m = d1.windowModel(d1.store([d1.session("api", .idle), d1.session("web", .idle)]))
        defer { m.close() }
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.setVisible(true)
        m.adopt(d1.paneLayout([d1.paneTarget("api"), d1.paneTarget("web")]))
        let api = try XCTUnwrap(m.layout.order.first), web = try XCTUnwrap(m.layout.order.last)
        m.focusPane(api)
        var told: [(AgentWindowModel.XrayShown, AgentWindowModel.XrayShown)] = []
        m.xrayShownChanged = { told.append(($0, $1)) }
        for _ in 0..<5 { m.refresh() }
        XCTAssertEqual(told.count, 0, "a refresh that changes nothing tells nothing")
        m.focusPane(web)
        XCTAssertEqual(told.count, 1, "a focus move tells once")
        XCTAssertEqual(told.last?.0.pane, api)
        XCTAssertEqual(told.last?.1.pane, web)
        XCTAssertEqual(told.last?.1.target, target("web"))
        m.focusPane(web)
        m.refresh()
        XCTAssertEqual(told.count, 1, "no change: nothing more")
        m.setVisible(false)
        m.focusPane(api)
        XCTAssertEqual(told.count, 1, "hidden: nothing")
        m.setVisible(true)
        XCTAssertEqual(told.count, 2, "shown again: the move is told once")
        XCTAssertEqual(told.last?.0.pane, web)
        XCTAssertEqual(told.last?.1.pane, api)
    }
}
