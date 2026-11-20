import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1268: the Agent Sessions sidebar row's model and effort badges, the age at the end of the second line and the
/// Command-digit chip's room at the end of the first: the looks by level, their contrast on every bundled theme, the
/// fixed slots, the ladder's order and the widths at UI scale 0.7, 0.85 and 1.0. Offscreen only: views are measured or
/// hosted in windows that are never shown; no event is posted; fakes only.
@MainActor
final class AgentRowBadgeTests: XCTestCase {

    static let now: TimeInterval = 1_800_000_000
    static let scales: [CGFloat] = [0.7, 0.85, 1.0]
    static let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")

    func atScales(_ body: (CGFloat) throws -> Void) rethrows {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in Self.scales {
            ThemeRuntime.scale = scale
            try body(scale)
        }
    }

    func ideal<V: View>(_ v: V) -> CGSize { NSHostingView(rootView: v.fixedSize()).fittingSize }

    /// The text column of a row `width` wide: padding 10 each side, the glyph slot 14, its gap 8; #1345: less the chip's
    /// column and its gap 8.
    func column(_ width: CGFloat) -> CGFloat {
        width - 2 * sz(10) - sz(14) - sz(8) - sz(8) - ideal(AgentSidebarRowView.digitColumn).width
    }

    /// A live Claude row by hand: idle, "4m", two PR chips, 3 agents, model and effort.
    func row(age: String = "4m", prs: Bool = true, model: String? = "Fable 9.2", effort: String? = "high") -> AgentSidebar.Row {
        AgentSidebar.Row(id: .live(Self.key), title: "api", state: .idle, detail: "Idle", age: age,
                         prs: prs ? ["api#1", "api#2"] : [], prCount: prs ? 2 : 0, agents: prs ? 3 : 0, merged: 0,
                         modelSlot: true, model: model, effort: model == nil ? nil : effort)
    }

    // MARK: The looks

    /// The effort badge's look by level, written out (quietest to strongest); an unknown word and no effort take the
    /// neutral look, as the model badge does; every level differs from the neutral and from each other.
    func testEffortLookByLevel() {
        typealias L = AgentSidebarRowView.BadgeLook
        func same(_ a: L, _ b: L) -> Bool { a.text == b.text && a.fill == b.fill && a.opacity == b.opacity }
        let want: [(String, L)] = [("low", (\ThemePalette.textSecondary, \ThemePalette.blue, 0.06)),
                                   ("medium", (\ThemePalette.textPrimary, \ThemePalette.blue, 0.12)),
                                   ("high", (\ThemePalette.textPrimary, \ThemePalette.blue, 0.24)),
                                   ("xhigh", (\ThemePalette.textPrimary, \ThemePalette.magenta, 0.18)),
                                   ("max", (\ThemePalette.textPrimary, \ThemePalette.magenta, 0.32))]
        XCTAssertEqual(Set(want.map { $0.0 }), AgentModelEffort.levels, "every level has a look")
        let neutral = AgentSidebarRowView.neutralLook
        XCTAssertTrue(same(neutral, (\ThemePalette.textSecondary, \ThemePalette.textSecondary, 0.06)))
        for (word, look) in want {
            XCTAssertTrue(same(AgentSidebarRowView.effortLook(word), look), word)
            XCTAssertFalse(same(look, neutral), "\(word) is tinted")
        }
        for (i, a) in want.enumerated() {
            for b in want.dropFirst(i + 1) { XCTAssertFalse(same(a.1, b.1), "\(a.0) and \(b.0) differ") }
        }
        let unknown: [String?] = ["ultra", "", "HIGH", nil]
        for word in unknown {
            XCTAssertTrue(same(AgentSidebarRowView.effortLook(word), neutral), "\(word ?? "nil"): neutral")
        }
    }

    /// The looks as the slot draws them (`badges(model:effort:)`, the one list modelSlotView draws): the model badge
    /// neutral first, then the effort badge with its level's look, never the neutral one; model only, one neutral badge;
    /// no model, none.
    func testBadgesTakeTheirLookAtTheCallSite() {
        typealias L = AgentSidebarRowView.BadgeLook
        func same(_ a: L?, _ b: L) -> Bool { a.map { $0.text == b.text && $0.fill == b.fill && $0.opacity == b.opacity } ?? false }
        let neutral = AgentSidebarRowView.neutralLook
        for level in AgentModelEffort.levels.sorted() {
            let b = AgentSidebarRowView.badges(model: "Fable 9.2", effort: level)
            XCTAssertEqual(b.map { $0.text }, ["Fable 9.2", level], level)
            XCTAssertTrue(same(b.first?.look, neutral), "\(level): the model badge is neutral")
            XCTAssertTrue(same(b.last?.look, AgentSidebarRowView.effortLook(level)), "\(level): the effort badge has its level's look")
            XCTAssertFalse(same(b.last?.look, neutral), "\(level): the effort badge is not drawn neutral")
        }
        let only = AgentSidebarRowView.badges(model: "Fable 9.2", effort: nil)
        XCTAssertEqual(only.map { $0.text }, ["Fable 9.2"])
        XCTAssertTrue(same(only.first?.look, neutral), "model only: neutral")
        XCTAssertTrue(AgentSidebarRowView.badges(model: nil, effort: "high").isEmpty, "no model: no badge")
    }

