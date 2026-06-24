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
}
