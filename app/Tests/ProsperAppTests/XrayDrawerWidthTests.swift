import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1473: the X-ray drawer's width: a measured default, a drag on its leading edge clamped between a minimum and a share of
/// the space offered, remembered per Mac, reset by a double-click. Offscreen only: the drag goes through the model's pure
/// seam (no event is built or posted); the store is the XCTest scratch defaults; the strip is measured in a never-shown
/// hosting view. No dch runs.
@MainActor
final class XrayDrawerWidthTests: XCTestCase {
    static let key = "xrayDrawerWidth"

    /// Runs `body` with the width key cleared in the scratch defaults, put back after.
    func withClearedKey(_ body: () throws -> Void) rethrows {
        XCTAssertFalse(Preferences.defaults === UserDefaults.standard, "a private defaults store")
        let saved = Preferences.defaults.object(forKey: Self.key)
        defer { Preferences.defaults.set(saved, forKey: Self.key) }
        Preferences.defaults.removeObject(forKey: Self.key)
        try body()
    }

    /// A panel that shows every tab: dch's chapters with refs (gate on), Search on, Tasks, (#1974) Questions and Memory.
    func sixTabs() -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        p.now = { XrayPanelTasksTests.now }
        p.fromDch = { true }
        p.apply(tasks: (0, XrayPanelTasksTests.tasksOut), memory: (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory)),
                chapters: (0, XrayRefsParseTests.object(refs: XrayRefsTabTests.three)))
        p.searchable = true
        p.takeQuestions((0, XrayQuestionsTabTests.out))   // #1974
        return p
    }

    func fitting<V: View>(_ v: V) -> CGFloat { NSHostingView(rootView: v).fittingSize.width }

    /// Red at TIP (no XrayDrawerWidth; the drawer was sz(340)): the header (the six names' strip, the two 6 pt gaps, the close
    /// button and the 10 pt padding each side) fits the default width at 0.7, 0.85 and 1.0, so no name is cut and nothing scrolls.
    func testTheDefaultFitsEveryTabNameAtEachScale() {
        let gate = XrayPanels.refsTab
        defer { XrayPanels.refsTab = gate }
        XrayPanels.refsTab = { true }
        let p = sixTabs()
        XCTAssertEqual(p.tabs, XrayTab.allCases, "every tab")
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let names = fitting(XrayTabStrip(panel: p, counts: false))
            XCTAssertEqual(ThemeRuntime.scale, scale)
            let counts = fitting(XrayTabStrip(panel: p, counts: true))
            let close = fitting(Image(systemName: "xmark").font(Neon.font(10, weight: .medium)))
            let header = names + 2 * sz(6) + close + 2 * sz(10)   // the gaps either side of the Spacer
            let drawn = XrayDrawerWidth.width(stored: XrayDrawerWidth.standard, offered: 10_000)
            print("XRAYWIDTH scale \(scale) names \(names) counts \(counts) close \(close) header \(header) drawn \(drawn)")
            XCTAssertGreaterThan(names, 0, "measured at \(scale)")
            XCTAssertLessThanOrEqual(header, drawn, "every name fits at \(scale)")
        }
    }

    /// A drag on the leading edge: left widens, right narrows; it stops at 60% of the space offered and at the minimum, and
    /// the stored points are the drawn width over the scale.
    func testADragClampsAtBothEnds() {
        withClearedKey {
            let w = XrayDrawerWidth()
            XCTAssertEqual(w.points, XrayDrawerWidth.standard, "unset: the default")
            w.dragged(by: -50, offered: 1000, scale: 1)
            XCTAssertEqual(w.points, 470, accuracy: 0.001)
            XCTAssertTrue(w.dragging)
            w.dragged(by: -1000, offered: 1000, scale: 1)
            XCTAssertEqual(w.points, 600, accuracy: 0.001, "at most 60% of the space offered")
            w.dragged(by: 1000, offered: 1000, scale: 1)
            XCTAssertEqual(w.points, 300, accuracy: 0.001, "at least the minimum")
            w.ended()
            XCTAssertFalse(w.dragging)
            w.dragged(by: -10_000, offered: 1000, scale: 0.85)
            XCTAssertEqual(w.points * 0.85, 600, accuracy: 0.001, "the share holds at 0.85")
            w.dragged(by: 10_000, offered: 1000, scale: 0.85)
            XCTAssertEqual(w.points, 300, accuracy: 0.001, "the minimum is in points at scale 1.0")
            w.ended()
        }
    }

    /// The width persists through the scratch store and a new model reads it back; outside data that is not a finite
    /// positive number reads as unset (the default).
    func testTheWidthPersistsAndBadValuesReadAsTheDefault() {
        withClearedKey {
            let w = XrayDrawerWidth()
            w.dragged(by: -80, offered: 1000, scale: 1)
            XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil, "nothing is written while the drag runs")
            w.ended()
            XCTAssertEqual(Preferences.xrayDrawerWidth ?? 0, 500, accuracy: 0.001, "stored")
            XCTAssertEqual(XrayDrawerWidth().points, 500, accuracy: 0.001, "read back by a new model")
            for bad: Any in ["wide", true, -5.0, 0.0, Double.nan, Double.infinity] {
                Preferences.defaults.set(bad, forKey: Self.key)
                XCTAssertTrue(Preferences.xrayDrawerWidth == nil, "\(bad) reads as unset")
                XCTAssertEqual(XrayDrawerWidth().points, XrayDrawerWidth.standard)
            }
        }
    }

    /// A double-click on the handle resets: the default again and the key removed.
    func testResetRestoresTheDefault() {
        withClearedKey {
            let w = XrayDrawerWidth()
            w.dragged(by: 100, offered: 1000, scale: 1)
            XCTAssertEqual(w.points, 320, accuracy: 0.001)
            w.reset()
            XCTAssertFalse(w.dragging)
            XCTAssertEqual(w.points, XrayDrawerWidth.standard)
            XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil, "the key is gone")
            XCTAssertEqual(XrayDrawerWidth().points, XrayDrawerWidth.standard)
        }
    }

    /// A narrow pane never gets a drawer wider than the space offered, whatever is stored, at every scale; a wide one draws
    /// the stored width times the scale.
    func testANarrowPaneNeverGetsADrawerWiderThanItself() {
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            for offered: CGFloat in [0, 120, 250, 299, 400, 700, 2000] {
                for stored: CGFloat in [1, 300, 420, 600, 1e12] {
                    let d = XrayDrawerWidth.width(stored: stored, offered: offered, scale: scale)
                    XCTAssertLessThanOrEqual(d, offered, "stored \(stored), offered \(offered), scale \(scale)")
                    XCTAssertGreaterThanOrEqual(d, min(offered, 300 * scale), "never under the minimum while it fits")
                }
            }
            XCTAssertEqual(XrayDrawerWidth.width(stored: 420, offered: 2000, scale: scale), 420 * scale, accuracy: 0.001)
        }
        XCTAssertEqual(XrayDrawerWidth.width(stored: 1e12, offered: 250, scale: 1), 250, "the pane, not past it")
        XCTAssertEqual(XrayDrawerWidth.width(stored: 420, offered: 400, scale: 1), 300, "60% of 400 is under the minimum")
    }

    final class Under: NSView {}
    struct UnderView: NSViewRepresentable {
        func makeNSView(context: Context) -> Under { Under() }
        func updateNSView(_ v: Under, context: Context) {}
    }

    /// The pane's own view under `host` at `x` (host points, mid height), with an open drawer: true when the hit is the pane view.
    func paneTakesHit<V: View>(_ v: V, size: CGSize, x: CGFloat) -> Bool {
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        var v: NSView? = host.hitTest(host.convert(NSPoint(x: x, y: size.height / 2), to: host.superview))
        while let n = v, !(n is Under) { v = n.superview }
        return v != nil
    }

    /// R1512-c1: the drawer's frame-wide GeometryReader takes no hit where it draws nothing: a point left of the open drawer
    /// reaches the pane's view under it, at one pane and in a split (the drawer over the pane area); a point in the drawer
    /// does not (the drawer is drawn). Red when the GeometryReader's frame is a content shape (drawer-full-hit).
    func testThePaneLeftOfAnOpenDrawerKeepsItsClicks() {
        let pane = UUID(), p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        let target = XrayTarget(name: "api", dir: "/tmp/dch-test")
        XrayPanels.shared.open = [pane: p]
        defer { XrayPanels.shared.open = [:] }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let size = CGSize(width: 900, height: 400)
        for scale: CGFloat in [0.7, 1.0] {
            ThemeRuntime.scale = scale
            let drawn = XrayDrawerWidth.width(stored: XrayDrawerWidth.shared.points, offered: size.width)
            let left = size.width - drawn - 20, inside = size.width - drawn / 2
            let one = UnderView().overlay(alignment: .trailing) { XrayDrawer(pane: pane, target: target) }
            let split = HStack(spacing: 0) { UnderView(); UnderView() }
                .overlay(alignment: .trailing) { XrayDrawer(pane: pane, target: target) }
            for (name, v) in [("one pane", AnyView(one)), ("split", AnyView(split))] {
                XCTAssertTrue(paneTakesHit(v, size: size, x: left), "\(name): the pane left of the drawer takes the click at \(scale)")
                XCTAssertFalse(paneTakesHit(v, size: size, x: inside), "\(name): the drawer takes its own click at \(scale)")
            }
        }
    }
}
