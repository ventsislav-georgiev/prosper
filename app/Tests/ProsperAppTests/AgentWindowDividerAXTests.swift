import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 5b; spec 7.5, 8.1, 13): a divider drag that is never ended by its up (R900-5a-1: the window closes,
/// stops being key, a key, a tree change), and each divider as one adjustable accessibility element (5 percent nudges
/// through the model, clamped, saved once), split gate on only. Offscreen only: the model's functions with literal
/// points, the window's route with built NSEvent values (nothing posted); the accessibility rows host the root view in a
/// never-shown borderless window with the flags on this process's own NSApplication (AXTreeSupport). The split gate and
/// the UI scale are saved, set and restored in a defer; layouts save to a private XCTestDefaults suite; the terminal is
/// the recorder fakes (no dch runs). Every closure runs on the main actor.
/// Filter: 'AgentWindowD1Tests/testDivider'.
extension AgentWindowD1Tests {
    /// A left mouse-down at the A | B line of a 1600 x 900 window, in content coordinates, and the pane area.
    @MainActor
    func dividerEndsSetup(_ m: AgentWindowModel) throws -> (p: CGPoint, a: CGRect, size: CGSize) {
        let size = CGSize(width: 1600, height: 900)
        let a = try XCTUnwrap(m.paneAreaFrame(in: size))
        let line = try XCTUnwrap(m.dividers(in: a.size).first).line
        return (CGPoint(x: a.minX + line.midX, y: a.minY + 300), a, size)
    }

    @MainActor
    func dividerKeyEvent() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    }

    // MARK: Part A: a drag that is never ended by its up

    /// R900-5a-1 hole 1: the window closes mid-drag: the live ratio is saved exactly once and the terminal's hold is
    /// released (exactly one setSize for the changed grid), before close() stops the saves.
    @MainActor
    func testDividerEndsOnCloseSavingOnceAndReleasingTheTerminal() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withModePref {
            try withTreeGate(true) {
                let d = layoutSuite()
                let st = store([mapped("api"), mapped("web")])
                st.controlDch = bin([1, 38, 0])
                let m = windowModel(st, layouts: d)
                let t = dividerTerminals(m)
                let clock = AgentTerminalTests.Clock()
                m.terminal.after = { clock.schedule($0, $1) }
                Calls().wire(m)
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                let size = CGSize(width: 1000, height: 600)
                m.paneArea = CGRect(origin: .zero, size: size)
                m.setVisible(true)
                defer { m.close() }
                let child = try XCTUnwrap(t.children().last, "the focused live pane's terminal attached")
                let base = child.resizes.count, writes = m.layoutWrites
                XCTAssertTrue(m.dragBegan(at: CGPoint(x: 500.5, y: 300), in: size))
                for i in 1...10 {
                    m.dragMoved(to: CGPoint(x: 500.5 - 5 * CGFloat(i), y: 300))
                    m.terminal.gridChanged(cols: 80 - i, rows: 24)
                    clock.advance(1)
                }
                let dragged = m.layout
                XCTAssertEqual(try XCTUnwrap(dividerRatio(dragged, [])), 0.45, accuracy: 1e-9)
                XCTAssertEqual(m.layoutWrites, writes, "nothing saved during the drag")
                XCTAssertEqual(child.resizes.count, base, "0 setSize during the drag")
                m.close()
                XCTAssertTrue(m.dividerDrag == nil, "the close ended the drag")
                XCTAssertEqual(m.layoutWrites, writes + 1, "saved exactly once")
                XCTAssertEqual(savedLayouts(d).activeLayout, dragged, "the live ratio is the saved one")
                XCTAssertEqual(child.resizes.count, base + 1, "the hold released: exactly one setSize")
                XCTAssertEqual(child.resizes.last, [70, 24], "the last grid")
                m.close()
                XCTAssertEqual(m.layoutWrites, writes + 1, "a second close saves nothing")
            }
        }
    }

    /// R900-5a-1 hole 2: the window stops being key mid-drag (through the hook's own function; no window is made key):
    /// the drag ends, saved once; the rest of that button's drags and its up are still the divider's (swallowed, no
    /// change); the next down elsewhere passes.
    @MainActor
    func testDividerEndsOnResignKeyAndTheButtonStaysSwallowed() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let d = layoutSuite()
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: d)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let (p, a, size) = try dividerEndsSetup(m)
            let writes = m.layoutWrites, focused = m.layout.focused
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: p, in: size))
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: CGPoint(x: p.x + 50, y: p.y), in: size))
            AgentsNSWindow.resignedKey(m)
            XCTAssertTrue(m.dividerDrag == nil, "resign key ended the drag")
            XCTAssertEqual(m.layoutWrites, writes + 1, "saved once")
            let ended = m.layout
            XCTAssertEqual(try XCTUnwrap(dividerRatio(ended, [])), 0.5 + 50 / Double(a.width), accuracy: 1e-9)
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: CGPoint(x: p.x + 150, y: p.y), in: size),
                          "the button's next drag is swallowed")
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseUp), m, at: CGPoint(x: p.x + 150, y: p.y), in: size),
                          "and its up")
            XCTAssertEqual(m.layout, ended, "they change nothing")
            XCTAssertEqual(m.layoutWrites, writes + 1)
            XCTAssertFalse(m.dividerHeld, "the up resets the state")
            let elsewhere = CGPoint(x: a.minX + 40, y: a.minY + 300)
            XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: elsewhere, in: size), "the next down passes")
            XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: elsewhere, in: size))
            XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.leftMouseUp), m, at: elsewhere, in: size))
            XCTAssertEqual(m.layout.focused, focused)
            AgentsNSWindow.resignedKey(m)
            XCTAssertEqual(m.layoutWrites, writes + 1, "no drag: resign key saves nothing")
        }
    }

    /// R900-5a-1 hole 3: a key's tree action mid-drag (Close Pane through perform): the drag ends FIRST (its ratio saved
    /// once), then the action's own change is there and saved once by the ordinary rule; a following move changes
    /// nothing; the button's drags and up are still swallowed; the next down is the window's again.
    @MainActor
    func testDividerEndsOnATreeKeyActionFirst() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let d = layoutSuite()
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: d)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            for l in m.layouts?.layouts ?? [] where l.id != m.layout.id { m.deleteLayout(l.id) }   // #1894: the lone layout, so the close to one pane keeps it
            let (p, a, size) = try dividerEndsSetup(m)
            let writes = m.layoutWrites
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: p, in: size))
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: CGPoint(x: p.x + 50, y: p.y), in: size))
            XCTAssertEqual(m.layoutWrites, writes, "nothing saved during the drag")
            XCTAssertTrue(m.perform(.closePane))
            XCTAssertTrue(m.dividerDrag == nil, "the tree change ended the drag")
            XCTAssertEqual(m.layout.panes.count, 1, "the action's own change is there")
            XCTAssertEqual(m.layoutWrites, writes + 2, "the drag's one save plus the action's one")
            XCTAssertEqual(savedLayouts(d).activeLayout, m.layout, "the action is saved")
            let after = m.layout
            m.dragMoved(to: CGPoint(x: 700, y: 300))
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: CGPoint(x: p.x + 90, y: p.y), in: size),
                          "the button's next drag is swallowed")
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseUp), m, at: CGPoint(x: p.x + 90, y: p.y), in: size))
            XCTAssertEqual(m.layout, after, "a move after the end changes nothing")
            XCTAssertEqual(m.layoutWrites, writes + 2)
            XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: CGPoint(x: a.minX + 40, y: p.y), in: size),
                           "the next down passes")
        }
    }

    /// R900-5a-1: a key down in the window ends a drag (the route, gate on; the key itself goes on: false); the button's
    /// drags and up stay swallowed. A select (the browse rule) mid-drag ends it too.
    @MainActor
    func testDividerEndsOnAKeyDownAndOnASelect() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let d = layoutSuite()
            let m = windowModel(store([session("api", .idle), session("web", .idle), session("docs", .idle)]), layouts: d)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let (p, a, size) = try dividerEndsSetup(m)
            let writes = m.layoutWrites
            XCTAssertFalse(AgentsNSWindow.divider(dividerKeyEvent(), m, at: .zero, in: size), "no drag: a key passes")
            XCTAssertEqual(m.layoutWrites, writes)
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: p, in: size))
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: CGPoint(x: p.x + 50, y: p.y), in: size))
            XCTAssertFalse(AgentsNSWindow.divider(dividerKeyEvent(), m, at: .zero, in: size), "the key itself goes on")
            XCTAssertTrue(m.dividerDrag == nil, "the key ended the drag")
            XCTAssertEqual(m.layoutWrites, writes + 1, "saved once")
            let ended = m.layout
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: CGPoint(x: p.x + 120, y: p.y), in: size))
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseUp), m, at: CGPoint(x: p.x + 120, y: p.y), in: size))
            XCTAssertEqual(m.layout, ended)
            // A select mid-drag: the drag's save. #1895 rule 1: docs is in no pane of the made layout, so the pick parks it
            // (the single-pane view, never saved): the saved layout is the parked one with the drag's ratio.
            let q = CGPoint(x: a.minX + (try XCTUnwrap(m.dividers(in: a.size).first)).line.midX, y: p.y)
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: q, in: size))
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: CGPoint(x: q.x - 40, y: q.y), in: size))
            m.select(.live(paneKey("docs")))
            XCTAssertTrue(m.dividerDrag == nil, "the select ended the drag")
            XCTAssertEqual(m.focusedTarget, paneTarget("docs"), "the pick's own change is there")
            XCTAssertEqual(m.layoutWrites, writes + 2, "the drag's one save; the single-pane view's pick saves nothing")
            XCTAssertTrue(m.parked != nil && savedLayouts(d).activeLayout == m.parked, "the drag's ratio saved before the park")
        }
    }

    /// R900-5a-2: no row can see a cursor on a never-shown window; the pure pick is pinned: left-right for a column
    /// divider (a vertical line), up-down for a row divider.
    @MainActor
    func testDividerEndsCursorIsPickedPerAxis() {
        XCTAssertTrue(AgentPaneArea.cursor(.columns) == NSCursor.resizeLeftRight)
        XCTAssertTrue(AgentPaneArea.cursor(.rows) == NSCursor.resizeUpDown)
    }

    // MARK: Part B: the model

    /// 13: a divider's value is its split's ratio in whole percent, rounded (0.29 is 28.999… times 100); a ratio that is
    /// not finite or not in [0, 1] (outside data) gives nil without a trap; a path that names no split gives nil.
    @MainActor
    func testDividerAXPercentOfLiteralRatios() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle), session("docs", .idle)]))
            defer { m.close() }
            let cases: [(Double, Int?)] = [(0.1, 10), (0.25, 25), (0.29, 29), (0.5, 50), (0.9, 90), (0.7, 70),
                                           (.nan, nil), (.infinity, nil), (1.5, nil), (-0.2, nil)]
            for (r, want) in cases {
                m.adopt(dividerNested(root: r, nested: 0.5))
                XCTAssertEqual(m.dividerPercent([]), want, "ratio \(r)")
                XCTAssertEqual(m.dividerPercent([1]), 50, "the nested split (ratio \(r) at the root)")
            }
            XCTAssertTrue(m.dividerPercent([0]) == nil, "a leaf is no split")
            XCTAssertTrue(m.dividerPercent([1, 1, 0]) == nil, "no such path")
            // A ratio held at the clamp by a nudge (1000 wide, 300 minimum: 0.7).
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            for _ in 1...6 { m.nudge([], up: true, in: CGSize(width: 1000, height: 600)) }
            XCTAssertEqual(m.dividerPercent([]), 70)
        }
    }

    /// 13 / 8.1: a nudge moves the ratio by 0.05 up or down, saved once and published once; at the clamp (1000 wide,
    /// 300 minimum: 0.7) further nudges change, save and publish nothing; a nudge while a drag is under way ends the
    /// drag first (its save) and then saves its own.
    @MainActor
    func testDividerAXNudgeStepsFivePercentClampsAndSavesOnce() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let d = layoutSuite()
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: d)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let size = CGSize(width: 1000, height: 600)
            var sends = 0
            let sink = m.objectWillChange.sink { _ in sends += 1 }
            defer { sink.cancel() }
            let writes = m.layoutWrites
            m.nudge([], up: true, in: size)
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.55, accuracy: 1e-9)
            XCTAssertEqual(m.layoutWrites, writes + 1, "one save")
            XCTAssertEqual(sends, 1, "one publish")
            XCTAssertEqual(savedLayouts(d).activeLayout, m.layout)
            m.nudge([], up: false, in: size)
            m.nudge([], up: false, in: size)
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.45, accuracy: 1e-9)
            XCTAssertEqual(m.layoutWrites, writes + 3, "one save each")
            for _ in 1...10 { m.nudge([], up: true, in: size) }
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.7, accuracy: 1e-9, "held at the clamp")
            XCTAssertEqual(m.layoutWrites, writes + 8, "0.5, 0.55, 0.6, 0.65, 0.7: five changes, five saves")
            let held = m.layout, heldSends = sends, heldWrites = m.layoutWrites
            for _ in 1...3 { m.nudge([], up: true, in: size) }
            XCTAssertEqual(m.layout, held)
            XCTAssertEqual(sends, heldSends, "at the clamp: no publish")
            XCTAssertEqual(m.layoutWrites, heldWrites, "at the clamp: no save")
            // Mid-drag: the drag's save first, then the nudge's.
            XCTAssertTrue(m.dragBegan(at: try XCTUnwrap(m.dividers(in: size).first).line.origin, in: size))
            m.dragMoved(to: CGPoint(x: 550, y: 300))
            let dragged = try XCTUnwrap(dividerRatio(m.layout, []))
            m.nudge([], up: false, in: size)
            XCTAssertTrue(m.dividerDrag == nil, "the nudge ended the drag")
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), dragged - 0.05, accuracy: 1e-9)
            XCTAssertEqual(m.layoutWrites, heldWrites + 2, "the drag's one save plus the nudge's one")
        }
    }

    /// 13: in A | (B over C) a nudge moves that split only; a leaf's path or a missing one changes nothing.
    @MainActor
    func testDividerAXNudgeInANestedLayoutMovesThatSplitOnly() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle), session("docs", .idle)]), layouts: layoutSuite())
            defer { m.close() }
            m.adopt(dividerNested(root: 0.5, nested: 0.5))
            let size = CGSize(width: 1200, height: 800)
            m.nudge([1], up: true, in: size)
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [1])), 0.55, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.5, accuracy: 1e-9, "the root unchanged")
            m.nudge([], up: false, in: size)
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.45, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [1])), 0.55, accuracy: 1e-9, "the nested split unchanged")
            let now = m.layout, writes = m.layoutWrites
            m.nudge([0], up: true, in: size)
            m.nudge([1, 0], up: true, in: size)
            m.nudge([1, 1, 1], up: false, in: size)
            XCTAssertEqual(m.layout, now, "no split there: nothing")
            XCTAssertEqual(m.layoutWrites, writes)
        }
    }

    /// 13 / 15.0: zoomed, too small, a size that is not finite, or the gate off: a nudge changes, saves and publishes
    /// nothing.
    @MainActor
    func testDividerAXNudgeDoesNothingZoomedTooSmallOrGateOff() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let size = CGSize(width: 1000, height: 600)
        @MainActor func unchanged(_ m: AgentWindowModel, _ s: CGSize, _ why: String) {
            var sends = 0
            let sink = m.objectWillChange.sink { _ in sends += 1 }
            defer { sink.cancel() }
            let was = m.layout, writes = m.layoutWrites
            m.nudge([], up: true, in: s)
            m.nudge([], up: false, in: s)
            XCTAssertEqual(m.layout, was, why)
            XCTAssertEqual(m.layoutWrites, writes, why)
            XCTAssertEqual(sends, 0, why)
        }
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            unchanged(m, CGSize(width: 500, height: 600), "too small")
            unchanged(m, CGSize(width: CGFloat.nan, height: 600), "not finite")
            unchanged(m, CGSize(width: 1000, height: CGFloat.infinity), "not finite")
            m.adopt(m.layout.toggleZoom())
            XCTAssertTrue(m.layout.zoomed != nil)
            unchanged(m, size, "zoomed")
        }
        withTreeGate(false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            unchanged(m, size, "gate off")
        }
    }

    // MARK: Part B: the view

    /// The root view of `m` in a never-shown window of `size`, read through AXTreeSupport (flags on this process only)
    /// until `done` holds, to its 5 s ceiling; then `after` runs and the tree is read again until `again` holds.
    @MainActor
    func dividerAXRead(_ m: AgentWindowModel, _ size: CGSize, until done: ([AXTreeNode]) -> Bool,
                       then after: () -> Void = {}, again: (([AXTreeNode]) -> Bool)? = nil) -> ([AXTreeNode], [AXTreeNode]) {
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
        defer { win.contentView = nil; win.close() }
        let first = AXTreeSupport.poll(host, until: done)
        after()
        let second = again.map { AXTreeSupport.poll(host, until: $0) } ?? []
        XCTAssertFalse(win.isVisible, "never shown")
        return (first, second)
    }

    /// 13: gate on, A | B: exactly one divider element, role AXSplitter, label "Vertical divider", value "50 percent",
    /// after both panes' containers; a nudge through the model reads "55 percent".
    @MainActor
    func testDividerAXOneAdjustableElementAfterThePanes() throws {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        defer { ThemeRuntime.scale = saved; restoreModes() }
        ThemeRuntime.scale = 1.0
        let size = CGSize(width: 1600, height: 900)
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            m.paneArea = zoomViewArea(size)
            m.setVisible(true)
            let (before, after) = dividerAXRead(m, size, until: { $0.contains { $0.label == "Vertical divider" } }, then: {
                m.nudge([], up: true, in: m.paneArea.size)
            }, again: { $0.contains { $0.label == "Vertical divider" && $0.value == "55 percent" } })
            let dividers = before.filter { $0.label == "Vertical divider" }
            XCTAssertEqual(dividers.count, 1, "one element: \(before.map(\.label).filter { !$0.isEmpty })")
            XCTAssertEqual(dividers.first?.value, "50 percent")
            XCTAssertFalse(before.contains { $0.label == "Horizontal divider" })
            XCTAssertEqual(dividers.first?.role, "AXSplitter")
            XCTAssertEqual(dividers.first?.ignored, false, "served to an AX client")
            let at = before.firstIndex { $0.label == "Vertical divider" }
            let p1 = before.firstIndex { $0.label.hasSuffix(", pane 1 of 2") }, p2 = before.firstIndex { $0.label.hasSuffix(", pane 2 of 2") }
            XCTAssertTrue(at != nil && p1 != nil && p2 != nil, "\(before.map(\.label).filter { !$0.isEmpty })")
            if let at, let p1, let p2 { XCTAssertTrue(p1 < p2 && p2 < at, "the panes in order, then the divider") }
            XCTAssertEqual(after.filter { $0.label == "Vertical divider" }.first?.value, "55 percent")
        }
    }

    /// 13 / 15.0: zoomed, too small, or the gate off: no divider element in the tree (read until the sidebar's row is
    /// there, so "none" is not an empty read).
    @MainActor
    func testDividerAXNoElementZoomedTooSmallOrGateOff() throws {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        defer { ThemeRuntime.scale = saved; restoreModes() }
        ThemeRuntime.scale = 1.0
        @MainActor func none(_ on: Bool, _ size: CGSize, zoom: Bool, _ why: String) throws {
            try withTreeGate(on) {
                let m = windowModel(store([session("api", .idle), session("web", .idle)]))
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                if zoom { m.adopt(m.layout.toggleZoom()) }
                m.setVisible(true)
                let title = try XCTUnwrap(m.row(.live(paneKey("web")))?.title)
                let (tree, _) = dividerAXRead(m, size, until: { $0.contains { $0.label.hasPrefix(title) } })
                XCTAssertTrue(tree.contains { $0.label.hasPrefix(title) }, "\(why): the tree was read")
                XCTAssertFalse(tree.contains { $0.label.hasSuffix(" divider") }, "\(why): \(tree.map(\.label).filter { !$0.isEmpty })")
            }
        }
        try none(true, CGSize(width: 1600, height: 900), zoom: true, "zoomed")
        try none(true, CGSize(width: 700, height: 500), zoom: false, "too small")
        try none(false, CGSize(width: 1600, height: 900), zoom: false, "gate off")
    }

    /// The divider elements' AppKit views under `v` (the window's own private type: found by its role).
    @MainActor
    func dividerAXViews(_ v: NSView) -> [NSView] {
        v.subviews.flatMap { ($0.accessibilityRole() == .splitter ? [$0] : []) + dividerAXViews($0) }
    }

    /// Gate on, `layout` in the root view of a never-shown 1600 x 900 window, flags on this process only (AXTreeSupport):
    /// `body` gets the model, the host, the tree read until it holds `label` (5 s ceiling) and the divider views.
    @MainActor
    func dividerAXHosted(_ layout: PaneLayout, until label: String,
                         _ body: (AgentWindowModel, NSView, [AXTreeNode], [NSView]) throws -> Void) throws {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        defer { ThemeRuntime.scale = saved; restoreModes() }
        ThemeRuntime.scale = 1.0
        let size = CGSize(width: 1600, height: 900)
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(layout)
            m.paneArea = zoomViewArea(size)
            m.setVisible(true)
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
            defer { win.contentView = nil; win.close() }
            let tree = AXTreeSupport.poll(host) { $0.contains { $0.label == label } }
            try body(m, host, tree, dividerAXViews(host))
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// 13: the element's own increment and decrement (called directly, not through an AX client) nudge the model's
    /// split by 5 percent each and return true; the value string follows at the next update.
    @MainActor
    func testDividerAXViewIncrementAndDecrementNudgeTheModel() throws {
        try dividerAXHosted(paneLayout([paneTarget("api"), paneTarget("web")]), until: "Vertical divider") { m, host, _, views in
            XCTAssertEqual(views.count, 1)
            let v = try XCTUnwrap(views.first)
            XCTAssertEqual(v.accessibilityValue() as? String, "50 percent")
            @MainActor func value(after wanted: String) -> String? {
                _ = AXTreeSupport.poll(host) { _ in dividerAXViews(host).first?.accessibilityValue() as? String == wanted }
                return dividerAXViews(host).first?.accessibilityValue() as? String
            }
            XCTAssertTrue(v.accessibilityPerformIncrement())
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.55, accuracy: 1e-9)
            XCTAssertEqual(value(after: "55 percent"), "55 percent")
            XCTAssertTrue(v.accessibilityPerformDecrement())
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.5, accuracy: 1e-9)
            XCTAssertEqual(value(after: "50 percent"), "50 percent")
        }
    }

    /// 13 / 7.5: the element takes no mouse event (the window's route keeps the mouse): hitTest of its own centre is
    /// nil; it has the hit area's size (no room of its own) and never takes the keys.
    @MainActor
    func testDividerAXViewTakesNoHits() throws {
        try dividerAXHosted(paneLayout([paneTarget("api"), paneTarget("web")]), until: "Vertical divider") { m, _, _, views in
            let v = try XCTUnwrap(views.first)
            let d = try XCTUnwrap(m.dividers(in: m.paneArea.size).first)
            XCTAssertEqual(v.frame.width, d.hitArea.width, accuracy: 1)
            XCTAssertEqual(v.frame.height, d.hitArea.height, accuracy: 1)
            XCTAssertTrue(v.frame.width > 0 && v.frame.height > 0, "a point inside it exists")
            XCTAssertTrue(v.hitTest(CGPoint(x: v.frame.midX, y: v.frame.midY)) == nil, "no mouse event lands on it")
            XCTAssertFalse(v.acceptsFirstResponder)
        }
    }

    /// 13: A over B: the one element reads "Horizontal divider", role AXSplitter, "50 percent".
    @MainActor
    func testDividerAXRowsLayoutReadsHorizontalDivider() throws {
        let a = Pane(id: UUID(), target: paneTarget("api")), b = Pane(id: UUID(), target: paneTarget("web"))
        let l = PaneLayout(id: UUID(), name: nil, tree: .split(.rows, ratio: 0.5, .leaf(a), .leaf(b)), focused: a.id, zoomed: nil)
        try dividerAXHosted(l, until: "Horizontal divider") { _, _, tree, views in
            XCTAssertEqual(views.count, 1)
            let found = tree.filter { $0.label.hasSuffix(" divider") }
            XCTAssertEqual(found.map(\.label), ["Horizontal divider"])
            XCTAssertEqual(found.first?.role, "AXSplitter")
            XCTAssertEqual(found.first?.value, "50 percent")
        }
    }
}
