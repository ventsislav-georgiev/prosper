import XCTest
@testable import ProsperApp

/// #1052: when mcp.json / hooks.json cannot be read, an in-app edit is not written to it; the store
/// keeps why (a value the Settings pane shows) until the file reads again. Scratch files only.
final class MCPConfigStoreFileStateTests: XCTestCase {
    private let mirrorKey = "agentMCPDiskMirror"

    private func withFile(_ text: String, _ body: (URL) throws -> Void) throws {
        let url = tempDir("mcp-file-state").appendingPathComponent("mcp.json")
        let savedURL = MCPConfigStore.fileURL, savedPrefs = Preferences.mcpServers
        let savedMirror = Preferences.defaults.string(forKey: mirrorKey)
        MCPConfigStore.fileURL = url
        Preferences.defaults.removeObject(forKey: mirrorKey)
        MCPConfigStore.fileProblem = nil
        defer {
            MCPConfigStore.fileURL = savedURL
            Preferences.mcpServers = savedPrefs
            Preferences.defaults.set(savedMirror, forKey: mirrorKey)
            MCPConfigStore.fileProblem = nil
        }
        try Data(text.utf8).write(to: url)
        try body(url)
    }

    private func assertSkippedEdit(_ text: String, reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try withFile(text) { url in
            MCPConfigStore.writeFile([MCPServer(id: "api", command: "npx")])
            XCTAssertEqual(MCPConfigStore.fileProblem, reason, file: file, line: line)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "file left as it was", file: file, line: line)
        }
    }

    func testBrokenJSONSetsTheParserReason() throws {
        try assertSkippedEdit(#"{"mcpServers": {},}"#, reason: "expected a key (a trailing comma is not allowed) (line 1)")
    }

    func testTopLevelNotAnObjectSetsItsReason() throws {
        try assertSkippedEdit(#"[{"mcpServers": {}}]"#, reason: "the top level is not a JSON object")
    }

    func testModelledFieldOfWrongTypeSetsTheDecoderReason() throws {
        try assertSkippedEdit(#"{"mcpServers": {"api": {"command": "npx", "enabled": "yes"}}}"#,
                              reason: "mcpServers.api.enabled has the wrong type (expected Bool)")
    }

    /// Set on open (checkFile, before any edit), told to the pane by a notification, and cleared by
    /// the watcher's reload as soon as the file reads again; the notice line follows the state.
    func testSetOnOpenAndClearedWhenTheFileReadsAgain() throws {
        try withFile(#"[1]"#) { url in
            let set = expectation(forNotification: .agentConfigFileProblemChanged, object: nil)
            XCTAssertEqual(MCPConfigStore.checkFile(), "the top level is not a JSON object")
            wait(for: [set], timeout: 1)
            XCTAssertEqual(ConfigFileNotice.line("mcp.json", MCPConfigStore.fileProblem),
                           "mcp.json could not be read; changes are not saved to the file: the top level is not a JSON object")

            try Data(#"{"mcpServers": {"api": {"command": "npx"}}}"#.utf8).write(to: url)
            let cleared = expectation(forNotification: .agentConfigFileProblemChanged, object: nil)
            XCTAssertEqual(MCPConfigStore.reloadIfChanged()?.map(\.id), ["api"])
            wait(for: [cleared], timeout: 1)
            XCTAssertTrue(MCPConfigStore.fileProblem == nil, "cleared by the watcher")
            XCTAssertTrue(ConfigFileNotice.line("mcp.json", MCPConfigStore.fileProblem) == nil, "no notice")
        }
    }
}

final class HooksConfigStoreFileStateTests: XCTestCase {
    private let mirrorKey = "agentHooksDiskMirror"

    private func withFile(_ text: String, _ body: (URL) throws -> Void) throws {
        let url = tempDir("hooks-file-state").appendingPathComponent("hooks.json")
        let savedURL = HooksConfigStore.fileURL, savedPrefs = Preferences.hooks
        let savedMirror = Preferences.defaults.string(forKey: mirrorKey)
        HooksConfigStore.fileURL = url
        Preferences.defaults.removeObject(forKey: mirrorKey)
        HooksConfigStore.fileProblem = nil
        defer {
            HooksConfigStore.fileURL = savedURL
            Preferences.hooks = savedPrefs
            Preferences.defaults.set(savedMirror, forKey: mirrorKey)
            HooksConfigStore.fileProblem = nil
        }
        try Data(text.utf8).write(to: url)
        try body(url)
    }

    private func assertSkippedEdit(_ text: String, reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try withFile(text) { url in
            HooksConfigStore.writeFile([HookRule(event: .stop, command: "echo a")])
            XCTAssertEqual(HooksConfigStore.fileProblem, reason, file: file, line: line)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "file left as it was", file: file, line: line)
        }
    }

    func testBrokenJSONSetsTheParserReason() throws {
        try assertSkippedEdit(#"{"hooks": {},}"#, reason: "expected a key (a trailing comma is not allowed) (line 1)")
    }

    func testTopLevelNotAnObjectSetsItsReason() throws {
        try assertSkippedEdit(#"[{"hooks": {}}]"#, reason: "the top level is not a JSON object")
    }

    func testModelledFieldOfWrongTypeSetsTheDecoderReason() throws {
        try assertSkippedEdit(#"{"hooks": {"Stop": [{"hooks": [{"command": "echo a", "timeout": "5"}]}]}}"#,
                              reason: "hooks.Stop.Index 0.hooks.Index 0.timeout has the wrong type (expected Int)")
    }

    func testSetOnOpenAndClearedWhenTheFileReadsAgain() throws {
        try withFile(#"{"hooks": {},}"#) { url in
            let set = expectation(forNotification: .agentConfigFileProblemChanged, object: nil)
            XCTAssertEqual(HooksConfigStore.checkFile(), "expected a key (a trailing comma is not allowed) (line 1)")
            wait(for: [set], timeout: 1)
            XCTAssertEqual(ConfigFileNotice.line("hooks.json", HooksConfigStore.fileProblem),
                           "hooks.json could not be read; changes are not saved to the file: expected a key (a trailing comma is not allowed) (line 1)")

            try Data(#"{"hooks": {}}"#.utf8).write(to: url)
            let cleared = expectation(forNotification: .agentConfigFileProblemChanged, object: nil)
            _ = HooksConfigStore.reloadIfChanged()
            wait(for: [cleared], timeout: 1)
            XCTAssertTrue(HooksConfigStore.fileProblem == nil, "cleared by the watcher")

            // A good write keeps it clear and lands in the file.
            HooksConfigStore.writeFile([HookRule(event: .stop, command: "echo a")])
            XCTAssertTrue(HooksConfigStore.fileProblem == nil)
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("echo a"))
        }
    }
}

/// #1052 item 2: Import over an id already configured keeps enabled, approval mode and the bearer token
/// variable when the imported text does not state them, and takes them when it does.
final class AgentSettingsImportTests: XCTestCase {
    private let existing = [MCPServer(id: "api", transport: .http, enabled: false, url: "https://example.com/old",
                                      bearerTokenEnvVar: "API_TOKEN", approvalMode: .auto)]

    private let unstated = [
        "json": #"{"mcpServers": {"api": {"type": "http", "url": "https://example.com/mcp"}}}"#,
        "opencode": #"{"mcp": {"api": {"type": "remote", "url": "https://example.com/mcp"}}}"#,
        "toml": "[mcp_servers.api]\nurl = \"https://example.com/mcp\"\n",
    ]

    func testImportOverAnExistingIdKeepsWhatTheTextDoesNotState() {
        for (kind, text) in unstated.sorted(by: { $0.key < $1.key }) {
            let got = MCPConfigStore.importServers(from: text, over: existing)
            XCTAssertEqual(got.count, 1, kind)
            guard let s = got.first else { continue }
            XCTAssertEqual(s.url, "https://example.com/mcp", "\(kind): the rest is the import's")
            XCTAssertFalse(s.enabled, "\(kind): enabled kept")
            XCTAssertEqual(s.approvalMode, .auto, "\(kind): approval mode kept")
            XCTAssertEqual(s.bearerTokenEnvVar, "API_TOKEN", "\(kind): token variable kept")
        }
    }

    func testImportOverAnExistingIdTakesWhatTheTextStates() {
        let stated = [
            "json": #"{"mcpServers": {"api": {"type": "http", "url": "https://example.com/mcp", "enabled": true, "approvalMode": "approve", "bearerTokenEnvVar": "NEW_TOKEN"}}}"#,
            "toml": "[mcp_servers.api]\nurl = \"https://example.com/mcp\"\nenabled = true\ndefault_tools_approval_mode = \"approve\"\nbearer_token_env_var = \"NEW_TOKEN\"\n",
        ]
        for (kind, text) in stated.sorted(by: { $0.key < $1.key }) {
            let got = MCPConfigStore.importServers(from: text, over: existing)
            XCTAssertEqual(got.count, 1, kind)
            guard let s = got.first else { continue }
            XCTAssertTrue(s.enabled, kind)
            XCTAssertEqual(s.approvalMode, .approve, kind)
            XCTAssertEqual(s.bearerTokenEnvVar, "NEW_TOKEN", kind)
        }
        let oc = MCPConfigStore.importServers(from: #"{"mcp": {"api": {"type": "remote", "url": "https://example.com/mcp", "enabled": true}}}"#,
                                              over: existing)
        XCTAssertEqual(oc.first?.enabled, true, "opencode: enabled taken")
    }

    func testImportOfANewIdHasTheDefaults() {
        for (kind, text) in unstated.sorted(by: { $0.key < $1.key }) {
            let got = MCPConfigStore.importServers(from: text, over: [MCPServer(id: "other", enabled: false)])
            XCTAssertEqual(got.first?.enabled, true, kind)
            XCTAssertEqual(got.first?.approvalMode, .prompt, kind)
            XCTAssertEqual(got.first?.bearerTokenEnvVar, "", kind)
        }
    }

    /// Source pin, never run: the panes pass their list to Import, check the file on open, follow the
    /// store's state, and the notice's Reveal goes through the pane's existing reveal helper.
    func testPanesAreWiredToTheStoreState() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/ProsperApp/AgentSettingsPane.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        for needle in [
            "MCPConfigStore.importServers(from: text, over: model.mcpServers)",
            #"ConfigFileNotice(fileName: "mcp.json", problem: fileProblem, onReveal: revealConfigFile)"#,
            #"ConfigFileNotice(fileName: "hooks.json", problem: fileProblem, onReveal: revealHooksConfigFile)"#,
            "fileProblem = MCPConfigStore.checkFile()",
            "fileProblem = HooksConfigStore.checkFile()",
            "fileProblem = MCPConfigStore.fileProblem",
            "fileProblem = HooksConfigStore.fileProblem",
            #"Button("Reveal in Finder", action: onReveal)"#,
        ] {
            XCTAssertTrue(text.contains(needle), needle)
        }
        XCTAssertEqual(text.components(separatedBy: ".onReceive(NotificationCenter.default.publisher(for: .agentConfigFileProblemChanged))").count, 3)
    }
}
