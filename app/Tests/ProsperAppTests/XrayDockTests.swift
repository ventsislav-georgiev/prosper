import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2055 (phase A): the X-ray drawer docks beside the terminal, which makes room (the default; overlay is a setting), the
/// terminal resizes once per drag, a session newly shown can open with its drawer, and each session keeps its drawer's
/// state. Offscreen only: never-shown windows, the fake dch gate and runner, the drag through the width model's pure seam
/// (no event built or posted), the settings in the XCTest scratch defaults, put back after.
extension XrayRemoteChipTests {
    /// Runs `body` with XrayPanels.docked at `docked` and the drawer width model between drags, both put back.
    func withDocked(_ docked: Bool, _ body: () async throws -> Void) async rethrows {
        let (saved, points) = (XrayPanels.shared.docked, XrayDrawerWidth.shared.points)
        let key = Preferences.defaults.object(forKey: "xrayDrawerWidth")
        defer {
            XrayPanels.shared.docked = saved
            let w = XrayDrawerWidth.shared, s = ThemeRuntime.scale
            w.reset()   // back to the standard, then a drag by the difference (the model's own seam) to the saved width
            if points != XrayDrawerWidth.standard { w.dragged(by: (XrayDrawerWidth.standard - points) * s, offered: 1e6); w.ended() }
            Preferences.defaults.set(key, forKey: "xrayDrawerWidth")
        }
        XrayPanels.shared.docked = docked
        try await body()
    }

    /// The remote branch of AgentDetailView (AgentsWindow.swift, the mount site under AgentRemoteHeader) at 800 x 500 with
    /// the drawer open; `each` sees every terminal probe frame; returns the host once both are laid out.
    func dockHost(_ win: AgentsNSWindow, _ m: AgentWindowModel, terminal each: @escaping (CGRect) -> Void,
                  xray: @escaping (CGRect) -> Void) -> NSView {
        AgentPaneArea.probe = { k, _, r in
            if k == "terminal" { each(r) } else if k == "xray" { xray(r) }
        }
        let host = NSHostingView(rootView: AgentDetailView(model: m, transcript: m.transcript, scrolls: false)
            .environment(\.agentPaneID, m.layout.focused).coordinateSpace(.named(agentPaneAreaSpace)).frame(width: 800, height: 500))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        win.contentView = host
        return host
    }

    /// Red at 00fefbad (AgentsWindow.swift:2644, the drawer an `.overlay` over the terminal: the terminal keeps 800 wide
    /// under it). Docked: the terminal is the pane's width less the drawer's and ends where the drawer starts; overlay
    /// (the setting off): the terminal keeps the whole width under the drawer, as before. Mutant dock-forced-overlay.
    func testXrayDockTerminalMakesRoomAndOverlayKeepsTheFullWidth() async throws {
        defer { AgentPaneArea.probe = nil }
        for docked in [true, false] {
            try await withDocked(docked) {
                try await withSeams([1, 78, 0], FakeRun()) {
                    try await window { win, m in
                        final class Seen { var term: CGRect?; var drawer: CGRect? }
                        let seen = Seen()
                        let host = dockHost(win, m, terminal: { seen.term = $0 }, xray: { seen.drawer = $0 })
                        defer { AgentPaneArea.probe = nil; win.contentView = nil }
                        Self.layOut(host, until: { seen.term != nil })
                        XCTAssertTrue(win.toggleXray(), "the drawer opens")
                        Self.layOut(host, until: { seen.drawer != nil && (docked ? (seen.term?.width ?? 800) < 799 : true) })
                        let t = try XCTUnwrap(seen.term), d = try XCTUnwrap(seen.drawer, "the drawer is drawn")
                        let want = XrayDrawerWidth.width(stored: XrayDrawerWidth.shared.settled, offered: 800)
                        XCTAssertEqual(d.width, want, accuracy: 1, "the drawer's width")
                        if docked {
                            XCTAssertEqual(t.width, 800 - d.width, accuracy: 1, "docked: the terminal makes room")
                            XCTAssertLessThanOrEqual(t.maxX, d.minX + 1, "docked: no overlap")
                        } else {
                            XCTAssertEqual(t.width, 800, accuracy: 1, "overlay: the terminal keeps the full width")
                            XCTAssertGreaterThan(t.maxX, d.minX + 1, "overlay: the drawer is over it")
                        }
                    }
                }
            }
        }
    }

    /// Red with the room made for the live width (mutant dock-resize-per-tick: XrayDrawerWidth.settled returns `points`):
    /// ten drag ticks on the drawer's edge, docked, move the terminal's frame zero times; the drag's end moves it once, to
    /// the new room.
    func testXrayDockDragResizesTheTerminalOnceAtItsEnd() async throws {
        defer { AgentPaneArea.probe = nil }
        try await withDocked(true) {
            try await withSeams([1, 78, 0], FakeRun()) {
                try await window { win, m in
                    final class Seen { var widths: [CGFloat] = []; var drawer: CGRect? }
                    let seen = Seen()
                    let host = dockHost(win, m, terminal: { r in
                        if seen.widths.last.map({ abs($0 - r.width) > 0.5 }) ?? true { seen.widths.append(r.width) }
                    }, xray: { seen.drawer = $0 })
                    defer { AgentPaneArea.probe = nil; win.contentView = nil }
                    XrayDrawerWidth.shared.reset()   // the standard 480 (withDocked puts the width back)
                    XCTAssertTrue(win.toggleXray())
                    Self.layOut(host, until: { seen.drawer != nil && (seen.widths.last ?? 800) < 799 })
                    let before = seen.widths.count, start = try XCTUnwrap(seen.drawer).width
                    for i in 1...10 {
                        XrayDrawerWidth.shared.dragged(by: CGFloat(4 * i), offered: 800)   // narrower by 4 pt a tick (480 is 60% of 800: the widest)
                        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                    }
                    XCTAssertLessThan(seen.drawer?.width ?? 1000, start - 20, "control: the drawer previews the drag")
                    XCTAssertEqual(seen.widths.count, before, "no terminal resize during the drag: \(seen.widths)")
                    XrayDrawerWidth.shared.ended()
                    let end = XrayDrawerWidth.width(stored: XrayDrawerWidth.shared.points, offered: 800)
                    Self.layOut(host, until: { abs((seen.widths.last ?? 0) - (800 - end)) < 1 })
                    XCTAssertEqual(seen.widths.count, before + 1, "one resize at the drag's end: \(seen.widths)")
                    XCTAssertEqual(seen.widths.last ?? 0, 800 - end, accuracy: 1, "to the new room")
                }
            }
        }
    }

