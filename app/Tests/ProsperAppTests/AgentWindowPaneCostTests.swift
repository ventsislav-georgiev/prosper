import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

#if DEBUG
/// #900 (#831 B2 step 6b2e; spec 3.4, 7.2, 8.1; R900-4b-1, R900-4b-2, R900-6b1-3): what the split work costs a window.
/// The three geometry probes attach no observer while nil; the too-small tier is a published value written only on a
/// change and only with the split gate on; the menus' dry runs per body pass do not grow with the sidebar's rows and are
/// none with the gate off. Offscreen only: every view is hosted in a borderless window that is never ordered in; no
/// event is built or posted; no menu is opened (counts come from the model's DEBUG counter); the accessibility flags go
/// on this process only (AXTreeSupport) and back. The split gate and the UI scale are saved, set and restored in a
/// defer. Sessions are fakes. Every closure here runs on the main actor (the sinks fire on the writer's thread, the
/// probes from SwiftUI's layout). Filter: 'AgentWindowD1Tests/testPaneCost'.
extension AgentWindowD1Tests {
    /// The root view of `m`, hosted at `size` in a never-shown window; `body` gets the host; the window is torn down after.
    @MainActor
    func paneCostHosted(_ m: AgentWindowModel, _ size: CGSize, _ body: (NSHostingView<AgentWindowRootView>) -> Void) {
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                           defer: true)
        win.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        defer { win.contentView = nil; win.close() }
        body(host)
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    // MARK: Item 1 (R900-4b-2): no observer while a probe is nil

    /// With every probe nil (the product), the window's sidebar rows, band and panes run no geometry callback, gate off
    /// and on, through hosting and a resize; with the row probe set the same window does (the counter is live).
    @MainActor
    func testPaneCostNoProbeObserverWhileTheProbesAreNil() {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        defer { ThemeRuntime.scale = saved; restoreModes(); AgentSidebarRowView.probe = nil }
        ThemeRuntime.scale = 1.0
        XCTAssertTrue(AgentSidebarRowView.probe == nil && AgentWindowBand.probe == nil && AgentPaneArea.probe == nil)
        for on in [false, true] {
            withTreeGate(on) {
                let m = windowModel(store([session("api", .idle), session("web", .idle)]))
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                m.setVisible(true)
                let before = agentProbeCallbacks
                paneCostHosted(m, CGSize(width: 1600, height: 900)) { host in
                    settle(host)
                    host.frame = CGRect(x: 0, y: 0, width: 1400, height: 800)
                    settle(host)
                }
                XCTAssertEqual(agentProbeCallbacks, before, "no probe set: no geometry callback (gate \(on))")
            }
        }
        withTreeGate(false) {
            let m = windowModel(store([session("api", .idle)]))
            defer { m.close() }
            m.setVisible(true)
            let box = PaneProbeBox()
            AgentSidebarRowView.probe = { kind, title, r in box.seen["\(kind) \(title)"] = r }   // before the view
            let before = agentProbeCallbacks
            paneCostHosted(m, CGSize(width: 1600, height: 900)) { host in settle(host) }
            AgentSidebarRowView.probe = nil
            XCTAssertTrue(box.seen["title api"] != nil, "the row probe set before the view is built: the title reports")
            XCTAssertGreaterThan(agentProbeCallbacks, before, "and the counter sees it")
        }
    }

    // MARK: Item 2 (R900-4b-1): the too-small tier

