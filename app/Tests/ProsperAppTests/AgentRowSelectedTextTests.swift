import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1271: every text the Agent Sessions sidebar's SELECTED row draws clears 4.5:1 over the selected fill (the accent at
/// 0.14 over the sidebar, NeonSelectedRowFill) on every bundled theme, and the drawn colour is read back from an offscreen
/// render (a view in a never-shown host, bitmapImageRepForCachingDisplay; no window, no event, no file). Fakes only.
@MainActor
final class AgentRowSelectedTextTests: XCTestCase {

    static let expected = ["Default", "theme-amber", "theme-blossom", "theme-contrast-dark", "theme-contrast-light",
                           "theme-crimson", "theme-daylight", "theme-default", "theme-ember", "theme-emerald",
                           "theme-fern", "theme-gold", "theme-graphite", "theme-indigo", "theme-lavender",
                           "theme-lime", "theme-mint", "theme-rose", "theme-silver", "theme-solar",
                           "theme-teal", "theme-violet"]
    typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)

    /// The 22 themes as ThemeContrastTests loads them (the literal list above must be all of them).
    func themes() throws -> [ThemeDescriptor] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { d -> ThemeDescriptor in
                let json = d.appendingPathComponent("theme.json")
                let spec = try ThemeSpec.decode(Data(contentsOf: json))
                return ThemeDescriptor(id: "test.1271.\(d.lastPathComponent)", title: d.lastPathComponent,
                                       appearance: spec.appearance, extensionID: "test.1271", jsonPath: json)
            }
        let all = [ThemeDescriptor.builtIn] + bundled
        XCTAssertEqual(Set(all.map(\.title)), Set(Self.expected), "the literal list is every bundled theme")
        XCTAssertEqual(all.count, 22)
        return all
    }

    /// Runs `body` with the runtime palette set to each theme (Increase Contrast off), restoring both after.
    func onEveryTheme(_ body: (ThemeDescriptor, ThemePalette) throws -> Void) throws {
        _ = ThemeStore.shared
        let (savedPalette, savedIC, savedScale) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast, ThemeRuntime.scale)
        defer { ThemeRuntime.palette = savedPalette; ThemeRuntime.increaseContrast = savedIC; ThemeRuntime.scale = savedScale }
        ThemeRuntime.increaseContrast = false
        ThemeRuntime.scale = 1.0
        for d in try themes() {
            let p = ThemePalette.load(for: d)
            ThemeRuntime.palette = p
            try body(d, p)
        }
    }

    func rgba(_ c: Color) -> RGBA {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }
    func over(_ b: RGBA, _ c: Color, _ opacity: Double) -> RGBA {
        let f = rgba(c), a = CGFloat(opacity) * f.a
        return (b.r * (1 - a) + f.r * a, b.g * (1 - a) + f.g * a, b.b * (1 - a) + f.b * a, b.a)
    }
    func ns(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
    func dist(_ a: RGBA, _ b: RGBA) -> CGFloat { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) }

    /// How far `px` is from the colour `c` drawn over `bg` at a coverage of 0.7...1 (the extreme pixel of a thin stem is not
    /// always fully covered: black over white reads 0.13 grey at 0.87), the closest coverage taken.
    func miss(_ px: RGBA, _ c: RGBA, over bg: RGBA) -> CGFloat {
        let d = (c.r - bg.r, c.g - bg.g, c.b - bg.b), v = (px.r - bg.r, px.g - bg.g, px.b - bg.b)
        let n = d.0 * d.0 + d.1 * d.1 + d.2 * d.2
        let t = n > 0 ? min(1, max(0.7, (v.0 * d.0 + v.1 * d.1 + v.2 * d.2) / n)) : 1
        return dist(px, (bg.r + t * d.0, bg.g + t * d.1, bg.b + t * d.2, 1))
    }

    func row(state: AgentState?, detail: String) -> AgentSidebar.Row {
        AgentSidebar.Row(id: .live(AgentSessionKey(dir: "/tmp/dch-test", name: "api")), title: "api", state: state,
                         detail: detail, age: "", prs: [], prCount: 0, agents: 0, merged: 0)
    }

    // MARK: Contrast

    /// Every text a selected row draws, by the ink the row takes (`AgentSidebarRowView.ink`, the one the row's views call),
    /// against the selected fill on every theme; the PR chip over its own blue wash on top; the badges are
    /// AgentRowBadgeTests'. The title with a state is textPrimary; the Command-digit chip is bgTop over the accent fill. On an
    /// unselected row the inks are the old tokens, unchanged.
    func testEverySelectedRowTextClearsTheSelectedFillOnEveryTheme() throws {
        var pairs = 0
        try onEveryTheme { d, p in
            let sel = over(rgba(p.sidebar), p.blue, 0.14)
            let chipFill = over(sel, agentStateColor(.blocked), 0.14)   // #1451: the Needs input badge's wash
            let texts: [(String, Color, RGBA)] = [
                ("title (no state)", AgentSidebarRowView.ink(.quiet, selected: true), sel),
                ("title (state)", Neon.textPrimary, sel),
                ("state text", AgentSidebarRowView.ink(.quiet, selected: true), sel),
                ("blocked state text", AgentSidebarRowView.ink(.blocked, selected: true), sel),
                ("count group", AgentSidebarRowView.ink(.quiet, selected: true), sel),
                ("open count", AgentSidebarRowView.ink(.blue, selected: true), sel),
                ("PR chip", AgentSidebarRowView.prChipInk(selected: true), chipFill),
                ("age", AgentSidebarRowView.ink(.quiet, selected: true), sel),
                ("host", AgentSidebarRowView.ink(.quiet, selected: true), sel),
                ("digit chip", Neon.bgTop, rgba(p.blue)),
            ]
            for (name, color, fill) in texts {
                let r = ThemeContrastTests.contrast(NSColor(color), on: ns((fill.r, fill.g, fill.b, 1)))
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(d.title): \(name) on the selected row is \(r):1")
                pairs += 1
            }
            // Nothing changes on an unselected row.
            for (kind, was) in [(AgentSidebarRowView.Ink.quiet, Neon.textSecondary), (.blue, Neon.blue),
                                (.blocked, d.appearance == .light ? AgentSidebarRowView.darkAmber : agentStateColor(.blocked))] {
                XCTAssertTrue(dist(rgba(AgentSidebarRowView.ink(kind, selected: false)), rgba(was)) < 0.001, "\(d.title): \(kind) unselected")
            }
        }
        XCTAssertEqual(pairs, 22 * 10)
    }

    /// #1451 step b: the amber as text. On every theme the unselected PR chip's ink over each surface it can sit on (the sidebar,
    /// the header and card surfaces) plus the 0.14 wash is at least 3:1; a dark theme's is agentStateColor(.blocked) exactly, a
    /// light theme's the darker amber (same hue); the Needs input badge's text is read back from its render over the header
    /// and is that same ink. 22 themes, 8 light.
    func testAmberInkClearsThreeToOneOnEveryTheme() throws {
        var light = 0, dark = 0, badges = 0
        try onEveryTheme { d, p in
            let amber = agentStateColor(.blocked)
            let chipInk = AgentSidebarRowView.prChipInk(selected: false)
            if d.appearance == .light {
                light += 1
                XCTAssertTrue(dist(rgba(chipInk), rgba(AgentSidebarRowView.darkAmber)) < 0.001, "\(d.title): light ink is the darker amber")
                XCTAssertTrue(dist(rgba(chipInk), rgba(amber)) > 0.3, "\(d.title): and not #FFB300")
            } else {
                dark += 1
                XCTAssertTrue(dist(rgba(chipInk), rgba(amber)) < 0.001, "\(d.title): a dark theme keeps agentStateColor(.blocked)")
            }
            for (name, surface) in [("sidebar", p.sidebar), ("bgTop", p.bgTop), ("bgBottom", p.bgBottom), ("card", p.card), ("cardHi", p.cardHi)] {
                let fill = over(rgba(surface), amber, AgentSidebarRowView.prChipFillOpacity)
                let r = ThemeContrastTests.contrast(NSColor(chipInk), on: ns((fill.r, fill.g, fill.b, 1)))
                XCTAssertGreaterThanOrEqual(r, 3, "\(d.title): the PR chip's text over \(name) plus the wash is \(r):1")
            }
            // The badge's own text, from its pixels over the header: the chip's ink, not the unfixed amber, on a light theme.
            let top = rgba(p.bgTop), fill = over(top, amber, 0.14)
            guard let (rep, k) = render(AgentStateChip(state: .blocked).padding(sz(4)), size: CGSize(width: sz(140), height: sz(28)),
                                        background: Color(.sRGB, red: Double(top.r), green: Double(top.g), blue: Double(top.b))),
                  let px = ink(rep, k: k, rect: CGRect(x: 0, y: 0, width: sz(140), height: sz(28)), bg: fill) else { return XCTFail("\(d.title): no badge") }
            badges += 1
            let want = rgba(chipInk)
            XCTAssertLessThanOrEqual(miss(px, want, over: fill), miss(px, rgba(amber), over: fill), "\(d.title): badge text \(px)")
            if d.appearance == .light {
                XCTAssertLessThan(miss(px, want, over: fill), miss(px, rgba(amber), over: fill), "\(d.title): the badge text is not #FFB300: \(px)")
            }
        }
        XCTAssertEqual([light, dark, badges], [8, 14, 22])
    }

    // MARK: Pixels

    /// Renders `view` over `background` in a never-shown host and returns the bitmap and its pixels-per-point.
    func render<V: View>(_ view: V, size: CGSize, background: Color) -> (NSBitmapImageRep, CGFloat)? {
        let root = ZStack(alignment: .topLeading) { background; view }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: size)
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        h.layoutSubtreeIfNeeded()
        guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { return nil }
        h.cacheDisplay(in: h.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / size.width)
    }

    /// The pixel in `rect` (points) farthest from `bg`: the text's colour where a stem is fully covered.
    func ink(_ rep: NSBitmapImageRep, k: CGFloat, rect: CGRect, bg: RGBA) -> RGBA? {
        var best: RGBA?, far: CGFloat = 0
        for y in Int(rect.minY * k)..<min(rep.pixelsHigh, Int(rect.maxY * k)) {
            for x in Int(rect.minX * k)..<min(rep.pixelsWide, Int(rect.maxX * k)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let v: RGBA = (c.redComponent, c.greenComponent, c.blueComponent, 1)
                if dist(v, bg) > far { far = dist(v, bg); best = v }
            }
        }
        return best
    }

    /// The state text of a selected row, read from the pixels of the second line (the state text alone: no age, so no
    /// other ink is in the band), is nearer textPrimary than textSecondary on every theme; a blocked row's, nearer textPrimary than the
    /// amber. The row is drawn over the sidebar colour; its own fill gives the selected background.
    func testSelectedRowStateTextIsDrawnInTextPrimaryOnEveryTheme() throws {
        var reads = 0
        try onEveryTheme { d, p in
            let sel = over(rgba(p.sidebar), p.blue, 0.14)
            for (state, detail, wrong) in [(AgentState.idle, "Idle", p.textSecondary), (.blocked, "Needs input", agentStateColor(.blocked))] {
                let size = CGSize(width: (AgentWindowModel.fullSidebarWidth - sz(16)), height: sz(60))
                guard let (rep, k) = render(AgentSidebarRowView(row: row(state: state, detail: detail), selected: true).frame(width: (AgentWindowModel.fullSidebarWidth - sz(16))),
                                            size: size, background: p.sidebar) else { return XCTFail("no bitmap") }
                // Line two: below the title, clear of the row's edge, bar and corners.
                let band = CGRect(x: sz(30), y: sz(27), width: (AgentWindowModel.fullSidebarWidth - sz(16)) - sz(60), height: sz(14))
                guard let px = ink(rep, k: k, rect: band, bg: sel) else { return XCTFail("\(d.title): no pixels") }
                reads += 1
                XCTAssertLessThan(miss(px, rgba(p.textPrimary), over: sel), miss(px, rgba(wrong), over: sel),
                                  "\(d.title): \(detail) is drawn nearer textSecondary/amber than textPrimary: \(px)")
            }
        }
        XCTAssertEqual(reads, 22 * 2)
    }

    /// R1268-c1: a selected row's badge text colour, read from the pixels of the badges as the slot draws them
    /// (`badges(model:effort:selected:)` through `badge`): the model's and the low effort's (the quiet looks) are nearer
    /// textPrimary than textSecondary on the selected row, on every theme.
    func testSelectedRowBadgeTextColourIsReadFromThePixels() throws {
        var reads = 0
        try onEveryTheme { d, p in
            for selected in [true] {   // unselected: grey over grey ties under the coverage fit; AgentRowBadgeTests holds its tokens
                let shown = AgentSidebarRowView.badges(model: "Fable 9.2", effort: "low", selected: selected)
                XCTAssertEqual(shown.count, 2)
                for (i, b) in shown.enumerated() {
                    let size = CGSize(width: sz(120), height: sz(24))
                    let sidebar = rgba(p.sidebar)
                    let rowBg = selected ? over(sidebar, p.blue, 0.14) : sidebar
                    guard let (rep, k) = render(AgentSidebarRowView.badge(b.text, b.look).padding(sz(4)), size: size,
                                                background: Color(.sRGB, red: Double(rowBg.r), green: Double(rowBg.g), blue: Double(rowBg.b))) else {
                        return XCTFail("no bitmap")
                    }
                    let fill = over(rowBg, p[keyPath: b.look.fill], b.look.opacity)
                    guard let px = ink(rep, k: k, rect: CGRect(x: sz(4), y: sz(4), width: sz(100), height: sz(16)), bg: fill) else {
                        return XCTFail("\(d.title): no pixels")
                    }
                    let (want, other) = selected ? (p.textPrimary, p.textSecondary) : (p.textSecondary, p.textPrimary)
                    reads += 1
                    XCTAssertLessThan(miss(px, rgba(want), over: fill), miss(px, rgba(other), over: fill),
                                      "\(d.title): badge \(i) selected \(selected) reads \(px)")
                }
            }
        }
        XCTAssertEqual(reads, 22 * 2)
    }
}
