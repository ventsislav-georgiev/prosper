import XCTest
@testable import ProsperApp

/// #1045: a rewrite of mcp.json / hooks.json keeps what the app does not model, and never
/// replaces a file the app could not read. Scratch files only (tempDir), never ~/.config.
final class MCPPassthroughTests: XCTestCase {
    private let mirrorKey = "agentMCPDiskMirror"

    /// Points the store at a scratch file holding `disk` with the mirror cleared (so a write is
    /// never skipped as unchanged), runs `body`, restores both.
    private func withFile(_ disk: Data?, _ body: (URL) throws -> Void) rethrows {
        let url = tempDir("mcp-passthrough").appendingPathComponent("mcp.json")
        let savedURL = MCPConfigStore.fileURL
        let savedMirror = Preferences.defaults.string(forKey: mirrorKey)
        MCPConfigStore.fileURL = url
        Preferences.defaults.removeObject(forKey: mirrorKey)
        defer {
            MCPConfigStore.fileURL = savedURL
            Preferences.defaults.set(savedMirror, forKey: mirrorKey)
        }
        if let disk { try? disk.write(to: url) }
        try body(url)
    }

    private func rewrite(_ disk: String, with servers: [MCPServer]) throws -> String {
        var out = ""
        try withFile(Data(disk.utf8)) { url in
            MCPConfigStore.writeFile(servers)
            out = try String(contentsOf: url, encoding: .utf8)
        }
        return out
    }

    func testUnknownTopLevelKeySurvivesRewrite() throws {
        let out = try rewrite(#"{"$schema": "https://example.com/s.json", "mcpServers": {"api": {"command": "npx"}}}"#,
                              with: [MCPServer(id: "api", command: "npx")])
        XCTAssertEqual(out, """
        {
          "$schema": "https://example.com/s.json",
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "command": "npx",
              "enabled": true,
              "type": "stdio"
            }
          }
        }
        """)
    }

