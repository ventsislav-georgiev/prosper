import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1108 P3b: the Read | Edit switch. Offscreen only: views are hosted in windows never shown (AXTreeSupport, the
/// precedent of AgentWindowHeaderTests.testSidebarTitleSharesTheHeaderTitleLine: ThemeStore.shared first, the scale
/// saved and restored in a defer, the window built after the scale is set); no event is posted, no file is touched.
/// Everything runs on the main actor.
final class CapsuleSwitchTests: XCTestCase {
    private struct Seg { let label: String; let frame: CGRect; let selected: Bool; let enabled: Bool; let help: String }

    @MainActor
    private func sw(_ mode: TextViewerMode, off: String? = nil, set: @escaping (Int) -> Void = { _ in }) -> some View {
        CapsuleSwitch(titles: TextViewerMode.allCases.map(\.title), selected: mode.rawValue, set: set,
                      help: CapsuleSwitch.textViewerHelp, off: off).disabled(off != nil)
    }

    /// The buttons of a hosted never-shown view, in tree order. The selected trait is read from the node itself
    /// (AXTreeNode has no field for it): by isAccessibilitySelected, falling back to the AXSelected attribute.
    @MainActor
    private func segments<V: View>(_ view: V, _ size: CGSize? = nil) -> (segs: [Seg], fitting: CGSize) {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let fitting = NSHostingView(rootView: view).fittingSize
        let (win, host) = AXTreeSupport.hosted(view, size ?? fitting)
        defer { win.close() }
        _ = AXTreeSupport.poll(host) { t in t.filter { $0.role == "AXButton" }.count >= 2 }
        var out: [Seg] = []
        func visit(_ e: Any, _ depth: Int) {
            guard depth < 60, let o = e as? NSObject else { return }
            var n: [AXTreeNode] = []
            AXTreeSupport.walk(o, &n, depth: 59)   // this node only (its children are visited below)
            if let me = n.first, me.role == "AXButton" {
                var sel = false
                if o.responds(to: Selector(("isAccessibilitySelected"))) { sel = (o.value(forKey: "accessibilitySelected") as? NSNumber)?.boolValue ?? false }
                else if let v = o.accessibilityAttributeValue(.selected) as? NSNumber { sel = v.boolValue }
                out.append(Seg(label: me.label.isEmpty ? me.title : me.label, frame: me.frame, selected: sel, enabled: me.enabled, help: me.help))
            }
            for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { visit(k, depth + 1) }
        }
        visit(host, 0)
        XCTAssertFalse(win.isVisible, "never on screen")
        return (out, fitting)
    }

    @MainActor
    func testReadFirstAndSelectedByDefaultThenEdit() {
        XCTAssertEqual(TextViewerMode.allCases, [.read, .edit])
        XCTAssertEqual(TextViewerMode.allCases.map(\.title), ["Read", "Edit"])
        let r = segments(sw(.read)).segs
        XCTAssertEqual(r.map(\.label), ["Read", "Edit"])
        XCTAssertEqual(r.map(\.selected), [true, false], "Read is selected")
        let e = segments(sw(.edit)).segs
        XCTAssertEqual(e.map(\.label), ["Read", "Edit"])
        XCTAssertEqual(e.map(\.selected), [false, true], "Edit is selected after the value changes")
    }

    /// The segment's action is the view's own `choose` (what each Button's action calls): no event, no press.
    @MainActor
    func testSetIsCalledOnceForAnotherSegmentAndNeverForTheSelectedOne() {
        var got: [Int] = []
        CapsuleSwitch.choose(TextViewerMode.edit.rawValue, selected: TextViewerMode.read.rawValue) { got.append($0) }
        XCTAssertEqual(got, [1], "once, with edit")
        CapsuleSwitch.choose(TextViewerMode.read.rawValue, selected: TextViewerMode.read.rawValue) { got.append($0) }
        XCTAssertEqual(got, [1], "not for the selected one")
    }

    /// A label's natural width: the same Text, font and scale, alone.
    @MainActor
    private func natural(_ title: String) -> CGFloat {
        NSHostingView(rootView: Text(title).font(Neon.font(10.5, weight: .medium)).fixedSize()).fittingSize.width
    }

    @MainActor
    func testNoClippingAtEveryScaleAndFixedSlots() {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let tag = "\(scale)"
            // The control: the same label in a deliberately too-narrow frame is measured as clipped by the same method
            // (the segment's drawn width less its paddings, against the Text's natural width).
            let narrow = Button {} label: {
                Text("Read").font(Neon.font(10.5, weight: .medium)).frame(width: 5)
                    .padding(.horizontal, sz(8)).padding(.vertical, sz(3)).background(Capsule().fill(.clear)).fixedSize()
            }.buttonStyle(.plain).accessibilityLabel("Read")
            let control = segments(HStack(spacing: 0) { narrow; narrow })
            let cw = control.segs.first.map { $0.frame.width - 2 * sz(8) } ?? -1
            XCTAssertLessThan(cw, natural("Read") - 1, "the method sees the control clip (\(tag)): \(cw) < \(natural("Read"))")

            let r = segments(sw(.read)), e = segments(sw(.edit))
            XCTAssertEqual(r.segs.count, 2, tag)
            XCTAssertEqual(r.fitting.width, e.fitting.width, accuracy: 0.5, "same switch width with either selected (\(tag))")
            XCTAssertEqual(r.fitting.height, e.fitting.height, accuracy: 0.5, "same switch height (\(tag))")
            for (a, b) in zip(r.segs, e.segs) {
                XCTAssertEqual(a.frame.width, b.frame.width, accuracy: 0.5, "segment slots are fixed (\(tag))")
                XCTAssertEqual(a.frame.minX, b.frame.minX, accuracy: 0.5, tag)
            }
            for (seg, title) in zip(r.segs, ["Read", "Edit"]) {
                let label = seg.frame.width - 2 * sz(8)
                // 1.0: the accessibility frames are rounded to the pixel grid, which at a fractional UI scale costs up to half a point per edge.
                XCTAssertGreaterThanOrEqual(label, natural(title) - 1.0, "\(title) is not truncated (\(tag)): \(label)")
                XCTAssertGreaterThanOrEqual(label, 1, tag)
                XCTAssertGreaterThanOrEqual(seg.frame.minX, -0.5, "inside the switch (\(tag))")
                XCTAssertLessThanOrEqual(seg.frame.maxX, r.fitting.width + pixel, "inside the switch (\(tag))")
            }
            if let a = r.segs.first, let b = r.segs.last, r.segs.count == 2 {
                XCTAssertLessThanOrEqual(a.frame.maxX, b.frame.minX + pixel, "the capsules do not overlap (\(tag))")
                XCTAssertGreaterThanOrEqual(r.fitting.width, a.frame.width + b.frame.width - pixel, "the switch holds both (\(tag))")
            }
        }
    }

    @MainActor
    func testOffReasonDisablesTheButtonsAndIsTheHelp() {
        let on = segments(sw(.read)).segs
        XCTAssertEqual(on.map(\.enabled), [true, true])
        XCTAssertEqual(on.map(\.help), [CapsuleSwitch.textViewerHelp, CapsuleSwitch.textViewerHelp])
        XCTAssertTrue(CapsuleSwitch.textViewerHelp.contains("⌘T"))
        let off = segments(sw(.read, off: "Nothing to edit here")).segs
        XCTAssertEqual(off.count, 2)
        XCTAssertEqual(off.map(\.enabled), [false, false])
        XCTAssertEqual(off.map(\.help), ["Nothing to edit here", "Nothing to edit here"])
    }
}
