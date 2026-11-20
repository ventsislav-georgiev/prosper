import AppKit
import XCTest
@testable import ProsperApp

/// #1707 (OQ-170 b, operator 2026-11-20: "Act on first click in header"): a first click on an unfocused pane's header
/// focuses the pane AND passes, so the control under it (the title chip, X-ray, the "...") acts on that click; a first
/// click in the body still only focuses. Offscreen only: built NSEvents handed to a never-shown AgentsNSWindow's own
/// sendEvent (never posted), with a recorder in its `raise` seam first; no menu or popover is opened: each control's
/// action is checked through its seam (the pane-menu model, the switcher list, xrayClicked). Sessions are fakes.
extension AgentWindowD1Tests {
    enum HeaderControl: CaseIterable { case chip, xray, menu }

    /// Where `c` sits in a pane header of `f` (the pane area's top-left coordinates): AgentCompactHeader's line, its
    /// 10·s side padding, the 18·s "...", the 8·s spacing and the 22·s X-ray button; the title chip at the leading edge.
    @MainActor
    func headerPoint(_ c: HeaderControl, in f: CGRect) -> CGPoint {
        let y = f.minY + AgentCompactHeader.height / 2
        switch c {
        case .chip: return CGPoint(x: f.minX + sz(20), y: y)
        case .xray: return CGPoint(x: f.maxX - sz(10) - sz(18) - sz(8) - AgentXrayButton.width / 2, y: y)
        case .menu: return CGPoint(x: f.maxX - sz(10) - sz(9), y: y)
        }
    }

    /// Red at base (the old line `focusPane(id); return true` swallows every first click): on the model, at three UI
    /// scales, a down on each header control of the unfocused pane focuses it, gives the panes the keys and passes
    /// (false); a down in its body focuses and is swallowed (true). The header's last point row passes, its first body
    /// row (the 1 pt line under the header) is swallowed. The focused pane's header passes and refocuses nothing.
    @MainActor
    func testHeaderFirstClickFocusesAndPassesTheBodyOnlyFocuses() throws {
        let gate = AgentPaneLayout.splitsEnabled, saved = ThemeRuntime.scale
        defer { AgentPaneLayout.splitsEnabled = gate; ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            AgentPaneLayout.splitsEnabled = true
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let first = try XCTUnwrap(m.layout.order.first), second = try XCTUnwrap(m.layout.order.last)
            let size = CGSize(width: 1600, height: 900)
            let area = try XCTUnwrap(m.paneAreaFrame(in: size))
            let f = try XCTUnwrap(m.paneFrames(in: CGRect(origin: .zero, size: area.size))[second])
            func at(_ p: CGPoint) -> CGPoint { CGPoint(x: area.minX + p.x, y: area.minY + p.y) }
            func back() throws { m.adopt(try m.layout.focus(first).get()); m.keyFocus = .sidebar }
            for c in HeaderControl.allCases {
                try back()
                XCTAssertFalse(m.mouseDown(at: at(headerPoint(c, in: f)), in: size), "\(c): the click passes (\(scale))")
                XCTAssertEqual(m.layout.focused, second, "\(c): and focuses its pane (\(scale))")
                XCTAssertEqual(m.keyFocus, .pane, "\(c): the panes take the keys (\(scale))")
            }
            try back()
            XCTAssertFalse(m.mouseDown(at: at(CGPoint(x: f.midX, y: f.minY + AgentCompactHeader.height - 0.5)), in: size),
                           "the header's last row passes (\(scale))")
            XCTAssertEqual(m.layout.focused, second)
            try back()
            XCTAssertTrue(m.mouseDown(at: at(CGPoint(x: f.midX, y: f.minY + AgentCompactHeader.height)), in: size),
                          "the line under the header is the body's: focus only (\(scale))")
            XCTAssertEqual(m.layout.focused, second)
            try back()
            XCTAssertTrue(m.mouseDown(at: at(CGPoint(x: f.midX, y: f.midY)), in: size), "the body: focus only (\(scale))")
            XCTAssertEqual(m.layout.focused, second)
            XCTAssertFalse(m.mouseDown(at: at(headerPoint(.menu, in: f)), in: size), "the focused pane's header passes")
            XCTAssertEqual(m.layout.focused, second)
        }
    }

    /// Pure: inHeader's bounds (top edge in, AgentCompactHeader.height out, outside the frame out, no frame out).
    @MainActor
    func testInHeaderIsTheTopLineOfTheFrameOnly() {
        let f = CGRect(x: 100, y: 50, width: 400, height: 300)
        XCTAssertTrue(AgentsNSWindow.inHeader(CGPoint(x: 100, y: 50), f))
        XCTAssertTrue(AgentsNSWindow.inHeader(CGPoint(x: 499, y: 50 + AgentCompactHeader.height - 0.01), f))
        XCTAssertFalse(AgentsNSWindow.inHeader(CGPoint(x: 300, y: 50 + AgentCompactHeader.height), f))
        XCTAssertFalse(AgentsNSWindow.inHeader(CGPoint(x: 50, y: 60), f), "left of the frame")
        XCTAssertFalse(AgentsNSWindow.inHeader(CGPoint(x: 300, y: 40), f), "above the frame")
        XCTAssertFalse(AgentsNSWindow.inHeader(CGPoint(x: 300, y: 60), nil))
    }

