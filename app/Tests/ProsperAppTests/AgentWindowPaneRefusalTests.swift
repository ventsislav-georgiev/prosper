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

    // MARK: Item 3, QA 1092's belt

    /// Every test file under app/Tests that turns the split gate on AND hands a window an event through sendEvent also
    /// installs the `raise` recorder. The set computed from the tree must EQUAL the literal list (a new file joins it on
    /// purpose), and each listed file assigns `.raise =`. Reads the package's own test sources only (#filePath).
    func testPaneFocusEveryGateOnSendEventFileSetsTheRecorder() throws {
        let listed: Set<String> = ["AgentWindowKeyFocusTests.swift", "AgentWindowPaneFocusTests.swift",
                                   "AgentWindowPaneRefusalTests.swift"]
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        var found: Set<String> = [], raises: [String: Bool] = [:], read = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let s = try String(contentsOf: url, encoding: .utf8)
            read += 1
            raises[url.lastPathComponent] = s.contains(".raise =")
            if s.contains("splitsEnabled = true") || s.contains("withPaneMenu(true"), s.contains(".sendEvent(") {
                found.insert(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(read, 100, "the test tree was read")
        XCTAssertEqual(found, listed, "gate-on files that call sendEvent")
        for f in listed.sorted() { XCTAssertEqual(raises[f], true, "\(f) installs the raise recorder") }
    }
}
