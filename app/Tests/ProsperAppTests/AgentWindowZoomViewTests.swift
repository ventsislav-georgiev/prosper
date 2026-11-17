import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 3; spec 3.4, 7.4, 9.1, 14.2 R1.1 / R2.1; R1196-a; N900-b): zoom and too small DRAWN by the view.
/// Offscreen only: every view is hosted in a window that is never ordered in; no event is built for a window or posted
/// (the hit test is the window's decision function called with literal points); the accessibility flags go on this
/// process only (bandAXOn, put back in a defer). The split gate and the UI scale are saved, set and restored in a defer
/// (withTreeGate); the Transcript-mode list too (transcriptMode). Sessions are the fakes the pane rows use. Every
/// closure here runs on the main actor (the rows are @MainActor; SwiftUI calls the probes from layout).
/// Filter: 'AgentWindowD1Tests/testZoomView' (an extension of the class the pane area rows live in).
extension AgentWindowD1Tests {
    /// The wide window of these rows and its pane area under the band at the current scale (gate on).
    @MainActor
    func zoomViewArea(_ size: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: size.width - AgentWindowModel.fullSidebarWidth - 1, height: size.height - AgentWindowBand.height)
    }

    /// The panes drawn in a snapshot: its "pane <i>" keys.
    func zoomViewPanes(_ s: [String: CGRect]) -> [String] {
        s.keys.filter { $0.hasPrefix("pane ") }.sorted()
    }

    /// R1.1 (7.4): with 2, 3 and 6 panes built by the model's own actions (perform: split, focus), every frame the view
    /// draws (pane, header, composer, mark) is the same before a zoom and after the unzoom; during the zoom exactly one
    /// pane is drawn, at the whole pane area, with no border or dim, and the model's tiling is untouched.
    @MainActor
    func testZoomViewFramesComeBackAfterUnzoomWith2And3And6Panes() throws {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api"])
        defer { ThemeRuntime.scale = saved; restoreModes() }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(paneKey("api")))
            let size = CGSize(width: 1600, height: 900), area = zoomViewArea(size)
            m.paneArea = area
            // 2: A | B. 3: B over C. 6: C over D, then A over E, E over F (each at least 300 x 200 in 1309 x 870).
            let steps: [(count: Int, actions: [PaneAction])] = [
                (2, [.split(.columns)]),
                (3, [.split(.rows)]),
                (6, [.split(.rows), .focus(.left), .split(.rows), .split(.rows)]),
            ]
            for step in steps {
                for a in step.actions { XCTAssertTrue(m.perform(a), "\(a) acted (\(step.count))") }
                XCTAssertEqual(m.layout.panes.count, step.count)
                XCTAssertTrue(m.paneRefusal == nil, "no refusal (\(step.count))")
                let tiling = m.paneFrames(in: area)
                XCTAssertEqual(tiling.count, step.count, "tiled, not too small (\(step.count))")
                let before = paneSnapshot(m, size)
                XCTAssertEqual(zoomViewPanes(before).count, step.count, "every pane drawn (\(step.count))")
                for (i, id) in m.layout.order.enumerated() {
                    assertSame(before["pane \(i)"], tiling[id], "pane \(i) at its tile (\(step.count))")
                }

                XCTAssertTrue(m.perform(.zoom))
                let z = try XCTUnwrap(m.layout.zoomed), zi = try XCTUnwrap(m.layout.order.firstIndex(of: z))
                XCTAssertEqual(z, m.layout.focused)
                XCTAssertEqual(m.paneFrames(in: area), tiling, "the model's tiling is untouched by the zoom (\(step.count))")
                XCTAssertEqual(AgentPaneArea.drawn(m, in: area), [z: area], "the zoomed pane over the area (\(step.count))")
                let during = paneSnapshot(m, size)
                XCTAssertEqual(zoomViewPanes(during), ["pane \(zi)"], "exactly one pane drawn (\(step.count))")
                assertSame(during["pane \(zi)"], area, "at the whole pane area (\(step.count))")
                XCTAssertTrue(during.keys.allSatisfy { !$0.hasPrefix("mark") }, "one pane drawn: no border, no dim (\(step.count))")

                XCTAssertTrue(m.perform(.zoom))
                XCTAssertTrue(m.layout.zoomed == nil)
                let after = paneSnapshot(m, size)
                XCTAssertEqual(Set(after.keys), Set(before.keys), "the same parts after the unzoom (\(step.count))")
                for k in before.keys { assertSame(after[k], before[k], "\(k) after the unzoom (\(step.count))") }
            }
        }
    }

    /// R2.1 (7.4, 3.4, 9.1): the chip's words, typed here, for 2 of 3, after a zoom move (⌘]) and for too small; at 0.7,
    /// 0.85 and 1.0 the chip slot (and every other band slot) has the same frame with and without the chip, in the wide
    /// window and in a narrower one where three columns are too small (the slot is the band's leading part, so the
    /// band's width does not move it).
    @MainActor
    func testZoomViewChipReadsZoomedIOfNAndTooSmallInItsFixedSlot() throws {
        let saved = ThemeRuntime.scale
        let names = ["api", "web", "db"]
        let restoreModes = transcriptMode(names)
        defer { ThemeRuntime.scale = saved; restoreModes() }
        try withTreeGate(true) {
            for scale: CGFloat in [0.7, 0.85, 1.0] {
                ThemeRuntime.scale = scale
                let m = windowModel(store(names.map { session($0, .idle) }))
                m.setVisible(true)
                defer { m.close() }
                m.adopt(paneLayout(names.map { paneTarget($0) }))
                let wide = CGSize(width: 1600, height: 900), area = zoomViewArea(wide)
                XCTAssertEqual(m.paneFrames(in: area).count, 3, "tiled in the wide window (\(scale))")
                XCTAssertTrue(AgentWindowBand.chip(m, in: area) == nil, "no chip (\(scale))")
                let base = bandSnapshot(m, wide)
                XCTAssertNotNil(base["chip"], "the wide band has the chip slot (\(scale))")
                func same(_ s: [String: CGRect], _ keys: [String], _ why: String) {
                    for k in keys { assertSame(s[k], base[k], "\(k): \(why) (\(scale))") }
                }
                let slots = ["band", "layout", "chip", "all", "picker"]

                m.adopt(try m.layout.focus(try XCTUnwrap(m.layout.order.dropFirst().first)).get())
                XCTAssertTrue(m.perform(.zoom))
                XCTAssertEqual(AgentWindowBand.chip(m, in: area), "Zoomed · 2 of 3")
                same(bandSnapshot(m, wide), slots, "zoomed 2 of 3")

                XCTAssertTrue(m.perform(.cycle(1)))   // ⌘] while zoomed: the zoom moves (7.4)
                XCTAssertEqual(m.layout.zoomed, m.layout.order.last)
                XCTAssertEqual(AgentWindowBand.chip(m, in: area), "Zoomed · 3 of 3")
                same(bandSnapshot(m, wide), slots, "the zoom moved")

                XCTAssertTrue(m.perform(.zoom))
                XCTAssertTrue(AgentWindowBand.chip(m, in: area) == nil, "unzoomed: no chip (\(scale))")
                same(bandSnapshot(m, wide), slots, "unzoomed")

                // Too small: three columns of a pane area 880·s wide are under 300·s each.
                let narrow = CGSize(width: AgentWindowModel.fullSidebarWidth + 1 + sz(880), height: sz(700)), small = zoomViewArea(narrow)
                XCTAssertEqual(m.paneFrames(in: small).count, 1, "too small (\(scale))")
                XCTAssertEqual(AgentWindowBand.chip(m, in: small), "2 panes hidden, window too small")
                same(bandSnapshot(m, narrow), ["layout", "chip"], "too small, a narrower band")
            }
            // One hidden pane: the singular.
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            XCTAssertEqual(AgentWindowBand.chip(m, in: CGRect(x: 0, y: 0, width: 400, height: 400)),
                           "1 pane hidden, window too small")
        }
    }

    /// 9.1 / 13: the chip is words an accessibility client reads, once, in the band's row: zoomed and too small. The
    /// tree is the real one of the root view in a never-shown window (bandTree), the flags on this process only.
    @MainActor
    func testZoomViewChipIsReadByAccessibilityInTheBand() throws {
        let names = ["api", "web", "db"]
        let restoreModes = transcriptMode(names), restoreAX = bandAXOn()
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved; restoreAX(); restoreModes() }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store(names.map { session($0, .idle) }))
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout(names.map { paneTarget($0) }))
            m.adopt(try m.layout.focus(try XCTUnwrap(m.layout.order.dropFirst().first)).get())
            XCTAssertTrue(m.perform(.zoom))
            for (words, size) in [("Zoomed · 2 of 3", CGSize(width: 1600, height: 900)),
                                  ("2 panes hidden, window too small", CGSize(width: AgentWindowModel.fullSidebarWidth + 1 + 880, height: 700))] {
                if words.hasPrefix("2 panes") { XCTAssertTrue(m.perform(.zoom), "unzoom for the too-small tree") }
                let (tree, screen) = bandTree(AgentWindowRootView(model: m, scrolls: false), size, until: [words])
                XCTAssertEqual(bandCount(tree, words), 1, "\"\(words)\" read once")
                let row = CGRect(x: screen.minX + AgentWindowModel.fullSidebarWidth + 1, y: screen.maxY - AgentWindowBand.height,
                                 width: size.width - AgentWindowModel.fullSidebarWidth - 1, height: AgentWindowBand.height)
                XCTAssertTrue(tree.contains { $0.names.contains(words) && row.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) },
                              "\"\(words)\" is in the band's row")
            }
        }
    }

    /// 7.4: zoomed, a down inside a hidden pane's TILED frame is the zoomed pane's: nothing is focused, the zoom stays,
    /// the panes take the keys and the click passes. Unzoomed, the same point focuses that pane (7.6, as before).
    @MainActor
    func testZoomViewHitTestWhileZoomedIsTheZoomedPanes() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let a = try XCTUnwrap(m.layout.order.first), b = try XCTUnwrap(m.layout.order.last)
            let size = CGSize(width: 1600, height: 900), area = zoomViewArea(size)
            let fb = try XCTUnwrap(m.paneFrames(in: area)[b])
            let p = CGPoint(x: AgentWindowModel.fullSidebarWidth + 1 + fb.midX, y: AgentWindowBand.height + fb.midY)
            XCTAssertEqual(AgentsNSWindow.firstClick(at: CGPoint(x: fb.midX, y: fb.midY), frames: m.paneFrames(in: area), focused: a), b,
                           "the point is in b's tile")
            XCTAssertTrue(m.perform(.zoom))
            let zoomed = m.layout
            m.keyFocus = .sidebar
            XCTAssertFalse(AgentsNSWindow.mouseDown(m, at: p, in: size), "the zoomed pane's: the click passes")
            XCTAssertEqual(m.layout, zoomed, "no pane focused, the zoom stays on a")
            XCTAssertEqual(m.layout.zoomed, a)
            XCTAssertEqual(m.keyFocus, .pane, "the panes take the keys")

            XCTAssertTrue(m.perform(.zoom))
            XCTAssertTrue(AgentsNSWindow.mouseDown(m, at: p, in: size), "unzoomed: the first click only focuses b")
            XCTAssertEqual(m.layout.focused, b)
        }
    }

    /// R1196-a: the focused pane's content keeps its identity across 1, 2, 1 panes and a zoom: the composer's text view
    /// (made by AgentComposerField.makeNSView) is the same object throughout, so nothing in the pane was remade.
    @MainActor
    func testZoomViewPaneKeepsItsIdentityAcrossOneTwoOne() throws {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        defer { ThemeRuntime.scale = saved; restoreModes() }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(paneKey("api")))
            let size = CGSize(width: 1600, height: 900), area = zoomViewArea(size)
            let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            defer { win.contentView = nil; win.close() }
            let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
            host.frame = CGRect(origin: .zero, size: size)
            win.contentView = host
            settle(host)
            @MainActor func composer(_ why: String) throws -> AgentComposerTextView {
                let fields = focusViews(host, AgentComposerTextView.self)
                XCTAssertEqual(fields.count, 1, "one composer: the focused pane's (\(why))")
                return try XCTUnwrap(fields.first, why)
            }
            let first = try composer("one pane")
            let a = m.layout.focused
            var two = try m.layout.split(axis: .columns, target: paneTarget("web"), minimum: m.paneMinimum, in: area).get()
            two = try two.focus(a).get()   // a second pane comes; a keeps the focus
            m.adopt(two)
            settle(host)
            XCTAssertEqual(m.layout.panes.count, 2)
            XCTAssertTrue(try composer("two panes") === first, "a second pane came: a's content was not remade")
            XCTAssertTrue(m.perform(.zoom))
            settle(host)
            XCTAssertTrue(try composer("zoomed") === first, "zoomed: not remade")
            XCTAssertTrue(m.perform(.zoom))
            settle(host)
            XCTAssertTrue(try composer("unzoomed") === first, "unzoomed: not remade")
            let other = try XCTUnwrap(m.layout.order.first { $0 != a })
            m.adopt(try m.layout.close(other).get())
            settle(host)
            XCTAssertEqual(m.layout.panes.count, 1)
            XCTAssertTrue(try composer("one pane again") === first, "the second pane went: a's content was not remade")
            XCTAssertFalse(win.isVisible)
        }
    }

    /// R1196-a's two infos, settled as the 7.6 rule (decisions in the report): the window's first-click machine reads the
    /// event TYPE only, so a control-click's left down on an unfocused pane only focuses (swallowed with its up, no
    /// menu); a double-click's second down comes after a swallowed up and passes, with its own clickCount, to the pane the
    /// first one focused.
    @MainActor
    func testZoomViewFirstClickInfosAreSettled() {
        var c = AgentsNSWindow.FocusClick()
        XCTAssertTrue(c.take(.leftMouseDown, focusing: true), "the first down (control held or not) only focuses")
        XCTAssertTrue(c.take(.leftMouseUp, focusing: false), "its up is swallowed with it")
        XCTAssertFalse(c.take(.leftMouseDown, focusing: false), "the second down (on the now-focused pane) passes")
        XCTAssertFalse(c.take(.leftMouseUp, focusing: false))
        XCTAssertFalse(c.take(.rightMouseDown, focusing: true), "a right-click is never taken")
    }

    /// N900-b (QA 991): a split while zoomed is measured against the UNZOOMED tiling (the layout unzooms first). At
    /// 1000·s the zoomed pane is drawn 1000 wide (room for two 300·s halves) but its tile is 500: the split is refused and
    /// the zoom stays. At 1400: the result is the tiling with one more pane, not zoomed, drawn tiled with no chip.
    @MainActor
    func testZoomViewASplitWhileZoomedIsMeasuredAgainstTheTiling() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withTreeGate(true) {
            let m = windowModel(store([session("api", .idle)]))
            defer { m.close() }
            m.select(.live(paneKey("api")))
            let narrow = CGRect(x: 0, y: 0, width: 1000, height: 800)
            m.paneArea = narrow
            XCTAssertTrue(m.perform(.split(.columns)))
            XCTAssertTrue(m.perform(.zoom))
            let zoomed = m.layout
            XCTAssertEqual(AgentPaneArea.drawn(m, in: narrow), [zoomed.focused: narrow], "drawn 1000 wide")
            XCTAssertTrue(m.perform(.split(.columns)), "acted: the refusal is shown")
            XCTAssertTrue(m.paneRefusal == .noRoom, "measured against the 500 wide tile, not the drawn 1000")
            XCTAssertEqual(m.layout, zoomed, "refused: the layout and its zoom stay")

            let wide = CGRect(x: 0, y: 0, width: 1400, height: 800)
            m.paneArea = wide
            XCTAssertTrue(m.perform(.split(.columns)))
            XCTAssertEqual(m.layout.panes.count, 3)
            XCTAssertTrue(m.layout.zoomed == nil, "the split unzoomed first")
            let tiling = m.paneFrames(in: wide)
            XCTAssertEqual(tiling.count, 3)
            XCTAssertEqual(AgentPaneArea.drawn(m, in: wide), tiling, "drawn as the tiling with one more pane")
            XCTAssertTrue(AgentWindowBand.chip(m, in: wide) == nil, "no chip")
        }
    }

    /// 15.0, gate off: nothing a person sees changes. A decoded zoomed two-pane layout draws its focused pane alone at the
    /// whole column (no band: the area is the full height), the full header, no border or dim; no band part is laid out;
    /// no chip (zoomed or too small); the drawn frames are the model's; a down in the right half passes as before.
    @MainActor
    func testZoomViewGateOffDrawsAndBandsAsBefore() throws {
        let saved = ThemeRuntime.scale
        let restoreModes = transcriptMode(["api", "web"])
        defer { ThemeRuntime.scale = saved; restoreModes() }
        ThemeRuntime.scale = 1.0
        try withTreeGate(false) {
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            m.adopt(m.layout.toggleZoom())   // a zoomed blob, inert with the gate off
            XCTAssertEqual(m.layout.zoomed, m.layout.focused)
            let size = CGSize(width: 1600, height: 900)
            let area = CGRect(x: 0, y: 0, width: size.width - AgentWindowModel.fullSidebarWidth - 1, height: size.height)
            let s = paneSnapshot(m, size)
            XCTAssertEqual(zoomViewPanes(s), ["pane 0"], "the focused pane alone")
            assertSame(s["pane 0"], area, "at the whole column, no band")
            XCTAssertGreaterThan(s["header 0"]?.height ?? 0, AgentCompactHeader.height + 1, "the full header")
            XCTAssertTrue(s.keys.allSatisfy { !$0.hasPrefix("mark") }, "no border, no dim")
            XCTAssertTrue(bandSnapshot(m, size).isEmpty, "no band")
            XCTAssertEqual(AgentPaneArea.drawn(m, in: area), m.paneFrames(in: area))
            XCTAssertTrue(AgentWindowBand.chip(m, in: area) == nil, "no zoom chip")
            XCTAssertTrue(AgentWindowBand.chip(m, in: CGRect(x: 0, y: 0, width: 300, height: 300)) == nil, "no too-small chip")
            let before = m.layout
            m.keyFocus = .sidebar
            XCTAssertFalse(AgentsNSWindow.mouseDown(m, at: CGPoint(x: size.width - 50, y: 450), in: size))
            XCTAssertEqual(m.layout, before)
            XCTAssertEqual(m.keyFocus, .pane, "a pane click takes the keys, as before")
        }
    }
}