    /// Each badge's text against its own fill over the sidebar (fill = token at its opacity, composited per channel as
    /// the window does), on every bundled theme: the 4.5:1 rule of ThemeContrastTests. The theme list is literal and
    /// must be every bundled theme.
    func testBadgeTextClearsItsFillOnEveryBundledTheme() throws {
        let expected = ["Default", "theme-amber", "theme-blossom", "theme-contrast-dark", "theme-contrast-light",
                        "theme-crimson", "theme-daylight", "theme-default", "theme-ember", "theme-emerald",
                        "theme-fern", "theme-gold", "theme-graphite", "theme-indigo", "theme-lavender",
                        "theme-lime", "theme-mint", "theme-rose", "theme-royal", "theme-silver", "theme-solar",
                        "theme-teal"]
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { d -> ThemeDescriptor in
                let json = d.appendingPathComponent("theme.json")
                let spec = try ThemeSpec.decode(Data(contentsOf: json))
                return ThemeDescriptor(id: "test.1268.\(d.lastPathComponent)", title: d.lastPathComponent,
                                       appearance: spec.appearance, extensionID: "test.1268", jsonPath: json)
            }
        let themes = [ThemeDescriptor.builtIn] + bundled
        XCTAssertEqual(expected.count, 22)
        XCTAssertEqual(Set(themes.map(\.title)), Set(expected), "the literal list is every bundled theme")
        let looks = [("model", AgentSidebarRowView.neutralLook)] + AgentModelEffort.levels.sorted().map {
            ($0, AgentSidebarRowView.effortLook($0))
        }
        XCTAssertEqual(looks.count, 6)
        func rgba(_ c: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
            return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
        }
        var pairs = 0
        for d in themes {
            let p = ThemePalette.load(for: d)
            let s = rgba(p.sidebar)
            for (name, look) in looks {
                let f = rgba(p[keyPath: look.fill]), a = CGFloat(look.opacity) * f.3
                let fill = NSColor(srgbRed: s.0 * (1 - a) + f.0 * a, green: s.1 * (1 - a) + f.1 * a,
                                   blue: s.2 * (1 - a) + f.2 * a, alpha: s.3)
                let r = ThemeContrastTests.contrast(NSColor(p[keyPath: look.text]), on: fill)
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(d.title): \(name) badge text on its fill is \(r):1")
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 22 * 6)
    }

    /// #1268 (R7): the looks as the slot draws them (`badges(model:effort:selected:)`, with the row's `selected`, the
    /// value the chip takes as `active`), every look (model, low, medium, high, xhigh, max) on a selected and an
    /// unselected row, on every bundled theme: the text over its fill over the row's background (the sidebar, and on
    /// the selected row NeonSelectedRowFill's accent at 0.14 over it) clears 4.5:1. The theme list is literal.
    func testBadgeTextClearsItsFillOnTheSelectedRowOnEveryBundledTheme() throws {
        let expected = ["Default", "theme-amber", "theme-blossom", "theme-contrast-dark", "theme-contrast-light",
                        "theme-crimson", "theme-daylight", "theme-default", "theme-ember", "theme-emerald",
                        "theme-fern", "theme-gold", "theme-graphite", "theme-indigo", "theme-lavender",
                        "theme-lime", "theme-mint", "theme-rose", "theme-royal", "theme-silver", "theme-solar",
                        "theme-teal"]
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { d -> ThemeDescriptor in
                let json = d.appendingPathComponent("theme.json")
                let spec = try ThemeSpec.decode(Data(contentsOf: json))
                return ThemeDescriptor(id: "test.1268.\(d.lastPathComponent)", title: d.lastPathComponent,
                                       appearance: spec.appearance, extensionID: "test.1268", jsonPath: json)
            }
        let themes = [ThemeDescriptor.builtIn] + bundled
        XCTAssertEqual(expected.count, 22)
        XCTAssertEqual(Set(themes.map(\.title)), Set(expected), "the literal list is every bundled theme")
        typealias L = AgentSidebarRowView.BadgeLook
        func looks(_ selected: Bool) -> [(String, L)] {
            let model: [(String, L)] = AgentSidebarRowView.badges(model: "Fable 9.2", effort: nil, selected: selected)
                .first.map { [("model", $0.look)] } ?? []
            return model + AgentModelEffort.levels.sorted().compactMap { level -> (String, L)? in
                AgentSidebarRowView.badges(model: "Fable 9.2", effort: level, selected: selected).last.map { (level, $0.look) }
            }
        }
        func rgba(_ c: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
            return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
        }
        func over(_ b: (CGFloat, CGFloat, CGFloat, CGFloat), _ c: Color, _ opacity: Double) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let f = rgba(c), a = CGFloat(opacity) * f.3
            return (b.0 * (1 - a) + f.0 * a, b.1 * (1 - a) + f.1 * a, b.2 * (1 - a) + f.2 * a, b.3)
        }
        var pairs = 0
        for d in themes {
            let p = ThemePalette.load(for: d)
            for selected in [false, true] {
                let ls = looks(selected)
                XCTAssertEqual(ls.map { $0.0 }, ["model"] + AgentModelEffort.levels.sorted(), "\(d.title) selected \(selected)")
                let row = selected ? over(rgba(p.sidebar), p.blue, 0.14) : rgba(p.sidebar)
                for (name, look) in ls {
                    let f = over(row, p[keyPath: look.fill], look.opacity)
                    let r = ThemeContrastTests.contrast(NSColor(p[keyPath: look.text]),
                                                        on: NSColor(srgbRed: f.0, green: f.1, blue: f.2, alpha: f.3))
                    XCTAssertGreaterThanOrEqual(r, 4.5, "\(d.title): \(name) badge text, selected \(selected), is \(r):1")
                    pairs += 1
                }
            }
        }
        XCTAssertEqual(pairs, 22 * 6 * 2)
    }