    /// Gate on, A | B: a resize across the too-small line flips the tier once and publishes once, and the "in view" rows
    /// follow; a resize that stays on one side writes nothing; back across, once more. A layout change that crosses the
    /// line moves the stored tier too, so the next resize back is seen. Gate off: the same resizes write nothing.
    @MainActor
    func testPaneCostTierFlipsOnceAcrossTheLineAndNeverWithTheGateOff() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let web = AgentSidebar.RowID.live(paneKey("web"))
        let big = CGRect(x: 0, y: 0, width: 3000, height: 1000), big2 = CGRect(x: 0, y: 0, width: 2800, height: 900)
        let small = CGRect(x: 0, y: 0, width: 400, height: 300), small2 = CGRect(x: 0, y: 0, width: 420, height: 320)
        for on in [true, false] {
            withTreeGate(on) {
                let m = windowModel(store([session("api", .idle), session("web", .idle)]))
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                m.paneArea = big
                XCTAssertFalse(m.paneTooSmall)
                var sends = 0
                let sink = m.objectWillChange.sink { _ in sends += 1 }
                defer { sink.cancel() }
                let changes = m.paneAreaChanges
                m.paneArea = small
                XCTAssertEqual(m.paneTooSmall, on, "too small (gate \(on))")
                XCTAssertEqual(sends, on ? 1 : 0, "across the line: one publish, gate on only")
                XCTAssertEqual(m.inViewRows, [], "too small: none in view")
                m.paneArea = small2
                XCTAssertEqual(sends, on ? 1 : 0, "still too small: nothing written")
                m.paneArea = big
                XCTAssertFalse(m.paneTooSmall)
                XCTAssertEqual(sends, on ? 2 : 0, "back across: one more publish, gate on only")
                XCTAssertEqual(m.inViewRows, on ? [web] : [], "the glyph rows follow")
                m.paneArea = big2
                XCTAssertEqual(sends, on ? 2 : 0, "still fits: nothing written")
                XCTAssertEqual(m.paneAreaChanges, changes + 4, "every size reached the model")
            }
        }
        withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.paneArea = CGRect(x: 0, y: 0, width: 500, height: 600)
            XCTAssertFalse(m.paneTooSmall, "one pane is never too small")
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            XCTAssertTrue(m.paneTooSmall, "two panes of 250 points: the layout's change moved the tier")
            var sends = 0
            let sink = m.objectWillChange.sink { _ in sends += 1 }
            defer { sink.cancel() }
            m.paneArea = big
            XCTAssertFalse(m.paneTooSmall)
            XCTAssertEqual(sends, 1, "the resize back across the line is seen")
        }
    }

    /// #1697 (QA n37): a fresh model's pane area is unmeasured (.zero) until the view's first pass; a layout adopted then
    /// is not too small, so the first pass draws no band (no 30 pt jump when a layout opens). Measured, the tier works.
    @MainActor
    func testPaneCostUnmeasuredAreaIsNotTooSmallAndDrawsNoBand() {
        let names = ["api", "web", "db"]
        let restoreModes = transcriptMode(names)
        defer { restoreModes() }
        withTreeGate(true) {
            let m = windowModel(store(names.map { session($0, .idle) }))
            m.setVisible(true)
            defer { m.close() }
            XCTAssertEqual(m.paneArea, .zero, "unmeasured")
            m.adopt(paneLayout(names.map { paneTarget($0) }))
            XCTAssertFalse(m.paneTooSmall, "an unmeasured area is not too small")
            XCTAssertFalse(AgentWindowBand.shows(m), "no band for it")
            XCTAssertTrue(bandSnapshot(m, CGSize(width: 1600, height: 900)).isEmpty, "the first pass draws no band")
            m.paneArea = CGRect(x: 0, y: 0, width: 400, height: 300)
            XCTAssertTrue(m.paneTooSmall, "measured too small: the tier is set")
        }
    }

    /// The drawn check, through the window's own sidebar (never shown): gate on with A | B the other pane's row has the
    /// glyph and reads "in view"; a window resize that only crosses the too-small line redraws the row (the label loses
    /// "in view") with no other change of the model, and every frame the probes report after keeps its place (the slot,
    /// the title). Gate off: no slot or glyph ever, no "in view", and the tier is never written.
    @MainActor
    func testPaneCostResizeAcrossTheLineRedrawsTheSidebarGlyphInPlace() {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        let restoreAX = AXTreeSupport.axOn()
        defer { ThemeRuntime.scale = saved; restoreModes(); restoreAX(); AgentSidebarRowView.probe = nil }
        ThemeRuntime.scale = 1.0
        for on in [true, false] {
            withTreeGate(on) {
                let m = windowModel(store([session("api", .idle), session("web", .idle)]))
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                let wide = CGSize(width: 1600, height: 900), narrow = CGSize(width: 750, height: 900)
                m.paneArea = zoomViewArea(wide)
                m.setVisible(true)
                let box = PaneProbeBox()
                AgentSidebarRowView.probe = { kind, title, r in box.seen["\(kind) \(title)"] = r }   // before the view
                paneCostHosted(m, wide) { host in
                    func webLabels(_ t: [AXTreeNode]) -> [String] { t.map(\.label).filter { $0.hasPrefix("web") } }
                    let before = AXTreeSupport.poll(host) { t in
                        on ? webLabels(t).contains { $0.contains("in view") } : !webLabels(t).isEmpty
                    }
                    XCTAssertEqual(webLabels(before).contains { $0.contains("in view") }, on, "before (gate \(on))")
                    XCTAssertFalse(m.paneTooSmall)
                    let drawn = box.seen
                    XCTAssertTrue(drawn["title web"] != nil, "the row drawn: \(drawn.keys.sorted())")
                    XCTAssertEqual(drawn["glyph web"] != nil, on, "the glyph slot, gate on only")
                    box.seen = [:]
                    var sends = 0
                    let sink = m.objectWillChange.sink { _ in sends += 1 }
                    defer { sink.cancel() }
                    host.frame = CGRect(origin: .zero, size: narrow)
                    let after = AXTreeSupport.poll(host) { t in
                        !webLabels(t).isEmpty && !webLabels(t).contains { $0.contains("in view") }
                    }
                    XCTAssertFalse(webLabels(after).isEmpty, "the row is still drawn")
                    XCTAssertFalse(webLabels(after).contains { $0.contains("in view") }, "too small: not in view (gate \(on))")
                    XCTAssertEqual(m.paneTooSmall, on, "the tier, gate on only")
                    XCTAssertEqual(sends, on ? 1 : 0, "the tier's publish alone")
                    for (k, r) in box.seen where k.hasSuffix(" web") {
                        let was = drawn[k] ?? drawn[k.replacingOccurrences(of: "slot ", with: "glyph ")]
                        XCTAssertTrue(was.map { abs($0.minX - r.minX) < 0.5 && abs($0.width - r.width) < 0.5 } ?? false,
                                      "\(k) keeps its place: \(String(describing: was)) -> \(r)")
                    }
                    XCTAssertTrue((Array(drawn.keys) + Array(box.seen.keys)).allSatisfy {
                        on || (!$0.hasPrefix("slot") && !$0.hasPrefix("glyph"))
                    }, "gate off: no slot")
                }
                AgentSidebarRowView.probe = nil
            }
        }
    }

    // MARK: Item 3 (R900-6b1-3, the header menus): dry runs per body pass

    /// The model's dry runs (showing, splitting) while the root view of a window with `extra` more idle sessions than
    /// api and web (A | B) is hosted tall enough to build every row, then in one more body pass (a publish that changes
    /// nothing). No menu is opened: SwiftUI builds what it builds and the counter says how many ran.
    @MainActor
    func paneCostDryRuns(extra: Int, gate on: Bool) -> (rows: Int, hosting: Int, pass: Int) {
        var out = (rows: 0, hosting: -1, pass: -1)
        let names = ["api", "web"] + (0..<max(0, extra)).map { "s\($0)" }
        let restoreModes = transcriptMode(["api", "web"])
        defer { restoreModes() }
        withTreeGate(on) {
            let m = windowModel(store(names.map { session($0, .idle) }))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let size = CGSize(width: 1600, height: 4000)
            m.paneArea = zoomViewArea(size)
            m.setVisible(true)
            out.rows = m.sections.flatMap(\.rows).count
            let start = m.dryRuns
            paneCostHosted(m, size) { host in
                settle(host)
                out.hosting = m.dryRuns - start
                let mid = m.dryRuns
                m.objectWillChange.send()   // one more body pass of the sidebar and the headers; nothing changed
                settle(host)
                out.pass = m.dryRuns - mid
            }
        }
        return out
    }

    /// Gate off: no dry run at all, hosting or passing. Gate on: one body pass costs the same with 50 rows as with 10
    /// (the rows' menus add nothing per pass). The measured counts are printed for the report.
    @MainActor
    func testPaneCostMenuDryRunsDoNotGrowWithTheRowsAndAreNoneWithTheGateOff() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let off = paneCostDryRuns(extra: 48, gate: false)
        let on10 = paneCostDryRuns(extra: 8, gate: true)
        let on50 = paneCostDryRuns(extra: 48, gate: true)
        print("PANE COST COUNT gate off 50 rows: \(off); gate on 10 rows: \(on10); gate on 50 rows: \(on50)")
        XCTAssertEqual(off.rows, 50)
        XCTAssertEqual(on10.rows, 10)
        XCTAssertEqual(on50.rows, 50)
        XCTAssertEqual(off.hosting, 0, "gate off: no dry run while the window is built")
        XCTAssertEqual(off.pass, 0, "gate off: no dry run per body pass")
        XCTAssertGreaterThanOrEqual(on50.pass, 0)
        XCTAssertEqual(on50.pass, on10.pass, "gate on: a body pass costs the same with 50 rows as with 10")
    }
}
#endif
