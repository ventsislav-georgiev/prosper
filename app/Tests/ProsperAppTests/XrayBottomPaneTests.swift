import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2066: the X-ray drawer's bottom pane: a height fraction (default 0.4) remembered per Mac, clamped on read, stored once
/// at a drag's end, folded to its strip near the strip, reset by a double-click; the X-ray content above keeps 120 pt; the
/// tab remembered; each tab's empty line. Offscreen only: drags go through the model's pure seam (no event is built or
/// posted); the store is the XCTest scratch defaults; views are hosted in never-shown windows. No dch runs.
@MainActor
final class XrayBottomPaneTests: XCTestCase {
    static let keys = ["xrayBottomFraction", "xrayBottomTab"]

    /// Runs `body` at UI scale 1.0 with the two keys cleared in the scratch defaults, put back after.
    func withClearedKeys(_ body: () throws -> Void) rethrows {
        XCTAssertFalse(Preferences.defaults === UserDefaults.standard, "a private defaults store")
        let saved = Self.keys.map { Preferences.defaults.object(forKey: $0) }
        let scale = ThemeRuntime.scale
        defer {
            for (k, v) in zip(Self.keys, saved) { Preferences.defaults.set(v, forKey: k) }
            ThemeRuntime.scale = scale
        }
        for k in Self.keys { Preferences.defaults.removeObject(forKey: k) }
        ThemeRuntime.scale = 1.0
        try body()
    }

    /// Red at TIP (no XrayBottomPane, no key). Mutant bottom-clamp-removed (the getter returns the raw number) fails the
    /// 5 and -3 lines: a stored value is outside data and reads clamped to 0...1; a non-number or non-finite one as unset.
    func testFractionDefaultsAndStoredValuesReadClampedNeverTrap() {
        withClearedKeys {
            XCTAssertEqual(XrayBottomPane().fraction, 0.4, "unset: the default")
            Preferences.defaults.set(5.0, forKey: "xrayBottomFraction")
            XCTAssertEqual(Preferences.xrayBottomFraction ?? -1, 1, accuracy: 0.0001, "over 1: clamped")
            XCTAssertLessThanOrEqual(XrayBottomPane().fraction, 1)
            Preferences.defaults.set(-3.0, forKey: "xrayBottomFraction")
            XCTAssertEqual(Preferences.xrayBottomFraction ?? -1, 0, accuracy: 0.0001, "negative: clamped (folded)")
            XCTAssertTrue(XrayBottomPane().collapsed)
            Preferences.defaults.set(0.25, forKey: "xrayBottomFraction")
            XCTAssertEqual(XrayBottomPane().fraction, 0.25, accuracy: 0.0001, "in range: as stored")
            let bad: [Any] = [Double.nan, Double.infinity, -Double.infinity, "0.5", true]
            for b in bad {
                Preferences.defaults.set(b, forKey: "xrayBottomFraction")
                XCTAssertTrue(Preferences.xrayBottomFraction == nil, "\(b) reads as unset")
                XCTAssertEqual(XrayBottomPane().fraction, 0.4, "\(b): the default")
            }
        }
    }

    /// Red at TIP. Mutant bottom-floor-dropped (height ignores `total - floor`) fails every line: whatever the fraction
    /// and the drawer's height, the X-ray content above keeps 120 pt (scaled); the pane is at least its strip where it fits.
    func testContentAboveKeepsItsFloorAtSmallDrawerHeights() {
        withClearedKeys {
            for scale: CGFloat in [0.7, 1.0, 1.3] {
                ThemeRuntime.scale = scale
                for (f, total): (CGFloat, CGFloat) in [(0.9, 200), (1, 1000), (0.4, 140), (0.6, 300), (0, 130)] {
                    let h = XrayBottomPane.height(f, in: total)
                    XCTAssertGreaterThanOrEqual(total - h, min(total, 120 * scale) - 0.001, "content floor: \(f) of \(total) at \(scale)")
                    XCTAssertGreaterThanOrEqual(h, 0)
                }
                XCTAssertEqual(XrayBottomPane.height(0.4, in: 1000), 400, accuracy: 0.001, "a tall drawer: the fraction")
                XCTAssertEqual(XrayBottomPane.height(0, in: 1000), 32 * scale, accuracy: 0.001, "folded: the strip")
            }
        }
    }

