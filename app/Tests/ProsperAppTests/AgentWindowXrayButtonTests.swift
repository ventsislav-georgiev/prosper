import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1476: every pane header has an X-ray button just before the "..." (the remote header: last, where its mode toggle
/// was). A click focuses that pane, then the window's one drawer opens or closes for it (operator: "One for the
/// window"); open reads as selected; off without dch; the tooltip names the chord; the compact header keeps its slots.
/// Fakes only: a fake dch gate and runner, never-shown windows, no menu opened and no event posted.
extension AgentWindowD1Tests {
    /// The X-ray seams on fakes (a gate at `version`, nil: no dch), put back with no panel left open.
    @MainActor
    func xrayButtonSeams(_ version: [Int]?, _ body: (XrayPanelTasksTests.FakeRun) throws -> Void) rethrows {
        let fake = XrayPanelTasksTests.FakeRun()
        let (dch, run, model, window, read) = (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window, XrayPanels.chaptersRead)
        defer {
            (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window, XrayPanels.chaptersRead) = (dch, run, model, window, read)
            XrayPanels.shared.open = [:]
        }
        if let version { XrayPanels.dch = XrayPanelTasksTests.gate(version) } else { XrayPanels.dch = { nil } }
        XrayPanels.run = fake.run
        XrayPanels.chaptersRead = { _, _ in false }
        try body(fake)
    }

    /// Two live panes ("api" focused, "web") under the split gate, on an offscreen AgentsNSWindow (never shown).
    @MainActor
    func xrayButtonSplit(_ body: (AgentWindowModel, AgentsNSWindow, UUID, UUID) throws -> Void) throws {
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let m = windowModel(store([session("api", .idle), session("web", .idle)]))
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.setVisible(true)
        defer { m.close() }
        m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
        let api = try XCTUnwrap(m.layout.order.first), web = try XCTUnwrap(m.layout.order.last)
        XCTAssertNotEqual(api, web)
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        win.cards = FakeCardPresenter()
        XrayPanels.model = { [weak m] _ in m }
        XrayPanels.window = { [weak win] _ in win }
        try body(m, win, api, web)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// A never-shown window's accessibility tree of `view` once the X-ray button is in it.
    @MainActor
    func xrayButtonTree<V: View>(_ view: V, _ size: CGSize) -> [AXTreeNode] {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top))
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        let tree = AXTreeSupport.poll(host) { $0.contains { $0.named(AgentXrayButton.label) } }
        XCTAssertFalse(win.isVisible, "never on screen")
        return tree
    }

    /// Red at base: no AgentXrayButton (AgentsWindow.swift: the headers end with the "..." / the chip, #1471 removed the
    /// toggle). The button is in all three headers, once, just before the "..." where there is one, named "X-ray", its
    /// tooltip the chord in the symbols the other tooltips use.
    @MainActor
    func testXrayButtonIsInAllThreeHeadersBeforeTheMenu() throws {
        _ = ThemeStore.shared   // #1510: warm before the scale is pinned
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        try xrayButtonSeams([1, 78, 0]) { _ in
            let s = session("api", .idle)
            let m = windowModel(store([s]))
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(s.key))
            let row = try XCTUnwrap(m.selectedRow)
            let pane = m.layout.focused
            let remote = XrayRemoteTabsTests.remoteRow
            let r = try XCTUnwrap(remote.remote)
            let headers: [(String, AnyView, Bool)] = [
                ("session", AnyView(AgentSessionHeader(row: row, session: s, cwd: nil, open: {}, xrayPane: pane)), true),
                ("compact", AnyView(AgentCompactHeader.of(row, s, cwd: nil, ended: false, store: nil, ask: { _ in }, open: {},
                                                          xrayPane: pane)), true),
                ("remote", AnyView(AgentRemoteHeader(row: remote, remote: r, pane: pane)), false),
            ]
            for (name, view, menu) in headers {
                let tree = xrayButtonTree(view, CGSize(width: 700, height: 60))
                let x = tree.filter { $0.named(AgentXrayButton.label) && !$0.ignored }
                XCTAssertEqual(x.count, 1, "one X-ray button (\(name)): \(tree.map(\.name))")
                XCTAssertEqual(x.first?.help, "X-ray (\u{21E7}\u{2318}X)", "the tooltip names the chord (\(name))")
                XCTAssertEqual(x.first?.enabled, true, "on with dch and a session (\(name))")
                XCTAssertEqual(x.first?.selected, false, "closed: not selected (\(name))")
                if menu {
                    let dots = try XCTUnwrap(tree.first { $0.named("Session actions") }, "the \"...\" (\(name))")
                    let b = try XCTUnwrap(x.first)
                    XCTAssertLessThanOrEqual(b.frame.maxX, dots.frame.minX + AXTreeSupport.devicePixel, "just before the \"...\" (\(name))")
                    XCTAssertEqual(b.frame.midY, dots.frame.midY, accuracy: 2, "on the menu's line (\(name))")
                    XCTAssertFalse(tree.contains { $0.frame.width > 0 && $0.frame.minX > b.frame.maxX && $0.frame.maxX < dots.frame.minX && !$0.ignored },
                                   "nothing between it and the \"...\" (\(name))")
                }
            }
        }
    }

    /// Red at base: AgentsNSWindow.xrayClicked does not exist. Mutant xray-button-other-pane (no focusPane: the focused
    /// pane's drawer toggles) fails the "focuses that pane" and "open for web" lines.
    @MainActor
    func testXrayButtonClickFocusesItsPaneAndTogglesTheWindowsOneDrawer() throws {
        try xrayButtonSeams([1, 78, 0]) { _ in
            try xrayButtonSplit { m, win, api, web in
                let panels = XrayPanels.shared
                XCTAssertEqual(m.layout.focused, api, "control: api focused")
                AgentsNSWindow.xrayClicked(pane: web, in: win)
                XCTAssertEqual(m.layout.focused, web, "the click focuses its own pane first")
                XCTAssertEqual(panels.open[web]?.target.name, "web", "the drawer opens for web")
                XCTAssertTrue(panels.open[api] == nil, "not for api")
                AgentsNSWindow.xrayClicked(pane: web, in: win)
                XCTAssertTrue(panels.open[web] == nil, "a second click closes it")
                XCTAssertEqual(m.layout.focused, web, "focus stays")
                // One for the window: api's button moves the drawer to api (web's closes).
                AgentsNSWindow.xrayClicked(pane: web, in: win)
                AgentsNSWindow.xrayClicked(pane: api, in: win)
                XCTAssertEqual(m.layout.focused, api)
                XCTAssertEqual(panels.open[api]?.target.name, "api", "the one drawer now shows api")
                XCTAssertTrue(panels.open[web] == nil, "web's is gone: one drawer per window")
                XCTAssertEqual(panels.open.count, 1, "one panel open")
                AgentsNSWindow.xrayClicked(pane: api, in: win)
                XCTAssertTrue(panels.open.isEmpty, "closed")
                AgentsNSWindow.xrayClicked(pane: web, in: nil)
                XCTAssertTrue(panels.open.isEmpty, "no window: nothing")
            }
        }
    }

    /// Red with the one-drawer line removed from toggleXray or with xrayFollow emptied: focus moves while the drawer is
    /// open, and the drawer follows (same tab) to the newly focused pane.
    @MainActor
    func testXrayButtonDrawerFollowsTheFocusedPane() throws {
        try xrayButtonSeams([1, 78, 0]) { _ in
            try xrayButtonSplit { m, win, api, web in
                let panels = XrayPanels.shared
                XCTAssertTrue(win.toggleXray(on: .tasks))
                XCTAssertEqual(panels.open[api]?.tab, .tasks)
                m.focusPane(web)
                win.xrayFollow(from: api)
                XCTAssertTrue(panels.open[api] == nil, "api's panel goes")
                XCTAssertEqual(panels.open[web]?.target.name, "web", "the drawer follows to web")
                XCTAssertEqual(panels.open[web]?.tab, .tasks, "on the same tab")
                win.xrayFollow(from: api)
                XCTAssertEqual(panels.open.count, 1, "a second call (nothing open for api) changes nothing")
                XCTAssertEqual(panels.open[web]?.target.name, "web")
            }
        }
    }

    /// Red at base (no button). Mutant xray-button-not-selected (no .isSelected trait) fails the selected lines. Open
    /// for its pane: selected; closed, or a panel for another session in that pane: not; no dch: off, with the reason.
    @MainActor
    func testXrayButtonReadsSelectedWhenOpenAndOffWithoutDch() throws {
        _ = ThemeStore.shared   // #1510
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        let s = session("api", .idle)
        let m = windowModel(store([s]))
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(s.key))
        let row = try XCTUnwrap(m.selectedRow)
        let pane = m.layout.focused
        func button() -> AXTreeNode? {
            let header = AgentCompactHeader.of(row, s, cwd: nil, ended: false, store: nil, ask: { _ in }, open: {}, xrayPane: pane)
            return xrayButtonTree(header, CGSize(width: 500, height: AgentCompactHeader.height))
                .first { $0.named(AgentXrayButton.label) && !$0.ignored }
        }
        try xrayButtonSeams([1, 78, 0]) { _ in
            XCTAssertEqual(button()?.selected, false, "closed")
            XrayPanels.shared.open[pane] = XrayPanelModel(target: XrayTarget(name: "web", dir: "/tmp/dch-test"), tab: .tasks)
            XCTAssertEqual(button()?.selected, false, "a panel for another session is not this pane's drawer")
            XrayPanels.shared.open[pane] = XrayPanelModel(target: try XCTUnwrap(XrayTarget.of(row)), tab: .tasks)
            XCTAssertEqual(button()?.selected, true, "open: selected")
            XCTAssertEqual(button()?.enabled, true)
        }
        try xrayButtonSeams(nil) { _ in
            let b = button()
            XCTAssertEqual(b?.enabled, false, "no dch: off")
            XCTAssertEqual(b?.help, AgentXrayButton.noDch, "the tooltip says why")
        }
        try xrayButtonSeams([1, 77, 0]) { _ in
            XCTAssertEqual(button()?.enabled, false, "below X-ray's dch: off")
        }
        XCTAssertEqual(AgentXrayButton.offReason(nil), AgentXrayButton.noDch, "no dch wins")
        try xrayButtonSeams([1, 78, 0]) { _ in
            XCTAssertEqual(AgentXrayButton.offReason(nil), AgentXrayButton.noSession, "no session")
            XCTAssertNil(AgentXrayButton.offReason(XrayTarget.of(row)))
        }
    }

    /// Red at base (no button). The compact header keeps every slot: the title, the X-ray button and the "..." sit at the
    /// same frames closed, open and off, at 0.7, 0.85 and 1.0; the button is no wider than its slot (narrower than the
    /// icon pair it replaces), and the title gives up at most that slot and one spacing to it.
    @MainActor
    func testXrayButtonKeepsTheCompactHeadersSlotsAtEveryScale() throws {
        _ = ThemeStore.shared   // #1510: a cold init resets the scale mid-loop
        let pixel = AXTreeSupport.devicePixel
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let s = session("api", .idle, alias: Self.headerTitle)
            let m = windowModel(store([s]))
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(s.key))
            let row = try XCTUnwrap(m.selectedRow)
            let pane = m.layout.focused
            let size = CGSize(width: sz(300), height: AgentCompactHeader.height)
            typealias Slots = (title: CGRect?, x: CGRect?, dots: CGRect?)
            func frames(_ withButton: Bool = true) -> Slots {
                let h = AgentCompactHeader.of(row, s, cwd: nil, ended: false, store: nil, ask: { _ in }, open: {},
                                              xrayPane: withButton ? pane : nil)
                let host = NSHostingView(rootView: h.frame(width: size.width, height: size.height, alignment: .top))
                host.frame = CGRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
                win.isReleasedWhenClosed = false
                defer { win.contentView = nil; win.close() }
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                let tree = AXTreeSupport.poll(host) { $0.contains { $0.named("Session actions") } }
                return (tree.first { $0.named(row.title) }?.frame, tree.first { $0.named(AgentXrayButton.label) }?.frame,
                        tree.first { $0.named("Session actions") }?.frame)
            }
            let tag = "\(scale)"
            var closed: Slots = (nil, nil, nil), open = closed, off = closed, none = closed
            try xrayButtonSeams([1, 78, 0]) { _ in
                closed = frames()
                XrayPanels.shared.open[pane] = XrayPanelModel(target: try XCTUnwrap(XrayTarget.of(row)), tab: .tasks)
                open = frames()
                none = frames(false)
            }
            xrayButtonSeams(nil) { _ in off = frames() }
            let x = try XCTUnwrap(closed.x, "the button (\(tag))"), dots = try XCTUnwrap(closed.dots, "the \"...\" (\(tag))")
            let title = try XCTUnwrap(closed.title, "the title (\(tag))")
            for (state, f) in [("open", open), ("off", off)] {
                assertSame(f.title, title, "the title does not move (\(state) \(tag))")
                assertSame(f.x, x, "the button does not move (\(state) \(tag))")
                assertSame(f.dots, dots, "the \"...\" does not move (\(state) \(tag))")
            }
            assertSame(none.dots, dots, "the \"...\" stays at the edge with the button before it (\(tag))")
            XCTAssertLessThanOrEqual(x.width, AgentXrayButton.width + pixel, "no wider than its slot (\(tag))")
            XCTAssertLessThanOrEqual(x.maxX, dots.minX + pixel, "before the \"...\" (\(tag))")
            let given = (none.title?.width ?? 0) - title.width
            XCTAssertLessThanOrEqual(given, AgentXrayButton.width + sz(8) + pixel, "the title gives up only the slot (\(tag))")
            XCTAssertGreaterThan(title.width, sz(60), "the long title keeps its room (\(tag))")
        }
    }
}
