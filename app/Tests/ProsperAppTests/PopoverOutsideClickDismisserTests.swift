import XCTest
@testable import ProsperApp

// #149: inside clicks must keep the popover open; outside clicks close it.
final class PopoverOutsideClickDismisserTests: XCTestCase {
    private let frame = NSRect(x: 100, y: 200, width: 300, height: 400)

    func testInsideKeepsOpen() {
        XCTAssertFalse(PopoverOutsideClickDismisser.shouldDismiss(click: NSPoint(x: 250, y: 400), popoverFrame: frame))
    }

    func testOutsideCloses() {
        XCTAssertTrue(PopoverOutsideClickDismisser.shouldDismiss(click: NSPoint(x: 50, y: 400), popoverFrame: frame))
        XCTAssertTrue(PopoverOutsideClickDismisser.shouldDismiss(click: NSPoint(x: 250, y: 601), popoverFrame: frame))
    }

    func testNilFrameCloses() {
        XCTAssertTrue(PopoverOutsideClickDismisser.shouldDismiss(click: NSPoint(x: 250, y: 400), popoverFrame: nil))
    }

    func testEdgesCountAsInside() {
        for p in [NSPoint(x: 100, y: 200), NSPoint(x: 400, y: 600), NSPoint(x: 400, y: 300), NSPoint(x: 250, y: 600)] {
            XCTAssertFalse(PopoverOutsideClickDismisser.shouldDismiss(click: p, popoverFrame: frame), "\(p)")
        }
    }
}
