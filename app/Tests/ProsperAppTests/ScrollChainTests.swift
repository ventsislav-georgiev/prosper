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
}
