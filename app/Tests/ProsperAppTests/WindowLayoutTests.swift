import XCTest
import CoreGraphics
@testable import ProsperApp

@MainActor
final class WindowLayoutTests: XCTestCase {

    // MARK: - Built-ins

    func testBuiltinsDecodeAndResolve() {
        // Force-unwrapped UUID strings must be valid hex, or this crashes.
        let store = LayoutStore.builtins
        XCTAssertFalse(store.allLayouts.isEmpty)
        XCTAssertNotNil(store.activeLayout)
        // Thirds mirrors the Lua extension's clean 1/3 fractions.
        let thirds = store.allLayouts.first { $0.name == "Thirds" }
        XCTAssertEqual(thirds?.zones.count, 3)
        XCTAssertEqual(thirds?.zones[1].rect.minX ?? 0, 1.0 / 3, accuracy: 1e-9)
    }

    func testCodableRoundTrip() throws {
        let store = LayoutStore.builtins
        let data = try JSONEncoder().encode(store)
        let back = try JSONDecoder().decode(LayoutStore.self, from: data)
        XCTAssertEqual(store, back)
    }

    func testGarbageDecodeThrows() {
        // Contract the Preferences fallback relies on: a bad blob fails to decode
        // (so the getter can fall back to built-ins instead of crashing).
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutStore.self, from: Data("nope".utf8)))
    }

    func testMoveOnlyDefaultsFalseAndIsOptional() throws {
        // Old JSON without the moveOnly key must decode (nil → false).
        let json = #"{"id":"00000000-0000-0000-0000-00000000a001","name":"X","zones":[]}"#
        let layout = try JSONDecoder().decode(WindowLayout.self, from: Data(json.utf8))
        XCTAssertFalse(layout.isMoveOnly)
    }

    // MARK: - hitZone

    private var halves: [LayoutZone] {
        [LayoutZone(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
         LayoutZone(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))]
    }

    func testHitZoneInsideEachZone() {
        XCTAssertEqual(LayoutStore.hitZone(halves, normCursor: CGPoint(x: 0.25, y: 0.5)), 0)
        XCTAssertEqual(LayoutStore.hitZone(halves, normCursor: CGPoint(x: 0.75, y: 0.5)), 1)
    }

    func testHitZoneRejectsOutOfBounds() {
        XCTAssertNil(LayoutStore.hitZone(halves, normCursor: CGPoint(x: 1.5, y: 0.5)))
        XCTAssertNil(LayoutStore.hitZone(halves, normCursor: CGPoint(x: -0.1, y: 0.5)))
        XCTAssertNil(LayoutStore.hitZone(halves, normCursor: CGPoint(x: 0.5, y: 1.2)))
    }

    // MARK: - Geometry

    func testEqualThirdsGetEqualWidths() {
        // The regression: independent per-zone insets/rounding must not drift the
        // outer thirds narrower than the center. All three widths within 1px.
        let v = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let third = CGFloat(1) / 3
        let zones = [
            LayoutZone(rect: CGRect(x: 0, y: 0, width: third, height: 1)),
            LayoutZone(rect: CGRect(x: third, y: 0, width: third, height: 1)),
            LayoutZone(rect: CGRect(x: 2 * third, y: 0, width: third, height: 1)),
        ]
        let frames = WindowManager.targetFrames(layout: zones, visible: v, gap: 10)
        let widths = frames.map { $0.width }
        XCTAssertEqual(widths[0], widths[1], accuracy: 1)
        XCTAssertEqual(widths[1], widths[2], accuracy: 1)
    }

    func testGapBetweenAdjacentZones() {
        let v = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let zones = [
            LayoutZone(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            LayoutZone(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        ]
        let f = WindowManager.targetFrames(layout: zones, visible: v, gap: 20)
        // Outer margin to screen edge == gap; inter-window gap == gap.
        XCTAssertEqual(f[0].minX - v.minX, 20, accuracy: 1)
        XCTAssertEqual(f[1].minX - f[0].maxX, 20, accuracy: 1)
        XCTAssertEqual(v.maxX - f[1].maxX, 20, accuracy: 1)
    }

    func testMaximizeZoneLeavesGapMargin() {
        let v = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let max = WindowManager.targetFrame(zone: CGRect(x: 0, y: 0, width: 1, height: 1),
                                            visible: v, gap: 16)
        XCTAssertEqual(max.minX - v.minX, 16, accuracy: 1)
        XCTAssertEqual(max.minY - v.minY, 16, accuracy: 1)
        XCTAssertEqual(v.maxX - max.maxX, 16, accuracy: 1)
    }

    func testPreviewEqualsPlacement() {
        // The overlay tile and the drop both come from targetFrame(zone:) — pin it.
        let v = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let rect = CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5)
        let tile = WindowManager.targetFrames(layout: [LayoutZone(rect: rect)], visible: v, gap: 8)[0]
        let drop = WindowManager.targetFrame(zone: rect, visible: v, gap: 8)
        XCTAssertEqual(tile, drop)
    }

    func testZeroGapTiles() {
        let v = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = WindowManager.targetFrame(zone: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                                          visible: v, gap: 0)
        XCTAssertEqual(f, CGRect(x: 0, y: 0, width: 500, height: 800))
    }

    // MARK: - Geometry edge cases

    func testThinZonePlusLargeGapStaysInFrame() {
        // A degenerate too-thin zone with the max gap must NOT become an off-position
        // 1px sliver — clamp keeps it ≥1px AND inside the visible frame.
        let v = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let f = WindowManager.targetFrame(zone: CGRect(x: 0.45, y: 0, width: 0.02, height: 1),
                                          visible: v, gap: 40)
        XCTAssertGreaterThanOrEqual(f.width, 1)
        XCTAssertGreaterThanOrEqual(f.height, 1)
        XCTAssertGreaterThanOrEqual(f.minX, v.minX)
        XCTAssertLessThanOrEqual(f.maxX, v.maxX)
    }

    func testAdjacentZoneGapHoldsOnOddWidths() {
        // Pin the documented ≤1px drift ceiling on a non-power-of-two width so a
        // future change can't silently widen the inter-zone gap.
        let v = CGRect(x: 0, y: 0, width: 1001, height: 800)
        let third = CGFloat(1) / 3
        let zones = (0..<3).map { LayoutZone(rect: CGRect(x: CGFloat($0) * third, y: 0, width: third, height: 1)) }
        let f = WindowManager.targetFrames(layout: zones, visible: v, gap: 10)
        XCTAssertEqual(f[1].minX - f[0].maxX, 10, accuracy: 1)
        XCTAssertEqual(f[2].minX - f[1].maxX, 10, accuracy: 1)
    }

    func testZeroGapAdjacentZonesNoBigOverlap() {
        // gap=0 thirds on an odd width: independent rounding can overlap/seam by ≤1px;
        // assert it never exceeds that (a 5px overlap would be a real regression).
        let v = CGRect(x: 0, y: 0, width: 1001, height: 800)
        let third = CGFloat(1) / 3
        let zones = (0..<3).map { LayoutZone(rect: CGRect(x: CGFloat($0) * third, y: 0, width: third, height: 1)) }
        let f = WindowManager.targetFrames(layout: zones, visible: v, gap: 0)
        XCTAssertLessThanOrEqual(abs(f[1].minX - f[0].maxX), 1)
        XCTAssertLessThanOrEqual(abs(f[2].minX - f[1].maxX), 1)
    }

    func testMoveOnlyClampsOversizedWindowToOrigin() {
        // A window wider/taller than the visible frame pins to the top-left edge.
        let v = CGRect(x: 100, y: 50, width: 800, height: 600)
        let o = WindowManager.moveOnlyOrigin(zoneOrigin: CGPoint(x: 500, y: 400),
                                              size: CGSize(width: 2000, height: 1500), visible: v)
        XCTAssertEqual(o.x, v.minX)
        XCTAssertEqual(o.y, v.minY)
    }

    func testMoveOnlyClampsNormalWindowWithinFrame() {
        // A normally-sized window keeps its anchor but can't overflow the right/bottom.
        let v = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let o = WindowManager.moveOnlyOrigin(zoneOrigin: CGPoint(x: 900, y: 700),
                                             size: CGSize(width: 400, height: 300), visible: v)
        XCTAssertEqual(o.x, 600)   // 1000 - 400
        XCTAssertEqual(o.y, 500)   // 800 - 300
    }

    // MARK: - Palette position labels

    func testPalettePositionNames() {
        func name(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> String {
            LayoutPaletteWindow.positionName(CGRect(x: x, y: y, width: w, height: h))
        }
        XCTAssertEqual(name(0, 0, 1, 1), "Full")
        XCTAssertEqual(name(0, 0, 0.5, 1), "Left Half")
        XCTAssertEqual(name(0.5, 0, 0.5, 1), "Right Half")
        XCTAssertEqual(name(0, 0, 1, 0.5), "Top Half")
        XCTAssertEqual(name(0, 0.5, 1, 0.5), "Bottom Half")
        XCTAssertEqual(name(0.5, 0.5, 0.5, 0.5), "Bottom Right")
        XCTAssertEqual(name(0, 0, 0.5, 0.5), "Top Left")
    }

    // MARK: - Hot-path budget
    //
    // Layout drag hot path (~120 Hz while a window is dragged in .layouts mode):
    //   updateLayoutDrag → hitZone (per event) + targetFrames (only on layout/
    //   screen change). Requirement: the per-event work — normalize cursor +
    //   hitZone over a representative layout — must be allocation-light pure
    //   geometry. Budget: 200k iterations < 200 ms (≈1µs/event, same gate as the
    //   edge-snap testHotPathBudget). A regression here means heap allocation or
    //   an AX/IPC call snuck onto the per-event path.
    func testLayoutHotPathBudget() {
        let v = CGRect(x: 0, y: 25, width: 1440, height: 875)
        // Grid 2×2 — 4 zones, the densest built-in; reverse-scan hitZone worst case.
        let zones = LayoutStore.builtins.allLayouts.first { $0.name == "Grid 2×2" }!.zones
        let iterations = 200_000
        var hits = 0
        let start = DispatchTime.now()
        for i in 0..<iterations {
            // Sweep the cursor across the whole visible frame so the hit zone varies.
            let cur = CGPoint(x: v.minX + CGFloat(i % 1440), y: v.minY + CGFloat(i % 875))
            let p = CGPoint(x: (cur.x - v.minX) / v.width, y: (cur.y - v.minY) / v.height)
            if LayoutStore.hitZone(zones, normCursor: p) != nil { hits += 1 }
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        XCTAssertGreaterThan(hits, 0)   // keep the optimizer honest
        XCTAssertLessThan(elapsedMs, 200, "layout hit-test too slow: \(elapsedMs) ms for \(iterations) iters")
    }

    // targetFrames runs only on a layout/screen change (not per event), but a
    // full overlay rebuild still must stay well under one frame (16 ms). 50k
    // full-layout computations < 200 ms pins it as cheap.
    func testTargetFramesBudget() {
        let v = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let zones = LayoutStore.builtins.allLayouts.first { $0.name == "Grid 2×2" }!.zones
        let iterations = 50_000
        var sink = 0
        let start = DispatchTime.now()
        for _ in 0..<iterations {
            sink &+= WindowManager.targetFrames(layout: zones, visible: v, gap: 8).count
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        XCTAssertEqual(sink, iterations * zones.count)
        XCTAssertLessThan(elapsedMs, 200, "targetFrames too slow: \(elapsedMs) ms for \(iterations) iters")
    }

    // MARK: - Drag move-confirm (DragSnapController.didMove)

    func testDidMoveNilOperandsNeverMove() {
        let p = CGPoint(x: 10, y: 10)
        XCTAssertFalse(DragSnapController.didMove(from: nil, to: p))   // origin unreadable at start
        XCTAssertFalse(DragSnapController.didMove(from: p, to: nil))   // poll failed this event
        XCTAssertFalse(DragSnapController.didMove(from: nil, to: nil))
    }

    func testDidMoveEpsilonBoundary() {
        let e = DragSnapController.moveConfirmEpsilon
        let o = CGPoint(x: 100, y: 100)
        // Exactly epsilon on either axis is NOT a move (strict >), so rounding jitter
        // up to epsilon on a stationary window can't false-confirm.
        XCTAssertFalse(DragSnapController.didMove(from: o, to: CGPoint(x: 100 + e, y: 100)))
        XCTAssertFalse(DragSnapController.didMove(from: o, to: CGPoint(x: 100, y: 100 + e)))
        XCTAssertFalse(DragSnapController.didMove(from: o, to: CGPoint(x: 100 - e, y: 100 - e)))
        // Just past epsilon on either axis (either direction) IS a move.
        XCTAssertTrue(DragSnapController.didMove(from: o, to: CGPoint(x: 100 + e + 0.01, y: 100)))
        XCTAssertTrue(DragSnapController.didMove(from: o, to: CGPoint(x: 100, y: 100 - e - 0.01)))
    }

    // The controller confirms on EITHER source: app AX origin OR window-server origin.
    // These two scenarios are the whole reason the OR exists.
    func testMoveConfirmOrSemantics() {
        let start = CGPoint(x: 200, y: 200)
        let moved = CGPoint(x: 260, y: 200)
        // Telegram/Qt: AX origin stays pinned during the drag, window server tracks it.
        let telegram = DragSnapController.didMove(from: start, to: start)        // AX pinned
            || DragSnapController.didMove(from: start, to: moved)                // server moved
        XCTAssertTrue(telegram, "window-server movement must confirm even when AX is pinned")
        // Ghostty text selection: neither the AX origin nor the server origin moves.
        let ghostty = DragSnapController.didMove(from: start, to: start)
            || DragSnapController.didMove(from: start, to: start)
        XCTAssertFalse(ghostty, "a non-moving drag must never confirm")
    }

    // MARK: - Window-server picker (WindowManager.pickWindow)

    private func winInfo(id: CGWindowID, pid: pid_t, layer: Int, _ b: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id,
         kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer,
         kCGWindowBounds as String: CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height)
            .dictionaryRepresentation]
    }

    func testPickWindowTopmostContainingCursor() {
        // Front-to-back order: two layer-0 windows overlap; the first one wins.
        let infos = [winInfo(id: 1, pid: 10, layer: 0, CGRect(x: 0, y: 0, width: 200, height: 200)),
                     winInfo(id: 2, pid: 20, layer: 0, CGRect(x: 0, y: 0, width: 400, height: 400))]
        let hit = WindowManager.pickWindow(infos: infos, cursor: CGPoint(x: 50, y: 50))
        XCTAssertEqual(hit?.windowID, 1)
        XCTAssertEqual(hit?.pid, 10)        // the front window's pid, not the larger one's
    }

    func testPickWindowSkipsNonZeroLayers() {
        // A menubar/panel (layer > 0) over the cursor must be skipped for the real
        // window beneath it.
        let infos = [winInfo(id: 9, pid: 99, layer: 25, CGRect(x: 0, y: 0, width: 100, height: 100)),
                     winInfo(id: 3, pid: 30, layer: 0, CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertEqual(WindowManager.pickWindow(infos: infos, cursor: CGPoint(x: 10, y: 10))?.windowID, 3)
    }

    func testPickWindowMissReturnsNil() {
        let infos = [winInfo(id: 1, pid: 10, layer: 0, CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertNil(WindowManager.pickWindow(infos: infos, cursor: CGPoint(x: 500, y: 500)))
        XCTAssertNil(WindowManager.pickWindow(infos: [], cursor: CGPoint(x: 10, y: 10)))
    }

    // Hot-path requirement: the move-confirm decision runs at most once per drag
    // event while pre-confirm (≤ ~12 events per drag total — it stops the instant the
    // window moves or the no-move cap aborts), so it must be effectively free. Ceiling
    // is sized for an unoptimized test build (~100 ns/call); the point isn't the
    // absolute number but to fail loudly if didMove ever regresses into allocation or
    // real work (which would push it to µs/call → seconds here).
    func testDidMoveBudget() {
        let start = CGPoint(x: 0, y: 0)
        let iterations = 1_000_000
        var hits = 0
        let t0 = DispatchTime.now()
        for i in 0..<iterations {
            let now = CGPoint(x: CGFloat(i % 5), y: 0)   // straddles the epsilon
            if DragSnapController.didMove(from: start, to: now) { hits += 1 }
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        XCTAssertGreaterThan(hits, 0)
        XCTAssertLessThan(elapsedMs, 200, "didMove too slow: \(elapsedMs) ms for \(iterations) iters")
    }
}
