import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #129: while the cursor is over a SCROLLABLE inner list the pane must not move
/// at all; a list too short to scroll must leave the pane exactly as it was.
///
/// #128 gated the responder chain and could not test the decision, because the
/// decision depended on AppKit's private routing. The capture decision is a pure
/// function of (event location, scroll-view geometry), so it is tested directly
/// against the real hosted hierarchy.
@MainActor
final class ScrollChainTests: XCTestCase {
    private func rows(_ n: Int) -> [BindableAction] {
        (0..<n).map { i in
            BindableAction(kind: .extensionItem, key: "chain.\(i)", title: "Chain probe \(i)",
                           category: "Quick Toggles", icon: "bolt",
                           combo: KeyCombo(keyCode: 0, carbonModifiers: 0, display: ""),
                           conflictNote: nil)
        }
    }

    private func scrollViews(_ v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = v as? NSScrollView { out.append(s) }
        for sub in v.subviews { out += scrollViews(sub) }
        return out
    }

    /// Hosts the real pane and hands back (window, hosting view, outer scroll, inner list scroll).
    private func host(rowCount: Int) throws -> (NSWindow, NSView, NSScrollView, NSScrollView) {
        let side = CGSize(width: 660, height: 640)
        let host = NSHostingView(rootView: NeonScroll {
            ShortcutTable(rows: self.rows(rowCount), paneHeight: side.height, model: SettingsModel())
        })
        host.frame = CGRect(origin: .zero, size: side)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.contentView = host
        // Detach deterministically at the end of the test rather than leaving it to
        // dealloc order: the monitor-lifetime assertions below are about a clean
        // registry, and must not depend on which test ran first.
        addTeardownBlock { MainActor.assumeIsolated { win.contentView = NSView() } }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let found = scrollViews(host)
        return (win, host, try XCTUnwrap(found.first), try XCTUnwrap(found.dropFirst().first,
            "no inner list scroll view — did NeonBoundedList stop bounding?"))
    }

    /// A point well inside the list, in the window coordinate space a local monitor
    /// would hand us.
    private func windowPointInside(_ sv: NSScrollView) -> NSPoint {
        sv.convert(NSPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: nil)
    }

    // MARK: - The decision

    func testCapturesAPointInsideAScrollableList() throws {
        let (_, _, _, inner) = try host(rowCount: 200)
        XCTAssertGreaterThan(inner.documentView?.frame.height ?? 0, inner.contentView.bounds.height,
                             "precondition: this list must actually be scrollable")
        XCTAssertTrue(ScrollChainCapture.shouldCapture(at: windowPointInside(inner), in: inner),
                      "a scrollable list under the cursor let the event through to the pane")
    }

    /// The other half of the boundary: "All Actions" is bounded at threshold 0, so
    /// 3 rows still get a scroll view — one whose content is shorter than its frame.
    func testDoesNotCaptureInsideAListTooShortToScroll() throws {
        let (_, _, _, inner) = try host(rowCount: 3)
        XCTAssertLessThan(inner.documentView?.frame.height ?? 0, inner.contentView.bounds.height,
                          "precondition: this list must NOT be scrollable")
        XCTAssertFalse(ScrollChainCapture.shouldCapture(at: windowPointInside(inner), in: inner),
                       "a short list swallowed the event — the pane can no longer scroll over it")
    }

    func testDoesNotCaptureAPointOutsideTheList() throws {
        let (_, hosted, _, inner) = try host(rowCount: 200)
        // Top-left of the window: inside the pane, well clear of the bounded list.
        let outside = NSPoint(x: 8, y: hosted.bounds.maxY - 8)
        XCTAssertFalse(inner.visibleRect.contains(inner.convert(outside, from: nil)),
                       "precondition: this point must be outside the list")
        XCTAssertFalse(ScrollChainCapture.shouldCapture(at: outside, in: inner),
                       "an event outside the list was captured — the pane would stop scrolling")
    }

