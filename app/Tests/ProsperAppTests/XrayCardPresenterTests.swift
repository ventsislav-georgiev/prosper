import AppKit
import XCTest
@testable import ProsperApp

/// #1432: a late did-close of a replaced popover must not touch the new card. The popovers here are never shown: the
/// presenter's state is set through its internal fields and the delegate method is called directly.
@MainActor
final class XrayCardPresenterTests: XCTestCase {
    func testStaleDidCloseLeavesTheNewCardAndItsClosedAlone() {
        let presenter = XrayPopoverPresenter()
        let current = NSPopover()
        var ran = 0
        presenter.popover = current
        presenter.closed = { ran += 1 }
        presenter.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: NSPopover()))
        XCTAssertEqual(ran, 0)
        XCTAssertTrue(presenter.popover === current)
        XCTAssertTrue(presenter.closed != nil)
    }

    func testDidCloseOfTheCurrentPopoverRunsClosedOnceAndClearsTheState() {
        let presenter = XrayPopoverPresenter()
        let current = NSPopover()
        var ran = 0
        presenter.popover = current
        presenter.closed = { ran += 1 }
        presenter.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: current))
        XCTAssertEqual(ran, 1)
        XCTAssertTrue(presenter.popover == nil)
        XCTAssertTrue(presenter.closed == nil)
    }
}
