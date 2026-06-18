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

    func testBrokenJSONReturnsEmpty() {
        XCTAssertTrue(MCPConfigStore.importServers(from: "{ not valid").isEmpty)
        XCTAssertTrue(MCPConfigStore.importServers(from: "").isEmpty)
    }

    func testDecodeBrokenFileIsNil() {
        // reloadIfChanged relies on decode → nil so the last good config is kept.
        XCTAssertNil(MCPConfigStore.decode("{ \"mcpServers\":"))
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