    /// The document is far taller than the list and scrolls under it. Testing the
    /// point against `documentView.frame` instead of the visible rect would claim
    /// the whole window; this pins that mistake down.
    func testDoesNotCaptureAPointInTheScrolledAwayPartOfTheDocument() throws {
        let (_, _, _, inner) = try host(rowCount: 200)
        let doc = try XCTUnwrap(inner.documentView)
        // A point far down the document, i.e. below the list on screen.
        let deep = doc.convert(NSPoint(x: doc.bounds.midX, y: doc.bounds.midY), to: nil)
        XCTAssertFalse(ScrollChainCapture.shouldCapture(at: deep, in: inner),
                       "a point in the scrolled-away part of the document was treated as a hit")
    }

    /// Scrollability is read at event time: filtering shrinks the list under the
    /// cursor and capture must stop immediately.
    func testDecisionFollowsContentHeightChanges() throws {
        let (_, _, _, inner) = try host(rowCount: 200)
        let point = windowPointInside(inner)
        XCTAssertTrue(ScrollChainCapture.shouldCapture(at: point, in: inner))

        inner.documentView?.setFrameSize(NSSize(width: inner.contentView.bounds.width, height: 10))
        XCTAssertFalse(ScrollChainCapture.shouldCapture(at: point, in: inner),
                       "kept capturing after the list stopped being scrollable")
    }

    func testDoesNotCaptureForAListThatHasLeftTheWindow() throws {
        let (win, _, _, inner) = try host(rowCount: 200)
        let point = windowPointInside(inner)
        XCTAssertTrue(ScrollChainCapture.shouldCapture(at: point, in: inner))

        win.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(ScrollChainCapture.shouldCapture(at: point, in: inner),
                       "an off-screen list still claimed events")
    }

    // MARK: - Monitor lifetime

