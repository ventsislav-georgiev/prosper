import XCTest
@testable import ProsperApp

/// Foreign-config importers + canonical round-trip for `MCPConfigStore`. These are the
/// correctness-critical parsers (a wrong map silently mis-launches a tool server).
final class MCPImportTests: XCTestCase {

    private func server(_ list: [MCPServer], _ id: String) -> MCPServer? {
        list.first { $0.id == id }
    }

    // MARK: Claude Code / canonical `mcpServers`

    func testImportClaudeCodeJSON() {
        let json = """
        { "mcpServers": {
          "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"], "env": {"K": "v"} },
          "api": { "type": "http", "url": "https://mcp.example.com/mcp" }
        }}
        """
        let out = MCPConfigStore.importServers(from: json)
        XCTAssertEqual(out.count, 2)
        let c7 = server(out, "context7")
        XCTAssertEqual(c7?.transport, .stdio)
        XCTAssertEqual(c7?.command, "npx")
        XCTAssertEqual(c7?.args, ["-y", "@upstash/context7-mcp"])
        XCTAssertEqual(c7?.env, ["K": "v"])
        let api = server(out, "api")
        XCTAssertEqual(api?.transport, .http)
        XCTAssertEqual(api?.url, "https://mcp.example.com/mcp")
    }

    /// A typeless entry with a url but no command is HTTP; with a command is stdio.
    func testTransportInferredWithoutTypeKey() {
        let json = """
        { "mcpServers": {
          "remote": { "url": "https://x.example.com/mcp" },
          "local":  { "command": "node", "args": ["server.js"] }
        }}
        """
        let out = MCPConfigStore.importServers(from: json)
        XCTAssertEqual(server(out, "remote")?.transport, .http)
        XCTAssertEqual(server(out, "local")?.transport, .stdio)
    }

    // MARK: opencode

    func testImportOpencodeJSON() {
        let json = """
        { "$schema": "https://opencode.ai/config.json", "mcp": {
          "my-local":  { "type": "local",  "command": ["npx", "-y", "x-mcp"], "environment": {"E": "1"}, "enabled": false },
          "my-remote": { "type": "remote", "url": "https://r.example.com", "enabled": true }
        }}
        """
        let out = MCPConfigStore.importServers(from: json)
        XCTAssertEqual(out.count, 2)
        let local = server(out, "my-local")
        XCTAssertEqual(local?.transport, .stdio)
        XCTAssertEqual(local?.command, "npx")          // command[0]
        XCTAssertEqual(local?.args, ["-y", "x-mcp"])    // command[1...]
        XCTAssertEqual(local?.env, ["E": "1"])          // `environment` → env
        XCTAssertEqual(local?.enabled, false)
        XCTAssertEqual(server(out, "my-remote")?.transport, .http)
        XCTAssertEqual(server(out, "my-remote")?.url, "https://r.example.com")
    }

    // MARK: codex config.toml

    func testImportCodexTOML() {
        let toml = """
        model = "gemma"
        model_provider = "prosper"

        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        default_tools_approval_mode = "auto"

        [mcp_servers.remote_api]
        url = "https://api.example.com/mcp"
        bearer_token_env_var = "EXAMPLE_TOKEN"
        """
        let out = MCPConfigStore.importServers(from: toml)
        XCTAssertEqual(out.count, 2)
        let c7 = server(out, "context7")
        XCTAssertEqual(c7?.transport, .stdio)
        XCTAssertEqual(c7?.args, ["-y", "@upstash/context7-mcp"])
        XCTAssertEqual(c7?.approvalMode, .auto)
        let remote = server(out, "remote_api")
        XCTAssertEqual(remote?.transport, .http)
        XCTAssertEqual(remote?.url, "https://api.example.com/mcp")
        XCTAssertEqual(remote?.bearerTokenEnvVar, "EXAMPLE_TOKEN")
    }

    // MARK: Robustness

