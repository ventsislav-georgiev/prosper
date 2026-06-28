import Foundation

/// One-time migration of the user's settings after the app bundle id was renamed
/// from the legacy `com.prosper.app` to `eu.illegible.prosper` (a globally-unique,
/// owned reverse-DNS id — required to register an App ID for the iCloud-Keychain
/// sync entitlement; see SyncKeyStore / scripts/Prosper.entitlements).
///
/// macOS keys a `UserDefaults.standard` domain to the bundle id, so without this
/// an upgrading user would launch into a blank-slate app (all prefs, shortcuts,
/// toggles gone). We copy every key from the legacy domain into the new one on
/// first launch under the new id, then set a guard flag so it never re-runs.
///
/// Must run BEFORE anything reads `UserDefaults.standard` — call it as the very
/// first statement in main.swift.
enum DefaultsMigration {
    private static let legacyBundleID = "com.prosper.app"
    private static let migratedKey = "migratedFromComProsperApp"
    private static let snapModeKey = "snapMode"  // mirrors Preferences.Keys.snapMode (private there)

    static func runIfNeeded() {
        // Only meaningful in a bundled run (the legacy domain is keyed by bundle
        // id); bare-binary dev runs have no bundle id and nothing to migrate.
        guard let current = Bundle.main.bundleIdentifier, current != legacyBundleID else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }

        // persistentDomain(forName:) returns the legacy app's plist contents
        // without binding this process to that suite.
        let legacy = defaults.persistentDomain(forName: legacyBundleID) ?? [:]
        if !legacy.isEmpty {
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        // First-run-only default: a genuinely fresh install (nothing to migrate
        // from legacy, no value already present) starts on the layout palette.
        // Existing/upgrading users keep their behavior — `migratedKey` short-
        // circuits this on every later launch, and a set key is never overwritten.
        if legacy.isEmpty && defaults.object(forKey: snapModeKey) == nil {
            defaults.set(SnapMode.palette.rawValue, forKey: snapModeKey)
        }

        defaults.set(true, forKey: migratedKey)
    }
}
