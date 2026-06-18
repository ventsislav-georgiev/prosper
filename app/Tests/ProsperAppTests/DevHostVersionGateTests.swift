import XCTest
@testable import ProsperApp

/// Regression: a development / unstamped bundle reports host version "0.0.0"
/// (the scripts/Info.plist placeholder when PROSPER_VERSION is unset). The host
/// must treat that as a dev host that satisfies any extension `min_version`,
/// otherwise EVERY system extension fails to load in local bundles — which broke
/// the quicklinks open path (it has no native fallback, unlike calc/unit/etc.).
final class DevHostVersionGateTests: XCTestCase {
    private func manifest(minVersion: String) throws -> ExtensionManifest {
        let json = """
        {
          "extension": {
            "id": "test.ext", "name": "test", "title": "Test",
            "description": "t", "version": "1.0.0", "author": "x",
            "system": true,
            "host": { "min_version": "\(minVersion)", "api_level": 1 },
            "entry": { "main": "init.lua" }
          }
        }
        """
        return try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    }

    func testDevHostSatisfiesAnyFloor() throws {
        XCTAssertNoThrow(try ExtensionLoader.validate(manifest(minVersion: "2.0.0"), hostVersion: "0.0.0"))
    }

    func testRealHostStillEnforcesFloor() throws {
        XCTAssertThrowsError(try ExtensionLoader.validate(manifest(minVersion: "2.0.0"), hostVersion: "1.5.0"))
        XCTAssertNoThrow(try ExtensionLoader.validate(manifest(minVersion: "2.0.0"), hostVersion: "2.38.0"))
    }

    /// End-to-end: a registry running as a 0.0.0 dev host (the exact live failure)
    /// must still load + route the system extensions from the in-repo source dir.
    @MainActor
    func testDevHostRegistryLoadsAndRoutes() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "no in-repo extensions dir")
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-devhost-\(UUID().uuidString)", isDirectory: true),
            hostVersion: "0.0.0"
        )
        registry.discover()
        XCTAssertNotNil(registry.command(id: "quicklinks.run"), "quicklinks must load under 0.0.0 dev host")
        XCTAssertEqual(registry.route(query: "ql list")?.command.id, "quicklinks.run")
    }
}
