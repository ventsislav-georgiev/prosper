import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #128: an inner list that can scroll must swallow the wheel events it cannot
/// use instead of handing them to the pane's own scroll view.
@MainActor
final class ScrollChainTests: XCTestCase {
    /// Counts the events that made it PAST the gate — i.e. the ones that would
    /// have chained on to the pane.
    private final class WheelSpy: NSResponder {
        var count = 0
        override func scrollWheel(with event: NSEvent) { count += 1 }
    }

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

    private func wheel(_ dy: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                         wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    /// Every `ScrollChainGate` reachable from a scroll view's responder chain.
    private func gates(from sv: NSScrollView) -> [ScrollChainGate] {
        var out: [ScrollChainGate] = []
        var next = sv.nextResponder
        var hops = 0
        while let cur = next, hops < 40 {
            if let g = cur as? ScrollChainGate { out.append(g) }
            next = cur.nextResponder
            hops += 1
        }
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
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let found = scrollViews(host)
        return (win, host, try XCTUnwrap(found.first), try XCTUnwrap(found.dropFirst().first,
            "no inner list scroll view — did NeonBoundedList stop bounding?"))
    }

    func testGateIsSplicedIntoTheListScrollViewAndNotThePane() throws {
        let (_, _, outer, inner) = try host(rowCount: 200)
        XCTAssertTrue(inner.nextResponder is ScrollChainGate,
                      "inner list scroll view is not gated: \(String(describing: inner.nextResponder))")
        XCTAssertFalse(outer.nextResponder is ScrollChainGate,
                       "the pane's own scroll view got gated — it must keep chaining normally")
    }

    /// The reported bug: at the end of a scrollable list the wheel event must stop
    /// here, not travel on to the pane.
    func testScrollableListSwallowsWhatItCannotUse() throws {
        let (_, _, _, inner) = try host(rowCount: 200)
        let gate = try XCTUnwrap(inner.nextResponder as? ScrollChainGate)
        let spy = WheelSpy()
        gate.nextResponder = spy

        XCTAssertGreaterThan(inner.documentView?.frame.height ?? 0, inner.contentView.bounds.height,
                             "precondition: this list must actually be scrollable")
        gate.scrollWheel(with: wheel(-40))
        gate.scrollWheel(with: wheel(40))
        XCTAssertEqual(spy.count, 0, "a scrollable list let \(spy.count) wheel events chain to the pane")
    }

    /// The other half: a list too short to scroll must keep letting the pane move.
    func testUnscrollableListStillLetsThePaneScroll() throws {
        // "All Actions" is bounded at threshold 0, so 3 rows still get a scroll
        // view — one whose content is shorter than its frame.
        let (_, _, _, inner) = try host(rowCount: 3)
        let gate = try XCTUnwrap(inner.nextResponder as? ScrollChainGate)
        let spy = WheelSpy()
        gate.nextResponder = spy

        XCTAssertLessThan(inner.documentView?.frame.height ?? 0, inner.contentView.bounds.height,
                          "precondition: this list must NOT be scrollable")
        gate.scrollWheel(with: wheel(-40))
        XCTAssertEqual(spy.count, 1, "a short list swallowed the event — the pane can no longer scroll over it")
    }

    /// Scrollability is read at event time, not captured at layout time: filtering
    /// shrinks the list under the cursor and the gate must notice.
    func testGateFollowsContentHeightChanges() throws {
        let (_, _, _, inner) = try host(rowCount: 200)
        let gate = try XCTUnwrap(inner.nextResponder as? ScrollChainGate)
        let spy = WheelSpy()
        gate.nextResponder = spy
        gate.scrollWheel(with: wheel(-40))
        XCTAssertEqual(spy.count, 0)

        // Same gate, same scroll view, content shrunk to below the frame.
        inner.documentView?.setFrameSize(NSSize(width: inner.contentView.bounds.width, height: 10))
        gate.scrollWheel(with: wheel(-40))
        XCTAssertEqual(spy.count, 1, "gate kept swallowing after the list stopped being scrollable")
    }

    /// AppKit does not retain `nextResponder`: a scroll view outliving its probe
    /// must not be left pointing at a freed gate.
    func testGateIsUnsplicedWhenTheListLeavesTheWindow() throws {
        let (win, _, _, inner) = try host(rowCount: 200)
        XCTAssertEqual(gates(from: inner).count, 1, "precondition: gate spliced")

        win.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(gates(from: inner).count, 0,
                       "the gate stayed spliced after teardown — the next wheel event over this list is a use-after-free")
    }

    /// Leaving and returning must end with exactly one gate, not two and not zero.
    func testGateIsResplicedExactlyOnceOnReturn() throws {
        let (win, hosted, _, inner) = try host(rowCount: 200)
        win.contentView = NSView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(gates(from: inner).count, 0)

        win.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosted.layoutSubtreeIfNeeded()

        let live = try XCTUnwrap(scrollViews(hosted).dropFirst().first)
        XCTAssertEqual(gates(from: live).count, 1,
                       "expected exactly one gate after returning to a window, found \(gates(from: live).count)")
    }
}