    func testUnknownServerKeySurvivesRewrite() throws {
        let out = try rewrite(#"{"mcpServers": {"api": {"command": "npx", "cwd": "/Users/example/app"}}}"#,
                              with: [MCPServer(id: "api", command: "npx")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "command": "npx",
              "cwd": "/Users/example/app",
              "enabled": true,
              "type": "stdio"
            }
          }
        }
        """)
    }

    /// An unknown nested object is kept whole; `env` is a map the app owns, so a variable
    /// removed in the app is gone from the file.
    func testNestedUnknownObjectKeptWholeAndEnvIsTheApps() throws {
        let disk = #"{"mcpServers": {"api": {"type": "http", "url": "https://mcp.example.com", "#
            + #""headers": {"X-Team": "a", "retry": {"max": 3}}, "env": {"OLD": "1"}}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "api", transport: .http, url: "https://mcp.example.com")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "enabled": true,
              "headers": {
                "X-Team": "a",
                "retry": {
                  "max": 3
                }
              },
              "type": "http",
              "url": "https://mcp.example.com"
            }
          }
        }
        """)
    }

    func testRemovedServerTakesItsUnknownKeys() throws {
        let disk = #"{"mcpServers": {"gone": {"command": "a", "x-gone": 1}, "kept": {"command": "b", "x-kept": 2}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "kept", command: "b")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "kept": {
              "approvalMode": "prompt",
              "command": "b",
              "enabled": true,
              "type": "stdio",
              "x-kept": 2
            }
          }
        }
        """)
    }

    func testEditedServerKeepsItsUnknownKeys() throws {
        let disk = #"{"mcpServers": {"api": {"command": "npx", "type": "stdio", "x-note": "mine"}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "api", enabled: false, command: "uvx", approvalMode: .auto)])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api": {
              "approvalMode": "auto",
              "command": "uvx",
              "enabled": false,
              "type": "stdio",
              "x-note": "mine"
            }
          }
        }
        """)
    }

    /// A server is its id: renamed in the app it starts with no unknown keys, and no other
    /// server picks up the old one's.
    func testRenamedServerStartsWithoutUnknownKeys() throws {
        let disk = #"{"mcpServers": {"api": {"command": "a", "x-old": 1}, "other": {"command": "b", "x-other": 2}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "api-qa", command: "a"), MCPServer(id: "other", command: "b")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api-qa": {
              "approvalMode": "prompt",
              "command": "a",
              "enabled": true,
              "type": "stdio"
            },
            "other": {
              "approvalMode": "prompt",
              "command": "b",
              "enabled": true,
              "type": "stdio",
              "x-other": 2
            }
          }
        }
        """)
    }

    /// The app's value is written for every key it models, and a field it leaves out (args
    /// cleared, url on a stdio server) is not brought back from the file.
    func testModelledKeyWinsOverFileValue() throws {
        let disk = #"{"mcpServers": {"api": {"command": "old", "args": ["-x"], "url": "https://example.com", "approvalMode": "auto"}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "api", command: "new")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "command": "new",
              "enabled": true,
              "type": "stdio"
            }
          }
        }
        """)
    }

    /// Unknown values are written back as the user wrote them: number lexemes, null, escapes.
    func testUnknownValuesKeptAsWritten() throws {
        let disk = #"{"mcpServers": {"api": {"command": "npx", "x-big": 9007199254740993, "x-frac": 0.1, "#
            + #""x-exp": 1e3, "x-one": 1.0, "x-null": null, "x-esc": "q\"b\\sé\/"}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "api", command: "npx")])
        XCTAssertEqual(out, #"""
        {
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "command": "npx",
              "enabled": true,
              "type": "stdio",
              "x-big": 9007199254740993,
              "x-esc": "q\"b\\sé/",
              "x-exp": 1e3,
              "x-frac": 0.1,
              "x-null": null,
              "x-one": 1.0
            }
          }
        }
        """#)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let api = (parsed["mcpServers"] as? [String: Any])?["api"] as? [String: Any]
        XCTAssertEqual((api?["x-big"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)
        XCTAssertEqual(api?["x-esc"] as? String, "q\"b\\s\u{e9}/")
        XCTAssertTrue(api?["x-null"] is NSNull)
    }

    /// A file with no `mcpServers` key is readable as "no servers": written, its keys kept.
    func testFileWithoutServersKeyIsWrittenAndKept() throws {
        let out = try rewrite(#"{"other": [1, 2]}"#, with: [MCPServer(id: "api", command: "npx")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "command": "npx",
              "enabled": true,
              "type": "stdio"
            }
          },
          "other": [
            1,
            2
          ]
        }
        """)
    }

    /// Fact 4: before #1045 an in-app write replaced a file the app could not read.
    private func assertNotOverwritten(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        try withFile(bytes) { url in
            MCPConfigStore.writeFile([MCPServer(id: "api", command: "npx")])
            XCTAssertEqual(try Data(contentsOf: url), bytes, "unreadable file was overwritten", file: file, line: line)
            XCTAssertTrue(Preferences.defaults.string(forKey: mirrorKey) == nil, "mirror moved", file: file, line: line)
        }
    }

    func testMalformedJSONNotOverwritten() throws {
        try assertNotOverwritten(Data(#"{ "mcpServers": { "half-edited": "#.utf8))
    }

    func testTopLevelArrayNotOverwritten() throws {
        try assertNotOverwritten(Data(#"[{"mcpServers": {}}]"#.utf8))
    }

    func testServerNotAnObjectNotOverwritten() throws {
        try assertNotOverwritten(Data(#"{"mcpServers": {"api": "npx"}}"#.utf8))
    }

    func testModelledFieldOfWrongTypeNotOverwritten() throws {
        try assertNotOverwritten(Data(#"{"mcpServers": {"api": {"command": "npx", "enabled": "yes"}}}"#.utf8))
    }

    func testNonUTF8FileNotOverwritten() throws {
        try assertNotOverwritten(Data([0x7B, 0xFF, 0xFE, 0x7D]))
    }

    // MARK: round 2: the file's own transport `type`, BOM and duplicate keys

    func testSSETypeSurvivesEditOfAnotherField() throws {
        let disk = #"{"mcpServers": {"api": {"type": "sse", "url": "https://mcp.example.com/sse"}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "api", transport: .http, enabled: false,
                                                     url: "https://mcp.example.com/sse")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "enabled": false,
              "type": "sse",
              "url": "https://mcp.example.com/sse"
            }
          }
        }
        """)
    }

    func testServerSwitchedToStdioGetsStdio() throws {
        let disk = #"{"mcpServers": {"api": {"type": "sse", "url": "https://mcp.example.com/sse"}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "api", command: "npx")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "command": "npx",
              "enabled": true,
              "type": "stdio"
            }
          }
        }
        """)
    }

    func testCapitalSSEKeptAsWritten() throws {
        let disk = #"{"mcpServers": {"api": {"type": "SSE", "url": "https://mcp.example.com/sse"}}}"#
        let out = try rewrite(disk, with: [MCPServer(id: "api", transport: .http, url: "https://mcp.example.com/sse")])
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "api": {
              "approvalMode": "prompt",
              "enabled": true,
              "type": "SSE",
              "url": "https://mcp.example.com/sse"
            }
          }
        }
        """)
        XCTAssertEqual(MCPConfigStore.decode(out)?.map(\.transport), [.http])
    }

    private let bomFile = Data([0xEF, 0xBB, 0xBF] + Array(#"{"mcpServers": {"api": {"command": "npx"}}}"#.utf8))
    private let duplicateKeyFile = Data(#"{"mcpServers": {"api": {"command": "npx", "x": 1, "x": 2}}}"#.utf8)

    /// Pins what happens (round 2 found it, the round 1 report said otherwise): the UTF-8 read
    /// drops the BOM, so the file is readable and an in-app write replaces it without the BOM.
    func testBOMFileIsReadAndRewrittenWithoutBOM() throws {
        try withFile(bomFile) { url in
            MCPConfigStore.writeFile([MCPServer(id: "api", command: "npx", approvalMode: .auto)])
            XCTAssertEqual(try Data(contentsOf: url), Data("""
            {
              "mcpServers": {
                "api": {
                  "approvalMode": "auto",
                  "command": "npx",
                  "enabled": true,
                  "type": "stdio"
                }
              }
            }
            """.utf8))
        }
    }
    func testDuplicateKeyFileLeftByteIdentical() throws { try assertNotOverwritten(duplicateKeyFile) }

    /// The premise of the two pins above: the app's own reader accepts both files.
    func testBOMAndDuplicateKeyFilesAreReadByTheApp() throws {
        try withFile(bomFile) { url in
            XCTAssertEqual(MCPConfigStore.decode(try String(contentsOf: url, encoding: .utf8))?.map(\.id), ["api"])
        }
        try withFile(duplicateKeyFile) { url in
            XCTAssertEqual(MCPConfigStore.decode(try String(contentsOf: url, encoding: .utf8))?.map(\.id), ["api"])
        }
    }

    func testAbsentFileIsWritten() throws {
        try withFile(nil) { url in
            MCPConfigStore.writeFile([MCPServer(id: "api", command: "npx")])
            XCTAssertEqual(MCPConfigStore.decode(try String(contentsOf: url, encoding: .utf8))?.map(\.id), ["api"])
        }
    }

    /// The no-change skip still holds with unknown keys on disk: the second write of the same
    /// list leaves the file alone (an atomic write would give it a new inode).
    func testUnchangedRewriteLeavesFileAlone() throws {
        try withFile(Data(#"{"x-top": true, "mcpServers": {"api": {"command": "npx", "x-in": 1}}}"#.utf8)) { url in
            let servers = [MCPServer(id: "api", command: "npx")]
            MCPConfigStore.writeFile(servers)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(Preferences.defaults.string(forKey: mirrorKey), text)
            let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
            MCPConfigStore.writeFile(servers)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode,
                           "an unchanged list rewrote the file")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        }
    }
}

final class HookPassthroughTests: XCTestCase {
    private let mirrorKey = "agentHooksDiskMirror"

    private func withFile(_ disk: Data?, _ body: (URL) throws -> Void) rethrows {
        let url = tempDir("hook-passthrough").appendingPathComponent("hooks.json")
        let savedURL = HooksConfigStore.fileURL
        let savedMirror = Preferences.defaults.string(forKey: mirrorKey)
        HooksConfigStore.fileURL = url
        Preferences.defaults.removeObject(forKey: mirrorKey)
        defer {
            HooksConfigStore.fileURL = savedURL
            Preferences.defaults.set(savedMirror, forKey: mirrorKey)
        }
        if let disk { try? disk.write(to: url) }
        try body(url)
    }

    private func rewrite(_ disk: String, with hooks: [HookRule]) throws -> String {
        var out = ""
        try withFile(Data(disk.utf8)) { url in
            HooksConfigStore.writeFile(hooks)
            out = try String(contentsOf: url, encoding: .utf8)
        }
        return out
    }

    /// A full Claude Code settings.json: everything but `hooks` is kept.
    func testUnknownTopLevelKeysSurviveRewrite() throws {
        let disk = #"{"model": "example", "permissions": {"allow": ["Bash(ls)"]}, "#
            + #""hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo done"}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .stop, command: "echo done")])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "echo done",
                    "type": "command"
                  }
                ]
              }
            ]
          },
          "model": "example",
          "permissions": {
            "allow": [
              "Bash(ls)"
            ]
          }
        }
        """)
    }

    /// Unknown keys of a rule's handler and of its matcher group survive.
    func testUnknownHandlerAndGroupKeysSurvive() throws {
        let disk = #"{"hooks": {"PreToolUse": [{"matcher": "Bash", "x-group": "g", "#
            + #""hooks": [{"type": "command", "command": "echo pre", "async": true}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .preToolUse, matcher: "Bash", command: "echo pre")])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "PreToolUse": [
              {
                "hooks": [
                  {
                    "async": true,
                    "command": "echo pre",
                    "type": "command"
                  }
                ],
                "matcher": "Bash",
                "x-group": "g"
              }
            ]
          }
        }
        """)
    }

    /// Nested content the app does not read: an unknown event name is kept whole, and a
    /// handler of another kind stays in a group with its group's matcher and keys.
    func testUnknownEventAndOtherHandlerKindKept() throws {
        let disk = #"{"hooks": {"Notification": [{"hooks": [{"type": "command", "command": "echo n"}]}], "#
            + #""PreToolUse": [{"matcher": "Bash", "x-group": "g", "hooks": ["#
            + #"{"type": "command", "command": "echo pre"}, {"type": "prompt", "prompt": "check it"}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .preToolUse, matcher: "Bash", command: "echo pre")])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "Notification": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo n"
                  }
                ]
              }
            ],
            "PreToolUse": [
              {
                "hooks": [
                  {
                    "command": "echo pre",
                    "type": "command"
                  }
                ],
                "matcher": "Bash",
                "x-group": "g"
              },
              {
                "hooks": [
                  {
                    "type": "prompt",
                    "prompt": "check it"
                  }
                ],
                "matcher": "Bash",
                "x-group": "g"
              }
            ]
          }
        }
        """)
    }

    func testRemovedRuleTakesItsUnknownKeys() throws {
        let disk = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo a", "x-a": 1}]}, "#
            + #"{"hooks": [{"type": "command", "command": "echo b", "x-b": 2}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .stop, command: "echo b")])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "echo b",
                    "type": "command",
                    "x-b": 2
                  }
                ]
              }
            ]
          }
        }
        """)
    }

    /// Toggled and re-timed in the app, the rule keeps its unknown keys.
    func testEditedRuleKeepsItsUnknownKeys() throws {
        let disk = #"{"hooks": {"Stop": [{"x-group": 1, "hooks": [{"type": "command", "command": "echo a", "timeout": 5, "x-a": 1}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .stop, command: "echo a", timeout: 30, enabled: false)])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "echo a",
                    "enabled": false,
                    "timeout": 30,
                    "type": "command",
                    "x-a": 1
                  }
                ],
                "x-group": 1
              }
            ]
          }
        }
        """)
    }

    /// A rule is its event, matcher and command. One renamed in the app starts with no unknown
    /// keys, even when its new command is another rule's: that rule keeps its own.
    func testRenamedRuleStartsWithoutUnknownKeys() throws {
        let disk = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo a", "timeout": 5, "x-a": 1}]}, "#
            + #"{"hooks": [{"type": "command", "command": "echo b", "x-b": 2}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .stop, command: "echo b", timeout: 5),
                                           HookRule(event: .stop, command: "echo b")])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "echo b",
                    "timeout": 5,
                    "type": "command"
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "command": "echo b",
                    "type": "command",
                    "x-b": 2
                  }
                ]
              }
            ]
          }
        }
        """)
    }

    /// The app's value wins for every key it models; a matcher on a non-matcher event and an
    /// `enabled: false` the app turned on are not brought back.
    func testModelledKeyWinsOverFileValue() throws {
        let disk = #"{"hooks": {"Stop": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo a", "#
            + #""timeout": 99, "enabled": false}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .stop, matcher: "Bash", command: "echo a", timeout: 5)])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "echo a",
                    "timeout": 5,
                    "type": "command"
                  }
                ]
              }
            ]
          }
        }
        """)
    }

    /// A rule read with a matcher on a non-matcher event is written without it; the next
    /// rewrite still finds it, so its unknown keys stay.
    func testMatcherDroppedOnDiskStillMatchesRule() throws {
        let disk = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo a", "x-a": 1}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .stop, matcher: "Bash", command: "echo a")])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "echo a",
                    "type": "command",
                    "x-a": 1
                  }
                ]
              }
            ]
          }
        }
        """)
    }

    func testUnknownValuesKeptAsWritten() throws {
        let disk = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo a", "#
            + #""x-big": 9007199254740993, "x-null": null, "x-esc": "q\"b\\sé\/", "x-exp": 1e3}]}]}}"#
        let out = try rewrite(disk, with: [HookRule(event: .stop, command: "echo a")])
        XCTAssertEqual(out, #"""
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "echo a",
                    "type": "command",
                    "x-big": 9007199254740993,
                    "x-esc": "q\"b\\sé/",
                    "x-exp": 1e3,
                    "x-null": null
                  }
                ]
              }
            ]
          }
        }
        """#)
    }

    private func assertNotOverwritten(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        try withFile(bytes) { url in
            HooksConfigStore.writeFile([HookRule(event: .stop, command: "echo a")])
            XCTAssertEqual(try Data(contentsOf: url), bytes, "unreadable file was overwritten", file: file, line: line)
            XCTAssertTrue(Preferences.defaults.string(forKey: mirrorKey) == nil, "mirror moved", file: file, line: line)
        }
    }

    func testMalformedJSONNotOverwritten() throws {
        try assertNotOverwritten(Data(#"{ "hooks": { "Stop": "#.utf8))
    }

    func testTopLevelArrayNotOverwritten() throws {
        try assertNotOverwritten(Data(#"[{"hooks": {}}]"#.utf8))
    }

    func testGroupNotAnObjectNotOverwritten() throws {
        try assertNotOverwritten(Data(#"{"hooks": {"Stop": ["echo a"]}}"#.utf8))
    }

    func testHooksNotAnObjectNotOverwritten() throws {
        try assertNotOverwritten(Data(#"{"hooks": [], "model": "example"}"#.utf8))
    }

    func testNonUTF8FileNotOverwritten() throws {
        try assertNotOverwritten(Data([0x7B, 0xFF, 0xFE, 0x7D]))
    }

    // MARK: round 2: handlers the reader does not make a rule of, BOM and duplicate keys

    /// A command-kind handler with no command is not read, so its group is kept whole.
    func testCommandHandlerWithoutCommandKeptWhole() throws {
        let disk = #"{"hooks": {"Stop": [{"x-group": 1, "hooks": [{"type": "command", "x-h": 2}]}]}}"#
        XCTAssertEqual(HooksConfigStore.decode(disk)?.count, 0)
        let out = try rewrite(disk, with: [])
        XCTAssertEqual(out, """
        {
          "hooks": {
            "Stop": [
              {
                "x-group": 1,
                "hooks": [
                  {
                    "type": "command",
                    "x-h": 2
                  }
                ]
              }
            ]
          }
        }
        """)
        XCTAssertEqual(HooksConfigStore.decode(out)?.count, 0)
    }

    /// An empty command beside a real one stays in the kept group; the rule list is unchanged.
    func testEmptyCommandHandlerKeptBesideRealOne() throws {
        let disk = #"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": ["#
            + #"{"type": "command", "command": "echo pre"}, {"type": "command", "command": ""}]}]}}"#
        let rules = try XCTUnwrap(HooksConfigStore.decode(disk))
        let out = try rewrite(disk, with: rules)
        XCTAssertEqual(out, """
        {
          "hooks": {
            "PreToolUse": [
              {
                "hooks": [
                  {
                    "command": "echo pre",
                    "type": "command"
                  }
                ],
                "matcher": "Bash"
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": ""
                  }
                ],
                "matcher": "Bash"
              }
            ]
          }
        }
        """)
        let shown = { (list: [HookRule]?) in list?.map { "\($0.event.rawValue) \($0.matcher) \($0.command)" } }
        XCTAssertEqual(shown(HooksConfigStore.decode(out)), ["PreToolUse Bash echo pre"])
        XCTAssertEqual(shown(rules), ["PreToolUse Bash echo pre"])
    }

    /// A rule with an empty command (not readable back) is not written, so rewrites do not
    /// pile up kept copies of it.
    func testBlankRuleNotWrittenAndRewriteIsStable() throws {
        try withFile(nil) { url in
            let hooks = [HookRule(event: .stop, command: ""), HookRule(event: .stop, command: "echo a")]
            HooksConfigStore.writeFile(hooks)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), """
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {
                        "command": "echo a",
                        "type": "command"
                      }
                    ]
                  }
                ]
              }
            }
            """)
            let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
            HooksConfigStore.writeFile(hooks)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode)
        }
    }

    private let bomFile = Data([0xEF, 0xBB, 0xBF] + Array(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo a"}]}]}}"#.utf8))
    private let duplicateKeyFile = Data(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo a", "x": 1, "x": 2}]}]}}"#.utf8)

    /// Pins what happens (round 2 found it, the round 1 report said otherwise): the UTF-8 read
    /// drops the BOM, so the file is readable and an in-app write replaces it without the BOM.
    func testBOMFileIsReadAndRewrittenWithoutBOM() throws {
        try withFile(bomFile) { url in
            HooksConfigStore.writeFile([HookRule(event: .stop, command: "echo b")])
            XCTAssertEqual(try Data(contentsOf: url), Data("""
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {
                        "command": "echo b",
                        "type": "command"
                      }
                    ]
                  }
                ]
              }
            }
            """.utf8))
        }
    }
    func testDuplicateKeyFileLeftByteIdentical() throws { try assertNotOverwritten(duplicateKeyFile) }

    /// The premise of the two pins above: the app's own reader accepts both files.
    func testBOMAndDuplicateKeyFilesAreReadByTheApp() throws {
        try withFile(bomFile) { url in
            XCTAssertEqual(HooksConfigStore.decode(try String(contentsOf: url, encoding: .utf8))?.map(\.command), ["echo a"])
        }
        try withFile(duplicateKeyFile) { url in
            XCTAssertEqual(HooksConfigStore.decode(try String(contentsOf: url, encoding: .utf8))?.map(\.command), ["echo a"])
        }
    }

    func testUnchangedRewriteLeavesFileAlone() throws {
        let disk = #"{"x-top": true, "hooks": {"Notification": [], "Stop": [{"x-group": 1, "hooks": ["#
            + #"{"type": "command", "command": "echo a", "x-a": 1}, {"type": "agent"}]}]}}"#
        try withFile(Data(disk.utf8)) { url in
            let hooks = [HookRule(event: .stop, command: "echo a")]
            HooksConfigStore.writeFile(hooks)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(Preferences.defaults.string(forKey: mirrorKey), text)
            let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
            HooksConfigStore.writeFile(hooks)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode,
                           "an unchanged list rewrote the file")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        }
    }
}