    func testMalformedTOMLNeverCrashesAndReturnsEmpty() {
        let cases: [(String, String)] = [
            ("unterminated string", "[mcp_servers.x]\ncommand = \"npx"),
            ("unterminated header", "[mcp_servers.x\ncommand = \"npx\""),
            ("duplicate key", "[mcp_servers.x]\ncommand = \"a\"\ncommand = \"b\""),
            ("key without value", "[mcp_servers.x]\ncommand ="),
            ("command is int", "[mcp_servers.x]\ncommand = 5"),
            ("args is string", "[mcp_servers.x]\ncommand = \"a\"\nargs = \"x\""),
            ("env is array", "[mcp_servers.x]\ncommand = \"a\"\nenv = [\"a\"]"),
            ("dotted key vs table", "mcp_servers.x = 1\n[mcp_servers.x]\ncommand = \"a\""),
            ("open inline table", "mcp_servers = { x = { command = \"x\""),
            ("control char in string", "[mcp_servers.x]\ncommand = \"a\u{01}b\""),
            ("1 MiB of [", String(repeating: "[", count: 1 << 20)),
            ("1 MiB of quote", String(repeating: "\"", count: 1 << 20)),
            // TOMLDecoder 0.4.5 fix shapes (#322 sign-only int, #323 base prefix, #324 float edge, #332 nested arrays, #331 top-level value)
            ("sign-only int", "[mcp_servers.x]\ncommand = +"),
            ("bare base prefix", "[mcp_servers.x]\ncommand = 0x"),
            ("signed base prefix", "[mcp_servers.x]\ncommand = -0b1"),
            ("float edge", "[mcp_servers.x]\ncommand = 1e"),
            ("float trailing dot", "[mcp_servers.x]\ncommand = 1."),
            ("nested bare array", "[mcp_servers.x]\nargs = [[1, a]]"),
            ("top-level value", "= 1"),
        ]
        for (name, input) in cases {
            XCTAssertTrue(MCPConfigStore.importServers(from: input).isEmpty, name)
        }
    }

    func testBrokenJSONReturnsEmpty() {
        XCTAssertTrue(MCPConfigStore.importServers(from: "{ not valid").isEmpty)
        XCTAssertTrue(MCPConfigStore.importServers(from: "").isEmpty)
    }

    func testDecodeBrokenFileIsNil() {
        // reloadIfChanged relies on decode → nil so the last good config is kept.
        XCTAssertNil(MCPConfigStore.decode("{ \"mcpServers\":"))
    }

    // MARK: Launch bootstrap (#311) — scratch directory, never the real ~/.config

    /// Points the store at a scratch file with a known prefs value and a cleared mirror
    /// (so the pre-#311 code would have rewritten the file), then restores everything.
    private func withScratchFile(_ body: (URL) throws -> Void) rethrows {
        let dir = tempDir("bootstrap")
        let savedURL = MCPConfigStore.fileURL, savedPrefs = Preferences.mcpServers
        let savedMirror = Preferences.defaults.string(forKey: "agentMCPDiskMirror")
        MCPConfigStore.fileURL = dir.appendingPathComponent("config.json")
        Preferences.mcpServers = [MCPServer(id: "keep", transport: .stdio, enabled: true, command: "npx")]
        Preferences.defaults.removeObject(forKey: "agentMCPDiskMirror")
        defer {
            MCPConfigStore.fileURL = savedURL
            Preferences.mcpServers = savedPrefs
            Preferences.defaults.set(savedMirror, forKey: "agentMCPDiskMirror")
            try? FileManager.default.removeItem(at: dir)
        }
        try body(MCPConfigStore.fileURL)
    }