    /// The pure room: docked and open, the drawn width; closed or overlay, none (XrayDrawerWidth.width's bounds).
    func testXrayDockInsetIsTheDrawnWidthOnlyWhenDockedAndOpen() {
        XCTAssertEqual(XrayDock.inset(open: true, docked: true, settled: 480, offered: 1200, scale: 1), 480)
        XCTAssertEqual(XrayDock.inset(open: true, docked: true, settled: 480, offered: 600, scale: 1), 360, "at most 60% of the pane")
        XCTAssertEqual(XrayDock.inset(open: true, docked: true, settled: 480, offered: 400, scale: 1), 240,
                       "a narrow pane: the drawer's 300 minimum is wider, the terminal keeps 40%")
        XCTAssertEqual(XrayDock.inset(open: false, docked: true, settled: 480, offered: 1200, scale: 1), 0, "closed: no room")
        XCTAssertEqual(XrayDock.inset(open: true, docked: false, settled: 480, offered: 1200, scale: 1), 0, "overlay: no room")
    }
}

extension AgentWindowD1Tests {
    /// One pane on an offscreen AgentsNSWindow (never shown) holding "api" and "web", the X-ray seams on fakes; the
    /// remembered states and the new-session setting put back after.
    @MainActor
    func xrayDockWindow(openWithNew: Bool, _ body: (AgentWindowModel, AgentsNSWindow, AgentSession, AgentSession) throws -> Void) throws {
        let savedNew = Preferences.defaults.object(forKey: "xrayOpenWithNewSessions")
        defer {
            Preferences.defaults.set(savedNew, forKey: "xrayOpenWithNewSessions")
            XrayPanels.shared.remembered = [:]
        }
        XCTAssertFalse(Preferences.defaults === UserDefaults.standard, "a private defaults store")
        Preferences.xrayOpenWithNewSessions = openWithNew
        XrayPanels.shared.remembered = [:]
        try xrayButtonSeams([1, 78, 0]) { _ in
            let api = session("api", .idle), web = session("web", .idle)
            let m = windowModel(store([api, web]))
            m.setVisible(true)
            defer { m.close() }
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
    }

    /// Red at 00fefbad (no xrayShown; the pane's panel stayed on api, undrawn, and web never opened its own). Open on api,
    /// the pane shows web (never opened: closed), back on api: open again; closed by its own X on api, it stays closed
    /// when api comes back. Mutant dock-no-restore.
    @MainActor
    func testXrayDockEachSessionKeepsItsDrawerState() throws {
        try xrayDockWindow(openWithNew: false) { m, win, api, web in
            let panels = XrayPanels.shared, pane = m.layout.focused
            m.select(.live(api.key))
            XCTAssertTrue(win.toggleXray())
            XCTAssertEqual(panels.open[pane]?.target.name, "api")
            m.select(.live(web.key))
            win.xrayShown()
            XCTAssertTrue(panels.open[pane] == nil, "web was never opened: closed (api's panel stops)")
            m.select(.live(api.key))
            win.xrayShown()
            XCTAssertEqual(panels.open[pane]?.target.name, "api", "back on api: open again")
            panels.open[pane]?.close()   // the panel's own X
            m.select(.live(web.key))
            win.xrayShown()
            m.select(.live(api.key))
            win.xrayShown()
            XCTAssertTrue(panels.open[pane] == nil, "closed on api by the person: stays closed")
        }
    }

    /// Red at 00fefbad (no setting). On: a session shown for the first time opens with its drawer; one the person closed
    /// stays closed. Off: closed. Mutant dock-new-ignored.
    @MainActor
    func testXrayDockNewSessionsOpenWithTheDrawerWhenSet() throws {
        for on in [true, false] {
            try xrayDockWindow(openWithNew: on) { m, win, api, web in
                let panels = XrayPanels.shared, pane = m.layout.focused
                m.select(.live(web.key))
                win.xrayShown()
                XCTAssertEqual(panels.open[pane]?.target.name, on ? "web" : nil, "a newly shown session, setting \(on)")
                if on {
                    XCTAssertTrue(win.toggleXray(), "the person closes web's")
                    m.select(.live(api.key))
                    win.xrayShown()
                    XCTAssertEqual(panels.open[pane]?.target.name, "api", "api, new too, opens")
                    m.select(.live(web.key))
                    win.xrayShown()
                    XCTAssertTrue(panels.open[pane] == nil, "web, closed by the person, stays closed")
                }
            }
        }
    }
}
