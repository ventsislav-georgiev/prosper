import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1360 (operator 2026-11-16, "make the agents number a bit more outlined"): on a sidebar row the subagents count wears
/// a capsule outline (stroke, no fill) and the PR counts do not. Offscreen only: rows hosted in never-shown windows or
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
    /// inside the group's width, so the ladder counts it), on line two, drawn whole (its stroke lit at both ends); the
    /// row's height is its own with no agents, and TIP's literal 31 / 39 / 45 on TIP's idle Claude row with the count; the
    /// row's VoiceOver label is TIP's text. 5 agents keep the open count at every scale (the operator's row); for 128 the
    /// step shown prints as ROW1360-LADDER.
    @MainActor
    func testAgentsCountOutlineOnTheLadderAtFiveAnd128() {
        let tip: [CGFloat: CGFloat] = [0.7: 31, 0.85: 39, 1.0: 45]
        func height(_ r: AgentSidebar.Row) -> CGFloat {
            NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false, number: 1).frame(width: sz(274))).fittingSize.height
        }
        atScales { scale in
            for n in [5, 128] {
                let r = outlined1360(agents: n)
                let v = AgentSidebarRowView(row: r, selected: false)
                let alone = ideal(AgentCountGroups(counts: [(.agents, n)], size: 10.5, outline: .white)).width
                for px: CGFloat in [1, 2] {
                    let tag = "\(n) agents (\(scale), \(Int(px))x)"
                    let h = hosted1345(r, number: 1, width: sz(274), backing: px)
                    let capsules = h.frames.keys.filter { $0.hasPrefix("capsule.") }.sorted()
                    print("ROW1360-LADDER \(tag) line \(column(sz(274))) count \(ideal(v.detailLine([], open: r.prCount)).width)"
                          + " none \(ideal(v.detailLine([])).width) capsuleAlone \(alone) shown \(h.frames["count.open"] == nil ? "none" : "count")"
                          + " \(h.frames.filter { $0.key.hasPrefix("c") }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })")
                    XCTAssertEqual(capsules, ["capsule.agents"], "the agents group alone is outlined: \(tag)")
                    // Ticket 1 read this Working row at 36 / 42 / 46 (not TIP's idle-row literals), so the literal is read on
                    // TIP's own idle Claude row below; here the height is the same row's with no agents (no capsule).
                    var bare = r
                    bare.agents = 0
                    XCTAssertEqual(h.height, height(bare), accuracy: 0.01, "the row's height, as with no agents: \(tag)")
                    guard let c = h.frames["capsule.agents"], let g = h.frames["count.agents"], let t = h.frames["title"],
                          let m = h.frames["count.merged"], let rep = h.rep else {
                        XCTFail("probed and drawn: \(h.frames.keys.sorted()) \(tag)"); continue
                    }
                    XCTAssertEqual(c.width, g.width, accuracy: 0.5, "the capsule is the group's frame: \(c) \(g) \(tag)")
                    XCTAssertEqual(c.width, alone, accuracy: 1, "the capsule whole, not cut: \(c) vs \(alone) \(tag)")
                    XCTAssertGreaterThan(c.minY, t.maxY - 1, "on line two: \(c) under \(t) \(tag)")
                    XCTAssertLessThanOrEqual(c.maxX, m.minX, "before the merged group: \(c) \(m) \(tag)")
                    let k = CGFloat(rep.pixelsWide) / sz(274).rounded(.up)
                    for (end, x) in [("left", c.minX), ("right", c.maxX - 1.5)] {
                        let strip = CGRect(x: x, y: c.midY - 1, width: 1.5, height: 2)
                        XCTAssertTrue(ink1345(rep, k: k, in: strip) != nil, "the stroke drawn at the \(end) end: \(strip) \(tag)")
                    }
                    if n == 5 { XCTAssertTrue(h.frames["count.open"] != nil, "5 agents keep the open count: \(tag)") }
                }
                // TIP's literal heights (testRowHeightIsTipsAtEveryScale's idle Claude row) with the outlined count on it.
                var claude = row(session("api", model: "claude-fable-9-2-20991231", effort: "high"))
                claude.agents = n
                claude.merged = 199
                XCTAssertEqual(height(claude), tip[scale] ?? -1, accuracy: 0.01, "TIP's height with \(n) agents (\(scale))")
                // VoiceOver: the row's one label, literally TIP's (the capsule adds no element and no word).
                let tree = AXTreeSupport.tree(AgentSidebarRowView(row: r, selected: false).frame(width: sz(274)),
                                              CGSize(width: sz(274), height: sz(60))) { t in t.contains { $0.label.hasPrefix("sec-1") } }
                XCTAssertEqual(tree.first(where: { $0.label.hasPrefix("sec-1") })?.label,
                               "sec-1, Working, \(n) agents, 199 merged pull requests, 7 open pull requests", "the row's words (\(scale))")
            }
        }
    }
}

extension AgentRowSelectedTextTests {
    /// The outline's ink against the row on every theme, unselected (the sidebar) and selected (the accent at 0.14 over
    /// it): at least 3:1 (non-text contrast); and on an unselected row stronger than the quiet ink of the counts beside it
    /// (the quiet ink itself would not stand out). The number keeps its ink (AgentRowSelectedTextTests' count group row).
    func testAgentsCountOutlineContrastOnEveryTheme() throws {
        var pairs = 0
        try onEveryTheme { d, p in
            for selected in [false, true] {
                let bg = selected ? over(rgba(p.sidebar), p.blue, 0.14) : rgba(p.sidebar)
                let row = ns((bg.r, bg.g, bg.b, 1))
                let stroke = ThemeContrastTests.contrast(NSColor(AgentSidebarRowView.outlineInk(selected: selected)), on: row)
                let number = ThemeContrastTests.contrast(NSColor(AgentSidebarRowView.ink(.quiet, selected: selected)), on: row)
                let tag = "\(d.title) selected \(selected): outline \(stroke):1, number \(number):1"
                XCTAssertGreaterThanOrEqual(stroke, 3, tag)
                if selected { XCTAssertGreaterThanOrEqual(stroke, number - 0.01, tag) } else { XCTAssertGreaterThan(stroke, number + 0.1, tag) }
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 22 * 2)
    }
}
