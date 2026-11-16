import XCTest
@testable import ProsperApp

/// #1312: a kit's hook or status line that is not shaped as a command is refused at plan time, so the consent
/// sheet's "Apply" (no command count, #1075) never hides a command. Fake commands, own tempDir(), recording consent.
@MainActor
final class ManagedConfigShapeTests: XCTestCase {
    private func hook(_ id: String, _ value: String, event: String = "PreToolUse") -> ManagedConfigPiece {
        ManagedConfigPiece(id: id, kind: .json, target: "claude:settings.json", path: ["hooks", event], op: .append, value: value)
    }

    private func status(_ id: String, _ value: String) -> ManagedConfigPiece {
        ManagedConfigPiece(id: id, kind: .json, target: "claude:settings.json", path: ["statusLine"], op: .set, value: value)
    }

    /// The piece is refused by name with the path in the words, and nothing is asked or written.
    private func assertRefused(_ piece: ManagedConfigPiece, _ path: String, file: StaticString = #filePath, line: UInt = #line) async {
        let env = makeMCEnv()
        let r = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(r.refusals.map(\.pieceID), [piece.id], file: file, line: line)
        let said = r.refusals.last.map { "\($0.reason)" } ?? ""
        XCTAssertTrue(said.hasPrefix("invalid piece: \(path) takes only {"), said, file: file, line: line)
        XCTAssertEqual(env.consent.seen.count, 0, "nothing is asked", file: file, line: line)
        XCTAssertTrue(env.read(env.settings) == nil, "nothing is written", file: file, line: line)
    }

    func testAHookEntryWithoutACommandIsRefused() async {
        await assertRefused(hook("h", #"{"hooks": [{"type": "command"}]}"#), "hooks.PreToolUse")
    }

    func testAHookEntryWithANonStringCommandIsRefused() async {
        await assertRefused(hook("h", #"{"hooks": [{"type": "command", "command": ["run", "x"]}]}"#), "hooks.PreToolUse")
        await assertRefused(hook("h", #"{"hooks": [{"type": "command", "command": 7}]}"#), "hooks.PreToolUse")
    }

    func testAHookEntryOfAnotherTypeIsRefused() async {
        await assertRefused(hook("h", #"{"hooks": [{"type": "prompt", "command": "kit-run"}]}"#), "hooks.PreToolUse")
        await assertRefused(hook("h", #"{"hooks": [{"command": "kit-run"}]}"#), "hooks.PreToolUse")
    }

    func testAHookEntryWithAnExtraKeyIsRefused() async {
        await assertRefused(hook("h", #"{"hooks": [{"type": "command", "command": "kit-run", "async": true}]}"#), "hooks.PreToolUse")
    }

    func testAHookGroupWithAnExtraKeyOrNoHooksIsRefused() async {
        await assertRefused(hook("h", #"{"matcher": "Bash", "x-group": 1, "hooks": [{"type": "command", "command": "kit-run"}]}"#), "hooks.PreToolUse")
        await assertRefused(hook("h", #"{"matcher": "Bash"}"#), "hooks.PreToolUse")
        await assertRefused(hook("h", #"{"matcher": 3, "hooks": []}"#), "hooks.PreToolUse")
        await assertRefused(hook("h", #""just a string""#), "hooks.PreToolUse")
    }

    func testOneBadEntryAmongGoodOnesRefusesTheGroup() async {
        await assertRefused(hook("h", #"{"hooks": [{"type": "command", "command": "kit-run"}, {"type": "command", "command": null}]}"#), "hooks.PreToolUse")
    }

    func testAStatusLineWithANonStringCommandIsRefused() async {
        await assertRefused(status("s", #"{"type": "command", "command": 5}"#), "statusLine")
        await assertRefused(status("s", #"{"type": "command"}"#), "statusLine")
    }

    func testAStatusLineOfAnotherShapeIsRefused() async {
        await assertRefused(status("s", #"{"type": "text", "command": "kit-status"}"#), "statusLine")
        await assertRefused(status("s", #"{"type": "command", "command": "kit-status", "x-extra": true}"#), "statusLine")
        await assertRefused(status("s", #"{"type": "command", "command": "kit-status", "padding": "2"}"#), "statusLine")
        await assertRefused(status("s", #""kit-status""#), "statusLine")
    }

    /// Well-shaped pieces, with the optional keys, still plan and still warn (two lines, two commands).
    func testWellShapedHookAndStatusLineStillPlanAndWarn() async throws {
        let env = makeMCEnv()
        let r = await env.mc.apply([
            hook("h", #"{"matcher": "Bash", "hooks": [{"type": "command", "command": "kit-run pre", "timeout": 10}]}"#),
            status("s", #"{"type": "command", "command": "kit-status", "padding": 0}"#),
        ], owner: env.owner)
        XCTAssertEqual(r.refusals.count, 0)
        let set = try XCTUnwrap(env.consent.seen.last)
        XCTAssertEqual(set.files.flatMap { ManagedConfigCommandWarning.lines(in: $0) },
                       ["Runs a command: `kit-run pre` on `PreToolUse` (`Bash`)", "Runs a command: `kit-status` as the status line"])
        XCTAssertEqual(ManagedConfigCommandWarning.title(for: set), "Apply and allow 2 commands to run")
    }
}
