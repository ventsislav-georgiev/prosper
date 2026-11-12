import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
import LuaRuntime
@testable import ProsperApp

/// Host services for the `host.config` tests: everything inert except the managed-config call,
/// which runs the real bridge against a temp-root ManagedConfig and records who called it.
final class MCHostServices: ExtensionHostServices, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(op: String, owner: String, onMain: Bool)] = []
    let config: ManagedConfig

    init(_ config: ManagedConfig) { self.config = config }

    var calls: [(op: String, owner: String, onMain: Bool)] { lock.withLock { _calls } }

    func managedConfigCall(_ op: String, owner: ManagedConfigOwner, json: String) async -> String {
        lock.withLock { _calls.append((op, owner.id, Thread.isMainThread)) }
        return await ManagedConfigLua.call(op, json: json, owner: owner, config: config)
    }

    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
}

/// A watch seam that records paths and fires their handlers on demand.
@MainActor
final class MCFakeWatcher {
    private(set) var handlers: [String: @MainActor () -> Void] = [:]

    var seam: ManagedConfigRefresh.Watcher {
        ManagedConfigRefresh.Watcher(watch: { [weak self] path, onChange in self?.handlers[path] = onChange },
                                     unwatch: { [weak self] path in self?.handlers[path] = nil })
    }

    /// An FSEvents-like change: every watch on the path or on a dir above it fires.
    func fire(_ path: String) {
        for (w, h) in handlers where path == w || path.hasPrefix(w + "/") { h() }
    }
}

/// #870 P2: `host.config`, the consent sheet, the uninstall hook and the status refresh. Numbers in
/// names map to spec 2.8; letters to the brief's decisions and the QA addendum.
final class ManagedConfigHostTests: XCTestCase {
    static let extID = "com.test.kit"

    private func owner(_ env: MCEnv) -> ManagedConfigOwner {
        ManagedConfigOwner(id: Self.extID, version: "1.0.0", kitSlug: "kit-a", extensionDir: env.ext)
    }

