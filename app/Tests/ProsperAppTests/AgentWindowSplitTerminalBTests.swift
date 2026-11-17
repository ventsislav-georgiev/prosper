import XCTest
@testable import ProsperApp

/// #1477 part b (spec 15 C, 7.6, 11.2, 11.3): the wheel and the first click on an unfocused terminal pane, the kept frame
/// on zoom-away, the cap of 4 attached clients, one client per session, and the divider drag's one re-grid per pane.
/// Fakes only: every pane terminal is on `splitTerminals` recorders (no dch, no pty, no libghostty surface); the wheel is a
/// built NSEvent handed to the view's own method (never posted); no window is made.
extension AgentWindowD1Tests {
    /// #1477: a row that pins the gate-off (one pane) behaviour turns the gate off; restored at teardown.
    @MainActor
    func splitsOff() {
        let saved = AgentPaneLayout.splitsEnabled
        AgentPaneLayout.splitsEnabled = false
        addTeardownBlock { @MainActor in AgentPaneLayout.splitsEnabled = saved }
    }

    /// Two local terminal panes "a" (focused) and "b", both attached (the rest run by hand).
    @MainActor
    func twoAttached() throws -> (m: AgentWindowModel, log: SplitTerminalLog) {
        let m = windowModel(store([session("a", .idle), session("b", .idle)]))
        let log = splitTerminals(m)
        m.paneArea = Self.wideArea
        m.adopt(paneLayout([paneTarget("a"), paneTarget("b")]))
        m.setVisible(true)
        Self.drainMain()
        endRests(log)
        XCTAssertEqual(log.spawned, ["a", "b"])
        return (m, log)
    }

    /// A one-notch wheel, built (never posted): `lines` up positive.
    func wheelEvent(_ lines: Int32) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// The attached clients of every pane terminal.
    @MainActor
    func attachedCount(_ m: AgentWindowModel) -> Int {
        m.runtimes.values.compactMap(\.terminal).filter { $0.key != nil }.count + (m.windowTerminal.key != nil ? 1 : 0)
    }

    /// R6.10 (7.6): the wheel over an UNFOCUSED terminal pane becomes scroll_page_lines on that pane's surface and never
    /// reaches the mouse path; its fake pty gets 0 bytes, no size, and the pane does not take focus. The focused pane's
    /// wheel still goes to the mouse path (libghostty), with no scrollback action.
    @MainActor
    func testAgentWindowSplitTerminalWheelOnAnUnfocusedPaneScrollsItsScrollbackOnly() throws {
        splitsOn()
        try withModePref {
            let (m, log) = try twoAttached()
            defer { m.close() }
            let ta = try XCTUnwrap(try runtime(m, "a").terminal), tb = try XCTUnwrap(try runtime(m, "b").terminal)
            let cb = try XCTUnwrap(log.children["b"]), ca = try XCTUnwrap(log.children["a"])
            var actions: [String] = []
            ta.scrollAction = { _, a in actions.append("a " + a) }
            tb.scrollAction = { _, a in actions.append("b " + a) }
            var mouse = 0
            let view = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            view.mouseWheel = { _ in mouse += 1 }
            view.owner = tb
            let focused = m.layout.focused
            view.scrollWheel(with: try wheelEvent(1))
            view.scrollWheel(with: try wheelEvent(-1))
            tb.writer.flush()
            XCTAssertEqual(mouse, 0, "the unfocused pane's wheel never reaches the mouse path")
            XCTAssertEqual(actions.count, 2, "\(actions)")
            XCTAssertTrue(actions.first?.hasPrefix("b scroll_page_lines:-") == true, "up: back into the scrollback: \(actions)")
            XCTAssertTrue(actions.last?.hasPrefix("b scroll_page_lines:") == true && actions.last?.contains(":-") == false, "\(actions)")
            XCTAssertEqual(cb.written, [], "0 bytes to the unfocused pane's pty")
            XCTAssertEqual(cb.resizes, [], "no setSize")
            XCTAssertEqual(m.layout.focused, focused, "the pane does not take focus")
            // The conversion: a notch is 3 lines; precise points accumulate; garbage is dropped.
            actions = []
            tb.scrollUnfocused(1, precise: false)
            tb.scrollUnfocused(.nan, precise: true)
            tb.scrollUnfocused(.infinity, precise: false)
            XCTAssertEqual(actions, ["b scroll_page_lines:-3"])
            // The focused pane: the mouse path as before (libghostty decides), no scrollback action.
            view.owner = ta
            actions = []
            view.scrollWheel(with: try wheelEvent(1))
            XCTAssertEqual(mouse, 1)
            XCTAssertEqual(actions, [])
            ta.writer.flush()
            XCTAssertEqual(ca.written, [])
        }
    }

