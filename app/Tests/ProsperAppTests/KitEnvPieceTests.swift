import Foundation
import XCTest
@testable import ProsperApp

/// OQ-193 (#1706): the env piece kind and a permissions piece's disable_bypass, through the real ManagedConfig over a
/// scratch claude root (makeMCEnv, under a tempDir()). Fakes only: no real ~/.claude, no real Claude Code.
final class KitEnvPieceTests: XCTestCase {
    private struct Setup {
        let env: MCEnv
        let v: KitValidated
        let c: KitRenderContext
        let a: String, b: String
    }

    /// The fixture kit plus an env piece (the first and last allowlisted keys) and a bypass-only permissions piece.
    private func setup(label: String = #function) throws -> Setup {
        let a = try XCTUnwrap(ManagedConfigPlanner.envKeys.first), b = try XCTUnwrap(ManagedConfigPlanner.envKeys.last)
        XCTAssertNotEqual(a, b)
        let env = makeMCEnv(label: label)
        let f = try makeKitDir(under: env.root)
        let kit = KitFixture.kit(replacing: "\n[[contributes.kit.settings]]", with: """

        [[contributes.kit.pieces]]
        id   = "env"
        kind = "env"
        vars = { \(a) = "1", \(b) = "600000" }

        [[contributes.kit.pieces]]
        id             = "no-bypass"
        kind           = "permissions"
        disable_bypass = true

        [[contributes.kit.settings]]
        """)
        guard case .ok(let v) = try f.validate(kit) else { XCTFail("kit refused"); throw CancellationError() }
        let c = KitRenderContext.standard(extensionID: v.extensionID, slug: v.slug, kitDir: f.kit,
                                          home: env.root.appendingPathComponent("home"), configHome: env.config)
        return Setup(env: env, v: v, c: c, a: a, b: b)
    }

    /// The env and bypass pieces of the plan: one `set` per key, and one for the bypass slot.
    private func setPieces(_ s: Setup) -> [ManagedConfigPiece] {
        KitRender.plan(s.v, s.c).pieces.filter { $0.path?.first == "env" || $0.path == ManagedConfigPlanner.bypassPath }
    }

