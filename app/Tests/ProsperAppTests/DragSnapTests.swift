import XCTest
import AppKit
@testable import ProsperApp

/// Drag-to-snap geometry + the hot-path budget. `SnapZone.at` runs on every mouse
/// drag event (~120 Hz) and `WindowManager.targetFrame` feeds both the live
/// footprint preview and the final drop, so both must be exact AND cheap.
final class DragSnapTests: XCTestCase {

    // A 1440×900 main screen at the AX origin, and the same screen offset to the
    // right (second display) to prove classification is screen-relative, not
    // absolute. AX top-left coords: minY is the top edge.
    private let scr = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let m: CGFloat = 8      // edge margin
    private let c: CGFloat = 70     // corner size

    private func zone(_ x: CGFloat, _ y: CGFloat, screen: CGRect? = nil) -> SnapZone? {
        SnapZone.at(cursorAX: CGPoint(x: x, y: y), screenAX: screen ?? scr,
                    edgeMargin: m, cornerSize: c)
    }

    // MARK: - Zone classification

    func testEdges() {
        XCTAssertEqual(zone(2, 450), .left)
        XCTAssertEqual(zone(1438, 450), .right)
        XCTAssertEqual(zone(720, 2), .top)
        XCTAssertEqual(zone(720, 898), .bottom)
    }

    func testCorners() {
        XCTAssertEqual(zone(2, 2), .topLeft)
        XCTAssertEqual(zone(1438, 2), .topRight)
        XCTAssertEqual(zone(2, 898), .bottomLeft)
        XCTAssertEqual(zone(1438, 898), .bottomRight)
    }

    func testInteriorIsNil() {
        XCTAssertNil(zone(720, 450))
        XCTAssertNil(zone(200, 200))   // inside corner column but far from any edge
    }

    /// A point in the top-left corner SQUARE but only near the left edge band must
    /// still classify as the corner — corners win over edges.
    func testCornerBeatsEdge() {
        // x=2 (near left edge), y=40 (inside top corner row c=70, but y>m=8 so not
        // near the top edge). Left column + top row ⇒ topLeft, not left.
        XCTAssertEqual(zone(2, 40), .topLeft)
        // Symmetric: near top edge, inside left corner column.
        XCTAssertEqual(zone(40, 2), .topLeft)
    }

    /// Just inside vs just outside the edge margin.
    func testMarginBoundary() {
        XCTAssertEqual(zone(8, 450), .left)    // p.x == minX + m ⇒ still "near"
        XCTAssertNil(zone(9, 450))             // one past the margin ⇒ interior
    }

    /// Classification is relative to the screen's own frame, not the global origin.
    func testSecondDisplayOffset() {
        let right = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        XCTAssertEqual(zone(1442, 450, screen: right), .left)
        XCTAssertEqual(zone(2878, 450, screen: right), .right)
        XCTAssertEqual(zone(1442, 2, screen: right), .topLeft)
        XCTAssertNil(zone(2160, 450, screen: right))   // centre of the right screen
    }

    // MARK: - Zone → action mapping

    func testZoneActions() {
        XCTAssertEqual(SnapZone.left.action, .leftHalf)
        XCTAssertEqual(SnapZone.right.action, .rightHalf)
        XCTAssertEqual(SnapZone.top.action, .maximize)        // top edge = maximize
        XCTAssertEqual(SnapZone.bottom.action, .bottomHalf)
        XCTAssertEqual(SnapZone.topLeft.action, .topLeftQuarter)
        XCTAssertEqual(SnapZone.bottomRight.action, .bottomRightQuarter)
    }

    // MARK: - targetFrame geometry

