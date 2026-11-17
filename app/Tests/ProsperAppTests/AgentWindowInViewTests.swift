import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 4b; spec 7.2, 7.3, 7.4, 12.1; N900-a, N900-f): the zoom hit rule in the model after its
/// finiteness guard, ⌘W on the focused pane whoever has the keys, and the sidebar rows' "in view" glyph.
/// Offscreen only: every view is hosted in a window that is never ordered in; every key is built with NSEvent.keyEvent
/// and handed to a never-shown window's performKeyEquivalent (nothing posted, no window ordered in or made key, the
/// input source never read); a close is recorded by the window's delegate, which refuses it. Clicks are the model's
/// decision function called with literal points. The accessibility flags go on this process only (AXTreeSupport). The
/// split gate and the UI scale are saved, set and restored in a defer. Sessions are fakes.
/// Filter: 'AgentWindowD1Tests/testInView' (an extension of the class the pane rows live in).
extension AgentWindowD1Tests {
    // MARK: Item 1 (N900-f): the zoom hit rule after the finiteness guard

    /// 7.4 / N900-f: zoomed, a point or a content size that is not finite is refused before the zoom branch reads a
    /// frame: nothing focused, the keys stay where they were, the zoom stays; the same finite point is the zoomed pane's.
    @MainActor
    func testInViewZoomHitRefusesANonFinitePointOrFrameFirst() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let a = try XCTUnwrap(m.layout.order.first)
            let size = CGSize(width: 1600, height: 900)
            let p = CGPoint(x: size.width - 50, y: 450)   // in b's tile, unzoomed
            XCTAssertTrue(m.perform(.zoom))
            let zoomed = m.layout
            XCTAssertEqual(zoomed.zoomed, a)
            let points = [CGPoint(x: CGFloat.nan, y: 450), CGPoint(x: p.x, y: .infinity), CGPoint(x: -CGFloat.infinity, y: 450)]
            let sizes = [CGSize(width: CGFloat.infinity, height: 900), CGSize(width: 1600, height: CGFloat.nan),
                         CGSize(width: CGFloat.nan, height: .infinity)]
            for q in points {
                m.keyFocus = .sidebar
                XCTAssertFalse(AgentsNSWindow.mouseDown(m, at: q, in: size), "point \(q): refused")
                XCTAssertFalse(m.mouseDown(at: q, in: size))
                XCTAssertEqual(m.keyFocus, .sidebar, "point \(q): the keys stay")
                XCTAssertEqual(m.layout, zoomed, "point \(q): nothing focused, the zoom stays")
            }
            for s in sizes {
                m.keyFocus = .sidebar
                XCTAssertFalse(AgentsNSWindow.mouseDown(m, at: p, in: s), "size \(s): refused")
                XCTAssertFalse(m.mouseDown(at: p, in: s))
                XCTAssertEqual(m.keyFocus, .sidebar, "size \(s): the keys stay (the zoom branch never ran)")
                XCTAssertEqual(m.layout, zoomed, "size \(s): nothing focused, the zoom stays")
            }
            m.keyFocus = .sidebar
            XCTAssertFalse(AgentsNSWindow.mouseDown(m, at: p, in: size), "finite: the zoomed pane's, the click passes")
            XCTAssertEqual(m.keyFocus, .pane, "finite: the panes take the keys")
            XCTAssertEqual(m.layout, zoomed)
        }
    }

    // MARK: Item 2 (N900-a): ⌘W closes the focused pane whoever has the keys

    /// 7.3 / 12.1: with several panes and the gate on, ⌘W closes the FOCUSED pane while the sidebar has the keys and
    /// while a text view (the composer's kind) is first responder; with one pane it asks the window to close; gate off,
    /// two panes in the layout, ⌘W asks the window to close and no pane closes (as today).
    @MainActor
    func testInViewCommandWClosesTheFocusedPaneFromTheSidebarAndTheComposer() throws {
        try withTreeGate(true) {
            let (win, m, rec) = treeWindow()
            defer { win.makeFirstResponder(nil); win.close(); m.close() }
            let first = m.layout.focused
            XCTAssertTrue(press(win, "⌘D"))
            m.keyFocus = .sidebar
            XCTAssertEqual(win.responderKind, .other)
            XCTAssertTrue(press(win, "⌘W"), "sidebar keys: handled")
            XCTAssertEqual(rec.asks, 0, "never the window")
            XCTAssertEqual(m.layout.order, [first], "the focused (new) pane closed")

            XCTAssertTrue(press(win, "⌘D"))
            let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
            tv.string = "draft"
            win.contentView?.addSubview(tv)
            XCTAssertFalse(win.isVisible, "never shown")
            XCTAssertTrue(win.makeFirstResponder(tv))
            XCTAssertEqual(win.responderKind, .text)
            XCTAssertTrue(press(win, "⌘W"), "composer keys: handled")
            XCTAssertEqual(rec.asks, 0, "never the window")
            XCTAssertEqual(m.layout.order, [first], "the focused (new) pane closed")
            XCTAssertEqual(tv.string, "draft", "the text view got nothing")

            XCTAssertTrue(press(win, "⌘W"))
            XCTAssertEqual(rec.asks, 1, "one pane: ⌘W closes the window, as today")
            XCTAssertFalse(win.isVisible)
        }
        try withTreeGate(false) {
            let (win, m, rec) = treeWindow()
            defer { win.close(); m.close() }
            m.adopt(paneLayout([paneTarget("api"), nil]))
            m.keyFocus = .sidebar
            XCTAssertTrue(press(win, "⌘W"))
            XCTAssertEqual(rec.asks, 1, "gate off: the window, as today")
            XCTAssertEqual(m.layout.panes.count, 2, "and no pane")
        }
    }

    // MARK: Item 3 (7.2): the "in view" glyph

    /// 7.2: every session shown in the active layout other than the focused pane's is in view; the focused pane's row
    /// has the selection and is not; a zoom or the too-small fallback (the focused pane alone shown, 7.4 / 3.4: the
    /// others are hidden) gives none; gate off: none.
    @MainActor
    func testInViewRowsAreTheOtherShownPanesSessions() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let api = AgentSidebar.RowID.live(paneKey("api")), web = AgentSidebar.RowID.live(paneKey("web"))
        let db = AgentSidebar.RowID.live(paneKey("db"))
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle), session("db", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web"), paneTarget("db")]))
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            let order = m.layout.order
            XCTAssertEqual(order.count, 3)
            XCTAssertEqual(m.shownPanes.count, 3, "every pane tiled")
            XCTAssertEqual(m.selection, api)
            XCTAssertEqual(m.inViewRows, [web, db])
            m.focusPane(try XCTUnwrap(order.dropFirst().first))
            XCTAssertEqual(m.selection, web)
            XCTAssertEqual(m.inViewRows, [api, db], "the focused pane's session has the selection, no glyph")
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertEqual(m.inViewRows, [], "zoomed: the other panes are hidden, so not shown")
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertEqual(m.inViewRows, [api, db], "unzoomed: back")
            m.paneArea = CGRect(x: 0, y: 0, width: 400, height: 300)
            XCTAssertEqual(m.inViewRows, [], "too small: the focused pane alone is shown")
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            m.adopt(paneLayout([paneTarget("api"), paneTarget("api")]))
            XCTAssertEqual(m.inViewRows, [], "the focused pane's session never gets the glyph, also shown twice")
        }
        try withTreeGate(false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            XCTAssertEqual(m.inViewRows, [], "gate off: none")
        }
    }

    /// A row part's frames in the row ("title", "slot", "glyph"), hosted in a never-shown window at `width`.
    @MainActor
    func inViewRowFrames(_ row: AgentSidebar.Row, inView: Bool, selected: Bool = false, width: CGFloat) -> [String: CGRect] {
        let box = PaneProbeBox()
        AgentSidebarRowView.probe = { kind, _, r in box.seen[kind] = r }
        defer { AgentSidebarRowView.probe = nil }
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 200), styleMask: [.borderless],
                           backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AgentSidebarRowView(row: row, selected: selected, inView: inView).frame(width: width))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        win.contentView = host
        settle(host)
        XCTAssertFalse(win.isVisible, "never on screen")
        win.contentView = nil
        win.close()
        return box.seen
    }

    /// 7.2 (#828 slot rule): gate on, the slot is laid out with and without the glyph at the same frame and the title
    /// never moves (scales 0.7, 0.85, 1.0, a title long enough to truncate); the row's height is the same. Gate off: no
    /// slot at all; the title starts where the parent's did (padding, state glyph, spacing) and gets the slot's room
    /// back; the row is the same with or without `inView`.
    @MainActor
    func testInViewSlotIsFixedWithTheGateOnAndAbsentWithItOff() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let long = AgentSidebar.row(session("api-" + String(repeating: "w", count: 60), .idle), details: .all, now: Self.now)
        for scale in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let width = (AgentWindowModel.fullSidebarWidth - sz(16))
            var on: [String: CGRect] = [:], onGlyph: [String: CGRect] = [:], off: [String: CGRect] = [:]
            var offGlyph: [String: CGRect] = [:]
            var heights: [CGFloat] = []
            withTreeGate(true) {
                on = inViewRowFrames(long, inView: false, width: width)
                onGlyph = inViewRowFrames(long, inView: true, width: width)
                heights.append(NSHostingView(rootView: AgentSidebarRowView(row: long, selected: false, inView: false)
                    .frame(width: width)).fittingSize.height)
                heights.append(NSHostingView(rootView: AgentSidebarRowView(row: long, selected: false, inView: true)
                    .frame(width: width)).fittingSize.height)
            }
            withTreeGate(false) {
                off = inViewRowFrames(long, inView: false, width: width)
                offGlyph = inViewRowFrames(long, inView: true, width: width)
                heights.append(NSHostingView(rootView: AgentSidebarRowView(row: long, selected: false)
                    .frame(width: width)).fittingSize.height)
            }
            XCTAssertTrue(on["glyph"] == nil && onGlyph["slot"] == nil, "one slot kind per row (\(scale))")
            assertSame(on["slot"], onGlyph["glyph"], "the slot's frame with and without the glyph (\(scale))")
            XCTAssertEqual(on["slot"]?.width ?? 0, sz(14), accuracy: pixel, "a fixed-width slot (\(scale))")
            assertSame(on["title"], onGlyph["title"], "the title does not move (\(scale))")
            XCTAssertTrue(off["slot"] == nil && off["glyph"] == nil && offGlyph["slot"] == nil && offGlyph["glyph"] == nil,
                          "gate off: no slot (\(scale))")
            assertSame(off["title"], offGlyph["title"], "gate off: inView changes nothing (\(scale))")
            let t = try XCTUnwrap(off["title"])
            XCTAssertEqual(t.minX, sz(10) + sz(14) + sz(8), accuracy: pixel, "gate off: the title starts as before (\(scale))")
            XCTAssertGreaterThan(t.maxX, (on["title"]?.maxX ?? .infinity) + 1, "gate off: no width taken (\(scale))")
            XCTAssertEqual(heights.count, 3)
            for h in heights { XCTAssertEqual(h, heights.first ?? 0, accuracy: pixel, "one row height (\(scale))") }
        }
    }

    /// 7.2: the glyph is folded into the row's one accessibility label as "in view" (after "pinned", where the row's
    /// marks go); an empty slot is not read; gate off: never.
    @MainActor
    func testInViewIsReadInTheRowsLabel() {
        let rows = [AgentSidebar.row(session("api", .idle), details: .all, now: Self.now),
                    AgentSidebar.row(session("web", .idle), details: .all, now: Self.now)]
        @MainActor func labels() -> [String] {
            let tree = AXTreeSupport.tree(VStack(spacing: 0) {
                ForEach(rows) { r in AgentSidebarRowView(row: r, selected: false, inView: r.title == "web") }
            }, CGSize(width: 300, height: 200)) { t in t.filter { $0.label.hasPrefix("api") || $0.label.hasPrefix("web") }.count >= 2 }
            return tree.map(\.label).filter { $0.hasPrefix("api") || $0.hasPrefix("web") }
        }
        withTreeGate(true) {
            let l = labels()
            XCTAssertEqual(l.count, 2)
            XCTAssertTrue(l.contains { $0.hasPrefix("web, in view") }, "\(l)")
            XCTAssertFalse(l.contains { $0.hasPrefix("api") && $0.contains("in view") }, "\(l)")
        }
        withTreeGate(false) {
            let l = labels()
            XCTAssertEqual(l.count, 2)
            XCTAssertFalse(l.contains { $0.contains("in view") }, "gate off: \(l)")
        }
    }

    /// 7.2 through the window's own sidebar: gate on with A | B, the focused pane's row (the selection) has the empty
    /// slot and the other's the glyph; gate off with the same layout: no slot in any row. The whole root view is drawn,
    /// so the rows come through AgentSidebarView's own call site (`inView: inView.contains(row.id)`). The model is made
    /// visible first: a hidden model never builds its sections (refresh() returns early), and the sidebar then draws
    /// the no-sessions state instead of the list. The lazy list is laid out until both rows report, with a ceiling.
    @MainActor
    func testInViewSidebarDrawsTheGlyphOnTheOtherPanesRow() {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        defer { ThemeRuntime.scale = saved; restoreModes() }
        ThemeRuntime.scale = 1.0
        @MainActor func drawn(_ on: Bool) -> [String: CGRect] {
            var seen: [String: CGRect] = [:]
            withTreeGate(on) {
                let m = windowModel(store([session("api", .idle), session("web", .idle)]))
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
                let size = CGSize(width: 1600, height: 900)
                m.paneArea = zoomViewArea(size)   // the view feeds it too; set first so the first pass draws the tiling
                m.setVisible(true)
                XCTAssertEqual(m.selection, .live(paneKey("api")))
                XCTAssertEqual(m.sections.flatMap(\.rows).map(\.title).sorted(), ["api", "web"], "the sidebar's rows (gate \(on))")
                XCTAssertTrue(m.sidebarShown, "the sidebar is drawn (gate \(on))")
                let box = PaneProbeBox()
                AgentSidebarRowView.probe = { kind, title, r in box.seen["\(kind) \(title)"] = r }
                defer { AgentSidebarRowView.probe = nil }
                let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                   backing: .buffered, defer: true)
                win.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
                host.frame = CGRect(origin: .zero, size: size)
                win.contentView = host
                defer { win.contentView = nil; win.close() }
                let deadline = Date().addingTimeInterval(5)   // until both rows report, bounded
                repeat { settle(host) } while (["title api", "title web"] + (on ? ["glyph web", "slot api"] : [])).contains(where: { box.seen[$0] == nil }) && Date() < deadline
                XCTAssertFalse(win.isVisible, "never on screen")
                seen = box.seen
                XCTAssertTrue(seen["title api"] != nil && seen["title web"] != nil, "both rows drawn: \(seen.keys.sorted())")
            }
            return seen
        }
        let on = drawn(true)
        XCTAssertTrue(on["slot api"] != nil && on["glyph api"] == nil, "the selection's row: an empty slot")
        XCTAssertTrue(on["glyph web"] != nil && on["slot web"] == nil, "the other pane's row: the glyph")
        let off = drawn(false)
        XCTAssertTrue(off.keys.allSatisfy { !$0.hasPrefix("slot") && !$0.hasPrefix("glyph") }, "gate off: \(off.keys.sorted())")
    }

    /// 7.2 / 7.4: a zoom toggle (the focused pane, so the selection, unchanged) publishes a change of the model, so the
    /// sidebar, which reads `inViewRows` under its observer, redraws: zoomed none is in view; unzoomed the other is back.
    @MainActor
    func testInViewZoomTogglePublishesAndEmptiesTheRowsWhileZoomed() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            let web = AgentSidebar.RowID.live(paneKey("web"))
            XCTAssertEqual(m.inViewRows, [web])
            var sends = 0
            let sink = m.objectWillChange.sink { _ in sends += 1 }
            defer { sink.cancel() }
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertTrue(try XCTUnwrap(m.layout.zoomed) == m.layout.focused)
            XCTAssertGreaterThan(sends, 0, "a zoom publishes")
            XCTAssertEqual(m.inViewRows, [], "zoomed: none in view")
            let zoomSends = sends
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertTrue(m.layout.zoomed == nil)
            XCTAssertGreaterThan(sends, zoomSends, "an unzoom publishes")
            XCTAssertEqual(m.inViewRows, [web], "unzoomed: back")
        }
    }

    /// 7.2: an EQUAL layout adopted (gate on, A | B) publishes nothing: the layout's publish is on a change of value only.
    @MainActor
    func testInViewEqualLayoutPublishesNothing() {
        withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            m.paneArea = CGRect(x: 0, y: 0, width: 3000, height: 1000)
            var sends = 0
            let sink = m.objectWillChange.sink { _ in sends += 1 }
            defer { sink.cancel() }
            let same = m.layout
            m.adopt(same)
            XCTAssertEqual(m.layout, same)
            XCTAssertEqual(sends, 0, "an equal layout publishes nothing")
        }
    }

    /// 15.0: with the gate off the layout's publish adds nothing. Counts by reading the step 4b model: a manual pick of
    /// another session publishes 5 times (newSession nil; then settle(): selection, confirming, refusal, renameEdit),
    /// each sidebar toggle once (sidebarHidden). Gate off a person reaches the pick; the toggle only through the model.
    @MainActor
    func testInViewGateOffPickAndSidebarTogglePublishAsBefore() {
        withSidebarRow(gate: false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api")]))
            XCTAssertEqual(m.selection, .live(paneKey("api")))
            var sends = 0
            let sink = m.objectWillChange.sink { _ in sends += 1 }
            defer { sink.cancel() }
            m.select(.live(paneKey("web")))
            XCTAssertEqual(m.selection, .live(paneKey("web")))
            XCTAssertEqual(sends, 5, "a pick: as on the base")
            m.toggleSidebar()
            XCTAssertEqual(sends, 6, "a toggle: once")
            m.toggleSidebar()
            XCTAssertEqual(sends, 7, "and back: once")
        }
    }

    /// R900-4b-4 (15.0): with the gate off, a layout change of value that KEEPS the row publishes nothing, as on the parent
    /// of a3d3d01a (its didSet sent nothing of its own; settle() publishes on a change of row or of focusedEnded only,
    /// and here neither changes). The model, not a person: one pane with another pane id over the same target, the same
    /// layout id. Gate on, the same adopt publishes once (round 2b), so the count can see a publish.
    @MainActor
    func testInViewGateOffLayoutChangeThatKeepsTheRowPublishesNothing() {
        for on in [false, true] {
            withTreeGate(on) {
                let m = windowModel(store([session("api", .idle), session("web", .idle)]))
                defer { m.close() }
                m.adopt(paneLayout([paneTarget("api")]))
                XCTAssertEqual(m.selection, .live(paneKey("api")))
                var sends = 0
                let sink = m.objectWillChange.sink { _ in sends += 1 }
                defer { sink.cancel() }
                let other = PaneLayout.single(paneTarget("api"), id: m.layout.id)
                XCTAssertNotEqual(other, m.layout, "another pane id: another value")
                m.adopt(other)
                XCTAssertEqual(m.layout, other)
                XCTAssertEqual(m.selection, .live(paneKey("api")), "the row kept (gate \(on))")
                XCTAssertEqual(sends, on ? 1 : 0, on ? "gate on: once (round 2b)" : "gate off: nothing, as on the parent")
            }
        }
    }
}
