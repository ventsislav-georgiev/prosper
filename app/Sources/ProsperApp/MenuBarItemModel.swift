import CoreGraphics
import Foundation

/// Which band of the menu bar an item sits in, decided purely by its x-origin
/// relative to the control-item dividers. There is no API to hide a *chosen*
/// foreign status item in place — the user assigns membership by ⌘-dragging an
/// icon across a divider (the native gesture). So section is POSITIONAL, derived
/// from measured frames at reconcile time, never an authoritative stored set.
enum MenuBarSection: String, Codable, CaseIterable, Sendable {
    case visible        // right of the hidden divider — always shown
    case hidden         // between the always-hidden and hidden dividers — shown on demand
    case alwaysHidden   // left of the always-hidden divider — shown only via the always-hidden reveal
}

/// The glyph drawn on the divider `NSStatusItem`s (the user-visible "chevron").
/// Each style is an SF Symbol pair: the collapsed symbol shows when the hidden
/// section is tucked away, the revealed symbol when it's open. Purely cosmetic —
/// nonisolated so the (nonisolated) store can hold it.
enum ChevronStyle: String, Codable, CaseIterable, Sendable {
    case chevrons, chevron, arrow, ellipsis, circle

    var label: String {
        switch self {
        case .chevrons: return "Chevrons »"
        case .chevron:  return "Chevron ›"
        case .arrow:    return "Arrow ▸"
        case .ellipsis: return "Dots …"
        case .circle:   return "Circle ●"
        }
    }

    /// Shown when the hidden section is collapsed (pointing "there's more this way").
    var collapsedSymbol: String {
        switch self {
        case .chevrons: return "chevron.left.2"
        case .chevron:  return "chevron.left"
        case .arrow:    return "arrowtriangle.left.fill"
        case .ellipsis: return "ellipsis"
        case .circle:   return "circle.fill"
        }
    }

    /// Shown while revealed (points back the other way; circle/ellipsis just stay).
    var revealedSymbol: String {
        switch self {
        case .chevrons: return "chevron.right.2"
        case .chevron:  return "chevron.right"
        case .arrow:    return "arrowtriangle.right.fill"
        case .ellipsis: return "ellipsis"
        case .circle:   return "circle"
        }
    }
}

/// Persisted menu-bar settings. Stored as a JSON blob in UserDefaults (mirrors
/// `Preferences.layoutStore`). Order is owned by macOS (it persists ⌘-drag
/// positions itself), so nothing here records item order — section membership is
/// derived live from divider positions at reconcile time.
struct MenuBarStore: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schemaVersion: Int = MenuBarStore.currentSchema

    /// Absolute icon spacing in points written to both NSStatusItem keys. macOS stock
    /// is 16 (`MenuBarSpacing.defaultSpacing`); we default tighter (3) since the whole
    /// point of the feature is a denser bar. Clamped on read.
    var spacing: Int = 3

    /// Master gate for the always-hidden third section (two-tier hide). Off → a
    /// single hidden section, one chevron.
    var alwaysHiddenEnabled: Bool = false

    /// Seconds the hidden section stays revealed with no interaction before it
    /// auto-rehides. Clamped 1...30 on read.
    var autoRehideSeconds: Int = 5

    /// Cosmetic glyph for the divider items.
    var chevronStyle: ChevronStyle = .ellipsis

    var clampedSpacing: Int { min(max(spacing, MenuBarSpacing.minSpacing), MenuBarSpacing.maxSpacing) }
    var clampedAutoRehide: Int { min(max(autoRehideSeconds, 1), 30) }

    static let `default` = MenuBarStore()

    init() {}

    /// Field-by-field tolerant decode: a blob written by an older/newer build that
    /// is missing a key keeps the others instead of failing the whole decode (which
    /// would force a full reset to `.default`). Synthesized Codable can't do this —
    /// it requires every non-optional key — so we spell it out. Downgrade-safe.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MenuBarStore.default
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        spacing = try c.decodeIfPresent(Int.self, forKey: .spacing) ?? d.spacing
        alwaysHiddenEnabled = try c.decodeIfPresent(Bool.self, forKey: .alwaysHiddenEnabled) ?? d.alwaysHiddenEnabled
        autoRehideSeconds = try c.decodeIfPresent(Int.self, forKey: .autoRehideSeconds) ?? d.autoRehideSeconds
        chevronStyle = try c.decodeIfPresent(ChevronStyle.self, forKey: .chevronStyle) ?? d.chevronStyle
    }
}

