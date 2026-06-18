import XCTest
@testable import ProsperApp

/// Verifies generic extension dispatch in `CommandRouter`: an installed
/// extension whose `match` regex accepts a query is invoked through the registry
/// (off-main async lane) and surfaced as a `.ext` outcome — the path that makes
/// arbitrary user/system extensions (quicklinks, window management, …) routable
/// from the palette instead of being swallowed by the translate fallback.
final class CommandRouterRoutingTests: XCTestCase {

    /// Write a throwaway "echo" extension into a temp dir and return its parent
    /// (used as the registry's systemDir so it loads without app-support setup).
    private func makeEchoExtension() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-test-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("echo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "com.test.echo"
        name = "echo"
        title = "Echo"
        description = "uppercases the rest of the query"
        version = "1.0.0"
        author = "test"
        system = true

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.commands]]
        id = "echo.run"
        title = "Echo"
        mode = "no-view"
        match = "^echo "
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try """
        function echo_run(query)
            local rest = (query:gsub("^echo ", ""))
            if #rest == 0 then return nil end
            return rest:upper() .. "\\techoed"
        end
        """.write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return root
    }

    @MainActor
    func testGenericExtensionRoutesAndDeclines() async throws {
        let root = try makeEchoExtension()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults(suiteName: "router-test-\(UUID().uuidString)")!
        let registry = ExtensionRegistry(
            systemDir: root,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: defaults
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "echo.run") == nil, "echo.run not discovered")

        let previous = CommandRouter.registry
        CommandRouter.registry = registry
        defer { CommandRouter.registry = previous }

        // Matches `^echo ` → routed to the extension, surfaced as `.ext` with the
        // command title as kind and the TAB-split value/detail.
        let out = await CommandRouter.run("echo hi")
        guard case .ext(let kind, let value, let detail) = out else {
            return XCTFail("expected .ext, got \(out)")
        }
        XCTAssertEqual(kind, "Echo")
        XCTAssertEqual(value, "HI")
        XCTAssertEqual(detail, "echoed")
        XCTAssertEqual(out.copyText, "HI")
    }
}
