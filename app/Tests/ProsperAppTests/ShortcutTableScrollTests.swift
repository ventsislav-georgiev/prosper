import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #122 — the Shortcuts pane tore and stuttered while scrolling with the full
/// catalog (hundreds of rows once every extension's items are expanded).
///
/// The cause was NOT that the row `LazyVStack` stopped being lazy — it stays
/// lazy. It was that the lazy stack sat directly inside `NeonScroll`, so the
/// PANE's scroll view got a document 28,309 pt tall for 500 rows (44 screens),
/// whose height AppKit then re-estimated as rows realized: measured drifting to
/// 28,487 pt over one full scroll pass. A document that resizes underneath the
/// scroller is the tearing. Bounding the list (`NeonBoundedList`) pins the outer
/// document at one screen and moves the row churn into an inner scroll, where a
/// full pass touches 7 row bodies instead of 104.
///
/// This test is the guard the #118 harness should have been: it measures the
/// rendered view, not the model.
@MainActor
final class ShortcutTableScrollTests: XCTestCase {
    private func rows(_ n: Int) -> [BindableAction] {
        (0..<n).map { i in
            BindableAction(kind: .extensionItem, key: "probe.\(i)",
                           title: "Probe action number \(i)",
                           category: i % 3 == 0 ? "Quick Toggles" : "System Settings",
                           icon: "bolt",
                           combo: KeyCombo(keyCode: 0, carbonModifiers: 0, display: ""),
                           // Uneven row heights are what makes the estimate drift.
                           conflictNote: i % 7 == 0 ? "Also bound to something else" : nil)
        }
    }

    private func scrollViews(_ v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = v as? NSScrollView { out.append(s) }
        for sub in v.subviews { out += scrollViews(sub) }
        return out
    }

    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
    }

    func testPaneScrollStaysBoundedWithTheFullCatalog() throws {
        let side = CGSize(width: 660, height: 640)
        let host = NSHostingView(rootView: NeonScroll {
            ShortcutTable(rows: self.rows(500), paneHeight: side.height, model: SettingsModel())
        })
        host.frame = CGRect(origin: .zero, size: side)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.contentView = host
        flush(host)

        let outer = try XCTUnwrap(scrollViews(host).first)
        var heights: Set<CGFloat> = []
        for step in 0...8 {
            let doc = (outer.documentView?.frame.height ?? 0).rounded()
            heights.insert(doc)
            // A few screens of slack for section chrome; the pre-fix value was
            // 28,309 pt, so this fails loudly if the bound is ever removed.
            XCTAssertLessThan(doc, side.height * 4,
                              "pane scroll document grew to \(doc)pt — the list is unbounded again")
            let target = max(0, doc - outer.contentSize.height) * CGFloat(step) / 8
            outer.contentView.scroll(to: NSPoint(x: 0, y: target))
            outer.reflectScrolledClipView(outer.contentView)
            flush(host)
        }
        // Constant across the whole scroll: no re-estimation, nothing to tear.
        XCTAssertEqual(heights.count, 1, "pane scroll document resized while scrolling: \(heights)")
    }

    // #127: numbers cut 30% on direct user preference (a shrink-to-content
    // version was tried and rejected as "too poppy UX") — same shape as #122,
    // `max(sz(224), paneHeight * 0.385)`.
    func testBoundedListHeightFollowsThePaneAndHasAFloor() {
        XCTAssertEqual(NeonBoundedList<EmptyView>.height(paneHeight: 1000), max(sz(224), 385), accuracy: 0.5)
        XCTAssertEqual(NeonBoundedList<EmptyView>.height(paneHeight: 200), sz(224), accuracy: 0.5)
    }

    private func textFields(_ v: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let f = v as? NSTextField { out.append(f) }
        for sub in v.subviews { out += textFields(sub) }
        return out
    }

    /// #126 — the picker moved onto the "All Actions" filter row, to the right
    /// of the field, and is `.fixedSize()` there. That guarantees the PICKER
    /// never shrinks; nothing guaranteed the FIELD wouldn't be squeezed to
    /// nothing beside it. Hosts at the narrowest real width — settings window's
    /// `contentMinSize` (820) minus the sidebar (218) minus `NeonScroll`'s own
    /// horizontal padding (26 a side) — and checks the field is still a usable
    /// text box, not a sliver.
    ///
    /// Checked directly against the FIELD's own AppKit frame rather than by also
    /// locating the picker's button node: `.buttonStyle(.neon)` renders without a
    /// distinct `NSButton`/`NSControl` subclass in this hosted hierarchy (dumped
    /// the tree to confirm — only the row's own icon-only `.plain`-style buttons
    /// show up as `NSButton`), so there is no reliable AppKit node to grab there.
    /// The field width bound below still proves the picker isn't invisible or
    /// zero-width: at 320.5pt (measured), the field gave up ~190pt of the
    /// ~510pt row to its neighbor rather than claiming the whole row for itself
    /// — the assertion's ceiling (`lessThan`) is exactly that check.
    func testAllActionsFilterFieldStaysUsableBesidePickerAtMinWidth() throws {
        let minContentWidth: CGFloat = 820 - 218 - 26 - 26
        let host = NSHostingView(rootView:
            ShortcutTable(rows: self.rows(5), paneHeight: 640, model: SettingsModel()))
        host.frame = CGRect(x: 0, y: 0, width: minContentWidth, height: 640)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.contentView = host
        flush(host)

        let field = try XCTUnwrap(
            textFields(host).first { $0.placeholderString == "Filter all actions\u{2026}" },
            "couldn't find the All Actions filter field")

        XCTAssertGreaterThan(field.frame.width, 150,
                             "All Actions filter field squeezed to \(field.frame.width)pt beside the picker at min window width")
        XCTAssertLessThan(field.frame.width, minContentWidth - 32 - 8 - 50,
                          "field claimed the whole row (\(field.frame.width)pt) — did the picker disappear?")
    }
}
