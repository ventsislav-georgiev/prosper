import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1360 (operator 2026-11-16, "make the agents number a bit more outlined"), #1531 (operator 2026-11-18, "remove the
/// robot white border"), #1776 (operator 2026-11-20, "it should have been borderless and the icon itself to be purle and its
/// number, same way merges uses the colour of our theme"; replaces #1735's outline): on a sidebar row the agents count draws its
/// glyph and number in the royal purple and the shells count in white, with no stroke and no fill. Offscreen only: rows hosted in
/// never-shown windows or measured; no event, no file. Fakes only.
extension AgentRowModelEffortTests {
    /// The operator's row: Working, N agents, 199 merged, 7 open PRs whose chips never fit (long names).
    func outlined1360(agents: Int) -> AgentSidebar.Row {
        let long = String(repeating: "w", count: 40)
        return AgentSidebar.Row(id: .live(AgentSessionKey(dir: Self.dir, name: "api")), title: "sec-1", state: .working,
                                detail: "Working", age: "", prs: [long + "#1", long + "#2", "+5"], prCount: 7,
                                agents: agents, merged: 199)
    }

    /// At the sidebar's width (sz(274)), 0.7 / 0.85 / 1.0, 1x and 2x, for 5 and 128 agents, by the probes and pixels: the
    /// agents group is on line two, drawn whole (as wide as the group alone), before the merged group; #1776: its top and
    /// bottom pixel rows over the number are the row behind it (no stroke, no fill) and its brightest pixel is purple; the
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
                let alone = ideal(AgentCountGroups(counts: [(.agents, n)], size: 10.5, tinted: true)).width
                for px: CGFloat in [1, 2] {
                    let tag = "\(n) agents (\(scale), \(Int(px))x)"
                    let h = hosted1345(r, number: 1, width: (AgentWindowModel.fullSidebarWidth - sz(16)), backing: px)
                    print("ROW1360-LADDER \(tag) line \(column(sz(274))) count \(ideal(v.detailLine([], open: r.prCount)).width)"
                          + " none \(ideal(v.detailLine([])).width) groupAlone \(alone) shown \(h.frames["count.open"] == nil ? "none" : "count")"
                          + " \(h.frames.filter { $0.key.hasPrefix("c") }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })")
                    // Ticket 1 read this Working row at 36 / 42 / 46 (not TIP's idle-row literals), so the literal is read on
                    // TIP's own idle Claude row below; here the height is the same row's with no agents.
                    var bare = r
                    bare.agents = 0
                    XCTAssertEqual(h.height, height(bare), accuracy: 0.01, "the row's height, as with no agents: \(tag)")
                    guard let g = h.frames["count.agents"], let t = h.frames["title"],
                          let m = h.frames["count.merged"], let rep = h.rep else {
                        XCTFail("probed and drawn: \(h.frames.keys.sorted()) \(tag)"); continue
                    }
                    XCTAssertEqual(g.width, alone, accuracy: 1, "the group whole, not cut: \(g) vs \(alone) \(tag)")
                    XCTAssertGreaterThan(g.minY, t.maxY - 1, "on line two: \(g) under \(t) \(tag)")
                    XCTAssertLessThanOrEqual(g.maxX, m.minX, "before the merged group: \(g) \(m) \(tag)")
                    let k = CGFloat(rep.pixelsWide) / (AgentWindowModel.fullSidebarWidth - sz(16)).rounded(.up)
                    func pix(_ x: CGFloat, _ y: CGFloat) -> [CGFloat] {
                        guard let col = rep.colorAt(x: Int(x * k), y: Int(y * k))?.usingColorSpace(.sRGB) else { return [] }
                        return [col.redComponent, col.greenComponent, col.blueComponent]
                    }
                    // #1776: no stroke, no fill. The number's span (the group's right 30%: the digits, never the glyph) on the frame's top and
                    // bottom pixel rows (the digits' cap height leaves about 2 pt of line above and below them) is the black row behind it,
                    // as the gap left of the group is; #1735's capsule drew its 1 pt stroke along both rows, a fill covers them.
                    let outside = pix(g.minX - 2, g.midY)
                    let rows: [[CGFloat]] = stride(from: g.maxX - 0.3 * g.width, through: g.maxX - 1, by: 0.5).flatMap { x in
                        [g.minY + 0.5 / k, g.maxY - 0.5 / k].map { pix(x, $0) }
                    }
                    XCTAssertTrue(outside.count == 3 && !rows.isEmpty && rows.allSatisfy { $0.count == 3 }, "pixels read: \(tag)")
                    let brightestEdge = rows.max { $0.reduce(0, +) < $1.reduce(0, +) } ?? []
                    XCTAssertTrue(zip(brightestEdge, outside).allSatisfy { abs($0 - $1) <= 0.02 }, "no stroke, no fill: \(brightestEdge) vs \(outside) \(tag)")
                    // The glyph and the number are the purple: the brightest pixel inside the group (blue above green, red above green).
                    let inside: [[CGFloat]] = stride(from: g.minX, to: g.maxX, by: 0.5).flatMap { x in stride(from: g.minY, to: g.maxY, by: 0.5).map { (y: CGFloat) -> [CGFloat] in pix(x, y) } }
                    let ink = inside.max { $0.reduce(0, +) < $1.reduce(0, +) } ?? []
                    XCTAssertTrue(ink.count == 3 && ink[2] > ink[1] + 0.1 && ink[0] > ink[1], "the glyph and number are purple: \(ink) \(tag)")
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

    /// #1776: on the row the agents glyph and number are the royal purple (blue above green, red above green) and the shells
    /// glyph and number the shells ink (white on the default dark theme), never the quiet grey, with Increase Contrast on and off alike.
    @MainActor
    func testCountInksArePurpleAndWhiteWithAndWithoutIncreaseContrast() {
        let saved = ThemeRuntime.increaseContrast
        defer { ThemeRuntime.increaseContrast = saved }
        var r = outlined1360(agents: 5)
        r.shells = [DchShell(id: "1", pid: 1, started: 0, command: "make")]
        for hc in [true, false] {
            ThemeRuntime.increaseContrast = hc
            let w = AgentWindowModel.fullSidebarWidth - sz(16)
            let h = hosted1345(r, number: 1, width: w, backing: 2)
            guard let a = h.frames["count.agents"], let sh = h.frames["count.shells"], let rep = h.rep else {
                return XCTFail("probed and drawn: \(h.frames.keys.sorted())")
            }
            let k = CGFloat(rep.pixelsWide) / w.rounded(.up)
            func brightest(_ f: CGRect) -> [CGFloat] {
                var best: [CGFloat] = [], sum: CGFloat = -1
                for x in stride(from: f.minX, to: f.maxX, by: 0.5) {
                    for y in stride(from: f.minY, to: f.maxY, by: 0.5) {
                        guard let c = rep.colorAt(x: Int(x * k), y: Int(y * k))?.usingColorSpace(.sRGB) else { continue }
                        let px = [c.redComponent, c.greenComponent, c.blueComponent]
                        if px.reduce(0, +) > sum { best = px; sum = px.reduce(0, +) }
                    }
                }
                return best
            }
            let purple = brightest(a), white = brightest(sh)
            XCTAssertTrue(purple.count == 3 && purple[2] > purple[1] + 0.1 && purple[0] > purple[1], "purple glyph and number (increase contrast \(hc)): \(purple)")
            XCTAssertTrue(AgentSidebarRowView.shellsInk == .white, "the default theme's shells ink is white (increase contrast \(hc))")
            XCTAssertTrue(white.count == 3 && white.allSatisfy { $0 > 0.9 }, "white glyph and number (increase contrast \(hc)): \(white)")
        }
    }
}

extension AgentRowSelectedTextTests {
    /// #1735, #1776: the two count inks over the row on every theme, unselected (the sidebar) and selected (the accent at 0.14 over
    /// it): each clears 3:1; the shells ink is white where white clears 3:1 over the sidebar, else textPrimary; the agents ink is one
    /// of the two purples (#9D7BEA, #7851A9). Prints the lowest ratio as COUNTINK1776-FACT.
    func testCountInksClearThreeToOneOnEveryTheme() throws {
        var pairs = 0
        var lowest = Double.infinity
        try onEveryTheme { d, p in
            let side = rgba(p.sidebar)
            let white = ThemeRuntime.contrastRatio(.white, p.sidebar) >= 3
            XCTAssertTrue(rgba(AgentSidebarRowView.shellsInk) == rgba(white ? .white : p.textPrimary), "\(d.title): shells ink is white or textPrimary")
            XCTAssertTrue([AgentSidebarRowView.purpleLight, AgentSidebarRowView.purpleDark].contains { rgba($0) == rgba(AgentSidebarRowView.agentsInk) }, "\(d.title): one royal purple")
            for selected in [false, true] {
                let bg = selected ? over(side, p.blue, 0.14) : side
                let row = Color(nsColor: ns((bg.r, bg.g, bg.b, 1)))
                for (name, ink) in [("agents", AgentSidebarRowView.agentsInk), ("shells", AgentSidebarRowView.shellsInk)] {
                    let ratio = ThemeRuntime.contrastRatio(ink, row)
                    XCTAssertGreaterThanOrEqual(ratio, 3, "\(d.title) selected \(selected): \(name) ink over row \(ratio):1")
                    lowest = min(lowest, ratio)
                    pairs += 1
                }
            }
        }
        print("COUNTINK1776-FACT lowest count ink ratio over the sidebar or the selected row: \(lowest)")
        XCTAssertEqual(pairs, 22 * 4)
    }

