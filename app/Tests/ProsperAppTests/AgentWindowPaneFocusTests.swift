import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 6b2b): the focusing mouse-down and the first responder, gate-on only, each with a gate-off row.
/// R1196-1: the swallowed focusing down asks for key and front through the window's `raise` seam; every row that hands
/// the window a mouse-down installs a recorder there FIRST, so the real makeKeyAndOrderFront never runs. 7.2: after a
/// pane focus action the window's first responder is the focused pane's terminal (#1471: was its input box). Events are BUILT (NSEvent.mouseEvent)
/// and handed to the window's own sendEvent as values: never posted, never sent to the application. Windows are never
/// shown, ordered in or made key; makeFirstResponder runs only on them. Sessions are fakes; layouts save to a private
/// XCTestDefaults suite; the split gate and the UI scale are saved, set and restored in a defer (withPaneMenu). Every row
/// and every closure in it runs on the main actor.
extension AgentWindowD1Tests {
    /// A left mouse event at `p` in the content's top-left coordinates (the model's), for `win`'s sendEvent.
    @MainActor
    func paneFocusMouse(_ type: NSEvent.EventType, _ p: CGPoint, _ win: NSWindow) throws -> NSEvent {
        let r = win.contentLayoutRect
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: r.minX + p.x, y: r.maxY - p.y), modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// The centre of `pane`'s frame in the content of `size` (top-left origin), from the model's own geometry.
    @MainActor
    func paneFocusCentre(_ m: AgentWindowModel, _ pane: UUID, in size: CGSize) throws -> CGPoint {
        let area = try XCTUnwrap(m.paneAreaFrame(in: size))
        let f = try XCTUnwrap(m.paneFrames(in: CGRect(origin: .zero, size: area.size))[pane])
        return CGPoint(x: area.minX + f.midX, y: area.minY + f.midY)
    }

    /// Settles `host` until `done` holds, at most 40 passes of the existing settle (no new fixed wait).
    @MainActor
    func paneFocusSettle(_ host: NSView, until done: () -> Bool) {
        var n = 0
        repeat { settle(host); n += 1 } while !done() && n < 40
    }

    /// #1471: the focused pane's terminal view once its (fake) client is live, or nil (was: the window's only input box).
    @MainActor
    func paneFocusBox(_ m: AgentWindowModel) -> AgentTerminalHostView? {
        m.terminal.phase == .live ? m.terminal.view : nil
    }

    // MARK: Item 1, R1196-1

