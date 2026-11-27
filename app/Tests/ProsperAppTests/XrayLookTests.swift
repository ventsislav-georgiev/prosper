import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2041: the X-ray drawer and its cards take the Agent Island's dark look by default (Settings > Agent Island > X-ray >
/// Follow theme, off), stand apart from the terminal they overlay, and follow the theme when the switch is on. Scratch
/// defaults only (Preferences.defaults is a temp suite under XCTest); views render in never-shown hosts. Fakes only.
@MainActor
final class XrayLookTests: XCTestCase {
    typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    static let key = "xrayFollowsTheme"
    private static var saved: Any?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            Self.saved = Preferences.defaults.object(forKey: Self.key)
            Preferences.defaults.removeObject(forKey: Self.key)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let v = Self.saved { Preferences.defaults.set(v, forKey: Self.key) } else { Preferences.defaults.removeObject(forKey: Self.key) }
        }
        super.tearDown()
    }

    func rgba(_ c: Color) -> RGBA {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }
    func dist(_ a: RGBA, _ b: RGBA) -> CGFloat { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) + abs(a.a - b.a) }
    func same(_ a: Color, _ b: Color) -> Bool { dist(rgba(a), rgba(b)) < 0.003 }
    /// `c` composited over the opaque `ground`.
    func onto(_ ground: Color, _ c: Color) -> Color {
        let g = rgba(ground), f = rgba(c)
        return Color(.sRGB, red: g.r * (1 - f.a) + f.r * f.a, green: g.g * (1 - f.a) + f.g * f.a, blue: g.b * (1 - f.a) + f.b * f.a)
    }

    /// The bundled theme `name`, loaded as AgentIslandFollowThemeTests loads it.
    func palette(_ name: String) throws -> ThemePalette {
        if name == "Default" { return ThemePalette.load(for: .builtIn) }
        let json = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions/\(name)/theme.json")
        let spec = try ThemeSpec.decode(Data(contentsOf: json))
        return ThemePalette.load(for: ThemeDescriptor(id: "test.2041.\(name)", title: name, appearance: spec.appearance,
                                                      extensionID: "test.2041", jsonPath: json))
    }

    /// Runs `body` on a dark and a light theme, Increase Contrast off, the palette put back after.
    func onTwoThemes(_ body: (String, ThemePalette) throws -> Void) throws {
        _ = ThemeStore.shared
        let (savedPalette, savedIC) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast)
        defer { ThemeRuntime.palette = savedPalette; ThemeRuntime.increaseContrast = savedIC }
        ThemeRuntime.increaseContrast = false
        for name in ["Default", "theme-daylight"] {
            let p = try palette(name)
            ThemeRuntime.palette = p
            try body(name, p)
        }
    }

    /// Terminal backgrounds: Prosper's vivid pair (black for a dark theme, white for a light one) and a few common terminal
    /// themes' (a user's own Ghostty colours), dark, light and mid grey.
    static let terminals = ["#000000", "#ffffff", "#1e1e2e", "#282c34", "#002b36", "#fdf6e3", "#767676"]

    // MARK: The setting

    /// Unset reads off; the key is per Mac (not synced). Parent: no setting, the drawer always drew the theme.
    func testFollowThemeIsOffByDefaultAndPerMac() {
        XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil, "unset in the scratch suite")
        Preferences.xrayFollowsTheme = false
        XCTAssertEqual(Preferences.defaults.object(forKey: Self.key) as? Bool, false, "stored under its key")
        Preferences.defaults.removeObject(forKey: Self.key)
        XCTAssertFalse(Preferences.xrayFollowsTheme)
        XCTAssertFalse(XrayInk.follows)
        XCTAssertFalse(SyncedKeys.isSynced(Self.key), "per Mac")
        Preferences.xrayFollowsTheme = true
        XCTAssertTrue(XrayInk.follows, "the switch reads the stored Bool")
    }

    /// The Settings row: "Follow theme" in an "X-ray" section on the Agent Island page, a checkbox read from a never-shown
    /// host's accessibility tree; hosting it stores nothing; flipping the setting changes the resolved colours.
    func testTheSettingsRowExistsAndFlippingItChangesTheColours() throws {
        XCTAssertEqual(XrayLookSection.title, "X-ray")
        XCTAssertEqual(XrayLookSection.label, "Follow theme")
        let size = CGSize(width: 520, height: 160)
        let want = "X-ray \(XrayLookSection.label)"
        let nodes = AXTreeSupport.tree(XrayLookSection().frame(width: size.width), size) {
            $0.contains { $0.label == want && $0.role == "AXCheckBox" }
        }
        XCTAssertTrue(nodes.last { $0.label == want && $0.role == "AXCheckBox" } != nil,
                      "an X-ray Follow theme checkbox; read \(nodes.map { "\($0.role) \($0.label)" }.prefix(8))")
        XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil, "the section seeds off and stores nothing")
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/SettingsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("AgentSessionsSection()\n                XrayLookSection()"), "the section is on the Agent Island page")
        try onTwoThemes { name, _ in
            let off = (XrayInk.textPrimary, XrayInk.surface)
            Preferences.xrayFollowsTheme = true
            let on = (XrayInk.textPrimary, XrayInk.surface)
            Preferences.xrayFollowsTheme = false
            XCTAssertFalse(same(off.0, on.0), "\(name): the text ink changed")
            XCTAssertFalse(same(off.1, on.1), "\(name): the fill changed")
        }
    }

    // MARK: Off

    /// Off, on a dark and a light theme alike: the island's own inks (AgentIslandInk's constants), its hairline outline and
    /// card, and a near-black fill. Parent: the theme's Neon tokens (theme-daylight's light card and dark text).
    func testOffResolvesToTheIslandColoursOnTwoThemes() throws {
        try onTwoThemes { name, _ in
            XCTAssertTrue(same(XrayInk.textPrimary, AgentIslandInk.white(1)), "\(name): primary")
            XCTAssertTrue(same(XrayInk.textSecondary, AgentIslandInk.white(0.7)), "\(name): secondary")
            XCTAssertTrue(same(XrayInk.stroke, AgentIslandInk.white(0.14)), "\(name): divider")
            XCTAssertTrue(same(XrayInk.card, AgentIslandInk.cardFill(selected: false)), "\(name): inner card")
            XCTAssertTrue(same(AgentIslandInk.cardFill(selected: false), AgentIslandHistoryRow.ownCardFill(selected: false)),
                          "the island's own card is the shared one")
            XCTAssertEqual(XrayInk.edgeColors.count, 2)
            for c in XrayInk.edgeColors {
                XCTAssertTrue(same(c, AgentIslandInk.hairline), "\(name): the island's hairline")
                XCTAssertGreaterThanOrEqual(rgba(c).a, 0.2, "\(name): a visible outline")
                XCTAssertGreaterThan(rgba(c).r, 0.9, "\(name): a light outline")
            }
            let fill = rgba(XrayInk.surface)
            XCTAssertTrue(same(XrayInk.surface, XrayInk.surface(base: AgentIslandInk.panel, over: XrayInk.terminalBackground)),
                          "\(name): the island's black lifted off the terminal")
            XCTAssertLessThan(max(fill.r, fill.g, fill.b), 0.15, "\(name): a dark island fill, read \(fill)")
            XCTAssertEqual(fill.a, 1, "opaque")
        }
    }

    // MARK: On

    /// On: the theme's tokens, and the theme's card as the fill where it already stands apart from the terminal (Default
    /// on black 1.19:1, theme-daylight on white). Parent: the same tokens, the edge Neon.stroke.
    func testOnResolvesToTheThemesColours() throws {
        Preferences.xrayFollowsTheme = true
        try onTwoThemes { name, p in
            XCTAssertTrue(same(XrayInk.textPrimary, p.textPrimary), "\(name): primary")
            XCTAssertTrue(same(XrayInk.textSecondary, p.textSecondary), "\(name): secondary")
            XCTAssertTrue(same(XrayInk.stroke, Neon.stroke), "\(name): divider")
            XCTAssertEqual(XrayInk.edgeColors.count, Neon.cardStrokeColors.count)
            XCTAssertTrue(zip(XrayInk.edgeColors, Neon.cardStrokeColors).allSatisfy { same($0, $1) }, "\(name): the card stroke")
            XCTAssertGreaterThan(rgba(XrayInk.edgeColors.first ?? .clear).a, rgba(Neon.stroke).a, "\(name): stronger than the old edge")
            let fill = XrayInk.surface
            XCTAssertGreaterThanOrEqual(ThemeRuntime.contrastRatio(fill, XrayInk.terminalBackground), XrayInk.minTerminalContrast)
            if name == "Default" { XCTAssertTrue(same(fill, p.card), "Default: the theme's card, read \(rgba(fill))") }
        }
    }

    // MARK: Set apart from the terminal

    /// The fill over each terminal background, from the island's black and from two themes' cards, is at least
    /// `minTerminalContrast` (1.18:1, about 8 L* units on black) from the terminal; off on black it is also that far from the
    /// island's own black. Parent: the drawer drew Neon.card whatever the terminal (no lift).
    func testTheFillStandsApartFromTheTerminal() throws {
        XCTAssertGreaterThanOrEqual(XrayInk.minTerminalContrast, 1.18, "a visible step")
        let bases: [(String, Color)] = [("island", AgentIslandInk.panel), ("Default card", ThemePalette.default.card),
                                        ("daylight card", try palette("theme-daylight").card)]
        for (b, base) in bases {
            for hex in Self.terminals {
                let t = try XCTUnwrap(Color(hex: hex))
                let r = ThemeRuntime.contrastRatio(XrayInk.surface(base: base, over: t), t)
                XCTAssertGreaterThanOrEqual(r, XrayInk.minTerminalContrast, "\(b) over \(hex): \(r):1")
            }
        }
        let offOnBlack = XrayInk.surface(base: AgentIslandInk.panel, over: .black)
        XCTAssertGreaterThanOrEqual(ThemeRuntime.contrastRatio(offOnBlack, AgentIslandInk.panel), XrayInk.minTerminalContrast,
                                    "distinct from the island's own black")
        XCTAssertFalse(same(offOnBlack, AgentIslandInk.panel), "lifted")
    }

    /// Text on the off fill reads at least as well as today's themed drawer (Default: textSecondary on card 6.5:1,
    /// textPrimary 15.6:1), Increase Contrast off.
    func testOffTextContrastIsAtLeastTodays() throws {
        try onTwoThemes { name, _ in
            let d = ThemePalette.default, fill = XrayInk.surface
            for (ink, before) in [(XrayInk.textPrimary, d.textPrimary), (XrayInk.textSecondary, d.textSecondary)] {
                let now = ThemeRuntime.contrastRatio(onto(fill, ink), fill), then = ThemeRuntime.contrastRatio(before, d.card)
                XCTAssertGreaterThanOrEqual(now, then, "\(name): \(now):1 against \(then):1")
            }
        }
    }

    /// The fill is worked out once per theme or setting change, never per read (a body reads it on every redraw).
    func testTheFillResolvesOncePerChange() throws {
        _ = XrayInk.surface
        let start = XrayInk.resolves
        for _ in 0..<100 { _ = XrayInk.surface }
        XCTAssertEqual(XrayInk.resolves, start, "100 reads, no new work")
        Preferences.xrayFollowsTheme = true
        for _ in 0..<100 { _ = XrayInk.surface }
        XCTAssertEqual(XrayInk.resolves, start + 1, "one setting change, one resolve")
    }

    /// Records the colour scheme its environment gives it.
    struct SchemeProbe: View {
        @Environment(\.colorScheme) var scheme
        let seen: (ColorScheme) -> Void
        var body: some View { seen(scheme); return Color.clear }
    }

    /// The scheme a probe reads under XrayIslandScheme, hosted (never shown) in a light-scheme environment.
    func scheme() -> ColorScheme? {
        var got: ColorScheme?
        let h = NSHostingView(rootView: SchemeProbe { got = $0 }.modifier(XrayIslandScheme()).environment(\.colorScheme, .light)
            .frame(width: 10, height: 10))
        h.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        h.layoutSubtreeIfNeeded()
        return got
    }

    /// Off, the drawer's and the card's native controls take the dark scheme on a light theme (the island's pin); on, the
    /// environment's scheme is left alone. Parent: no modifier, the theme's light scheme under a dark surface. Both the drawer
    /// and the card host apply it (source anchors).
    func testOffPinsTheDarkSchemeAndOnLeavesIt() throws {
        XCTAssertEqual(scheme(), .dark, "off: dark")
        Preferences.xrayFollowsTheme = true
        XCTAssertEqual(scheme(), .light, "on: the environment's own")
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AgentWindow")
        for f in ["XrayPanel.swift", "XrayCardPresenter.swift"] {
            let src = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            XCTAssertTrue(src.contains(".modifier(XrayIslandScheme())"), "\(f) applies the scheme")
        }
    }

    /// The drawer and the card draw the fill, the outline and the drawer's shade on the terminal side (source anchors: the
    /// views are hosted inside the Agent Sessions window, out of reach of a never-shown host).
    func testTheDrawerAndCardDrawTheOutline() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AgentWindow")
        let panel = try String(contentsOf: dir.appendingPathComponent("XrayPanel.swift"), encoding: .utf8)
        let card = try String(contentsOf: dir.appendingPathComponent("XrayCardPresenter.swift"), encoding: .utf8)
        for s in [".background(XrayInk.surface)", "Rectangle().fill(XrayInk.edge).frame(width: 1)", "XrayDrawer.shade.frame("] {
            XCTAssertTrue(panel.contains(s), "the drawer: \(s)")
        }
        for s in ["shape.fill(XrayInk.surface)", "shape.strokeBorder(XrayInk.edge, lineWidth: 1)", "p.hasShadow = true"] {
            XCTAssertTrue(card.contains(s), "the card: \(s)")
        }
    }

    // MARK: #2043 the accent on the black surface

    func ratio(_ c: Color, _ s: Color) -> Double { Double(ThemeContrastTests.contrast(NSColor(c), on: NSColor(s))) }

    /// `body` under the default palette with the accent set to `hex` (the palette and the Increase Contrast flag put back).
    func withAccent(_ hex: String?, _ body: () -> Void) {
        _ = ThemeStore.shared
        let (saved, ic) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast)
        defer { ThemeRuntime.palette = saved; ThemeRuntime.increaseContrast = ic }
        ThemeRuntime.increaseContrast = false
        var p = ThemePalette.default
        if let hex, let c = Color(hex: hex) { p.blue = c }
        ThemeRuntime.palette = p
        body()
    }

    /// Off, a dark accent (#1A237E, about 1.5:1 on black) is replaced where it is text, an icon or a mark (4.5:1: the answer
    /// button and the Answer mark) and where it is a ring or tint (3:1: the chip, the tab, the recommended chip). Red at base:
    /// those sites drew Neon.blue (XrayPanel.swift:1586/1587/1612/1692/1766, XrayAnswer.swift:256/257).
    func testOffADarkAccentIsReplacedOnTheSurface() {
        withAccent("#1A237E") {
            let surface = XrayInk.surface
            XCTAssertLessThan(ratio(Neon.blue, surface), 3, "the fixture: the accent alone is unreadable")
            XCTAssertGreaterThanOrEqual(ratio(XrayInk.accentInk, surface), 4.5, "text and icon sites")
            XCTAssertGreaterThanOrEqual(ratio(XrayInk.accentRing, surface), 3, "ring and tint sites")
            XCTAssertFalse(same(XrayInk.accentInk, Neon.blue))
        }
    }

    /// A mid accent (#707070, about 3.6:1 on the black surface): too faint for text (4.5:1), enough for a ring (3:1).
    func testOffAMidAccentIsKeptOnlyWhereThreeToOneIsEnough() {
        withAccent("#707070") {
            let surface = XrayInk.surface
            XCTAssertTrue((3..<4.5).contains(ratio(Neon.blue, surface)), "the fixture: between the two thresholds")
            XCTAssertFalse(same(XrayInk.accentInk, Neon.blue), "text: replaced")
            XCTAssertTrue(same(XrayInk.accentRing, Neon.blue), "ring: kept")
        }
    }

    /// Off with the default theme the accent stays Neon.blue (same look as before).
    func testOffTheDefaultAccentIsUnchanged() {
        withAccent(nil) {
            XCTAssertTrue(same(XrayInk.accentInk, Neon.blue))
            XCTAssertTrue(same(XrayInk.accentRing, Neon.blue))
        }
    }

    /// On, the accent is the theme's whatever its contrast.
    func testOnKeepsTheAccentWhateverTheTheme() {
        Preferences.xrayFollowsTheme = true
        withAccent("#1A237E") {
            XCTAssertTrue(same(XrayInk.accentInk, Neon.blue))
            XCTAssertTrue(same(XrayInk.accentRing, Neon.blue))
        }
    }

    /// The check runs once per theme or setting change, never per row per frame.
    func testTheAccentIsCheckedOncePerChange() {
        withAccent("#1A237E") {
            _ = XrayInk.accentInk
            let start = XrayInk.accentResolves
            for _ in 0..<100 { _ = XrayInk.accentInk; _ = XrayInk.accentRing }
            XCTAssertEqual(XrayInk.accentResolves, start, "200 reads, no new check")
            ThemeRuntime.palette.blue = Color(hex: "#0D1B5E") ?? .blue
            for _ in 0..<100 { _ = XrayInk.accentInk }
            XCTAssertEqual(XrayInk.accentResolves, start + 1, "one theme change, one check")
        }
    }

    /// Every listed site draws through XrayInk and none through the raw accent (source anchors: the views live in the window).
    func testTheAccentSitesRouteThroughXrayInk() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AgentWindow")
        let want: [(String, String, Int)] = [("XrayPanel.swift", ".foregroundStyle(XrayInk.accentInk)", 2),
                                             ("XrayPanel.swift", "XrayInk.accentRing.opacity", 3),
                                             ("XrayAnswer.swift", "XrayInk.accentRing.opacity", 2),
                                             // #2049: the cards' rich text, the ref card's tabs and sentence, the chapter
                                             // card's ref underline, all in the card panel on XrayInk.surface
                                             ("XrayRichText.swift", "? XrayInk.accentInk : XrayInk.textPrimary", 1),
                                             ("XrayRichText.swift", "XrayInk.accentRing.opacity(0.24)", 1),
                                             ("XrayRefPopover.swift", "XrayInk.accentRing.opacity(0.2)", 1),
                                             ("XrayRefPopover.swift", ".foregroundColor(XrayInk.accentInk)", 1),
                                             ("XrayChapterCard.swift", "color: XrayInk.accentRing)", 1)]
        for (f, needle, n) in want {
            let src = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            XCTAssertEqual(src.components(separatedBy: needle).count - 1, n, "\(f): \(needle)")
            XCTAssertFalse(src.contains("foregroundStyle(Neon.blue)") || src.contains("Neon.blue.opacity"), "\(f): no raw accent")
        }
        for f in ["XrayRichText.swift", "XrayRefPopover.swift", "XrayChapterCard.swift"] {   // #2049: no Neon.blue in any form
            XCTAssertFalse(try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8).contains("Neon.blue"), "\(f): no raw accent")
        }
        // QA R2043: the recap strip sits on the theme's card, not the black surface, so it keeps the theme's accent.
        let recap = try String(contentsOf: dir.appendingPathComponent("XrayRecap.swift"), encoding: .utf8)
        XCTAssertEqual(recap.components(separatedBy: ".foregroundStyle(Neon.blue)").count - 1, 3, "XrayRecap keeps Neon.blue")
        XCTAssertFalse(recap.contains("XrayInk.accent"), "XrayRecap: no X-ray surface ink on the theme card")
    }

    /// #2049: off, a card's link text and the filter's highlight take the readable accent, not the dark one. Red at base:
    /// XrayRichText.swift:162/164 drew Neon.blue.
    func testOffTheCardsRichTextTakesTheReadableAccent() {
        withAccent("#1A237E") {
            let a = XrayRich.attributed([XrayRich.Run(text: "docs", style: .link)], size: 11, match: "docs")
            let fg = a.runs.first?[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self]
            let bg = a.runs.first?[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self]
            XCTAssertEqual(a.runs.count, 1, "one hit run")
            XCTAssertTrue(fg.map { same($0, XrayInk.accentInk) } ?? false, "link text: accentInk")
            XCTAssertTrue(fg.map { !same($0, Neon.blue) } ?? false, "link text: not the dark accent")
            XCTAssertTrue(bg.map { same($0, XrayInk.accentRing.opacity(0.24)) } ?? false, "highlight: accentRing")
            XCTAssertTrue(bg.map { !same($0, Neon.blue.opacity(0.24)) } ?? false, "highlight: not the dark accent")
        }
    }
}
