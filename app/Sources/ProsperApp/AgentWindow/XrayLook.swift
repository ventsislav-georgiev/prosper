import AppKit
import SwiftUI

/// #2041: the X-ray drawer's and its cards' colours. Settings > Agent Island > X-ray > Follow theme, off by default
/// (Preferences.xrayFollowsTheme, per Mac, as #1452's island switch): off, the Agent Island's dark look (AgentIslandInk's
/// panel, card fill, white inks and hairline); on, the theme's tokens with the stronger card edge. Either way the surface
/// is lifted off the terminal it overlays (`surface(base:over:)`). A change redraws as a theme switch does (ThemeStore).
@MainActor
enum XrayInk {
    static var follows: Bool { Preferences.xrayFollowsTheme }

    /// Off, full white: at least the themed default's 15.6:1 (17.4:1 on the lifted black); secondary 9.0:1 against 6.5:1.
    static var textPrimary: Color { follows ? Neon.textPrimary : AgentIslandInk.white(1) }
    static var textSecondary: Color { follows ? Neon.textSecondary : AgentIslandInk.white(0.7) }
    /// A divider or a chip's ring inside the drawer or a card.
    static var stroke: Color { follows ? Neon.stroke : AgentIslandInk.white(0.14) }
    /// The outline round the drawer and each card, top-leading end first: the island's hairline; on, the card stroke's
    /// ends (Neon.cardStroke, 0.38 accent against Neon.stroke's 0.16, which the drawer's edge drew before #2041).
    static var edgeColors: [Color] { follows ? Neon.cardStrokeColors : [AgentIslandInk.hairline, AgentIslandInk.hairline] }
    static var edge: LinearGradient { LinearGradient(colors: edgeColors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    /// An inner rounded card or section (the island's white 5% card).
    static var card: Color { follows ? Neon.textSecondary.opacity(0.08) : AgentIslandInk.cardFill(selected: false) }

    /// The least WCAG ratio between the surface and the terminal under it: about 8 L* units against black (#171717),
    /// a step the eye reads at once, while the themed default card (1.19:1 on black) keeps its own colour.
    static let minTerminalContrast = 1.18

    /// The terminal's background under the drawer: Prosper's vivid pair for the theme's appearance (AgentTerminalLook).
    /// shortcut: "My Ghostty colours" is not read here (a file read per theme change), so it counts as Prosper's; upgrade
    /// when the terminal controller exposes its resolved background.
    static var terminalBackground: Color {
        Color(hex: AgentTerminalLook.vivid(ThemeStore.shared.appearance).background) ?? .black
    }

    private struct Key: Equatable { let follows: Bool; let palette: ThemePalette; let terminal: Color }
    private static var memo: (key: Key, fill: Color)?
    /// Tests only: how many times `surface` was worked out (a memo miss).
    static var resolves = 0

    /// The drawer's and the cards' fill, resolved once per theme, appearance or setting change (never per draw).
    static var surface: Color {
        let key = Key(follows: follows, palette: ThemeRuntime.palette, terminal: terminalBackground)
        if let m = memo, m.key == key { return m.fill }
        let fill = surface(base: follows ? Neon.card : AgentIslandInk.panel, over: key.terminal)
        memo = (key, fill)
        resolves += 1
        return fill
    }

    private struct AccentKey: Equatable { let accent: Color; let surface: Color }
    private static var accentMemo: (key: AccentKey, text: Color, mark: Color)?
    /// Tests only: how many times the accent was checked against the surface (a memo miss).
    static var accentResolves = 0

    /// #2043: off, the theme's accent drawn on the black surface only where it reads (4.5:1 for text or an icon, 3:1 for a
    /// ring or a tint), else the island's white; on, the accent as it was. Checked once per theme or surface change.
    private static var accents: (text: Color, mark: Color) {
        guard !follows else { return (Neon.blue, Neon.blue) }
        let key = AccentKey(accent: Neon.blue, surface: surface)
        if let m = accentMemo, m.key == key { return (m.text, m.mark) }
        let fallback = AgentIslandInk.white(0.9)
        let text = AgentIslandInk.readable(key.accent, on: key.surface, else: fallback)
        let mark = AgentIslandInk.readable(key.accent, on: key.surface, else: fallback, dim: true)
        accentMemo = (key, text, mark)
        accentResolves += 1
        return (text, mark)
    }
    /// A button label, an icon or a mark drawn in the accent.
    static var accentInk: Color { accents.text }
    /// A chip or tab ring or tint in the accent.
    static var accentRing: Color { accents.mark }

    /// `base` drawn opaque over `terminal`, then moved away from it (toward white on a dark terminal, toward black on a
    /// light one) in 1% steps until the two are at least `minTerminalContrast` apart. A base already apart is kept.
    static func surface(base: Color, over terminal: Color) -> Color {
        let t = NSColor(terminal).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(base).usingColorSpace(.sRGB) ?? .black
        let opaque = t.blended(withFraction: b.alphaComponent, of: b.withAlphaComponent(1)) ?? b
        let away: NSColor = ThemeRuntime.contrastRatio(Color(nsColor: t), .black) < ThemeRuntime.contrastRatio(Color(nsColor: t), .white)
            ? .white : .black
        for step in 0...100 {
            let c = opaque.blended(withFraction: Double(step) / 100, of: away) ?? away
            if ThemeRuntime.contrastRatio(Color(nsColor: c), Color(nsColor: t)) >= minTerminalContrast { return Color(nsColor: c) }
        }
        return Color(nsColor: away)
    }
}

/// #2041: Follow theme off, X-ray's drawer and cards are dark on every theme (the island's look), so their native controls
/// (buttons, the filter field, pickers) take the dark scheme too, as the island does; on, nothing is pinned (the theme's).
/// The branch swaps the view when the setting flips (a Settings change, never per draw).
struct XrayIslandScheme: ViewModifier {
    @ObservedObject var liveTheme = ThemeStore.shared   // a flip sends ThemeStore.objectWillChange

    func body(content: Content) -> some View {
        if XrayInk.follows { content } else { content.environment(\.colorScheme, .dark) }
    }
}
