import TOMLDecoder
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
    func llmChat(_ prompt: String) async -> String { "" }
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
            defaults: scratchDefaults("test"),
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
        let tmp = tempDir()
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
        let tmp = tempDir()
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
        let tmp = tempDir()
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let defaults = scratchDefaults("test")
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

    func testUninstallClearsPrivilege() async throws {
        let tmp = tempDir()
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let defaults = scratchDefaults("test")
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
        try await registry.uninstall(id: "com.test.hello")
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
        let tmp = tempDir()
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let defaults = scratchDefaults("test")
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
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sysParent = tmp.appendingPathComponent("system")
        let extDir = sysParent.appendingPathComponent("hello")
        try writeSource(into: extDir, id: "com.test.hello")

        let registry = ExtensionRegistry(
            systemDir: sysParent,
            userDir: tmp.appendingPathComponent("user"),
            hostVersion: "2.0.0",
            defaults: scratchDefaults("test"),
            services: NoopServices())
        registry.discover()
        // System extensions are trusted without any user action and route immediately.
        XCTAssertEqual(registry.isTrusted(id: "com.test.hello"), true)
        XCTAssertNotNil(registry.command(id: "hello.run"))
    }

    func testGrandfatherTrustsPreexistingInstalls() throws {
        // An extension already on disk before the trust gate existed (no trusted key
        // in defaults yet) must be trusted on first discover, not silently disabled.
        let tmp = tempDir()
        let userDir = tmp.appendingPathComponent("user")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: userDir.appendingPathComponent("com.test.hello"), id: "com.test.hello")

        let registry = makeRegistry(userDir: userDir)
        registry.discover()
        XCTAssertEqual(registry.isTrusted(id: "com.test.hello"), true)
        XCTAssertNotNil(registry.command(id: "hello.run"))
    }

    func testUninstallUserExtensionRemovesIt() async throws {
        let tmp = tempDir()
        let userDir = tmp.appendingPathComponent("user")
        let source = tmp.appendingPathComponent("source")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSource(into: source, id: "com.test.hello")

        let registry = makeRegistry(userDir: userDir)
        try registry.installLocal(from: source)
        XCTAssertNotNil(registry.record(id: "com.test.hello"))

        try await registry.uninstall(id: "com.test.hello")
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
        let tmp = tempDir()
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
        try requireHeavyTests()
        let tmp = tempDir()
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

    func testCannotUninstallSystemExtension() async throws {
        // A registry whose only "system" dir is our source — the loaded record is
        // flagged system and must refuse uninstall.
        let tmp = tempDir()
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
            defaults: scratchDefaults("test"),
            services: NoopServices())
        registry.discover()
        XCTAssertEqual(registry.record(id: "com.test.sys")?.isSystem, true)
        do {
            try await registry.uninstall(id: "com.test.sys")
            XCTFail("a system extension was uninstalled")
        } catch {
            XCTAssertEqual(error as? ExtensionError, .cannotUninstallSystem("com.test.sys"))
        }
    }
}

// MARK: - #883 manifest size and nesting caps

/// #883: every reader of extension.toml (built-in discover, local install, the market id binding)
/// refuses one over `TOMLGuard.maxBytes` or nested deeper than `TOMLGuard.maxDepth` before the
/// decoder runs, and the kit decode bounds its own depth under deep table headers. Every input here
/// nests 200 deep at most, so even a reader that skipped a cap would decode it without risk to this
/// process (QA #107 and the measure below: ~1500 decode levels fill the 8 MiB main stack).
@MainActor
final class ExtensionManifestCapTests: XCTestCase {
    private let d = TOMLGuard.maxDepth
    /// The existing malformed-manifest reason. Only `TOMLGuard` (inside decodeGuarded) and the bounded
    /// read throw it, so seeing it proves the decoder never ran.
    private let nestedReason = ExtensionLoadError.parse(String(describing: TOMLGuard.Rejected()))
    private var tooLarge: ExtensionLoadError { nestedReason }

    private static let head = """
    [extension]
    id = "com.test.capped"
    name = "capped"
    title = "Capped"
    description = "A test extension"
    version = "1.0.0"
    author = "tester"

    [extension.host]
    min_version = "2.0.0"
    api_level = 1

    [extension.entry]
    main = "init.lua"

    [contributes.kit]

    """