    /// Red at TIP. A drag previews (the content's `settled` stays) and stores once, at its end; a double-click resets to
    /// the default and removes the key.
    func testDragStoresOnceAtItsEndAndDoubleClickResets() {
        withClearedKeys {
            let b = XrayBottomPane()
            for i in 1...10 {
                b.dragged(by: CGFloat(-10 * i), in: 1000)   // up 10 pt a tick: taller
                XCTAssertTrue(Preferences.defaults.object(forKey: "xrayBottomFraction") == nil, "nothing stored mid-drag (tick \(i))")
                XCTAssertEqual(b.settled, 0.4, accuracy: 0.0001, "the content's room stays put mid-drag (tick \(i))")
                XCTAssertTrue(b.dragging)
            }
            XCTAssertEqual(b.fraction, 0.5, accuracy: 0.0001, "the preview: 400 + 100 of 1000")
            b.ended()
            XCTAssertFalse(b.dragging)
            XCTAssertEqual(b.settled, 0.5, accuracy: 0.0001, "settled at the end")
            XCTAssertEqual(Preferences.xrayBottomFraction ?? 0, 0.5, accuracy: 0.0001, "stored at the end")
            XCTAssertEqual(XrayBottomPane().fraction, 0.5, accuracy: 0.0001, "read back by a new pane")
            b.dragged(by: -10_000, in: 1000)
            b.ended()
            XCTAssertEqual(XrayBottomPane.height(b.fraction, in: 1000), 880, accuracy: 0.001, "dragged past the top: the floor stops it")
            b.reset()
            XCTAssertEqual(b.fraction, 0.4)
            XCTAssertTrue(Preferences.defaults.object(forKey: "xrayBottomFraction") == nil, "reset removes the key")
        }
    }

    /// Red at TIP. Mutant bottom-no-collapse (the snap to 0 dropped) fails the folded lines: a drag that ends within the
    /// snap of the strip folds the pane to its strip, stored; a header count group's show unfolds it to the default.
    func testDraggingDownToTheStripFoldsAndShowUnfolds() {
        withClearedKeys {
            let b = XrayBottomPane()
            b.dragged(by: 300, in: 1000)   // 400 to 100: above the snap, not folded
            XCTAssertFalse(b.collapsed, "control: 100 pt stays a pane")
            b.dragged(by: 358, in: 1000)   // 400 to 42: within the strip's 32 + the 24 pt snap
            b.ended()
            XCTAssertTrue(b.collapsed, "folded to its strip")
            XCTAssertEqual(XrayBottomPane.height(b.fraction, in: 1000), 32, accuracy: 0.001, "drawn as the strip")
            XCTAssertEqual(Preferences.xrayBottomFraction ?? -1, 0, accuracy: 0.0001, "the fold is stored")
            XCTAssertTrue(XrayBottomPane().collapsed, "a new drawer opens folded")
            b.show(.shells)
            XCTAssertFalse(b.collapsed, "a count group unfolds it")
            XCTAssertEqual(b.fraction, 0.4, accuracy: 0.0001)
            XCTAssertEqual(b.tab, .shells)
        }
    }

    /// Red at TIP. Mutant bottom-tab-not-stored (the didSet's write dropped) fails the read-back line: the tab is stored
    /// once chosen and read back by a new drawer; unset or unknown reads Agents.
    func testSelectedTabIsRememberedPerMac() {
        withClearedKeys {
            XCTAssertEqual(XrayBottomPane().tab, .agents, "default")
            let b = XrayBottomPane()
            b.tab = .shells
            XCTAssertEqual(Preferences.defaults.string(forKey: "xrayBottomTab"), "Shells")
            XCTAssertEqual(XrayBottomPane().tab, .shells, "read back on a new drawer")
            Preferences.defaults.set("Nope", forKey: "xrayBottomTab")
            XCTAssertEqual(XrayBottomPane().tab, .agents, "unknown: Agents")
        }
    }

    /// Red at TIP (no bottom pane). Each tab's body draws its one empty line (the drawn view, read through AX in a
    /// never-shown window); folded, no body.
    func testEachTabShowsItsEmptyLine() throws {
        _ = ThemeStore.shared   // #1510: warm before the scale is pinned
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        try withClearedKeys {
            let lines: [(XrayBottomTab, String)] = [(.agents, "No subagents running in this session."),
                                                     (.shells, "No background shells in this session."),
                                                     (.prs, "No pull requests for this session.")]
            let b = XrayBottomPane.shared
            let saved = b.tab
            defer { b.tab = saved; b.reset() }
            b.reset()
            for (tab, line) in lines {
                b.tab = tab
                let (win, host) = AXTreeSupport.hosted(XrayBottomView(bottom: b, total: 600), CGSize(width: 480, height: 600))
                defer { win.contentView = nil; win.close() }
                let tree = AXTreeSupport.poll(host) { $0.contains { $0.reads(line) } }
                XCTAssertTrue(tree.contains { $0.reads(line) }, "\(tab): \(line) in \(tree.map(\.names))")
                XCTAssertEqual(lines.filter { l in tree.contains { $0.reads(l.1) } }.count, 1, "\(tab): only its own line")
                XCTAssertTrue(tree.contains { $0.reads(tab.spoken) && $0.selected }, "\(tab): its strip button reads selected")
                XCTAssertFalse(win.isVisible, "never shown")
            }
            b.dragged(by: 1000, in: 600)
            b.ended()
            let (win, host) = AXTreeSupport.hosted(XrayBottomView(bottom: b, total: 600), CGSize(width: 480, height: 600))
            defer { win.contentView = nil; win.close() }
            let tree = AXTreeSupport.poll(host) { $0.contains { $0.reads("Agents") } }
            XCTAssertFalse(tree.contains { n in lines.contains { n.reads($0.1) } }, "folded: the strip only")
        }
    }
}
