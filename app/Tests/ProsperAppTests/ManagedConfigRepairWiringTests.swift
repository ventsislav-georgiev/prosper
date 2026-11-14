import Darwin
import Foundation
import XCTest
import LuaRuntime
@testable import ProsperApp

/// #1232: ManagedConfig.repair(_:owner:) wired: host.config.repair{ pieces = { … } }, the status row's `repair` offer for a
/// drifted block, and the uninstall that names a block with no record. Every file is the row's own, inside its tempDir()
/// (a made-up home and fake kit ids); the registry installs into the row's tempDir() too.
final class ManagedConfigRepairWiringTests: XCTestCase {
    static let extID = "com.test.kit"
    private let blockPiece = #"{ id = "rules", kind = "block", target = "claude:CLAUDE.md", text = "Follow the kit rules." }"#

    private func owner(_ env: MCEnv) -> ManagedConfigOwner {
        ManagedConfigOwner(id: Self.extID, version: "1.0.0", kitSlug: "kit-a", extensionDir: env.ext)
    }

    /// `body` (Lua returning a table) as handler `run` on the extension's real async lane.
    private static func runOnLane(_ services: MCHostServices, _ env: MCEnv, configOwner: ManagedConfigOwner? = nil, _ body: String) async throws -> [String: Any] {
        let entry = env.root.appendingPathComponent("init-\(UUID().uuidString).lua")
        try "function run(arg) local r = (function() \(body) end)() return host.json.encode(r) end".write(to: entry, atomically: true, encoding: .utf8)
        let lanes = AsyncExtensionRuntimes(services: services)
        let spec = AsyncExtensionRuntimes.Spec(extensionID: Self.extID, entryURL: entry, handler: "run", callTimeout: 30,
                                               privileged: false, trusted: true, configOwner: configOwner ?? ManagedConfigOwner(id: extID, version: "1.0.0", kitSlug: "kit-a", extensionDir: env.ext))
        let raw = await lanes.invoke(spec, args: [""])
        let out = try XCTUnwrap(raw)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8), options: [.fragmentsAllowed]) as? [String: Any], out)
    }

    /// The answer reduced to strings (an empty Lua table has no fixed JSON shape).
    private func lists(_ call: String) -> String {
        "local r = \(call) local why = {} for _, x in ipairs(r.refused) do why[#why + 1] = x.id .. \"=\" .. x.why end "
            + "return { status = r.status, applied = table.concat(r.applied, \",\"), refused = table.concat(why, \";\"), message = r.message or \"\" }"
    }

    /// Applies the block, loses the state (the record) and edits the block by hand: what A-INFO-1 repairs.
    private static func lostAndEdited(_ env: MCEnv, _ o: ManagedConfigOwner) async throws -> (applied: [UInt8], edited: [UInt8]) {
        try env.write("# mine\n", env.claudeMD)
        let r = await env.mc.apply([MCPieces.block()], owner: o)
        XCTAssertEqual(r.status, .done)
        let applied = try XCTUnwrap(env.bytes(env.claudeMD))
        try FileManager.default.removeItem(at: env.state.appendingPathComponent("state.json"))
        let text = try XCTUnwrap(env.read(env.claudeMD))
        try env.write(text.replacingOccurrences(of: "Follow the kit rules.", with: "Follow my rules instead."), env.claudeMD)
        let edited = try XCTUnwrap(env.bytes(env.claudeMD))
        XCTAssertNotEqual(applied, edited)
        return (applied, edited)
    }

    // MARK: item 1, the host call

    func testHostRepairWithPiecesTakesOverAnUnrecordedEditedBlockOnlyOnAllow() async throws {
        let env = makeMCEnv()
        let (applied, edited) = try await Self.lostAndEdited(env, owner(env))
        let byIDs = try await Self.runOnLane(MCHostServices(env.mc), env, lists("host.config.repair{ all = true }"))
        XCTAssertEqual(byIDs["status"] as? String, "nothingToDo", "repair by ids knows only records")

        let deny = MCRecordingConsent(false)
        let denying = MCHostServices(ManagedConfig(roots: env.mc.roots, consent: deny, writer: env.writer))
        let cancelled = try await Self.runOnLane(denying, env, lists("host.config.repair{ pieces = { \(blockPiece) } }"))
        XCTAssertEqual(cancelled["status"] as? String, "denied", "\(cancelled)")
        XCTAssertEqual(deny.seen.map(\.action), [.repair], "the sheet was shown")
        XCTAssertTrue(deny.seen.last?.files.first?.notes.contains { $0.contains("Repair replaces") } ?? false, "the sheet shows the drift note")
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "Cancel: the person's bytes are unchanged")
        XCTAssertEqual(env.mc.ownerIDs(), [], "Cancel: nothing recorded")

        let services = MCHostServices(env.mc)
        let r = try await Self.runOnLane(services, env, lists("host.config.repair{ pieces = { \(blockPiece) } }"))
        XCTAssertEqual(r["status"] as? String, "done", "\(r)")
        XCTAssertEqual(r["applied"] as? String, "rules")
        XCTAssertEqual(env.consent.seen.last?.action, .repair)
        XCTAssertTrue(env.consent.seen.last?.files.first?.lines.contains(.init(sign: .removed, text: "Follow my rules instead.")) ?? false,
                      "the sheet shows the edit it replaces")
        XCTAssertTrue(env.consent.seen.last?.files.first?.notes.contains { $0.contains("Repair replaces") } ?? false)
        XCTAssertEqual(env.bytes(env.claudeMD), applied, "Allow: the block is replaced")
        XCTAssertEqual(env.mc.status(owner: owner(env)).map(\.state), [.applied], "and recorded")
        XCTAssertEqual(services.calls.map(\.owner), [Self.extID])
        XCTAssertFalse(services.calls.contains { $0.onMain })
    }

    func testHostRepairRefusesInvalidPiecesWithApplysRefusal() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let services = MCHostServices(env.mc)
        let badKind = #"{ { id = "rules", kind = "nope", target = "claude:CLAUDE.md", text = "x" } }"#
        let badID = #"{ { id = "../x", kind = "block", target = "claude:CLAUDE.md", text = "x" } }"#
        for pieces in [badKind, badID, #""not a list""#] {
            let viaApply = try await Self.runOnLane(services, env, lists("host.config.apply{ pieces = \(pieces) }"))
            let viaRepair = try await Self.runOnLane(services, env, lists("host.config.repair{ pieces = \(pieces) }"))
            XCTAssertEqual(viaApply["status"] as? String, "refused", "\(viaApply)")
            XCTAssertFalse((viaApply["refused"] as? String ?? "").isEmpty, "\(viaApply)")
            XCTAssertEqual(viaRepair as NSDictionary, viaApply as NSDictionary, "repair refuses as apply does: \(pieces)")
        }
        XCTAssertEqual(env.consent.seen.count, 0, "refused before the sheet")
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertEqual(env.mc.ownerIDs(), [])
    }

    func testHostRepairOfAnotherOwnersPieceIsRefused() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        _ = await env.mc.apply([MCPieces.statusLine()], owner: env.owner("kit-b"))
        let held = try XCTUnwrap(env.bytes(env.settings))
        XCTAssertTrue(String(decoding: held, as: UTF8.self).contains("kit-status"))
        let seen = env.consent.seen.count
        let services = MCHostServices(env.mc)
        // owner fields in the Lua arguments are ignored: the repair is the caller's, and kit-b holds the slot
        let r = try await Self.runOnLane(services, env, lists("""
            host.config.repair{ owner = "kit-b", pieces = { { id = "status", owner = "kit-b", kind = "json", target = "claude:settings.json",
                                                               path = { "statusLine" }, op = "set", value = { type = "command", command = "kit-status" } } } }
            """))
        XCTAssertEqual(r["status"] as? String, "refused", "\(r)")
        XCTAssertEqual(r["refused"] as? String, "status=conflict: kit-b already holds this slot")
        XCTAssertEqual(services.calls.map(\.owner), [Self.extID])
        XCTAssertEqual(env.consent.seen.count, seen, "no sheet")
        XCTAssertEqual(env.bytes(env.settings), held)
        XCTAssertEqual(env.mc.ownerIDs(), ["kit-b"], "nothing recorded for the caller")
        XCTAssertEqual(env.mc.status(owner: env.owner("kit-b")).map(\.state), [.applied])
    }

    func testHostRepairOfAnUnreadableTargetIsRefused() async throws {
        try XCTSkipIf(geteuid() == 0, "root reads a mode-0200 file: the unreadable state cannot be made")
        let env = makeMCEnv()
        let url = env.claudeMD
        let mine: [UInt8] = Array("# mine, known bytes\n".utf8)
        try Data(mine).write(to: url)
        defer { _ = chmod(url.path, 0o600) }
        XCTAssertEqual(chmod(url.path, 0o200), 0)
        let r = try await Self.runOnLane(MCHostServices(env.mc), env, lists("host.config.repair{ pieces = { \(blockPiece) } }"))
        XCTAssertEqual(r["status"] as? String, "refused", "\(r)")
        XCTAssertEqual(r["refused"] as? String, "rules=unreadable: the file exists but cannot be read")
        XCTAssertEqual(env.consent.seen.count, 0, "refused before the sheet")
        XCTAssertEqual(env.writer.temps(url), 0)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertEqual(env.bytes(url), mine)
        XCTAssertEqual(env.files(under: env.backups), [])
    }

    /// The retired-call gate (#1238): __h_config is refused for a call a teardown retired, repair included. On main a
    /// current call would read "main thread"; "not permitted" is the gate's answer, and the service is never reached.
    @MainActor
    func testRetiredCallsHostConfigRepairIsRefused() throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let services = MCHostServices(env.mc)
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: Self.extID, services: services, trusted: true, configOwner: owner(env), isCurrent: { false }).install(into: lua)
        try lua.run("function probe() local r = host.config.repair{ pieces = { \(blockPiece) } } return tostring(r.ok) .. '|' .. r.message end")
        XCTAssertEqual(try lua.callGlobal("probe"), "false|not permitted")
        XCTAssertTrue(services.calls.isEmpty)
        XCTAssertTrue(env.consent.seen.isEmpty)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
    }

    // MARK: item 2, the status row

    func testStatusRowOffersRepairForDriftedWithNoRecordAndNotForApplied() async throws {
        let env = makeMCEnv()
        let services = MCHostServices(env.mc)
        let row = """
            local p = { \(blockPiece) }
            local rows = host.config.status{ pieces = p }
            local out = {}
            for _, r in ipairs(rows) do out[#out + 1] = r.id .. ":" .. r.state .. ":" .. tostring(r.repair) end
            local done = ""
            if rows[1] and rows[1].repair then done = host.config.repair{ pieces = p }.status end
            return { rows = table.concat(out, ","), done = done }
            """
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: owner(env))
        let applied = try XCTUnwrap(env.bytes(env.claudeMD))
        let a = try await Self.runOnLane(services, env, row)
        XCTAssertEqual(a["rows"] as? String, "rules:applied:false", "\(a)")
        XCTAssertEqual(a["done"] as? String, "")
        let seen = env.consent.seen.count

        try FileManager.default.removeItem(at: env.state.appendingPathComponent("state.json"))
        try env.write(try XCTUnwrap(env.read(env.claudeMD)).replacingOccurrences(of: "Follow the kit rules.", with: "Mine."), env.claudeMD)
        let d = try await Self.runOnLane(services, env, row)
        XCTAssertEqual(d["rows"] as? String, "rules:drifted:true", "\(d)")
        XCTAssertEqual(d["done"] as? String, "done", "the offer goes through host.config.repair{ pieces }")
        XCTAssertEqual(env.consent.seen.count, seen + 1, "through the sheet")
        XCTAssertEqual(env.bytes(env.claudeMD), applied)
    }

    // MARK: item 3, uninstall

    func testUninstallCheckNamesAnUnrecordedBlockAndWritesNothing() async throws {
        let env = makeMCEnv()
        let o = owner(env)
        let (_, edited) = try await Self.lostAndEdited(env, o)
        let provider = ManagedConfigProvider(env.mc)
        let silent = await ExtensionRegistry.removeManagedPieces(owner: o, provider: provider)
        XCTAssertTrue(silent == nil, "the premise: with no declared pieces the block is not seen")
        let named = await ExtensionRegistry.removeManagedPieces(owner: o, declared: [MCPieces.block()], provider: provider)
        let kept = try XCTUnwrap(named)
        XCTAssertTrue(kept.contains(#"rules in "claude:CLAUDE.md""#), kept)
        XCTAssertTrue(kept.hasPrefix("Not uninstalled"), kept)
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "the person's bytes are unchanged")
        XCTAssertTrue(env.consent.seen.count == 1, "only the setup's apply asked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.state.appendingPathComponent("state.json").path), "no state written")

        // byte-equal but unrecorded: named too, and not adopted by the check
        let piece = MCPieces.block("other", text: "Other rules.")
        let block = ManagedTextBlock.render(owner: o.id, piece: "other", version: o.version, body: "Other rules.",
                                            syntax: try XCTUnwrap(ManagedTextBlock.syntax(for: env.claudeMD)))
        try Data(edited + Array(block.utf8)).write(to: env.claudeMD)
        let twice = await ExtensionRegistry.removeManagedPieces(owner: o, declared: [MCPieces.block(), piece], provider: provider)
        let both = try XCTUnwrap(twice)
        XCTAssertTrue(both.contains("other in "), both)
        XCTAssertEqual(env.mc.ownerIDs(), [], "nothing adopted")
    }

    @MainActor
    private func installedRegistry(_ env: MCEnv) throws -> (ExtensionRegistry, URL) {
        let userDir = env.root.appendingPathComponent("user-extensions")
        let source = env.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(Self.extID)"
        name = "kit-a"
        title = "Kit"
        description = "A test kit"
        version = "1.0.0"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: source.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "function noop() end".write(to: source.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let registry = ExtensionRegistry(systemDir: nil, userDir: userDir, hostVersion: "2.0.0", defaults: scratchDefaults("mc-repair-wiring"),
                                         services: MCHostServices(env.mc))
        let record = try registry.installLocal(from: source)
        registry.managedConfig = ManagedConfigProvider(env.mc)
        return (registry, record.loaded.directory)
    }

    /// The production path: the extension's status call declares its pieces, the uninstall reads them and stops, naming
    /// the block; after Repair (Allow) the uninstall's Remove sheet takes it and the folder goes.
    @MainActor
    func testUninstallNamesAnUnrecordedBlockThenRemovesItAfterRepair() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let watcher = MCFakeWatcher()
        let refresh = ManagedConfigRefresh(config: env.mc, watcher: watcher.seam, owners: { [] })
        ManagedConfigRefresh.current = refresh
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        let (applied, edited) = try await Self.lostAndEdited(env, o)
        let services = MCHostServices(env.mc)
        _ = try await Self.runOnLane(services, env, configOwner: o, "return { n = #host.config.status{ pieces = { \(blockPiece) } } }")
        for _ in 0..<1000 where refresh.declared[Self.extID] == nil { await Task.yield() }
        XCTAssertEqual(refresh.declared[Self.extID], [MCPieces.block()], "the status call's declaration is kept")

        do {
            try await registry.uninstall(id: Self.extID)
            XCTFail("uninstalled with an unrecorded block left in the file")
        } catch ExtensionError.managedConfigKept(let id, let reason) {
            XCTAssertEqual(id, Self.extID)
            XCTAssertTrue(reason.contains(#"rules in "claude:CLAUDE.md""#), reason)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "the folder stays")
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "the person's bytes are unchanged")
        XCTAssertEqual(env.consent.seen.map(\.action), [.apply], "no sheet from the uninstall")

        let r = try await Self.runOnLane(services, env, configOwner: o, lists("host.config.repair{ pieces = { \(blockPiece) } }"))
        XCTAssertEqual(r["status"] as? String, "done", "\(r)")
        XCTAssertEqual(env.bytes(env.claudeMD), applied)
        try await registry.uninstall(id: Self.extID)
        XCTAssertEqual(env.consent.seen.map(\.action), [.apply, .repair, .remove])
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
