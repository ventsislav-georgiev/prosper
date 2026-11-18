import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1474: the mode switch at the bottom of the Agent Sessions sidebar (Full, Mini, Hidden). Offscreen only: windows are
/// built and never shown, ordered in or made key; a click is an AX press on the offscreen window's own element, never an
/// event. The mode lives in Preferences.defaults (the private test store); AgentSidebarModeTests' row wrapper saves and
/// puts back the mode, the gate, the scale and the Slide seams.
@MainActor
final class AgentSidebarModeSwitchTests: XCTestCase {
    private let modes = AgentSidebarModeTests()
    private let d1 = AgentWindowD1Tests()
    static let labels = ["Full", "Mini", "Hidden, slides in"]

    private func ours(_ t: [AXTreeNode]) -> [AXTreeNode] {
        t.filter { !$0.ignored && $0.role == "AXButton" && Self.labels.contains($0.label) }
    }

    /// The switch sits at the bottom of the drawn sidebar in Full, in Mini (stacked, inside the rail) and in Slide's
    /// slid-in sidebar (a row), at 0.7, 0.85 and 1.0; every segment keeps its sz(20) by sz(18) target.
    func testSwitchSitsAtTheBottomOfTheSidebarInEveryModeAndScale() throws {
        try modes.withModeRow {
            for scale in AgentSidebarModeTests.scales {
                ThemeRuntime.scale = scale
                for mode in AgentSidebarMode.allCases {
                    try modes.built(mode) { win, m in
                        XCTAssertEqual(ThemeRuntime.scale, scale, "the scale held after the build")
                        if mode == .slide { m.toggleSidebar(); modes.settle(win) }   // pinned open: the slid-in sidebar
                        XCTAssertTrue(m.sidebarShown, "\(mode) at \(scale)")
                        let restore = AXTreeSupport.axOn()
                        defer { restore() }
                        let host = try XCTUnwrap(win.contentView)
                        let found = ours(AXTreeSupport.poll(host) { ours($0).count >= 3 })
                        XCTAssertEqual(Set(found.map(\.label)), Set(Self.labels), "\(mode) at \(scale)")
                        XCTAssertEqual(found.count, 3, "one switch, \(mode) at \(scale)")
                        let pixel = AXTreeSupport.devicePixel(of: win), frame = win.frame
                        let width = mode == .mini ? AgentWindowModel.miniSidebarWidth : AgentWindowModel.fullSidebarWidth
                        let seg = AgentSidebarModeSwitch.segment
                        for n in found {
                            XCTAssertGreaterThanOrEqual(n.frame.minX - frame.minX, -pixel, "\(n.label) inside, \(mode) at \(scale)")
                            XCTAssertLessThanOrEqual(n.frame.maxX - frame.minX, width + pixel, "\(n.label) inside the sidebar, \(mode) at \(scale)")
                            XCTAssertGreaterThanOrEqual(n.frame.width, seg.width - pixel, "\(n.label) target, \(mode) at \(scale)")
                            XCTAssertGreaterThanOrEqual(n.frame.height, seg.height - pixel, "\(n.label) target, \(mode) at \(scale)")
                        }
                        // AX frames are y-up: the lowest segment's bottom is the switch's bottom padding above the window's.
                        let bottom = (found.map(\.frame.minY).min() ?? .infinity) - frame.minY
                        XCTAssertEqual(bottom, sz(6), accuracy: pixel + 1, "at the very bottom, \(mode) at \(scale)")
                        let xs = Set(found.map { ($0.frame.minX * 2).rounded() }), ys = Set(found.map { ($0.frame.minY * 2).rounded() })
                        if mode == .mini {
                            XCTAssertTrue(xs.count == 1 && ys.count == 3, "Mini: stacked, \(found.map(\.frame))")
                        } else {
                            XCTAssertTrue(xs.count == 3 && ys.count == 1, "\(mode): a row, \(found.map(\.frame))")
                        }
                    }
                }
            }
        }
    }

