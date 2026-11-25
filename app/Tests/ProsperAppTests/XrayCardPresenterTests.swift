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

    /// Red with canBecomeKey false (#1934): a borderless panel must be key for the filter field, Esc and the resign-key close.
    func testTheCardPanelCanBecomeKeyButNotMain() throws {
        let (p, shows) = presenter()
        show(p) {}
        let panel = try XCTUnwrap(p.panel)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(shows(), [.showKey], "the seam that targets this key-capable panel")
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

    // MARK: #1944 the back stack (a card opened from inside a card)

    func push(_ p: XrayCardPanelPresenter, _ text: String = "pushed", _ closed: @escaping @MainActor () -> Void) {
        p.push(AnyView(Text(verbatim: text)), size: CGSize(width: 460, height: 520), anchor: NSView(), closed: closed)
    }

    /// Red with push as present (the old card's closed ran, no stack) and with Back as close: the first card's own panel
    /// comes back, its closed not run; the pushed card's closed ran once.
    func testPushThenBackShowsTheFirstCardAgain() throws {
        let (p, shows) = presenter()
        var log: [String] = []
        show(p) { log.append("a") }
        let first = try XCTUnwrap(p.panel)
        push(p) { log.append("b") }
        XCTAssertEqual(log, [], "a push runs no closed")
        XCTAssertFalse(p.panel === first)
        XCTAssertEqual(p.under.count, 1)
        XCTAssertEqual(shows(), [.showKey, .hide, .showKey])
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertEqual(log, [], "the hidden card's resign key is no click outside")
        p.back()
        XCTAssertEqual(log, ["b"])
        XCTAssertTrue(p.panel === first, "the first card itself, its state kept")
        XCTAssertEqual(p.under.count, 0)
        XCTAssertEqual(shows(), [.showKey, .hide, .showKey, .hide, .showKey])
        p.close()
        XCTAssertEqual(log, ["b", "a"])
    }

    /// Red with onCancel closing (the old hook): Escape on a pushed card goes back one step; on the first card it closes.
    func testEscapeGoesBackThenCloses() throws {
        let (p, _) = presenter()
        var log: [String] = []
        show(p) { log.append("a") }
        let first = try XCTUnwrap(p.panel)
        push(p) { log.append("b") }
        p.panel?.cancelOperation(nil)
        XCTAssertEqual(log, ["b"])
        XCTAssertTrue(p.panel === first)
        p.panel?.cancelOperation(nil)
        XCTAssertEqual(log, ["b", "a"])
        XCTAssertFalse(p.isShown)
    }

    /// Red with close() leaving the cards under: a fresh open, a click outside and close() each clear the whole stack;
    /// each card's closed runs once, the shown one first, then down the stack; never on a push.
    func testClearRunsEachClosedOnceInOrder() throws {
        let (p, _) = presenter()
        var log: [String] = []
        show(p) { log.append("a") }
        push(p) { log.append("b") }
        push(p) { log.append("c") }
        XCTAssertEqual(log, [])
        XCTAssertEqual(p.under.count, 2)
        show(p) { log.append("d") }
        XCTAssertEqual(log, ["c", "b", "a"], "a fresh open clears the stack")
        XCTAssertEqual(p.under.count, 0)
        push(p) { log.append("e") }
        let top = try XCTUnwrap(p.panel)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: top)
        XCTAssertEqual(log, ["c", "b", "a", "e", "d"], "a click outside clears it too")
        XCTAssertFalse(p.isShown)
        XCTAssertEqual(p.under.count, 0)
        p.close()
        p.back()
        XCTAssertEqual(log.count, 5, "nothing runs twice")
    }

    /// A probe that records whether the card was handed a way back.
    struct BackProbe: View {
        let seen: (Bool) -> Void
        @Environment(\.xrayCardBack) var back
        var body: some View {
            seen(back != nil)
            return XrayCardBackButton()
        }
    }

    /// Red with the back action always set (or never): only a pushed card gets the Back control's action; the first, none.
    func testOnlyAPushedCardHasBack() throws {
        let (p, _) = presenter()
        var first: Bool?, pushed: Bool?
        func layout() {   // as FakeCardPresenter: laid out in the never-shown panel, never ordered front
            p.panel?.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            p.panel?.contentView?.layoutSubtreeIfNeeded()
        }
        p.present(AnyView(BackProbe { first = $0 }), size: CGSize(width: 200, height: 100), anchor: NSView()) {}
        layout()
        p.push(AnyView(BackProbe { pushed = $0 }), size: CGSize(width: 200, height: 100), anchor: NSView()) {}
        layout()
        XCTAssertEqual(first, false)
        XCTAssertEqual(pushed, true)
        p.close()
    }

    /// The real path, red with jumpRef calling presentRef (the old openChapterCard): a mention's arrow in a ref card
    /// pushes the chapter card over it; Back brings the ref card back.
    func testJumpRefFromARefCardPushes() throws {
        let (p, _) = presenter()
        let m = XrayPanelModel(target: XrayRefRunTests.local, tab: .search)
        m.presentRef = { p.present($0, size: $1, anchor: NSView(), closed: $2) }
        m.pushRef = { p.push($0, size: $1, anchor: NSView(), closed: $2) }
        m.dchChapters = [XrayRefTurnTests.chapter(3, "Fix login")]
        let c = XrayRefTurnTests.context([XrayRefTurnTests.mention(turn: 3, offset: 1)])
        var refClosed = 0
        m.presentRef(AnyView(Text(verbatim: "ref card")), CGSize(width: 460, height: 520)) { refClosed += 1 }
        let refPanel = try XCTUnwrap(p.panel)
        let mention = try XCTUnwrap(c.groups.first?.mentions.first)
        XCTAssertTrue(m.jumpRef(mention, in: c))
        XCTAssertEqual(refClosed, 0, "the ref card's read goes on")
        XCTAssertEqual(p.under.count, 1)
        XCTAssertEqual(m.chapterCard?.ordinal, 3)
        p.back()
        XCTAssertTrue(p.panel === refPanel)
        XCTAssertEqual(refClosed, 0)
        p.close()
        XCTAssertEqual(refClosed, 1)
    }

    /// Red without the put-back in openRef's closed: a ref card pushed from a chapter card owns the one --ref state while
    /// shown; Back puts the ref card's under it back.
    func testARefCardPushedFromAChapterCardPutsTheOneUnderBack() throws {
        let (p, _) = presenter()
        let m = XrayPanelModel(target: XrayRefRunTests.local, tab: .search)
        m.presentRef = { p.present($0, size: $1, anchor: NSView(), closed: $2) }
        m.pushRef = { p.push($0, size: $1, anchor: NSView(), closed: $2) }
        let refs = try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs: XrayRefPopoverTests.refs)))
        let a = try XCTUnwrap(refs.entries.first { $0.text == "#12" }), b = try XCTUnwrap(refs.entries.first { $0.text == "#1" })
        m.openRef(a)
        m.refContext = XrayRefTurnTests.context([XrayRefTurnTests.mention(turn: 3, offset: 1)])
        m.openChapterCard(XrayRefTurnTests.chapter(3, "Fix login"), fromCard: true)
        m.openRef(b, fromCard: true)
        XCTAssertEqual(p.under.count, 2)
        XCTAssertEqual(m.refCard?.text, "#1")
        XCTAssertTrue(m.refContext == nil, "the pushed card's own read state")
        p.back()
        p.back()
        XCTAssertEqual(m.refCard?.text, "#12")
        XCTAssertEqual(m.refContext?.ref, "#12", "the first ref card's context again")
        p.close()
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