/// Pure, AX-free menu-bar math. Everything here is unit-tested without touching
/// CGS/AppKit — the load-bearing logic (section assignment, spacing key mapping,
/// reorder destination) lives here so the manager stays a thin imperative shell.
enum MenuBarLogic {
    /// Assign each item to a section by comparing its x-origin to the divider
    /// x-positions. Items are taken as-is (caller sorts left→right by `minX`).
    ///
    /// Coordinate model: status items lay out with the visible band at the HIGHEST
    /// x (right edge of screen). So:
    ///   - x  > hiddenDividerX                         → .visible
    ///   - alwaysHiddenDividerX < x < hiddenDividerX    → .hidden
    ///   - x  < alwaysHiddenDividerX                    → .alwaysHidden
    /// When `alwaysHiddenDividerX` is nil (two-tier disabled) everything left of
    /// the hidden divider is `.hidden`.
    static func section(forItemX x: CGFloat,
                        hiddenDividerX: CGFloat,
                        alwaysHiddenDividerX: CGFloat?) -> MenuBarSection {
        if x > hiddenDividerX { return .visible }
        if let a = alwaysHiddenDividerX, x < a { return .alwaysHidden }
        return .hidden
    }

    /// The (hidden, alwaysHidden) divider lengths for a given reveal state — the
    /// single source of truth for the show/hide hot path. `expanded` pushes every
    /// item left of a divider past the screen edge; `standard` collapses it to a
    /// normal divider. The always-hidden divider only collapses when explicitly
    /// revealed (which implies the hidden section is revealed too).
    static func dividerLengths(revealed: Bool, revealedAlwaysHidden: Bool,
                               standard: CGFloat, expanded: CGFloat) -> (hidden: CGFloat, alwaysHidden: CGFloat) {
        (hidden: revealed ? standard : expanded,
         alwaysHidden: revealedAlwaysHidden ? standard : expanded)
    }

    /// The integer to write to `NSStatusItemSpacing` / `NSStatusItemSelectionPadding`
    /// for a desired absolute spacing. Returns nil when spacing equals the macOS
    /// default (16) → caller should `delete` the keys to restore stock behavior
    /// rather than pinning the default value.
    static func spacingDefaultsValue(forSpacing spacing: Int) -> Int? {
        let v = min(max(spacing, MenuBarSpacing.minSpacing), MenuBarSpacing.maxSpacing)
        return v == MenuBarSpacing.defaultSpacing ? nil : v
    }

    /// Whether the Settings preview strip can be trusted (pure; the live wrapper
    /// supplies the sets). Hide/show + spacing ride public AppKit and never depend
    /// on this — ONLY the cosmetic preview reads item positions via the private CGS
    /// enumeration. A future macOS can shift menu-bar window semantics (Tahoe did
    /// exactly this to Bartender) and return `.success` while omitting windows that
    /// provably exist — a hard CGS error wouldn't catch that. So we probe positively:
    /// does the enumeration still contain our OWN divider windows? Empty dividers ⇒
    /// nothing to probe against yet ⇒ trust (never false-alarm before setup runs).
    static func previewHealthy(dividerWindowIDs: Set<CGWindowID>,
                               enumeratedWindowIDs: Set<CGWindowID>) -> Bool {
        guard !dividerWindowIDs.isEmpty else { return true }
        return !dividerWindowIDs.isDisjoint(with: enumeratedWindowIDs)
    }
}
