import XCTest
@testable import ProsperApp

@MainActor
final class AnalyticsSnapshotTests: XCTestCase {

    // MARK: - Fixture helpers (temp-dir system extensions, mirrors ExtensionSettingsTests)

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-analytics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeExtension(in parent: URL, dir: String, toml: String) throws -> URL {
        let d = parent.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try toml.write(to: d.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- noop".write(to: d.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return d
    }

    private func manifest(id: String, name: String, system: Bool, commands: Int) -> String {
        var t = """
        [extension]
        id = "\(id)"
        name = "\(name)"
        title = "\(name)"
        description = "d"
        version = "1.0.0"
        author = "t"
        system = \(system)

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """
        for i in 0..<commands {
            t += """


            [[contributes.commands]]
            id = "\(name).cmd\(i)"
            title = "C\(i)"
            mode = "no-view"
            match = "^__never\(i)__"
            """
        }
        return t
    }

    /// Build a registry whose system extensions (auto-trusted on discover, so `isLive`
    /// == `enabled`) are seeded from a temp dir. Uses an isolated UserDefaults suite so
    /// the enabled/trusted state never touches `.standard`.
    private func makeRegistry(system: [(id: String, name: String, commands: Int)]) throws -> ExtensionRegistry {
        let systemRoot = try tempDir()
        let userRoot = try tempDir()
        for e in system {
            try writeExtension(in: systemRoot, dir: e.name,
                               toml: manifest(id: e.id, name: e.name, system: true, commands: e.commands))
        }
        let reg = ExtensionRegistry(
            systemDir: systemRoot, userDir: userRoot, hostVersion: "2.0.0",
            defaults: UserDefaults(suiteName: "analytics-test-\(UUID().uuidString)")!)
        reg.discover()
        return reg
    }

    // MARK: - PII

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

    /// Aptabase props accept only String / Number — assert every value qualifies,
    /// including the Double-valued agent props (only present when the agent is on).
    func testAllValuesAreStringOrNumber() {
        Preferences.agentEnabled = true
        let p = AnalyticsSnapshot.build(registry: nil)
        XCTAssertFalse(p.isEmpty)
        for (k, v) in p {
            let ok = v is String || v is Int || v is Double || v is NSNumber
            XCTAssertTrue(ok, "prop \(k) is not String/Number: \(type(of: v))")
        }
        // Bools are emitted as Int 0/1, not Bool.
        XCTAssertNotNil(p["completions_autocomplete_enabled"] as? Int)
        // Doubles serialize fine through JSONSerialization (no NaN/Inf).
        XCTAssertNotNil(p["agent_temperature"] as? Double ?? (p["agent_temperature"] as? NSNumber).map { $0.doubleValue })
    }

    /// System-supplied counts must never be lumped with user-supplied counts.
    func testSystemUserCountsSeparated() {
        Preferences.agentEnabled = true   // persona counts are gated behind the agent toggle now
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

    // MARK: - Disabled-feature gating

    /// A disabled feature's detail props carry no signal, so only the master toggle
    /// is sent; flipping the feature on surfaces the detail props.
    func testDisabledFeatureSettingsOmitted() {
        Preferences.autocompleteEnabled = false
        Preferences.clipboardHistoryEnabled = false
        Preferences.emojiSuggestionsEnabled = false
        Preferences.loraEnabled = false
        Preferences.snippetsEnabled = false
        Preferences.agentEnabled = false

        let off = AnalyticsSnapshot.build(registry: nil)
        // Master toggles always present...
        XCTAssertEqual(off["completions_autocomplete_enabled"] as? Int, 0)
        XCTAssertEqual(off["clipboard_history_enabled"] as? Int, 0)
        XCTAssertEqual(off["emoji_suggestions_enabled"] as? Int, 0)
        XCTAssertEqual(off["personalization_lora_enabled"] as? Int, 0)
        XCTAssertEqual(off["snippets_enabled"] as? Int, 0)
        XCTAssertEqual(off["agent_enabled"] as? Int, 0)
        // ...but the detail props are omitted.
        XCTAssertNil(off["completions_length"])
        XCTAssertNil(off["completions_model"], "no autocomplete, no translate → no model")
        XCTAssertNil(off["context_use_ocr"])
        XCTAssertNil(off["clipboard_history_max_items"])
        XCTAssertNil(off["emoji_skin_tone"])
        XCTAssertNil(off["personalization_lora_rank"])
        XCTAssertNil(off["snippets_auto_expand"])
        XCTAssertNil(off["agent_model"])

        // Flip them all on → detail props appear.
        Preferences.autocompleteEnabled = true
        Preferences.clipboardHistoryEnabled = true
        Preferences.emojiSuggestionsEnabled = true
        Preferences.loraEnabled = true
        Preferences.snippetsEnabled = true
        Preferences.agentEnabled = true

        let on = AnalyticsSnapshot.build(registry: nil)
        XCTAssertNotNil(on["completions_length"])
        XCTAssertNotNil(on["completions_model"])
        XCTAssertNotNil(on["context_use_ocr"])
        XCTAssertNotNil(on["clipboard_history_max_items"])
        XCTAssertNotNil(on["emoji_skin_tone"])
        XCTAssertNotNil(on["personalization_lora_rank"])
        XCTAssertNotNil(on["snippets_auto_expand"])
        XCTAssertNotNil(on["agent_model"])
    }

    /// The inline model is shared with Translate, so it stays meaningful when
    /// autocomplete is off but the Translate extension is live.
    func testCoreModelSharedWithTranslate() throws {
        Preferences.autocompleteEnabled = false

        // Translate live → model still reported.
        let withTranslate = try makeRegistry(system: [
            ("com.prosper.translate", "translate", 0),
        ])
        XCTAssertTrue(withTranslate.record(id: "com.prosper.translate")?.isLive == true)
        let p1 = AnalyticsSnapshot.build(registry: withTranslate)
        XCTAssertNotNil(p1["completions_model"], "translate live → core model is meaningful")

        // Translate disabled + autocomplete off → model omitted.
        try withTranslate.setEnabled(false, id: "com.prosper.translate")
        let p2 = AnalyticsSnapshot.build(registry: withTranslate)
        XCTAssertNil(p2["completions_model"], "neither consumer active → no model")
    }

    // MARK: - Extension counts + usage filtering

    /// Counts are computed in one pass; usage counters for non-live extensions are
    /// dropped (a disabled extension's historical usage carries no current signal).
    func testExtensionCountsAndUsageFiltering() throws {
        let liveID = "com.test.live"
        let offID = "com.test.off"
        let reg = try makeRegistry(system: [
            (liveID, "livesys", 0),
            (offID, "offsys", 0),
        ])
        try reg.setEnabled(false, id: offID)
        AnalyticsStore.bumpUsage(extensionID: liveID)
        AnalyticsStore.bumpUsage(extensionID: offID)

        let p = AnalyticsSnapshot.build(registry: reg)
        XCTAssertEqual(p["extensions_count_system"] as? Int, 2)
        XCTAssertEqual(p["extensions_count_disabled"] as? Int, 1)
        XCTAssertNotNil(p["extensions_use_com_test_live"], "live extension usage is reported")
        XCTAssertNil(p["extensions_use_com_test_off"], "disabled extension usage is filtered out")
    }

    /// A corrupt (NaN/Inf) Double pref must be dropped, not crash the daily send:
    /// JSONSerialization throws on non-finite numbers, which would block every future
    /// send. The prop is omitted and the rest of the payload still serializes.
    func testNonFiniteAgentDoublesDropped() {
        Preferences.agentEnabled = true
        Preferences.agentTemperature = .nan
        Preferences.agentTopP = .infinity

        let p = AnalyticsSnapshot.build(registry: nil)
        XCTAssertNil(p["agent_temperature"], "NaN temperature must be dropped")
        XCTAssertNil(p["agent_top_p"], "Inf top_p must be dropped")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(p), "payload must stay JSON-serializable")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: p))

