import AppKit
import ApplicationServices
import XCTest
@testable import ProsperApp

// #1032: on macOS 27 the host shows our items on every display's bar, while an item's
// client window has one frame on one display. With a readable, complete host layout the
// dismisser's "is this click on one of our items" uses the host's slots on every display,
// converted to the click's Cocoa space, for THIS bridge's non-live items only (round 2);
// a partial or unreadable read keeps the client
// frames. Pure decisions with literal screens, slots and clicks: no status item, no
// Accessibility read, no event posted, no window shown.
@MainActor
final class PopoverSecondDisplayTests: XCTestCase {
    private typealias P = ExpandedInterfacePolicy
    private typealias Items = [(frame: NSRect, sessionLive: Bool)]

    // Cocoa screen frames (bottom-left origin of the primary, y up), primary first.
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)    // AX top at y -180

    // Our two items' client frames, on the primary's bar (Cocoa).
    private let clientA = NSRect(x: 1300, y: 876, width: 30, height: 24)
    private let clientB = NSRect(x: 1340, y: 876, width: 30, height: 24)

    // The host's slots for our pid (AX, top-left origin, y down): A and B on the primary,
    // and 140 / 100 pt left of the right edge of the right display.
    private let slotA1 = CGRect(x: 1300, y: 0, width: 30, height: 24)
    private let slotB1 = CGRect(x: 1340, y: 0, width: 30, height: 24)
    private let slotA2 = CGRect(x: 3220, y: -180, width: 30, height: 24)
    private let slotB2 = CGRect(x: 3260, y: -180, width: 30, height: 24)
    // The same slots in Cocoa.
    private let a1 = CGRect(x: 1300, y: 876, width: 30, height: 24)
    private let b1 = CGRect(x: 1340, y: 876, width: 30, height: 24)
    private let a2 = CGRect(x: 3220, y: 1056, width: 30, height: 24)
    private let b2 = CGRect(x: 3260, y: 1056, width: 30, height: 24)

    private var both: Items { [(clientA, false), (clientB, false)] }
    private var twoDisplays: [CGRect] { [slotA1, slotB1, slotA2, slotB2] }

    /// Does the system own `click` (the popover stays open while the system begins that item)?
    private func owns(_ click: NSPoint, items: Items, slots: [CGRect]?, screens: [CGRect]) -> Bool {
        let frames = P.systemOwnedFrames(items, click: click, screens: screens, hostSlots: { slots })
        return P.systemOwnsClick(click, itemFrames: frames)
    }

    // The entry's case: our icon on the second display's bar. Before, the click was outside
    // every client frame and the dismisser closed the open popover.
    func testClickOnOurIconOnTheSecondDisplaysBarIsTheSystems() {
        XCTAssertEqual(P.systemOwnedFrames(both, screens: [primary, right], hostSlots: { self.twoDisplays }), [a1, b1, a2, b2])
        XCTAssertTrue(owns(NSPoint(x: 3235, y: 1068), items: both, slots: twoDisplays, screens: [primary, right]))
        XCTAssertTrue(owns(NSPoint(x: 3275, y: 1068), items: both, slots: twoDisplays, screens: [primary, right]))
    }

    func testClickOnOurIconOnTheFirstDisplayIsTheSystems() {
        XCTAssertTrue(owns(NSPoint(x: 1315, y: 888), items: both, slots: twoDisplays, screens: [primary, right]))
    }

    func testClickOnAnotherAppsIconIsTheDismissers() {
        XCTAssertFalse(owns(NSPoint(x: 3100, y: 1068), items: both, slots: twoDisplays, screens: [primary, right]), "second display")
        XCTAssertFalse(owns(NSPoint(x: 1250, y: 888), items: both, slots: twoDisplays, screens: [primary, right]), "first display")
    }

    func testClickInTheGapBetweenTwoOfOursIsTheDismissers() {
        XCTAssertFalse(owns(NSPoint(x: 1335, y: 888), items: both, slots: twoDisplays, screens: [primary, right]), "first display")
        XCTAssertFalse(owns(NSPoint(x: 3255, y: 1068), items: both, slots: twoDisplays, screens: [primary, right]), "second display")
    }

    func testDisplayToTheLeftWithNegativeX() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let slotLeft = CGRect(x: -140, y: -180, width: 30, height: 24)
        let items: Items = [(clientA, false)]
        XCTAssertEqual(P.systemOwnedFrames(items, screens: [primary, left], hostSlots: { [self.slotA1, slotLeft] }),
                       [a1, CGRect(x: -140, y: 1056, width: 30, height: 24)])
        XCTAssertTrue(owns(NSPoint(x: -125, y: 1068), items: items, slots: [slotA1, slotLeft], screens: [primary, left]))
        XCTAssertFalse(owns(NSPoint(x: -200, y: 1068), items: items, slots: [slotA1, slotLeft], screens: [primary, left]))
    }

    // Only the primary's height flips the space: a display above or below of another
    // height lands where its own bar is.
    func testDisplaysAboveAndBelowWithOtherHeights() {
        let above = CGRect(x: 0, y: 900, width: 2560, height: 1440)     // AX top -1440
        let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080)   // AX top 900
        let slotAbove = CGRect(x: 2420, y: -1440, width: 30, height: 24)
        let slotBelow = CGRect(x: 1780, y: 900, width: 30, height: 24)
        let screens = [primary, above, below]
        let items: Items = [(clientA, false)]
        let slots = [slotA1, slotAbove, slotBelow]
        XCTAssertEqual(P.systemOwnedFrames(items, screens: screens, hostSlots: { slots }),
                       [a1, CGRect(x: 2420, y: 2316, width: 30, height: 24), CGRect(x: 1780, y: -24, width: 30, height: 24)])
        XCTAssertTrue(owns(NSPoint(x: 2435, y: 2328), items: items, slots: slots, screens: screens), "above")
        XCTAssertTrue(owns(NSPoint(x: 1795, y: -12), items: items, slots: slots, screens: screens), "below")
    }

    // A 2x display: the host and Cocoa both speak points, nothing is scaled.
    func testScaleTwoDisplayIsInPoints() {
        let retina = CGRect(x: 1440, y: 0, width: 1280, height: 800)   // a 2560 x 1600 px panel; AX top 100
        let slot = CGRect(x: 2580, y: 100, width: 30, height: 24)
        let items: Items = [(clientA, false)]
        XCTAssertEqual(P.systemOwnedFrames(items, screens: [primary, retina], hostSlots: { [self.slotA1, slot] }),
                       [a1, CGRect(x: 2580, y: 776, width: 30, height: 24)])
        XCTAssertTrue(owns(NSPoint(x: 2595, y: 788), items: items, slots: [slotA1, slot], screens: [primary, retina]))
    }

    // #430 on every display: the open item's click is the dismisser's wherever its icon is.
    func testOpenItemIsTheDismissersOnEveryDisplay() {
        let items: Items = [(clientA, true), (clientB, false)]
        XCTAssertEqual(P.systemOwnedFrames(items, screens: [primary, right], hostSlots: { self.twoDisplays }), [b1, b2])
        XCTAssertFalse(owns(NSPoint(x: 3235, y: 1068), items: items, slots: twoDisplays, screens: [primary, right]), "A on the second display")
        XCTAssertFalse(owns(NSPoint(x: 1315, y: 888), items: items, slots: twoDisplays, screens: [primary, right]), "A on the first display")
        XCTAssertTrue(owns(NSPoint(x: 3275, y: 1068), items: items, slots: twoDisplays, screens: [primary, right]), "B on the second display")
        XCTAssertTrue(owns(NSPoint(x: 1355, y: 888), items: items, slots: twoDisplays, screens: [primary, right]), "B on the first display")
    }

    // Round 2 (F1032-1): a slot of ours that is no item of THIS bridge (the main icon, an
    // extension's item, another popover owner's item) stays the dismisser's on every display,
    // as under the parent, where the frames were this bridge's items only.
    func testOurSlotOfNoItemOfThisBridgeIsTheDismissersOnEveryDisplay() {
        let other1 = CGRect(x: 1380, y: 0, width: 30, height: 24)     // AX; Cocoa (1380, 876)
        let other2 = CGRect(x: 3300, y: -180, width: 30, height: 24)  // 60 pt left of the right display's edge; Cocoa (3300, 1056)
        let slots = twoDisplays + [other1, other2]
        let items: Items = [(clientA, true), (clientB, false)]
        XCTAssertEqual(P.systemOwnedFrames(items, screens: [primary, right], hostSlots: { slots }), [b1, b2])
        XCTAssertFalse(owns(NSPoint(x: 1395, y: 888), items: items, slots: slots, screens: [primary, right]), "first display")
        XCTAssertFalse(owns(NSPoint(x: 3315, y: 1068), items: items, slots: slots, screens: [primary, right]), "second display")
        XCTAssertFalse(owns(NSPoint(x: 1395, y: 888), items: both, slots: slots, screens: [primary, right]), "no live item: first display")
        XCTAssertFalse(owns(NSPoint(x: 3315, y: 1068), items: both, slots: slots, screens: [primary, right]), "no live item: second display")
        XCTAssertTrue(owns(NSPoint(x: 1355, y: 888), items: items, slots: slots, screens: [primary, right]), "this bridge's B, first display")
        XCTAssertTrue(owns(NSPoint(x: 3275, y: 1068), items: items, slots: slots, screens: [primary, right]), "this bridge's B, second display")
        XCTAssertFalse(owns(NSPoint(x: 1315, y: 888), items: items, slots: slots, screens: [primary, right]), "the live A, first display")
        XCTAssertFalse(owns(NSPoint(x: 3235, y: 1068), items: items, slots: slots, screens: [primary, right]), "the live A, second display")
    }

    // The one geometric rule for both uses: own display by x (within 3 pt), another display by
    // the distance from its right edge.
    func testSameItemRule() {
        XCTAssertTrue(P.sameItem(clientA, a1, screens: [primary, right]))
        XCTAssertTrue(P.sameItem(clientA, CGRect(x: 1302, y: 876, width: 30, height: 24), screens: [primary, right]), "under 3 pt")
        XCTAssertFalse(P.sameItem(clientA, CGRect(x: 1303, y: 876, width: 30, height: 24), screens: [primary, right]), "3 pt is another item")
        XCTAssertTrue(P.sameItem(clientA, a2, screens: [primary, right]), "140 pt from both right edges")
        let above = CGRect(x: 0, y: 900, width: 2560, height: 1440)
        XCTAssertFalse(P.sameItem(clientA, CGRect(x: 1300, y: 2316, width: 30, height: 24), screens: [primary, above]),
                       "the same x on a wider display above is not the item")
        XCTAssertTrue(P.sameItem(clientA, CGRect(x: 2420, y: 2316, width: 30, height: 24), screens: [primary, above]))
    }

    // The rider: B's container timed out, so the host returned only A. A partial read keeps
    // the client frames, exactly as an empty one does.
    func testPartialReadKeepsTheClientFrames() {
        typealias L = MenuBarAX.Laid
        let me: pid_t = 100, agent: pid_t = 50
        let clock = CGRect(x: 1400, y: 0, width: 30, height: 24)
        let laid = [L(frame: slotA1, pid: me), L(frame: clock, pid: agent)]
        XCTAssertTrue(P.ownSlots(in: laid, pid: me, complete: false) == nil, "partial: a failed read")
        XCTAssertEqual(P.ownSlots(in: laid, pid: me, complete: true), [slotA1])
        let onB = NSPoint(x: 1355, y: 888)
        let partial = P.systemOwnedFrames(both, click: onB, screens: [primary, right],
                                          hostSlots: { P.ownSlots(in: laid, pid: me, complete: false) })
        XCTAssertEqual(partial, [clientA, clientB])
        XCTAssertTrue(P.systemOwnsClick(onB, itemFrames: partial), "B's click stays the system's")
    }

    // Round 3: a read failed ONLY on the messaging timeout (.cannotComplete), an element gone
    // between two reads (.invalidUIElement) or the interface switched off (.apiDisabled); every other
    // error is the element's answer (a healthy element may give one). Literals on both sides.
    func testOnlyTimeoutAndGoneElementAreFailedReads() {
        let failed: [AXError] = [.cannotComplete, .invalidUIElement, .apiDisabled]
        let answers: [AXError] = [.success, .noValue, .attributeUnsupported, .failure, .illegalArgument, .notImplemented,
                                  .actionUnsupported, .parameterizedAttributeUnsupported, .notificationUnsupported,
                                  .invalidUIElementObserver, .notEnoughPrecision, .notificationAlreadyRegistered,
                                  .notificationNotRegistered]
        XCTAssertEqual(Set((failed + answers).filter(MenuBarAX.readFailed).map(\.rawValue)),
                       Set([AXError.cannotComplete.rawValue, AXError.invalidUIElement.rawValue, AXError.apiDisabled.rawValue]))
        for e in answers { XCTAssertFalse(MenuBarAX.readFailed(e), "\(e.rawValue) is an answer") }
    }

    // Round 3: the note carries the first failed read's raw AXError and a literal attribute name;
    // without one the line is as before. Literal values, no clock, no Accessibility read.
    func testHostReadNoteNamesTheFirstError() {
        XCTAssertEqual(P.hostReadNote(complete: false, elapsed: 0.1, deadline: 0.25, count: 4,
                                      firstError: (code: -25204, attribute: "children")),
                       "host read partial after 0.100 s, 4 items read, first error -25204 on children")
        XCTAssertEqual(P.hostReadNote(complete: false, elapsed: 0.3, deadline: 0.25, count: 2,
                                      firstError: (code: AXError.invalidUIElement.rawValue, attribute: "position")),
                       "host read past the deadline after 0.300 s, 2 items read, first error -25202 on position")
        XCTAssertEqual(P.hostReadNote(complete: false, elapsed: 0.1, deadline: 0.25, count: 4, firstError: nil),
                       "host read partial after 0.100 s, 4 items read")
        XCTAssertTrue(P.hostReadNote(complete: true, elapsed: 0.1, deadline: 0.25, count: 9,
                                     firstError: (code: -25204, attribute: "size")) == nil, "a whole read in time logs nothing")
    }

    // F1032-4: one line, counts only, when the host read is partial or past the deadline;
    // nothing for a whole read in time. Literal elapsed times, no clock.
    func testHostReadNote() {
        XCTAssertTrue(P.hostReadNote(complete: true, elapsed: 0.1, deadline: 0.25, count: 9) == nil)
        XCTAssertEqual(P.hostReadNote(complete: false, elapsed: 0.1, deadline: 0.25, count: 4),
                       "host read partial after 0.100 s, 4 items read")
        XCTAssertEqual(P.hostReadNote(complete: true, elapsed: 0.3, deadline: 0.25, count: 9),
                       "host read past the deadline after 0.300 s, 9 items read")
        XCTAssertEqual(P.hostReadNote(complete: false, elapsed: 0.25, deadline: 0.25, count: 2),
                       "host read past the deadline after 0.250 s, 2 items read")
        XCTAssertEqual(ExpandedInterfaceBridge.hostReadDeadline, 0.25)
    }

    func testUnreadableHostOrNoScreenKeepsTheClientFrames() {
        XCTAssertEqual(P.systemOwnedFrames(both, screens: [primary, right], hostSlots: { nil }), [clientA, clientB])
        XCTAssertEqual(P.systemOwnedFrames(both, screens: [], hostSlots: { self.twoDisplays }), [clientA, clientB])
        let broken = CGRect(x: 0, y: 0, width: 1440, height: CGFloat.nan)
        XCTAssertEqual(P.systemOwnedFrames(both, screens: [broken, right], hostSlots: { self.twoDisplays }), [clientA, clientB])
    }

    // Host frames are outside data: skipped, never trapped on.
    func testOutsideDataIsSkipped() {
        let junk = [CGRect(x: CGFloat.nan, y: 0, width: 30, height: 24), CGRect(x: 1300, y: CGFloat.infinity, width: 30, height: 24),
                    CGRect.null, CGRect.infinite, CGRect(x: 1200, y: 0, width: 0, height: 24),
                    CGRect(x: 9000, y: 0, width: 30, height: 24)]   // on no screen
        XCTAssertEqual(P.systemOwnedFrames(both, screens: [primary, right], hostSlots: { junk + [self.slotA1] }), [a1])
        XCTAssertFalse(P.onMenuBar(NSPoint(x: CGFloat.nan, y: 888), screens: [primary]))
        let nanScreen = CGRect(x: CGFloat.nan, y: 0, width: 1440, height: 900)
        XCTAssertFalse(P.onMenuBar(NSPoint(x: 10, y: 890), screens: [nanScreen]))
        XCTAssertTrue(P.screen(of: a1, in: [nanScreen]) == nil)
        XCTAssertFalse(P.sameItem(clientA, a2, screens: [nanScreen, right]), "a NaN screen: x alone, no trap")
    }

    // The host (an Accessibility read on 27) is read only for a click inside a client frame
    // or on a menu bar; anywhere else the answer is the same without it.
    func testHostIsReadOnlyForAClickInAClientFrameOrOnABar() {
        var reads = 0
        @MainActor func frames(_ click: NSPoint) -> [NSRect] {
            P.systemOwnedFrames(both, click: click, screens: [primary, right], hostSlots: { reads += 1; return self.twoDisplays })
        }
        XCTAssertEqual(frames(NSPoint(x: 700, y: 400)), [clientA, clientB], "mid-screen: no read")
        XCTAssertEqual(frames(NSPoint(x: -100_000, y: -100_000)), [clientA, clientB], "on no screen: no read")
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(frames(NSPoint(x: 3235, y: 1068)), [a1, b1, a2, b2], "the second display's bar")
        XCTAssertEqual(reads, 1)
    }

    // Round 3 (R1032-1): a bar click farther from its screen's right edge than every non-live client frame's
    // left edge (140 pt for A, on the primary) plus 3 pt lies left of every slot that could match: no read.
    // Every other bar click reads as before. `reads` is a local; the closure runs on main inside the call.
    func testBarClickLeftOfEveryItemReadsNothing() {
        var reads = 0
        @MainActor func frames(_ click: NSPoint, items: Items? = nil, slots: [CGRect]? = nil) -> [NSRect] {
            P.systemOwnedFrames(items ?? both, click: click, screens: [primary, right],
                                hostSlots: { reads += 1; return slots ?? self.twoDisplays })
        }
        XCTAssertEqual(frames(NSPoint(x: 1200, y: 888)), [clientA, clientB], "first display, 240 pt from its edge")
        XCTAssertEqual(frames(NSPoint(x: 3210, y: 1068)), [clientA, clientB], "second display, 150 pt from its edge")
        XCTAssertEqual(frames(NSPoint(x: 3216, y: 1068)), [clientA, clientB], "144 pt: just past the margin")
        XCTAssertEqual(frames(NSPoint(x: 700, y: 400)), [clientA, clientB], "below the bar")
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(frames(NSPoint(x: 3217, y: 1068)), [a1, b1, a2, b2], "143 pt: on the margin, reads")
        XCTAssertEqual(reads, 1)
        // The round-3 counter-example: a 40 pt slot for the 30 pt A; a click in its right part is the system's.
        let wide = CGRect(x: 3220, y: -180, width: 40, height: 24)   // AX; Cocoa (3220, 1056, 40, 24)
        let click = NSPoint(x: 3257, y: 1068)
        let wideFrames = frames(click, slots: [wide])
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(P.systemOwnsClick(click, itemFrames: wideFrames), "a wide slot's click is still the system's")
        // Not removed: right of every item (the clock, Control Center) still reads.
        _ = frames(NSPoint(x: 3350, y: 1068))
        XCTAssertEqual(reads, 3)
        let offScreen = NSRect(x: -100_000, y: -100_000, width: 30, height: 24)
        _ = frames(NSPoint(x: 1200, y: 888), items: [(clientA, false), (offScreen, false)])
        XCTAssertEqual(reads, 4, "a client frame on no screen: the gate does not apply")
        _ = frames(NSPoint(x: 1315, y: 888))
        XCTAssertEqual(reads, 5, "inside a client frame")
        XCTAssertFalse(owns(NSPoint(x: 1200, y: 888), items: both, slots: twoDisplays, screens: [primary, right]))
        XCTAssertFalse(owns(NSPoint(x: 3210, y: 1068), items: both, slots: twoDisplays, screens: [primary, right]))
    }

    // The bridge hands its screens to the decision (the product's default reads NSScreen).
    func testBridgePassesItsScreens() {
        let b = ExpandedInterfaceBridge(begin: { _ in }, end: { _ in }, hostSlots: { self.twoDisplays },
                                        clientFrames: { self.both }, screens: { [self.primary, self.right] })
        let click = NSPoint(x: 3235, y: 1068)
        XCTAssertEqual(b.itemFrames(at: click), [a1, b1, a2, b2])
        XCTAssertTrue(P.systemOwnsClick(click, itemFrames: b.itemFrames(at: click)))
    }
}