    /// Runs `body` (Lua returning a value for host.json.encode) as handler `run` on the extension's
    /// real async lane, the queue every async handler uses.
    private func runOnLane(_ services: MCHostServices, _ env: MCEnv, configOwner: ManagedConfigOwner? = nil, _ body: String) async throws -> [String: Any] {
        let entry = env.root.appendingPathComponent("init-\(UUID().uuidString).lua")
        try "function run(arg) local r = (function() \(body) end)() return host.json.encode(r) end".write(to: entry, atomically: true, encoding: .utf8)
        let lanes = AsyncExtensionRuntimes(services: services)
        let spec = AsyncExtensionRuntimes.Spec(extensionID: Self.extID, entryURL: entry, handler: "run", callTimeout: 30,
                                               privileged: false, trusted: true, configOwner: configOwner ?? owner(env))
        let raw = await lanes.invoke(spec, args: [""])
        let out = try XCTUnwrap(raw)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8), options: [.fragmentsAllowed]) as? [String: Any], out)
    }

    private let blockPiece = #"{ id = "rules", kind = "block", target = "claude:CLAUDE.md", text = "Follow the kit rules." }"#

    // MARK: 2.8-12 Lua API

    @MainActor
    func test12UntrustedExtensionGetsInertAnswersForAllFiveCalls() throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let services = MCHostServices(env.mc)
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: Self.extID, services: services, privileged: false, trusted: false, configOwner: owner(env)).install(into: lua)
        try lua.run("""
        function probe()
            local p = { pieces = { \(blockPiece) } }
            local out = {}
            for _, op in ipairs({ "plan", "apply", "remove", "repair" }) do
                local r = host.config[op]((op == "plan" or op == "apply") and p or { all = true })
                out[#out + 1] = op .. "=" .. tostring(r.ok)
            end
            out[#out + 1] = "status=" .. #host.config.status()
            return table.concat(out, ",") .. "," .. tostring(__h_config)
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "plan=false,apply=false,remove=false,repair=false,status=0,nil")
        XCTAssertTrue(services.calls.isEmpty, "the service is never reached")
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertTrue(env.consent.seen.isEmpty)
    }

    func test12TrustedExtensionCannotNameAnotherOwner() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let services = MCHostServices(env.mc)
        // a record carrying another id, and owner fields in the Lua arguments: both ignored
        var forged = owner(env)
        forged.id = "kit-b"
        let r = try await runOnLane(services, env, configOwner: forged, """
            return host.config.apply{ owner = "kit-b", pieces = { { id = "rules", owner = "kit-b", kind = "block",
                                                                     target = "claude:CLAUDE.md", text = "Follow the kit rules." } } }
            """)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual(services.calls.map(\.owner), [Self.extID])
        XCTAssertEqual(env.mc.status(owner: env.owner("kit-b")).count, 0)
        XCTAssertEqual(env.mc.ownerIDs(), [Self.extID])
        XCTAssertTrue(try XCTUnwrap(env.read(env.claudeMD)).contains("prosper:\(Self.extID):rules"))
    }

    func testStatusShowsOnlyTheCallersPieces() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block("other")], owner: env.owner("kit-b"))
        let services = MCHostServices(env.mc)
        _ = try await runOnLane(services, env, "return host.config.apply{ pieces = { \(blockPiece) } }")
        let r = try await runOnLane(services, env, """
            local rows = host.config.status()
            local ids = {}
            for _, row in ipairs(rows) do ids[#ids + 1] = row.id .. ":" .. row.state end
            return { ids = table.concat(ids, ",") }
            """)
        XCTAssertEqual(r["ids"] as? String, "rules:applied")
    }

    func test12DeniedConsentWritesNothingAndReturnsNotOK() async throws {
        let env = makeMCEnv(consent: false)
        try env.write("# mine\n", env.claudeMD)
        let r = try await runOnLane(MCHostServices(env.mc), env, "return host.config.apply{ pieces = { \(blockPiece) } }")
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual(r["status"] as? String, "denied")
        XCTAssertEqual(env.consent.seen.count, 1)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertNil(env.read(env.state.appendingPathComponent("state.json")), "no state either")
        let again = try await runOnLane(MCHostServices(env.mc), env, lists("host.config.apply{ pieces = { \(blockPiece) } }"))
        XCTAssertEqual(again as NSDictionary, ["status": "denied", "applied": "", "removed": "", "pieces": 0] as NSDictionary,
                       "QA #743 F1: a cancelled apply names nothing")
    }

    /// The Lua answer reduced to strings: an empty Lua table has no fixed JSON shape.
    private func lists(_ call: String) -> String {
        "local r = \(call) return { status = r.status, applied = table.concat(r.applied, \",\"), removed = table.concat(r.removed, \",\"), pieces = #r.pieces }"
    }

    /// QA #743 F1: a cancelled remove or repair names nothing, and the file keeps what it had.
    func test12DeniedRemoveAndRepairNameNothing() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = try await runOnLane(MCHostServices(env.mc), env, "return host.config.apply{ pieces = { \(blockPiece) } }")
        let applied = try XCTUnwrap(env.read(env.claudeMD))
        XCTAssertTrue(applied.contains("prosper:\(Self.extID):rules"), applied)
        let deny = MCRecordingConsent(false)
        let denying = MCHostServices(ManagedConfig(roots: env.mc.roots, consent: deny, writer: env.writer))
        let none = ["status": "denied", "applied": "", "removed": "", "pieces": 0] as NSDictionary
        let removed = try await runOnLane(denying, env, lists(#"host.config.remove{ ids = { "rules" } }"#))
        XCTAssertEqual(removed as NSDictionary, none)
        XCTAssertEqual(env.read(env.claudeMD), applied, "the block is still in the file")
        let edited = applied.replacingOccurrences(of: "Follow the kit rules.", with: "Follow the kit rules, edited.")
        XCTAssertNotEqual(edited, applied)
        try env.write(edited, env.claudeMD)
        let repaired = try await runOnLane(denying, env, lists(#"host.config.repair{ ids = { "rules" } }"#))
        XCTAssertEqual(repaired as NSDictionary, none)
        XCTAssertEqual(env.read(env.claudeMD), edited, "the edit is still in the file")
        XCTAssertEqual(deny.seen.count, 2, "both calls asked")
        // granted: unchanged
        let granted = try await runOnLane(MCHostServices(env.mc), env, lists(#"host.config.repair{ ids = { "rules" } }"#))
        XCTAssertEqual(granted as NSDictionary, ["status": "done", "applied": "rules", "removed": "", "pieces": 1] as NSDictionary)
        XCTAssertEqual(env.read(env.claudeMD), applied)
    }

    /// QA #743 F1, pinned as it was: a cancel after one round landed lists exactly that round.
    func test12DenyAfterALandedRoundListsOnlyTheLandedPieces() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        let consent = MCRecordingConsent(false, script: [true])
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)
        let settings = env.settings
        // CLAUDE.md lands, then settings.json changes under the write: the replan asks again, and is cancelled
        env.writer.interleave { target, n in
            if target.lastPathComponent == "settings.json", n == 1 { try? Data("{\n  \"theme\": \"light\"\n}\n".utf8).write(to: settings) }
        }
        let hook = #"{ id = "pre", kind = "json", target = "claude:settings.json", path = { "hooks", "PreToolUse" }, op = "append", value = { matcher = "Bash", hooks = { { type = "command", command = "kit-run pre" } } } }"#
        let r = try await runOnLane(MCHostServices(mc), env, lists("host.config.apply{ pieces = { \(blockPiece), \(hook) } }"))
        env.writer.interleave(nil)
        XCTAssertEqual(r as NSDictionary, ["status": "denied", "applied": "rules", "removed": "", "pieces": 1] as NSDictionary)
        XCTAssertEqual(consent.seen.count, 2)
        XCTAssertTrue(try XCTUnwrap(env.read(env.claudeMD)).contains("prosper:\(Self.extID):rules"))
        XCTAssertEqual(env.read(env.settings), "{\n  \"theme\": \"light\"\n}\n", "the cancelled piece is not in the file")
    }

    /// QA #743 F1 follow-up: a file that keeps changing until the replans run out. Nothing landed: nothing
    /// named; one file landed first: only its piece.
    func test12FileChangedListsOnlyTheLandedPieces() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        let settings = env.settings
        env.writer.interleave { target, n in
            if target.lastPathComponent == "settings.json" { try? Data("{\n  \"theme\": \"user-\(n)\"\n}\n".utf8).write(to: settings) }
        }
        let hook = #"{ id = "pre", kind = "json", target = "claude:settings.json", path = { "hooks", "PreToolUse" }, op = "append", value = { matcher = "Bash", hooks = { { type = "command", command = "kit-run pre" } } } }"#
        let services = MCHostServices(env.mc)
        let none = try await runOnLane(services, env, lists("host.config.apply{ pieces = { \(hook) } }"))
        XCTAssertEqual(none as NSDictionary, ["status": "fileChanged", "applied": "", "removed": "", "pieces": 0] as NSDictionary)
        let one = try await runOnLane(services, env, lists("host.config.apply{ pieces = { \(blockPiece), \(hook) } }"))
        env.writer.interleave(nil)
        XCTAssertEqual(one as NSDictionary, ["status": "fileChanged", "applied": "rules", "removed": "", "pieces": 1] as NSDictionary)
        XCTAssertTrue(try XCTUnwrap(env.read(env.claudeMD)).contains("prosper:\(Self.extID):rules"))
        XCTAssertFalse(try XCTUnwrap(env.read(env.settings)).contains("kit-run pre"))
    }

    /// The one test that drives the whole path: the Lua call on the extension's async lane, the
    /// bridge's detached task (never main), the consent seam, the write, and the answer back.
    func testLuaApplyEndToEndFromTheAsyncLane() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        let services = MCHostServices(env.mc)
        let plan = try await runOnLane(services, env, """
            return host.config.plan{ pieces = { { id = "pre", kind = "json", target = "claude:settings.json", path = { "hooks", "PreToolUse" },
                op = "append", value = { matcher = "Bash", hooks = { { type = "command", command = "kit-run pre" } } } } } }
            """)
        XCTAssertEqual(plan["ok"] as? Bool, true, "\(plan)")
        XCTAssertTrue(env.consent.seen.isEmpty, "plan never asks")
        XCTAssertEqual(env.read(env.settings), "{\n  \"theme\": \"dark\"\n}\n")
        let r = try await runOnLane(services, env, """
            return host.config.apply{ pieces = { { id = "pre", kind = "json", target = "claude:settings.json", path = { "hooks", "PreToolUse" },
                op = "append", value = { matcher = "Bash", hooks = { { type = "command", command = "kit-run pre" } } } } } }
            """)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual(r["applied"] as? [String], ["pre"])
        XCTAssertEqual(env.consent.seen.count, 1)
        XCTAssertTrue(try XCTUnwrap(env.read(env.settings)).contains("kit-run pre"))
        XCTAssertEqual(services.calls.map(\.op), ["plan", "apply"])
        XCTAssertFalse(services.calls.contains { $0.onMain }, "the bridge never runs the core on main")
        let removed = try await runOnLane(services, env, #"return host.config.remove{ ids = { "pre" } }"#)
        XCTAssertEqual(removed["removed"] as? [String], ["pre"])
        XCTAssertEqual(env.read(env.settings), "{\n  \"theme\": \"dark\"\n}\n")
    }

    @MainActor
    func testWriteCallsFromAMainThreadVMAreRefusedNotDeadlocked() throws {
        let env = makeMCEnv()
        let services = MCHostServices(env.mc)
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: Self.extID, services: services, trusted: true, configOwner: owner(env)).install(into: lua)
        try lua.run("function probe() local r = host.config.apply{ pieces = { \(blockPiece) } } return tostring(r.ok) .. '|' .. r.message end")
        let out = try XCTUnwrap(try lua.callGlobal("probe"))
        XCTAssertTrue(out.hasPrefix("false|"), out)
        XCTAssertTrue(out.contains("main thread"), out)
        XCTAssertTrue(services.calls.isEmpty)
    }

    /// A-INFO-3: an unreadable state reads as such, never as "nothing applied".
    func testStatusOnAnUnreadableStateSaysSo() async throws {
        let env = makeMCEnv()
        try FileManager.default.createDirectory(at: env.state, withIntermediateDirectories: true)
        try env.write("{ half written", env.state.appendingPathComponent("state.json"))
        let r = try await runOnLane(MCHostServices(env.mc), env, "return host.config.status()")
        XCTAssertEqual(r["error"] as? String, "state_unreadable", "\(r)")
        XCTAssertEqual(env.read(env.state.appendingPathComponent("state.json")), "{ half written")
    }

    // MARK: 2.8-13 uninstall hook

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
        let registry = ExtensionRegistry(systemDir: nil, userDir: userDir, hostVersion: "2.0.0", defaults: scratchDefaults("mc-uninstall"),
                                         services: MCHostServices(env.mc))
        let record = try registry.installLocal(from: source)
        registry.managedConfig = ManagedConfigProvider(env.mc)
        return (registry, record.loaded.directory)
    }

    @MainActor
    func test13UninstallWithLivePiecesDeclinedKeepsTheDirAndState() async throws {
        let env = makeMCEnv(consent: false)
        try env.write("# mine\n", env.claudeMD)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        // applied through a consenting core over the same roots
        let yes = ManagedConfig(roots: env.mc.roots, consent: MCRecordingConsent(true))
        _ = await yes.apply([MCPieces.block()], owner: o)
        let applied = env.read(env.claudeMD)
        do {
            try await registry.uninstall(id: Self.extID)
            XCTFail("uninstalled although Remove was declined")
        } catch ExtensionError.managedConfigKept(let id, _) {
            XCTAssertEqual(id, Self.extID)
        }
        XCTAssertEqual(env.consent.seen.map(\.action), [.remove], "the Remove sheet was shown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "dir kept")
        XCTAssertNotNil(registry.record(id: Self.extID))
        XCTAssertEqual(env.mc.status(owner: o).map(\.state), [.applied], "state kept")
        XCTAssertEqual(env.read(env.claudeMD), applied)
    }

    @MainActor
    func test13UninstallWithLivePiecesAcceptedRemovesThemThenTheDir() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        _ = await env.mc.apply([MCPieces.block()], owner: o)
        try await registry.uninstall(id: Self.extID)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n", "the block went first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(registry.record(id: Self.extID))
        XCTAssertEqual(env.mc.ownerIDs(), [])
    }

    @MainActor
    func testUninstallWithNoPiecesNeverShowsTheSheet() async throws {
        let env = makeMCEnv(consent: false)
        let (registry, dir) = try installedRegistry(env)
        try await registry.uninstall(id: Self.extID)
        XCTAssertTrue(env.consent.seen.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testVanishedExtensionDirShowsOrphanedAndRemoveStillWorks() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: owner(env))
        try FileManager.default.removeItem(at: env.ext)
        XCTAssertEqual(env.mc.status(owner: owner(env)).map(\.state), [.orphaned])
        let r = await env.mc.remove(owner: ManagedConfigOwner(id: Self.extID, version: "0"))
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
    }

    // MARK: status refresh

    @MainActor
    func testRefreshRescansAfterARecordedFileChangesAndNeverOnStateWrites() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: owner(env))
        let watcher = MCFakeWatcher()
        let refresh = ManagedConfigRefresh(config: env.mc, watcher: watcher.seam) { [] }
        await refresh.rescan().value
        XCTAssertEqual(refresh.statuses[Self.extID]?.map(\.state), [.applied])
        XCTAssertEqual(refresh.watched, Set(env.mc.recordedPaths()))
        XCTAssertEqual(refresh.watched.map { URL(fileURLWithPath: $0).lastPathComponent }, ["CLAUDE.md"], "never the state dir")
        let watchedMD = try XCTUnwrap(refresh.watched.first)

        // state.json writes (status itself may make them) never trigger a rescan: bounded, no loop
        let scans = refresh.scans
        for _ in 0..<5 {
            try env.write(try XCTUnwrap(env.read(env.state.appendingPathComponent("state.json"))), env.state.appendingPathComponent("state.json"))
            watcher.fire(env.state.appendingPathComponent("state.json").path)
            await Task.yield()
        }
        XCTAssertEqual(refresh.scans, scans, "a state write re-ran status")

        try env.write(try XCTUnwrap(env.read(env.claudeMD)).replacingOccurrences(of: "kit rules", with: "my rules"), env.claudeMD)
        watcher.fire(watchedMD)
        XCTAssertEqual(refresh.scans, scans + 1)
        for _ in 0..<50 where refresh.statuses[Self.extID]?.first?.state != .drifted { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(refresh.statuses[Self.extID]?.map(\.state), [.drifted])
    }

    @MainActor
    func testRefreshFlagsAnUnreadableState() async throws {
        let env = makeMCEnv()
        try FileManager.default.createDirectory(at: env.state, withIntermediateDirectories: true)
        try env.write(#"{"version": 99, "records": [], "files": []}"#, env.state.appendingPathComponent("state.json"))
        let refresh = ManagedConfigRefresh(config: env.mc, watcher: MCFakeWatcher().seam) { [] }
        await refresh.rescan().value
        XCTAssertTrue(refresh.stateUnreadable)
    }

    // MARK: D2 kitconfig dir, D5 events, D6 sweep

    func testD2KitDirGoesWithTheLastPieceOnlyWhenItHoldsJustTheMarker() async throws {
        let env = makeMCEnv()
        let kitDir = env.config.appendingPathComponent("kit-a")
        _ = await env.mc.apply([MCPieces.block(target: "kitconfig:notes.md")], owner: env.owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kitDir.appendingPathComponent(".prosper-kit").path))
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kitDir.path), "only the marker was left: the dir goes")

        _ = await env.mc.apply([MCPieces.block(target: "kitconfig:notes.md")], owner: env.owner)
        try env.write("the user's own file\n", kitDir.appendingPathComponent("mine.txt"))
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(ManagedConfig.entries(of: kitDir), [".prosper-kit", "mine.txt"], "another file in it: the dir stays")
    }

    func testD5HookEventsAreTheDocumented33AndNoOther() async throws {
        XCTAssertEqual(ManagedConfigPlanner.hookEvents.count, 33)
        XCTAssertEqual(Set(ManagedConfigPlanner.hookEvents).count, 33)
        for event in ManagedConfigPlanner.hookEvents { XCTAssertNil(ManagedConfigPlanner.jsonRule(["hooks", event], .append), event) }
        for event in ["MadeUpEvent", "preToolUse", "PreToolUses", "Pre"] {
            XCTAssertEqual(ManagedConfigPlanner.jsonRule(["hooks", event], .append), .refusedJSONPath("hooks.\(event)"), event)
        }
        let env = makeMCEnv()
        let r = await env.mc.apply([MCPieces.hook(event: "MadeUpEvent")], owner: env.owner)
        XCTAssertEqual(r.status, .refused)
        XCTAssertNil(env.read(env.settings))
    }

    func testD6SweepTakesOnlyStaleExactTempNames() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        let dir = env.claude
        let uuid = UUID().uuidString
        let stale = ".CLAUDE.md.prosper-\(uuid)"
        let names = [stale, ".CLAUDE.md.prosper-\(uuid)x", ".CLAUDE.md.prosper-not-a-uuid", ".other.md.prosper-\(uuid)", ".CLAUDE.md.keep", "fresh"]
        for n in names { try env.write("x", dir.appendingPathComponent(n)) }
        let fresh = ".CLAUDE.md.prosper-\(UUID().uuidString)"
        try env.write("x", dir.appendingPathComponent(fresh))
        let old = Date().addingTimeInterval(-ManagedConfig.staleTempAge - 30)
        for n in names { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent(n).path) }
        _ = env.mc.status(owner: env.owner)
        let left = Set(ManagedConfig.entries(of: dir) ?? [])
        XCTAssertFalse(left.contains(stale), "the stale exact-pattern temp goes")
        for n in names.dropFirst() + [fresh] { XCTAssertTrue(left.contains(n), "\(n) stays") }
    }

    // MARK: the consent sheet

    /// D3: a replan that changes the change set shows the sheet a second time, and the sheet copes.
    @MainActor
    func testD3SheetIsShownAgainWhenTheReplanChangesTheSet() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        final class Box: @unchecked Sendable { var models: [ManagedConfigConsentModel] = [] }
        let box = Box()
        let sheet = ManagedConfigSheetConsent { changes, done in
            let model = ManagedConfigConsentModel(changes: changes) { done($0) }
            box.models.append(model)
            _ = ManagedConfigConsentPanel.makePanel(model) // built, never ordered front
            model.answer(true)
        }
        let mc = ManagedConfig(roots: env.mc.roots, consent: sheet, writer: env.writer)
        env.writer.interleave { target, n in
            if target.lastPathComponent == "CLAUDE.md", n == 1 { try? Data("# mine, edited meanwhile\n".utf8).write(to: target) }
        }
        let r = await mc.apply([MCPieces.block()], owner: env.owner)
        env.writer.interleave(nil)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(box.models.count, 2, "the diff changed: asked again")
        XCTAssertTrue(box.models.allSatisfy(\.answered))
        if box.models.count == 2 { XCTAssertNotEqual(box.models[0].changes, box.models[1].changes) } // never index past a short list
        XCTAssertTrue(try XCTUnwrap(env.read(env.claudeMD)).hasPrefix("# mine, edited meanwhile\n"))
    }

    /// errata C11: a dummy secret in `env` never reaches the rendered sheet. `renderedStrings` lists
    /// every string ManagedConfigConsentView draws (each Text reads title, path, status, text(line),
    /// notes or the backup line). SwiftUI publishes no AX tree for a hosting view in xctest, so the
    /// view's strings are pinned through the model it renders, and the view is built at the end.
    @MainActor
    func testSheetRenderedForSettingsWithASecretMasksIt() async throws {
        let env = makeMCEnv()
        let secret = "dummy-secret-not-real-0000"
        try env.write("{\n  \"env\": {\"API_TOKEN\": \"\(secret)\"},\n  \"hooks\": {}\n}\n", env.settings)
        _ = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        let changes = try XCTUnwrap(env.consent.seen.first)
        let model = ManagedConfigConsentModel(changes: changes) { _ in }
        let strings = model.renderedStrings
        XCTAssertFalse(strings.contains { $0.contains(secret) }, "\(strings)")
        XCTAssertFalse(strings.contains { $0.contains("API_TOKEN") }, "\(strings)")
        XCTAssertTrue(strings.contains { $0.hasPrefix("+ ") && $0.contains("kit-run pre") }, "the added hook is shown: \(strings)")
        XCTAssertTrue(strings.contains { $0.hasSuffix("settings.json") }, "\(strings)")
        XCTAssertTrue(strings.contains(ManagedConfigConsentModel.liveNote))
        XCTAssertTrue(strings.contains { $0.hasPrefix("Backup: ") })
        let size = NSHostingController(rootView: ManagedConfigConsentView(model: model)).sizeThatFits(in: CGSize(width: 560, height: 10_000))
        XCTAssertGreaterThan(size.height, 100, "the view renders the model")
    }

    /// Nothing clips at UI scale 0.7 and 0.85: the view fits the panel's scaled width, and its text
    /// wraps (taller, never wider) as the content grows.
    @MainActor
    func testSheetFitsItsPanelAtEveryUIScale() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        _ = await env.mc.apply([MCPieces.hook(command: "kit-run --with-a-rather-long-flag=" + String(repeating: "x", count: 120)),
                                MCPieces.statusLine()], owner: env.owner)
        let model = ManagedConfigConsentModel(changes: try XCTUnwrap(env.consent.seen.first)) { _ in }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        var heights: [CGFloat] = []
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            let width = sz(ManagedConfigConsentPanel.width)
            let size = NSHostingController(rootView: ManagedConfigConsentView(model: model))
                .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, width + 1, "scale \(scale): \(size.width) > \(width)") // sub-point rounding of scaled padding
            XCTAssertGreaterThan(size.height, 100, "scale \(scale)")
            heights.append(size.height)
        }
        XCTAssertLessThan(heights[0], heights[2], "text scales with the UI")
    }

    func testSheetConsentHopsToMainAndALateAnswerAfterCancelIsACancel() async throws {
        let consent = ManagedConfigSheetConsent { _, done in
            XCTAssertTrue(Thread.isMainThread)
            done(true)
        }
        let set = ManagedConfigChangeSet(action: .apply, owner: "kit-a", files: [], pieces: [])
        let yes = await Task.detached { await consent.confirm(set) }.value
        XCTAssertTrue(yes)
        let task = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await consent.confirm(set)
        }
        let late = await task.value
        XCTAssertFalse(late, "the bridge gave up: Apply after that writes nothing")
    }

    // MARK: production seams, without I/O

    /// r2 (R2-1): the script is portable (no `${…}`, which fish rejects): printenv between two
    /// markers. Exactly one trailing newline (printenv's own) is dropped; unset reads as "".
    func testLoginPathValueReadsOneVariableThroughTheProbe() {
        let marker = LoginPath.marker
        func read(_ out: String?) -> String? {
            LoginPath.value(of: "CLAUDE_CONFIG_DIR", shell: "/opt/fake/fish") { _, script in
                XCTAssertFalse(script.contains("${"), script)
                XCTAssertTrue(script.contains("; /usr/bin/printenv CLAUDE_CONFIG_DIR; "), script)
                return out.map { Data($0.utf8) }
            }
        }
        XCTAssertEqual(read("motd noise\(marker)/scratch/claude\n\(marker)bye"), "/scratch/claude")
        XCTAssertEqual(read("\(marker)A\n\n\(marker)"), "A\n", "exactly one newline goes")
        XCTAssertEqual(read("\(marker)\(marker)"), "", "unset: printenv prints nothing")
        XCTAssertEqual(read("\(marker)\n\(marker)"), "", "set and empty")
        XCTAssertNil(read(nil))
        XCTAssertNil(read("no markers at all"))
        XCTAssertNil(LoginPath.value(of: "BAD; rm", shell: "/bin/zsh") { _, _ in XCTFail("probed"); return nil })
    }

    func testProviderCachesSuccessOnlyAndLiveIsOffUnderTests() {
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let mc = makeMCEnv().mc
        let flaky = ManagedConfigProvider(make: {
            count.n += 1
            return count.n == 1 ? .failure(.unwritable("probe failed")) : .success(mc)
        })
        guard case .failure = flaky.get() else { return XCTFail("first get") }
        guard case .success = flaky.get() else { return XCTFail("second get") }
        _ = flaky.get()
        XCTAssertEqual(count.n, 2, "a failure is retried, a success cached")
        guard case .failure = ManagedConfigProvider.live.get() else { return XCTFail("the live provider ran under XCTest") }
        XCTAssertNil(ManagedConfigProvider.live.stateOnly(), "nor its state-only view")
    }

    // MARK: r2

    /// A provider whose login-env probe fails, over the env's state.
    private func failing(_ env: MCEnv) -> ManagedConfigProvider {
        let mc = env.mc
        return ManagedConfigProvider(make: { .failure(.unwritable("slow login shell")) }, stateOnly: { mc })
    }

    /// R2-1: an extension that never wrote a piece uninstalls while the provider cannot resolve.
    @MainActor
    func testR2UninstallWithAFailingProviderAndNoStateGoesAhead() async throws {
        let env = makeMCEnv(consent: false)
        let (registry, dir) = try installedRegistry(env)
        registry.managedConfig = failing(env)
        try await registry.uninstall(id: Self.extID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(registry.record(id: Self.extID))
        XCTAssertTrue(env.consent.seen.isEmpty)
        XCTAssertNil(env.read(env.state.appendingPathComponent("state.json")))
    }

    @MainActor
    func testR2UninstallWithAFailingProviderKeepsAnOwnerWithRecords() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        _ = await env.mc.apply([MCPieces.block()], owner: o)
        let applied = env.read(env.claudeMD)
        registry.managedConfig = failing(env)
        do {
            try await registry.uninstall(id: Self.extID)
            XCTFail("uninstalled with pieces it could not remove")
        } catch ExtensionError.managedConfigKept(let id, let reason) {
            XCTAssertEqual(id, Self.extID)
            XCTAssertTrue(reason.contains("slow login shell"), reason)
        }
        XCTAssertEqual(env.consent.seen.count, 1, "only the apply asked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "dir kept")
        XCTAssertEqual(env.mc.ownerIDs(), [Self.extID], "state kept")
        XCTAssertEqual(env.read(env.claudeMD), applied)
    }

    @MainActor
    func testR2UninstallWithAFailingProviderIgnoresAnotherOwnersRecords() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block("other")], owner: env.owner("kit-b"))
        let (registry, dir) = try installedRegistry(env)
        registry.managedConfig = failing(env)
        try await registry.uninstall(id: Self.extID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(env.mc.ownerIDs(), ["kit-b"])
    }

    /// R2-1 (c), pinned: an unreadable state stops every uninstall, provider or not.
    @MainActor
    func testR2UninstallOnAnUnreadableStateIsRefusedWithOrWithoutTheProvider() async throws {
        let env = makeMCEnv()
        try FileManager.default.createDirectory(at: env.state, withIntermediateDirectories: true)
        try env.write("{ half written", env.state.appendingPathComponent("state.json"))
        let (registry, dir) = try installedRegistry(env)
        for provider in [ManagedConfigProvider(env.mc), failing(env)] {
            registry.managedConfig = provider
            do {
                try await registry.uninstall(id: Self.extID)
                XCTFail("uninstalled over an unreadable state")
            } catch ExtensionError.managedConfigKept(_, let reason) {
                XCTAssertEqual(reason, ManagedConfigRefusalReason.stateUnreadable.description)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        }
        XCTAssertEqual(env.read(env.state.appendingPathComponent("state.json")), "{ half written")
    }

    /// R2-2: a Return typed into another app must not consent. Apply has no key equivalent; Esc
    /// still cancels. AppKit's defaultButtonCell is checked too, and what it reports for a SwiftUI
    /// .defaultAction is printed for the record: the source guard is what pins the rule.
    @MainActor
    func testR2ApplyHasNoKeyEquivalent() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/ManagedConfigHost/ManagedConfigConsentSheet.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(".defaultAction"), "Apply must not answer Return")
        XCTAssertTrue(text.contains(".keyboardShortcut(.cancelAction)"), "Esc still cancels")
        let set = ManagedConfigChangeSet(action: .apply, owner: "kit-a", files: [], pieces: [])
        let panel = ManagedConfigConsentPanel.makePanel(ManagedConfigConsentModel(changes: set) { _ in }) // never ordered front
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(panel.defaultButtonCell)
        let probe = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        probe.contentView = NSHostingView(rootView: Button("Go") {}.keyboardShortcut(.defaultAction))
        probe.contentView?.layoutSubtreeIfNeeded()
        print("r2 R2-2 probe: SwiftUI .defaultAction sets NSWindow.defaultButtonCell = \(probe.defaultButtonCell != nil)")
    }

    /// R2-3: the refresh comes to exist on the first successful resolve, not only at launch; ten
    /// racing first successes still make one.
    @MainActor
    func testR2RefreshComesToExistOnTheFirstSuccessfulResolve() async throws {
        let saved = ManagedConfigRefresh.current
        ManagedConfigRefresh.current = nil
        defer { ManagedConfigRefresh.current = saved }
        let mc = makeMCEnv().mc
        final class Gate: @unchecked Sendable { let lock = NSLock(); var up = false }
        @MainActor final class Count { var rescans = 0 }
        let gate = Gate(), count = Count()
        let provider = ManagedConfigProvider(make: {
            gate.lock.withLock { gate.up } ? .success(mc) : .failure(.unwritable("slow login shell"))
        })
        let watcher = MCFakeWatcher()
        // every refresh rescans once when made, and asks for the owners once per rescan
        ManagedConfigRefresh.follow(provider, watcher: watcher.seam) { count.rescans += 1; return [] }
        guard case .failure = await provider.resolve() else { return XCTFail("first get") }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(ManagedConfigRefresh.current, "a failed resolve makes nothing")
        gate.lock.withLock { gate.up = true }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = await provider.resolve() } }
        }
        for _ in 0..<100 where ManagedConfigRefresh.current == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let refresh = try XCTUnwrap(ManagedConfigRefresh.current, "a later success makes the refresh")
        XCTAssertTrue(refresh.config === mc)
        XCTAssertEqual(count.rescans, 1, "one refresh, however many callers raced")
    }

    /// R2-4: plan's Lua answer carries the extension's own lines only, never the user's text
    /// around them; the consent change set keeps that context for the sheet.
    func testR2PlanDiffCarriesNoLineOfTheUsersFile() async throws {
        let env = makeMCEnv()
        try env.write((1...10).map { "user line \($0) private-text" }.joined(separator: "\n") + "\n", env.claudeMD)
        let r = try await runOnLane(MCHostServices(env.mc), env, """
            return host.config.plan{ pieces = { { id = "rules", kind = "block", target = "claude:CLAUDE.md", text = "Follow the kit rules.", position = "bottom" } } }
            """)
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: r), as: UTF8.self)
        XCTAssertFalse(json.contains("private-text"), json)
        let diff = try XCTUnwrap((r["files"] as? [[String: Any]])?.first?["diff"] as? String)
        XCTAssertTrue(diff.contains("+Follow the kit rules."), diff)
        let lines = try XCTUnwrap(env.mc.plan([MCPieces.block()], owner: owner(env)).changes.files.first).lines
        XCTAssertTrue(lines.contains { $0.sign == .context && $0.text.contains("private-text") }, "\(lines)")
    }

    /// T1: an empty id list is never "all", and a call with neither key does nothing.
    func testT1EmptyIDsNeverMeanAll() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let services = MCHostServices(env.mc)
        _ = try await runOnLane(services, env, "return host.config.apply{ pieces = { \(blockPiece) } }")
        // drifted, so a repair of "all" would have something to do
        try env.write(try XCTUnwrap(env.read(env.claudeMD)).replacingOccurrences(of: "kit rules", with: "my rules"), env.claudeMD)
        let before = env.read(env.claudeMD)
        for op in ["repair", "remove"] {
            let r = try await runOnLane(services, env, "return host.config.\(op){ ids = {} }")
            XCTAssertEqual(r["ok"] as? Bool, true, "\(op): \(r)")
            XCTAssertEqual(r["status"] as? String, "nothingToDo", "\(op): \(r)")
            let none = try await runOnLane(services, env, "return host.config.\(op){}")
            XCTAssertEqual(none["ok"] as? Bool, false, "\(op): \(none)")
            XCTAssertTrue((none["message"] as? String ?? "").contains("needs ids = { … } or all = true"), "\(op): \(none)")
        }
        XCTAssertEqual(env.consent.seen.count, 1, "only the apply asked")
        XCTAssertEqual(env.read(env.claudeMD), before)
        XCTAssertEqual(env.mc.status(owner: owner(env)).map(\.state), [.drifted])
    }

    /// T2: malformed pieces from Lua: plan names the piece and the reason; apply refuses, asks
    /// nothing and writes nothing.
    func testT2MalformedPiecesThroughLuaAreRefusedByName() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let services = MCHostServices(env.mc)
        let md = #"kind = "block", target = "claude:CLAUDE.md", text = "t""#
        let cases: [(pieces: String, id: String, why: String)] = [
            (#""x""#, "*", "pieces must be a list"),
            (#"{ "x" }"#, "#1", "a piece is a table"),
            ("{ { \(md) } }", "#1", "id, target and kind"),
            (#"{ { id = "a", kind = "block", text = "t" } }"#, "a", "id, target and kind"),
            (#"{ { id = "a", kind = "blob", target = "claude:CLAUDE.md", text = "t" } }"#, "a", "id, target and kind"),
            ("{ { id = \"a\", \(md), position = \"middle\" } }", "a", "position is top or bottom"),
            (#"{ { id = "a", kind = "json", target = "claude:settings.json", path = { "permissions", "allow" }, op = "merge", value = { "x" } } }"#,
             "a", "op is append, union or set"),
            (#"{ { id = "a", kind = "json", target = "claude:settings.json", path = { 1, 2 }, op = "union", value = { "x" } } }"#,
             "a", "path is a list of keys"),
        ]
        for c in cases {
            let plan = try await runOnLane(services, env, "return host.config.plan{ pieces = \(c.pieces) }")
            XCTAssertEqual(plan["ok"] as? Bool, false, "\(c.pieces): \(plan)")
            let refused = (plan["refused"] as? [[String: Any]]) ?? []
            XCTAssertEqual(refused.first?["id"] as? String, c.id, "\(c.pieces): \(plan)")
            XCTAssertTrue((refused.first?["why"] as? String ?? "").contains(c.why), "\(c.pieces): \(plan)")
            let apply = try await runOnLane(services, env, "return host.config.apply{ pieces = \(c.pieces) }")
            XCTAssertEqual(apply["ok"] as? Bool, false, "\(c.pieces): \(apply)")
            XCTAssertEqual(apply["status"] as? String, "refused", "\(c.pieces): \(apply)")
        }
        XCTAssertTrue(env.consent.seen.isEmpty)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertNil(env.read(env.settings))
        XCTAssertNil(env.read(env.state.appendingPathComponent("state.json")))
    }

    /// T3: the refresh lets go of a path once no record points at it, and stop() drops them all.
    @MainActor
    func testT3RefreshUnwatchesAPathNoRecordPointsAt() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: owner(env))
        let watcher = MCFakeWatcher()
        let refresh = ManagedConfigRefresh(config: env.mc, watcher: watcher.seam) { [] }
        await refresh.rescan().value
        XCTAssertEqual(refresh.watched.map { URL(fileURLWithPath: $0).lastPathComponent }, ["CLAUDE.md"])
        XCTAssertEqual(Set(watcher.handlers.keys), refresh.watched)
        _ = await env.mc.remove(owner: owner(env))
        await refresh.rescan().value
        XCTAssertTrue(refresh.watched.isEmpty, "\(refresh.watched)")
        XCTAssertTrue(watcher.handlers.isEmpty, "\(watcher.handlers.keys)")
        _ = await env.mc.apply([MCPieces.block()], owner: owner(env))
        await refresh.rescan().value
        XCTAssertFalse(watcher.handlers.isEmpty)
        refresh.stop()
        XCTAssertTrue(watcher.handlers.isEmpty, "\(watcher.handlers.keys)")
        XCTAssertTrue(refresh.watched.isEmpty)
    }

    /// T4: the panel's queue behind its show seam: one sheet at a time, in request order, each
    /// answered once; idle afterwards. The production show is never called here.
    @MainActor
    func testT4ConsentPanelShowsOneSheetAtATimeInRequestOrder() {
        @MainActor final class Log { var shown: [ManagedConfigConsentModel] = []; var closed = 0; var answers: [String] = [] }
        let log = Log()
        let panel = ManagedConfigConsentPanel { model in
            log.shown.append(model)
            return { log.closed += 1 }
        }
        func request(_ n: Int) {
            panel.enqueue(ManagedConfigChangeSet(action: .apply, owner: "kit-\(n)", files: [], pieces: [])) { log.answers.append("kit-\(n):\($0)") }
        }
        for n in 1...3 { request(n) }
        XCTAssertEqual(log.shown.map(\.changes.owner), ["kit-1"], "one at a time")
        log.shown[0].answer(true)
        XCTAssertEqual(log.answers, ["kit-1:true"])
        XCTAssertEqual(log.closed, 1)
        XCTAssertEqual(log.shown.map(\.changes.owner), ["kit-1", "kit-2"])
        guard log.shown.count == 2 else { return XCTFail("the next request was not shown") } // never index past a short list
        log.shown[0].answer(false)
        XCTAssertEqual(log.answers, ["kit-1:true"], "a second answer does nothing")
        XCTAssertEqual(log.closed, 1)
        log.shown[1].answer(false)
        guard log.shown.count == 3 else { return XCTFail("the third request was not shown") }
        log.shown[2].answer(true)
        XCTAssertEqual(log.answers, ["kit-1:true", "kit-2:false", "kit-3:true"], "request order")
        XCTAssertEqual(log.closed, 3)
        XCTAssertEqual(log.shown.count, 3, "the queue is empty")
        request(4)
        XCTAssertEqual(log.shown.map(\.changes.owner), ["kit-1", "kit-2", "kit-3", "kit-4"], "idle: a new request shows at once")
    }

    // MARK: r3

    /// Counts hook calls and keeps the configs they were given. Lock-guarded: the race test calls it
    /// from many threads.
    private final class HookLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [ManagedConfig] = []
        func record(_ config: ManagedConfig) { lock.withLock { seen.append(config) } }
        var configs: [ManagedConfig] { lock.withLock { seen } }
    }

    /// r3 (R3-1): a hook set after a get() already succeeded runs at once, with the cached config,
    /// and never again.
    func testR3HookSetAfterACachedSuccessRunsOnceAtOnce() {
        let mc = makeMCEnv().mc
        let provider = ManagedConfigProvider(make: { .success(mc) })
        guard case .success = provider.get() else { return XCTFail("first get") }
        let log = HookLog()
        provider.onFirstSuccess { log.record($0) }
        XCTAssertEqual(log.configs.count, 1, "the hook runs as it is set")
        XCTAssertTrue(log.configs.first === mc, "with the cached config")
        _ = provider.get()
        XCTAssertEqual(log.configs.count, 1, "a later get() does not run it again")
    }

    /// r3 (R3-1): a hook set first runs on the first get() that succeeds, once.
    func testR3HookSetBeforeTheFirstSuccessRunsOnce() {
        let mc = makeMCEnv().mc
        let provider = ManagedConfigProvider(make: { .success(mc) })
        let log = HookLog()
        provider.onFirstSuccess { log.record($0) }
        XCTAssertEqual(log.configs.count, 0, "nothing is cached yet")
        _ = provider.get()
        _ = provider.get()
        XCTAssertEqual(log.configs.count, 1)
        XCTAssertTrue(log.configs.first === mc)
    }

    /// r3 (R3-1): concurrent get() calls racing one onFirstSuccess still run the hook exactly once,
    /// whichever side wins. 300 rounds, no sleeps.
    func testR3ConcurrentGetsRacingTheHookRunItExactlyOnce() {
        let mc = makeMCEnv().mc
        for round in 0..<300 {
            let provider = ManagedConfigProvider(make: { .success(mc) })
            let log = HookLog()
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                if i == round % 8 { provider.onFirstSuccess { log.record($0) } } else { _ = provider.get() }
            }
            XCTAssertEqual(log.configs.count, 1, "round \(round)")
            if log.configs.count != 1 { return }
        }
    }
}