    /// QA r1449 i1 (7.6): a first click on an unfocused terminal pane only focuses it (the window swallows it), so its
    /// pty gets 0 bytes; nothing re-attaches.
    @MainActor
    func testAgentWindowSplitTerminalFirstClickOnAnUnfocusedPaneOnlyFocuses() throws {
        splitsOn()
        try withModePref {
            let (m, log) = try twoAttached()
            defer { m.close() }
            let size = CGSize(width: 1600, height: 900)
            let a = try XCTUnwrap(m.paneAreaFrame(in: size))
            let frames = m.paneFrames(in: CGRect(origin: .zero, size: a.size))
            let b = try paneID(m, "b"), fb = try XCTUnwrap(frames[b])
            XCTAssertTrue(AgentsNSWindow.mouseDown(m, at: CGPoint(x: a.minX + fb.midX, y: a.minY + fb.midY), in: size),
                          "the first click only focuses: the window swallows it")
            XCTAssertEqual(m.layout.focused, b)
            Self.drainMain()
            for n in ["a", "b"] {
                try runtime(m, n).terminal?.writer.flush()
                XCTAssertEqual(log.children[n]?.written, [], "\(n): 0 bytes")
            }
            XCTAssertEqual(log.spawned, ["a", "b"], "both stay attached; nothing new")
        }
    }

    /// 11.2 "visible, zoomed away: detached, last frame kept": the zoomed-away pane's client ends, its screen stays;
    /// unzoomed it attaches again after the rest. A hidden window drops it as before.
    @MainActor
    func testAgentWindowSplitTerminalZoomedAwayPaneKeepsItsLastFrame() throws {
        splitsOn()
        try withModePref {
            let (m, log) = try twoAttached()
            defer { m.close() }
            let tb = try XCTUnwrap(try runtime(m, "b").terminal)
            let frame = try XCTUnwrap(tb.screen as? AgentTerminalTests.FakeScreen)
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertEqual(m.shownPanes, [try paneID(m, "a")])
            XCTAssertTrue(tb.key == nil, "detached")
            XCTAssertEqual(log.children["b"]?.terminated, 1)
            XCTAssertTrue((tb.screen as? AgentTerminalTests.FakeScreen) === frame, "the last frame kept")
            XCTAssertEqual(log.rests.count, 0)
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertEqual(log.rests.count, 1, "unzoomed: the rest again")
            endRests(log)
            XCTAssertEqual(log.spawned, ["a", "b", "b"])
            XCTAssertFalse((tb.screen as? AgentTerminalTests.FakeScreen) === frame, "a fresh screen for the new attach")
            m.setVisible(false)
            XCTAssertTrue(tb.screen == nil, "hidden: detached, no frame")
        }
    }

