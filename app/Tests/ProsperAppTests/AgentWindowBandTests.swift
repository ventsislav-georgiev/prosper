import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #831 B1 step 5b (spec 9.1, 13, 14.2 R1.4 without the Mixed rows): the window-level band over the pane area. Offscreen
/// only: every view is hosted in a window never ordered in, no event is posted, no menu opens. The band is shown only while the split gate is on (#1224,
/// AgentWindowBand.shown): every row saves the gate, sets it and puts it back in a defer.
extension AgentWindowD1Tests {
    final class BandProbeBox { var seen: [String: CGRect] = [:] }
    /// The window's minimum before #1925 (640 x 420 at 1.0, plus #1470's chip growth): the band rows' narrowest layout.
    @MainActor static func oldMin(_ s: CGFloat) -> CGSize { CGSize(width: 640 * s + AgentWindowModel.digitColumnExtra(at: s), height: 420 * s) }

    /// Every band part's frame by kind ("band", "layout", "chip", "all"; "picker" never since #1471), from a fresh never-shown window at
    /// `size`, on the pixel grid of `backing` (nil: the screen's). The probe closure runs on the main actor (SwiftUI layout).
    @MainActor
    func bandSnapshot(_ m: AgentWindowModel, _ size: CGSize, backing: CGFloat? = nil) -> [String: CGRect] {
        let box = BandProbeBox()
        AgentWindowBand.probe = { kind, r in box.seen[kind] = r }
        defer { AgentWindowBand.probe = nil }
        let win = BandFixedBackingWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.fixedBacking = backing
        win.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        settle(host)
        XCTAssertFalse(win.isVisible, "never on screen")
        win.contentView = nil
        win.close()
        return box.seen
    }

    /// The chip slot's widest text as NSHostingView measures it: fittingSize rounds up to a whole point, so a slot is
    /// compared within one point below it, never to the point.
    @MainActor
    var bandChipMeasured: CGFloat {
        NSHostingView(rootView: Text(AgentWindowBand.chipWidest).font(Neon.font(11)).lineLimit(1).fixedSize()).fittingSize.width
    }