    /// A press on each segment sets that mode through the model and saves it (what Settings reads); the pressed one reads
    /// selected and the others not; a press on the current mode keeps it.
    func testEachSegmentSetsItsModeAndIsTheSelectedOne() throws {
        try modes.withModeRow {
            Preferences.agentSidebarMode = .full
            let m = d1.windowModel(d1.store([d1.session("api", .idle)]))
            defer { m.close() }
            m.setVisible(true)
            let restore = AXTreeSupport.axOn()
            defer { restore() }
            let width = AgentWindowModel.fullSidebarWidth
            let (win, host) = AXTreeSupport.hosted(AgentSidebarView(model: m).frame(width: width, height: 600),
                                                   CGSize(width: width, height: 600))
            defer { win.close() }
            let first = AXTreeSupport.poll(host) { ours($0).count >= 3 }
            XCTAssertEqual(ours(first).filter(\.selected).map(\.label), ["Full"], "the open mode is selected")
            for (mode, label) in [(AgentSidebarMode.mini, "Mini"), (.slide, "Hidden, slides in"), (.full, "Full"), (.full, "Full")] {
                XCTAssertEqual(mode.label, label)
                let button = try XCTUnwrap(pressable(host, label: label), "no segment \(label)")
                XCTAssertTrue(press(button), "\(label) pressed")
                XCTAssertEqual(m.sidebarMode, mode, "the model, after \(label)")
                XCTAssertEqual(Preferences.agentSidebarMode, mode, "saved, after \(label)")
                let tree = AXTreeSupport.poll(host) { t in ours(t).filter(\.selected).map(\.label) == [label] }
                XCTAssertEqual(ours(tree).filter(\.selected).map(\.label), [label], "only \(label) selected")
            }
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// The switch alone: three buttons named by AgentSidebarMode.label (VoiceOver and the tooltip), no text drawn; each
    /// segment is its named SF Symbol; its inks are the theme's, on a dark and on a light theme.
    func testLabelsSymbolsAndInksAndNoText() throws {
        try modes.withModeRow {
            XCTAssertEqual(AgentSidebarMode.allCases.map(\.label), Self.labels)
            XCTAssertEqual(AgentSidebarMode.allCases.map(AgentSidebarModeSwitch.symbol), ["sidebar.left", "sidebar.squares.left", "rectangle"])
            for mode in AgentSidebarMode.allCases {
                XCTAssertNotNil(NSImage(systemSymbolName: AgentSidebarModeSwitch.symbol(mode), accessibilityDescription: nil), "\(mode)")
            }
            Preferences.agentSidebarMode = .mini
            let m = d1.windowModel(d1.store([d1.session("api", .idle)]))
            defer { m.close() }
            let size = CGSize(width: AgentWindowModel.fullSidebarWidth, height: sz(100))
            let tree = AXTreeSupport.tree(AgentSidebarModeSwitch(model: m).frame(width: size.width), size) { ours($0).count >= 3 }
            let found = ours(tree)
            XCTAssertEqual(found.map(\.label), Self.labels, "\(tree.map { "\($0.role) \($0.label)" })")
            for n in found { XCTAssertEqual(n.help, n.label, "the tooltip is the label") }
            XCTAssertEqual(tree.filter { !$0.ignored && $0.label == "Sidebar mode" }.count, 1, "the group is named: \(tree.map { "\($0.role) \($0.label)" })")
            XCTAssertFalse(tree.contains { !$0.ignored && $0.role == "AXStaticText" }, "no text: \(tree.map { "\($0.role) \($0.label)" })")
            XCTAssertEqual(tree.filter { !$0.ignored && $0.role == "AXButton" }.count, 3, "no other button")
            let saved = ThemeRuntime.palette
            defer { ThemeRuntime.palette = saved }
            var accents: [Color] = []
            for dark in [true, false] {
                ThemeRuntime.palette = dark ? saved : AgentWindowD1Tests.lightPalette
                XCTAssertEqual(AgentSidebarModeSwitch.ink(true), Neon.blue, "the current mode in the accent, dark \(dark)")
                XCTAssertEqual(AgentSidebarModeSwitch.ink(false), Neon.textSecondary, "the others secondary, dark \(dark)")
                XCTAssertEqual(AgentSidebarModeSwitch.fill(true), Neon.blue.opacity(0.2), "a faint accent fill, dark \(dark)")
                XCTAssertEqual(AgentSidebarModeSwitch.fill(false), Color.clear, "no fill, dark \(dark)")
                accents.append(AgentSidebarModeSwitch.ink(true))
            }
            XCTAssertNotEqual(accents.first, accents.last, "the light theme's accent is its own")
        }
    }

    /// #1474 b (QA R1511 s1): non-text UI needs 3:1. On every bundled theme (Increase Contrast off), the idle symbol
    /// (textSecondary at idleOpacity over the sidebar) and the current one (the accent over its 0.2 fill over the sidebar,
    /// never dimmed) clear it. The measured figures are printed (IDLE1474B); 0.6 left 8 themes under.
    func testIdleAndCurrentSymbolsClearThreeToOneOnEveryTheme() throws {
        let t = AgentRowSelectedTextTests()
        var cases = 0
        try t.onEveryTheme { d, p in
            let sidebar = t.rgba(p.sidebar)
            let idle = ThemeContrastTests.contrast(NSColor(Neon.textSecondary).withAlphaComponent(AgentSidebarModeSwitch.idleOpacity),
                                                   on: t.ns(sidebar))
            let fill = t.over(sidebar, p.blue, 0.2)
            let current = ThemeContrastTests.contrast(NSColor(AgentSidebarModeSwitch.ink(true)), on: t.ns(fill))
            print("IDLE1474B \(d.title) idle \(idle) current \(current) at \(AgentSidebarModeSwitch.idleOpacity)")
            XCTAssertGreaterThanOrEqual(idle, 3, "\(d.title): idle symbol is \(idle):1")
            XCTAssertGreaterThanOrEqual(current, 3, "\(d.title): current symbol is \(current):1")
            cases += 1
        }
        XCTAssertEqual(cases, 22)
    }

    // MARK: AX press (no event; the offscreen window's own tree)

    /// The first element under `e` named `label` that takes a press.
    private func pressable(_ e: Any, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 60, let o = e as? NSObject else { return nil }
        let sel = NSSelectorFromString("accessibilityPerformPress")
        if o.responds(to: Selector(("accessibilityLabel"))), (o.value(forKey: "accessibilityLabel") as? String) == label,
           o.responds(to: sel) { return o }
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
            if let found = pressable(k, label: label, depth: depth + 1) { return found }
        }
        return nil
    }

    private func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard o.responds(to: sel) else { return false }
        if let p = o as? NSAccessibilityProtocol { return p.accessibilityPerformPress() }
        _ = o.perform(sel)
        return true
    }
}
