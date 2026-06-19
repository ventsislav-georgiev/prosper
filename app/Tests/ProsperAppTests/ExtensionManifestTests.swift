import XCTest
@testable import ProsperApp

final class ExtensionManifestTests: XCTestCase {

    // MARK: - Fixtures

    private static let sampleManifest = """
    [extension]
    id          = "com.prosper.calc"
    name        = "calc"
    title       = "Calculator"
    description = "Deterministic local arithmetic"
    version     = "1.0.0"
    author      = "prosper"
    system      = true

    [extension.host]
    min_version = "2.0.0"
    api_level   = 1

    [extension.entry]
    main = "init.lua"

    [extension.activation]
    on_event = ["app:focus"]
    eager    = false

    [[contributes.commands]]
    id       = "calc.eval"
    title    = "Calculate"
    mode     = "no-view"
    keywords = ["math"]
    match    = "^[0-9(]"

    [[contributes.keybindings]]
    command = "calc.eval"
    key     = "cmd+shift+c"

    [[contributes.settings_sections]]
    id    = "general"
    title = "General"

    [[contributes.settings_sections.controls]]
    kind    = "number"
    key     = "precision"
    title   = "Decimal places"
    default = 6

    [[contributes.settings_sections.controls]]
    kind    = "enum"
    key     = "mode"
    title   = "Mode"
    values  = ["auto", "manual"]
    default = "auto"
    """

    private func writeExtension(
        in parent: URL,
        dirName: String,
        toml: String,
        entry: String = "init.lua",
        entryBody: String = "function run() return 'ok' end"
    ) throws -> URL {
        let dir = parent.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try entryBody.write(to: dir.appendingPathComponent(entry), atomically: true, encoding: .utf8)
        return dir
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-ext-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Parsing

    func testManifestParses() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeExtension(in: dir, dirName: "calc", toml: Self.sampleManifest)

        let loaded = try ExtensionLoader.load(
            directory: dir.appendingPathComponent("calc"),
            isSystem: true,
            hostVersion: "2.0.0")

        XCTAssertEqual(loaded.manifest.extension.id, "com.prosper.calc")
        XCTAssertTrue(loaded.manifest.extension.isSystem)
        XCTAssertEqual(loaded.manifest.extension.entry.main, "init.lua")
        XCTAssertEqual(loaded.manifest.extension.activation?.events, ["app:focus"])

        let commands = loaded.manifest.contributes?.allCommands ?? []
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.mode, .noView)
        XCTAssertEqual(commands.first?.match, "^[0-9(]")

