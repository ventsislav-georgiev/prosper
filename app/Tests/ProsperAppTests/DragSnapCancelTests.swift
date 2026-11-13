import AppKit
import XCTest
@testable import ProsperApp

/// #1003 (QA #19 on #204): the `.mouseCancelled` path, which no test reached (QA's three
/// mutants, mask, cancel-without-abort and cancel-ignored, all survived). No monitor is
/// installed and no window moves: the drop goes through the `snapToEdge` recorder.
@MainActor
final class DragSnapCancelTests: XCTestCase {
    private final class Drops { var actions: [WindowAction] = [] }

    func testMonitorMaskAsksForTheCancelFromMacOS26() {
        // leftMouseDown 1, leftMouseUp 2, leftMouseDragged 6; mouseCancelled 40.
        let base: UInt64 = (1 << 1) | (1 << 2) | (1 << 6)
        if #available(macOS 26, *) {
            XCTAssertEqual(DragSnapController.monitorMask.rawValue, base | (1 << 40))
        } else {
            XCTAssertEqual(DragSnapController.monitorMask.rawValue, base)
        }
    }

    func testEachMonitoredEventMapsToItsStep() throws {
        XCTAssertEqual(DragSnapController.step(for: .leftMouseDown), .begin)
        XCTAssertEqual(DragSnapController.step(for: .leftMouseDragged), .drag)
        XCTAssertEqual(DragSnapController.step(for: .leftMouseUp), .drop)
        XCTAssertEqual(DragSnapController.step(for: try XCTUnwrap(NSEvent.EventType(rawValue: 40))), .cancel)
        XCTAssertTrue(DragSnapController.step(for: .rightMouseDown) == nil)
    }

    /// A drag past the move confirmation, over the left edge zone, as updateDrag leaves it.
    private func confirmedDrag(_ drops: Drops) throws -> DragSnapController {
        let screen = try XCTUnwrap(NSScreen.screens.first, "no screen to stage a drag on")
        let c = DragSnapController()
        c.snapToEdge = { _, action, _ in drops.actions.append(action) }
        c.dragging = true
        c.moveConfirmed = true
        c.win = AXUIElementCreateApplication(getpid())   // never messaged: the recorder takes the drop
        c.currentScreen = screen
        c.currentZone = .left
        return c
    }

    /// Control: the staged drag does snap on a plain drop, so the cancel row below is not vacuous.
    func testADropOfAConfirmedDragSnapsToItsZone() throws {
        let drops = Drops()
        let c = try confirmedDrag(drops)
        c.endDrag()
        XCTAssertEqual(drops.actions, [.leftHalf])
        XCTAssertFalse(c.dragging, "the drop resets the drag")
    }

    func testACancelOfAConfirmedDragNeverSnapsAndResets() throws {
        let drops = Drops()
        let c = try confirmedDrag(drops)
        c.cancelDrag()
        XCTAssertEqual(drops.actions, [], "a cancelled drag must not snap")
        XCTAssertFalse(c.dragging)
        XCTAssertTrue(c.win == nil, "the cancel resets the drag")
        XCTAssertTrue(c.currentZone == nil)
        c.endDrag()   // a stray mouse-up after the cancel
        XCTAssertEqual(drops.actions, [], "a mouse-up after the cancel must not snap either")
    }
}