    /// #1789 (QA n105, WCAG 1.4.3): the count DIGITS are text: over the sidebar and over the selected row each clears 4.5:1 on every theme;
    /// they keep the glyph's ink (purple, white) wherever it already does and draw textPrimary where it does not; the glyph's ink is unchanged.
    /// On the island's own card the ink is kept. Prints the lowest digit ratio as COUNTDIGIT1789-FACT and how many pairs fell back.
    func testCountDigitsClearFourPointFiveOnEveryTheme() throws {
        var pairs = 0, fallbacks = 0
        var lowest = Double.infinity
        try onEveryTheme { d, p in
            let side = rgba(p.sidebar)
            for selected in [false, true] {
                let bg = selected ? over(side, p.blue, 0.14) : side
                let row = Color(nsColor: ns((bg.r, bg.g, bg.b, 1)))
                for (name, glyph) in [("agents", AgentSidebarRowView.agentsInk), ("shells", AgentSidebarRowView.shellsInk)] {
                    let digits = AgentCountGroups.digitInk(glyph, selected: selected, ownCard: false) ?? .clear
                    let ratio = ThemeRuntime.contrastRatio(digits, row)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(d.title) selected \(selected): \(name) digits over row \(ratio):1")
                    let kept = ThemeRuntime.contrastRatio(glyph, row) >= 4.5
                    XCTAssertTrue(rgba(digits) == rgba(kept ? glyph : p.textPrimary), "\(d.title) selected \(selected): \(name) digits keep the ink or draw textPrimary")
                    if !kept { fallbacks += 1 }
                    lowest = min(lowest, ratio)
                    pairs += 1
                }
            }
            XCTAssertTrue(rgba(AgentCountGroups.digitInk(.purple, selected: true, ownCard: true) ?? .clear) == rgba(.purple), "\(d.title): the island's own card keeps the ink")
            XCTAssertTrue(AgentCountGroups.digitInk(nil, selected: true, ownCard: false) == nil, "\(d.title): no ink, no digits ink")
        }
        print("COUNTDIGIT1789-FACT lowest digit ratio \(lowest), \(fallbacks) of \(pairs) pairs draw textPrimary")
        XCTAssertEqual(pairs, 22 * 4)
    }