    nonisolated private func arrays(_ n: Int) -> String { "deep = " + String(repeating: "[", count: n) + "1" + String(repeating: "]", count: n) + "\n" }
    nonisolated private func tables(_ n: Int) -> String { "deep = " + String(repeating: "{a = ", count: n) + "1" + String(repeating: "}", count: n) + "\n" }
    /// `[contributes.kit.a.a…]` with n segments under the kit: thousands crash an unguarded decode, so these
    /// are safe only because TOMLGuard refuses them before any parse (n = 400 000 is ~800 KB, under 1 MiB).
    nonisolated private func header(_ n: Int) -> String {
        "[contributes.kit." + Array(repeating: "a", count: n - 2).joined(separator: ".") + "]\nx = 1\n"
    }
    /// Precondition before handing a deep header to a reader: if the guard ever let one through, the reader
    /// would overflow the stack and take the whole xctest run, so the test fails instead of calling it.
    private func deepHeadersRefused() -> Bool {
        for n in [20_000, 400_000] where TOMLGuard.accepts(Self.head + header(n)) {
            XCTFail("guard let a \(n)-segment header through; not calling the readers")
            return false
        }
        return true
    }
    /// `[{a = [{a = …}]}]`: n containers, alternating array and inline table.
    nonisolated private func mixed(_ n: Int) -> String {
        var open = "", close = ""
        for i in 0..<n {
            open += i % 2 == 0 ? "[" : "{a = "
            close = (i % 2 == 0 ? "]" : "}") + close
        }
        return "deep = " + open + "1" + close + "\n"
    }

    /// An extension dir whose manifest is `head + body`, padded with a comment to `size` bytes.
    @discardableResult
    private func writeExt(_ dir: URL, _ body: String, size: Int? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = Self.head + body
        if let size {
            let pad = size - text.utf8.count - 3
            precondition(pad >= 0)
            text += "# " + String(repeating: "x", count: pad) + "\n"
            precondition(text.utf8.count == size)
        }
        try text.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- noop".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return dir
    }

    private func load(_ dir: URL) throws -> LoadedExtension {
        try ExtensionLoader.load(directory: dir, isSystem: false, hostVersion: "2.0.0")
    }

