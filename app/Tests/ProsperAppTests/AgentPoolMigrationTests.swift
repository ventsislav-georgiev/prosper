import XCTest
@testable import ProsperApp

/// #2012: AgentPoolMigration.migrateV1 on a temp Application Support root and a scratch defaults suite (which also holds
/// the extension registry's record sets). No real home, defaults domain or Keychain.
@MainActor
final class AgentPoolMigrationTests: XCTestCase {
    private let old = AgentPoolMigration.oldExtensionID, new = AgentPoolMigration.newExtensionID

    private func oldState(_ d: UserDefaults, _ support: URL) throws {
        d.set([old, "com.prosper.other"], forKey: "enabledExtensionIDs")
        d.set([old], forKey: "trustedExtensionIDs")
        d.set(false, forKey: "ccpoolRouteAgentSessions")
        d.set(false, forKey: "ccpoolRouteCodexSessions")
        d.set(0.75, forKey: "ccpoolExhaustedThreshold")
        let dir = support.appendingPathComponent("ccpool", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("usage"), withIntermediateDirectories: true)
        try Data("{\"accounts\":{}}".utf8).write(to: dir.appendingPathComponent("state.json"))
        try Data("u".utf8).write(to: dir.appendingPathComponent("usage/2026-11-27.jsonl"))
        try Data("e".utf8).write(to: dir.appendingPathComponent("events.jsonl"))
    }

    private func files(_ dir: URL) -> [String] {
        (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).sorted()
    }

