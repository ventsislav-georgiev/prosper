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

/// Stable identity for a menu-bar item. Window titles are unreliable (off-space
/// items report `""`), so identity keys on the owning app's bundle id. Items from
/// the same app are disambiguated by their left→right slot within that app.
struct MenuBarItemInfo: Codable, Equatable, Hashable, Sendable {
    var bundleID: String
    var slot: Int   // 0-based index among this app's items, left→right

    init(bundleID: String, slot: Int = 0) {
        self.bundleID = bundleID
        self.slot = slot
    }
}

/// Persisted menu-bar settings. Stored as a JSON blob in UserDefaults (mirrors
/// `Preferences.layoutStore`). `observedOrder` is a *display/restore* aid — the
/// last seen left→right order of items, NOT a command set. The divider positions
/// + the user's drags are the real source of truth.
struct MenuBarStore: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schemaVersion: Int = MenuBarStore.currentSchema

    /// Absolute icon spacing in points written to both NSStatusItem keys.
    /// macOS default is 16; `MenuBarSpacing.defaultSpacing`. Clamped on read.
    var spacing: Int = MenuBarSpacing.defaultSpacing

    /// Master gate for the always-hidden third section (two-tier hide). Off → a
    /// single hidden section, one chevron.
    var alwaysHiddenEnabled: Bool = false

    /// Experimental synthetic-⌘-drag reorder. Default OFF — it's the fragile path
    /// (Ice's top bug source) and needs Accessibility. Core hide never needs it.
    var reorderEnabled: Bool = false

    /// Reveal the hidden section on hovering the menu bar (vs click/hotkey only).
    var hoverReveal: Bool = false

    /// Seconds the hidden section stays revealed with no interaction before it
    /// auto-rehides. Clamped 1...30 on read.
    var autoRehideSeconds: Int = 5

    /// Last observed left→right order, keyed by stable item info. Display/restore
    /// only.
    var observedOrder: [MenuBarItemInfo] = []

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
        reorderEnabled = try c.decodeIfPresent(Bool.self, forKey: .reorderEnabled) ?? d.reorderEnabled
        hoverReveal = try c.decodeIfPresent(Bool.self, forKey: .hoverReveal) ?? d.hoverReveal
        autoRehideSeconds = try c.decodeIfPresent(Int.self, forKey: .autoRehideSeconds) ?? d.autoRehideSeconds
        observedOrder = try c.decodeIfPresent([MenuBarItemInfo].self, forKey: .observedOrder) ?? d.observedOrder
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

    /// Index where `item` should land to sit immediately left/right of `anchor`
    /// within a left→right ordered list. Pure index math for the reorder planner;
    /// the synthetic-event executor turns this into a ⌘-drag. Returns nil if either
    /// item isn't found.
    static func reorderInsertionIndex(moving item: MenuBarItemInfo,
                                      toLeftOf anchor: MenuBarItemInfo,
                                      in order: [MenuBarItemInfo]) -> Int? {
        guard order.firstIndex(of: item) != nil,
              let anchorIdx = order.firstIndex(of: anchor) else { return nil }
        return anchorIdx
    }

    static func reorderInsertionIndex(moving item: MenuBarItemInfo,
                                      toRightOf anchor: MenuBarItemInfo,
                                      in order: [MenuBarItemInfo]) -> Int? {
        guard order.firstIndex(of: item) != nil,
              let anchorIdx = order.firstIndex(of: anchor) else { return nil }
        return anchorIdx + 1
    }

    /// Apply an insertion index to produce the resulting order (pure, for tests +
    /// observedOrder restore). Removing the item first means the index is relative
    /// to the list WITHOUT the moved item.
    static func applyMove(_ item: MenuBarItemInfo, toIndex rawIndex: Int,
                          in order: [MenuBarItemInfo]) -> [MenuBarItemInfo] {
        var out = order
        guard let from = out.firstIndex(of: item) else { return order }
        out.remove(at: from)
        let clamped = min(max(rawIndex > from ? rawIndex - 1 : rawIndex, 0), out.count)
        out.insert(item, at: clamped)
        return out
    }
}
