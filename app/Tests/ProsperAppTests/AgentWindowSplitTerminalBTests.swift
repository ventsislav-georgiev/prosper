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

    /// #1644 (operator 2026-11-19, was R6.10 7.6's scrollback-only rule): each wheel goes to the mouse path (libghostty)
    /// of the pane it was handed to, the pane under the pointer, focused or not: an event each, none to the other pane.
    /// The pane does not take focus; its fake pty gets no size.
    @MainActor
    func testAgentWindowSplitTerminalWheelScrollsThePaneUnderThePointerFocusedOrNot() throws {
        splitsOn()
        try withModePref {
            let (m, log) = try twoAttached()
            defer { m.close() }
            let ta = try XCTUnwrap(try runtime(m, "a").terminal), tb = try XCTUnwrap(try runtime(m, "b").terminal)
            let cb = try XCTUnwrap(log.children["b"])
            var wheels: [String] = []
            let va = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            let vb = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            va.mouseWheel = { _ in wheels.append("a") }
            vb.mouseWheel = { _ in wheels.append("b") }
            va.owner = ta
            vb.owner = tb
            let focused = m.layout.focused
            XCTAssertTrue(ta.paneFocused() && !tb.paneFocused(), "a is the focused pane, b is not")
            vb.scrollWheel(with: try wheelEvent(1))
            vb.scrollWheel(with: try wheelEvent(-1))
            XCTAssertEqual(wheels, ["b", "b"], "the unfocused pane under the pointer takes both wheels, the focused one none")
            XCTAssertEqual(cb.resizes, [], "no setSize")
            XCTAssertEqual(m.layout.focused, focused, "the pane does not take focus")
            va.scrollWheel(with: try wheelEvent(1))
            XCTAssertEqual(wheels, ["b", "b", "a"], "the focused pane's wheel: its own mouse path, as before")
            XCTAssertEqual(m.layout.focused, focused)
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

// MARK: R1477b-m1 (QA r1457): the right and middle buttons, motion and exit on an unfocused pane

extension AgentWindowD1Tests {
    /// R1477b-m1 (7.6) through the window's sendEvent, built events handed to it (never posted; the window is never shown):
    /// a right or middle down on the unfocused pane takes the left first-click rule: the pane is focused, the down, its
    /// drag and its up are swallowed (so no view and no program sees them), no key and front is asked, and the window's
    /// keys then follow the clicked pane's own terminal (#1471: every pane is a terminal, each on a fake client, so the keys
    /// land in its view once live; adopt() attaches before it asks for the keys). The middle click runs first and the row
    /// stops at the first down that is not swallowed, so a passing right down never opens AppKit's context menu.
    @MainActor
    func testAgentWindowSplitTerminalRightAndMiddleClickOnAnUnfocusedPaneOnlyFocus() throws {
        try withPaneMenu(true) {
            let buttons: [(NSEvent.EventType, NSEvent.EventType, NSEvent.EventType)] = [
                (.otherMouseDown, .otherMouseDragged, .otherMouseUp), (.rightMouseDown, .rightMouseDragged, .rightMouseUp)]
            for (down, drag, up) in buttons {
                let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
                _ = splitTerminals(m)   // fake clients: a pane's terminal goes live, so its view can take the keys
                m.setVisible(true)
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                let second = try XCTUnwrap(m.layout.order.last)
                let (win, host) = focusWindow(m)
                defer { win.close() }
                var raised = 0
                win.raise = { _ in raised += 1 }   // before any down: the real call never runs
                XCTAssertTrue(m.focusSelection())
                // #1471: the keys go to the focused pane's terminal (its view when live, else pending on it).
                @MainActor func keysIn(_ t: AgentTerminalController) -> Bool {
                    if let v = t.view { return win.firstResponder === v }
                    return t.focusPending
                }
                let old = try XCTUnwrap(m.focusedRuntime?.terminal, "\(down)")
                paneFocusSettle(host) { keysIn(old) }
                XCTAssertTrue(keysIn(old), "\(down): the keys in api's terminal")
                let p = try paneFocusCentre(m, second, in: win.contentLayoutRect.size)
                func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    let r = win.contentLayoutRect
                    return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: r.minX + p.x, y: r.maxY - p.y),
                                                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: type == up ? 0 : 1))
                }
                win.sendEvent(try event(down))
                XCTAssertEqual(m.layout.focused, second, "\(down): the unfocused pane is focused")
                // A right down that passes would reach AppKit's context menu (a real menu): the middle click goes first, and
                // once a down is not swallowed the row stops before any right down is sent.
                guard win.focusClick.swallowing else { return XCTFail("\(down): not swallowed; the row stops here") }
                win.sendEvent(try event(drag))
                XCTAssertTrue(win.focusClick.swallowing, "\(down): its drag too")
                win.sendEvent(try event(up))
                XCTAssertFalse(win.focusClick.swallowing, "\(down): its up ends the swallow")
                XCTAssertEqual(raised, 0, "\(down): no key and front for a right or middle click")
                let clicked = try XCTUnwrap(m.focusedRuntime?.terminal, "\(down)")
                XCTAssertFalse(clicked === old, "\(down): the focused pane's terminal is the clicked pane's")
                paneFocusSettle(host) { keysIn(clicked) }
                XCTAssertTrue(keysIn(clicked), "\(down): the keys followed the clicked pane's terminal")
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }
}