    func testBootstrapLeavesMalformedFileByteForByte() throws {
        try withScratchFile { url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let broken = Data(#"{ "mcpServers": { "half-edited": "#.utf8)
            try broken.write(to: url)
            let before = Preferences.mcpServers
            MCPConfigStore.bootstrap()
            XCTAssertEqual(try Data(contentsOf: url), broken, "malformed user edit was overwritten")
            XCTAssertEqual(Preferences.mcpServers, before, "last good config must stay live")
        }
    }

    func testBootstrapCreatesAbsentFile() throws {
        try withScratchFile { url in
            Preferences.defaults.set(MCPConfigStore.encode(Preferences.mcpServers), forKey: "agentMCPDiskMirror")
            MCPConfigStore.bootstrap()
            let written = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(MCPConfigStore.decode(written), Preferences.mcpServers)
        }
    }

    // MARK: Unreadable-but-present file (#351): never replaced at launch

    /// Writes a non-UTF-8 file at the store path, sets the mirror, bootstraps, and
    /// asserts the bytes and the mirror both survive.
    private func assertNonUTF8FileKept(mirror makeMirror: @autoclosure () -> String?, file: StaticString = #filePath, line: UInt = #line) throws {
        try withScratchFile { url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data([0xff, 0xfe, 0x00, 0x41, 0x42, 0x43])
            try bytes.write(to: url)
            let mirror = makeMirror()
            Preferences.defaults.set(mirror, forKey: "agentMCPDiskMirror")
            MCPConfigStore.bootstrap()
            XCTAssertEqual(try Data(contentsOf: url), bytes, "unreadable user file was replaced", file: file, line: line)
            XCTAssertEqual(Preferences.defaults.string(forKey: "agentMCPDiskMirror"), mirror, "mirror must be left as is", file: file, line: line)
        }
    }

    func testBootstrapKeepsNonUTF8FileWhenMirrorMatchesPrefs() throws {
        // Non-empty prefs (set by withScratchFile) + matching mirror, evaluated inside the
        // scratch scope: only clearing the mirror makes writeFile write.
        try assertNonUTF8FileKept(mirror: MCPConfigStore.encode(Preferences.mcpServers))
    }

    func testBootstrapKeepsNonUTF8FileWhenMirrorIsStale() throws {
        try assertNonUTF8FileKept(mirror: "stale")
    }

    func testBootstrapLeavesDirectoryAtPath() throws {
        try withScratchFile { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            Preferences.defaults.set("stale", forKey: "agentMCPDiskMirror")
            MCPConfigStore.bootstrap()
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
            XCTAssertEqual(Preferences.defaults.string(forKey: "agentMCPDiskMirror"), "stale", "mirror must be left as is")
        }
    }

    func testBootstrapRecreatesAbsentFileWithStaleMirror() throws {
        try withScratchFile { url in
            Preferences.defaults.set("stale", forKey: "agentMCPDiskMirror")
            MCPConfigStore.bootstrap()
            XCTAssertNotNil(MCPConfigStore.decode(try String(contentsOf: url, encoding: .utf8)))
        }
    }

    func testBootstrapCreatesAbsentFileWithNilMirror() throws {
        try withScratchFile { url in  // withScratchFile leaves the mirror nil
            MCPConfigStore.bootstrap()
            XCTAssertEqual(MCPConfigStore.decode(try String(contentsOf: url, encoding: .utf8)), Preferences.mcpServers)
        }
    }

    func testBootstrapAdoptsDifferentValidFile() throws {
        try withScratchFile { url in
            let json = try XCTUnwrap(MCPConfigStore.encode([MCPServer(id: "disk", transport: .stdio, enabled: true, command: "uvx")]))
            try json.write(to: url, atomically: true, encoding: .utf8)
            Preferences.defaults.set("stale", forKey: "agentMCPDiskMirror")
            MCPConfigStore.bootstrap()
            XCTAssertEqual(Preferences.mcpServers.map(\.id), ["disk"])
            XCTAssertEqual(Preferences.defaults.string(forKey: "agentMCPDiskMirror"), json)
        }
    }

    func testBootstrapFileEqualToMirrorWritesPrefs() throws {
        try withScratchFile { url in
            let json = try XCTUnwrap(MCPConfigStore.encode([MCPServer(id: "old", transport: .stdio, enabled: true, command: "uvx")]))
            try json.write(to: url, atomically: true, encoding: .utf8)
            Preferences.defaults.set(json, forKey: "agentMCPDiskMirror")
            MCPConfigStore.bootstrap()  // unchanged on disk: in-app prefs win and land on disk
            XCTAssertEqual(MCPConfigStore.decode(try String(contentsOf: url, encoding: .utf8))?.map(\.id), ["keep"])
        }
    }

    // MARK: Symlinked config (#391): a dotfiles link survives, writes land on its target

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func testWriteFollowsValidSymlink() throws {
        try withScratchFile { url in
            let target = tempDir("dotfiles").appendingPathComponent("mcp.json")
            try "{}".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            MCPConfigStore.writeFile(Preferences.mcpServers)
            XCTAssertTrue(isSymlink(url), "link was replaced by a regular file")
            XCTAssertEqual(MCPConfigStore.decode(try String(contentsOf: target, encoding: .utf8)), Preferences.mcpServers)
        }
    }

    func testBootstrapLeavesDanglingSymlinkAndWriteCreatesTarget() throws {
        try withScratchFile { url in
            let target = tempDir("dotfiles").appendingPathComponent("sub/mcp.json")
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            Preferences.defaults.set("stale", forKey: "agentMCPDiskMirror")
            MCPConfigStore.bootstrap()
            XCTAssertTrue(isSymlink(url), "dangling link was replaced")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "bootstrap treated the link as absent")
            XCTAssertEqual(Preferences.defaults.string(forKey: "agentMCPDiskMirror"), "stale", "mirror must be left as is")
            MCPConfigStore.writeFile(Preferences.mcpServers)
            XCTAssertTrue(isSymlink(url), "write replaced the dangling link")
            XCTAssertEqual(MCPConfigStore.decode(try String(contentsOf: target, encoding: .utf8)), Preferences.mcpServers)
        }
    }

