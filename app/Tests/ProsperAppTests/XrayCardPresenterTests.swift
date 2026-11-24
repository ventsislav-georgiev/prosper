import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1760 (was #1432's popover rows): the product presenter is a Prosper card panel, never an NSPopover. Its `order`
/// seam is a recorder here: no panel is ever ordered front or made key; resign-key (a click outside) is posted for the
/// never-shown panel and Escape is its cancelOperation.
@MainActor
final class XrayCardPresenterTests: XCTestCase {
    typealias O = XrayCardPanelPresenter.Order
    func presenter() -> (XrayCardPanelPresenter, () -> [O]) {
        let p = XrayCardPanelPresenter()
        var shows: [O] = []
        p.order = { _, _, o in shows.append(o) }
        return (p, { shows })
    }

    func show(_ p: XrayCardPanelPresenter, _ closed: @escaping @MainActor () -> Void) {
        p.present(AnyView(Text(verbatim: "card")), size: CGSize(width: 460, height: 520), anchor: NSView(), closed: closed)
    }

    /// A clicked or keyboard open asks for key (#1931: the only open; the quiet hover card is gone).
    func testAClickOpenRequestsKey() {
        let (p, shows) = presenter()
        p.present(AnyView(Text(verbatim: "card")), size: CGSize(width: 460, height: 520), anchor: NSView()) {}
        XCTAssertEqual(shows(), [.showKey])
        XCTAssertTrue(p.panel?.canBecomeKey == true)
        p.close()
    }

    /// Red with the NSPopover presenter: the card is a borderless clear panel with the system shadow, shown by the seam.
    func testPresentShowsAProsperCardPanelThroughTheSeam() throws {
        let (p, shows) = presenter()
        show(p) {}
        let panel = try XCTUnwrap(p.panel)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.hasShadow)
        XCTAssertTrue(p.isShown)
        XCTAssertEqual(shows(), [.showKey])
        p.close()
    }

    /// Red without the cancelOperation hook: Escape closes the card once.
    func testEscapeClosesTheCardOnce() throws {
        let (p, shows) = presenter()
        var ran = 0
        show(p) { ran += 1 }
        p.panel?.cancelOperation(nil)
        p.panel?.cancelOperation(nil)
        XCTAssertEqual(ran, 1)
        XCTAssertFalse(p.isShown)
        XCTAssertEqual(shows(), [.showKey, .hide])
    }

    /// Red without the resign-key observer: a click outside (the panel resigns key) closes the card once.
    func testOutsideClickClosesTheCardOnce() throws {
        let (p, _) = presenter()
        var ran = 0
        show(p) { ran += 1 }
        let panel = try XCTUnwrap(p.panel)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        XCTAssertEqual(ran, 1)
        XCTAssertTrue(p.panel == nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        XCTAssertEqual(ran, 1, "a second resign does nothing")
    }

    /// #1432 kept: a replaced card's late resign leaves the new card and its closed alone.
    func testStaleResignLeavesTheNewCardAlone() throws {
        let (p, _) = presenter()
        var first = 0, second = 0
        show(p) { first += 1 }
        let old = try XCTUnwrap(p.panel)
        show(p) { second += 1 }
        XCTAssertEqual(first, 1, "the old card's closed ran when the new one came")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: old)
        XCTAssertEqual(second, 0)
        XCTAssertTrue(p.isShown)
        p.close()
        XCTAssertEqual(second, 1)
    }

    // MARK: placement (pure: screen points, y up)

    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 460, height: 520)

    /// Red with the drawer ignored: the card went under the anchor, over the drawer's list.
    func testWithTheDrawerOpenTheCardNeverCoversIt() {
        let window = CGRect(x: 100, y: 100, width: 1200, height: 700)
        let anchor = CGRect(x: 1250, y: 760, width: 20, height: 20)
        let right = CGRect(x: 1000, y: 100, width: 300, height: 700)
        let r = XrayCardPanelPresenter.frame(size: size, anchor: anchor, drawer: right, window: window, screen: screen)
        XCTAssertFalse(r.intersects(right), "a drawer on the right: the card is beside it")
        XCTAssertLessThanOrEqual(r.maxX, right.minX)
        XCTAssertEqual(r.maxY, anchor.maxY, accuracy: 0.5, "top aligned to the anchor")
        let left = CGRect(x: 100, y: 100, width: 300, height: 700)
        let l = XrayCardPanelPresenter.frame(size: size, anchor: CGRect(x: 150, y: 760, width: 20, height: 20), drawer: left,
                                             window: window, screen: screen)
        XCTAssertFalse(l.intersects(left), "a drawer on the left: the card is beside it")
        XCTAssertGreaterThanOrEqual(l.minX, left.maxX)
    }

    func testTheOtherSideOnlyWhenTheFirstHasNoRoom() {
        let window = CGRect(x: 0, y: 0, width: 700, height: 900)
        let drawer = CGRect(x: 300, y: 0, width: 300, height: 900)   // right half of its window, no room on its left
        let r = XrayCardPanelPresenter.frame(size: size, anchor: CGRect(x: 580, y: 860, width: 20, height: 20), drawer: drawer,
                                             window: window, screen: screen)
        XCTAssertGreaterThanOrEqual(r.minX, drawer.maxX, "flipped to the right")
        XCTAssertFalse(r.intersects(drawer))
    }

    func testNeitherSideHasRoomOverlapsAtMostTheOverflow() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 900), drawer = CGRect(x: 200, y: 0, width: 400, height: 900)
        let r = XrayCardPanelPresenter.frame(size: size, anchor: CGRect(x: 580, y: 860, width: 20, height: 20), drawer: drawer,
                                             window: small, screen: small)
        XCTAssertTrue(small.contains(r))
        XCTAssertLessThanOrEqual(r.intersection(drawer).width, size.width + 6 - 200 + 6 + 0.5, "only the overflow")
    }

    /// Red without the clamp: the 460x520 card ran off a small screen.
    func testTheSizeClampsToASmallScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
        let r = XrayCardPanelPresenter.frame(size: size, anchor: CGRect(x: 200, y: 280, width: 10, height: 10), drawer: nil,
                                             window: tiny, screen: tiny)
        XCTAssertTrue(tiny.contains(r))
        XCTAssertEqual(r.width, 400 - 12)
        XCTAssertEqual(r.height, 300 - 12)
    }

    /// Without a drawer: today's place, centred below the anchor.
    func testANonDrawerAnchorKeepsTodaysPlacement() {
        let anchor = CGRect(x: 500, y: 600, width: 20, height: 20)
        XCTAssertEqual(XrayCardPanelPresenter.frame(size: size, anchor: anchor, drawer: nil, window: nil, screen: screen),
                       CGRect(x: 510 - 230, y: 600 - 6 - 520, width: 460, height: 520))
    }
}
