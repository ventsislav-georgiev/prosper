import AppKit
import SwiftUI

// MARK: - Palette
//
// Prosper's whole look derives from twelve semantic colors. Every gradient,
// stroke, glow and shadow in SettingsTheme is built from these — so re-skinning
// the app is exactly "override some of these twelve". A theme that sets none of
// them is identical to the built-in default; a theme that sets `accent`/`blue`
// alone re-tints every neon edge in the UI.

/// The twelve themable colors. `Neon.*` reads the live copy from `ThemeRuntime`.
struct ThemePalette: Equatable, Sendable {
    var blue: Color
    var blueBright: Color
    var indigo: Color
    var magenta: Color
    var terminal: Color
    var bgTop: Color
    var bgBottom: Color
    var sidebar: Color
    var card: Color
    var cardHi: Color
    var textPrimary: Color
    var textSecondary: Color

    /// The built-in look — the byte-exact values that used to live as `static let`
    /// in `enum Neon`. This is the ultimate fallback: any token a theme omits
    /// resolves to this, so a partial theme can never produce a nil/black color.
    static let `default` = ThemePalette(
        blue:          Color(red: 0.13,  green: 0.80,  blue: 1.00),
        blueBright:    Color(red: 0.46,  green: 0.92,  blue: 1.00),
        indigo:        Color(red: 0.36,  green: 0.50,  blue: 1.00),
        magenta:       Color(red: 0.96,  green: 0.27,  blue: 0.69),
        terminal:      Color(red: 0.27,  green: 1.00,  blue: 0.71),
        bgTop:         Color(red: 0.043, green: 0.063, blue: 0.094),
        bgBottom:      Color(red: 0.020, green: 0.031, blue: 0.051),
        sidebar:       Color(red: 0.031, green: 0.047, blue: 0.075),
        card:          Color(red: 0.075, green: 0.098, blue: 0.137),
        cardHi:        Color(red: 0.106, green: 0.137, blue: 0.184),
        textPrimary:   Color(red: 0.91,  green: 0.95,  blue: 0.99),
        textSecondary: Color(red: 0.55,  green: 0.62,  blue: 0.73))

    /// Build a palette from a decoded theme spec: every key the spec provides
    /// overrides the default; every key it omits keeps the default. This is the
    /// partial-theme fallback (VS Code's "unset tokens use the base theme").
    static func resolve(_ spec: ThemeSpec) -> ThemePalette {
        var p = ThemePalette.default
        let c = spec.colors
        if let v = c["blue"]          { p.blue = v }
        if let v = c["blueBright"]    { p.blueBright = v }
        if let v = c["indigo"]        { p.indigo = v }
        if let v = c["magenta"]       { p.magenta = v }
        if let v = c["terminal"]      { p.terminal = v }
        if let v = c["bgTop"]         { p.bgTop = v }
        if let v = c["bgBottom"]      { p.bgBottom = v }
        if let v = c["sidebar"]       { p.sidebar = v }
        if let v = c["card"]          { p.card = v }
        if let v = c["cardHi"]        { p.cardHi = v }
        if let v = c["textPrimary"]   { p.textPrimary = v }
        if let v = c["textSecondary"] { p.textSecondary = v }
        return p
    }

    /// Resolve a descriptor's palette without applying it — used by the selector
    /// to render swatch previews. Falls back to the default for the built-in theme
    /// or any unreadable theme.json.
    static func load(for d: ThemeDescriptor) -> ThemePalette {
        guard let path = d.jsonPath,
              let data = try? Data(contentsOf: path),
              let spec = try? ThemeSpec.decode(data) else { return .default }
        return resolve(spec)
    }

    /// Recognized token names (for validation / docs). Order is display order.
    static let tokenNames = [
        "blue", "blueBright", "indigo", "magenta", "terminal",
        "bgTop", "bgBottom", "sidebar", "card", "cardHi",
        "textPrimary", "textSecondary",
    ]

    /// Channel-wise equality. SwiftUI `Color.==` is unreliable across colors built
    /// from different inits (literal default vs hex-parsed), so compare resolved
    /// sRGB components. Used to suppress redundant re-applies that would otherwise
    /// rebuild every window and drop scroll/focus state on a no-op rescan.
    func channelsEqual(_ other: ThemePalette) -> Bool {
        // Local (not a static) — a KeyPath array isn't Sendable, so a stored
        // static would trip strict-concurrency. Cheap to build; runs only on apply.
        let paths: [KeyPath<ThemePalette, Color>] = [
            \.blue, \.blueBright, \.indigo, \.magenta, \.terminal,
            \.bgTop, \.bgBottom, \.sidebar, \.card, \.cardHi,
            \.textPrimary, \.textSecondary,
        ]
        for kp in paths where !ThemePalette.sameColor(self[keyPath: kp], other[keyPath: kp]) {
            return false
        }
        return true
    }

