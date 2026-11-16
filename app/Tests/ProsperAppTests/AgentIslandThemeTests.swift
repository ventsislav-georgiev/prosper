import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1375: Agent Island's inks follow the selected theme while its notch shape stays black (the operator's ruling,
/// 2026-11-16: "Keep black, theme only inks"). Every ink is measured over its real surface on all 22 bundled themes;
/// views render in never-shown hosts (no window, no event, no file). Fakes only.
@MainActor
final class AgentIslandThemeTests: XCTestCase {
    static let expected = ["Default", "theme-amber", "theme-blossom", "theme-contrast-dark", "theme-contrast-light",
                           "theme-crimson", "theme-daylight", "theme-default", "theme-ember", "theme-emerald",
                           "theme-fern", "theme-gold", "theme-graphite", "theme-indigo", "theme-lavender",
                           "theme-lime", "theme-mint", "theme-rose", "theme-silver", "theme-solar",
                           "theme-teal", "theme-violet"]
    typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    static let now: TimeInterval = 1_000_000

    /// The 22 themes as ThemeContrastTests loads them; the literal list above must be all of them.
    func themes() throws -> [ThemeDescriptor] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { d -> ThemeDescriptor in
                let json = d.appendingPathComponent("theme.json")
                let spec = try ThemeSpec.decode(Data(contentsOf: json))
                return ThemeDescriptor(id: "test.1375.\(d.lastPathComponent)", title: d.lastPathComponent,
                                       appearance: spec.appearance, extensionID: "test.1375", jsonPath: json)
            }
        let all = [ThemeDescriptor.builtIn] + bundled
        XCTAssertEqual(Set(all.map(\.title)), Set(Self.expected), "the literal list is every bundled theme")
        XCTAssertEqual(all.count, 22)
        return all
    }

    /// Runs `body` with the runtime palette set to each named theme (all 22 when nil), Increase Contrast off, scale 1.
    func onThemes(_ names: [String]? = nil, _ body: (ThemeDescriptor, ThemePalette) throws -> Void) throws {
        _ = ThemeStore.shared
        let (savedPalette, savedIC, savedScale) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast, ThemeRuntime.scale)
        defer { ThemeRuntime.palette = savedPalette; ThemeRuntime.increaseContrast = savedIC; ThemeRuntime.scale = savedScale }
        ThemeRuntime.increaseContrast = false
        ThemeRuntime.scale = 1.0
        let all = try themes()
        let picked = names.map { n in all.filter { n.contains($0.title) } } ?? all
        XCTAssertEqual(picked.count, names?.count ?? 22, "every named theme found")
        for d in picked {
            let p = ThemePalette.load(for: d)
            ThemeRuntime.palette = p
            try body(d, p)
        }
    }

    func rgba(_ c: Color) -> RGBA {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }
    /// `c` drawn over the opaque `b` at its own alpha.
    func onto(_ b: RGBA, _ c: Color) -> RGBA {
        let f = rgba(c)
        return (b.r * (1 - f.a) + f.r * f.a, b.g * (1 - f.a) + f.g * f.a, b.b * (1 - f.a) + f.b * f.a, 1)
    }
    func ns(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
    func dist(_ a: RGBA, _ b: RGBA) -> CGFloat { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) }

    // MARK: Contrast

    /// Every island ink over the surface it is drawn on, on all 22 themes: 4.5:1, 3:1 for the dim cues and marks
    /// (the state glyphs, the answer buttons' digit, hint and detail). Inks with an alpha are composited first; the bound
    /// and the helper are the sidebar rows' (AgentRowSelectedTextTests, ThemeContrastTests.contrast). TIP: no
    /// AgentIslandInk or AgentPromptCardView.look (the inks were white: `line($0, Color.white)` on a daylight card is 1.1:1,
    /// the History row's `Color.white.opacity(0.4)` age on a light sidebar under 1.5:1).
    func testEveryIslandInkReadsOnItsSurfaceOnEveryTheme() throws {
        var pairs = 0
        try onThemes { d, p in
            let black: RGBA = (0, 0, 0, 1)
            let card = rgba(AgentIslandRow.cardFill), sel = onto(card, p.blue.opacity(0.14))
            XCTAssertLessThan(dist(card, rgba(p.sidebar)), 0.001, "\(d.title): the card is the sidebar surface")
            XCTAssertLessThan(dist(rgba(AgentPromptCardView.cardFill), card), 0.001, "\(d.title): the prompt card is the row's")
            let accent = AgentPromptCardView.look(.accent), deny = AgentPromptCardView.look(.deny)
            let plain = AgentPromptCardView.look(.plain)
            let accentFill = onto(card, accent.fill), denyFill = onto(card, deny.fill), wash = onto(card, plain.fill)
            let quiet = AgentSidebarRowView.ink(.quiet, selected: false), lit = AgentSidebarRowView.ink(.quiet, selected: true)
            let inks: [(String, Color, RGBA, Double)] = [
                // On the black shape.
                ("shown tab", AgentIslandInk.selectedTab, black, 4.5),
                ("blocked glyph", AgentIslandInk.glyph(.blocked), black, 3),
                ("working glyph", AgentIslandInk.glyph(.working), black, 3),
                ("done glyph", AgentIslandInk.glyph(.done), black, 3),
                // The History row's card, and hovered.
                ("history title", Neon.textPrimary, card, 4.5),
                ("history quiet (glyph, age, end, cwd, status, icons)", quiet, card, 4.5),
                ("history crash", AgentIslandInk.blockedOnCard, card, 4.5),
                ("history pinned pin", Neon.textPrimary, card, 4.5),
                ("history hovered", lit, sel, 4.5),
                ("history hovered title", Neon.textPrimary, sel, 4.5),
                // The prompt card.
                ("question", Neon.textPrimary, card, 4.5),
                ("caption", AgentIslandInk.blockedOnCard, card, 4.5),
                ("context", Neon.textSecondary, onto(card, AgentPromptCardView.contextFill), 4.5),
                ("accent answer", accent.text, accentFill, 4.5),
                ("accent dim", accent.dim, accentFill, 3),
                ("accent hint", accent.dim, onto(accentFill, AgentPromptCardView.hintFill), 3),
                ("accent detail lines", AgentPromptCardView.detailInk(.accent), accentFill, 4.5),
                ("deny answer", deny.text, denyFill, 4.5),
                ("deny dim", deny.dim, denyFill, 3),
                ("deny hint", deny.dim, onto(denyFill, AgentPromptCardView.hintFill), 3),
                ("deny detail lines", AgentPromptCardView.detailInk(.deny), denyFill, 4.5),
                ("plain answer", plain.text, wash, 4.5),
                ("plain dim", plain.dim, wash, 3),
                ("plain hint", plain.dim, onto(wash, AgentPromptCardView.hintFill), 3),
                ("plain detail lines", AgentPromptCardView.detailInk(.plain), wash, 4.5),
                ("open terminal", Neon.textPrimary, onto(card, AgentPromptCardView.wash), 4.5),
                // The composer's field.
                ("draft", Neon.textPrimary, card, 4.5),
                ("draft placeholder", Neon.textSecondary, card, 4.5),
            ]
            for (name, ink, surface, floor) in inks {
                let r = ThemeContrastTests.contrast(ns(onto(surface, ink)), on: ns(surface))
                XCTAssertGreaterThanOrEqual(r, CGFloat(floor), "\(d.title): \(name) is \(r):1")
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 22 * 28)
    }

    // MARK: Cards

    var width: CGFloat { AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset }

    func session(open: Int = 0) -> AgentSession {
        var s = AgentSession(key: AgentSessionKey(dir: "/Users/example/work", name: "api"), alias: "",
                             activity: Self.now - 240, state: .idle, agents: 3)
        s.transcriptPath = "/Users/example/t.jsonl"
        s.model = "claude-opus-4-5"
        s.effort = "high"
        if open > 0 {
            s.meta = DchSessionMeta(openPRs: (1...open).map {
                .init(url: "https://github.com/example/api/pull/\($0)", repo: "example/api", num: $0, title: "") })
        }
        return s
    }

    func record() -> DchHistoryRecord {
        DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "api"), cwd: "/src", updated: Self.now - 60,
                         ended: Self.now - 60, end: "signal 9")
    }

    /// Renders `view` over black in a never-shown host; the pixel at `at` (points).
    func pixel<V: View>(_ view: V, size: CGSize, at: CGPoint) -> RGBA? {
        let root = ZStack(alignment: .topLeading) { Color.black; view }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: size)
        return pixel(h, at: at)
    }

    func pixel(_ h: NSView, at: CGPoint) -> RGBA? {
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        h.layoutSubtreeIfNeeded()
        guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { return nil }
        h.cacheDisplay(in: h.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / h.bounds.width
        guard let c = rep.colorAt(x: Int(at.x * k), y: Int(at.y * k))?.usingColorSpace(.sRGB) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent, 1)
    }

    /// The History row draws the session row's card (the sidebar surface) on a dark, a light and a high-contrast theme:
    /// the pixel inside both cards' straight leading edge, left of the glyph. TIP: `.fill(Color.white.opacity(hover &&
    /// enabled ? 0.10 : 0.05))`, a near-black grey over the island's black on every theme.
    func testTheHistoryRowCardIsTheSessionRowCard() throws {
        try onThemes(["Default", "theme-daylight", "theme-contrast-dark"]) { d, p in
            let size = CGSize(width: width, height: AgentIslandGeometry.rowHeight)
            let at = CGPoint(x: 4, y: size.height / 2)
            let hist = try XCTUnwrap(pixel(AgentIslandHistoryRow(record: record(), now: Self.now, status: nil, enabled: true,
                                                                  action: {}).frame(width: width), size: size, at: at), d.title)
            let live = try XCTUnwrap(pixel(AgentIslandRow(session: session(), now: Self.now, notice: nil, show: .all) {}
                                            .frame(width: width), size: size, at: at), d.title)
            XCTAssertLessThan(dist(hist, live), 0.03, "\(d.title): History card \(hist), session card \(live)")
            XCTAssertLessThan(dist(hist, rgba(p.sidebar)), 0.03, "\(d.title): the History card is the sidebar, read \(hist)")
        }
    }

    // MARK: The ruling

    /// The operator's ruling: the notch shape stays black, collapsed and expanded, on a dark and a light theme (its
    /// middle, under the hardware notch, has no content). A shape in the theme's surface reads the light sidebar there.
    func testTheNotchShapeStaysBlackOnEveryLook() throws {
        let geometry = AgentIslandGeometry.make(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
            safeTop: 32)
        try onThemes(["Default", "theme-daylight"]) { d, _ in
            for expanded in [false, true] {
                let store = AgentIslandStore(geometry: geometry)
                store.sessions = [session()]
                store.expanded = expanded
                let size = store.size
                let h = NSHostingView(rootView: ZStack { Color.white; AgentIslandView(store: store) }
                    .frame(width: size.width, height: size.height))
                h.frame = CGRect(origin: .zero, size: size)
                let px = try XCTUnwrap(pixel(h, at: CGPoint(x: size.width / 2, y: geometry.barHeight / 2)), d.title)
                XCTAssertLessThan(dist(px, (0, 0, 0, 1)), 0.03, "\(d.title) expanded \(expanded): the shape is black, read \(px)")
            }
        }
    }

    // MARK: Riders from #1371

    /// R1371-i2: a theme switch (ThemeStore publishes) redraws the island row's card with no new list answer: the same
    /// hosted row, the palette swapped, the card's pixel follows. TIP: AgentIslandRow did not observe ThemeStore, so its
    /// body (and `.fill(Self.cardFill)`) was not re-run until the store changed.
    func testAThemeSwitchRedrawsTheRowCardWithNoListAnswer() throws {
        let all = try themes()
        let dark = try XCTUnwrap(all.first { $0.title == "Default" }), light = try XCTUnwrap(all.first { $0.title == "theme-daylight" })
        _ = ThemeStore.shared
        let (savedPalette, savedIC) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast)
        defer { ThemeRuntime.palette = savedPalette; ThemeRuntime.increaseContrast = savedIC; ThemeStore.shared.objectWillChange.send() }
        ThemeRuntime.increaseContrast = false
        let (pd, pl) = (ThemePalette.load(for: dark), ThemePalette.load(for: light))
        ThemeRuntime.palette = pd
        let size = CGSize(width: width, height: AgentIslandGeometry.rowHeight)
        let root = ZStack(alignment: .topLeading) {
            Color.black
            AgentIslandRow(session: session(), now: Self.now, notice: nil, show: .all) {}.frame(width: width)
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
        let (win, h) = AXTreeSupport.hosted(root, size)   // a borderless window that is never shown
        defer { XCTAssertFalse(win.isVisible, "never on screen"); win.contentView = nil; win.close() }
        let at = CGPoint(x: 4, y: size.height / 2)
        // The window-backed bitmap is colour-matched to the window's screen (about 0.04 off sRGB, ticket 2), so each read
        // is placed by which sidebar it is nearer; the two sidebars are 2.6 apart (sum of the sRGB channels).
        let (dk, lt) = (rgba(pd.sidebar), rgba(pl.sidebar))
        let before = try XCTUnwrap(pixel(h, at: at))
        XCTAssertLessThan(dist(before, dk), 0.1, "the dark card first, read \(before)")
        ThemeRuntime.palette = pl
        ThemeStore.shared.objectWillChange.send()
        let after = try XCTUnwrap(pixel(h, at: at))
        XCTAssertLessThan(dist(after, lt), 0.1, "after the switch the light card, read \(after)")
        XCTAssertLessThan(dist(after, lt), dist(after, dk), "nearer the light sidebar than the dark one, read \(after)")
    }

    /// R1371-s1: the island row speaks the model, the effort and the open count it now shows, in the sidebar's words
    /// (Row.modelWords, Count.open). TIP's label (AgentIsland.rowAccessibilityLabel) is kept in front, unchanged.
    func testTheRowSpeaksTheModelEffortAndOpenCount() throws {
        let s = session(open: 2)
        let old = AgentIsland.rowAccessibilityLabel(s, now: Self.now, show: .all)
        XCTAssertFalse(old.contains("model"), "TIP's label has no model: \(old)")
        XCTAssertFalse(old.contains("2 open pull requests"), "TIP's label has no open count (it names the chips): \(old)")
        let label = AgentIslandRow.accessibilityLabel(s, now: Self.now, show: .all)
        XCTAssertEqual(label, old + ", model Opus 4.5, effort high, 2 open pull requests")
        // No model, no PRs: nothing appended.
        var bare = session()
        bare.model = nil
        bare.effort = nil
        XCTAssertEqual(AgentIslandRow.accessibilityLabel(bare, now: Self.now, show: .all),
                       AgentIsland.rowAccessibilityLabel(bare, now: Self.now, show: .all))
        // The hosted row's element reads it (never shown).
        // AXTreeSupport.tree: a never-shown borderless window, this process's AX flags on and put back, polled to 5 s.
        let nodes = AXTreeSupport.tree(AgentIslandRow(session: s, now: Self.now, notice: nil, show: .all) {}.frame(width: width),
                                       CGSize(width: width, height: AgentIslandGeometry.prRowHeight)) { $0.contains { $0.label == label } }
        XCTAssertTrue(nodes.contains { $0.label == label }, "the row's element speaks it; read \(nodes.map(\.label).filter { !$0.isEmpty }.prefix(6))")
    }
}
