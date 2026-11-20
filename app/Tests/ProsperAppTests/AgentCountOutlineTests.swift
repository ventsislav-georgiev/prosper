import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1360 (operator 2026-11-16, "make the agents number a bit more outlined"), #1531 (operator 2026-11-18, "remove the
/// robot white border"), #1735 (operator 2026-11-20, "terminal can have white border, agent royal purple, remove the fog"): on a
/// sidebar row the agents count wears a purple outline and the shells count a white one (no fill), and the PR counts do not. Offscreen only: rows hosted in never-shown windows or
/// measured; no event, no file. Fakes only.
extension AgentRowModelEffortTests {
    /// The operator's row: Working, N agents, 199 merged, 7 open PRs whose chips never fit (long names).
    func outlined1360(agents: Int) -> AgentSidebar.Row {
        let long = String(repeating: "w", count: 40)
        return AgentSidebar.Row(id: .live(AgentSessionKey(dir: Self.dir, name: "api")), title: "sec-1", state: .working,
                                detail: "Working", age: "", prs: [long + "#1", long + "#2", "+5"], prCount: 7,
                                agents: agents, merged: 199)
    }

    /// At the sidebar's width (sz(274)), 0.7 / 0.85 / 1.0, 1x and 2x, for 5 and 128 agents, by the probes and pixels: the
    /// capsule is on the agents group alone (no capsule on the merged or open group), as wide as the group (its padding
    /// inside the group's width, so the ladder counts it), on line two, drawn whole (#1735: its edge pixel
    /// is the 1 pt purple stroke, its interior is the row behind it, no fill); the
    /// row's height is its own with no agents, and TIP's literal 31 / 39 / 45 on TIP's idle Claude row with the count; the
    /// row's VoiceOver label is TIP's text. 5 agents keep the open count at every scale (the operator's row); for 128 the
    /// step shown prints as ROW1360-LADDER.
    @MainActor
    func testAgentsCountOutlineOnTheLadderAtFiveAnd128() {
        let tip: [CGFloat: CGFloat] = [0.7: 31, 0.85: 39, 1.0: 45]
        func height(_ r: AgentSidebar.Row) -> CGFloat {
            NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false, number: 1).frame(width: (AgentWindowModel.fullSidebarWidth - sz(16)))).fittingSize.height
        }
        atScales { scale in
            for n in [5, 128] {
                let r = outlined1360(agents: n)
                let v = AgentSidebarRowView(row: r, selected: false)
                let alone = ideal(AgentCountGroups(counts: [(.agents, n)], size: 10.5, outlined: true)).width
                for px: CGFloat in [1, 2] {
                    let tag = "\(n) agents (\(scale), \(Int(px))x)"
                    let h = hosted1345(r, number: 1, width: (AgentWindowModel.fullSidebarWidth - sz(16)), backing: px)
                    let capsules = h.frames.keys.filter { $0.hasPrefix("capsule.") }.sorted()
                    print("ROW1360-LADDER \(tag) line \(column(sz(274))) count \(ideal(v.detailLine([], open: r.prCount)).width)"
                          + " none \(ideal(v.detailLine([])).width) capsuleAlone \(alone) shown \(h.frames["count.open"] == nil ? "none" : "count")"
                          + " \(h.frames.filter { $0.key.hasPrefix("c") }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })")
                    XCTAssertEqual(capsules, ["capsule.agents"], "the agents group alone is a pill: \(tag)")
                    // Ticket 1 read this Working row at 36 / 42 / 46 (not TIP's idle-row literals), so the literal is read on
                    // TIP's own idle Claude row below; here the height is the same row's with no agents (no capsule).
                    var bare = r
                    bare.agents = 0
                    XCTAssertEqual(h.height, height(bare), accuracy: 0.01, "the row's height, as with no agents: \(tag)")
                    guard let c = h.frames["capsule.agents"], let g = h.frames["count.agents"], let t = h.frames["title"],
                          let m = h.frames["count.merged"], let rep = h.rep else {
                        XCTFail("probed and drawn: \(h.frames.keys.sorted()) \(tag)"); continue
                    }
                    XCTAssertEqual(c.width, g.width, accuracy: 1 / px, "the capsule is the group's frame: \(c) \(g) \(tag)")
                    XCTAssertEqual(c.width, alone, accuracy: 1, "the capsule whole, not cut: \(c) vs \(alone) \(tag)")
                    XCTAssertGreaterThan(c.minY, t.maxY - 1, "on line two: \(c) under \(t) \(tag)")
                    XCTAssertLessThanOrEqual(c.maxX, m.minX, "before the merged group: \(c) \(m) \(tag)")
                    let k = CGFloat(rep.pixelsWide) / (AgentWindowModel.fullSidebarWidth - sz(16)).rounded(.up)
                    // #1735: the pixel at the capsule's left edge (mid height) is the stroke, brighter than the black row behind it; the
                    // interior (inside the padding, left of the glyph) is that black row: no fill.
                    func pix(_ x: CGFloat, _ y: CGFloat) -> [CGFloat] {
                        guard let col = rep.colorAt(x: Int(x * k), y: Int(y * k))?.usingColorSpace(.sRGB) else { return [] }
                        return [col.redComponent, col.greenComponent, col.blueComponent]
                    }
                    let edge = pix(c.minX + 0.5, c.midY), inside = pix(c.minX + sz(3), c.midY), outside = pix(c.minX - 2, c.midY)
                    XCTAssertTrue(edge.count == 3 && inside.count == 3 && outside.count == 3, "pixels read: \(tag)")
                    XCTAssertTrue(zip(inside, outside).allSatisfy { abs($0 - $1) <= 0.02 }, "no fill: the interior is the row behind it: \(inside) \(outside) \(tag)")
                    XCTAssertGreaterThan(zip(edge, inside).map { $0 - $1 }.reduce(0, +), 0.5, "the stroke is drawn at the edge: \(edge) over \(inside) \(tag)")
                    if n == 5 { XCTAssertTrue(h.frames["count.open"] != nil, "5 agents keep the open count: \(tag)") }
                }
                // TIP's literal heights (testRowHeightIsTipsAtEveryScale's idle Claude row) with the pill count on it.
                var claude = row(session("api", model: "claude-fable-9-2-20991231", effort: "high"))
                claude.agents = n
                claude.merged = 199
                XCTAssertEqual(height(claude), tip[scale] ?? -1, accuracy: 0.01, "TIP's height with \(n) agents (\(scale))")
                // VoiceOver: the row's one label, literally TIP's (the pill adds no element and no word).
                let tree = AXTreeSupport.tree(AgentSidebarRowView(row: r, selected: false).frame(width: (AgentWindowModel.fullSidebarWidth - sz(16))),
                                              CGSize(width: (AgentWindowModel.fullSidebarWidth - sz(16)), height: sz(60))) { t in t.contains { $0.label.hasPrefix("sec-1") } }
                XCTAssertEqual(tree.first(where: { $0.label.hasPrefix("sec-1") })?.label,
                               "sec-1, Working, \(n) agents, 199 merged pull requests, 7 open pull requests", "the row's words (\(scale))")
            }
        }
    }

    /// #1735: the agents stroke on the row is the royal purple (blue above green, red above green), with Increase Contrast on and off alike.
    @MainActor
    func testAgentsCountStrokeIsPurpleWithAndWithoutIncreaseContrast() {
        let saved = ThemeRuntime.increaseContrast
        defer { ThemeRuntime.increaseContrast = saved }
        let r = outlined1360(agents: 5)
        for hc in [true, false] {
            ThemeRuntime.increaseContrast = hc
            let w = AgentWindowModel.fullSidebarWidth - sz(16)
            let h = hosted1345(r, number: 1, width: w, backing: 2)
            guard let c = h.frames["capsule.agents"], let rep = h.rep,
                  let col = rep.colorAt(x: Int((c.minX + 0.5) * CGFloat(rep.pixelsWide) / w.rounded(.up)), y: Int(c.midY * CGFloat(rep.pixelsWide) / w.rounded(.up)))?.usingColorSpace(.sRGB)
            else { return XCTFail("probed and drawn") }
            XCTAssertTrue(col.blueComponent > col.greenComponent + 0.1 && col.redComponent > col.greenComponent, "purple edge (increase contrast \(hc)): \(col)")
        }
    }
}