    /// #1739, #1776: on the island's own card (Follow theme off: white at 0.05, 0.10 hovered, over the black notch about #0d0d0d) the
    /// inks are white (shells) and #9D7BEA (agents) on every theme, each >= 3:1 over both fills; the sidebar's choice is unchanged (ownCard false).
    func testCountInksOnTheFollowOffIslandCardClearThreeToOneOnEveryTheme() throws {
        var pairs = 0
        let notch = (r: CGFloat(13) / 255, g: CGFloat(13) / 255, b: CGFloat(13) / 255, a: CGFloat(1))
        try onEveryTheme { d, _ in
            let shells = AgentCountGroups.tint(.shells, ownCard: true), agents = AgentCountGroups.tint(.agents, ownCard: true)
            XCTAssertTrue(rgba(shells ?? .clear) == rgba(.white), "\(d.title): shells ink is white")
            XCTAssertTrue(rgba(agents ?? .clear) == rgba(AgentSidebarRowView.purpleLight), "\(d.title): agents ink is #9D7BEA")
            XCTAssertTrue(AgentCountGroups.tint(.open, ownCard: true) == nil, "\(d.title): the open group keeps its own ink")
            XCTAssertTrue(rgba(AgentCountGroups.tint(.shells, ownCard: false) ?? .clear) == rgba(AgentSidebarRowView.shellsInk), "\(d.title): sidebar shells unchanged")
            XCTAssertTrue(rgba(AgentCountGroups.tint(.agents, ownCard: false) ?? .clear) == rgba(AgentSidebarRowView.agentsInk), "\(d.title): sidebar agents unchanged")
            for hover in [false, true] {
                let bg = over(notch, AgentIslandHistoryRow.ownCardFill(selected: hover), 1)
                let card = Color(nsColor: ns((bg.r, bg.g, bg.b, 1)))
                for (name, ink) in [("agents", agents), ("shells", shells)] {
                    let ratio = ink.map { ThemeRuntime.contrastRatio($0, card) } ?? 0
                    XCTAssertGreaterThanOrEqual(ratio, 3, "\(d.title) hover \(hover): \(name) ink over the card \(ratio):1")
                    pairs += 1
                }
            }
        }
        XCTAssertEqual(pairs, 22 * 4)
    }