extension AgentTerminalTests {
    /// A built mouse event at `p` (the view's own coordinates) for `v`'s window, never posted.
    @MainActor
    func splitMouse(_ type: NSEvent.EventType, _ p: NSPoint, _ v: ViewRig) throws -> NSEvent {
        let at = v.host.convert(p, to: nil)
        if type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                                        windowNumber: v.window.windowNumber, context: nil, eventNumber: 0,
                                                        trackingNumber: 0, userData: nil))
        }
        let up = [NSEvent.EventType.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                                windowNumber: v.window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: up ? 0 : 1))
    }

    /// R1477b-m1 (7.6), the second guard in the real view (libghostty, offscreen; the fake program puts the screen in
    /// ?1003 any-motion mode with SGR reports): on an UNFOCUSED pane a right click, a middle click, a move, every drag and
    /// the exit each write 0 bytes and leave the window's first responder where it was (never the pane: no keys moved);
    /// on the FOCUSED pane the same move, right click and middle click still write their reports (the guard is not
    /// "always drop"). Events are built and handed to the view's own methods.
    @MainActor
    func testUnfocusedSplitPaneMouseButtonsMotionAndExitWriteNothing() throws {
        let v = startedView()
        defer { v.tearDown() }
        v.output("\u{1b}[?1003h\u{1b}[?1006h", self)
        _ = v.take(self)
        var focused = false
        v.rig.c.paneFocused = { focused }
        XCTAssertTrue(v.window.makeFirstResponder(nil))
        let calls: [(String, NSEvent.EventType, @MainActor (NSEvent) -> Void)] = [
            ("right down", .rightMouseDown, v.host.rightMouseDown), ("right drag", .rightMouseDragged, v.host.rightMouseDragged),
            ("right up", .rightMouseUp, v.host.rightMouseUp), ("middle down", .otherMouseDown, v.host.otherMouseDown),
            ("middle drag", .otherMouseDragged, v.host.otherMouseDragged), ("middle up", .otherMouseUp, v.host.otherMouseUp),
            ("move", .mouseMoved, v.host.mouseMoved), ("left drag", .leftMouseDragged, v.host.mouseDragged),
            ("exit", .mouseExited, v.host.mouseExited)]
        var x: CGFloat = 40
        for (name, type, call) in calls {
            x += 37   // a new cell each time: a motion report would be due
            call(try splitMouse(type, NSPoint(x: x, y: 200), v))
            XCTAssertEqual(v.take(self), [], "unfocused \(name): 0 bytes to the program")
            XCTAssertTrue(v.window.firstResponder === v.window, "unfocused \(name): the first responder is unchanged")
        }
        // The focused pane: libghostty as before, reports included (the right down first: it takes the keys, as before).
        focused = true
        v.host.rightMouseDown(with: try splitMouse(.rightMouseDown, NSPoint(x: 200, y: 200), v))
        let right = String(decoding: v.take(self, until: { !$0.isEmpty }), as: UTF8.self)
        XCTAssertTrue(right.contains("\u{1b}[<2;"), "focused right down: its press report (\(right.debugDescription))")
        XCTAssertTrue(v.window.firstResponder === v.host, "the focused pane's right click takes the keys, as before")
        v.host.rightMouseUp(with: try splitMouse(.rightMouseUp, NSPoint(x: 200, y: 200), v))
        _ = v.take(self)
        v.host.otherMouseDown(with: try splitMouse(.otherMouseDown, NSPoint(x: 200, y: 200), v))
        let middle = String(decoding: v.take(self, until: { !$0.isEmpty }), as: UTF8.self)
        XCTAssertTrue(middle.contains("\u{1b}[<1;"), "focused middle down: its press report (\(middle.debugDescription))")
        v.host.otherMouseUp(with: try splitMouse(.otherMouseUp, NSPoint(x: 200, y: 200), v))
        _ = v.take(self)
        v.host.mouseMoved(with: try splitMouse(.mouseMoved, NSPoint(x: 300, y: 120), v))
        v.host.mouseMoved(with: try splitMouse(.mouseMoved, NSPoint(x: 360, y: 160), v))
        let moved = String(decoding: v.take(self, until: { !$0.isEmpty }), as: UTF8.self)
        XCTAssertTrue(moved.contains("\u{1b}[<"), "focused move: a motion report (\(moved.debugDescription))")
    }

    /// #1644: a one-notch wheel up at `p` (the view's own coordinates), built from a CGEvent and never posted. A
    /// windowless event's location is the screen's, so the point is placed where the view reads it back (its window
    /// point, flipped to CoreGraphics' top-left origin on the primary screen).
    @MainActor
    func splitWheel(_ p: NSPoint, _ v: ViewRig) throws -> NSEvent {
        let w = v.host.convert(p, to: nil)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        cg.location = CGPoint(x: w.x, y: (NSScreen.screens.first?.frame.height ?? 0) - w.y)
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// #1644: the first SGR mouse report in `bytes` ("ESC [ < button ; col ; row M"), nil for none.
    func firstReport(_ bytes: [UInt8]) -> String? {
        let s = String(decoding: bytes, as: UTF8.self)
        guard let start = s.range(of: "\u{1b}[<"), let end = s[start.upperBound...].firstIndex(where: { $0 == "M" || $0 == "m" })
        else { return nil }
        return String(s[start.lowerBound...end])
    }

    /// #1644 (operator 2026-11-19), the real view (libghostty, offscreen; the fake program asks for ?1000 button reports
    /// in SGR form, so a wheel writes "ESC [ < 64 ; col ; row M" at libghostty's pointer and a move writes nothing): the
    /// wheel reports at the event's own point, focused or not, with no move first. Unfocused, the pane takes the wheel
    /// (was: scroll_page_lines, 0 bytes) and not the keys. Focused right after a focus switch, the first wheel reports
    /// where it happened, not where libghostty last saw the pointer (was: the unfocused pane's moves never reached it, so
    /// the wheel went to a stale point until the mouse moved). Events are built and handed to the view's own methods.
    @MainActor
    func testSplitPaneWheelReportsAtItsOwnPointFocusedOrNotWithNoMoveFirst() throws {
        let v = startedView()
        defer { v.tearDown() }
        v.output("\u{1b}[?1000h\u{1b}[?1006h", self)
        _ = v.take(self)
        var focused = true
        v.rig.c.paneFocused = { focused }
        let here = try splitWheel(NSPoint(x: 100, y: 300), v), there = try splitWheel(NSPoint(x: 500, y: 80), v)
        // The references: the focused pane with the pointer moved there first (the path that always worked).
        v.host.mouseMoved(with: here)
        v.host.scrollWheel(with: here)
        let atHere = try XCTUnwrap(firstReport(v.take(self, until: { !$0.isEmpty })), "a wheel report at here")
        v.host.mouseMoved(with: there)
        v.host.scrollWheel(with: there)
        let atThere = try XCTUnwrap(firstReport(v.take(self, until: { !$0.isEmpty })), "a wheel report at there")
        XCTAssertTrue(atHere.hasPrefix("\u{1b}[<64;"), "a wheel-up report: \(atHere.debugDescription)")
        XCTAssertNotEqual(atHere, atThere, "the two points are different cells")
        // A focus switch: the pointer last reached libghostty at `here`, moved to `there` while the pane was unfocused
        // (dropped), the pane takes focus, and the first wheel at `there` reports at `there`.
        v.host.mouseMoved(with: here)
        focused = false
        v.host.mouseMoved(with: there)
        focused = true
        v.host.scrollWheel(with: there)
        XCTAssertEqual(firstReport(v.take(self, until: { !$0.isEmpty })), atThere, "the first wheel after a focus switch")
        // Unfocused: the wheel at `here` reports at `here`; the keys stay where they were.
        focused = false
        XCTAssertTrue(v.window.makeFirstResponder(nil))
        v.host.scrollWheel(with: here)
        XCTAssertEqual(firstReport(v.take(self, until: { !$0.isEmpty })), atHere, "the unfocused pane under the pointer scrolls")
        XCTAssertTrue(v.window.firstResponder === v.window, "the wheel moves no keys")
        XCTAssertFalse(v.window.isVisible, "never shown")
    }
}
