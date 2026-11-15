import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 5a; spec 3.3, 7.5, 7.6, 8.1, 14.2 WINCH): the dividers by mouse, split gate on only. The hit area
/// (the 1 pt line widened to 6·s, clipped to its split), a live drag through setRatio that saves once at its end, a
/// double-click that equalizes that split alone, and the window's route ahead of the first-click rule. Offscreen only:
/// the model's functions are called with literal points (pane-area coordinates), the window's route with built
/// NSEvent values (nothing posted); the one drawn row hosts the root view in a never-shown borderless window. The split
/// gate and the UI scale are saved, set and restored in a defer; layouts save to a private XCTestDefaults suite; the
/// terminal is the recorder fakes of the Terminal-mode rows (no dch runs). Every closure runs on the main actor.
/// Filter: 'AgentWindowD1Tests/testDivider' (an extension of the class the pane rows live in).
extension AgentWindowD1Tests {
    /// A | (B over C): the root columns at `root`, the nested rows at `nested`; A focused.
    func dividerNested(root: Double = 0.5, nested: Double = 0.5) -> PaneLayout {
        let a = Pane(id: UUID(), target: paneTarget("api")), b = Pane(id: UUID(), target: paneTarget("web"))
        let c = Pane(id: UUID(), target: paneTarget("docs"))
        return PaneLayout(id: UUID(), name: nil, tree: .split(.columns, ratio: root, .leaf(a), .split(.rows, ratio: nested, .leaf(b), .leaf(c))),
                          focused: a.id, zoomed: nil)
    }

    /// The ratio of the split at `path`.
    func dividerRatio(_ l: PaneLayout, _ path: [Int]) -> Double? {
        guard case let .split(_, r, _, _)? = l.tree.locate(path[...], in: .zero)?.node else { return nil }
        return r
    }

    /// The hit table of `dividerNested()` in 1200 x 800 at half-band `h` (3·s): the root line is the 1 pt strip x 600..601
    /// (centre 600.5), the nested one y 400..401 over x 600..1200 (centre 400.5). nil: no divider.
    func dividerTable(_ h: CGFloat) -> [(p: CGPoint, path: [Int]?, why: String)] {
        func row(_ x: CGFloat, _ y: CGFloat, _ path: [Int]?, _ why: String) -> (p: CGPoint, path: [Int]?, why: String) {
            (CGPoint(x: x, y: y), path, why)
        }
        return [
            row(600.5, 100, [], "on the root line"),
            row(600.5 - h + 0.05, 100, [], "the root band's left edge, inside"),
            row(600.5 + h - 0.05, 700, [], "the root band's right edge, inside"),
            row(600.5 - h - 1, 100, nil, "one point left of the root band: pane A"),
            row(600.5 + h + 1, 100, nil, "one point right of the root band: pane B"),
            row(300, 400, nil, "inside pane A"),
            row(900, 200, nil, "inside pane B"),
            row(900, 600, nil, "inside pane C"),
            row(900, 400.5, [1], "on the nested line"),
            row(900, 400.5 + h - 0.05, [1], "the nested band's lower edge, inside"),
            row(900, 400.5 - h - 1, nil, "one point above the nested band: pane B"),
            row(601.5, 400.5, [], "where the lines meet: the parent's"),
            row(300, 400.5, nil, "the nested line's row outside its own split (in A)"),
            row(600.5, 800.5, nil, "below the root split's extent"),
            row(600.5, -0.5, nil, "above it"),
        ]
    }