    /// Fixed slots (operator, 2026-11-09; 9.1; R1.4): at 0.7, 0.85 and 1.0, at the minimum window and a wide one, the band
    /// is one row of 30·s over the pane area (the area is the column less it), and every slot's frame is the same for each
    /// session state and with no session at all. Sizes from the scale alone: the layout and All slots at their set widths,
    /// the chip slot at its widest text, the All slot at the trailing edge (#1471: no detail-level picker after it).
    /// Wide: every slot is there. A click on the band is in no pane: the keys stay where they were.
    @MainActor
    func testAgentWindowBandHoldsEverySlotAtEveryScaleWidthAndState() throws {
        let saved = ThemeRuntime.scale, gate = AgentPaneLayout.splitsEnabled
        defer { ThemeRuntime.scale = saved; AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let screen = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true).backingScaleFactor
        print("#1253 band: this machine's backing scale \(screen); the row lays out at 1x and 2x whatever it is")
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let chipText = bandChipMeasured
            let st = store([session("api", .idle)])
            let m = windowModel(st)
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(paneKey("api")))
            bandTwoPanes(m)   // #1538: the band shows only with something to show; two panes (the chip slot) keep it
            let empty = windowModel(store([]))
            empty.setVisible(true)
            defer { empty.close() }
            bandTwoPanes(empty)
            let sizes = [("min", Self.oldMin(scale)), ("wide", CGSize(width: 1600, height: 900))]
            // #1253: on the 1x pixel grid of CI's runner and the 2x of a Retina Mac, whatever this machine's screen.
            for (label, size, px) in sizes.flatMap({ s in [CGFloat(1), 2].map { (s.0, s.1, $0) } }) {
                let tag = "\(label) \(scale) \(Int(px))x"
                st.sessions = [session("api", .idle)]
                let base = bandSnapshot(m, size, backing: px)
                XCTAssertEqual(ThemeRuntime.scale, scale, "#1512: the snapshot kept the scale (\(tag))")
                let band = try XCTUnwrap(base["band"], tag)
                let f = { (k: String) in base[k].map { "\($0.minX)...\($0.maxX) w \($0.width)" } ?? "none" }
                print("#1253 band \(tag): band.width \(band.width) all \(f("all")) layout \(f("layout"))"
                      + " chip \(f("chip")) chipText \(chipText) want all.maxX \(band.width - sz(16))")
                XCTAssertEqual(band.height, AgentWindowBand.height, accuracy: 1 / px, "one row of 30·s (\(tag))")
                XCTAssertEqual(band.width, size.width - AgentWindowModel.fullSidebarWidth - 1, accuracy: 1 / px, "over the whole pane column (\(tag))")
                XCTAssertEqual(m.paneArea.height, size.height - AgentWindowBand.height, accuracy: 1 / px, "the area under it (\(tag))")
                let all = try XCTUnwrap(base["all"], tag)
                XCTAssertEqual(all.width, AgentWindowBand.allWidth, accuracy: 1 / px, "the All slot keeps its room (\(tag))")
                // #1253: one device pixel, the edge snaps to the grid. #1471: the All slot is last now (no picker).
                XCTAssertEqual(all.maxX, band.width - sz(16), accuracy: 1 / px, "the All slot at the trailing edge (\(tag))")
                XCTAssertTrue(base["picker"] == nil, "#1471: no detail-level picker slot (\(tag))")
                if let l = base["layout"] { XCTAssertEqual(l.width, AgentWindowBand.layoutWidth, accuracy: 1 / px, "layout slot (\(tag))") }
                if let c = base["chip"] {
                    XCTAssertTrue(c.width <= chipText + 0.01 && c.width > chipText - 1, "the chip slot at its widest text (\(tag)): \(c.width) vs \(chipText)")
                }
                if label == "wide" {
                    XCTAssertTrue(["layout", "chip", "all"].allSatisfy { base[$0] != nil }, "wide: every slot (\(tag)): \(base.keys)")
                }
                func same(_ s: [String: CGRect], _ why: String) {
                    XCTAssertEqual(Set(s.keys), Set(base.keys), "the same slots (\(why), \(tag))")
                    for k in base.keys { assertSame(s[k], base[k], "\(k) (\(why), \(tag))") }
                }
                for state in [AgentState.working, .blocked, .done] {
                    st.sessions = [session("api", state)]
                    same(bandSnapshot(m, size, backing: px), "\(state)")
                }
                st.sessions = [session("api", .idle)]
                same(bandSnapshot(empty, size, backing: px), "no session")
            }
            // 7.2: the band is in no pane: a click there leaves the keys; a click under it is the pane's.
            let size = CGSize(width: 1600, height: 900), x = AgentWindowModel.fullSidebarWidth + 1 + 50
            m.keyFocus = .sidebar
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: x, y: AgentWindowBand.height / 2), in: size))
            XCTAssertEqual(m.keyFocus, .sidebar, "a band click changes no key focus (\(scale))")
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: x, y: AgentWindowBand.height + 50), in: size))
            XCTAssertEqual(m.keyFocus, .pane, "the pane under the band (\(scale))")
        }
    }

    /// 9.1's narrow-window tiers, swept from a wide window down to the minimum at 0.7, 0.85 and 1.0: the chip slot gives
    /// way first, then the layout slot; the All slot never goes (#1471: the picker and its narrower tiers are gone), and
    /// nothing that went comes back at a narrower width. The sweep must cross the step where the layout slot
    /// stands without the chip (so the order is seen, not assumed).
    @MainActor
    func testAgentWindowBandGivesWayChipFirstThenLayoutNeverTheAllSlot() throws {
        let saved = ThemeRuntime.scale, gate = AgentPaneLayout.splitsEnabled
        defer { ThemeRuntime.scale = saved; AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let m = windowModel(store([session("api", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(paneKey("api")))
            bandTwoPanes(m)   // #1538: the band shows only with something to show; two panes (the chip slot) keep it
            let least = Self.oldMin(scale)
            var hadChip = true, hadLayout = true, layoutAlone = 0
            var steps: [String] = []
            for w in stride(from: CGFloat(1600), through: least.width, by: -24) {
                let s = bandSnapshot(m, CGSize(width: w, height: least.height))
                let tag = "\(w) at \(scale)"
                XCTAssertEqual(ThemeRuntime.scale, scale, "#1512: the snapshot kept the scale (\(tag))")
                let chip = s["chip"] != nil, layout = s["layout"] != nil
                XCTAssertNotNil(s["all"], "the All slot never goes (\(tag))")
                XCTAssertTrue(!chip || layout, "the chip slot gives way before the layout slot (\(tag)): \(s.keys)")
                XCTAssertTrue(hadChip || !chip, "the chip slot does not come back narrower (\(tag))")
                XCTAssertTrue(hadLayout || !layout, "the layout slot does not come back narrower (\(tag))")
                if layout && !chip { layoutAlone += 1 }
                let step = "\(chip ? "chip+" : "")\(layout ? "layout+" : "")all"
                if steps.last?.hasSuffix(step) != true { steps.append("\(Int(w)): \(step)") }
                hadChip = chip; hadLayout = layout
            }
            XCTAssertGreaterThan(layoutAlone, 0, "the sweep crossed the layout-without-chip step at \(scale)")
            print("#1224 band tiers at \(scale) (window width: slots): \(steps.joined(separator: " | "))")
        }
    }

    /// Turns this process's accessibility tree on, as an AX client's attribute write would; the closure puts both
    /// attributes back as read (the R1137-1 rule). Main actor, called from a row's defer.
    @MainActor
    func bandAXOn() -> @MainActor () -> Void { AXTreeSupport.axOn() }

    /// The accessibility tree of `view` hosted at `size` in a never-shown borderless window, read until every name in
    /// `until` is there (bounded at 5 s, no fixed wait), and the window's frame on the screen (bottom-left origin).
    @MainActor
    func bandTree<V: View>(_ view: V, _ size: CGSize, until: [String]) -> (tree: [(names: [String], frame: CGRect)], screen: CGRect) {
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        var tree: [(names: [String], frame: CGRect)] = []
        func ready() -> Bool { until.allSatisfy { n in tree.contains { $0.names.contains(n) } } }
        let ceiling = Date().addingTimeInterval(5)
        repeat {
            settle(host)
            tree = []
            bandAX(host, &tree)
        } while !ready() && Date() < ceiling
        XCTAssertFalse(win.isVisible, "never shown")
        return (tree, win.convertToScreen(CGRect(origin: .zero, size: size)))
    }

    /// How many elements of `tree` read `name`.
    func bandCount(_ tree: [(names: [String], frame: CGRect)], _ name: String) -> Int {
        tree.filter { $0.names.contains(name) }.count
    }

    /// 13 and 9.1 on the real accessibility tree of the root view in a never-shown window, the split gate on: nothing in
    /// the band's row is read (the empty layout, chip and All slots add no element; the shown sidebar hides its button) and,
    /// #1471, no detail-level button is read anywhere in the window.
    @MainActor
    func testAgentWindowBandReadsNothingAndNoPickerIsLeft() throws {
        let restoreAX = bandAXOn()
        let saved = ThemeRuntime.scale, gate = AgentPaneLayout.splitsEnabled
        defer { ThemeRuntime.scale = saved; AgentPaneLayout.splitsEnabled = gate; restoreAX() }
        ThemeRuntime.scale = 1.0
        AgentPaneLayout.splitsEnabled = true
        let m = windowModel(store([session("api", .idle)]))
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(paneKey("api")))
        bandTwoPanes(m)   // #1538: the band shows only with something to show
        let size = CGSize(width: 1600, height: 900)
        let (tree, screen) = bandTree(AgentWindowRootView(model: m, scrolls: false), size, until: ["Session actions"])
        XCTAssertTrue(tree.contains { $0.names.contains("Session actions") }, "the header was read")
        for n in ["Focused view", "Default view", "Verbose view"] {
            XCTAssertEqual(bandCount(tree, n), 0, "#1471: \"\(n)\" is never read")
        }
        // The band's row in screen coordinates (bottom-left origin): the window's top 30·s, right of the sidebar.
        let row = CGRect(x: screen.minX + AgentWindowModel.fullSidebarWidth + 1, y: screen.maxY - AgentWindowBand.height,
                         width: size.width - AgentWindowModel.fullSidebarWidth - 1, height: AgentWindowBand.height)
        let inBand = tree.filter { !$0.names.isEmpty && $0.frame.width > 0 && row.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        // #1697: bandTwoPanes zooms, so the chip's own words are read there (testZoomViewChipIsReadByAccessibilityInTheBand)
        let other = inBand.filter { !$0.names.allSatisfy { $0.hasPrefix("Zoomed · ") } }
        XCTAssertTrue(other.isEmpty, "nothing but the chip is read in the band: \(other.map(\.names))")
    }

    /// #1470 a2: the full sidebar's width at the current scale: TIP's sz(290), plus how much wider the full row's chip
    /// column (all 18 chips) is than the nine Command chips', measured from the chip views as the product does
    /// (AgentWindowModel.digitColumnExtra). The pane area starts 1 pt (the line) right of it.
    @MainActor
    func measuredSidebarWidth() -> CGFloat {
        let w = AgentSidebarRowView.idealWidths(AgentSidebarRowView.digitColumn, AgentSidebarRowView.miniDigitColumn)
        XCTAssertEqual(w.count, 2, "the chip columns were measured")
        let extra = max(0, (w.first ?? 0) - (w.last ?? 0))
        XCTAssertGreaterThan(extra, 0, "#1470: the 18 chips' column is wider than the nine's")
        return sz(290) + extra
    }

    /// #1224 (the supervisor's decision, 2026-11-14): with the split gate off (the product) the window is the parent's.
    /// No band is laid out (no probe frame at all); the pane area is the whole column (paneAreaFrame and the size the
    /// view writes; a click in the top 30 points is the pane's, as before); #1471: no detail-level picker anywhere, and the
    /// window reads no picker button.
    /// At UI scale 1.0 in a 1600 x 900 content; the column's left edge from measuredSidebarWidth (#1470 a2).
    @MainActor
    func testAgentWindowGateOffHasNoBandAndNoPicker() throws {
        let restoreAX = bandAXOn()
        let saved = ThemeRuntime.scale, gate = AgentPaneLayout.splitsEnabled
        defer { ThemeRuntime.scale = saved; AgentPaneLayout.splitsEnabled = gate; restoreAX() }
        ThemeRuntime.scale = 1.0
        AgentPaneLayout.splitsEnabled = false
        XCTAssertFalse(AgentWindowBand.shown, "one gate: the split gate")
        let a = session("api", .idle)
        let m = windowModel(store([a]))
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(paneKey("api")))
        let size = CGSize(width: 1600, height: 900)
        let seen = bandSnapshot(m, size)
        XCTAssertTrue(seen.isEmpty, "no band and no band slot is laid out: \(seen.keys)")
        let lead = measuredSidebarWidth() + 1
        XCTAssertEqual(m.paneAreaFrame(in: size), CGRect(x: lead, y: 0, width: 1600 - lead, height: 900), "the parent's pane area")
        XCTAssertEqual(m.paneArea.width, 1600 - lead, accuracy: 0.5, "the view's pane area: the whole column")
        XCTAssertEqual(m.paneArea.height, 900, accuracy: 0.5, "the view's pane area: the whole height")
        m.keyFocus = .sidebar
        XCTAssertFalse(m.mouseDown(at: CGPoint(x: 341, y: 15), in: size))
        XCTAssertEqual(m.keyFocus, .pane, "a click in the top 30 points is the pane's, as before")
        let tree = bandTree(AgentWindowRootView(model: m, scrolls: false), size, until: ["Session actions"]).tree
        XCTAssertTrue(tree.contains { $0.names.contains("Session actions") }, "the header was read")
        for n in ["Focused view", "Default view", "Verbose view"] {
            XCTAssertEqual(bandCount(tree, n), 0, "#1471: \"\(n)\" is never read: every pane is a terminal, no picker")
        }
    }

    /// #1224: with the split gate on the band is laid out (one row of 30 points at 1.0 over the column) and
    /// the pane area starts under it (paneAreaFrame and the size the view writes); #1471: no picker slot.
    @MainActor
    func testAgentWindowGateOnTheBandIsLaidOutWithNoPicker() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let restoreAX = bandAXOn()
        let saved = ThemeRuntime.scale, gate = AgentPaneLayout.splitsEnabled
        defer { ThemeRuntime.scale = saved; AgentPaneLayout.splitsEnabled = gate; restoreAX() }
        ThemeRuntime.scale = 1.0
        AgentPaneLayout.splitsEnabled = true
        XCTAssertTrue(AgentWindowBand.shown, "one gate: the split gate")
        let a = session("api", .idle)
        let m = windowModel(store([a]))
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(paneKey("api")))
        bandTwoPanes(m)   // #1538: the band shows only with something to show
        let size = CGSize(width: 1600, height: 900)
        let seen = bandSnapshot(m, size)
        let band = try XCTUnwrap(seen["band"], "the band is laid out")
        let lead = measuredSidebarWidth() + 1
        XCTAssertEqual(band.width, 1600 - lead, accuracy: pixel)
        XCTAssertEqual(band.height, 30, accuracy: pixel)
        XCTAssertTrue(seen["picker"] == nil, "#1471: no picker slot in the band")
        XCTAssertEqual(m.paneAreaFrame(in: size), CGRect(x: lead, y: 30, width: 1600 - lead, height: 870), "the pane area under the band")
        XCTAssertEqual(m.paneArea.height, 870, accuracy: 0.5, "the view's pane area: the column less the band")
    }

    /// #1538: a second, empty pane beside the first (its target kept), so the band has something to show (the chip slot).
    /// #1697: two panes alone show no band; zoomed (the focused pane), the chip's words keep it.
    @MainActor
    func bandTwoPanes(_ m: AgentWindowModel) {
        m.adopt(paneLayout([m.layout.panes.first?.target, nil]).toggleZoom())
        XCTAssertTrue(m.layout.zoomed != nil && AgentWindowBand.shows(m), "#1697: zoomed, the band shows")
    }

    /// An AX client's walk: the names it is shown (AXDescription, AXTitle, AXValue; none for an ignored node) and the frame.
    @MainActor
    func bandAX(_ e: Any, _ out: inout [(names: [String], frame: CGRect)], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let ignored = !NSAccessibility.unignoredChildren(from: [o]).contains { ($0 as AnyObject) === o }
        let frame = o.responds(to: Selector(("accessibilityFrame")))
            ? (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero : .zero
        let names = ignored ? [] : ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].map(text).filter { !$0.isEmpty }
        out.append((names, frame))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { bandAX(k, &out, depth: depth + 1) }
    }
}

/// A window whose backing scale can be pinned (see KeyMappingRowLayoutTests): SwiftUI snaps the hosted views to it.
private final class BandFixedBackingWindow: NSWindow {
    var fixedBacking: CGFloat?
    override var backingScaleFactor: CGFloat { fixedBacking ?? super.backingScaleFactor }
}
