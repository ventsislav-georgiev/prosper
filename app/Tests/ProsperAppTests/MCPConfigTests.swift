import XCTest
@testable import ProsperApp

/// Covers the MCP server model + its `config.toml` rendering — the contract codex
/// reads at app-server startup. A regression here silently breaks tool availability.
final class MCPConfigTests: XCTestCase {

    func testCodecRoundTrip() throws {
        let servers = [
            MCPServer(id: "context7", transport: .stdio, enabled: true,
                      command: "npx", args: ["-y", "@upstash/context7-mcp"],
                      env: ["TOKEN": "abc"], approvalMode: .prompt),
            MCPServer(id: "figma", transport: .http, enabled: false,
                      url: "https://mcp.figma.com/mcp", bearerTokenEnvVar: "FIGMA_TOKEN",
                      approvalMode: .approve),
        ]
        let data = try JSONEncoder().encode(servers)
        let decoded = try JSONDecoder().decode([MCPServer].self, from: data)
        XCTAssertEqual(decoded, servers)
    }

    func testStdioRendersExpectedTOML() {
        let s = MCPServer(id: "context7", transport: .stdio, enabled: true,
                          command: "npx", args: ["-y", "@upstash/context7-mcp"],
                          env: ["TOKEN": "abc"], approvalMode: .prompt)
        let toml = MCPServer.tomlBlocks(for: [s])
        XCTAssertTrue(toml.contains("[mcp_servers.context7]"))
        XCTAssertTrue(toml.contains("command = \"npx\""))
        XCTAssertTrue(toml.contains("args = [\"-y\", \"@upstash/context7-mcp\"]"))
        XCTAssertTrue(toml.contains("default_tools_approval_mode = \"prompt\""))
        XCTAssertTrue(toml.contains("[mcp_servers.context7.env]"))
        XCTAssertTrue(toml.contains("\"TOKEN\" = \"abc\""))
    }

    func testHTTPRendersURLAndBearer() {
        let s = MCPServer(id: "figma", transport: .http, enabled: true,
                          url: "https://mcp.figma.com/mcp", bearerTokenEnvVar: "FIGMA_TOKEN",
                          approvalMode: .approve)
        let toml = MCPServer.tomlBlocks(for: [s])
        XCTAssertTrue(toml.contains("[mcp_servers.figma]"))
        XCTAssertTrue(toml.contains("url = \"https://mcp.figma.com/mcp\""))
        XCTAssertTrue(toml.contains("bearer_token_env_var = \"FIGMA_TOKEN\""))
        XCTAssertFalse(toml.contains("command ="), "http server must not emit a command")
    }

    func testDisabledAndInvalidServersAreSkipped() {
        let disabled = MCPServer(id: "off", transport: .stdio, enabled: false, command: "x")
        let noCommand = MCPServer(id: "blank", transport: .stdio, enabled: true, command: "  ")
        let noURL = MCPServer(id: "nourl", transport: .http, enabled: true, url: "")
        XCTAssertEqual(MCPServer.tomlBlocks(for: [disabled, noCommand, noURL]), "",
                       "no renderable servers → empty string (config unchanged)")
    }

    func testDuplicateKeysCollapseToFirst() {
        let a = MCPServer(id: "dup", transport: .stdio, enabled: true, command: "first")
        let b = MCPServer(id: "dup", transport: .stdio, enabled: true, command: "second")
        let toml = MCPServer.tomlBlocks(for: [a, b])
        XCTAssertEqual(toml.components(separatedBy: "[mcp_servers.dup]").count - 1, 1,
                       "only one [mcp_servers.dup] table may be emitted")
        XCTAssertTrue(toml.contains("command = \"first\""))
        XCTAssertFalse(toml.contains("command = \"second\""))
    }

    func testIDSanitizedToBareKey() {
        let s = MCPServer(id: "my server!", transport: .stdio, enabled: true, command: "x")
        let toml = MCPServer.tomlBlocks(for: [s])
        XCTAssertTrue(toml.contains("[mcp_servers.my_server_]"),
                      "non-bare-key chars must become underscores")
    }

    func testQuotingEscapesSpecials() {
        let s = MCPServer(id: "q", transport: .stdio, enabled: true,
                          command: #"a"b\c"#)
        let toml = MCPServer.tomlBlocks(for: [s])
        XCTAssertTrue(toml.contains(#"command = "a\"b\\c""#),
                      "backslash and quote must be TOML-escaped")
    }
}