    private func assertRefused<T>(_ expr: @autoclosure () throws -> T, _ expected: ExtensionLoadError,
                               _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), msg, file: file, line: line) {
            XCTAssertEqual($0 as? ExtensionLoadError, expected, msg, file: file, line: line)
        }
    }

    private func registry(_ tmp: URL, systemDir: URL? = nil) -> ExtensionRegistry {
        ExtensionRegistry(systemDir: systemDir, userDir: tmp.appendingPathComponent("user"), hostVersion: "2.0.0",
                          defaults: scratchDefaults("cap"), services: NoopServices())
    }

    func testDepthAtLimitLoadsAndOneOverIsRefused() throws {
        let tmp = tempDir()
        let shapes: [(String, (Int) -> String)] = [("arrays", arrays), ("inline tables", tables), ("mixed", mixed)]
        for (name, shape) in shapes {
            let dir = try writeExt(tmp.appendingPathComponent(name.filter(\.isLetter)), shape(d))
            let loaded = try load(dir)
            XCTAssertNotNil(loaded.manifest.contributes?.kit, name)
            try writeExt(dir, shape(d + 1))
            assertRefused(try load(dir), nestedReason, name)
        }
    }

    func testSizeAtLimitLoadsAndOneOverIsRefusedBeforeTheDecode() throws {
        let dir = try writeExt(tempDir().appendingPathComponent("e"), "", size: TOMLGuard.maxBytes)
        XCTAssertNoThrow(try load(dir))
        try writeExt(dir, "", size: TOMLGuard.maxBytes + 1)
        assertRefused(try load(dir), tooLarge, "one over")
        // The bounded read refuses on its own (never hands back a truncated text, which injectUpdateURL
        // would write back over the manifest).
        assertRefused(try ExtensionLoader.readManifest(dir.appendingPathComponent("extension.toml")), tooLarge, "read")
        try writeExt(dir, "", size: 3 * TOMLGuard.maxBytes)
        assertRefused(try load(dir), tooLarge, "far over")
    }

    func testBracketsInStringsAndCommentsDoNotCount() throws {
        let deep = String(repeating: "[", count: 100) + String(repeating: "{", count: 100)
        let body = """
        basic = "\(deep)"
        literal = '\(deep)'
        ml_basic = \"\"\"
        \(deep)
        \"\"\"
        ml_literal = '''
        \(deep)
        '''
        # \(deep)

        """
        XCTAssertNoThrow(try load(try writeExt(tempDir().appendingPathComponent("e"), body)))
    }

    func testUnterminatedStringIsRefusedNotLooped() throws {
        let dir = tempDir().appendingPathComponent("e")
        for tail in ["s = \"[[[", "s = '[[[", "s = \"\"\"[[[\n", "s = '''[[[\n", "s = \"x\\"] {
            try writeExt(dir, tail)
            assertRefused(try load(dir), nestedReason, tail)
        }
    }

    /// The bounded read decodes the same text the parent's `String(contentsOf:)` did (BOM included).
    func testReadManifestMatchesTheParentRead() throws {
        let url = tempDir().appendingPathComponent("extension.toml")
        for bytes in [Data("a = 1\n".utf8), Data([0xEF, 0xBB, 0xBF] + Array("a = 1\n".utf8)), Data()] {
            try bytes.write(to: url)
            XCTAssertEqual(try ExtensionLoader.readManifest(url), try String(contentsOf: url, encoding: .utf8))
        }
        try Data([0x61, 0xFF, 0x0A]).write(to: url)
        XCTAssertThrowsError(try String(contentsOf: url, encoding: .utf8))
        assertRefused(try ExtensionLoader.readManifest(url), .unreadable("extension.toml is not valid UTF-8"), "bad utf8")
    }

    func testLocalInstallRefusesBeforeCopying() throws {
        guard deepHeadersRefused() else { return }
        let tmp = tempDir()
        let reg = registry(tmp)
        let src = tmp.appendingPathComponent("src")
        let cases: [(String, Int?, ExtensionLoadError)] = [(arrays(d + 1), nil, nestedReason), ("", TOMLGuard.maxBytes + 1, tooLarge),
                                                             (header(20_000), nil, nestedReason), (header(400_000), nil, nestedReason)]
        for (body, size, expected) in cases {
            try writeExt(src, body, size: size)
            assertRefused(try reg.installLocal(from: src), expected, "installLocal")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("user/com.test.capped").path))
        }
        try writeExt(src, arrays(d))
        XCTAssertEqual(try reg.installLocal(from: src).id, "com.test.capped")
    }

    /// The market path's first reader of the downloaded manifest (before inject + install).
    func testMarketBindingRefuses() throws {
        guard deepHeadersRefused() else { return }
        let tmp = tempDir()
        let reg = registry(tmp)
        let ext = tmp.appendingPathComponent("market")
        let cases: [(String, Int?, ExtensionLoadError)] = [(tables(d + 1), nil, nestedReason), ("", TOMLGuard.maxBytes + 1, tooLarge),
                                                             (header(20_000), nil, nestedReason), (header(400_000), nil, nestedReason)]
        for (body, size, expected) in cases {
            try writeExt(ext, body, size: size)
            assertRefused(try reg.bindMarketIdentity(extDir: ext, expected: "com.test.capped"), expected, "market")
        }
        try writeExt(ext, tables(d))
        XCTAssertNoThrow(try reg.bindMarketIdentity(extDir: ext, expected: "com.test.capped"))
    }

    /// Built-in: discover seeds the system dir and loads it; an over-limit one is skipped, its sibling loads.
    func testBuiltInDiscoverSkipsOverLimit() throws {
        guard deepHeadersRefused() else { return }
        let tmp = tempDir()
        let sys = tmp.appendingPathComponent("system")
        try writeExt(sys.appendingPathComponent("deep"), mixed(d + 1))
        let ok = try writeExt(sys.appendingPathComponent("ok"), mixed(d))
        try (Self.head + mixed(d)).replacingOccurrences(of: "com.test.capped", with: "com.test.ok")
            .write(to: ok.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try writeExt(sys.appendingPathComponent("big"), "", size: TOMLGuard.maxBytes + 1)
        try writeExt(sys.appendingPathComponent("header"), header(400_000))
        let reg = registry(tmp, systemDir: sys)
        reg.discover()
        XCTAssertEqual(reg.records.map(\.id), ["com.test.ok"])
    }

    /// Iterative, so measuring a deep value cannot itself recurse.
    private static func depth(_ v: KitTOML) -> Int {
        var stack = [(v, 1)], deepest = 0
        while let top = stack.popLast() {
            let (x, d) = top
            deepest = max(deepest, d)
            switch x {
            case .table(let t): stack += t.values.map { ($0, d + 1) }
            case .array(let a): stack += a.map { ($0, d + 1) }
            default: break
            }
        }
        return deepest
    }

    /// The kit decode bounds its own depth (second line behind TOMLGuard). A 100-segment header is refused
    /// by the guard, so it is decoded here WITHOUT the guard; a `[[…]]` chain of 50 headers (52 segments
    /// each, under the header cap) nests ~100 levels and goes through the real load. 100 levels uncapped is
    /// ~0.55 MB of debug decode frames (testMeasureDecoderAtLowDepths: ~5.4 KB a level): safe.
    func testKitDecodeDepthIsBoundedUnderDeepTableHeaders() throws {
        let dotted = "[contributes.kit." + Array(repeating: "a", count: 100).joined(separator: ".") + "]\nx = 1\n"
        XCTAssertFalse(TOMLGuard.accepts(Self.head + dotted))
        let raw = try TOMLDecoder().decode(ExtensionManifest.self, from: Self.head + dotted)
        var chained = "", path = "contributes.kit"
        for _ in 0..<50 { path += ".a"; chained += "[[\(path)]]\n" }   // an array and a table per header
        XCTAssertTrue(TOMLGuard.accepts(Self.head + chained))
        let loaded = try load(try writeExt(tempDir().appendingPathComponent("e"), chained))
        for (name, manifest) in [("dotted header, unguarded", raw), ("arrays of tables", loaded.manifest)] {
            let kit = try XCTUnwrap(manifest.contributes?.kit, name)
            XCTAssertLessThanOrEqual(Self.depth(kit), TOMLGuard.maxDepth, name)
            XCTAssertFalse(KitManifest.parse(kit).refusals.isEmpty, name)
        }
    }

    // MARK: Facts for the report (#883 item 2): low depths only, on a 64 MiB stack

    /// Mirrors `KitTOML.init(from:)` and records the lowest stack address its decode reaches.
    private struct Probe: Decodable {
        nonisolated(unsafe) static var low = UInt.max
        init(from decoder: Decoder) throws {
            var here = 0
            Probe.low = min(Probe.low, withUnsafeMutablePointer(to: &here) { UInt(bitPattern: $0) })
            if let c = try? decoder.singleValueContainer(), (try? c.decode(Int64.self)) != nil { return }
            if var c = try? decoder.unkeyedContainer() {
                while !c.isAtEnd { _ = try c.decode(Probe.self) }
            }
        }
    }
    private struct ProbeDoc: Decodable { let deep: Probe }
    private struct KitDoc: Decodable { let deep: KitTOML }

    nonisolated func testMeasureDecoderAtLowDepths() {
        let done = DispatchSemaphore(value: 0)
        let lines = LockedLines()
        let thread = Thread { @Sendable in
            for n in [64, 256, 1024] {
                let text = "deep = " + String(repeating: "[", count: n) + "1" + String(repeating: "]", count: n) + "\n"
                var base = 0
                let top = withUnsafeMutablePointer(to: &base) { UInt(bitPattern: $0) }
                Probe.low = .max
                let probed = (try? TOMLDecoder().decode(ProbeDoc.self, from: text)) != nil
                let used = top > Probe.low ? top - Probe.low : 0
                let start = Date()
                let kit = (try? TOMLDecoder().decode(KitDoc.self, from: text)) != nil
                let ms = Date().timeIntervalSince(start) * 1000
                lines.add("MEASURE #883 depth=\(n) probeDecoded=\(probed) decodeStackBytes=\(used) perLevel=\(used / UInt(n)) kitDecoded=\(kit) kitMs=\(String(format: "%.2f", ms))")
            }
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        for line in lines.all { print(line) }
        XCTAssertEqual(lines.all.count, 3)
        XCTAssertTrue(lines.all.allSatisfy { $0.contains("probeDecoded=true") && $0.contains("kitDecoded=true") })
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