        Preferences.agentTemperature = 0.7   // restore so other tests see a sane value
        Preferences.agentTopP = 1.0
    }

    func testNewAdoptionSignalsPresent() {
        let p = AnalyticsSnapshot.build(registry: nil)
        XCTAssertNotNil(p["sync_enabled"] as? Int)
        XCTAssertNotNil(p["theme_active_id"] as? String)
        XCTAssertNotNil(p["agent_enabled"] as? Int)
        XCTAssertNotNil(p["snippets_enabled"] as? Int)
    }

    // MARK: - Performance / hot-path ceiling

    /// HOT-PATH REQUIREMENT: `build()` runs on the daily timer and on every open of
    /// the analytics transparency view, so it must stay cheap and — critically —
    /// O(records), NOT O(records × usage-counters). This guards the single-pass +
    /// live-id-Set optimization against an accidental return to per-id linear scans:
    /// a 60-extension registry must build within ~8× a 2-extension one, not ~30×.
    func testBuildScalesLinearlyWithExtensionCount() throws {
        Preferences.agentEnabled = false   // exclude the FS-touching pluginCount() path

        func avgNanos(_ reg: ExtensionRegistry, iterations: Int) -> Double {
            for _ in 0..<5 { _ = AnalyticsSnapshot.build(registry: reg) }   // warm caches
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                for _ in 0..<iterations { _ = AnalyticsSnapshot.build(registry: reg) }
            }
            let totalNs = Double(elapsed.components.seconds) * 1e9
                + Double(elapsed.components.attoseconds) / 1e9
            return totalNs / Double(iterations)
        }

        let small = try makeRegistry(system: [("com.test.a", "a", 0), ("com.test.b", "b", 0)])
        var many: [(String, String, Int)] = []
        for i in 0..<60 { many.append(("com.test.e\(i)", "e\(i)", 0)) }
        let big = try makeRegistry(system: many.map { ($0.0, $0.1, $0.2) })
        for i in 0..<60 { AnalyticsStore.bumpUsage(extensionID: "com.test.e\(i)") }

        let smallNs = avgNanos(small, iterations: 200)
        let bigNs = avgNanos(big, iterations: 200)
        XCTAssertLessThan(bigNs, smallNs * 8 + 1_000_000,
                          "build() scaled super-linearly (small=\(Int(smallNs))ns big=\(Int(bigNs))ns) — O(n×m) regression?")
        // Absolute sanity ceiling (CI-generous): an in-memory build stays well under 25ms.
        XCTAssertLessThan(bigNs, 25_000_000, "build() exceeded 25ms for 60 extensions")
    }
}

@MainActor
final class AnalyticsServiceTests: XCTestCase {

    /// GOAL: when the extension registry hasn't loaded yet the snapshot would be
    /// incomplete (missing extension counts + per-system usage), so the send is
    /// DELAYED — `sendNow()` bails without posting and never stamps `lastSent`, so the
    /// next tick retries once the registry is present.
    func testSendDelayedWhenRegistryMissing() async {
        let service = AnalyticsService.shared
        let saved = service.registryProvider
        defer { service.registryProvider = saved }

        Preferences.analyticsEnabled = true
        let marker = Date(timeIntervalSince1970: 1_000_000)
        AnalyticsStore.lastSent = marker
        service.registryProvider = { nil }

        let ok = await service.sendNow()
        XCTAssertFalse(ok, "must not report success while the registry is missing")
        XCTAssertEqual(AnalyticsStore.lastSent, marker, "lastSent must stay put so the day isn't skipped")
    }
}
