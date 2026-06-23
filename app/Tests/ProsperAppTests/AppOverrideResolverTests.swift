import XCTest
@testable import ProsperApp

/// Covers the WS3 per-app override resolution order (`AppOverrideResolver`):
///
///   user override → seed → structural (`AppProfile.Kind`) → `Preferences` fallback
///
/// Drives the synchronous read cache (`AppOverrideCache`) directly to stand in for a
/// stored override, so these tests never touch the GRDB actor or disk — they assert
/// the pure resolution logic. Each test restores the cache afterward so ordering is
/// irrelevant. The legacy `Preferences` fallback is exercised with bundle ids that
/// are in (or out of) the shipped default lists.
final class AppOverrideResolverTests: XCTestCase {

    /// A bundle id in no seed and no structural list: resolution falls straight
    /// through to the `Preferences` fallback.
    private let unlistedId = "com.example.prosper.unlisted-test-app"

    override func tearDown() {
        // Always clear the shared cache so a leaked override can't bleed into the
        // next test (the cache is a process-wide singleton).
        AppOverrideCache.shared.replace(with: [])
        super.tearDown()
    }

    // MARK: - enabled: priority order

    /// User override is the highest-priority layer: an explicit `enabled` beats the
    /// seed, the structural default, and Preferences.
    func testUserOverrideBeatsSeed() {
        // Seed says Mail is enabled; user override forces it off.
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: "com.apple.mail", enabled: false)
        ])
        XCTAssertFalse(AppOverrideResolver.isEnabled(forBundleId: "com.apple.mail"))
        XCTAssertTrue(AppOverrideResolver.isAutocompleteDisabled(forBundleId: "com.apple.mail"))
    }

    /// With no user override, the curated seed applies: Mail/Slack/Discord etc. are
    /// seeded enabled.
    func testSeedAppliesWhenNoOverride() {
        AppOverrideCache.shared.replace(with: [])
        XCTAssertTrue(AppOverrideResolver.isEnabled(forBundleId: "com.apple.mail"))
        XCTAssertTrue(AppOverrideResolver.isEnabled(forBundleId: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(AppOverrideResolver.isEnabled(forBundleId: "com.hnc.discord"))
    }

    /// The disable-by-default set is referenced (not duplicated) by the seed layer:
    /// apps in `Preferences.defaultDisabledBundleIds` resolve to a disabled seed,
    /// case-insensitively (that set carries mixed-case ids like `com.apple.dt.Xcode`).
    func testDisableByDefaultSeedFromPreferencesList() {
        AppOverrideCache.shared.replace(with: [])
        // Lowercased form of an id present in defaultDisabledBundleIds.
        XCTAssertFalse(AppOverrideResolver.isEnabled(forBundleId: "com.apple.dt.xcode"))
        XCTAssertFalse(AppOverrideResolver.isEnabled(forBundleId: "com.apple.finder"))
        // And a user override still beats that disabled seed.
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: "com.apple.dt.xcode", enabled: true)
        ])
        XCTAssertTrue(AppOverrideResolver.isEnabled(forBundleId: "com.apple.dt.xcode"))
    }

    /// Secure apps (password managers) NEVER complete — the structural layer hard-
    /// suppresses them even with no override and no enabling seed.
    func testStructuralSecureSuppression() {
        AppOverrideCache.shared.replace(with: [])
        XCTAssertFalse(AppOverrideResolver.isEnabled(forBundleId: "com.1password.1password"))
        // A user override can still re-enable a non-seeded structural default, but the
        // hard secure suppression sits *below* the override, so an explicit on wins.
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: "com.1password.1password", enabled: true)
        ])
        XCTAssertTrue(AppOverrideResolver.isEnabled(forBundleId: "com.1password.1password"))
    }

    /// Terminals have no working inline-completion path (no AX-editable text), so the
    /// structural layer suppresses them too — the engine must schedule no request and
    /// show no ghost, matching the menu bar's "not supported" row.
    func testStructuralTerminalSuppression() {
        AppOverrideCache.shared.replace(with: [])
        XCTAssertFalse(AppOverrideResolver.isEnabled(forBundleId: "com.googlecode.iterm2"))
        XCTAssertTrue(AppOverrideResolver.isAutocompleteDisabled(forBundleId: "com.apple.terminal"))
    }

    /// An app in no seed and no structural list falls through to the `Preferences`
    /// fallback, which (with completions-on-by-default) enables it — reproducing the
    /// pre-WS3 outcome exactly.
    func testPreferencesFallbackForUnlistedApp() {
        AppOverrideCache.shared.replace(with: [])
        // The resolver's fallback for an unlisted app equals the old gate.
        XCTAssertEqual(
            AppOverrideResolver.isAutocompleteDisabled(forBundleId: unlistedId),
            Preferences.isAutocompleteDisabled(forBundleId: unlistedId)
        )
    }

    // MARK: - tabToAccept

    /// `tabToAccept` follows the same order; a user override flips it off and the
    /// `isTabDisabled` mirror reflects that.
    func testTabToAcceptUserOverride() {
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: unlistedId, tabToAccept: false)
        ])
        XCTAssertFalse(AppOverrideResolver.tabToAccept(forBundleId: unlistedId))
        XCTAssertTrue(AppOverrideResolver.isTabDisabled(forBundleId: unlistedId))
    }

    /// With no override and no seed, Tab acceptance falls back to Preferences (Tab is
    /// enabled unless the id is in `disableTabBundleIds`, empty by default).
    func testTabToAcceptPreferencesFallback() {
        AppOverrideCache.shared.replace(with: [])
        XCTAssertEqual(
            AppOverrideResolver.isTabDisabled(forBundleId: unlistedId),
            Preferences.isTabDisabled(forBundleId: unlistedId)
        )
    }

    // MARK: - customInstructions

    /// A per-app override addendum is appended to the global instructions, joined by
    /// a blank line — matching the legacy `effectiveCustomInstructions` shape.
    func testCustomInstructionsOverrideAppendedToGlobal() {
        let savedGlobal = Preferences.customInstructions
        defer { Preferences.customInstructions = savedGlobal }
        Preferences.customInstructions = "Global tone."

        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: unlistedId, customInstructions: "Per-app tone.")
        ])
        XCTAssertEqual(
            AppOverrideResolver.effectiveCustomInstructions(forBundleId: unlistedId),
            "Global tone.\n\nPer-app tone."
        )
    }

    /// With no override/seed and no legacy per-app entry, only the global text is used.
    func testCustomInstructionsFallsBackToGlobalOnly() {
        let savedGlobal = Preferences.customInstructions
        defer { Preferences.customInstructions = savedGlobal }
        Preferences.customInstructions = "Only global."
        AppOverrideCache.shared.replace(with: [])
        XCTAssertEqual(
            AppOverrideResolver.effectiveCustomInstructions(forBundleId: unlistedId),
            "Only global."
        )
    }

    // MARK: - surface

    /// A `surfaceOverride` pins the writing surface; otherwise the inferred
    /// `AppProfile.surface` is used.
    func testSurfaceOverride() {
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: unlistedId, surfaceOverride: AppProfile.Surface.email.rawName)
        ])
        XCTAssertEqual(AppOverrideResolver.surface(forBundleId: unlistedId), .email)

        AppOverrideCache.shared.replace(with: [])
        // No override: inferred surface for an unlisted standard app is .generic.
        XCTAssertEqual(AppOverrideResolver.surface(forBundleId: unlistedId), .generic)
    }

    /// `Surface.rawName` ↔ `init?(rawName:)` round-trip for every case (the encoding
    /// used to persist `surfaceOverride`).
    func testSurfaceRawNameRoundTrip() {
        let all: [AppProfile.Surface] = [
            .chat, .email, .social, .notes, .code, .docs, .terminal, .browser, .generic
        ]
        for s in all {
            XCTAssertEqual(AppProfile.Surface(rawName: s.rawName), s)
        }
        XCTAssertNil(AppProfile.Surface(rawName: "not-a-surface"))
    }

    // MARK: - WS4 + threshold knobs (stored/resolved only)

    /// `minSizeThreshold` resolves override → seed → 0.
    func testMinSizeThreshold() {
        AppOverrideCache.shared.replace(with: [])
        XCTAssertEqual(AppOverrideResolver.minSizeThreshold(forBundleId: unlistedId), 0)
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: unlistedId, minSizeThreshold: 3)
        ])
        XCTAssertEqual(AppOverrideResolver.minSizeThreshold(forBundleId: unlistedId), 3)
    }

    /// WS4 knobs are stored/resolved but carry no behavior here; they default to nil.
    func testWS4KnobsResolveButDefaultNil() {
        AppOverrideCache.shared.replace(with: [])
        XCTAssertNil(AppOverrideResolver.forceEnhancedUI(forBundleId: unlistedId))
        XCTAssertNil(AppOverrideResolver.textMirroring(forBundleId: unlistedId))
        AppOverrideCache.shared.replace(with: [
            AppOverride(bundleId: unlistedId, forceEnhancedUI: true, textMirroring: true)
        ])
        XCTAssertEqual(AppOverrideResolver.forceEnhancedUI(forBundleId: unlistedId), true)
        XCTAssertEqual(AppOverrideResolver.textMirroring(forBundleId: unlistedId), true)
    }

    // MARK: - record shape

    /// An all-unset override is `isEmpty` (so the store can drop it rather than persist
    /// an inheriting row); setting any one knob makes it non-empty.
    func testAppOverrideIsEmpty() {
        XCTAssertTrue(AppOverride(bundleId: unlistedId).isEmpty)
        XCTAssertFalse(AppOverride(bundleId: unlistedId, enabled: true).isEmpty)
        XCTAssertFalse(AppOverride(bundleId: unlistedId, customInstructions: "x").isEmpty)
    }
}