    @MainActor
    func testTargetFrames() {
        let v = CGRect(x: 0, y: 25, width: 1440, height: 875)   // minus menu bar
        let cur = CGRect(x: 300, y: 300, width: 400, height: 300)
        func t(_ a: WindowAction) -> CGRect {
            WindowManager.targetFrame(for: a, visible: v, current: cur)
        }
        XCTAssertEqual(t(.leftHalf), CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(t(.rightHalf), CGRect(x: 720, y: 25, width: 720, height: 875))
        XCTAssertEqual(t(.topHalf), CGRect(x: 0, y: 25, width: 1440, height: 438))
        XCTAssertEqual(t(.bottomHalf), CGRect(x: 0, y: 462, width: 1440, height: 438))
        XCTAssertEqual(t(.maximize), v)
        XCTAssertEqual(t(.topLeftQuarter), CGRect(x: 0, y: 25, width: 720, height: 438))
        XCTAssertEqual(t(.topRightQuarter), CGRect(x: 720, y: 25, width: 720, height: 438))
        XCTAssertEqual(t(.bottomLeftQuarter), CGRect(x: 0, y: 462, width: 720, height: 438))
        XCTAssertEqual(t(.bottomRightQuarter), CGRect(x: 720, y: 462, width: 720, height: 438))
    }

    /// Drag zones must never depend on the window's `current` frame (only `.center`
    /// does) — otherwise the hot path would have to poll the window's position via
    /// AX on every event. Same frame for two very different `current` values proves it.
    @MainActor
    func testDragZonesIgnoreCurrentFrame() {
        let v = CGRect(x: 0, y: 25, width: 1440, height: 875)
        for z in [SnapZone.left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight] {
            let a = WindowManager.targetFrame(for: z.action, visible: v, current: .zero)
            let b = WindowManager.targetFrame(for: z.action, visible: v,
                                              current: CGRect(x: 9, y: 9, width: 99, height: 99))
            XCTAssertEqual(a, b, "\(z) must ignore current frame")
        }
    }

    /// The keyboard repeat-press cycle: leftHalf at 1/4 fraction is a quarter-width.
    @MainActor
    func testFractionCycle() {
        let v = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let half = WindowManager.targetFrame(for: .leftHalf, visible: v, current: .zero, fraction: 0.5)
        let quarter = WindowManager.targetFrame(for: .leftHalf, visible: v, current: .zero, fraction: 0.25)
        XCTAssertEqual(half.width, 500)
        XCTAssertEqual(quarter.width, 250)
    }

    // MARK: - Modifier gate

    func testModifierGate() {
        XCTAssertTrue(DragSnapModifier.none.isSatisfied(by: []))
        XCTAssertTrue(DragSnapModifier.none.isSatisfied(by: .control))
        XCTAssertTrue(DragSnapModifier.control.isSatisfied(by: [.control, .shift]))
        XCTAssertFalse(DragSnapModifier.control.isSatisfied(by: .option))
        XCTAssertTrue(DragSnapModifier.option.isSatisfied(by: .option))
        XCTAssertFalse(DragSnapModifier.command.isSatisfied(by: []))
    }

    // MARK: - Hot-path budget
    //
    // Per-drag-event steady-state geometry (zone classify + target compute) must be
    // a sub-microsecond pure computation with NO allocation and NO AX IPC. Budget:
    // 200k iterations < 200 ms ⇒ < 1 µs each. Generous vs the real ~tens-of-ns cost,
    // so it won't flake under CI load, but it WILL catch an accidental AX/alloc call
    // sneaking back onto the hot path (those cost 100µs–ms each → blow the budget by
    // orders of magnitude).
    @MainActor
    func testHotPathBudget() {
        let v = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let iterations = 200_000
        var sink = CGRect.zero
        let start = DispatchTime.now()
        for i in 0..<iterations {
            // Sweep the cursor along the top edge so classification varies per call.
            let x = CGFloat(i % 1440)
            if let z = SnapZone.at(cursorAX: CGPoint(x: x, y: 4), screenAX: scr,
                                   edgeMargin: m, cornerSize: c) {
                sink = WindowManager.targetFrame(for: z.action, visible: v, current: .zero)
            }
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        XCTAssertFalse(sink.isEmpty)   // keep the optimizer honest
        XCTAssertLessThan(elapsedMs, 200, "hot-path geometry too slow: \(elapsedMs) ms for \(iterations) iters")
    }
}