    /// Through the window's sendEvent: a down on `c` in web's (unfocused) header focuses web, is not swallowed (its up
    /// neither) and asks no key and front of its own (AppKit's super.sendEvent does what it does for any passing click).
    @MainActor
    func headerFirstClick(_ c: HeaderControl, _ m: AgentWindowModel, _ win: AgentsNSWindow, web: UUID) throws {
        var raised = 0
        win.raise = { _ in raised += 1 }   // R1196-1: a recorder first, never the real key and front
        let size = win.contentLayoutRect.size
        let area = try XCTUnwrap(m.paneAreaFrame(in: size))
        let f = try XCTUnwrap(m.paneFrames(in: CGRect(origin: .zero, size: area.size))[web])
        let h = headerPoint(c, in: f), p = CGPoint(x: area.minX + h.x, y: area.minY + h.y)
        XCTAssertNotEqual(m.layout.focused, web, "control: web unfocused")
        m.keyFocus = .sidebar
        win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
        XCTAssertEqual(m.layout.focused, web, "\(c): the click focused web")
        XCTAssertEqual(m.keyFocus, .pane)
        XCTAssertFalse(win.focusClick.swallowing, "\(c): its down passed to the control")
        XCTAssertEqual(raised, 0, "\(c): no swallowed down, so no key-and-front ask of the window's own")
        win.sendEvent(try paneFocusMouse(.leftMouseUp, p, win))
        XCTAssertFalse(win.focusClick.swallowing, "\(c): its up passed")
        // The body still only focuses: back to api, a down in web's body is swallowed.
        m.focusPane(try XCTUnwrap(m.layout.order.first))
        let b = CGPoint(x: area.minX + f.midX, y: area.minY + f.midY)
        win.sendEvent(try paneFocusMouse(.leftMouseDown, b, win))
        XCTAssertTrue(win.focusClick.swallowing, "\(c) control: the body's first click is swallowed")
        win.sendEvent(try paneFocusMouse(.leftMouseUp, b, win))
        XCTAssertFalse(win.focusClick.swallowing)
        m.focusPane(try XCTUnwrap(m.layout.order.first))
    }

    /// Red at base: the down on web's X-ray button is swallowed (the "passed" line). After it, the button's action
    /// (xrayClicked, its seam) opens the window's one drawer for web, the pane the click focused.
    @MainActor
    func testHeaderFirstClickOnXrayFocusesAndActs() throws {
        try xrayButtonSeams([1, 78, 0]) { _ in
            try xrayButtonSplit { m, win, _, web in
                try headerFirstClick(.xray, m, win, web: web)
                win.sendEvent(try paneFocusMouse(.leftMouseDown, try xrayHeaderPoint(m, win, web), win))
                XCTAssertFalse(win.focusClick.swallowing)
                AgentsNSWindow.xrayClicked(pane: web, in: win)   // the X-ray Button's action, on that click's up
                XCTAssertEqual(m.layout.focused, web)
                XCTAssertEqual(XrayPanels.shared.open[web]?.target.name, "web", "the drawer opens for web")
                win.sendEvent(try paneFocusMouse(.leftMouseUp, try xrayHeaderPoint(m, win, web), win))
            }
        }
    }

    @MainActor
    func xrayHeaderPoint(_ m: AgentWindowModel, _ win: AgentsNSWindow, _ web: UUID) throws -> CGPoint {
        let area = try XCTUnwrap(m.paneAreaFrame(in: win.contentLayoutRect.size))
        let f = try XCTUnwrap(m.paneFrames(in: CGRect(origin: .zero, size: area.size))[web])
        let h = headerPoint(.xray, in: f)
        return CGPoint(x: area.minX + h.x, y: area.minY + h.y)
    }

    /// Red at base: the down on web's "..." is swallowed. The "..." of the header it opens on (the pane-menu model, no
    /// menu popped) is on, holds web's pane items, and its Zoom runs on web.
    @MainActor
    func testHeaderFirstClickOnMenuFocusesAndActs() throws {
        try xrayButtonSeams([1, 78, 0]) { _ in
            try xrayButtonSplit { m, win, _, web in
                try headerFirstClick(.menu, m, win, web: web)
                m.focusPane(web)   // the state the passing down leaves (headerFirstClick refocused api for its body leg)
                let items = AgentWindowControls.paneMenu(m, pane: web)
                XCTAssertFalse(AgentSessionMenuButton.disabled(ended: false, entries: items), "the \"...\" is on")
                let zoom = try XCTUnwrap(items.compactMap { e -> AgentPaneVerb? in
                    if case let .pane(t, true, v) = e, t == "Zoom" { return v } else { return nil }
                }.first)
                AgentWindowControls.runPane(zoom, pane: web, in: m)
                XCTAssertEqual(m.layout.zoomed, web, "its Zoom acts on web")
            }
        }
    }

    /// Red at base: the down on web's title chip is swallowed. The chip's list (its seam) picks into web.
    @MainActor
    func testHeaderFirstClickOnTitleChipFocusesAndActs() throws {
        try paneSwitcherModel(["api", "web", "db"], targets: ["api", "web"]) { m, panes in
            let web = try XCTUnwrap(panes.last)
            let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            try headerFirstClick(.chip, m, win, web: web)
            m.focusPane(web)
            var dismissed = 0
            let list = AgentPaneSwitcherList.of(AgentPaneSwitch(model: m, pane: web), dismiss: { dismissed += 1 })
            list.query = "db"
            XCTAssertTrue(list.command(#selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(dismissed, 1, "the pick closes the list")
            XCTAssertEqual(paneSwitcherName(m, web), "db", "the pick goes into web")
            XCTAssertEqual(m.layout.focused, web)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }
}