    func testFirstLaunchCarriesTheRecordKeysAndFolder() throws {
        let d = scratchDefaults("agentpool-mig"), support = tempDir(), log = CCPoolCapturingLogger()
        try oldState(d, support)
        let before = files(support.appendingPathComponent("ccpool"))
        AgentPoolMigration.migrateV1(defaults: d, support: support, logger: log)

        XCTAssertEqual(d.stringArray(forKey: "enabledExtensionIDs"), ["com.prosper.agentpool", "com.prosper.other"])
        XCTAssertEqual(d.stringArray(forKey: "trustedExtensionIDs"), [new], "trusted carried, old id dropped")
        XCTAssertEqual(d.object(forKey: "poolRoute.claude") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "poolRoute.codex") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "poolExhaustedThreshold") as? Double, 0.75)
        for k in ["ccpoolRouteAgentSessions", "ccpoolRouteCodexSessions", "ccpoolExhaustedThreshold"] {
            XCTAssertTrue(d.object(forKey: k) == nil, k)
        }
        XCTAssertFalse(CCPoolPaneModel.routeValue(in: d))
        XCTAssertFalse(CCPoolPaneModel.codexRouteValue(in: d))
        XCTAssertEqual(CCPoolPaneModel.exhaustedValue(in: d), 0.75, "the model reads the new keys")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("ccpool").path))
        XCTAssertEqual(files(support.appendingPathComponent("agentpool")), before, "the same files")
        XCTAssertEqual(before.count, 4)
        XCTAssertEqual(d.integer(forKey: AgentPoolMigration.markerKey), 1)
        XCTAssertEqual(log.lines, ["-: agent pool migration: moved the ccpool folder to agentpool"])
    }

    /// The bundled extension under its new id reads the carried sets: enabled (it is opt-in) and live.
    func testTheRegistryReadsTheCarriedRecordAsEnabled() throws {
        let d = scratchDefaults("agentpool-mig-reg"), root = tempDir()
        d.set([old], forKey: "enabledExtensionIDs")
        AgentPoolMigration.migrateV1(defaults: d, support: root, logger: CCPoolCapturingLogger())
        let system = root.appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions/ccpool", isDirectory: true)
        try FileManager.default.copyItem(at: bundled, to: system.appendingPathComponent("ccpool", isDirectory: true))
        let reg = GateFixture(systemDir: system, userDir: root.appendingPathComponent("user"), defaults: d).registry()
        let rec = try XCTUnwrap(reg.record(id: new))
        XCTAssertTrue(rec.isLive, "enabled and trusted after the id change")
        XCTAssertTrue(reg.record(id: old) == nil)
    }

    func testAbsentKeysStayAbsent() {
        let d = scratchDefaults("agentpool-mig-absent")
        d.set(0.9, forKey: "ccpoolExhaustedThreshold")
        AgentPoolMigration.migrateV1(defaults: d, support: tempDir(), logger: CCPoolCapturingLogger())
        XCTAssertTrue(d.object(forKey: "poolRoute.claude") == nil, "no default written")
        XCTAssertTrue(d.object(forKey: "poolRoute.codex") == nil)
        XCTAssertEqual(d.object(forKey: "poolExhaustedThreshold") as? Double, 0.9)
        XCTAssertTrue(CCPoolPaneModel.routeValue(in: d), "absent reads on")
    }

    /// Mutant m1 (marker check removed): an old key written again by an older build is not carried over a new choice.
    func testSecondRunIsANoOp() throws {
        let d = scratchDefaults("agentpool-mig-twice"), support = tempDir()
        try oldState(d, support)
        AgentPoolMigration.migrateV1(defaults: d, support: support, logger: CCPoolCapturingLogger())
        d.set(true, forKey: "poolRoute.claude")
        d.set(false, forKey: "ccpoolRouteAgentSessions")
        d.set([old], forKey: "trustedExtensionIDs")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("ccpool"), withIntermediateDirectories: true)
        let log = CCPoolCapturingLogger()
        AgentPoolMigration.migrateV1(defaults: d, support: support, logger: log)
        XCTAssertEqual(d.object(forKey: "poolRoute.claude") as? Bool, true, "not overwritten")
        XCTAssertEqual(d.object(forKey: "ccpoolRouteAgentSessions") as? Bool, false, "left alone")
        XCTAssertEqual(d.stringArray(forKey: "trustedExtensionIDs"), [old])
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("ccpool").path))
        XCTAssertEqual(log.lines, [])
    }

    /// Mutant m3 (no RENAME_EXCL): rename(2) would replace the empty target.
    func testAnExistingTargetMovesNothing() throws {
        let d = scratchDefaults("agentpool-mig-target"), support = tempDir(), log = CCPoolCapturingLogger()
        try oldState(d, support)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("agentpool"), withIntermediateDirectories: true)
        AgentPoolMigration.migrateV1(defaults: d, support: support, logger: log)
        XCTAssertEqual(files(support.appendingPathComponent("ccpool")).count, 4, "the source is left")
        XCTAssertEqual(files(support.appendingPathComponent("agentpool")), [], "the target untouched")
        XCTAssertEqual(log.lines, ["-: agent pool migration: the agentpool folder already exists; the ccpool folder was not moved"])
        XCTAssertEqual(d.integer(forKey: AgentPoolMigration.markerKey), 1)
    }

    func testAFreshInstallOnlyWritesTheMarker() {
        let d = scratchDefaults("agentpool-mig-fresh"), support = tempDir(), log = CCPoolCapturingLogger()
        AgentPoolMigration.migrateV1(defaults: d, support: support, logger: log)
        for k in ["enabledExtensionIDs", "trustedExtensionIDs", "poolRoute.claude", "poolRoute.codex", "poolExhaustedThreshold",
                  AgentPoolMigration.selectedPaneKey] {
            XCTAssertTrue(d.object(forKey: k) == nil, k)
        }
        XCTAssertEqual(d.integer(forKey: AgentPoolMigration.markerKey), 1)
        XCTAssertEqual(files(support), [], "no folder made")
        XCTAssertEqual(log.lines, [])
    }

    /// Mutant m7 (the alias dropped): the old pane id, stored or opened, lands on the new pane.
    func testTheOldPaneIDResolvesToTheNewPane() {
        XCTAssertEqual(settingsPaneAlias("ext:com.prosper.ccpool|ccpool"), "ext:com.prosper.agentpool|agentpool")
        XCTAssertEqual(settingsPaneAlias("general"), "general")
        let tab = SettingsTab(id: AgentPlanLimits.settingsPane, title: "Agent Account Pool", icon: "person.2.circle")
        XCTAssertEqual(settingsHealedSelection("ext:com.prosper.ccpool|ccpool", groups: [("Agents", [tab])]), AgentPlanLimits.settingsPane)
        let d = scratchDefaults("agentpool-mig-pane")
        d.set("ext:com.prosper.ccpool|ccpool", forKey: AgentPoolMigration.selectedPaneKey)
        AgentPoolMigration.migrateV1(defaults: d, support: tempDir(), logger: CCPoolCapturingLogger())
        XCTAssertEqual(d.string(forKey: AgentPoolMigration.selectedPaneKey), AgentPlanLimits.settingsPane)
    }

    /// The person-facing names (design 5): the island link and help, the manifest's titles.
    func testTheUserVisibleNames() throws {
        XCTAssertEqual(AgentPlanLimits.settingsLink, "Agent pool settings\u{2026}")
        XCTAssertEqual(CCPoolPane.addClaudeTitle, "Add Claude account")
    }
}
