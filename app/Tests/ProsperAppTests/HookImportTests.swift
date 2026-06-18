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

    func testBrokenInputReturnsEmpty() {
        XCTAssertTrue(HooksConfigStore.importHooks(from: "{ not valid").isEmpty)
        XCTAssertTrue(HooksConfigStore.importHooks(from: "").isEmpty)
    }

    func testDecodeBrokenFileIsNil() {
        // reloadIfChanged relies on decode → nil so the last good config is kept.
        XCTAssertNil(HooksConfigStore.decode("{ \"hooks\":"))
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
