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
        XCTAssertTrue(ManagedConfigPlanner.jsonRule(["env", a], .set) == nil)
        XCTAssertTrue(ManagedConfigPlanner.jsonRule(ManagedConfigPlanner.bypassPath, .set) == nil)
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env", "ANTHROPIC_API_KEY"], .set), .refusedJSONPath("env.ANTHROPIC_API_KEY"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env", a.lowercased()], .set), .refusedJSONPath("env.\(a.lowercased())"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env"], .set), .refusedJSONPath("env"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["env", a], .union), .refusedJSONPath("env.\(a)"))
        XCTAssertEqual(ManagedConfigPlanner.jsonRule(["disableBypassPermissionsMode"], .set), .refusedJSONPath("disableBypassPermissionsMode"))

        let env = makeMCEnv()
        let bad = [
            ManagedConfigPiece(id: "e", kind: .json, target: "claude:settings.json", path: ["env", a], op: .set, value: "1"),
            ManagedConfigPiece(id: "b", kind: .json, target: "claude:settings.json", path: ManagedConfigPlanner.bypassPath, op: .set, value: #""allow""#),
        ]
        for piece in bad {
            let r = await env.mc.apply([piece], owner: env.owner)
            XCTAssertEqual(r.status, .refused, piece.id)
        }
        XCTAssertEqual(env.consent.seen.count, 0, "refused before the sheet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.settings.path))
    }
}