    /// A monitor outliving the settings window would eat wheel events across the
    /// whole app — strictly worse than the bug it fixes.
    func testMonitorIsInstalledWithTheListsAndRemovedWithTheLast() throws {
        XCTAssertEqual(ScrollChainCapture.registeredCount, 0, "a previous test leaked a registration")
        XCTAssertFalse(ScrollChainCapture.isMonitoring, "a previous test leaked the monitor")

        let (win, _, _, _) = try host(rowCount: 200)
        XCTAssertGreaterThan(ScrollChainCapture.registeredCount, 0, "no list registered for capture")
        XCTAssertTrue(ScrollChainCapture.isMonitoring, "lists registered but no monitor installed")

        win.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ScrollChainCapture.registeredCount, 0, "a torn-down list stayed registered")
        XCTAssertFalse(ScrollChainCapture.isMonitoring,
                       "the monitor outlived the last list — it now eats wheel events app-wide")
    }

    /// Leaving and returning must end with exactly one registration, not two.
    func testRegistrationIsIdempotentAcrossLeaveAndReturn() throws {
        let (win, hosted, _, _) = try host(rowCount: 200)
        let first = ScrollChainCapture.registeredCount

        win.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ScrollChainCapture.registeredCount, 0)

        win.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosted.layoutSubtreeIfNeeded()
        XCTAssertEqual(ScrollChainCapture.registeredCount, first,
                       "returning to a window changed the registration count")

        win.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(ScrollChainCapture.isMonitoring)
    }

    // MARK: - #130: delivery

    /// A wheel event with precise (trackpad-style) deltas. Unlike #128/#129, this
    /// event never reaches `NSScrollView`'s own event handling — `scroll(_:by:)`
    /// touches the clip view directly — so a synthetic event is honest here where
    /// it was useless before.
    private func wheel(deltaY: Int32) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                       wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let e = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(e.hasPreciseScrollingDeltas, "precondition: precise-delta event")
        XCTAssertEqual(e.scrollingDeltaY, CGFloat(deltaY), accuracy: 0.01)
        return e
    }

    /// The #130 fix, as measured in the harness: the list moves and the pane does
    /// not. Delivering the event to the scroll view instead (#129) is what moved
    /// the pane, so this asserts both halves.
    func testScrollingAListMovesItAndLeavesThePaneWhereItWas() throws {
        let (_, _, outer, inner) = try host(rowCount: 200)
        let paneBefore = outer.contentView.bounds.origin
        let listBefore = inner.contentView.bounds.origin.y

        ScrollChainCapture.scroll(inner, by: try wheel(deltaY: -120))

        XCTAssertEqual(inner.contentView.bounds.origin.y, listBefore + 120, accuracy: 0.01,
                       "the list did not take the scroll")
        XCTAssertEqual(outer.contentView.bounds.origin, paneBefore,
                       "the pane moved — this is exactly the #129 failure")
    }

    /// #155: the monitor's own entry point, not just the helper. `scroll(_:by:)` is
    /// pinned above, but nothing pinned that `capture(_:)` routes to it — reverting
    /// the call to `target.scrollWheel(with: event)` kept every other test green.
    /// The event carries the window number, so `capture` resolves the window and
    /// hit-tests exactly as it does for a live event.
    func testCaptureEntryPointScrollsTheListDirectlyAndLeavesThePane() throws {
        let (win, _, outer, inner) = try host(rowCount: 200)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                       wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Field 51 is the window number NSEvent(cgEvent:) resolves `window` from, and
        // CGEventSetWindowLocation the point it reports as `locationInWindow` (both
        // private; the public location/91/92 fields are ignored for an unordered window).
        cg.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 51)), value: Int64(win.windowNumber))
        typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
        let sym = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
        let target = windowPointInside(inner)
        unsafeBitCast(sym, to: SetWindowLocation.self)(cg, CGPoint(x: target.x, y: win.frame.height - target.y))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(event.window === win, "precondition: the event must resolve to the test window")
        XCTAssertTrue(ScrollChainCapture.shouldCapture(at: event.locationInWindow, in: inner),
                      "precondition: the event must land on the list")
        let paneBefore = outer.contentView.bounds.origin
        let listBefore = inner.contentView.bounds.origin.y

        XCTAssertTrue(ScrollChainCapture.capture(event), "an event over a scrollable list was not consumed")
        XCTAssertEqual(inner.contentView.bounds.origin.y, listBefore + 120, accuracy: 0.01,
                       "capture did not scroll the list's clip view directly")
        // The #129 path chains to the pane a frame later, not synchronously.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(outer.contentView.bounds.origin, paneBefore,
                       "the pane moved — capture handed the event to NSScrollView (#129)")
    }

    /// The user's rule at the ends: scrolling past the bottom of the list must
    /// still leave the pane alone. Clamped, so there is no overshoot to bounce back.
    func testScrollIsClampedAtBothEndsWithoutMovingThePane() throws {
        let (_, _, outer, inner) = try host(rowCount: 200)
        let doc = try XCTUnwrap(inner.documentView)
        let maxY = doc.frame.height - inner.contentView.bounds.height
        XCTAssertGreaterThan(maxY, 0, "precondition: scrollable")
        let paneBefore = outer.contentView.bounds.origin

        ScrollChainCapture.scroll(inner, by: try wheel(deltaY: -100_000))
        XCTAssertEqual(inner.contentView.bounds.origin.y, maxY, accuracy: 0.01,
                       "overshot the bottom of the list")
        XCTAssertEqual(outer.contentView.bounds.origin, paneBefore,
                       "the pane moved once the list hit its end — the reported bug")

        ScrollChainCapture.scroll(inner, by: try wheel(deltaY: 100_000))
        XCTAssertEqual(inner.contentView.bounds.origin.y, 0, accuracy: 0.01,
                       "overshot the top of the list")
        XCTAssertEqual(outer.contentView.bounds.origin, paneBefore,
                       "the pane moved once the list hit its top")
    }

    // MARK: - #162: one gesture, one owner

    /// A trackpad-style event bound to `win` at `point` (window coordinates), with
    /// the CG scroll phase (99: 1 began, 2 changed, 4 ended) and momentum phase
    /// (123: 1 begin, 2 continue, 3 end) set the way a real trackpad sets them.
    private func gestureEvent(_ win: NSWindow, at point: NSPoint, deltaY: Int32,
                              phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                       wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 51)), value: Int64(win.windowNumber))
        typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
        let sym = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
        unsafeBitCast(sym, to: SetWindowLocation.self)(cg, CGPoint(x: point.x, y: win.frame.height - point.y))
        let e = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(e.window === win, "precondition: the event must resolve to the test window")
        return e
    }

    private struct Step { var at: NSPoint; var phase: Int64 = 0; var momentum: Int64 = 0 }

    /// A whole trackpad sequence as the monitor sees it: `.began`, `.changed`s,
    /// `.ended`, then a momentum tail. Returns what `capture` said for each event.
    private func gesture(_ win: NSWindow, from start: NSPoint, to end: NSPoint, deltaY: Int32) throws -> [Bool] {
        var steps = [Step(at: start, phase: 1), Step(at: start, phase: 2)]
        steps += Array(repeating: Step(at: end, phase: 2), count: 5)
        steps += [Step(at: end, phase: 4), Step(at: end, momentum: 1), Step(at: end, momentum: 2), Step(at: end, momentum: 3)]
        return try steps.map { s in
            ScrollChainCapture.capture(try gestureEvent(win, at: s.at, deltaY: deltaY, phase: s.phase, momentum: s.momentum))
        }
    }

    private func panePoint(_ hosted: NSView, clearOf inner: NSScrollView) -> NSPoint {
        let p = NSPoint(x: 8, y: hosted.bounds.maxY - 8)
        XCTAssertFalse(ScrollChainCapture.shouldCapture(at: p, in: inner), "precondition: pane point is off the list")
        return p
    }

    /// QA #2 r2 handoff: a pane swipe brings a list under the pointer mid-gesture.
    /// The pane began the gesture, so it must get every event to the end of the
    /// momentum tail — otherwise it never sees `.ended` and resumes on its own
    /// (279.5 pt of drift over the list). Synthetic events do not drive the pane's
    /// own NSScrollView in this host, so the pane half is asserted by routing:
    /// `capture == false` is the monitor passing the event on to the pane.
    func testGestureBegunOverThePaneStaysWithThePaneWhenAListArrivesUnderThePointer() throws {
        let (win, hosted, _, inner) = try host(rowCount: 200)
        let listBefore = inner.contentView.bounds.origin.y

        let routed = try gesture(win, from: panePoint(hosted, clearOf: inner), to: windowPointInside(inner), deltaY: -40)

        XCTAssertEqual(routed, Array(repeating: false, count: routed.count),
                       "the list took over part of a gesture the pane began — the pane never sees .ended")
        XCTAssertEqual(inner.contentView.bounds.origin.y, listBefore, accuracy: 0.01,
                       "the list scrolled during a gesture it did not begin")
    }

    /// The mirror: a gesture begun over a list keeps scrolling that list, and never
    /// the pane, after the pointer leaves it — the pane must not get `.changed`
    /// without ever having seen `.began`.
    func testGestureBegunOverAListStaysWithTheListWhenThePointerLeavesIt() throws {
        let (win, hosted, outer, inner) = try host(rowCount: 200)
        let paneBefore = outer.contentView.bounds.origin
        let listBefore = inner.contentView.bounds.origin.y

        let routed = try gesture(win, from: windowPointInside(inner), to: panePoint(hosted, clearOf: inner), deltaY: -40)

        XCTAssertEqual(routed, Array(repeating: true, count: routed.count),
                       "part of a list gesture leaked to the pane once the pointer left the list")
        XCTAssertGreaterThan(inner.contentView.bounds.origin.y, listBefore + 40 * 7 - 0.01,
                             "the list stopped taking its own gesture when the pointer left it")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(outer.contentView.bounds.origin, paneBefore, "the pane moved during a list gesture")
    }

    /// The latch is per gesture, not sticky: a notched wheel (no phase) still
    /// decides per event, and the next gesture's `.began` decides afresh.
    func testAfterAPaneGestureAPhaselessWheelAndANewGestureOverTheListScrollIt() throws {
        let (win, hosted, _, inner) = try host(rowCount: 200)
        let list = windowPointInside(inner)
        _ = try gesture(win, from: panePoint(hosted, clearOf: inner), to: list, deltaY: -40)
        let listBefore = inner.contentView.bounds.origin.y

        XCTAssertTrue(ScrollChainCapture.capture(try gestureEvent(win, at: list, deltaY: -40)),
                      "a phaseless wheel event over the list obeyed the previous gesture's latch")
        XCTAssertEqual(inner.contentView.bounds.origin.y, listBefore + 40, accuracy: 0.01)
        XCTAssertTrue(ScrollChainCapture.capture(try gestureEvent(win, at: list, deltaY: -40, phase: 1)),
                      "a new gesture began over the list but kept the old gesture's owner")
        XCTAssertEqual(inner.contentView.bounds.origin.y, listBefore + 80, accuracy: 0.01)
    }

    /// QA on 6114972: `capture` must only consider lists in the EVENT's window. An
    /// event bound to a second window at the first window's list coordinates (where
    /// the second window has only a too-short list) must leave the first list alone.
    func testAnEventInAnotherWindowNeverScrollsThisWindowsList() throws {
        let (_, _, _, inner) = try host(rowCount: 200)
        let (other, _, _, otherInner) = try host(rowCount: 3)
        let point = windowPointInside(inner)
        XCTAssertFalse(ScrollChainCapture.shouldCapture(at: point, in: otherInner),
                       "precondition: the other window has nothing to capture at this point")
        let listBefore = inner.contentView.bounds.origin.y

        XCTAssertFalse(ScrollChainCapture.capture(try gestureEvent(other, at: point, deltaY: -40)),
                       "an event in another window was consumed on this window's list's behalf")
        XCTAssertEqual(inner.contentView.bounds.origin.y, listBefore, accuracy: 0.01,
                       "an event in another window scrolled this window's list")
    }

    /// QA #70: the latched list is torn down mid-gesture while another list keeps
    /// the monitor alive. The rest of the gesture must be swallowed, never handed
    /// to a pane that did not see it begin.
    func testGestureWhoseListIsGoneIsSwallowedNotHandedToThePane() throws {
        let (win, _, _, inner) = try host(rowCount: 200)
        let (other, otherHosted, _, otherInner) = try host(rowCount: 3)
        XCTAssertTrue(ScrollChainCapture.capture(try gestureEvent(win, at: windowPointInside(inner), deltaY: -40, phase: 1)))
        win.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(ScrollChainCapture.isMonitoring, "precondition: the other window keeps the monitor")

        XCTAssertTrue(ScrollChainCapture.capture(try gestureEvent(other, at: panePoint(otherHosted, clearOf: otherInner),
                                                                  deltaY: -40, phase: 2)),
                      "the rest of a gesture whose list is gone leaked to the pane")
    }

    /// QA #70: removing the monitor ends the latch. A `.changed` arriving after a
    /// fresh registration is decided by the hit test, not by a dead list's latch.
    func testRemovingTheMonitorClearsTheLatch() throws {
        let (win, _, _, inner) = try host(rowCount: 200)
        XCTAssertTrue(ScrollChainCapture.capture(try gestureEvent(win, at: windowPointInside(inner), deltaY: -40, phase: 1)))
        win.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(ScrollChainCapture.isMonitoring, "precondition: last list gone, monitor removed")

        let (fresh, freshHosted, _, freshInner) = try host(rowCount: 200)
        XCTAssertFalse(ScrollChainCapture.capture(try gestureEvent(fresh, at: panePoint(freshHosted, clearOf: freshInner),
                                                                   deltaY: -40, phase: 2)),
                       "a stale latch from a removed monitor swallowed a pane event")
    }
}