    /// Source pin: the unreadable branch of bootstrap logs before returning.
    func testBootstrapUnreadableBranchLogs() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/ProsperApp/MCPConfigStore.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        guard let start = text.range(of: "if onDisk == nil {"),
              let end = text.range(of: "return", range: start.upperBound..<text.endIndex)
        else { return XCTFail("unreadable branch not found in MCPConfigStore.swift") }
        XCTAssertTrue(text[start.upperBound..<end.lowerBound].contains(".error("), "unreadable branch must log")
    }

    // MARK: Canonical encode/decode round-trip

    func testRoundTrip() {
        let servers = [
            MCPServer(id: "context7", transport: .stdio, enabled: true,
                      command: "npx", args: ["-y", "@upstash/context7-mcp"], env: ["K": "v"],
                      approvalMode: .prompt),
            MCPServer(id: "api", transport: .http, enabled: false,
                      url: "https://mcp.example.com/mcp", bearerTokenEnvVar: "TOK",
                      approvalMode: .auto),
        ]
        guard let json = MCPConfigStore.encode(servers),
              let back = MCPConfigStore.decode(json) else { return XCTFail("encode/decode failed") }
        XCTAssertEqual(back.count, 2)
        let c7 = server(back, "context7")
        XCTAssertEqual(c7?.command, "npx")
        XCTAssertEqual(c7?.args, ["-y", "@upstash/context7-mcp"])
        XCTAssertEqual(c7?.env, ["K": "v"])
        XCTAssertEqual(c7?.enabled, true)
        let api = server(back, "api")
        XCTAssertEqual(api?.transport, .http)
        XCTAssertEqual(api?.bearerTokenEnvVar, "TOK")
        XCTAssertEqual(api?.enabled, false)
        XCTAssertEqual(api?.approvalMode, .auto)
    }
}
