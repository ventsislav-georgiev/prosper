import Foundation

/// Resolves the *effective* value of each per-app autocomplete knob, combining the
/// user's override, a seeded sensible default, the legacy `Preferences` value, and
/// the structural `AppProfile.Kind` default — in that priority order:
///
///   1. **User override** — what the user set in Settings (the `AppOverrideStore`).
///   2. **Seed** — a curated per-app default (`seeds`) for well-known apps.
///   3. **Preferences fallback** — the pre-WS3 global/list behavior, kept working so
///      nothing regresses for apps with no override and no seed.
///   4. **Structural default** — derived from `AppProfile.Kind` (e.g. secure apps
///      never complete).
///
/// Reads are synchronous (via `AppOverrideCache`), so the resolver is safe on the
/// keystroke hot path. Resolution for an app the user has never touched and that
/// has no seed reproduces today's `Preferences`-driven outcome exactly.
enum AppOverrideResolver {

    // MARK: - Seeds

    /// Curated per-app defaults applied only when the user has set no explicit
    /// override for that app. Messaging/email apps where inline completion shines
    /// are seeded **enabled**. The disable-by-default set (Xcode, iWork, Finder, …)
    /// is *not* duplicated here — `seed(for:)` reuses `Preferences.defaultDisabledBundleIds`
    /// to synthesize a `enabled: false` seed for those ids. Keys are matched
    /// case-sensitively against the live bundle id (the same form `Preferences` stores).
    static let seeds: [String: AppOverride] = [
        "com.apple.mail": AppOverride(bundleId: "com.apple.mail", enabled: true),
        "com.apple.mobilesms": AppOverride(bundleId: "com.apple.mobilesms", enabled: true),
        "com.microsoft.outlook": AppOverride(bundleId: "com.microsoft.outlook", enabled: true),
        "com.microsoft.teams2": AppOverride(bundleId: "com.microsoft.teams2", enabled: true),
        // Electron/Chromium apps: forceEnhancedUI sets `AXManualAccessibility` on the
        // app element, which materializes Chromium's lazily-built a11y tree. Without
        // it the tree degrades whenever no other assistive client is active and every
        // caret-geometry query (`kAXBoundsForRange`, text markers) returns degenerate
        // rects — the ghost then falls back to the field's leading edge.
        "com.tinyspeck.slackmacgap": AppOverride(
            bundleId: "com.tinyspeck.slackmacgap", enabled: true, forceEnhancedUI: true
        ),
        "com.hnc.discord": AppOverride(
            bundleId: "com.hnc.discord", enabled: true, forceEnhancedUI: true
        ),
    ]

    /// `Preferences.defaultDisabledBundleIds`, lowercased once, so the disable-by-default
    /// seed match is case-insensitive (that set mixes case, e.g. `com.apple.dt.Xcode`,
    /// while live frontmost bundle ids may differ in case).
    private static let defaultDisabledLowercased: Set<String> =
        Set(Preferences.defaultDisabledBundleIds.map { $0.lowercased() })

    /// The seed for an app, or nil. A nil-returning lookup means "no curated default".
    /// Explicit `seeds` entries win; otherwise apps in `Preferences.defaultDisabledBundleIds`
    /// (Xcode, iWork, Finder, password managers, IDEs, launchers) get a synthesized
    /// `enabled: false` seed — the disable-by-default list is referenced, never duplicated.
    static func seed(for bundleId: String?) -> AppOverride? {
        guard let bundleId else { return nil }
        if let explicit = seeds[bundleId] { return explicit }
        if defaultDisabledLowercased.contains(bundleId.lowercased()) {
            return AppOverride(bundleId: bundleId, enabled: false)
        }
        return nil
    }

    // MARK: - enabled

    /// Whether inline autocomplete is enabled for the given app, resolved through
    /// the full priority chain. This is the single source of truth that replaces
    /// `Preferences.isAutocompleteDisabled(forBundleId:)` for the per-app gate.
    ///
    /// Order: user override → seed → structural-secure (never complete in password
    /// managers) → `Preferences` (`disabledBundleIds` + `completionsEnabledByDefault`
    /// + `enabledBundleIds`).
    static func isEnabled(forBundleId bundleId: String?) -> Bool {
        // 1. User override.
        if let ov = AppOverrideCache.shared.override(for: bundleId), let on = ov.enabled {
            return on
        }
        // 2. Seed.
        if let s = seed(for: bundleId), let on = s.enabled {
            return on
        }
        // 3. Structural: apps with no working inline-completion path NEVER complete,
        //    regardless of any list — terminals (no AX-editable text) and secure
        //    password managers (leak secrets). This is the same flag the menu bar
        //    uses to show the "not supported" row, so the engine and the UI agree:
        //    no request is scheduled and no ghost is shown for those apps.
        if !AppProfile.profile(for: bundleId).supportsInlineCompletion {
            return false
        }
        // 4. Preferences fallback — identical to the pre-WS3 gate.
        return !Preferences.isAutocompleteDisabled(forBundleId: bundleId)
    }

    /// Inverse of `isEnabled`, named to drop straight into the old call site
    /// (`Preferences.isAutocompleteDisabled`).
    static func isAutocompleteDisabled(forBundleId bundleId: String?) -> Bool {
        !isEnabled(forBundleId: bundleId)
    }

    // MARK: - tabToAccept

