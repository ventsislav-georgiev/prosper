import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import ProsperApp

/// #859 — the first row of "All Actions" had its key field's top border cut off
/// right under the filter field (operator, UI scale below 1.0).
///
/// Cause: `RecorderView` reports a fixed 110x24 intrinsic size, and the
/// representable kept it over the row's `.frame(width: sz(142), height: sz(24))`.
/// Below scale 1.0 the field was taller than its slot and overflowed it by half
/// the difference at the top (-1.8 pt at 0.85, -3.5 pt at 0.7, measured), which
/// the bounded list's scroll view clips on the first row (and on the last one
/// at the bottom).
///
/// Hosted offscreen: the window is never ordered front or made key.
@MainActor
final class BoundedListEdgeTests: XCTestCase {
    /// 10 bound rows, so "Bound" scrolls on its own too, plus 3 unbound ones.
    private func rows() -> [BindableAction] {
        let set = KeyCombo(keyCode: 0, carbonModifiers: UInt32(cmdKey), display: "")
        let unset = KeyCombo(keyCode: 0, carbonModifiers: 0, display: "")
        let bound = (0..<10).map { i in
            BindableAction(kind: .prosper, key: "edge.b\(i)", title: "Edge bound \(i)",
                           category: "Prosper", icon: "brain", combo: set, defaultCombo: set)
        }
        let unbound = (0..<3).map { i in
            // The operator's first row: a Prosper action with a reset button.
            BindableAction(kind: i == 0 ? .prosper : .extensionItem, key: "edge.u\(i)",
                           title: "Edge unbound \(i)", category: "Snippets", icon: "text.alignleft",
                           combo: unset, defaultCombo: i == 0 ? set : nil)
        }
        return bound + unbound
    }

    private func all<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] {
        var out: [T] = []
        if let x = v as? T { out.append(x) }
        for s in v.subviews { out += all(s, t) }
        return out
    }

    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
    }

    /// Shown recorder frames in the list's clip-view space, top to bottom. The lazy
    /// stack keeps recycled rows around hidden, at stale positions; those are skipped.
    private func recorderFrames(in sv: NSScrollView) -> [CGRect] {
        all(sv, RecorderView.self).filter { !$0.isHiddenOrHasHiddenAncestor }.map { $0.convert($0.bounds, to: sv.contentView) }
            .sorted { $0.minY < $1.minY }
    }

    private func checkLists(scale: CGFloat, query: String?, expectLists: Int, backing: CGFloat? = nil,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = ThemeRuntime.scale
        ThemeRuntime.scale = scale
        defer { ThemeRuntime.scale = saved; SettingsFocusRouter.shared.pendingShortcutsQuery = nil }
        // Prefills "All Actions" on appear, the same route a deep link uses.
        SettingsFocusRouter.shared.pendingShortcutsQuery = query

        let side = CGSize(width: 660, height: 900)
        let host = NSHostingView(rootView: NeonScroll {
            ShortcutTable(rows: self.rows(), paneHeight: side.height, model: SettingsModel())
        })
        host.frame = CGRect(origin: .zero, size: side)
        let win = FixedBackingWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.fixedBacking = backing
        win.contentView = host
        defer { win.contentView = NSView() }
        flush(host)

        let tag = "scale \(scale), backing \(win.backingScaleFactor), query \(query ?? "none")"
        // SwiftUI snaps each edge of a hosted view to the backing pixel grid, so a
        // field filling its sz(24) slot measures up to one pixel off it (21 or 20 for
        // 20.4 at 1x). Anything further off is the #859 overflow (24 in a 20.4 slot).
        let pixel = 1 / win.backingScaleFactor
        // [0] is the pane's own scroll; the rest are the bounded lists.
        let lists = Array(all(host, NSScrollView.self).dropFirst())
        XCTAssertEqual(lists.count, expectLists, "bounded lists at \(tag)", file: file, line: line)
        for (i, sv) in lists.enumerated() {
            XCTAssertEqual(sv.frame.height, NeonBoundedList<EmptyView>.height(paneHeight: side.height),
                           accuracy: 0.5, "list \(i) height moved at \(tag)", file: file, line: line)
            let clip = sv.contentView
            let top = recorderFrames(in: sv)
            let first = try XCTUnwrap(top.first, "no key field in list \(i) at \(tag)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(first.minY, clip.bounds.minY,
                                        "list \(i) first key field cut at the top at \(tag): \(first) in \(clip.bounds)",
                                        file: file, line: line)
            for f in top {
                XCTAssertEqual(f.height, sz(24), accuracy: pixel,
                               "key field overflows its row slot at \(tag): \(f)", file: file, line: line)
                XCTAssertEqual(f.width, sz(142), accuracy: pixel,
                               "key field overflows its column at \(tag): \(f)", file: file, line: line)
            }

            // The other end: scrolled all the way down, the last field shows whole too.
            let docH = sv.documentView?.frame.height ?? 0
            clip.scroll(to: NSPoint(x: 0, y: max(0, docH - clip.bounds.height)))
            sv.reflectScrolledClipView(clip)
            flush(host)
            let last = try XCTUnwrap(recorderFrames(in: sv).last, file: file, line: line)
            XCTAssertLessThanOrEqual(last.maxY, clip.bounds.maxY,
                                     "list \(i) last key field cut at the bottom at \(tag): \(last) in \(clip.bounds)",
                                     file: file, line: line)
        }
    }

    func testFirstAndLastKeyFieldsShowWholeAtEveryScaleUnfiltered() throws {
        // nil: this machine's own backing scale; 1: CI's non-Retina grid.
        for backing in [nil, 1] as [CGFloat?] {
            for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                try checkLists(scale: scale, query: nil, expectLists: 2, backing: backing)
            }
        }
    }

    /// "All Actions" filtered down to three rows, the operator's case; it stays a
    /// bounded list (threshold 0) with content shorter than its frame.
    func testFirstAndLastKeyFieldsShowWholeAtEveryScaleFiltered() throws {
        // nil: this machine's own backing scale; 1: CI's non-Retina grid.
        for backing in [nil, 1] as [CGFloat?] {
            for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                try checkLists(scale: scale, query: "unbound", expectLists: 2, backing: backing)
            }
        }
    }
}

/// A window whose backing scale can be pinned, so a Retina machine lays out on the
/// 1x pixel grid CI's runner uses. SwiftUI snaps the hosted views to this value.
private final class FixedBackingWindow: NSWindow {
    var fixedBacking: CGFloat?
    override var backingScaleFactor: CGFloat { fixedBacking ?? super.backingScaleFactor }
}
