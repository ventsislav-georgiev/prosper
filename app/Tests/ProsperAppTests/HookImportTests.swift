import XCTest
@testable import ProsperApp

/// Hook importers, canonical round-trip, and codex TOML generation. The parsers and the
/// TOML emitter are correctness-critical: a wrong block silently mis-runs (or skips) a
/// lifecycle hook, and a quoting slip is a config-injection bug.
final class HookImportTests: XCTestCase {

    // MARK: Claude Code settings.json import

    func testImportClaudeCodeSettings() {
        let json = """
        { "hooks": {
          "PreToolUse": [
            { "matcher": "Bash", "hooks": [{ "type": "command", "command": "echo pre", "timeout": 5 }] }
          ],
          "Stop": [
            { "hooks": [{ "type": "command", "command": "echo stop" }] }
          ]
        }}
        """
        let out = HooksConfigStore.importHooks(from: json)
        XCTAssertEqual(out.count, 2)
        let pre = out.first { $0.event == .preToolUse }
        XCTAssertEqual(pre?.matcher, "Bash")
        XCTAssertEqual(pre?.command, "echo pre")
        XCTAssertEqual(pre?.timeout, 5)
        let stop = out.first { $0.event == .stop }
        XCTAssertEqual(stop?.command, "echo stop")
        XCTAssertEqual(stop?.matcher, "")
    }

    /// Unknown event names and non-command handler kinds are skipped, not faked.
    func testImportSkipsUnknownEventAndNonCommand() {
        let json = """
        { "hooks": {
          "Bogus": [{ "hooks": [{ "type": "command", "command": "nope" }] }],
          "Stop":  [{ "hooks": [{ "type": "prompt", "command": "also nope" }] }]
        }}
        """
        XCTAssertTrue(HooksConfigStore.importHooks(from: json).isEmpty)
    }

    // MARK: codex config.toml import