    private static func sameColor(_ a: Color, _ b: Color) -> Bool {
        func comps(_ x: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let n = NSColor(x).usingColorSpace(.sRGB) ?? NSColor(x)
            return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
        }
        let l = comps(a), r = comps(b)
        return abs(l.0 - r.0) < 0.001 && abs(l.1 - r.1) < 0.001
            && abs(l.2 - r.2) < 0.001 && abs(l.3 - r.3) < 0.001
    }
}

// MARK: - Live runtime
//
// `Neon.*` reads this. It is a plain global, not the @MainActor store, so the
// non-isolated color accessors (e.g. `NSColor(Neon.bgTop)` in window setup)
// compile without actor hops. Single writer: `ThemeStore` (main thread only)
// assigns it inside `apply`. The value is a small value type, so a read can
// only ever see a fully-formed old or new palette, never a torn one.

enum ThemeRuntime {
    // ponytail: single-writer-on-main global, not a lock. ThemeStore is the only
    // writer and only on the main thread; readers are SwiftUI bodies (main) plus
    // a few main-thread AppKit setups. Value-type assignment is atomic enough for
    // that. If a background reader ever appears, switch to an os_unfair_lock box.
    nonisolated(unsafe) static var palette: ThemePalette = .default

    /// Global UI size multiplier. Every scalable dimension (font sizes, paddings,
    /// spacing, frames, corner radii, window widths) is read as `N * scale`, so
    /// `scale == 1.0` reproduces the original layout byte-for-byte. ThemeStore is
    /// the single writer; readers re-read on the `generation` rebuild, same as
    /// `palette`. See `Neon.font` / `sz` in SettingsTheme.swift.
    nonisolated(unsafe) static var scale: CGFloat = 1.0

    /// Global window opacity (0…1). Backdrops multiply their fill alpha by this so
    /// the desktop shows through below 1.0; `opacity == 1.0` is the original opaque
    /// look. AppKit windows flip `isOpaque` off below 1.0 via the onChange hook.
    nonisolated(unsafe) static var opacity: CGFloat = 1.0

    /// Frosted glass: when on, backdrops drop a `.behindWindow` blur of the desktop
    /// behind a translucent theme tint instead of fading. ThemeStore is the single
    /// writer; mirrors `Preferences.uiFrost`, forced off while system "Reduce
    /// transparency" is on. AppKit windows flip `isOpaque` off when set (the blur
    /// needs a non-opaque window), same onChange hook as `opacity`.
    nonisolated(unsafe) static var frost = false

    /// Densest glass tint — the alpha of the theme gradient over the frost blur at
    /// the 100% Transparency preset (preserves the original frost look). Lower presets
    /// thin it toward `frostTintMin` so more blurred desktop shows through. Never read
    /// raw on a render path; use `backdropFillOpacity`.
    nonisolated(unsafe) static let frostSurfaceOpacity: CGFloat = 0.6
    /// Thinnest glass tint, at the lowest Transparency preset. Floored above 0 so the
    /// neon palette never fully vanishes into the bare blur.
    nonisolated(unsafe) static let frostTintMin: CGFloat = 0.15

    /// Single source of truth for the alpha every window/panel backdrop fades its fill
    /// to. Non-frost: the plain transparency setting. Frost: the Transparency control
    /// tunes the glass density — it maps the opacity presets (1.0…0.7) onto a wide,
    /// visibly-distinct tint range (`frostSurfaceOpacity`…`frostTintMin`). The blur is
    /// dominant, so a narrow range reads as "no effect"; this spans enough that each
    /// preset clearly changes how much desktop shows. Content/text drawn ON TOP stays
    /// fully opaque either way. Read on every backdrop render — keep it pure arithmetic.
    static var backdropFillOpacity: CGFloat {
        guard frost else { return opacity }
        // Map the full Transparency range (lowest preset…1.0) onto the glass-tint range.
        // Floor comes from the one clamp definition so adding presets never desyncs it.
        let lo = CGFloat(Preferences.uiOpacityRange.lowerBound)
        let t = max(0, min(1, (opacity - lo) / (1 - lo)))
        return frostTintMin + t * (frostSurfaceOpacity - frostTintMin)
    }
}

