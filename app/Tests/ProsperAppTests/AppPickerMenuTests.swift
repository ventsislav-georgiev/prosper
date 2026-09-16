import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #124 — on-device report: "this button here does not work" against the
/// "＋ Launch an app…" picker. `AppPickerMenu` is the same control already
/// shipping in Key Remapping and `Mouse/MousePane.swift`, so the diagnosis's
/// working theory was that the control itself is fine and the real bug was the
/// picked row being invisible afterward (see `ShortcutCatalogTests
/// .testAllActionsKeepsBoundRows` and the visibility fix in `ShortcutsPane`).
///
/// This proves the OTHER half rather than assuming it: the popover's CONTENT
/// really builds — walks the real `AppIndex`, lays out real app rows, no crash.
/// It does NOT drive AppKit into actually presenting the `NSPopover` window:
/// pre-seeding `showing = true` and hosting `AppPickerMenu` in a bare
/// `NSHostingView`/`NSWindow` produces no popover child window and no attached
/// sheet even after activating the app and pumping the run loop for a full
/// second — that is a WindowServer mechanic this test harness cannot drive, not
/// evidence of a bug. That last mile (does `Button { showing.toggle() }` really
/// open the OS popover on screen) was NOT verified here and needs an on-device
/// check.
@MainActor
final class AppPickerMenuTests: XCTestCase {
    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
    }

    private func scrollViews(_ v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = v as? NSScrollView { out.append(s) }
        for sub in v.subviews { out += scrollViews(sub) }
        return out
    }

    func testPopoverBodyBuildsAndListsRealApps() throws {
        // At least one app must exist on this machine for the list to be
        // non-trivial — true of any real Mac (Finder alone guarantees it).
        XCTAssertFalse(AppIndex.shared.ensureBuilt().isEmpty,
                       "no installed apps found — can't prove the row list actually builds")

        let menu = AppPickerMenu(label: "Launch an app", help: "") { _, _ in }
        let host = NSHostingView(rootView: menu.popoverBody)
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 300)
        // Needs a real window: the `ScrollView`/`LazyVStack` document never gets
        // real geometry from a bare, unparented `NSHostingView` (same reason
        // `ShortcutTableScrollTests` hosts inside an `NSWindow`).
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.contentView = host
        flush(host)

        let scroll = try XCTUnwrap(scrollViews(host).first,
                                   "popover content has no scroll view — did it even build?")
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, 0,
                             "app list rendered with zero height — no rows laid out")
    }
}