    /// Whether Tab accepts a word in the given app. Order: user override → seed →
    /// `Preferences.disableTabBundleIds` (membership ⇒ Tab disabled). Default true.
    static func tabToAccept(forBundleId bundleId: String?) -> Bool {
        if let ov = AppOverrideCache.shared.override(for: bundleId), let tab = ov.tabToAccept {
            return tab
        }
        if let s = seed(for: bundleId), let tab = s.tabToAccept {
            return tab
        }
        return !Preferences.isTabDisabled(forBundleId: bundleId)
    }

    /// Inverse of `tabToAccept`, named to drop straight into the old call site
    /// (`Preferences.isTabDisabled`).
    static func isTabDisabled(forBundleId bundleId: String?) -> Bool {
        !tabToAccept(forBundleId: bundleId)
    }

    // MARK: - customInstructions

    /// Effective custom instructions for an app: the global `Preferences`
    /// instructions plus the per-app addendum, where the addendum is resolved
    /// override → seed → legacy `Preferences.perAppCustomInstructions`. Both parts
    /// are trimmed and joined with a blank line, exactly like the old
    /// `Preferences.effectiveCustomInstructions(forBundleId:)`.
    static func effectiveCustomInstructions(forBundleId bundleId: String?) -> String {
        let global = Preferences.customInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let perApp: String? = {
            if let ov = AppOverrideCache.shared.override(for: bundleId),
               let instr = ov.customInstructions { return instr }
            if let s = seed(for: bundleId), let instr = s.customInstructions { return instr }
            if let bundleId { return Preferences.perAppCustomInstructions[bundleId] }
            return nil
        }()

        let trimmed = perApp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return global }
        return global.isEmpty ? trimmed : global + "\n\n" + trimmed
    }

    /// The full addendum handed to `CoreBridge.completionSystemPrompt(custom:)` for
    /// an app: the structured persona block (name/languages/voice) **first**, then
    /// the resolved free-form / per-app `effectiveCustomInstructions`. Both parts
    /// are trimmed and joined with a blank line; empty parts are skipped.
    ///
    /// Persona is intentionally placed ahead of the free-form text so the user's
    /// identity/voice frames the more specific instructions, while the free-form
    /// `customInstructions` (and per-app addenda) remain the fallback/extension.
    /// When persona is unset this returns exactly `effectiveCustomInstructions`,
    /// keeping the no-persona path byte-identical to before.
    static func effectivePromptAddendum(forBundleId bundleId: String?) -> String {
        let persona = Preferences.structuredPersonaBlock
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = effectiveCustomInstructions(forBundleId: bundleId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !persona.isEmpty else { return custom }
        guard !custom.isEmpty else { return persona }
        return persona + "\n\n" + custom
    }

    // MARK: - surface

    /// The effective writing surface for an app: an explicit `surfaceOverride`
    /// (user override → seed) if it parses, else the inferred `AppProfile.surface`.
    static func surface(forBundleId bundleId: String?) -> AppProfile.Surface {
        if let ov = AppOverrideCache.shared.override(for: bundleId),
           let raw = ov.surfaceOverride, let s = AppProfile.Surface(rawName: raw) {
            return s
        }
        if let s = seed(for: bundleId), let raw = s.surfaceOverride,
           let parsed = AppProfile.Surface(rawName: raw) {
            return parsed
        }
        return AppProfile.profile(for: bundleId).surface
    }

    // MARK: - WS4 knobs (stored/resolved only; no behavior yet)

    /// Effective `forceEnhancedUI` (user override → seed → nil). **Consumed by WS4.**
    static func forceEnhancedUI(forBundleId bundleId: String?) -> Bool? {
        if let ov = AppOverrideCache.shared.override(for: bundleId),
           let v = ov.forceEnhancedUI { return v }
        return seed(for: bundleId)?.forceEnhancedUI
    }

    /// Effective `textMirroring` (user override → seed → nil). **Consumed by WS4.**
    static func textMirroring(forBundleId bundleId: String?) -> Bool? {
        if let ov = AppOverrideCache.shared.override(for: bundleId),
           let v = ov.textMirroring { return v }
        return seed(for: bundleId)?.textMirroring
    }

    // MARK: - minSizeThreshold

    /// Minimum chars in the field before completing (user override → seed → 0).
    static func minSizeThreshold(forBundleId bundleId: String?) -> Int {
        if let ov = AppOverrideCache.shared.override(for: bundleId),
           let v = ov.minSizeThreshold { return v }
        return seed(for: bundleId)?.minSizeThreshold ?? 0
    }
}

extension AppProfile.Surface {
    /// Parses a raw case name ("chat", "email", …) into a `Surface`, or nil.
    /// Used to decode `AppOverride.surfaceOverride`.
    init?(rawName: String) {
        switch rawName {
        case "chat": self = .chat
        case "email": self = .email
        case "social": self = .social
        case "notes": self = .notes
        case "code": self = .code
        case "docs": self = .docs
        case "terminal": self = .terminal
        case "browser": self = .browser
        case "generic": self = .generic
        default: return nil
        }
    }

    /// The raw case name, the inverse of `init?(rawName:)`. Used to store a
    /// `surfaceOverride`.
    var rawName: String {
        switch self {
        case .chat: return "chat"
        case .email: return "email"
        case .social: return "social"
        case .notes: return "notes"
        case .code: return "code"
        case .docs: return "docs"
        case .terminal: return "terminal"
        case .browser: return "browser"
        case .generic: return "generic"
        }
    }
}
