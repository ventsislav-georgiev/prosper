import XCTest
@testable import ProsperApp

@MainActor
final class AnalyticsSnapshotTests: XCTestCase {

    /// The snapshot must NEVER contain free-text / PII, even when prefs are full of it.
    func testNoPIILeaks() {
        let secrets = ["SECRET_NAME_ZZ", "SECRET_PROMPT_ZZ", "SECRET_PERAPP_ZZ", "secret-domain-zz.example"]
        Preferences.userName = secrets[0]
        Preferences.customInstructions = secrets[1]
        Preferences.perAppCustomInstructions = ["com.zz.app": secrets[2]]
        Preferences.disabledDomains = [secrets[3]]

        let json = AnalyticsSnapshot.prettyJSON(registry: nil)
        for s in secrets {
            XCTAssertFalse(json.contains(s), "payload leaked PII: \(s)")
        }
        // But the COUNT of those items must still be reported.
        let p = AnalyticsSnapshot.build(registry: nil)
        XCTAssertEqual(p["apps_count_per_app_instructions"] as? Int, 1)
        XCTAssertEqual(p["apps_count_disabled_domains"] as? Int, 1)
    }

    /// Aptabase props accept only String / Number — assert every value qualifies.
    func testAllValuesAreStringOrNumber() {
        let p = AnalyticsSnapshot.build(registry: nil)
        XCTAssertFalse(p.isEmpty)
        for (k, v) in p {
            let ok = v is String || v is Int || v is NSNumber
            XCTAssertTrue(ok, "prop \(k) is not String/Number: \(type(of: v))")
        }
        // Bools are emitted as Int 0/1, not Bool.
        XCTAssertNotNil(p["completions_autocomplete_enabled"] as? Int)
    }

    /// System-supplied counts must never be lumped with user-supplied counts.
    func testSystemUserCountsSeparated() {
        // Personas: the unsplit key is gone; system count == the shipped built-ins.
        let p0 = AnalyticsSnapshot.build(registry: nil)
        XCTAssertNil(p0["agent_count_personas"], "unsplit personas key must be gone")
        XCTAssertEqual(p0["agent_count_personas_system"] as? Int,
                       AgentPersonaStore.all().filter(\.isBuiltIn).count)
        XCTAssertNotNil(p0["agent_count_personas_user"] as? Int)

        // Disabled apps: a user-added id (outside the shipped defaults) lands in the
        // user bucket; the seeded defaults that remain land in the system bucket.
        let userApp = "com.zz.useradded"
        Preferences.disabledBundleIds = Preferences.defaultDisabledBundleIds.union([userApp])
        let p = AnalyticsSnapshot.build(registry: nil)
        XCTAssertNil(p["apps_count_disabled"], "unsplit disabled key must be gone")
        XCTAssertEqual(p["apps_count_disabled_system"] as? Int,
                       Preferences.defaultDisabledBundleIds.count)
        XCTAssertEqual(p["apps_count_disabled_user"] as? Int, 1)
    }

    func testAnonIDStable() {
        XCTAssertEqual(AnalyticsStore.anonID(), AnalyticsStore.anonID())
        XCTAssertFalse(AnalyticsStore.anonID().isEmpty)
    }

    func testUsageCounterIncrements() {
        let id = "test.ext.counter"
        let before = AnalyticsStore.usageCounts()[id] ?? 0
        AnalyticsStore.bumpUsage(extensionID: id)
        XCTAssertEqual(AnalyticsStore.usageCounts()[id], before + 1)
    }
}