        let sections = loaded.manifest.contributes?.allSettingsSections ?? []
        XCTAssertEqual(sections.count, 1)
        let controls = sections.first?.allControls ?? []
        XCTAssertEqual(controls.count, 2)
        XCTAssertEqual(controls[0].kind, .number)
        XCTAssertEqual(controls[0].default?.stringValue, "6")
        XCTAssertEqual(controls[1].kind, .enumeration)
        XCTAssertEqual(controls[1].values, ["auto", "manual"])
    }

    // MARK: - Semver + validation

    func testSemanticVersionOrdering() {
        XCTAssertTrue(SemanticVersion("1.9.0") < SemanticVersion("1.10.0"))
        XCTAssertTrue(SemanticVersion("2.0.0") < SemanticVersion("2.0.1"))
        XCTAssertFalse(SemanticVersion("2.1.0") < SemanticVersion("2.0.9"))
        XCTAssertEqual(SemanticVersion("2.0.0-beta"), SemanticVersion("2.0.0"))
    }

    func testIncompatibleHostRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeExtension(in: dir, dirName: "calc", toml: Self.sampleManifest)

        XCTAssertThrowsError(try ExtensionLoader.load(
            directory: dir.appendingPathComponent("calc"),
            isSystem: true,
            hostVersion: "1.5.0")) { err in
            XCTAssertEqual(err as? ExtensionLoadError,
                           .incompatibleHost(need: "2.0.0", have: "1.5.0"))
        }
    }

    func testUnsupportedAPILevelRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = Self.sampleManifest.replacingOccurrences(of: "api_level   = 1", with: "api_level   = 99")
        _ = try writeExtension(in: dir, dirName: "calc", toml: future)

        XCTAssertThrowsError(try ExtensionLoader.load(
            directory: dir.appendingPathComponent("calc"),
            isSystem: true,
            hostVersion: "2.0.0")) { err in
            XCTAssertEqual(err as? ExtensionLoadError,
                           .unsupportedAPILevel(need: 99, max: ExtensionLoader.supportedAPILevel))
        }
    }

    func testEntryMissingRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let extDir = dir.appendingPathComponent("calc", isDirectory: true)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try Self.sampleManifest.write(to: extDir.appendingPathComponent("extension.toml"),
                                      atomically: true, encoding: .utf8)
        // no init.lua written
        XCTAssertThrowsError(try ExtensionLoader.load(
            directory: extDir, isSystem: true, hostVersion: "2.0.0")) { err in
            XCTAssertEqual(err as? ExtensionLoadError, .entryMissing("init.lua"))
        }
    }

    // MARK: - Registry

    @MainActor
    func testRegistryDiscoversRoutesAndActivates() throws {
        let systemRoot = try tempDir()
        let userRoot = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: systemRoot)
            try? FileManager.default.removeItem(at: userRoot)
        }
        _ = try writeExtension(in: systemRoot, dirName: "calc", toml: Self.sampleManifest,
                               entryBody: "function run() return 'calc-ok' end")

        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let registry = ExtensionRegistry(
            systemDir: systemRoot, userDir: userRoot, hostVersion: "2.0.0", defaults: defaults)
        registry.discover()

        XCTAssertEqual(registry.records.count, 1)
        XCTAssertTrue(registry.records[0].isSystem)

        // match-route on a numeric query
        let routed = registry.route(query: "12+3")
        XCTAssertEqual(routed?.command.id, "calc.eval")
        XCTAssertNil(registry.route(query: "hello"))

        // lazy activation runs the entry script
        let rt = try registry.activate(registry.records[0])
        XCTAssertEqual(try rt.callGlobal("run"), "calc-ok")
    }

    @MainActor
    func testDisableRemovesFromRoutingAndPersists() throws {
        let systemRoot = try tempDir()
        let userRoot = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: systemRoot)
            try? FileManager.default.removeItem(at: userRoot)
        }
        _ = try writeExtension(in: systemRoot, dirName: "calc", toml: Self.sampleManifest)

        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let registry = ExtensionRegistry(
            systemDir: systemRoot, userDir: userRoot, hostVersion: "2.0.0", defaults: defaults)
        registry.discover()

        try registry.setEnabled(false, id: "com.prosper.calc")
        XCTAssertNil(registry.route(query: "12+3"), "disabled ext should not route")

        // persisted across a fresh registry
        let registry2 = ExtensionRegistry(
            systemDir: systemRoot, userDir: userRoot, hostVersion: "2.0.0", defaults: defaults)
        registry2.discover()
        XCTAssertFalse(registry2.records[0].enabled)
    }

    @MainActor
    func testSystemExtensionCannotBeUninstalled() throws {
        let systemRoot = try tempDir()
        let userRoot = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: systemRoot)
            try? FileManager.default.removeItem(at: userRoot)
        }
        _ = try writeExtension(in: systemRoot, dirName: "calc", toml: Self.sampleManifest)

        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let registry = ExtensionRegistry(
            systemDir: systemRoot, userDir: userRoot, hostVersion: "2.0.0", defaults: defaults)
        registry.discover()

        XCTAssertThrowsError(try registry.uninstall(id: "com.prosper.calc")) { err in
            XCTAssertEqual(err as? ExtensionError, .cannotUninstallSystem("com.prosper.calc"))
        }
    }

    @MainActor
    func testUserExtensionUninstallAndResetRules() throws {
        let userRoot = try tempDir()
        defer { try? FileManager.default.removeItem(at: userRoot) }
        // user extension: not system
        let userManifest = Self.sampleManifest.replacingOccurrences(of: "system      = true", with: "system      = false")
        _ = try writeExtension(in: userRoot, dirName: "calc", toml: userManifest)

        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let registry = ExtensionRegistry(
            systemDir: nil, userDir: userRoot, hostVersion: "2.0.0", defaults: defaults)
        registry.discover()
        XCTAssertEqual(registry.records.count, 1)
        XCTAssertFalse(registry.records[0].isSystem)

        // reset is invalid for a user extension
        XCTAssertThrowsError(try registry.reset(id: "com.prosper.calc")) { err in
            XCTAssertEqual(err as? ExtensionError, .cannotResetUserExtension("com.prosper.calc"))
        }

        // uninstall removes it from disk + registry
        try registry.uninstall(id: "com.prosper.calc")
        XCTAssertTrue(registry.records.isEmpty)
    }
}
