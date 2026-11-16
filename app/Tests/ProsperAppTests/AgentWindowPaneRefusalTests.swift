import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 6b2c), gate-on only, each with a gate-off row. testPaneFocusDivider…: a divider's left mouse-down
/// asks for key and front through the window's `raise` seam, as the focusing down does; every row that hands the window
/// a mouse-down installs a recorder there FIRST, so the real makeKeyAndOrderFront never runs. testPaneRefusal…
/// (R900-6b1-4, spec 3.3, 224): a refused split's notice is drawn in the focused pane's notice slot, a top overlay, so
/// nothing moves. Events are BUILT (NSEvent.mouseEvent) and handed to the window's own sendEvent as values: never posted,
/// never sent to the application. Windows are never shown, ordered in or made key. Accessibility flags only on this
/// process's NSApplication through AXTreeSupport, put back in a defer. Sessions are fakes; layouts save to a private
/// XCTestDefaults suite; the split gate and the UI scale are saved, set and restored in a defer (withPaneMenu,
/// withTreeGate). Every row and every closure in it runs on the main actor.
extension AgentWindowD1Tests {
    // MARK: Item 1, the divider's down

    /// Gate on, two panes, a window that is not key (never shown): a down on the divider (inside the unfocused pane's
    /// frame) is the divider's and asks for key and front once; its drags and its up ask nothing; the next down on the
    /// divider asks once more (once per down, the window still not key).
    @MainActor
    func testPaneFocusDividerDownAsksForKeyAndFrontOnce() throws {
        try withPaneMenu(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let focused = m.layout.focused
            let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 900), styleMask: [.titled],
                                     backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            var raised: [NSWindow] = []
            win.raise = { raised.append($0) }   // the recorder first: the real call never runs
            let size = win.contentLayoutRect.size
            let a = try XCTUnwrap(m.paneAreaFrame(in: size))
            let line = try XCTUnwrap(m.dividers(in: a.size).first).line
            let p = CGPoint(x: a.minX + line.midX, y: a.minY + 300)
            let writes = m.layoutWrites
            win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
            XCTAssertTrue(m.dividerDrag != nil, "the divider took the down")
            XCTAssertEqual(m.layout.focused, focused, "not the first-click rule: nothing focused")
            XCTAssertEqual(raised.count, 1, "asked for key and front once")
            XCTAssertTrue(raised.first === win, "for this window")
            win.sendEvent(try paneFocusMouse(.leftMouseDragged, CGPoint(x: p.x + 50, y: p.y), win))
            win.sendEvent(try paneFocusMouse(.leftMouseDragged, CGPoint(x: p.x + 60, y: p.y), win))
            XCTAssertEqual(raised.count, 1, "the moves ask nothing")
            win.sendEvent(try paneFocusMouse(.leftMouseUp, CGPoint(x: p.x + 60, y: p.y), win))
            XCTAssertTrue(m.dividerDrag == nil, "the up ended the drag")
            XCTAssertEqual(raised.count, 1, "the up asks nothing")
            XCTAssertEqual(m.layoutWrites, writes + 1, "the drag saved once")
            let moved = try XCTUnwrap(m.dividers(in: a.size).first).line
            let q = CGPoint(x: a.minX + moved.midX, y: a.minY + 300)
            win.sendEvent(try paneFocusMouse(.leftMouseDown, q, win))
            XCTAssertEqual(raised.count, 2, "the next down asks once more")
            win.sendEvent(try paneFocusMouse(.leftMouseUp, q, win))
            XCTAssertEqual(raised.count, 2)
            XCTAssertEqual(m.layout.focused, focused)
            XCTAssertFalse(win.isVisible, "never shown")
            XCTAssertFalse(win.isKeyWindow, "never key")
        }
    }

    /// "The window is key" reaches the divider's decision as a value (the window passes its isKeyWindow): a key window is
    /// never asked; of a divider's events only the down asks.
    @MainActor
    func testPaneFocusDividerKeyWindowIsNotAsked() {
        for (type, down) in [(NSEvent.EventType.leftMouseDown, true), (.leftMouseDragged, false), (.leftMouseUp, false)] {
            XCTAssertFalse(AgentsNSWindow.asksKey(focusing: type == .leftMouseDown, isKey: true), "key: \(type.rawValue)")
            XCTAssertEqual(AgentsNSWindow.asksKey(focusing: type == .leftMouseDown, isKey: false), down, "\(type.rawValue)")
        }
    }

    /// GATE OFF: no divider. A down, a drag and an up where the divider would be with the gate on pass as today: nothing
    /// taken, nothing swallowed, nothing written, the recorder never called; the down reached the focusing code (the
    /// panes take the keys, today's rule).
    @MainActor
    func testPaneFocusDividerGateOffAsksNothing() throws {
        var p = CGPoint.zero
        let size = CGSize(width: 1600, height: 900)
        let l = paneLayout([paneTarget("api"), paneTarget("web")])
        try withPaneMenu(true) {   // the divider's point as it would be drawn with the gate on
            let probe = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { probe.close() }
            probe.adopt(l)
            let a = try XCTUnwrap(probe.paneAreaFrame(in: size))
            let line = try XCTUnwrap(probe.dividers(in: a.size).first).line
            p = CGPoint(x: a.minX + line.midX, y: a.minY + 300)
        }
        try withPaneMenu(false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(l)
            let start = m.layout
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
            XCTAssertTrue(m.dividerDrag == nil, "gate off: no divider")
            XCTAssertFalse(win.focusClick.swallowing, "gate off: the down passes")
            XCTAssertEqual(m.keyFocus, .pane, "today's: the down reached the focusing code")
            win.sendEvent(try paneFocusMouse(.leftMouseDragged, CGPoint(x: p.x + 50, y: p.y), win))
            win.sendEvent(try paneFocusMouse(.leftMouseUp, CGPoint(x: p.x + 50, y: p.y), win))
            XCTAssertEqual(raised, 0, "gate off: never asked")
            XCTAssertEqual(m.layout, start, "nothing moved, nothing focused")
            XCTAssertEqual(m.layoutWrites, writes, "nothing written")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: Item 2, R900-6b1-4: the pane refusal drawn

    /// Every node that reads `text` sits in pane `index` of `n` (its container's frame holds the node's centre) and in no
    /// other; at least one does. Frames are the AX client's (one window, one space).
    @MainActor
    func paneRefusalOnlyIn(_ tree: [AXTreeNode], _ text: String, index: Int, of n: Int, line: UInt = #line) {
        let shown = tree.filter { $0.reads(text) }
        let boxes = (1...max(1, n)).map { i in tree.first { !$0.ignored && $0.label.hasSuffix(", pane \(i) of \(n)") }?.frame }
        XCTAssertFalse(shown.isEmpty, "the refusal is drawn", line: line)
        XCTAssertEqual(boxes.compactMap { $0 }.count, n, "every pane is a container", line: line)
        for node in shown {
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            let inside = boxes.indices.filter { boxes[$0]?.contains(c) == true }.map { $0 + 1 }
            XCTAssertEqual(inside, [index], "in pane \(index) only: \(node.frame) in \(boxes)", line: line)
        }
    }

    /// The frame of the empty pane's "Select a session" in pane `index` of `n` (the slot's content under the overlay).
    @MainActor
    func paneRefusalBody(_ tree: [AXTreeNode], index: Int, of n: Int) -> CGRect? {
        guard let box = tree.first(where: { !$0.ignored && $0.label.hasSuffix(", pane \(index) of \(n)") })?.frame else { return nil }
        return tree.first { $0.reads("Select a session") && box.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }?.frame
    }

    /// Two measured snapshots (paneSnapshot, bandSnapshot) hold the same parts at the same frames.
    func paneRefusalSame(_ a: [String: CGRect], _ b: [String: CGRect], _ why: String, line: UInt = #line) {
        XCTAssertFalse(a.isEmpty, "\(why): measured", line: line)
        XCTAssertEqual(Set(a.keys), Set(b.keys), "\(why): the same parts", line: line)
        for (k, r) in a { assertSame(r, b[k], "\(why) \(k)", line: line) }
    }

    /// Gate on, six panes at 1600 x 900 (all tiled), the focused one empty (the cap's commonest case: ⌘D again from the new
    /// empty pane): the 7th split is refused and its notice is drawn in that pane's slot and in no other; every pane part
    /// and band slot is where it was; a landed focus key (⌘] through perform) clears it and the line is gone.
    @MainActor
    func testPaneRefusalCapIsDrawnInTheNamedPaneOnly() throws {
        let restoreModes = transcriptMode(["api"])
        defer { restoreModes() }
        try withPaneMenu(true) {
            let size = CGSize(width: 1600, height: 900)
            let m = windowModel(store([session("api", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), nil, nil, nil, nil, nil]))
            let named = try XCTUnwrap(m.layout.order.last)
            m.focusPane(named)
            XCTAssertEqual(m.layout.focused, named)
            let index = try XCTUnwrap(m.layout.order.firstIndex(of: named)) + 1
            let text = try XCTUnwrap(PaneRefusal.cap.notice)
            let panesBefore = paneSnapshot(m, size), bandBefore = bandSnapshot(m, size)
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
            defer { win.contentView = nil; win.close() }
            let before = AXTreeSupport.poll(host) { paneRefusalBody($0, index: index, of: 6) != nil }
            XCTAssertFalse(before.contains { $0.reads(text) }, "nothing refused yet")
            let body = try XCTUnwrap(paneRefusalBody(before, index: index, of: 6), "the empty pane's text")
            XCTAssertTrue(m.perform(.split(.columns)), "refused: swallowed, its notice kept")
            XCTAssertEqual(m.paneRefusal, .cap)
            XCTAssertEqual(m.layout.panes.count, 6)
            let tree = AXTreeSupport.poll(host) { $0.contains { $0.reads(text) } }
            paneRefusalOnlyIn(tree, text, index: index, of: 6)
            XCTAssertEqual(paneRefusalBody(tree, index: index, of: 6), body, "an overlay: the pane's own content did not move")
            paneRefusalSame(panesBefore, paneSnapshot(m, size), "pane parts")
            paneRefusalSame(bandBefore, bandSnapshot(m, size), "band slots")
            XCTAssertTrue(m.perform(.cycle(1)), "a landed focus key")
            XCTAssertTrue(m.paneRefusal == nil, "the model cleared it")
            let gone = AXTreeSupport.poll(host) { !$0.contains { $0.reads(text) } }
            XCTAssertFalse(gone.contains { $0.reads(text) }, "the line is gone with it")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Gate on, two Transcript panes at 1000 x 680: a split right of the focused session pane leaves halves below 300·s,
    /// so it is refused; the "No room" notice is drawn in that pane's notice line (over its transcript) and not in the
    /// other pane; nothing moves; a landed pick (the other pane's session: it focuses that pane) clears it.
    @MainActor
    func testPaneRefusalNoRoomIsDrawnInTheFocusedSessionPane() throws {
        let restoreModes = transcriptMode(["api", "web"])
        defer { restoreModes() }
        try withPaneMenu(true) {
            let size = CGSize(width: 1000, height: 680)
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let named = m.layout.focused
            let index = try XCTUnwrap(m.layout.order.firstIndex(of: named)) + 1
            let text = try XCTUnwrap(PaneRefusal.noRoom.notice)
            let panesBefore = paneSnapshot(m, size), bandBefore = bandSnapshot(m, size)
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
            defer { win.contentView = nil; win.close() }
            let before = AXTreeSupport.poll(host) { $0.contains { $0.label.hasSuffix(", pane 2 of 2") } }
            XCTAssertFalse(before.contains { $0.reads(text) }, "nothing refused yet")
            XCTAssertGreaterThan(m.paneArea.width, 0, "the view fed the pane area")
            XCTAssertTrue(m.perform(.split(.columns)), "refused: swallowed, its notice kept")
            XCTAssertEqual(m.paneRefusal, .noRoom)
            XCTAssertEqual(m.layout.panes.count, 2)
            let tree = AXTreeSupport.poll(host) { $0.contains { $0.reads(text) } }
            paneRefusalOnlyIn(tree, text, index: index, of: 2)
            paneRefusalSame(panesBefore, paneSnapshot(m, size), "pane parts")
            paneRefusalSame(bandBefore, bandSnapshot(m, size), "band slots")
            m.select(live("web"))
            XCTAssertNotEqual(m.layout.focused, named, "the pick focused web's pane")
            XCTAssertTrue(m.paneRefusal == nil, "the model cleared it")
            let gone = AXTreeSupport.poll(host) { !$0.contains { $0.reads(text) } }
            XCTAssertFalse(gone.contains { $0.reads(text) }, "the line is gone with it")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// GATE OFF: a refusal left from before the gate went off (nothing observes the gate) draws nothing: one pane, its
    /// notice slot empty, its parts where a model with no refusal has them.
    @MainActor
    func testPaneRefusalGateOffDrawsNothing() throws {
        let restoreModes = transcriptMode(["api"])
        defer { restoreModes() }
        let size = CGSize(width: 1000, height: 680)
        try withPaneMenu(true) {
            let m = windowModel(store([session("api", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api")]))
            m.select(live("api"))
            m.paneArea = CGRect(x: 0, y: 0, width: 400, height: 600)   // halves of 200 < 300: no room
            XCTAssertTrue(m.perform(.split(.columns)))
            XCTAssertEqual(m.paneRefusal, .noRoom)
            let text = try XCTUnwrap(PaneRefusal.noRoom.notice)
            let twin = windowModel(store([session("api", .idle)]), layouts: layoutSuite())
            twin.setVisible(true)
            defer { twin.close() }
            twin.adopt(paneLayout([paneTarget("api")]))
            twin.select(live("api"))
            try withTreeGate(false) {
                let title = try XCTUnwrap(m.row(live("api"))?.title)
                let restoreAX = AXTreeSupport.axOn()
                defer { restoreAX() }
                let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
                defer { win.contentView = nil; win.close() }
                let tree = AXTreeSupport.poll(host) { t in t.contains { $0.reads(title) } }
                XCTAssertTrue(tree.contains { $0.reads(title) }, "the tree was read")
                XCTAssertFalse(tree.contains { $0.reads(text) }, "gate off: nothing drawn")
                XCTAssertFalse(tree.contains { $0.label.contains(", pane ") }, "one pane: no container")
                XCTAssertTrue(m.paneRefusal == .noRoom, "the model's value is untouched")
                paneRefusalSame(paneSnapshot(twin, size), paneSnapshot(m, size), "gate off: the parts of a model with no refusal")
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }

    // MARK: Step 6b2d, R900-6b2c-1: a focus change drops the refusal (spec 3.1 :224)

    /// A refused split on `m` with no view: the model's own pane area `width` wide (700: two panes of 350 whose halves
    /// are under 300; 400: one pane of 400, halves of 200), so `.noRoom`.
    @MainActor
    func paneRefusalRefuse(_ m: AgentWindowModel, width: CGFloat = 700, line: UInt = #line) {
        m.paneArea = CGRect(x: 0, y: 0, width: width, height: 600)
        XCTAssertTrue(m.perform(.split(.columns)), "refused: swallowed", line: line)
        XCTAssertEqual(m.paneRefusal, .noRoom, line: line)
    }

    /// Gate on, two Transcript panes at 1000 x 680: the refusal is drawn in the focused pane; a focusing click on the
    /// other pane (a BUILT left mouse-down and up handed to an unshown window's sendEvent, the raise recorder installed
    /// first) moves the focus, the model drops the refusal and the line is gone from the tree.
    @MainActor
    func testPaneRefusalFocusingClickDropsIt() throws {
        let restoreModes = transcriptMode(["api", "web"])
        defer { restoreModes() }
        try withPaneMenu(true) {
            let size = CGSize(width: 1000, height: 680)
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let other = try XCTUnwrap(m.layout.order.last)
            let text = try XCTUnwrap(PaneRefusal.noRoom.notice)
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            let (shown, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
            defer { shown.contentView = nil; shown.close() }
            _ = AXTreeSupport.poll(host) { $0.contains { $0.label.hasSuffix(", pane 2 of 2") } }
            XCTAssertTrue(m.perform(.split(.columns)), "refused: swallowed")
            XCTAssertEqual(m.paneRefusal, .noRoom)
            paneRefusalOnlyIn(AXTreeSupport.poll(host) { $0.contains { $0.reads(text) } }, text, index: 1, of: 2)
            let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 900), styleMask: [.titled],
                                     backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            var raised = 0
            win.raise = { _ in raised += 1 }   // the recorder first: the real call never runs
            let p = try paneFocusCentre(m, other, in: win.contentLayoutRect.size)
            win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
            win.sendEvent(try paneFocusMouse(.leftMouseUp, p, win))
            XCTAssertEqual(m.layout.focused, other, "the click focused the other pane")
            XCTAssertEqual(raised, 1, "asked through the recorder only")
            XCTAssertTrue(m.paneRefusal == nil, "a focus change drops the refusal")
            let gone = AXTreeSupport.poll(host) { !$0.contains { $0.reads(text) } }
            XCTAssertFalse(gone.contains { $0.reads(text) }, "the line is gone with it")
            XCTAssertFalse(win.isVisible || shown.isVisible, "never shown")
        }
    }

    /// Gate on, model calls (no view, no event): Close Pane (the focused one: the sibling takes the focus; the other one:
    /// the panes change, the focus stays), Pick Another on the other pane and a layout switch each drop the refusal;
    /// Pick Another and focusPane on the pane already focused change neither the focus nor the panes and keep it.
    @MainActor
    func testPaneRefusalCloseAndPickAnotherAndLayoutSwitchDropIt() throws {
        let cases: [(why: String, drops: Bool, act: @MainActor (AgentWindowModel, UUID) -> Void)] = [
            ("Close Pane, the focused one", true, { m, _ in m.closePane(m.layout.focused) }),
            ("Close Pane, the other one", true, { m, other in m.closePane(other) }),
            ("Pick Another, the other pane", true, { m, other in m.pickAnother(other) }),
            ("a layout switch", true, { m, _ in m.adopt(self.paneLayout([self.paneTarget("api")])) }),
            ("Pick Another, the focused pane", false, { m, _ in m.pickAnother(m.layout.focused) }),
            ("focusPane, the focused pane", false, { m, _ in m.focusPane(m.layout.focused) }),
        ]
        try withPaneMenu(true) {
            for c in cases {
                let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
                m.setVisible(true)
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                let other = try XCTUnwrap(m.layout.order.last)
                paneRefusalRefuse(m)
                c.act(m, other)
                XCTAssertEqual(m.paneRefusal, c.drops ? nil : PaneRefusal.noRoom, c.why)
            }
        }
    }

    /// Gate on: a divider drag (BUILT down, move and up handed to an unshown window's sendEvent, the recorder first)
    /// changes the ratios only, neither the focus nor the panes; spec 3.1 moves the focus on a click, the keys, a split,
    /// a close or a layout switch, never on a drag: the refusal is kept.
    @MainActor
    func testPaneRefusalDividerDragKeepsIt() throws {
        try withPaneMenu(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            paneRefusalRefuse(m)
            let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 900), styleMask: [.titled],
                                     backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            var raised = 0
            win.raise = { _ in raised += 1 }   // the recorder first: the real call never runs
            let a = try XCTUnwrap(m.paneAreaFrame(in: win.contentLayoutRect.size))
            let line = try XCTUnwrap(m.dividers(in: a.size).first).line
            let p = CGPoint(x: a.minX + line.midX, y: a.minY + 300)
            let before = m.layout
            win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
            win.sendEvent(try paneFocusMouse(.leftMouseDragged, CGPoint(x: p.x + 50, y: p.y), win))
            win.sendEvent(try paneFocusMouse(.leftMouseUp, CGPoint(x: p.x + 50, y: p.y), win))
            XCTAssertNotEqual(m.layout, before, "the drag moved the divider")
            XCTAssertEqual(m.layout.focused, before.focused, "the focus stayed")
            XCTAssertEqual(m.layout.order, before.order, "the panes stayed")
            XCTAssertEqual(m.paneRefusal, .noRoom, "a drag keeps the refusal")
            XCTAssertEqual(raised, 1, "the divider's down asked through the recorder only")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// GATE OFF: a refusal left from before the gate went off. The same click (where the other pane is with the gate on)
    /// focuses nothing (one pane shown) and asks nothing; Pick Another, Close Pane and a layout switch move the focus or
    /// the panes and leave the value untouched (the clear is gate-on only: no write, no publish); nothing is drawn.
    @MainActor
    func testPaneRefusalGateOffFocusChangesLeaveTheValue() throws {
        let restoreModes = transcriptMode(["api", "web"])
        defer { restoreModes() }
        let size = CGSize(width: 1600, height: 900)
        let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
        m.setVisible(true)
        defer { m.close() }
        var p = CGPoint.zero, other = UUID()
        try withPaneMenu(true) {
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            other = try XCTUnwrap(m.layout.order.last)
            p = try paneFocusCentre(m, other, in: size)
            paneRefusalRefuse(m)
        }
        try withPaneMenu(false) {
            let focused = m.layout.focused
            let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                                     backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            var raised = 0
            win.raise = { _ in raised += 1 }
            XCTAssertEqual(win.contentLayoutRect.size, size)
            win.sendEvent(try paneFocusMouse(.leftMouseDown, p, win))
            win.sendEvent(try paneFocusMouse(.leftMouseUp, p, win))
            XCTAssertEqual(m.layout.focused, focused, "gate off: one pane shown, the click focuses nothing")
            XCTAssertEqual(raised, 0, "gate off: never asked")
            XCTAssertTrue(m.paneRefusal == .noRoom, "after the click: untouched")
            m.pickAnother(other)
            XCTAssertEqual(m.layout.focused, other, "Pick Another moved the focus")
            XCTAssertTrue(m.paneRefusal == .noRoom, "after Pick Another: untouched")
            m.closePane(focused)
            XCTAssertEqual(m.layout.panes.count, 1, "Close Pane changed the panes")
            XCTAssertTrue(m.paneRefusal == .noRoom, "after Close Pane: untouched")
            m.adopt(paneLayout([paneTarget("api")]))
            XCTAssertTrue(m.paneRefusal == .noRoom, "after a layout switch: untouched")
            let title = try XCTUnwrap(m.row(live("api"))?.title)
            let text = try XCTUnwrap(PaneRefusal.noRoom.notice)
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            let (shown, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), CGSize(width: 1000, height: 680))
            defer { shown.contentView = nil; shown.close() }
            let tree = AXTreeSupport.poll(host) { t in t.contains { $0.reads(title) } }
            XCTAssertTrue(tree.contains { $0.reads(title) }, "the tree was read")
            XCTAssertFalse(tree.contains { $0.reads(text) }, "gate off: nothing drawn")
            XCTAssertFalse(win.isVisible || shown.isVisible, "never shown")
        }
    }

    // MARK: Step 6b2d, R900-6b2c-2: History, the 4.2 placeholder and Terminal mode; the History question's slot

    /// Gate on, two panes at 1000 x 680, the focused (first) one a History record, a 4.2 placeholder (a session that is
    /// not running) or a Terminal-mode session: a refused split's notice is drawn in that pane only (a top overlay), and
    /// every pane part and band slot is where it was.
    @MainActor
    func testPaneRefusalIsDrawnInHistoryPlaceholderAndTerminalPanes() throws {
        let restoreModes = transcriptMode(["web"])   // "api" opens in Terminal
        defer { restoreModes() }
        let h = record("h")
        let cases: [(why: String, first: PaneTarget?)] = [
            ("History", nil), ("4.2 placeholder", paneTarget("gone")), ("Terminal mode", paneTarget("api")),
        ]
        try withPaneMenu(true) {
            let size = CGSize(width: 1000, height: 680)
            let text = try XCTUnwrap(PaneRefusal.noRoom.notice)
            for c in cases {
                let m = windowModel(store([session("api", .idle), session("web", .idle)], history: [h]), layouts: layoutSuite())
                m.setVisible(true)
                defer { m.close() }
                m.adopt(paneLayout([c.first, paneTarget("web")]))
                if c.first == nil { m.select(.history(h.id)) }
                XCTAssertEqual(m.layout.order.first, m.layout.focused, c.why)
                let kind = m.selectedRow?.record != nil ? "History"
                    : AgentPanePlaceholder.title(m.content) != nil ? "4.2 placeholder" : "Terminal mode"
                XCTAssertEqual(kind, c.why, "the focused pane holds that content")
                let panesBefore = paneSnapshot(m, size), bandBefore = bandSnapshot(m, size)
                let restoreAX = AXTreeSupport.axOn()
                defer { restoreAX() }
                let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
                defer { win.contentView = nil; win.close() }
                let before = AXTreeSupport.poll(host) { $0.contains { $0.label.hasSuffix(", pane 2 of 2") } }
                XCTAssertFalse(before.contains { $0.reads(text) }, "\(c.why): nothing refused yet")
                XCTAssertTrue(m.perform(.split(.columns)), "\(c.why): refused, swallowed")
                XCTAssertEqual(m.paneRefusal, .noRoom, c.why)
                let tree = AXTreeSupport.poll(host) { $0.contains { $0.reads(text) } }
                paneRefusalOnlyIn(tree, text, index: 1, of: 2)
                paneRefusalSame(panesBefore, paneSnapshot(m, size), "\(c.why): pane parts")
                paneRefusalSame(bandBefore, bandSnapshot(m, size), "\(c.why): band slots")
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }

    /// Gate on, two panes at 1000 x 680, the focused one a History record with its Remove question open (asked through
    /// the model; only ever cancelled): a refused split leaves the strip at its frame and draws no refusal (the question
    /// holds the slot); the question cancelled, the refusal is drawn in that pane's slot.
    @MainActor
    func testPaneRefusalHistoryQuestionKeepsItsSlot() throws {
        let restoreModes = transcriptMode(["web"])
        defer { restoreModes() }
        try withPaneMenu(true) {
            let size = CGSize(width: 1000, height: 680)
            let h = record("h")
            let st = store([session("web", .idle)], history: [h])
            let m = windowModel(st, layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([nil, paneTarget("web")]))
            m.select(.history(h.id))
            m.act(.remove, h)
            XCTAssertEqual(m.confirming, AgentWindowConfirm(verb: .remove, key: h.id), "the question is open")
            let question = AgentWindowControls.removeQuestion(h, in: st.history)
            let text = try XCTUnwrap(PaneRefusal.noRoom.notice)
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
            defer { win.contentView = nil; win.close() }
            let before = AXTreeSupport.poll(host) { $0.contains { $0.reads(question) } }
            let strip = try XCTUnwrap(before.first { $0.reads(question) }?.frame, "the strip is drawn")
            XCTAssertTrue(m.perform(.split(.columns)), "refused: swallowed")
            XCTAssertEqual(m.paneRefusal, .noRoom)
            XCTAssertTrue(m.confirming != nil, "the question stays open")
            let tree = AXTreeSupport.poll(host) { $0.contains { $0.reads(question) } }   // one pass pumps the run loop first
            assertSame(tree.first { $0.reads(question) }?.frame, strip, "the strip did not move")
            XCTAssertFalse(tree.contains { $0.reads(text) }, "the question holds the slot: no refusal drawn")
            m.confirm(false)   // Cancel: runs nothing
            XCTAssertTrue(m.confirming == nil, "the question is closed")
            XCTAssertEqual(m.paneRefusal, .noRoom, "cancel keeps the refusal")
            let after = AXTreeSupport.poll(host) { $0.contains { $0.reads(text) } }
            XCTAssertFalse(after.contains { $0.reads(question) }, "the strip is gone")
            paneRefusalOnlyIn(after, text, index: 1, of: 2)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// GATE OFF: one History pane with its Remove question open and a refusal left from before the gate went off: the
    /// strip's frame is its frame on a twin with no refusal, and no refusal text is drawn.
    @MainActor
    func testPaneRefusalGateOffHistoryStripIsWhereItWas() throws {
        let size = CGSize(width: 1000, height: 680)
        let h = record("h")
        var models: [AgentWindowModel] = []
        defer { models.forEach { $0.close() } }
        try withPaneMenu(true) {
            for refused in [true, false] {
                let m = windowModel(store([session("web", .idle)], history: [h]), layouts: layoutSuite())
                m.setVisible(true)
                models.append(m)
                m.select(.history(h.id))
                m.act(.remove, h)
                if refused { paneRefusalRefuse(m, width: 400) }
                XCTAssertTrue(m.confirming != nil, "the question is open (refused \(refused))")
            }
        }
        let m = try XCTUnwrap(models.first), twin = try XCTUnwrap(models.last)
        XCTAssertTrue(twin.paneRefusal == nil, "the twin has no refusal")
        let question = AgentWindowControls.removeQuestion(h, in: [h])
        let text = try XCTUnwrap(PaneRefusal.noRoom.notice)
        try withTreeGate(false) {
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            var frames: [CGRect] = []
            for model in [m, twin] {
                let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: model, scrolls: false), size)
                defer { win.contentView = nil; win.close() }
                let tree = AXTreeSupport.poll(host) { $0.contains { $0.reads(question) } }
                XCTAssertFalse(tree.contains { $0.reads(text) }, "gate off: nothing drawn")
                frames.append(try XCTUnwrap(tree.first { $0.reads(question) }?.frame, "the strip is drawn"))
                XCTAssertFalse(win.isVisible, "never shown")
            }
            XCTAssertEqual(frames.count, 2)
            assertSame(frames.first, frames.last, "gate off: the strip where a model with no refusal has it")
            XCTAssertTrue(m.paneRefusal == .noRoom, "the model's value is untouched")
        }
    }

    // MARK: Item 3, QA 1092's belt

    /// Every test file under app/Tests that turns the split gate on AND hands a window an event through sendEvent also
    /// installs the `raise` recorder. The set computed from the tree must EQUAL the literal list (a new file joins it on
    /// purpose), and each listed file assigns `.raise =`. Reads the package's own test sources only (#filePath).
    func testPaneFocusEveryGateOnSendEventFileSetsTheRecorder() throws {
        let listed: Set<String> = ["AgentWindowChapterListTests.swift", "AgentWindowKeyFocusTests.swift",
                                   "AgentWindowPaneFocusTests.swift", "AgentWindowPaneRefusalTests.swift"]
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        var found: Set<String> = [], raises: [String: Bool] = [:], read = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let s = try String(contentsOf: url, encoding: .utf8)
            read += 1
            raises[url.lastPathComponent] = s.contains(".raise =")
            // 6b2d (QA r1107): every way a file turns the gate on, the helpers that take it as a parameter included.
            let on = ["splitsEnabled = true", "withPaneMenu(true", "withTreeGate(true", "gate(true", "withSidebarRow(gate: true",
                      "splitsOn()", "splitsEnabled = row.gate"]
            if on.contains(where: { s.contains($0) }), s.contains(".sendEvent(") {
                found.insert(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(read, 100, "the test tree was read")
        XCTAssertEqual(found, listed, "gate-on files that call sendEvent")
        for f in listed.sorted() { XCTAssertEqual(raises[f], true, "\(f) installs the raise recorder") }
    }
}