    /// #1745 (QA r1733-stack n74), #1776: the wiring, not the static choice. The row's real detailLine draws its count groups; the probe
    /// reports the ink each group chose. The island card (inks set, as AgentIslandRow.inks builds them with Follow theme off) is white shells and
    /// #9D7BEA agents; the sidebar (inks nil) keeps #1735's choice. `ownCard: inks != nil` -> `ownCard: false` turns the card's rows red.
    @MainActor
    func testCountInksComeThroughDetailLineWiring() throws {
        var s = AgentSidebar.Row(id: .live(AgentSessionKey(dir: "/Users/example/work", name: "api")), title: "sec-1", state: .working,
                                 detail: "Working", age: "", prs: [], prCount: 0, agents: 3, merged: 0)
        s.shells = [DchShell(id: "1", pid: 1, started: 0, command: "make")]
        let inks = AgentSidebarRowView.Inks(primary: .white, quiet: .white, blue: .blue, blocked: .orange, mark: .gray, badges: .default)
        func chosen(_ inks: AgentSidebarRowView.Inks?) throws -> [String: String] {
            var got: [String: String] = [:]
            AgentCountGroups.tintProbe = { [self] c, col in got["\(c)"] = col.map { "\(self.rgba($0))" } ?? "none" }
            defer { AgentCountGroups.tintProbe = nil }
            let r = ImageRenderer(content: AgentSidebarRowView(row: s, selected: false, inks: inks).detailLine([]))
            _ = try XCTUnwrap(r.cgImage)
            return got
        }
        let card = try chosen(inks), side = try chosen(nil)
        XCTAssertEqual(card["shells"], "\(rgba(.white))", "card shells ink is white")
        XCTAssertEqual(card["agents"], "\(rgba(AgentSidebarRowView.purpleLight))", "card agents ink is #9D7BEA")
        XCTAssertEqual(side["shells"], "\(rgba(AgentSidebarRowView.shellsInk))", "sidebar shells unchanged")
        XCTAssertEqual(side["agents"], "\(rgba(AgentSidebarRowView.agentsInk))", "sidebar agents unchanged")
    }

    /// #1795 helper: the digits' ink each group of the row's real detailLine draws, on the current palette.
    @MainActor
    func digitsDrawn1795(selected: Bool) throws -> [String: String] {
        var s = AgentSidebar.Row(id: .live(AgentSessionKey(dir: "/Users/example/work", name: "api")), title: "sec-1", state: .working,
                                 detail: "Working", age: "", prs: [], prCount: 0, agents: 3, merged: 0)
        s.shells = [DchShell(id: "1", pid: 1, started: 0, command: "make")]
        var got: [String: String] = [:]
        AgentCountGroups.digitProbe = { [self] c, col in got["\(c)"] = col.map { "\(self.rgba($0))" } ?? "none" }
        defer { AgentCountGroups.digitProbe = nil }
        _ = try XCTUnwrap(ImageRenderer(content: AgentSidebarRowView(row: s, selected: selected).detailLine([])).cgImage)
        return got
    }

