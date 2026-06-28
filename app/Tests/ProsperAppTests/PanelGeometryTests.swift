import XCTest
@testable import ProsperApp

/// Pure placement geometry for the runner / Clipboard History panels (issue #2:
/// open on the active display under the cursor). No real NSScreen needed — these
/// drive `PanelGeometry` with hand-built frames.
final class PanelGeometryTests: XCTestCase {

    // Two side-by-side 1000x1000 displays: main at origin, external to its right.
    private let main = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private let right = CGRect(x: 1000, y: 0, width: 1000, height: 1000)

    func testCursorPicksContainingScreen() {
        let frames = [main, right]
        XCTAssertEqual(PanelGeometry.screenIndex(for: NSPoint(x: 500, y: 500), frames: frames), 0)
        XCTAssertEqual(PanelGeometry.screenIndex(for: NSPoint(x: 1500, y: 500), frames: frames), 1)
    }

    func testCursorOffAllScreensReturnsNil() {
        // Point above both displays (dead space) — caller falls back to main.
        XCTAssertNil(PanelGeometry.screenIndex(for: NSPoint(x: 500, y: 5000), frames: [main, right]))
    }

    func testCenteredOriginCentersOnTheGivenScreen() {
        let size = NSSize(width: 200, height: 100)
        let o = PanelGeometry.centeredOrigin(size: size, in: right)
        // Centered within the right display, not the main one.
        XCTAssertEqual(o.x, 1000 + 500 - 100, accuracy: 0.5)   // vf.midX - w/2
        XCTAssertEqual(o.y, 500 - 50, accuracy: 0.5)            // vf.midY - h/2
    }

    func testRaiseFractionLiftsAboveCenter() {
        let size = NSSize(width: 200, height: 100)
        let centered = PanelGeometry.centeredOrigin(size: size, in: main, raiseFraction: 0)
        let raised = PanelGeometry.centeredOrigin(size: size, in: main, raiseFraction: 0.1)
        XCTAssertEqual(raised.y - centered.y, 100, accuracy: 0.5)  // 0.1 * height(1000)
    }

    func testCenteredOriginClampsInsideVisibleFrame() {
        // A large raise would push the panel off the top; it clamps to the inset.
        let size = NSSize(width: 200, height: 100)
        let o = PanelGeometry.centeredOrigin(size: size, in: main, raiseFraction: 1.0)
        XCTAssertEqual(o.y, main.maxY - size.height - PanelGeometry.edgeInset, accuracy: 0.5)
    }

    func testPanelLargerThanScreenCentersInsteadOfNonsense() {
        // Runner (600 wide) on a tiny 500-wide display: inverted clamp range must
        // center the panel, not jam it to a negative-width edge.
        let tiny = CGRect(x: 0, y: 0, width: 500, height: 400)
        let size = NSSize(width: 600, height: 300)
        let o = PanelGeometry.centeredOrigin(size: size, in: tiny)
        XCTAssertEqual(o.x, tiny.midX - size.width / 2, accuracy: 0.5)  // -50, centered overflow
        XCTAssertEqual(o.y, tiny.midY - size.height / 2, accuracy: 0.5)
    }

    func testRunnerRelativeOriginCentersOnRunnerAndRaises() {
        let size = NSSize(width: 400, height: 300)
        // Runner top-left at x=300 (so center 600) with top edge at y=800 on `main`.
        let o = PanelGeometry.runnerRelativeOrigin(
            size: size, runnerTopLeft: (x: 300, top: 800), runnerWidth: 600,
            screenVisible: main)
        XCTAssertEqual(o.x, 600 - 200, accuracy: 0.5)        // runnerCenterX - w/2
        XCTAssertEqual(o.y, 800 - 300 * 0.7, accuracy: 0.5)  // raised above runner top
    }

    func testRunnerRelativeOriginClampsToRunnerScreen() {
        let size = NSSize(width: 400, height: 300)
        // Runner pushed hard to the right edge of `right`; origin clamps inside it.
        let o = PanelGeometry.runnerRelativeOrigin(
            size: size, runnerTopLeft: (x: 1950, top: 200), runnerWidth: 600,
            screenVisible: right)
        XCTAssertLessThanOrEqual(o.x, right.maxX - size.width - PanelGeometry.edgeInset + 0.5)
        XCTAssertGreaterThanOrEqual(o.x, right.minX + PanelGeometry.edgeInset - 0.5)
    }

    /// Hot-path budget: placement runs once per ⌥Space / Clipboard open on the main
    /// thread before the panel is shown. The pure geometry must be effectively free.
    /// Gate: full cursor-screen resolution (screen pick + centered origin) over a
    /// realistic 3-display arrangement stays under 5µs/call averaged over 100k runs.
    func testPlacementComputeUnderBudget() {
        let frames = [main, right, CGRect(x: 2000, y: 0, width: 1000, height: 1000)]
        let size = NSSize(width: 600, height: 420)
        let iterations = 100_000
        let loc = NSPoint(x: 1500, y: 500)

        let start = DispatchTime.now().uptimeNanoseconds
        var sink: CGFloat = 0
        for _ in 0..<iterations {
            let i = PanelGeometry.screenIndex(for: loc, frames: frames) ?? 0
            let o = PanelGeometry.centeredOrigin(size: size, in: frames[i], raiseFraction: 0.1)
            sink += o.x + o.y
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
        let perCallNs = Double(elapsedNs) / Double(iterations)
        XCTAssertGreaterThan(sink, 0)  // defeat dead-code elimination
        print("placement compute hot path: \(perCallNs) ns/call over \(iterations) iters, 3 displays")
        XCTAssertLessThan(perCallNs, 5_000, "placement compute \(perCallNs)ns/call exceeds 5µs budget")
    }
}