    func testImportCodexTOML() {
        let toml = """
        model = "gemma"

        [[hooks.PreToolUse]]
        matcher = "Bash"

        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "echo hi"
        timeout = 10
        """
        let out = HooksConfigStore.importHooks(from: toml)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.event, .preToolUse)
        XCTAssertEqual(out.first?.matcher, "Bash")
        XCTAssertEqual(out.first?.command, "echo hi")
        XCTAssertEqual(out.first?.timeout, 10)
    }

    // MARK: Robustness

    func testMalformedTOMLNeverCrashesAndReturnsEmpty() {
        let cases: [(String, String)] = [
            ("unterminated string", "[hooks.PreToolUse]\ncommand = \"npx"),
            ("unterminated header", "[hooks.PreToolUse\ncommand = \"npx\""),
            ("duplicate key", "[hooks.PreToolUse]\ncommand = \"a\"\ncommand = \"b\""),
            ("key without value", "[hooks.PreToolUse]\ncommand ="),
            ("command is int", "[hooks.PreToolUse]\ncommand = 5"),
            ("args is string", "[hooks.PreToolUse]\ncommand = \"a\"\nargs = \"x\""),
            ("env is array", "[hooks.PreToolUse]\ncommand = \"a\"\nenv = [\"a\"]"),
            ("dotted key vs table", "hooks.PreToolUse = 1\n[hooks.PreToolUse]\ncommand = \"a\""),
            ("open inline table", "hooks = { PreToolUse = { command = \"x\""),
            ("control char in string", "[hooks.PreToolUse]\ncommand = \"a\u{01}b\""),
            ("1 MiB of [", String(repeating: "[", count: 1 << 20)),
            ("1 MiB of quote", String(repeating: "\"", count: 1 << 20)),
            // TOMLDecoder 0.4.5 fix shapes (#322 sign-only int, #323 base prefix, #324 float edge, #332 nested arrays, #331 top-level value)
            ("sign-only int", "[hooks.PreToolUse]\ncommand = +"),
            ("bare base prefix", "[hooks.PreToolUse]\ncommand = 0x"),
            ("signed base prefix", "[hooks.PreToolUse]\ncommand = -0b1"),
            ("float edge", "[hooks.PreToolUse]\ncommand = 1e"),
            ("float trailing dot", "[hooks.PreToolUse]\ncommand = 1."),
            ("nested bare array", "[hooks.PreToolUse]\nargs = [[1, a]]"),
            ("top-level value", "= 1"),
        ]
        for (name, input) in cases {
            XCTAssertTrue(HooksConfigStore.importHooks(from: input).isEmpty, name)
        }
    }

    func testBrokenInputReturnsEmpty() {
        XCTAssertTrue(HooksConfigStore.importHooks(from: "{ not valid").isEmpty)
        XCTAssertTrue(HooksConfigStore.importHooks(from: "").isEmpty)
    }

    func testDecodeBrokenFileIsNil() {
        // reloadIfChanged relies on decode → nil so the last good config is kept.
        XCTAssertNil(HooksConfigStore.decode("{ \"hooks\":"))
    }

    // MARK: Launch bootstrap (#311) — scratch directory, never the real ~/.config

    /// Points the store at a scratch file with a known prefs value and a cleared mirror
    /// (so the pre-#311 code would have rewritten the file), then restores everything.
    private func withScratchFile(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap-\(UUID().uuidString)", isDirectory: true)
        let savedURL = HooksConfigStore.fileURL, savedPrefs = Preferences.hooks
        let savedMirror = Preferences.defaults.string(forKey: "agentHooksDiskMirror")
        HooksConfigStore.fileURL = dir.appendingPathComponent("config.json")
        Preferences.hooks = [HookRule(event: .stop, matcher: "", command: "echo keep", timeout: nil, enabled: true)]
        Preferences.defaults.removeObject(forKey: "agentHooksDiskMirror")
        defer {
            HooksConfigStore.fileURL = savedURL
            Preferences.hooks = savedPrefs
            Preferences.defaults.set(savedMirror, forKey: "agentHooksDiskMirror")
            try? FileManager.default.removeItem(at: dir)
        }
        try body(HooksConfigStore.fileURL)
    }

    func testBootstrapLeavesMalformedFileByteForByte() throws {
        try withScratchFile { url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let broken = Data(#"{ "hooks": { "PreToolUse": [ "#.utf8)
            try broken.write(to: url)
            let before = Preferences.hooks
            HooksConfigStore.bootstrap()
            XCTAssertEqual(try Data(contentsOf: url), broken, "malformed user edit was overwritten")
            XCTAssertEqual(Preferences.hooks, before, "last good config must stay live")
        }
    }

    func testBootstrapCreatesAbsentFile() throws {
        try withScratchFile { url in
            Preferences.defaults.set(HooksConfigStore.encode(Preferences.hooks), forKey: "agentHooksDiskMirror")
            HooksConfigStore.bootstrap()
            let written = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(HooksConfigStore.decode(written)?.map(\.command), Preferences.hooks.map(\.command))
        }
    }

    // MARK: Canonical encode/decode round-trip

    func testRoundTrip() {
        let hooks = [
            HookRule(event: .preToolUse, matcher: "Bash", command: "echo a", timeout: 5, enabled: true),
            HookRule(event: .stop, matcher: "", command: "echo b", timeout: nil, enabled: false),
        ]
        guard let json = HooksConfigStore.encode(hooks),
              let back = HooksConfigStore.decode(json) else { return XCTFail("encode/decode failed") }
        XCTAssertEqual(back.count, 2)
        let pre = back.first { $0.event == .preToolUse }
        XCTAssertEqual(pre?.matcher, "Bash")
        XCTAssertEqual(pre?.command, "echo a")
        XCTAssertEqual(pre?.timeout, 5)
        XCTAssertEqual(pre?.enabled, true)
        let stop = back.first { $0.event == .stop }
        XCTAssertEqual(stop?.command, "echo b")
        XCTAssertEqual(stop?.enabled, false)
    }

    /// A matcher on a non-matcher event (Stop) is dropped on the way to disk.
    func testMatcherDroppedForNonMatcherEvent() {
        let hooks = [HookRule(event: .stop, matcher: "Bash", command: "echo b")]
        guard let json = HooksConfigStore.encode(hooks),
              let back = HooksConfigStore.decode(json) else { return XCTFail("encode/decode failed") }
        XCTAssertEqual(back.first?.matcher, "")
    }

    // MARK: codex TOML generation (HookRule.tomlBlocks)

    func testTOMLBlocksRendersEnabledValidOnly() {
        let hooks = [
            HookRule(event: .preToolUse, matcher: "Bash", command: "echo run", timeout: 7, enabled: true),
            HookRule(event: .stop, matcher: "", command: "echo disabled", enabled: false),  // skipped
            HookRule(event: .stop, matcher: "", command: "   ", enabled: true),              // invalid, skipped
        ]
        let toml = HookRule.tomlBlocks(for: hooks)
        XCTAssertTrue(toml.contains("[[hooks.PreToolUse]]"))
        XCTAssertTrue(toml.contains("matcher = \"Bash\""))
        XCTAssertTrue(toml.contains("[[hooks.PreToolUse.hooks]]"))
        XCTAssertTrue(toml.contains("type = \"command\""))
        XCTAssertTrue(toml.contains("command = \"echo run\""))
        XCTAssertTrue(toml.contains("timeout = 7"))
        XCTAssertFalse(toml.contains("echo disabled"))
        XCTAssertFalse(toml.contains("Stop"))
    }

    func testTOMLBlocksEmptyForNothingRenderable() {
        XCTAssertEqual(HookRule.tomlBlocks(for: []), "")
        XCTAssertEqual(HookRule.tomlBlocks(for: [HookRule(command: "x", enabled: false)]), "")
    }

    /// A command with quotes/newlines must be TOML-escaped (injection guard).
    func testTOMLBlocksEscapesCommand() {
        let hooks = [HookRule(event: .stop, command: "echo \"hi\"\nrm", enabled: true)]
        let toml = HookRule.tomlBlocks(for: hooks)
        XCTAssertTrue(toml.contains(#"command = "echo \"hi\"\nrm""#))
    }
}