    // MARK: Fixed slots

    /// The age slot keeps one width whatever the age (and with none), so the badges never move; the first line keeps
    /// one width and the title's height with any number or none; the row's height is the same with or without one.
    func testAgeAndChipSlotsKeepOneSize() {
        let ages = ["", "now", "4m", "59m", "23h", "364d", "1y", "99y"]
        atScales { scale in
            let lines = ages.map { ideal(AgentSidebarRowView(row: row(age: $0, prs: false), selected: false)
                .detailLine([])).width }
            for (age, w) in zip(ages, lines) {
                XCTAssertEqual(w, lines.first ?? -1, accuracy: 0.01, "line two with age \"\(age)\" (\(scale))")
            }
            XCTAssertGreaterThanOrEqual(ideal(AgentSidebarRowView(row: row(), selected: false).ageSlot).width,
                                        ideal(Text("364d").font(Neon.font(10).monospacedDigit())).width - 0.01,
                                        "the slot holds the widest age (\(scale))")
            let r = row()
            let title = ideal(Text(r.title).font(Neon.font(12.5, weight: .medium))).height
            let numbers: [Int?] = [nil, 1, 2, 3, 4, 5, 6, 7, 8, 9]
            let first = numbers.map { ideal(AgentSidebarRowView(row: r, selected: false, number: $0).titleLine) }
            for (i, s) in first.enumerated() {
                XCTAssertEqual(s.width, first.first?.width ?? -1, accuracy: 0.01, "line one width, number \(i) (\(scale))")
                XCTAssertEqual(s.height, title, accuracy: 0.01, "line one is the title's height, number \(i) (\(scale))")
            }
            for width in [(AgentWindowModel.fullSidebarWidth - sz(16)), sz(150)] {
                let h = ([nil, 4] as [Int?]).map { NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false, number: $0)
                    .frame(width: width)).fittingSize.height }
                XCTAssertEqual(h.first ?? -1, h.last ?? -2, accuracy: 0.01, "row height with and without Command-4 chip at \(width) (\(scale))")
            }
        }
    }

    // MARK: The ladder

    /// One row per step of line two's ladder (chips, count, none; #1345: the badges are on line one, was chips +
    /// badges, count + badges, count, none): each at a column just as wide as its own variant, so the step before it
    /// does not fit; the state text and the age are on every step and the badges on none.
    func testCrowdedLineGivesUpChipsThenCount() {
        let r = row()
        atScales { scale in
            let v = AgentSidebarRowView(row: r, selected: false)
            let widths = [v.detailLine(r.prs), v.detailLine([], open: r.prCount), v.detailLine([])].map { ideal($0).width }
            XCTAssertEqual(widths.count, 3)
            for (a, b) in zip(widths, widths.dropFirst()) { XCTAssertGreaterThan(a, b + 1, "steps apart: \(widths) (\(scale))") }
            let want: [(chips: Bool, count: Bool)] = [(true, false), (false, true), (false, false)]
            for (step, w) in zip(want, widths) {
                let width = w.rounded(.up) + 0.5
                let t = AXTreeSupport.tree(v.detailVariants.frame(width: width, alignment: .leading),
                                           CGSize(width: width, height: sz(30))) { t in
                    t.contains { $0.named("Idle") } && t.contains { $0.named("4m") }
                }
                let labels = Set(t.flatMap(\.names))
                let tag = "at \(width) (\(scale)): \(labels.filter { !$0.isEmpty }.sorted())"
                XCTAssertTrue(labels.isSuperset(of: ["Idle", "4m", "3 agents"]), "state, count groups and age stay \(tag)")
                XCTAssertEqual(labels.contains("api#1"), step.chips, "chips \(tag)")
                XCTAssertFalse(labels.contains("Fable 9.2") || labels.contains("high"), "no badges on line two \(tag)")
                XCTAssertEqual(labels.contains("2 open pull requests"), step.count, "count \(tag)")
            }
            // Too narrow for every step but the last: the state text and the age still drawn.
            let narrow = (widths.last ?? 0).rounded(.up) + 0.5
            let t = AXTreeSupport.tree(v.detailVariants.frame(width: narrow, alignment: .leading),
                                       CGSize(width: narrow, height: sz(30))) { t in t.contains { $0.named("4m") } }
            XCTAssertTrue(t.contains { $0.named("Idle") } && t.contains { $0.named("4m") }, "the last step (\(scale))")
            // The sidebar's own width (fixed sz(290), rows sz(274)): which step it takes, for the report.
            let side = AXTreeSupport.tree(v.detailVariants.frame(width: column((AgentWindowModel.fullSidebarWidth - sz(16))), alignment: .leading),
                                          CGSize(width: column((AgentWindowModel.fullSidebarWidth - sz(16))), height: sz(30))) { t in t.contains { $0.named("4m") } }
            print("ROW1345-LADDER scale \(scale) column \(column(sz(274))) steps \(widths.map { ($0 * 10).rounded() / 10 }) "
                  + "sidebar names \(Set(side.flatMap(\.names)).sorted())")
            XCTAssertTrue(side.contains { $0.named("4m") }, "the age at the sidebar's width (\(scale))")
        }
    }

    // MARK: VoiceOver

    /// The badges add no accessibility element: the full row reads one element (today's words) and the Command-4 chip,
    /// nothing named after the model or the effort.
    func testBadgesAddNoAccessibilityElement() {
        let r = row(prs: false)
        let t = AXTreeSupport.tree(AgentSidebarRowView(row: r, selected: false, number: 4).frame(width: (AgentWindowModel.fullSidebarWidth - sz(16))),
                                   CGSize(width: (AgentWindowModel.fullSidebarWidth - sz(16)), height: sz(60))) { t in t.contains { $0.label == "Command-4" } }
        let named = t.flatMap(\.names)
        XCTAssertTrue(named.contains("api, Idle, model Fable 9.2, effort high, 4m ago"), "\(named)")
        XCTAssertTrue(named.contains("Command-4"), "\(named)")
        XCTAssertFalse(named.contains { $0 == "Fable 9.2" || $0 == "high" || $0 == "4m" }, "no badge or age element: \(named)")
    }

    // MARK: Widths (item 4)

    /// The widths at each scale, printed for widths.txt: today's model text slot ("Sonnet 4.5 \u{00B7} medium" at 10 pt), the
    /// new badge slot (never wider), the age slot, the chip slot, and the title's room on line one before (the age slot
    /// there) and after (the chip slot there).
    func testBadgeSlotIsNoWiderThanTheTextSlot() {
        atScales { scale in
            let v = AgentSidebarRowView(row: row(), selected: false)
            let today = ideal(Text("Sonnet 4.5 \u{00B7} medium").font(Neon.font(10))).width
            let slot = ideal(v.modelSlotView).width, age = ideal(v.ageSlot).width
            let chip = ideal(ZStack { ForEach(1...18, id: \.self) { AgentDigitChip(number: $0) } }).width   // #1470: all 18
            let col = column((AgentWindowModel.fullSidebarWidth - sz(16))), fixed = 2 * sz(6) + sz(4)
            XCTAssertLessThanOrEqual(slot, today + 0.01, "the badges are no wider than today's text (\(scale))")
            XCTAssertGreaterThan(slot, sz(40), "the slot has room (\(scale))")
            func r1(_ x: CGFloat) -> CGFloat { (x * 10).rounded() / 10 }
            print("BADGE1268-WIDTHS scale \(scale) todaySlot \(r1(today)) badgeSlot \(r1(slot)) ageSlot \(r1(age)) "
                  + "chipSlot \(r1(chip)) titleRoomBefore \(r1(col - fixed - age)) titleRoomAfter \(r1(col - fixed - chip))")
        }
    }
}