    func testPlanSetsExactlyTheVarsAndTheBypassSlot() throws {
        let s = try setup()
        XCTAssertEqual(KitRender.plan(s.v, s.c).refusals, [])
        XCTAssertEqual(setPieces(s).sorted { $0.id < $1.id }, [
            ManagedConfigPiece(id: "env.\(s.a)", kind: .json, target: "claude:settings.json", path: ["env", s.a], op: .set, value: #""1""#),
            ManagedConfigPiece(id: "env.\(s.b)", kind: .json, target: "claude:settings.json", path: ["env", s.b], op: .set, value: #""600000""#),
            ManagedConfigPiece(id: "no-bypass.disable-bypass", kind: .json, target: "claude:settings.json",
                               path: ["permissions", "disableBypassPermissionsMode"], op: .set, value: #""disable""#),
        ].sorted { $0.id < $1.id })
    }

    /// Install writes exactly the kit's keys next to the user's own env (one of them overwritten), sets the bypass slot;
    /// Remove gives back the user's value, drops the key that was not there, and leaves the file byte for byte.
    func testInstallWritesExactlyTheKeysAndUninstallRestores() async throws {
        let s = try setup()
        let env = s.env
        let user = """
        {
          "env": {
            "\(s.a)": "0",
            "EXAMPLE_TOKEN": "dummy-value"
          },
          "permissions": {
            "allow": ["Bash(ls:*)"]
          }
        }

        """
        try env.write(user, env.settings)
        let before = env.bytes(env.settings)
        let owner = KitRender.owner(s.v, kitDir: URL(fileURLWithPath: s.c.kitDir))
        let applied = await env.mc.apply(setPieces(s), owner: owner)
        XCTAssertEqual(applied.status, .done, applied.message)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: env.settings)) as? [String: Any])
        XCTAssertEqual(doc["env"] as? [String: String], [s.a: "1", s.b: "600000", "EXAMPLE_TOKEN": "dummy-value"])
        let perms = try XCTUnwrap(doc["permissions"] as? [String: Any])
        XCTAssertEqual(perms["disableBypassPermissionsMode"] as? String, "disable")
        XCTAssertEqual(perms["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertEqual(Set(doc.keys), ["env", "permissions"])

        let removed = await env.mc.remove(owner: owner)
        XCTAssertEqual(removed.status, .done, removed.message)
        XCTAssertEqual(env.bytes(env.settings), before)
    }

    /// The sheet names every key and value: the kit's "What will change" lines and the consent sheet's notes and diff.
    /// The user's own env key that is off the allowlist stays masked.
    func testSheetListsEveryKeyAndValue() async throws {
        let s = try setup()
        let summary = KitRender.summary(s.v, s.c)
        XCTAssertTrue(summary.contains("env: env \(s.a) in settings.json is set to \"1\"; Remove puts your own value back"), "\(summary)")
        XCTAssertTrue(summary.contains("env: env \(s.b) in settings.json is set to \"600000\"; Remove puts your own value back"), "\(summary)")
        XCTAssertTrue(summary.contains("no-bypass: permissions.disableBypassPermissionsMode in settings.json is set to disable; Remove puts your own value back"))

        let env = s.env
        try env.write("{\n  \"env\": {\n    \"EXAMPLE_TOKEN\": \"dummy-secret-not-real\"\n  }\n}\n", env.settings)
        let applied = await env.mc.apply(setPieces(s), owner: KitRender.owner(s.v, kitDir: URL(fileURLWithPath: s.c.kitDir)))
        XCTAssertEqual(applied.status, .done, applied.message)
        let file = try XCTUnwrap(env.consent.seen.first?.files.first { $0.target == "claude:settings.json" })
        XCTAssertTrue(file.notes.contains("Claude Code sessions get the environment variable \(s.a) = \"1\"."), "\(file.notes)")
        XCTAssertTrue(file.notes.contains("Claude Code sessions get the environment variable \(s.b) = \"600000\"."), "\(file.notes)")
        XCTAssertTrue(file.notes.contains("Claude Code's bypass permissions mode is switched off."), "\(file.notes)")
        let added = file.lines.filter { $0.sign == .added }.map(\.text).joined(separator: "\n")
        XCTAssertTrue(added.contains("\"\(s.a)\": \"1\""), added)
        XCTAssertTrue(added.contains("\"\(s.b)\": \"600000\""), added)
        XCTAssertTrue(added.contains("\"disableBypassPermissionsMode\": \"disable\""), added)
        XCTAssertFalse(file.lines.contains { $0.text.contains("dummy-secret-not-real") }, "\(file.lines)")
    }

    /// The planner's allowlist: a set on an allowlisted env key or on the bypass slot plans; any other env key, any other
    /// op on env, a top-level bypass key, and a value of the wrong shape are refused before the sheet.
    func testPlannerAllowsOnlyTheAllowlistedSlotsAndShapes() async throws {
        let a = try XCTUnwrap(ManagedConfigPlanner.envKeys.first)
        XCTAssertTrue(ManagedConfigPlanner.jsonRule(["env", a], .set, kit: true) == nil)
        XCTAssertTrue(ManagedConfigPlanner.jsonRule(ManagedConfigPlanner.bypassPath, .set, kit: true) == nil)
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env", "ANTHROPIC_API_KEY"], .set, kit: true), .refusedJSONPath("env.ANTHROPIC_API_KEY"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env", a.lowercased()], .set, kit: true), .refusedJSONPath("env.\(a.lowercased())"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env"], .set, kit: true), .refusedJSONPath("env"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env", a], .union, kit: true), .refusedJSONPath("env.\(a)"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["disableBypassPermissionsMode"], .set, kit: true), .refusedJSONPath("disableBypassPermissionsMode"))

        let env = makeMCEnv()
        let bad = [
            ManagedConfigPiece(id: "e", kind: .json, target: "claude:settings.json", path: ["env", a], op: .set, value: "1"),
            ManagedConfigPiece(id: "b", kind: .json, target: "claude:settings.json", path: ManagedConfigPlanner.bypassPath, op: .set, value: #""allow""#),
        ]
        for piece in bad {
            var kitOwner = env.owner
            kitOwner.isKit = true // the shape check must be what refuses, not the owner
            let r = await env.mc.apply([piece], owner: kitOwner)
            XCTAssertEqual(r.status, .refused, piece.id)
        }
        XCTAssertEqual(env.consent.seen.count, 0, "refused before the sheet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.settings.path))
    }

    /// n51: an extension (host.config, not a kit owner) asking for an allowlisted env key or the bypass slot is refused
    /// before the sheet, like any other env key; the same pieces plan for a kit owner.
    func testAnExtensionOwnerIsRefusedTheEnvAndBypassSlots() async throws {
        let a = try XCTUnwrap(ManagedConfigPlanner.envKeys.first)
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env", a], .set), .refusedJSONPath("env.\(a)"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(ManagedConfigPlanner.bypassPath, .set), .refusedJSONPath("permissions.disableBypassPermissionsMode"))
        XCTAssertTrue(ManagedConfigPlanner.jsonRule(["statusLine"], .set) == nil, "the status line stays open to every owner")
        let pieces = [
            ManagedConfigPiece(id: "e", kind: .json, target: "claude:settings.json", path: ["env", a], op: .set, value: #""1""#),
            ManagedConfigPiece(id: "b", kind: .json, target: "claude:settings.json", path: ManagedConfigPlanner.bypassPath, op: .set, value: #""disable""#),
        ]
        let env = makeMCEnv()
        XCTAssertFalse(env.owner.isKit)
        for piece in pieces {
            let r = await env.mc.apply([piece], owner: env.owner)
            XCTAssertEqual(r.status, .refused, piece.id)
        }
        XCTAssertEqual(env.consent.seen.count, 0, "refused before the sheet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.settings.path))
        var kit = env.owner
        kit.isKit = true
        for piece in pieces {
            let r = await env.mc.apply([piece], owner: kit)
            XCTAssertEqual(r.status, .done, r.message)
        }
    }

    /// n52: the two keys that change behaviour get one plain line each on the sheet; no other key does.
    func testTheTwoBehaviourKeysGetTheirLineOnTheSheetAndNoOtherKeyDoes() async throws {
        let autoMode = "CLAUDE_CODE_ENABLE_AUTO_MODE", connectors = "ENABLE_CLAUDEAI_MCP_SERVERS"
        let plain = try XCTUnwrap(ManagedConfigPlanner.envKeys.first)
        XCTAssertEqual(Set(ManagedConfigPlanner.envWarnings.keys), [autoMode, connectors])
        XCTAssertTrue(ManagedConfigPlanner.envKeys.contains(autoMode) && ManagedConfigPlanner.envKeys.contains(connectors))
        let env = makeMCEnv()
        var kit = env.owner
        kit.isKit = true
        func piece(_ k: String) -> ManagedConfigPiece {
            ManagedConfigPiece(id: k, kind: .json, target: "claude:settings.json", path: ["env", k], op: .set, value: #""1""#)
        }
        let applied = await env.mc.apply([piece(plain), piece(autoMode), piece(connectors)], owner: kit)
        XCTAssertEqual(applied.status, .done, applied.message)
        let notes = try XCTUnwrap(env.consent.seen.first?.files.first { $0.target == "claude:settings.json" }).notes
        XCTAssertTrue(notes.contains("Claude Code sessions act without asking you."), "\(notes)")
        XCTAssertTrue(notes.contains("Your claude.ai connectors load in every session."), "\(notes)")
        XCTAssertEqual(notes.filter { $0.contains("act without asking") || $0.contains("connectors load") }.count, 2, "\(notes)")
        XCTAssertTrue(notes.contains("Claude Code sessions get the environment variable \(plain) = \"1\"."), "\(notes)")
    }
}