    /// #1795 (#1789 review, mutant wiring-dropped): the row passes `selected` to its count groups. On a theme whose digits keep the glyph's
    /// ink on the sidebar and fall back to textPrimary only on the selected wash, the real detailLine draws the glyph's ink unselected and
    /// textPrimary selected. `selected: selected` -> `selected: false` in detailLine turns the selected half red.
    @MainActor
    func testCountDigitsFallBackOnlyWhenSelectedThroughDetailLine() throws {
        var checked = 0
        try onEveryTheme { d, p in
            for (name, glyph) in [("agents", AgentSidebarRowView.agentsInk), ("shells", AgentSidebarRowView.shellsInk)] {
                let off = rgba(AgentCountGroups.digitInk(glyph, selected: false, ownCard: false) ?? .clear)
                let on = rgba(AgentCountGroups.digitInk(glyph, selected: true, ownCard: false) ?? .clear)
                guard off != on else { continue }   // the digits differ by selection on this theme and group
                let drawnOff = try digitsDrawn1795(selected: false), drawnOn = try digitsDrawn1795(selected: true)
                XCTAssertEqual(drawnOff[name], "\(off)", "\(d.title): \(name) digits unselected")
                XCTAssertEqual(drawnOn[name], "\(on)", "\(d.title): \(name) digits selected draw the fallback")
                XCTAssertEqual(drawnOn[name], "\(rgba(p.textPrimary))", "\(d.title): \(name) the fallback is textPrimary")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "at least one theme and group falls back only when selected (11 of 88 pairs)")
    }

    /// #1795 (performance, operator): the digits' ink is computed once per (group, selected) per theme, not per row body. Ten bodies of the
    /// same row on one palette compute at most two inks (agents, shells) and none after the first body; the other selection computes its own;
    /// a palette change recomputes. Counts computations, not time. Mutants: cache-bypassed (every body computes), cache-key-drops-selected
    /// (the selected body draws the unselected ink), cache-never-cleared-on-theme-change (the new palette draws the old ink, no recompute).
    @MainActor
    func testCountDigitsInkIsComputedOncePerThemeNotPerRowBody() throws {
        let saved = ThemeRuntime.palette
        defer { ThemeRuntime.palette = saved }
        var fallsOnlySelected: ThemePalette?
        try onEveryTheme { _, p in
            ThemeRuntime.palette = p
            let g = AgentSidebarRowView.agentsInk
            if rgba(AgentCountGroups.digitInk(g, selected: false, ownCard: false) ?? .clear) != rgba(AgentCountGroups.digitInk(g, selected: true, ownCard: false) ?? .clear), fallsOnlySelected == nil { fallsOnlySelected = p }
        }
        let p = try XCTUnwrap(fallsOnlySelected, "a theme whose digits differ by selection")
        ThemeRuntime.palette = p   // empties the cache
        let before = AgentCountGroups.digitInkComputations
        let first = try digitsDrawn1795(selected: true)
        let afterFirst = AgentCountGroups.digitInkComputations
        XCTAssertGreaterThan(afterFirst, before, "the first body computes")
        XCTAssertLessThanOrEqual(afterFirst - before, 2, "at most one per group (agents, shells)")
        for _ in 0..<9 { XCTAssertEqual(try digitsDrawn1795(selected: true), first) }
        XCTAssertEqual(AgentCountGroups.digitInkComputations, afterFirst, "nine more bodies compute nothing")
        let unselected = try digitsDrawn1795(selected: false)
        XCTAssertGreaterThan(AgentCountGroups.digitInkComputations, afterFirst, "the other selection is its own key")
        XCTAssertNotEqual(unselected["agents"] ?? unselected["shells"], first["agents"] ?? first["shells"], "selected and unselected digits differ on this theme")
        let afterBoth = AgentCountGroups.digitInkComputations
        ThemeRuntime.palette = .default
        _ = try digitsDrawn1795(selected: true)
        XCTAssertGreaterThan(AgentCountGroups.digitInkComputations, afterBoth, "a theme change recomputes")
    }
}