// MARK: - Appearance

enum ThemeAppearance: String, Sendable, Equatable {
    case dark
    case light

    /// The AppKit appearance to force for this theme. Prosper windows render
    /// against this; a light theme flips them to aqua.
    var nsAppearanceName: NSAppearance.Name {
        self == .light ? .aqua : .darkAqua
    }

    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

// MARK: - Theme spec (decoded JSON)

/// A theme as authored: a flat color map (token name → color), an appearance,
/// and an optional logical-name → asset-ref map. Decoded from a theme.json
/// shipped inside an extension. Unknown color keys are ignored (forward-compat);
/// missing ones fall back to the default palette.
struct ThemeSpec: Sendable, Equatable {
    var appearance: ThemeAppearance
    var colors: [String: Color]
    /// logical name (e.g. "menuBarIcon", "appIcon") → ref string (https URL,
    /// `data:` URI, or bundle-relative path). Resolved + cached by `ThemeStore`.
    var assets: [String: String]

    static let empty = ThemeSpec(appearance: .dark, colors: [:], assets: [:])

    /// Decode from raw JSON data. Lenient: bad color strings are skipped, not
    /// fatal, so one typo can't brick a theme — that token just falls back.
    static func decode(_ data: Data) throws -> ThemeSpec {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThemeError.malformed
        }
        let appearance = (obj["appearance"] as? String).flatMap(ThemeAppearance.init(rawValue:)) ?? .dark
        var colors: [String: Color] = [:]
        if let raw = obj["colors"] as? [String: Any] {
            for (k, v) in raw {
                if let s = v as? String, let color = Color(hex: s) { colors[k] = color }
            }
        }
        var assets: [String: String] = [:]
        if let raw = obj["assets"] as? [String: Any] {
            for (k, v) in raw where v is String { assets[k] = v as? String }
        }
        return ThemeSpec(appearance: appearance, colors: colors, assets: assets)
    }
}

enum ThemeError: Error, Equatable {
    case malformed
    case missingFile(String)
}

// MARK: - Descriptor (selector row)

/// One selectable theme in the picker. The built-in default has no extension;
/// contributed themes carry their extension id + the on-disk theme.json path so
/// `ThemeStore` can load + reload them.
struct ThemeDescriptor: Identifiable, Equatable, Sendable {
    let id: String            // globally unique theme id
    let title: String
    let appearance: ThemeAppearance
    let extensionID: String?  // nil = built-in default
    let jsonPath: URL?        // nil = built-in default (uses ThemePalette.default)

    var isBuiltIn: Bool { extensionID == nil }

    static let builtInID = "com.prosper.theme.default"

    static let builtIn = ThemeDescriptor(
        id: builtInID, title: "Default", appearance: .dark,
        extensionID: nil, jsonPath: nil)
}

// MARK: - Color hex

extension Color {
    /// Parse `#rgb`, `#rrggbb`, `#rrggbbaa` (with or without leading `#`).
    /// Returns nil on anything malformed so the caller can fall back.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        // Strict ASCII hex only: `Character.isHexDigit` also accepts non-ASCII
        // hex forms (Arabic-Indic, fullwidth) that `Int(_, radix:)` then fails to
        // parse, silently yielding a black channel. Reject up front instead.
        let asciiHex = Set("0123456789abcdefABCDEF")
        guard !s.isEmpty, s.allSatisfy(asciiHex.contains) else { return nil }
        let r, g, b, a: Double
        func byte(_ i: Int) -> Double {
            let start = s.index(s.startIndex, offsetBy: i)
            let end = s.index(start, offsetBy: 2)
            return Double(Int(s[start..<end], radix: 16) ?? 0) / 255.0
        }
        switch s.count {
        case 3:  // #rgb → expand each nibble
            let chars = Array(s)
            func nib(_ i: Int) -> Double { Double(Int(String(chars[i]), radix: 16) ?? 0) / 15.0 }
            (r, g, b, a) = (nib(0), nib(1), nib(2), 1)
        case 6:
            (r, g, b, a) = (byte(0), byte(2), byte(4), 1)
        case 8:
            (r, g, b, a) = (byte(0), byte(2), byte(4), byte(6))
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