extension AgentRowSelectedTextTests {
    /// #1735: the two strokes over the row on every theme, unselected (the sidebar) and selected (the accent at 0.14 over it): each
    /// clears 3:1 non-text contrast; the shells stroke is white where white clears 3:1 over the sidebar, else textPrimary; the agents
    /// stroke is one of the two purples (#9D7BEA, #7851A9).
    func testCountPillStrokesClearThreeToOneOnEveryTheme() throws {
        var pairs = 0
        try onEveryTheme { d, p in
            let side = rgba(p.sidebar)
            let white = ThemeRuntime.contrastRatio(.white, p.sidebar) >= 3
            XCTAssertTrue(rgba(AgentSidebarRowView.shellsStroke) == rgba(white ? .white : p.textPrimary), "\(d.title): shells stroke is white or textPrimary")
            XCTAssertTrue([AgentSidebarRowView.purpleLight, AgentSidebarRowView.purpleDark].contains { rgba($0) == rgba(AgentSidebarRowView.agentsStroke) }, "\(d.title): one royal purple")
            for selected in [false, true] {
                let bg = selected ? over(side, p.blue, 0.14) : side
                let row = Color(nsColor: ns((bg.r, bg.g, bg.b, 1)))
                for (name, stroke) in [("agents", AgentSidebarRowView.agentsStroke), ("shells", AgentSidebarRowView.shellsStroke)] {
                    let ratio = ThemeRuntime.contrastRatio(stroke, row)
                    XCTAssertGreaterThanOrEqual(ratio, 3, "\(d.title) selected \(selected): \(name) stroke over row \(ratio):1")
                    pairs += 1
                }
            }
        }
        XCTAssertEqual(pairs, 22 * 4)
    }
}