    /// 11.3 (the budget gate's conservative branch): 5 and 6 local terminal panes keep 4 clients attached (the least
    /// recently focused over the cap, behind Connect); a focus moves the attachment (count stays 4); Connect focuses.
    @MainActor
    func testAgentWindowSplitTerminalCapKeepsFourClientsAttached() throws {
        splitsOn()
        try withModePref {
            XCTAssertEqual(AgentWindowModel.attachCap, 4)
            for n in [5, 6] {
                let names = ["a", "b", "c", "d", "e", "f"].prefix(n).map { $0 }
                let m = windowModel(store(names.map { session($0, .idle) }))
                defer { m.close() }
                let log = splitTerminals(m)
                m.paneArea = Self.tallArea
                m.adopt(paneLayout(names.map(paneTarget)))
                m.setVisible(true)
                Self.drainMain()
                endRests(log)
                XCTAssertEqual(attachedCount(m), 4, "\(n) panes")
                XCTAssertEqual(log.spawned, ["a", "b", "c", "d"], "\(n): the focused one and the first three by order")
                XCTAssertEqual(m.connectPanes, Set(try names.dropFirst(4).map { try paneID(m, $0) }), "\(n)")
                // Focus the last pane: it attaches; the least recently focused attached one (d: never focused, last) goes.
                let last = try XCTUnwrap(names.last)
                try focus(m, last)
                Self.drainMain()
                endRests(log)
                XCTAssertEqual(attachedCount(m), 4, "\(n): after a focus move")
                XCTAssertEqual(log.spawned.last, last)
                let td = try XCTUnwrap(try runtime(m, "d").terminal)
                XCTAssertTrue(td.key == nil && td.screen != nil, "\(n): d parked with its last frame")
                XCTAssertTrue(m.connectPanes.contains(try paneID(m, "d")))
                XCTAssertFalse(m.connectPanes.contains(try paneID(m, last)))
                // Connect on d focuses it (and so attaches it); c (never focused) goes now.
                m.focusPane(try paneID(m, "d"))
                Self.drainMain()
                endRests(log)
                XCTAssertEqual(m.layout.focused, try paneID(m, "d"))
                XCTAssertEqual(attachedCount(m), 4, "\(n): after Connect")
                XCTAssertTrue(td.key?.name == "d")
                XCTAssertTrue(try runtime(m, "c").terminal?.key == nil, "\(n): c over the cap now")
                XCTAssertTrue(try runtime(m, "a").terminal?.key?.name == "a", "\(n): a (focused before) stays")
            }
        }
    }

    /// QA r1449 i2: one session in two panes (the layout's no-duplicates rule normally refuses it) gets one client: the
    /// focused pane's; the other shows Connect.
    @MainActor
    func testAgentWindowSplitTerminalOneSessionInTwoPanesAttachesOnce() throws {
        splitsOn()
        try withModePref {
            let m = windowModel(store([session("a", .idle)]))
            defer { m.close() }
            let log = splitTerminals(m)
            m.paneArea = Self.wideArea
            m.adopt(paneLayout([paneTarget("a"), paneTarget("a")]))
            m.setVisible(true)
            Self.drainMain()
            endRests(log)
            let second = try XCTUnwrap(m.layout.order.last)
            XCTAssertTrue(AgentWindowModel.isLive(m.runtimes[second]?.content), "precondition: both panes show the live session")
            XCTAssertEqual(log.spawned, ["a"], "one client for the session")
            XCTAssertEqual(m.connectPanes, [second])
        }
    }

    /// R4.2 / R4.6 (7.5): a divider drag pushes no grid while it moves and exactly one per pane at its end.
    @MainActor
    func testAgentWindowSplitTerminalDividerDragRegridsOncePerPaneAtItsEnd() throws {
        splitsOn()
        try withModePref {
            let (m, log) = try twoAttached()
            defer { m.close() }
            let ta = try XCTUnwrap(try runtime(m, "a").terminal), tb = try XCTUnwrap(try runtime(m, "b").terminal)
            for t in [ta, tb] { t.after = { _, work in work() } }   // a debounced push would land at once
            let size = Self.wideArea.size
            let line = try XCTUnwrap(m.dividers(in: size).first).line
            let p = CGPoint(x: line.midX, y: 300)
            XCTAssertTrue(m.dragBegan(at: p, in: size))
            for dx in [20.0, 40, 60] {
                m.dragMoved(to: CGPoint(x: p.x + dx, y: p.y))
                ta.gridChanged(cols: 80 + Int(dx / 10), rows: 24)
                tb.gridChanged(cols: 80 - Int(dx / 10), rows: 24)
            }
            XCTAssertEqual(log.children["a"]?.resizes, [], "no grid push during the drag")
            XCTAssertEqual(log.children["b"]?.resizes, [])
            m.dragEnded()
            XCTAssertEqual(log.children["a"]?.resizes, [[86, 24]], "one push at the end")
            XCTAssertEqual(log.children["b"]?.resizes, [[74, 24]])
        }
    }
}