    /// Gate on, two panes, a window that is not key (never shown): a down on the unfocused pane is swallowed as before,
    /// focuses it in one write and asks for key and front once; its up asks nothing; a down on the now focused pane
    /// passes (not swallowed) and asks nothing.
    @MainActor
    func testPaneFocusSwallowedDownAsksForKeyAndFrontOnce() throws {
        try withPaneMenu(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let second = try XCTUnwrap(m.layout.order.last)
            let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 900), styleMask: [.titled],
                                     backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            var raised: [NSWindow] = []
            win.raise = { raised.append($0) }   // the recorder first: the real call never runs
            let p = try paneFocusCentre(m, second, in: win.contentLayoutRect.size)
            m.keyFocus = .sidebar
            let writes = m.layoutWrites
            win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
            XCTAssertEqual(m.layout.focused, second, "the down focused the pane")
            XCTAssertTrue(win.focusClick.swallowing, "swallowed as before")
            XCTAssertEqual(m.layoutWrites, writes + 1, "one write")
            XCTAssertEqual(raised.count, 1, "asked for key and front once")
            XCTAssertTrue(raised.first === win, "for this window")
            win.sendEvent(try paneFocusMouse(.leftMouseUp, p, win))
            XCTAssertFalse(win.focusClick.swallowing)
            XCTAssertEqual(raised.count, 1, "its up asks nothing")
            win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
            XCTAssertFalse(win.focusClick.swallowing, "a down on the focused pane passes to super")
            XCTAssertEqual(raised.count, 1, "and asks nothing")
            XCTAssertEqual(m.layout.focused, second)
            XCTAssertEqual(m.layoutWrites, writes + 1)
            XCTAssertFalse(win.isVisible, "never shown")
            XCTAssertFalse(win.isKeyWindow, "never key")
        }
    }

    /// "The window is key" reaches the decision as a value: a window that is key already is never asked again; a down
    /// that does not only focus is never asked, key or not.
    @MainActor
    func testPaneFocusKeyWindowIsNotAskedAgain() {
        XCTAssertTrue(AgentsNSWindow.asksKey(focusing: true, isKey: false))
        XCTAssertFalse(AgentsNSWindow.asksKey(focusing: true, isKey: true), "key already: nothing asked")
        XCTAssertFalse(AgentsNSWindow.asksKey(focusing: false, isKey: false), "a passing down: AppKit's own")
        XCTAssertFalse(AgentsNSWindow.asksKey(focusing: false, isKey: true))
    }

    /// GATE OFF: the decoded two-pane layout shows its focused pane alone; a down where the second pane would be and a
    /// sidebar down pass as today: nothing swallowed, nothing refocused, nothing written, the recorder never called.
    @MainActor
    func testPaneFocusGateOffDownPassesAndAsksNothing() throws {
        var p = CGPoint.zero, second = UUID()
        let size = CGSize(width: 1600, height: 900)
        let l = paneLayout([paneTarget("api"), paneTarget("web")])
        try withPaneMenu(true) {   // the second pane's centre as it would be drawn with the gate on
            let probe = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { probe.close() }
            probe.adopt(l)
            second = try XCTUnwrap(probe.layout.order.last)
            p = try paneFocusCentre(probe, second, in: size)
        }
        try withPaneMenu(false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(l)
            let first = m.layout.focused
            let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            var raised = 0
            win.raise = { _ in raised += 1 }
            XCTAssertEqual(win.contentLayoutRect.size, size)
            m.keyFocus = .sidebar
            let writes = m.layoutWrites
            win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
            XCTAssertFalse(win.focusClick.swallowing, "gate off: the down passes")
            XCTAssertEqual(m.layout.focused, first, "nothing refocused")
            XCTAssertEqual(m.keyFocus, .pane, "today's: a pane click gives the panes the keys")
            win.sendEvent(try paneFocusMouse(.leftMouseUp, p, win))
            win.sendEvent(try paneFocusMouse(.leftMouseDown, CGPoint(x: sz(100), y: 40), win))
            XCTAssertEqual(m.keyFocus, .sidebar, "a sidebar down")
            XCTAssertEqual(raised, 0, "gate off: never asked")
            XCTAssertEqual(m.layoutWrites, writes, "nothing written")
            XCTAssertEqual(m.layout.panes.count, 2, "the decoded tree is kept (15.0)")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: Item 2, the first responder follows the focused pane

    /// Gate on, two terminal panes (fake clients) hosted in a never-shown window, the keys in the focused pane's box or in the
    /// sidebar (7.2: a pane focus action gives the panes the keys): after each pane focus action (the focusing click, a
    /// pane key, the pane menu, close pane) the focused pane moved and the window's first responder is ITS box (a new
    /// view, kind .terminal; #1471: was the input box, kind .text), never the old pane's, the sidebar or the window.
    @MainActor
    func testPaneFocusResponderFollowsEveryPaneFocusAction() throws {
        try withPaneMenu(true) {
            for start in ["box", "sidebar"] { for action in ["click", "key", "menu", "close"] {
                let m = windowModel(store([session("api", .idle), session("web", .idle), session("db", .idle)]),
                                    layouts: layoutSuite())
                _ = splitTerminals(m)   // #1471: every pane terminal on a fake client, so it goes live and takes the keys
                m.setVisible(true)
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                let first = m.layout.focused, second = try XCTUnwrap(m.layout.order.last)
                let (win, host) = focusWindow(m)
                defer { win.close() }
                var raised = 0
                win.raise = { _ in raised += 1 }   // before any down: the real call never runs
                XCTAssertTrue(m.focusSelection())
                paneFocusSettle(host) { paneFocusBox(m).map { win.firstResponder === $0 } ?? false }
                let old = try XCTUnwrap(paneFocusBox(m), action)
                XCTAssertTrue(win.firstResponder === old, "\(action): the keys in api's box")
                if start == "sidebar" { sidebarKeys(win) }   // the sidebar's keys: nothing that types is first responder
                switch action {
                case "click":
                    let p = try paneFocusCentre(m, second, in: win.contentLayoutRect.size)
                    win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
                    win.sendEvent(try paneFocusMouse(.leftMouseUp, p, win))
                    XCTAssertEqual(raised, 1, "the swallowed down asked the recorder")
                case "key":
                    XCTAssertTrue(m.perform(.cycle(1)), "⌘] as the window routes it")
                case "menu":
                    AgentWindowControls.runPane(.equalize, pane: second, in: m)
                default:
                    m.closePane(first)
                }
                XCTAssertEqual(m.layout.focused, second, "\(action): the second pane is focused")
                XCTAssertEqual(m.keyFocus, .pane)
                paneFocusSettle(host) { paneFocusBox(m).map { $0 !== old && win.firstResponder === $0 } ?? false }
                let box = try XCTUnwrap(paneFocusBox(m), action)
                XCTAssertFalse(box === old, "\(action): the focused pane's box is a new view")
                XCTAssertTrue(win.firstResponder === box, "\(action): the keys followed the focused pane")
                XCTAssertEqual(win.responderKind, .terminal, "\(action): PaneKeys.Context sees the box")
                XCTAssertFalse(m.terminal.focusPending, "\(action): landed")
                XCTAssertFalse(win.isVisible, "never shown")
            } }
        }
    }

    /// #1618: gate on, two live terminal panes (fake clients) hosted in a never-shown window: a focus switch, there and
    /// back, keeps each pane's AgentTerminalHostView (the same object, so its libghostty surface: no #1615 remount) and
    /// starts or ends no client. Red at base: AgentPaneArea.pane swapped each pane's branch (AgentDetailView /
    /// AgentUnfocusedPane) with the terminal inside it, so SwiftUI made a new host view for both panes.
    @MainActor
    func testPaneFocusSwitchKeepsBothTerminalViews() throws {
        try withPaneMenu(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            let log = splitTerminals(m)
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let first = m.layout.focused, second = try XCTUnwrap(m.layout.order.last)
            final class Slots { var frames: [UUID: CGRect] = [:] }
            let slots = Slots()
            AgentPaneArea.probe = { kind, pane, r in if kind == "terminal" { slots.frames[pane] = r } }
            defer { AgentPaneArea.probe = nil }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            endRests(log)
            let views = { [first, second].compactMap { m.runtimes[$0]?.terminal?.view } }
            paneFocusSettle(host) { views().count == 2 && views().allSatisfy { $0.window === win } }
            let before = views()
            XCTAssertEqual(before.count, 2, "both panes draw a terminal view")
            XCTAssertFalse(before.first === before.last, "one view per pane")
            XCTAssertEqual(log.spawned.count, 2, "both panes attached")
            for (to, why) in [(second, "focus to web"), (first, "focus back to api")] {
                m.focusPane(to)
                XCTAssertEqual(m.layout.focused, to, why)
                paneFocusSettle(host) { false }   // every pass of the settle: the flip has drawn
                let after = views()
                XCTAssertEqual(after.count, 2, why)
                XCTAssertTrue(after.first === before.first, "\(why): api's host view kept")
                XCTAssertTrue(after.last === before.last, "\(why): web's host view kept")
                let shown = focusViews(host, AgentTerminalHostView.self)
                XCTAssertEqual(shown.count, 2, "\(why): no second view for a pane")
                XCTAssertTrue(shown.allSatisfy { v in before.contains { $0 === v } }, "\(why): the views in the window are the kept ones")
                XCTAssertEqual(log.spawned.count, 2, "\(why): no client started")
                XCTAssertEqual(log.children.values.map(\.terminated).reduce(0, +), 0, "\(why): no client ended")
                // Drawn where the branch's slot is (under the header), at its size: content top-left coordinates.
                let area = try XCTUnwrap(m.paneAreaFrame(in: win.contentLayoutRect.size), why)
                let r = win.contentLayoutRect
                for (pane, v) in zip([first, second], after) {
                    let slot = try XCTUnwrap(slots.frames[pane], "\(why): the slot's frame")
                    let f = v.convert(v.bounds, to: nil)
                    XCTAssertEqual(f.minX - r.minX, area.minX + slot.minX, accuracy: 1, "\(why): x")
                    XCTAssertEqual(r.maxY - f.maxY, area.minY + slot.minY, accuracy: 1, "\(why): y, under the header")
                    XCTAssertEqual(f.width, slot.width, accuracy: 1, "\(why): width")
                    XCTAssertEqual(f.height, slot.height, accuracy: 1, "\(why): height")
                }
            }
            XCTAssertFalse(win.isVisible, "never shown")
            XCTAssertFalse(win.isKeyWindow, "never key")
        }
    }

    /// Gate on (R900-6b1-1): open to the side and a plain click follow the same rule: the focused pane AFTER the action
    /// has the keys. Open to the side focuses the NEW pane: its box takes them, not the old pane's (which goes inert).
    @MainActor
    func testPaneFocusOpenToTheSideGivesTheNewPaneTheKeys() throws {
        try withPaneMenu(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle), session("db", .idle)]),
                                layouts: layoutSuite())
            _ = splitTerminals(m)   // #1471: every pane terminal on a fake client
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api")]))
            let (win, host) = focusWindow(m)
            defer { win.close() }
            var raised = 0
            win.raise = { _ in raised += 1 }
            XCTAssertTrue(m.focusSelection())
            paneFocusSettle(host) { paneFocusBox(m).map { win.firstResponder === $0 } ?? false }
            let old = try XCTUnwrap(paneFocusBox(m))
            XCTAssertTrue(win.firstResponder === old)
            let before = m.layout.focused
            m.openToTheSide(live("web"))
            XCTAssertEqual(m.layout.panes.count, 2, "opened to the side: \(String(describing: m.paneRefusal))")
            XCTAssertNotEqual(m.layout.focused, before, "the new pane is focused")
            paneFocusSettle(host) { paneFocusBox(m).map { $0 !== old && win.firstResponder === $0 } ?? false }
            let box = try XCTUnwrap(paneFocusBox(m))
            XCTAssertFalse(box === old)
            XCTAssertTrue(win.firstResponder === box, "the new pane's box has the keys")
            XCTAssertEqual(win.responderKind, .terminal)
            XCTAssertEqual(m.selection, live("web"))
            // A plain click on db's row: into the focused (new) pane, the keys stay in its box (the same rule).
            m.click(live("db"))
            paneFocusSettle(host) { paneFocusBox(m).map { win.firstResponder === $0 } ?? false }
            XCTAssertEqual(m.selection, live("db"))
            XCTAssertEqual(win.responderKind, .terminal, "a plain click: the focused pane's box")
            XCTAssertEqual(raised, 0, "no down was handed to the window")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// GATE OFF: today's values. The decoded two-pane layout shows its focused pane alone: a plain row click and an
    /// Option-click (the plain click with the gate off) put the keys in the shown pane's box as today, nothing is
    /// pending, and no focus move asks anything (the pane-area down with the gate off is the item 1 gate-off row's).
    @MainActor
    func testPaneFocusGateOffResponderAsToday() throws {
        try withPaneMenu(false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle), session("db", .idle)]),
                                layouts: layoutSuite())
            _ = fakeTerminal(m)   // #1471: gate off, the window's terminal on a fake client
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let first = m.layout.focused
            let (win, host) = focusWindow(m)
            defer { win.close() }
            var raised = 0
            win.raise = { _ in raised += 1 }
            XCTAssertTrue(m.focusSelection())
            paneFocusSettle(host) { paneFocusBox(m).map { win.firstResponder === $0 } ?? false }
            let box = try XCTUnwrap(paneFocusBox(m))
            XCTAssertTrue(win.firstResponder === box)
            m.click(live("db"))
            paneFocusSettle(host) { paneFocusBox(m).map { win.firstResponder === $0 } ?? false }
            XCTAssertEqual(m.layout.focused, first, "the plain click fills the focused pane")
            XCTAssertEqual(win.responderKind, .terminal, "today's: the box has the keys")
            m.click(live("api"), flags: .option)
            paneFocusSettle(host) { paneFocusBox(m).map { win.firstResponder === $0 } ?? false }
            XCTAssertEqual(m.layout.focused, first, "gate off: Option-click is the plain click")
            XCTAssertEqual(m.layout.panes.count, 2)
            XCTAssertEqual(m.selection, live("api"))
            XCTAssertEqual(win.responderKind, .terminal)
            XCTAssertFalse(m.terminal.focusPending)
            // A focus move the model writes with the gate off (a layout switch's adopt) asks no responder change.
            let second = try XCTUnwrap(m.layout.order.last), asks = win.responderAsks
            m.adopt(try m.layout.focus(second).get())
            XCTAssertEqual(win.responderAsks, asks, "gate off: the keys are not moved by a focus change")
            XCTAssertFalse(m.terminal.focusPending)
            XCTAssertEqual(raised, 0, "gate off: never asked")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }
}
