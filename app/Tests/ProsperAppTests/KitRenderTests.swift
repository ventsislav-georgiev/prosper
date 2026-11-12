import Foundation
import XCTest
@testable import ProsperApp

final class KitRenderTests: XCTestCase {
    /// /tmp-style fake roots: strings only, nothing is created there.
    private let ctx = KitRenderContext.standard(
        extensionID: "dev.example.kit.calm-agent", slug: "calm-agent", kitDir: URL(fileURLWithPath: "/tmp/kits/calm agent"),
        home: URL(fileURLWithPath: "/tmp/home dir"), configHome: URL(fileURLWithPath: "/tmp/home dir/.config"))

    private func validatedFixture(_ kitTOML: String = KitFixture.kit, line: UInt = #line) throws -> KitValidated {
        let v = try makeKitDir(label: "render\(line)").validate(kitTOML)
        guard case .ok(let k) = v else { XCTFail("\(v)", line: line); throw CancellationError() }
        return k
    }

    /// argv as /bin/sh parses `line`. Runs only /bin/sh on a fixed string; no kit script runs.
    private func shArgs(_ line: String) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "set -- " + line + "\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done"]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": "/nonexistent"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    func testStandardContextPaths() {
        XCTAssertEqual(ctx.kitDir, "/tmp/kits/calm agent")
        XCTAssertEqual(ctx.kitBin, "/tmp/home dir/.config/prosper/kits/dev.example.kit.calm-agent/bin")
        XCTAssertEqual(ctx.kitConfig, "/tmp/home dir/.config/calm-agent")
        XCTAssertEqual(ctx.home, "/tmp/home dir")
        XCTAssertEqual(ctx.runner, "/tmp/home dir/.config/prosper/kit-runtime/prosper-kit-run")
    }

    // MARK: (a) placeholders, *.md only (spec 4.2, 4.12 item 2)

    func testSubstituteEveryPlaceholder() {
        XCTAssertEqual(KitRender.substitute("a {{kit_dir}} b {{kit_bin}} c {{kit_config}} d {{home}} e {{other}} {{", ctx),
                       "a \(ctx.kitDir) b \(ctx.kitBin) c \(ctx.kitConfig) d \(ctx.home) e {{other}} {{")
        // right after `@` it is an import path: errata A4 form
        XCTAssertEqual(KitRender.substitute("@{{kit_config}}/local.md\n", ctx), "@/tmp/home\\ dir/.config/calm-agent/local.md\n")
    }

    func testScriptsAreNeverRendered() throws {
        let f = try makeKitDir()
        var seen = 0
        for rel in ["hooks/guard.sh", "tools/calm-note", "statusline/hud.mjs", "init.lua", "seed/notes.toml"] {
            let data = try Data(contentsOf: f.url(rel))
            XCTAssertFalse(KitRender.isRendered(rel), rel)
            XCTAssertEqual(KitRender.renderFile(rel, data, ctx), data, rel)
            seen += 1
        }
        XCTAssertEqual(seen, 5)
        XCTAssertTrue(KitDirFixture.guardScript.contains("{{kit_dir}}"), "the script carries a placeholder, so a render would show")
        let md = try Data(contentsOf: f.url("CLAUDE.md"))
        XCTAssertEqual(String(decoding: KitRender.renderFile("CLAUDE.md", md, ctx), as: UTF8.self),
                       "# Calm agent rules\n\nKeep answers short. Kit tools live in \(ctx.kitBin).\n\n@/tmp/home\\ dir/.config/calm-agent/local.md\n")
        XCTAssertTrue(KitRender.isRendered("docs/README.MD"))
        XCTAssertFalse(KitRender.isRendered("notes.md.sh"))
        XCTAssertFalse(KitRender.isRendered("md"))
        let notUTF8 = Data([0xFF, 0xFE, 0x7B, 0x7B])
        XCTAssertEqual(KitRender.renderFile("x.md", notUTF8, ctx), notUTF8)
    }

    // MARK: (b) import line (errata A4)

    func testImportLineEscapesSpacesUnquoted() {
        let line = KitRender.importLine("/tmp/kits/calm agent/CLAUDE.md")
        XCTAssertEqual(line, "@/tmp/kits/calm\\ agent/CLAUDE.md")
        XCTAssertFalse(line?.contains("\"") ?? true)
        XCTAssertFalse(line?.contains("'") ?? true)
        XCTAssertFalse(line?.contains("`") ?? true)
        XCTAssertNil(KitRender.importLine("/tmp/kits/new\nline/CLAUDE.md"))
        XCTAssertNil(KitRender.importLine("/tmp/kits/cr\rx/CLAUDE.md"))
    }

    // MARK: (c) runner line (spec 4.5, errata A7, C12)

    func testRunnerLineRoundTripsThroughSh() throws {
        for dir in ["/tmp/kits/calm agent", "/tmp/kits/it's mine", "/tmp/kits/$HOME `x` $(echo no) *", "/tmp/kits/new\nline",
                    "/tmp/kits/back\\slash \"dq\" ''"] {
            var c = ctx
            c.kitDir = dir
            c.runner = "/tmp/home dir/it's/prosper-kit-run"
            let target = dir + "/hooks/guard.sh"
            XCTAssertEqual(try shArgs(KitRender.runnerLine(c, pieceID: "guard", name: "guard", target: target)),
                           [c.runner, "dev.example.kit.calm-agent", "guard", "guard", target], dir)
            XCTAssertEqual(try shArgs(KitRender.runnerLine(c, pieceID: "hud", name: "hud", target: target, interpreter: "node")),
                           [c.runner, "dev.example.kit.calm-agent", "hud", "hud", "node", target], dir)
        }
        XCTAssertEqual(KitRender.shellQuote("it's"), #"'it'\''s'"#)
    }

    func testShimExecsTheRunnerWithItsArguments() throws {
        let v = try validatedFixture()
        let shims = KitRender.plan(v, ctx).shims
        XCTAssertEqual(shims.map(\.name), ["calm-note"])
        let shim = try XCTUnwrap(shims.first)
        XCTAssertEqual(shim.pieceID, "tools")
        XCTAssertEqual(shim.target, ctx.kitBin + "/calm-note")
        let line = KitRender.runnerLine(ctx, pieceID: "tools", name: "calm-note", target: ctx.kitDir + "/tools/calm-note")
        XCTAssertEqual(shim.text, "#!/bin/sh\nexec " + line + " \"$@\"\n")
        XCTAssertFalse(shim.text.contains("exec --"))
        XCTAssertEqual(try shArgs(line), [ctx.runner, "dev.example.kit.calm-agent", "tools", "calm-note", ctx.kitDir + "/tools/calm-note"])
    }

    // MARK: (d) managed pieces (spec 4.2 table)

    func testPlanMapsEveryKindToManagedPieces() throws {
        let v = try validatedFixture()
        let plan = KitRender.plan(v, ctx)
        XCTAssertEqual(plan.refusals, [])
        XCTAssertEqual(plan.pieces.map(\.id), ["config.notes.toml", KitRender.localSeedID, "rules", "guard", "hud", "perms.allow", "perms.deny"])
        let guardLine = KitRender.runnerLine(ctx, pieceID: "guard", name: "guard", target: ctx.kitDir + "/hooks/guard.sh")
        let hudLine = KitRender.runnerLine(ctx, pieceID: "hud", name: "hud", target: ctx.kitDir + "/statusline/hud.mjs", interpreter: "node")
        XCTAssertEqual(plan.pieces, [
            ManagedConfigPiece(id: "config.notes.toml", kind: .seed, target: "kitconfig:notes.toml", source: "ext:seed/notes.toml"),
            ManagedConfigPiece(id: "_local", kind: .seed, target: "kitconfig:local.md", text: KitRender.localTemplate),
            ManagedConfigPiece(id: "rules", kind: .block, target: "claude:CLAUDE.md", text: "@/tmp/kits/calm\\ agent/CLAUDE.md", position: .bottom),
            ManagedConfigPiece(id: "guard", kind: .json, target: "claude:settings.json", path: ["hooks", "PreToolUse"], op: .append,
                               value: #"{"matcher": "Bash", "hooks": [{"type": "command", "command": "# + OrderedJSON.quote(guardLine) + #", "timeout": 10}]}"#),
            ManagedConfigPiece(id: "hud", kind: .json, target: "claude:settings.json", path: ["statusLine"], op: .set,
                               value: #"{"type": "command", "command": "# + OrderedJSON.quote(hudLine) + "}"),
            ManagedConfigPiece(id: "perms.allow", kind: .json, target: "claude:settings.json", path: ["permissions", "allow"], op: .union,
                               value: #"["Bash(calm-note:*)"]"#),
            ManagedConfigPiece(id: "perms.deny", kind: .json, target: "claude:settings.json", path: ["permissions", "deny"], op: .union,
                               value: #"["Bash(rm -rf:*)"]"#),
        ])
        for p in plan.pieces { XCTAssertTrue(ManagedConfigPaths.isValidID(p.id), p.id) }
        // a seed that ships its own local.md replaces the template
        var own = v
        own.seeds["config"]?.append(KitFileRef(name: "local.md", path: "seed/local.md"))
        XCTAssertFalse(KitRender.plan(own, ctx).pieces.contains { $0.id == KitRender.localSeedID })
    }

    /// spec 4.2 "Env-free": walks every piece kind's rendered output. The only settings.json keys a
    /// kit can produce are hooks.<event>, statusLine and permissions.allow / deny / ask, and no
    /// object carries a marker key (errata A10).
    func testEveryPieceKindWritesOnlyAllowedSettingsKeys() throws {
        let extra = """

        [[contributes.kit.pieces]]
        id    = "start"
        kind  = "hook"
        event = "SessionStart"
        run   = "hooks/guard.sh"

        [[contributes.kit.pieces]]
        id    = "perms-all"
        kind  = "permissions"
        allow = ["Read(*)"]
        deny  = ["Bash(curl:*)"]
        ask   = ["Bash(git push:*)"]

        [[contributes.kit.settings]]
        """
        let v = try validatedFixture(KitFixture.kit(replacing: "\n[[contributes.kit.settings]]", with: extra))
        XCTAssertEqual(Set(v.kit.pieces.map(\.kind)), Set(KitManifest.Piece.Kind.allCases), "the walk covers every kind")
        let plan = KitRender.plan(v, ctx)
        XCTAssertEqual(plan.refusals, [])
        var json = 0
        for p in plan.pieces {
            switch p.kind {
            case .block:
                XCTAssertEqual(p.target, "claude:CLAUDE.md", p.id)
            case .seed:
                XCTAssertTrue(p.target.hasPrefix("kitconfig:"), p.id)
            case .json:
                json += 1
                XCTAssertEqual(p.target, "claude:settings.json", p.id)
                let path = p.path ?? []
                let allowed = (path.count == 2 && path[0] == "hooks" && ManagedConfigPlanner.hookEvents.contains(path[1]) && p.op == .append)
                    || (path == ["statusLine"] && p.op == .set)
                    || (path.count == 2 && path[0] == "permissions" && ["allow", "deny", "ask"].contains(path[1]) && p.op == .union)
                XCTAssertTrue(allowed, "\(p.id) writes \(path) with \(String(describing: p.op))")
                XCTAssertNil(ManagedConfigPlanner.jsonRule(path, p.op ?? .set), p.id)
                let value = try JSONSerialization.jsonObject(with: Data((p.value ?? "").utf8), options: .fragmentsAllowed)
                switch path.first {
                case "hooks":
                    let group = try XCTUnwrap(value as? [String: Any], p.id)
                    XCTAssertTrue(Set(group.keys).isSubset(of: ["matcher", "hooks"]), "\(p.id): \(group.keys)")
                    for handler in try XCTUnwrap(group["hooks"] as? [[String: Any]], p.id) {
                        XCTAssertTrue(Set(handler.keys).isSubset(of: ["type", "command", "timeout"]), "\(p.id): \(handler.keys)")
                    }
                case "statusLine":
                    XCTAssertEqual(Set(try XCTUnwrap(value as? [String: Any], p.id).keys), ["type", "command"])
                default:
                    XCTAssertNotNil(value as? [String], p.id)
                }
            }
        }
        XCTAssertEqual(json, 8)
    }

    // MARK: (e) "What will change" (spec 4.3, errata A1)

    func testSummaryLines() throws {
        let lines = KitRender.summary(try validatedFixture(), ctx)
        XCTAssertEqual(lines, [
            "rules: a block at the bottom of CLAUDE.md imports /tmp/kits/calm agent/CLAUDE.md",
            "tools: commands calm-note in \(ctx.kitBin)",
            "guard: Claude Code runs hooks/guard.sh on PreToolUse (Bash) in every session, timeout 10 s",
            "hud: Claude Code runs statusline/hud.mjs with node as the status line; Remove puts your own status line back",
            "perms: permissions.allow in settings.json gains Bash(calm-note:*)",
            "perms: permissions.deny in settings.json gains Bash(rm -rf:*)",
            "config: copies notes.toml into \(ctx.kitConfig) when missing; never overwritten",
            "_local: \(ctx.kitConfig)/local.md is created for your own lines; Claude Code reads it last",
            "requires on PATH: node",
        ])
        XCTAssertFalse((lines + [KitRender.localTemplate]).contains { $0.lowercased().contains("override") })
    }

    /// round 2 F3: a kit that passed validation never yields a line break inside one summary
    /// entry, even with every printable ASCII punctuation in the matcher; one line per permission
    /// rule, so a rule holding ", " stays one entry.
    func testSummaryEntriesAreSingleLines() throws {
        let punct = #"!#$%&'()*+,-./:;<=>?@[]^_`{|}~ "#
        let kit = KitFixture.kit(replacing: #"matcher = "Bash""#, with: "matcher = \"" + punct + #"\"\\""#)
            .replacingOccurrences(of: #"allow = ["Bash(calm-note:*)"]"#, with: #"allow = ["Bash(a, b:*)", "Read(*)"]"#)
        let v = try validatedFixture(kit)
        XCTAssertEqual(v.kit.pieces[2].matcher, punct + #""\"#)
        let lines = KitRender.summary(v, ctx)
        for l in lines {
            XCTAssertFalse(l.unicodeScalars.contains { KitManifest.isControlScalar($0) }, l)
        }
        XCTAssertTrue(lines.contains("guard: Claude Code runs hooks/guard.sh on PreToolUse (\(punct)\"\\) in every session, timeout 10 s"), "\(lines)")
        XCTAssertTrue(lines.contains("perms: permissions.allow in settings.json gains Bash(a, b:*)"), "\(lines)")
        XCTAssertTrue(lines.contains("perms: permissions.allow in settings.json gains Read(*)"), "\(lines)")
    }

    // MARK: round trip (spec 4.12 item 3)

    /// The fixture kit's six kinds applied through the real ManagedConfig over a user's CLAUDE.md and
    /// settings.json, then removed: both files byte-identical to the start.
    func testRoundTripThroughManagedConfigIsByteIdentical() async throws {
        let env = makeMCEnv()
        let f = try makeKitDir(under: env.root)
        guard case .ok(let v) = try f.validate() else { return XCTFail("fixture refused") }
        let c = KitRenderContext.standard(extensionID: v.extensionID, slug: v.slug, kitDir: f.kit,
                                          home: env.root.appendingPathComponent("home"), configHome: env.config)
        let plan = KitRender.plan(v, c)
        XCTAssertEqual(plan.refusals, [])
        let userMD = "# My own rules\n\nBe kind.\n"
        let userSettings = """
        {
          "env": {
            "EXAMPLE_TOKEN": "dummy-value"
          },
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  { "type": "command", "command": "my-own-guard" }
                ]
              }
            ]
          },
          "permissions": {
            "allow": ["Bash(ls:*)"]
          },
          "statusLine": { "type": "command", "command": "my-own-status" }
        }

        """
        try env.write(userMD, env.claudeMD)
        try env.write(userSettings, env.settings)
        let mdBefore = env.bytes(env.claudeMD), settingsBefore = env.bytes(env.settings)
        let owner = KitRender.owner(v, kitDir: f.kit)
        XCTAssertEqual(owner.id, "dev.example.kit.calm-agent")
        XCTAssertEqual(owner.kitSlug, "calm-agent")

        let applied = await env.mc.apply(plan.pieces, owner: owner)
        XCTAssertEqual(applied.status, .done, applied.message)
        let md = try XCTUnwrap(env.read(env.claudeMD))
        XCTAssertTrue(md.hasPrefix(userMD), md)
        XCTAssertTrue(md.contains("\n" + KitRender.importLine(c.kitDir + "/CLAUDE.md")! + "\n"), md)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: env.settings)) as? [String: Any])
        let pre = try XCTUnwrap((doc["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre.count, 2)
        let kitHook = try XCTUnwrap((pre.last?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(kitHook["command"] as? String, KitRender.runnerLine(c, pieceID: "guard", name: "guard", target: c.kitDir + "/hooks/guard.sh"))
        XCTAssertEqual(kitHook["timeout"] as? Int, 10)
        XCTAssertEqual((doc["statusLine"] as? [String: Any])?["command"] as? String,
                       KitRender.runnerLine(c, pieceID: "hud", name: "hud", target: c.kitDir + "/statusline/hud.mjs", interpreter: "node"))
        let perms = try XCTUnwrap(doc["permissions"] as? [String: Any])
        XCTAssertEqual(perms["allow"] as? [String], ["Bash(ls:*)", "Bash(calm-note:*)"])
        XCTAssertEqual(perms["deny"] as? [String], ["Bash(rm -rf:*)"])
        XCTAssertEqual(Set(doc.keys), ["env", "hooks", "permissions", "statusLine"])
        let kitConfig = env.config.appendingPathComponent("calm-agent")
        XCTAssertEqual(env.read(kitConfig.appendingPathComponent("notes.toml")), "# your notes\n")
        XCTAssertEqual(env.read(kitConfig.appendingPathComponent("local.md")), KitRender.localTemplate)

        let removed = await env.mc.remove(owner: owner)
        XCTAssertEqual(removed.status, .done, removed.message)
        XCTAssertEqual(env.bytes(env.claudeMD), mdBefore)
        XCTAssertEqual(env.bytes(env.settings), settingsBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kitConfig.appendingPathComponent("notes.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kitConfig.appendingPathComponent("local.md").path))
        XCTAssertEqual(env.consent.seen.count, 2)
    }
}
