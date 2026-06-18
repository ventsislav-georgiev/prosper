import XCTest
@testable import ProsperApp

/// Minimal no-op host services for registry tests (no native side effects).
private final class NoopServices: ExtensionHostServices, @unchecked Sendable {
    var prefs: [String: String] = [:]
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { prefs["\(extensionID).\(key)"] }
    func prefSet(extensionID: String, key: String, value: String) { prefs["\(extensionID).\(key)"] = value }
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
}

@MainActor
final class ExtensionInstallTests: XCTestCase {

    private func makeRegistry(userDir: URL) -> ExtensionRegistry {
        ExtensionRegistry(
            systemDir: nil,
            userDir: userDir,
            hostVersion: "2.0.0",
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
            services: NoopServices()
        )
    }

    /// Build a throwaway source extension directory on disk.
    private func writeSource(into dir: URL, id: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toml = """
        [extension]
        id = "\(id)"
        name = "hello"
        title = "Hello"
        description = "A test extension"
        version = "1.0.0"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.commands]]
        id = "hello.run"
        title = "Run Hello"
        mode = "no-view"
        match = "^hello"
        """
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "function hello_run(q) return 'hi' end".write(
            to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    }

    func testInstallLocalCopiesAndDiscovers() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let registry = makeRegistry(userDir: userDir)
        registry.discover()
        XCTAssertTrue(registry.records.isEmpty)

        let record = try registry.installLocal(from: source)
        XCTAssertEqual(record.id, "com.test.hello")
        XCTAssertFalse(record.isSystem)
        XCTAssertNotNil(registry.command(id: "hello.run"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent("com.test.hello/extension.toml").path))

        // Invoking the installed Lua handler works end to end.
        XCTAssertEqual(registry.invokeSync(commandID: "hello.run", query: "hello world"), "hi")
    }

    func testUninstallUserExtensionRemovesIt() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let registry = makeRegistry(userDir: userDir)
        try registry.installLocal(from: source)
        XCTAssertNotNil(registry.record(id: "com.test.hello"))

        try registry.uninstall(id: "com.test.hello")
        XCTAssertNil(registry.record(id: "com.test.hello"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent("com.test.hello").path))
    }

    func testCannotUninstallSystemExtension() throws {
        // A registry whose only "system" dir is our source — the loaded record is
        // flagged system and must refuse uninstall.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sysParent = tmp.appendingPathComponent("system")
        let extDir = sysParent.appendingPathComponent("hello")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let toml = """
        [extension]
        id = "com.test.sys"
        name = "sys"
        title = "Sys"
        description = "system"
        version = "1.0.0"
        author = "tester"
        system = true

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """
        try toml.write(to: extDir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- noop".write(to: extDir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)

        let registry = ExtensionRegistry(
            systemDir: sysParent,
            userDir: tmp.appendingPathComponent("user"),
            hostVersion: "2.0.0",
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
            services: NoopServices())
        registry.discover()
        XCTAssertEqual(registry.record(id: "com.test.sys")?.isSystem, true)
        XCTAssertThrowsError(try registry.uninstall(id: "com.test.sys")) { error in
            XCTAssertEqual(error as? ExtensionError, .cannotUninstallSystem("com.test.sys"))
        }
    }
}
