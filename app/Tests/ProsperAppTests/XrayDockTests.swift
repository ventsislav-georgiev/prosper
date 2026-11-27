import Combine
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
        let restore = Self.dockSaved()
        defer { restore() }
        XrayPanels.shared.docked = docked
        try await body()
    }

    /// XrayPanels.docked and the drawer width model as they are now; the closure puts them back (#2068: sync rows too).
    static func dockSaved() -> @MainActor () -> Void {
        let (saved, points) = (XrayPanels.shared.docked, XrayDrawerWidth.shared.points)
        let key = Preferences.defaults.object(forKey: "xrayDrawerWidth")
        return {
            XrayPanels.shared.docked = saved
            let w = XrayDrawerWidth.shared, s = ThemeRuntime.scale
            w.reset()   // back to the standard, then a drag by the difference (the model's own seam) to the saved width
            if points != XrayDrawerWidth.standard { w.dragged(by: (XrayDrawerWidth.standard - points) * s, offered: 1e6); w.ended() }
            Preferences.defaults.set(key, forKey: "xrayDrawerWidth")
        }
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
                        Self.pump(host)
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

    /// Red at 46e5c1ab (XrayPanel.swift:1149, `start` not @Published): ended() only cleared `start`, so `settled` moved
    /// (the drag's start width to the new points) with no objectWillChange and a docked terminal never re-read it.
    /// Mutant dock-end-not-published.
    func testXrayDockDragEndPublishesTheSettledWidth() async throws {
        try await withDocked(true) {
            let w = XrayDrawerWidth()
            w.reset()   // the standard 480 whatever the scratch defaults hold, so the drag below moves it (withDocked puts the key back)
            var sent = 0
            let sub = w.objectWillChange.sink { sent += 1 }
            defer { sub.cancel() }
            w.dragged(by: 0, offered: 1000)
            let from = w.settled
            for i in 1...3 { w.dragged(by: CGFloat(20 * i), offered: 1000) }
            XCTAssertEqual(w.settled, from, "control: settled holds the start width during the drag")
            let before = sent
            w.ended()
            XCTAssertGreaterThan(sent, before, "ended() publishes: settled changes with it")
            XCTAssertEqual(w.settled, w.points, "settled is the new points once the drag is over")
            XCTAssertNotEqual(w.settled, from, "the width did change")
            w.dragged(by: 40, offered: 1000)   // a drag in flight, then a reset: start clears before points moves
            w.reset()
            XCTAssertEqual(w.settled, XrayDrawerWidth.standard, "reset() leaves settled at the new points")
            XCTAssertFalse(w.dragging, "reset() ends the drag")
        }
    }

    /// Three layout passes with the run loop turned between them; synchronous, as RunLoop.run is unavailable in an async test.
    static func pump(_ host: NSView) {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
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

    /// #2068: the terminal on fakes (no dch, no screen) and AgentPaneArea hosted in the never-shown `win` at `size`, over a
    /// window-move view, so a point no view of the area takes is told apart (AppKit's hitTest, no event).
    @MainActor
    func xrayDockArea(_ m: AgentWindowModel, _ win: AgentsNSWindow, _ size: CGSize) -> NSView {
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.terminal.makeScreen = { AgentTerminalTests.FakeScreen($0) }
        m.terminal.after = { _, _ in }
        let host = NSHostingView(rootView: ZStack { AgentWindowDragArea(); AgentPaneArea(model: m, scrolls: false) }
            .frame(width: size.width, height: size.height))
        win.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        return host
    }

    /// #2068 (supervisor gap, QA R2055a): red without the new call (mutant dock-first-not-applied: makeWindow's
    /// `model.firstShown` line gone): the area's onChange sees only later changes, so the session focused when the window
    /// first shows kept a closed drawer whatever its remembered state or the setting. The model's first selection lands
    /// at setVisible(true) on a window AgentsWindow.makeWindow built (never shown). Remembered wins over the setting.
    @MainActor
    func testXrayDockTheSessionTheWindowOpensOnTakesItsDrawerState() throws {
        // (api's remembered state, Open the X-ray drawer with new sessions, the drawer open)
        for (remembered, openWithNew, want) in [(true, false, true), (false, true, false), (nil, true, true), (nil, false, false)]
            as [(Bool?, Bool, Bool)] {
            let savedNew = Preferences.defaults.object(forKey: "xrayOpenWithNewSessions")
            defer {
                Preferences.defaults.set(savedNew, forKey: "xrayOpenWithNewSessions")
                XrayPanels.shared.remembered = [:]
            }
            XCTAssertFalse(Preferences.defaults === UserDefaults.standard, "a private defaults store")
            Preferences.xrayOpenWithNewSessions = openWithNew
            try xrayButtonSeams([1, 78, 0]) { _ in
                let api = session("api", .idle), why = "remembered \(String(describing: remembered)), new \(openWithNew)"
                XrayPanels.shared.remembered = remembered.map { [XrayTarget(name: api.key.name, dir: api.key.dir): $0] } ?? [:]
                let m = windowModel(store([api]))
                defer { m.close() }
                m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
                m.terminal.makeScreen = { AgentTerminalTests.FakeScreen($0) }
                let win = AgentsWindow.makeWindow(m, autosave: nil)
                defer { win.close() }
                win.cards = FakeCardPresenter()
                XrayPanels.model = { [weak m] _ in m }
                XrayPanels.window = { [weak win] _ in win }
                XCTAssertTrue(XrayPanels.shared.open.isEmpty, "control: nothing open before the window shows")
                m.setVisible(true)
                if m.selection == nil { m.select(.live(api.key)) }   // the first fill's pick, else the person's: either lands first
                XCTAssertEqual(m.selection, .live(api.key), "control: the window shows api")
                XCTAssertEqual(XrayPanels.shared.open[m.layout.focused]?.target.name, want ? "api" : nil, why)
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }

    /// #2068 n1 (QA R2055a): two columns ("api" focused, "web"), the drawer docked open on api, AgentPaneArea hosted. 1400
    /// wide (the standard 480 drawer): both panes are drawn and end where the room starts. 700 wide: the area left holds
    /// one column, yet compact is the 700-wide window's (two columns fit), so the window's one drawer is drawn in the room.
    /// Either way the drawer fills the room and a click there lands on it, not through to the window-move view. Red with
    /// the compact size read without the room (mutant dock-compact-no-room, AgentsWindow.swift:3003): at 700 the pane is
    /// not compact, draws a drawer inside itself, and the room is empty.
    @MainActor
    func testXrayDockSplitLayoutPanesEndAtTheRoomAndTheDrawerTakesTheClicks() throws {
        let restore = XrayRemoteChipTests.dockSaved()
        defer { restore(); AgentPaneArea.probe = nil }
        XrayPanels.shared.docked = true
        XrayDrawerWidth.shared.reset()   // the standard 480 (restore puts the width back)
        try xrayButtonSeams([1, 78, 0]) { _ in try xrayButtonSplit { m, win, api, _ in
            for width in [1400, 700] as [CGFloat] {
                final class Seen { var panes: [UUID: CGRect] = [:]; var drawer: CGRect? }
                let seen = Seen(), size = CGSize(width: width, height: 600)
                AgentPaneArea.probe = { k, p, r in if k == "pane" { seen.panes[p] = r } else if k == "xray" { seen.drawer = r } }
                defer { AgentPaneArea.probe = nil; win.contentView = nil }
                XCTAssertTrue(AgentPaneArea.compact(m, size), "control: two columns fit \(width)")
                if XrayPanels.shared.open[api] == nil { XCTAssertTrue(win.toggleXray(), "the drawer opens on api") }
                let room = XrayDock.inset(open: true, docked: true, settled: XrayDrawerWidth.shared.settled, offered: width)
                let host = xrayDockArea(m, win, size)
                XrayRemoteChipTests.layOut(host, until: { !seen.panes.isEmpty && abs((seen.drawer?.maxX ?? 0) - width) < 1 })
                let d = try XCTUnwrap(seen.drawer, "\(width): the drawer is drawn")
                XCTAssertEqual(d.minX, width - room, accuracy: 1, "\(width): the drawer starts where the room does")
                XCTAssertEqual(d.maxX, width, accuracy: 1, "\(width): and fills it to the window's edge")
                // the panes drawn now: a pane hidden once the room took its width keeps its last (first-pass) probe in `seen`
                let drawn = AgentPaneArea.drawn(m, in: CGRect(x: 0, y: 0, width: width - room, height: 600)).keys
                let ends = drawn.compactMap { seen.panes[$0]?.maxX }
                XCTAssertEqual(ends.count, width == 1400 ? 2 : 1, "\(width): both columns drawn at 1400, the focused one at 700")
                XCTAssertLessThanOrEqual(ends.max() ?? .infinity, width - room + 1, "\(width): the panes end at the room: \(ends)")
                let p = CGPoint(x: width - room / 2, y: 300), v = host.hitTest(host.superview.map { host.convert(p, to: $0) } ?? p)
                XCTAssertTrue(v != nil && !(v is AgentWindowDragView), "\(width): a click in the room: \(String(describing: v))")
            }
        } }
    }

    /// #2068 n2 (QA R2055a): the session changed THROUGH THE MODEL (the sidebar's pick), never a direct xrayShown call: the
    /// area's onChange applies the new session's state. Red with the onChange's `else { w?.xrayShown() }` gone (mutant
    /// dock-onchange-unwired, AgentsWindow.swift:3077): api's panel stays open over web.
    @MainActor
    func testXrayDockASessionChangeThroughTheModelTakesItsDrawerState() throws {
        try xrayDockWindow(openWithNew: false) { m, win, api, web in
            let panels = XrayPanels.shared, pane = m.layout.focused
            m.select(.live(api.key))
            let host = xrayDockArea(m, win, CGSize(width: 1200, height: 600))
            defer { win.contentView = nil }
            XrayRemoteChipTests.layOut(host, until: { AgentsNSWindow.window(of: pane) === win })
            XCTAssertTrue(AgentsNSWindow.window(of: pane) === win, "control: the area's onChange finds this window")
            XCTAssertTrue(win.toggleXray())
            XCTAssertEqual(panels.open[pane]?.target.name, "api")
            m.select(.live(web.key))
            XrayRemoteChipTests.layOut(host, until: { panels.open[pane] == nil })
            XCTAssertTrue(panels.open[pane] == nil, "web, never opened: closed")
            m.select(.live(api.key))
            XrayRemoteChipTests.layOut(host, until: { panels.open[pane] != nil })
            XCTAssertEqual(panels.open[pane]?.target.name, "api", "back on api: open again")
        }
    }
}