    @MainActor
    func dividerEvent(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    // MARK: The hit area

    /// 7.5: at 0.7, 1.0 and 1.45 the band is 6·s centred on the 1 pt line, clipped to the split; a parent before its
    /// child; the model's lines are where the panes' edges are. Gate off: no divider for any point of the table.
    @MainActor
    func testDividerHitAreaTruthTableAtThreeScalesAndNoneWithTheGateOff() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let size = CGSize(width: 1200, height: 800)
        for scale: CGFloat in [0.7, 1.0, 1.45] {
            ThemeRuntime.scale = scale
            try withTreeGate(true) {
                let m = windowModel(store([session("api", .idle), session("web", .idle), session("docs", .idle)]))
                defer { m.close() }
                m.adopt(dividerNested())
                XCTAssertEqual(m.dividers(in: size).map(\.line), [CGRect(x: 600, y: 0, width: 1, height: 800),
                                                                  CGRect(x: 600, y: 400, width: 600, height: 1)], "scale \(scale)")
                XCTAssertEqual(m.dividers(in: size).map(\.axis), [.columns, .rows])
                for row in dividerTable(3 * scale) {
                    XCTAssertEqual(m.divider(at: row.p, in: size)?.path, row.path, "\(row.why) at scale \(scale)")
                }
                let root = try XCTUnwrap(m.dividers(in: size).first)
                XCTAssertEqual(root.hitArea.width, 6 * scale, accuracy: 0.001, "6·s wide at \(scale)")
                XCTAssertEqual(root.hitArea.height, 800, accuracy: 0.001, "the split's own extent")
            }
            withTreeGate(false) {
                let m = windowModel(store([session("api", .idle), session("web", .idle), session("docs", .idle)]))
                defer { m.close() }
                m.adopt(dividerNested())
                XCTAssertTrue(m.dividers(in: size).isEmpty, "gate off: no divider at \(scale)")
                for row in dividerTable(3 * scale) {
                    XCTAssertTrue(m.divider(at: row.p, in: size) == nil, "gate off, \(row.why) at scale \(scale)")
                    XCTAssertFalse(m.dragBegan(at: row.p, in: size), "gate off: no drag (\(row.why))")
                }
            }
        }
    }

