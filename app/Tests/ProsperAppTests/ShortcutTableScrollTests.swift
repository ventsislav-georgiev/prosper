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

    func testBoundedListHeightFollowsThePaneAndHasAFloor() {
        XCTAssertEqual(NeonBoundedList<EmptyView>.height(paneHeight: 1000), max(sz(320), 550), accuracy: 0.5)
        XCTAssertEqual(NeonBoundedList<EmptyView>.height(paneHeight: 200), sz(320), accuracy: 0.5)
    }
}
