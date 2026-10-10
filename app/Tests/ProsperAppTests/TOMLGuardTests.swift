import XCTest
@testable import ProsperApp

/// QA #107: dduan/TOMLDecoder recurses without a depth limit, so deep nesting
/// SIGSEGVs the process. Every trapping text here is checked against `TOMLGuard`
/// FIRST and the routing tests bail before calling a site if the guard would let
/// it through — handing one to the real decoder would kill the whole xctest run.
final class TOMLGuardTests: XCTestCase {

    // Generated trapping shapes (sizes from the QA report).
    private let inlineTables = "a = " + String(repeating: "{b = ", count: 3000) + "1" + String(repeating: "}", count: 3000)
    private let arrays = "a = " + String(repeating: "[", count: 5000) + "1" + String(repeating: "]", count: 5000)
    private let dottedKey = Array(repeating: "a", count: 5000).joined(separator: ".") + " = 1"
    private let unclosed = "a = " + String(repeating: "[", count: 5000)
    private let oversized = "a = \"" + String(repeating: "x", count: 1 << 20) + "\""

    private var trapping: [(String, String)] {
        [("inline tables", inlineTables), ("arrays", arrays), ("dotted key", dottedKey),
         ("unclosed", unclosed), ("over 1 MiB", oversized)]
    }

    func testRejectsTrappingShapes() {
        for (name, text) in trapping {
            XCTAssertFalse(TOMLGuard.accepts(text), name)
        }
    }

    func testAcceptsLegitDocuments() {
        let d = TOMLGuard.maxDepth
        let cases: [(String, String)] = [
            ("64-deep arrays", "a = " + String(repeating: "[", count: d) + "1.5" + String(repeating: "]", count: d)),
            ("64-segment dotted key", Array(repeating: "a", count: d + 1).joined(separator: ".") + " = 1"),
            ("brackets in strings", "a = \"[[[[[[{{{{\"\nb = 'x[[[['\nc = \"\"\"\n[[[[\n{{{{\n\"\"\"\nd = '''\n[[[['''"),
            ("brackets in comment", "# {{{{ [[[[\na = 1 # ]]]] [[[["),
            ("escaped quote", "a = \"\\\"[[[[\"\nb = 1"),
            ("floats and dates", "a = [1.5, 2.25, 3.0]\nb = 1979-05-27T07:32:00.999Z"),
        ]
        for (name, text) in cases {
            XCTAssertTrue(TOMLGuard.accepts(text), name)
        }
        // Strings must actually hide their brackets: the same text with 65 of them in a string.
        XCTAssertTrue(TOMLGuard.accepts("a = \"" + String(repeating: "[", count: d + 1) + "\""))
        XCTAssertFalse(TOMLGuard.accepts("a = " + String(repeating: "[", count: d + 1)))
    }

    /// Every bundled and example extension.toml passes the guard.
    func testAcceptsShippedManifests() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found = 0
        for root in ["Sources/ProsperApp/Resources/extensions", "Examples/extensions"] {
            let base = app.appendingPathComponent(root)
            let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.lastPathComponent == "extension.toml" else { continue }
                found += 1
                XCTAssertTrue(TOMLGuard.accepts(try String(contentsOf: url, encoding: .utf8)), url.path)
            }
        }
        XCTAssertGreaterThan(found, 5)
    }

    func testAcceptsStoreFixtures() {
        XCTAssertTrue(TOMLGuard.accepts("""
        model = "gemma"
        model_provider = "prosper"

        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        default_tools_approval_mode = "auto"

        [mcp_servers.remote_api]
        url = "https://api.example.com/mcp"
        bearer_token_env_var = "EXAMPLE_TOKEN"
        """))
        XCTAssertTrue(TOMLGuard.accepts("""
        model = "gemma"

        [[hooks.PreToolUse]]
        matcher = "Bash"

        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "echo hi"
        timeout = 10
        """))
    }

    /// Scans app sources: files calling the raw decoder, and the count of guarded calls.
    private func decodeSites() throws -> (raw: [String], guarded: Int) {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var raw: [String] = [], guarded = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "TOMLGuard.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("TOMLDecoder().decode(") { raw.append(url.lastPathComponent) }
            guarded += text.components(separatedBy: "TOMLDecoder().decodeGuarded(").count - 1
        }
        return (raw, guarded)
    }

    /// Precondition of every routing test: the guard rejects the text AND no site calls
    /// the raw decoder. Either failing means the site would hand trapping text to
    /// `TOMLDecoder` and SIGSEGV the run, so the test fails instead of calling it.
    private func safeToCallSites() throws -> Bool {
        for (name, text) in trapping where TOMLGuard.accepts(text) {
            XCTFail("guard let \(name) through; not calling the sites")
            return false
        }
        let sites = try decodeSites()
        guard sites.raw.isEmpty, sites.guarded == 3 else {
            XCTFail("unguarded decode in \(sites.raw), guarded=\(sites.guarded); not calling the sites")
            return false
        }
        return true
    }

    /// Structural: no app source calls the raw decoder, so a site that drops the guard
    /// fails here without any trapping text ever reaching `TOMLDecoder`.
    func testNoSourceBypassesTheGuard() throws {
        let sites = try decodeSites()
        XCTAssertEqual(sites.raw, [])
        XCTAssertEqual(sites.guarded, 3)
    }

    // MARK: Routing — each site takes its malformed-TOML path

    func testMCPImportRoutesRejectedTextToMalformedPath() throws {
        guard try safeToCallSites() else { return }
        for (name, text) in trapping {
            XCTAssertTrue(MCPConfigStore.importServers(from: text).isEmpty, name)
        }
    }

    func testHooksImportRoutesRejectedTextToMalformedPath() throws {
        guard try safeToCallSites() else { return }
        for (name, text) in trapping {
            XCTAssertTrue(HooksConfigStore.importHooks(from: text).isEmpty, name)
        }
    }

    func testExtensionLoaderRoutesRejectedTextToParseError() throws {
        guard try safeToCallSites() else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-tomlguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in trapping {
            try text.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ExtensionLoader.load(directory: dir, isSystem: false, hostVersion: "2.0.0"), name) { error in
                guard case .parse? = error as? ExtensionLoadError else { return XCTFail("\(name): \(error)") }
            }
        }
    }
}