    /// 7.4 / 3.4: zoomed, or too small (the focused pane alone), no divider is hit anywhere; unzoomed they are back.
    @MainActor
    func testDividerNoneWhileZoomedOrTooSmall() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle), session("docs", .idle)]))
            defer { m.close() }
            m.adopt(dividerNested())
            let size = CGSize(width: 1200, height: 800)
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertTrue(m.layout.zoomed != nil)
            for row in dividerTable(3) { XCTAssertTrue(m.divider(at: row.p, in: size) == nil, "zoomed: \(row.why)") }
            XCTAssertTrue(m.dividers(in: size).isEmpty)
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertEqual(m.dividers(in: size).count, 2, "unzoomed: both back")
            let small = CGSize(width: 500, height: 300)   // 300 x 200 per pane does not fit three
            XCTAssertEqual(m.paneFrames(in: CGRect(origin: .zero, size: small)).count, 1, "too small: the focused pane alone")
            XCTAssertTrue(m.dividers(in: small).isEmpty)
            for p in [CGPoint(x: 250.5, y: 100), CGPoint(x: 375, y: 150.5), CGPoint(x: 100, y: 100)] {
                XCTAssertTrue(m.divider(at: p, in: small) == nil, "too small: \(p)")
                XCTAssertFalse(m.dragBegan(at: p, in: small))
            }
        }
    }

    /// Outside data: a point or a size that is not finite is nil (no trap); a drag's move to one changes nothing; the
    /// window's route refuses it before the model reads a frame.
    @MainActor
    func testDividerRefusesNonFinitePointsAndSizes() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let size = CGSize(width: 1000, height: 600)
            let bad = [CGPoint(x: CGFloat.nan, y: 300), CGPoint(x: 500.5, y: .infinity), CGPoint(x: -CGFloat.infinity, y: .nan)]
            let badSizes = [CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 1000, height: CGFloat.nan)]
            for p in bad {
                XCTAssertTrue(m.divider(at: p, in: size) == nil, "\(p)")
                XCTAssertFalse(m.dragBegan(at: p, in: size), "\(p)")
                XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: p, in: CGSize(width: 1600, height: 900)))
            }
            for s in badSizes {
                XCTAssertTrue(m.dividers(in: s).isEmpty, "\(s)")
                XCTAssertTrue(m.divider(at: CGPoint(x: 500.5, y: 300), in: s) == nil, "\(s)")
                XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: CGPoint(x: 800, y: 300), in: s))
            }
            XCTAssertTrue(m.dividerDrag == nil, "no drag began")
            XCTAssertTrue(m.dragBegan(at: CGPoint(x: 500.5, y: 300), in: size))
            m.dragMoved(to: CGPoint(x: 550.5, y: 300))
            let moved = m.layout
            XCTAssertEqual(try XCTUnwrap(dividerRatio(moved, [])), 0.55, accuracy: 1e-9)
            for p in bad {
                m.dragMoved(to: p)
                XCTAssertEqual(m.layout, moved, "a move to \(p) changes nothing")
            }
            m.dragEnded()
        }
    }

    // MARK: The drag

    /// 7.5 / 8.1: 30 literal positions: the ratio follows live, clamped at the minimum at both ends (300 of 1000: 0.3 and
    /// 0.7), one publish per changing move and none for an equal one, 0 saves during the drag and exactly 1 at its end
    /// (`layoutWrites`, the autosave rows' seam); 10 moves held against the clamp publish nothing.
    @MainActor
    func testDividerDragFollowsLiveClampsAndSavesOnceAtTheEnd() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let d = layoutSuite()
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: d)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let size = CGSize(width: 1000, height: 600)
            let writes = m.layoutWrites
            XCTAssertGreaterThan(writes, 0, "the adopt saved: the seam counts")
            var sends = 0
            let sink = m.objectWillChange.sink { _ in sends += 1 }
            defer { sink.cancel() }
            XCTAssertTrue(m.dragBegan(at: CGPoint(x: 500.5, y: 300), in: size))
            XCTAssertEqual(sends, 0, "a down alone changes nothing")
            let xs: [CGFloat] = (1...15).map { 500.5 - 20 * CGFloat($0) } + (1...15).map { 200.5 + 50 * CGFloat($0) }
            XCTAssertEqual(xs.count, 30)
            for x in xs {
                let before = sends, was = m.layout
                m.dragMoved(to: CGPoint(x: x, y: 300 + x / 10))   // the other axis is ignored
                let want = min(max(0.5 + Double(x - 500.5) / 1000, 0.3), 0.7)
                XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), want, accuracy: 1e-9, "x \(x)")
                XCTAssertEqual(sends - before, m.layout == was ? 0 : 1, "x \(x): once per change, none when equal")
                XCTAssertEqual(m.layoutWrites, writes, "x \(x): nothing saved during the drag")
            }
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.7, accuracy: 1e-9, "held at the right clamp")
            let held = sends
            for i in 1...10 { m.dragMoved(to: CGPoint(x: 950.5 + 10 * CGFloat(i), y: 300)) }
            XCTAssertEqual(sends, held, "10 moves against the clamp: no publish (setRatio gives an equal layout)")
            XCTAssertEqual(m.layoutWrites, writes)
            m.dragEnded()
            XCTAssertTrue(m.dividerDrag == nil)
            XCTAssertEqual(m.layoutWrites, writes + 1, "exactly one save, at the end")
            XCTAssertEqual(savedLayouts(d).activeLayout, m.layout, "the saved ratio is the last one")
            m.dragEnded()
            m.dragMoved(to: CGPoint(x: 400, y: 300))
            XCTAssertEqual(m.layoutWrites, writes + 1, "no drag: a move and an up change nothing")
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.7, accuracy: 1e-9)
        }
    }

    /// 8.1: a drag that comes back to where it began saves nothing; a drag that ends where it began saves nothing.
    @MainActor
    func testDividerDragBackToItsStartSavesNothing() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]), layouts: layoutSuite())
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let size = CGSize(width: 1000, height: 600), start = m.layout, writes = m.layoutWrites
            XCTAssertTrue(m.dragBegan(at: CGPoint(x: 501, y: 300), in: size))
            for x: CGFloat in [561, 531, 501] { m.dragMoved(to: CGPoint(x: x, y: 300)) }
            XCTAssertEqual(m.layout, start, "back at the start")
            m.dragEnded()
            XCTAssertEqual(m.layoutWrites, writes, "nothing saved")
            XCTAssertTrue(m.dragBegan(at: CGPoint(x: 500, y: 300), in: size))
            m.dragEnded()
            XCTAssertEqual(m.layoutWrites, writes, "a click on the divider saves nothing")
        }
    }

    /// 7.5: a double-click equalizes THAT split only (the other split's ratio is unchanged) and saves once.
    @MainActor
    func testDividerDoubleClickEqualizesThatSplitOnlyAndSavesOnce() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle), session("docs", .idle)]), layouts: layoutSuite())
            defer { m.close() }
            m.adopt(dividerNested(root: 0.5, nested: 0.3))
            let size = CGSize(width: 1200, height: 800), writes = m.layoutWrites
            XCTAssertTrue(m.dragBegan(at: CGPoint(x: 600.5, y: 100), in: size, clicks: 2))
            m.dragEnded()
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 1.0 / 3, accuracy: 1e-9, "A | (B, C): one leaf of three")
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [1])), 0.3, accuracy: 1e-9, "the nested split unchanged")
            XCTAssertEqual(m.layoutWrites, writes + 1, "saved once")
            // The nested divider now: B over C equalized, the root kept.
            let nestedY = try XCTUnwrap(m.dividers(in: size).last).line.midY
            XCTAssertTrue(m.dragBegan(at: CGPoint(x: 1000, y: nestedY), in: size, clicks: 2))
            m.dragEnded()
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [1])), 0.5, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 1.0 / 3, accuracy: 1e-9, "the root unchanged")
            XCTAssertEqual(m.layoutWrites, writes + 2, "saved once more")
        }
    }

    // MARK: The window's route

    /// 7.5 / 7.6: gate on, a left down on the divider (inside the unfocused pane B's frame: the first-click rule alone
    /// would focus B and swallow it) is the divider's: B is not focused, the drag and the up are the model's, a
    /// double-click equalizes; a right down or a drag with no down is not. Gate off: the route takes nothing and the
    /// model's mouse-down is today's: the focused pane alone at the whole area, so the click passes to it.
    @MainActor
    func testDividerWindowRouteTakesTheDividerBeforeTheFirstClickRule() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let size = CGSize(width: 1600, height: 900)
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let a = try XCTUnwrap(m.paneAreaFrame(in: size)), focused = m.layout.focused
            let line = try XCTUnwrap(m.dividers(in: a.size).first).line
            let p = CGPoint(x: a.minX + line.midX, y: a.minY + 300)
            m.keyFocus = .sidebar
            XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.rightMouseDown), m, at: p, in: size), "a second button")
            XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: p, in: size), "a drag with no down")
            XCTAssertFalse(AgentsNSWindow.divider(dividerEvent(.leftMouseUp), m, at: p, in: size), "an up with no down")
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDown), m, at: p, in: size), "the divider's")
            XCTAssertEqual(m.layout.focused, focused, "B not focused")
            XCTAssertEqual(m.keyFocus, .sidebar, "the keys stay")
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDragged), m, at: CGPoint(x: p.x + 50, y: p.y), in: size))
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.5 + 50 / Double(a.width), accuracy: 1e-9)
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseUp), m, at: CGPoint(x: p.x + 50, y: p.y), in: size))
            XCTAssertTrue(m.dividerDrag == nil)
            let moved = try XCTUnwrap(m.dividers(in: a.size).first).line
            let q = CGPoint(x: a.minX + moved.midX, y: a.minY + 300)
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseDown, clicks: 2), m, at: q, in: size))
            XCTAssertTrue(AgentsNSWindow.divider(dividerEvent(.leftMouseUp, clicks: 2), m, at: q, in: size))
            XCTAssertEqual(try XCTUnwrap(dividerRatio(m.layout, [])), 0.5, accuracy: 1e-9, "a double-click equalizes")
            XCTAssertEqual(m.layout.focused, focused)
            // Today's rule alone, at the line (inside B's half-open frame): it would focus B and swallow the down.
            XCTAssertTrue(AgentsNSWindow.mouseDown(m, at: p, in: size))
            XCTAssertNotEqual(m.layout.focused, focused)
        }
        try withTreeGate(false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let a = try XCTUnwrap(m.paneAreaFrame(in: size)), start = m.layout
            let p = CGPoint(x: a.minX + a.width / 2, y: a.minY + 300)   // where the line would be with the gate on
            for e in [dividerEvent(.leftMouseDown), dividerEvent(.leftMouseDown, clicks: 2), dividerEvent(.leftMouseDragged),
                      dividerEvent(.leftMouseUp)] {
                XCTAssertFalse(AgentsNSWindow.divider(e, m, at: p, in: size), "gate off: \(e.type.rawValue) not the divider's")
            }
            XCTAssertEqual(m.layout, start)
            m.keyFocus = .sidebar
            XCTAssertFalse(AgentsNSWindow.mouseDown(m, at: p, in: size), "gate off: the focused pane alone, the click passes")
            XCTAssertEqual(m.keyFocus, .pane, "as today: the panes take the keys")
            XCTAssertEqual(m.layout, start, "nothing focused, nothing saved")
        }
    }

    // MARK: The view

    /// 7.5: the 1 pt line the view draws (the second pane's edge overlay, through the pane probe on a never-shown window)
    /// is the model's line for A | B; gate off no line is drawn.
    @MainActor
    func testDividerDrawnLineIsTheModelsLine() throws {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        defer { ThemeRuntime.scale = saved; restoreModes() }
        ThemeRuntime.scale = 1.0
        let size = CGSize(width: 1600, height: 900)
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let area = zoomViewArea(size)
            m.paneArea = area
            let snap = paneSnapshot(m, size)
            let line = try XCTUnwrap(m.dividers(in: area.size).first).line
            assertSame(snap["vline 1"], line, "the drawn line is the model's")
            XCTAssertTrue(snap["vline 0"] == nil && !snap.keys.contains { $0.hasPrefix("hline") }, "one line: \(snap.keys.sorted())")
        }
        withTreeGate(false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            m.paneArea = CGRect(origin: .zero, size: CGSize(width: size.width - sz(290) - 1, height: size.height))
            let snap = paneSnapshot(m, size)
            XCTAssertFalse(snap.keys.contains { $0.hasPrefix("vline") || $0.hasPrefix("hline") }, "gate off: \(snap.keys.sorted())")
        }
    }

    // MARK: Item 4: the terminal re-grids once, at the drag's end

    /// 7.5 / 14.2: the window's one terminal (the focused live pane's, Terminal mode) gets 0 setSize during 30 moves,
    /// though its view re-grids on each and the debounce is run, and exactly 1 at the drag's end; a drag that leaves its
    /// grid as sent (an unaffected pane) gets 0. Recorder fakes only: no dch, no session.
    @MainActor
    func testDividerDragResizesTheTerminalOnceAtItsEnd() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withModePref {
            try withTreeGate(true) {
                let st = store([mapped("api"), mapped("web")])
                st.controlDch = bin([1, 38, 0])
                let m = windowModel(st)
                let t = fakeTerminal(m)
                let clock = AgentTerminalTests.Clock()
                m.terminal.after = { clock.schedule($0, $1) }
                Calls().wire(m)
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                let size = CGSize(width: 1000, height: 600)
                m.paneArea = CGRect(origin: .zero, size: size)
                m.setVisible(true)
                defer { m.close() }
                let child = try XCTUnwrap(t.children().last, "the focused live pane's terminal attached")
                let base = child.resizes.count
                XCTAssertTrue(m.dragBegan(at: CGPoint(x: 500.5, y: 300), in: size))
                for i in 1...30 {
                    m.dragMoved(to: CGPoint(x: 500.5 - 5 * CGFloat(i), y: 300))
                    m.terminal.gridChanged(cols: 80 - i, rows: 24)   // the pane's view re-grids as it narrows
                    clock.advance(1)
                }
                XCTAssertEqual(child.resizes.count, base, "0 setSize during the drag")
                m.dragEnded()
                XCTAssertEqual(child.resizes.count, base + 1, "exactly 1 at the end")
                XCTAssertEqual(child.resizes.last, [50, 24], "the last grid")
                clock.advance(1)
                XCTAssertEqual(child.resizes.count, base + 1, "no trailing one")
                XCTAssertTrue(m.dragBegan(at: try XCTUnwrap(m.dividers(in: size).first).line.origin, in: size))
                for i in 1...30 { m.dragMoved(to: CGPoint(x: 350 + CGFloat(i), y: 300)); clock.advance(1) }
                m.dragEnded()
                XCTAssertEqual(child.resizes.count, base + 1, "the grid as sent: 0 for an unaffected pane")
                XCTAssertEqual(t.children().count, 1, "the same client through the drag")
            }
        }
    }
}
