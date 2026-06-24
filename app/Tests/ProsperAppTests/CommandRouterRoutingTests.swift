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

    /// Discovery: a no-view command with NO `match` regex (only reachable by its
    /// prefix today) must surface in the universal launcher when the user types
    /// the extension's name or one of the command's keywords — the gap this whole
    /// feature fills. Locks down both `commandSearchEntries()` (haystack includes
    /// ext name + keywords) and the `.search` command-hit path.
    private func makeDiscoverableExtension() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc-test-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("frobber", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "com.test.frobber"
        name = "frobnicator"
        title = "Frobnicator"
        description = "test discovery fixture"
        version = "1.0.0"
        author = "test"
        system = true

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.commands]]
        id = "frob.toggle"
        title = "Toggle Frob"
        mode = "no-view"
        keywords = ["wibble", "awake"]
        prefix = "fb "
        runs_on_select = true

        [[contributes.commands]]
        id = "frob.input"
        title = "Frob Text"
        mode = "no-view"
        prefix = "ft "
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "function noop() end".write(to: dir.appendingPathComponent("init.lua"),
                                        atomically: true, encoding: .utf8)
        return root
    }

    @MainActor
    func testCommandsDiscoverableByNameAndKeyword() async throws {
        let root = try makeDiscoverableExtension()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ExtensionRegistry(
            systemDir: root,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: UserDefaults(suiteName: "disc-test-\(UUID().uuidString)")!
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "frob.toggle") == nil, "frob.toggle not discovered")

        // commandSearchEntries: haystack carries the extension name + keywords, so
        // both ext-name and keyword queries can find this prefix-only command.
        let entries = registry.commandSearchEntries()
        guard let toggle = entries.first(where: { $0.commandID == "frob.toggle" }) else {
            return XCTFail("frob.toggle missing from commandSearchEntries")
        }
        XCTAssertTrue(toggle.haystack.contains("frobnicator"), "ext name in haystack")
        XCTAssertTrue(toggle.haystack.contains("wibble"), "keyword in haystack")
        XCTAssertFalse(toggle.launchesWindow)

        let previous = CommandRouter.registry
        CommandRouter.registry = registry
        defer { CommandRouter.registry = previous }

        // Typing a keyword surfaces the command as a selectable `.search` row.
        func commandHits(_ q: String) async -> [SearchHit] {
            guard case .search(let hits) = await CommandRouter.run(q) else { return [] }
            return hits.filter { $0.kind == .command }
        }
        let byKeyword = await commandHits("wibble")
        XCTAssertTrue(byKeyword.contains { $0.commandID == "frob.toggle" },
                      "keyword 'wibble' should surface frob.toggle")

        // Typing the extension name surfaces its commands.
        let byName = await commandHits("frobnicator")
        XCTAssertTrue(byName.contains { $0.commandID == "frob.toggle" })
        XCTAssertTrue(byName.contains { $0.commandID == "frob.input" })
    }

    /// Stress fixture: one extension contributing `count` no-view commands, each
    /// with a distinct title + keyword list, so `commandSearchEntries()` has real
    /// haystacks to build.
    private func makeStressExtension(count: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stress-test-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("stress", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var toml = """
        [extension]
        id = "com.test.stress"
        name = "stress"
        title = "Stress"
        description = "perf fixture"
        version = "1.0.0"
        author = "test"
        system = true

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        """
        for i in 0..<count {
            toml += """
            [[contributes.commands]]
            id = "stress.cmd\(i)"
            title = "Stress Command Number \(i)"
            mode = "no-view"
            keywords = ["alpha\(i)", "bravo\(i)", "charlie\(i)", "delta\(i)"]
            prefix = "s\(i) "

            """
        }
        try toml.write(to: dir.appendingPathComponent("extension.toml"),
                       atomically: true, encoding: .utf8)
        try "function noop() end".write(to: dir.appendingPathComponent("init.lua"),
                                        atomically: true, encoding: .utf8)
        return root
    }

    /// HOT-PATH REQUIREMENT: `commandSearchEntries()` runs inside the per-keystroke
    /// `unifiedSearch` main-actor snapshot. Rebuilding the haystacks for a large
    /// command set (300 — an extreme upper bound; real installs have a few dozen)
    /// must stay imperceptible on the main thread. Ceiling is generous for debug +
    /// noisy CI; the test prints the real figure so a regression is caught. With the
    /// records-revision memo it is an O(1) cache hit after the first build.
    @MainActor
    func testCommandSearchEntriesRebuildIsFast() throws {
        let root = try makeStressExtension(count: 300)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ExtensionRegistry(
            systemDir: root,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: UserDefaults(suiteName: "stress-test-\(UUID().uuidString)")!
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "stress.cmd0") == nil, "stress fixture not discovered")
        XCTAssertEqual(registry.commandSearchEntries().count, 300)

        // Simulate 200 keystrokes each re-snapshotting the command set.
        let iterations = 200
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            var sink = 0
            for _ in 0..<iterations { sink += registry.commandSearchEntries().count }
            XCTAssertEqual(sink, 300 * iterations)
        }
        let usPerCall = Double(elapsed.components.attoseconds) / 1e12 / Double(iterations)
        print("⏱  commandSearchEntries (300 cmds): \(String(format: "%.1f", usPerCall)) µs/call")
        // Memoized: ~0.1µs/call (cache hit). An unmemoized rebuild is ~300µs/call in
        // debug — a 10µs ceiling catches a regression that drops the cache without
        // flaking on CI noise.
        XCTAssertLessThan(usPerCall, 10, "command snapshot must be a memoized O(1) hit on the hot path")
    }

    /// Stability: the discovery memo must reflect live-set changes. Disabling the
    /// contributing extension routes through `rebuildRoutes()`, which drops the
    /// cache, so the next `commandSearchEntries()` must return the fresh (empty) set
    /// rather than a stale cached list.
    @MainActor
    func testCommandSearchEntriesCacheInvalidatesOnDisable() throws {
        let root = try makeStressExtension(count: 5)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ExtensionRegistry(
            systemDir: root,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: UserDefaults(suiteName: "stress-test-\(UUID().uuidString)")!
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "stress.cmd0") == nil, "stress fixture not discovered")

        XCTAssertEqual(registry.commandSearchEntries().count, 5)  // primes the cache
        try registry.setEnabled(false, id: "com.test.stress")
        XCTAssertEqual(registry.commandSearchEntries().count, 0, "memo must drop on disable")
        try registry.setEnabled(true, id: "com.test.stress")
        XCTAssertEqual(registry.commandSearchEntries().count, 5, "memo must rebuild on re-enable")
    }
}
