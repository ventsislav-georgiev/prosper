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
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent("com.test.hello/extension.toml").path))

        // Trust gate: a freshly installed extension lands untrusted and inert.
        XCTAssertFalse(record.trusted)
        XCTAssertNil(registry.command(id: "hello.run"))
        XCTAssertNil(registry.invokeSync(commandID: "hello.run", query: "hello world"))

        // After trusting, it routes and invokes end to end.
        try registry.trust(id: "com.test.hello")
        XCTAssertNotNil(registry.command(id: "hello.run"))
        XCTAssertEqual(registry.invokeSync(commandID: "hello.run", query: "hello world"), "hi")
    }

    func testTrustGate() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let registry = makeRegistry(userDir: userDir)
        registry.discover()   // seeds the (empty) trusted key, so the install below is untrusted
        try registry.installLocal(from: source)

        // Untrusted: route() declines and no VM is spawned.
        XCTAssertNil(registry.route(query: "hello world"))
        XCTAssertFalse(registry.isTrusted(id: "com.test.hello"))

        // Trust persists and makes it live; untrust tears it back down.
        try registry.trust(id: "com.test.hello")
        XCTAssertTrue(registry.isTrusted(id: "com.test.hello"))
        XCTAssertNotNil(registry.route(query: "hello world"))

        try registry.untrust(id: "com.test.hello")
        XCTAssertNil(registry.route(query: "hello world"))

        // Trust survives a rescan (persisted in UserDefaults).
        try registry.trust(id: "com.test.hello")
        registry.discover()
        XCTAssertTrue(registry.isTrusted(id: "com.test.hello"))
        XCTAssertNotNil(registry.command(id: "hello.run"))
    }

    func testPrivilegeGate() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let registry = ExtensionRegistry(
            systemDir: nil, userDir: userDir, hostVersion: "2.0.0",
            defaults: defaults, services: NoopServices())
        registry.discover()
        try registry.installLocal(from: source)
        try registry.trust(id: "com.test.hello")

        // Trusted but NOT privileged by default: automation tier only (today's behaviour).
        XCTAssertFalse(registry.isPrivileged(id: "com.test.hello"))
        XCTAssertFalse(registry.record(id: "com.test.hello")?.privileged ?? true)

        // Explicit grant elevates to the system tier; revoke drops back.
        try registry.grantPrivilege(id: "com.test.hello")
        XCTAssertTrue(registry.isPrivileged(id: "com.test.hello"))
        try registry.revokePrivilege(id: "com.test.hello")
        XCTAssertFalse(registry.isPrivileged(id: "com.test.hello"))

        // Privilege is its OWN opt-in, separate from Trust: trust alone never grants it.
        try registry.grantPrivilege(id: "com.test.hello")

        // Survives a rescan / fresh registry on the same defaults (UserDefaults-backed).
        let registry2 = ExtensionRegistry(
            systemDir: nil, userDir: userDir, hostVersion: "2.0.0",
            defaults: defaults, services: NoopServices())
        registry2.discover()
        XCTAssertTrue(registry2.isPrivileged(id: "com.test.hello"))

        // Unknown id throws rather than silently granting.
        XCTAssertThrowsError(try registry.grantPrivilege(id: "com.nope"))

        // Revoking trust revokes privilege (privilege requires trust): no
        // privileged-but-untrusted state can linger.
        XCTAssertTrue(registry.isPrivileged(id: "com.test.hello"))
        try registry.untrust(id: "com.test.hello")
        XCTAssertFalse(registry.isPrivileged(id: "com.test.hello"))
        // Granting privilege to an UNTRUSTED extension is refused at the API (not just
        // hidden in the UI): privilege can never exceed trust.
        XCTAssertThrowsError(try registry.grantPrivilege(id: "com.test.hello")) { error in
            XCTAssertEqual(error as? ExtensionError, .untrusted("com.test.hello"))
        }
        XCTAssertFalse(registry.isPrivileged(id: "com.test.hello"))
        // A fresh registry on the same defaults agrees — the set was persisted clear.
        let registry3 = ExtensionRegistry(
            systemDir: nil, userDir: userDir, hostVersion: "2.0.0",
            defaults: defaults, services: NoopServices())
        registry3.discover()
        XCTAssertFalse(registry3.isPrivileged(id: "com.test.hello"))
    }

    func testUninstallClearsPrivilege() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        func freshRegistry() -> ExtensionRegistry {
            ExtensionRegistry(systemDir: nil, userDir: userDir, hostVersion: "2.0.0",
                              defaults: defaults, services: NoopServices())
        }

        let registry = freshRegistry()
        registry.discover()
        try registry.installLocal(from: source)
        try registry.trust(id: "com.test.hello")
        try registry.grantPrivilege(id: "com.test.hello")
        XCTAssertTrue(registry.isPrivileged(id: "com.test.hello"))

        // Uninstall must scrub the privilege grant so a DIFFERENT extension reinstalled
        // under the same id is never silently privileged (RCE escalation guard).
        try registry.uninstall(id: "com.test.hello")
        try registry.installLocal(from: source)
        XCTAssertFalse(registry.isPrivileged(id: "com.test.hello"))
        // And a brand-new registry reading the persisted set agrees.
        let registry2 = freshRegistry()
        registry2.discover()
        XCTAssertFalse(registry2.isPrivileged(id: "com.test.hello"))
    }

    // Defense-in-depth: even if some path persists a privilege grant WITHOUT trust
    // (e.g. trust cleared by a route that forgot to scrub the set), discover() must
    // never elevate an untrusted extension to the system tier. The compute-time gate
    // (`record.trusted && privileged.contains`) enforces the invariant regardless of
    // which mutation path ran.
    func testPrivilegeNeverExceedsTrustOnDiscover() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        // Forge the corrupt state directly: id is in the privilege set but NOT trusted.
        defaults.set(["com.test.hello"], forKey: "privilegedExtensionIDs")

        let registry = ExtensionRegistry(
            systemDir: nil, userDir: userDir, hostVersion: "2.0.0",
            defaults: defaults, services: NoopServices())
        registry.discover()
        try registry.installLocal(from: source)
        registry.discover()
        // Untrusted → privilege gate denies it despite the stale set entry.
        XCTAssertFalse(registry.isPrivileged(id: "com.test.hello"))
    }

    func testSystemExtensionAlwaysTrusted() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sysParent = tmp.appendingPathComponent("system")
        let extDir = sysParent.appendingPathComponent("hello")
        try writeSource(into: extDir, id: "com.test.hello")

        let registry = ExtensionRegistry(
            systemDir: sysParent,
            userDir: tmp.appendingPathComponent("user"),
            hostVersion: "2.0.0",
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
            services: NoopServices())
        registry.discover()
        // System extensions are trusted without any user action and route immediately.
        XCTAssertEqual(registry.isTrusted(id: "com.test.hello"), true)
        XCTAssertNotNil(registry.command(id: "hello.run"))
    }

    func testGrandfatherTrustsPreexistingInstalls() throws {
        // An extension already on disk before the trust gate existed (no trusted key
        // in defaults yet) must be trusted on first discover, not silently disabled.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDir = tmp.appendingPathComponent("user")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: userDir.appendingPathComponent("com.test.hello"), id: "com.test.hello")

        let registry = makeRegistry(userDir: userDir)
        registry.discover()
        XCTAssertEqual(registry.isTrusted(id: "com.test.hello"), true)
        XCTAssertNotNil(registry.command(id: "hello.run"))
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

    // MARK: - Zip-slip predicate (pure, no I/O)

    func testUnsafeEntryReason() {
        // Safe entries — manifest at root, nested files, dot-prefixed names.
        for safe in ["extension.toml", "init.lua", "themes/dark.json", "a/b/c.lua", ".keep", "a..b/c"] {
            XCTAssertNil(RemoteInstaller.unsafeEntryReason(safe), "should accept \(safe)")
        }
        // Escapes — absolute, home, and every shape of `..` traversal.
        for bad in ["/etc/passwd", "~/.ssh/key", "../evil", "a/../../b", "foo/..", "../"] {
            XCTAssertNotNil(RemoteInstaller.unsafeEntryReason(bad), "should reject \(bad)")
        }
    }

    // MARK: - Market id binding (authenticity)

    func testMarketIdentityBinding() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")   // tarball declares this id

        let registry = makeRegistry(userDir: tmp.appendingPathComponent("user"))

        // Match (signed id == manifest id): accepted.
        XCTAssertNoThrow(try registry.bindMarketIdentity(extDir: source, expected: "com.test.hello"))

        // Spoof (published as another id): rejected before any install/overwrite.
        XCTAssertThrowsError(try registry.bindMarketIdentity(extDir: source, expected: "com.trusted.victim")) {
            XCTAssertEqual($0 as? ExtensionError,
                           .marketIdMismatch(expected: "com.trusted.victim", got: "com.test.hello"))
        }
    }

    // MARK: - Hot path

    /// Build N distinct extensions directly under `userDir`. Pre-seeding before the
    /// first discover() grandfathers them all as trusted → live (see discover()).
    private func writeRoutes(into userDir: URL, count: Int) throws {
        for i in 0..<count {
            let dir = userDir.appendingPathComponent("com.test.ext\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let toml = """
            [extension]
            id = "com.test.ext\(i)"
            name = "ext\(i)"
            title = "Ext \(i)"
            description = "perf"
            version = "1.0.0"
            author = "tester"

            [extension.host]
            min_version = "2.0.0"
            api_level = 1

            [extension.entry]
            main = "init.lua"

            [[contributes.commands]]
            id = "ext\(i).run"
            title = "Run \(i)"
            mode = "no-view"
            match = "^cmd\(i)\\\\b"
            """
            try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            try "-- noop".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        }
    }

    /// route() is per-keystroke. Budget: O(live routes) precompiled-regex matches,
    /// no regex compilation, no allocations beyond one NSRange. Asserts a non-matching
    /// worst-case query (scans every route) stays well under budget over 200 routes.
    func testRoutePerformance() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDir = tmp.appendingPathComponent("user")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeRoutes(into: userDir, count: 200)

        let registry = makeRegistry(userDir: userDir)
        registry.discover()   // grandfathers all 200 as trusted → live
        XCTAssertNotNil(registry.route(query: "cmd5 hello"))   // sanity: routes resolve

        let iterations = 2_000
        let worstCase = "zzz no route matches this"   // forces a full scan of all 200 regexes
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<iterations { _ = registry.route(query: worstCase) }
        }
        let perCall = elapsed / iterations
        // Budget: < 1ms per keystroke even scanning 200 routes with no match.
        XCTAssertLessThan(perCall, .milliseconds(1), "route() over 200 routes took \(perCall)/call")
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
