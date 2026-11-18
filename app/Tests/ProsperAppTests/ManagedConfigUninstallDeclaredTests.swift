import Foundation
import XCTest
@testable import ProsperApp

/// #1232 round 2: the uninstall adopts a byte-equal declared block with no record (F1232-1), a disabled extension's
/// declaration is dropped and never stops its uninstall (F1232-2), the kept declaration is capped and the notice names at
/// most five blocks (R1232-2). Round 3 (OQ-144 b): an edited unrecorded block no longer stops the uninstall; it is left
/// in the file and named afterwards in Extensions settings (ExtensionRegistry.uninstallNotices). Every file is the row's own, inside its tempDir() (a made-up home and fake kit ids); the
/// registry installs into the row's tempDir() and its uninstall removes only that row's extension folder.
/// Isolation: the rows that touch the registry or ManagedConfigRefresh are @MainActor; the owners closure runs on main.
final class ManagedConfigUninstallDeclaredTests: XCTestCase {
    static let extID = "com.test.kit"

    /// Applies `pieces`, then loses the state (the records): the blocks stay in the file byte for byte.
    private static func lost(_ env: MCEnv, _ o: ManagedConfigOwner, _ pieces: [ManagedConfigPiece]) async throws -> [UInt8] {
        try env.write("# mine\n", env.claudeMD)
        let r = await env.mc.apply(pieces, owner: o)
        XCTAssertEqual(r.status, .done)
        try FileManager.default.removeItem(at: env.state.appendingPathComponent("state.json"))
        XCTAssertEqual(env.mc.ownerIDs(), [])
        return try XCTUnwrap(env.bytes(env.claudeMD))
    }

    /// `lost`, then each block's text edited by hand.
    private static func lostAndEdited(_ env: MCEnv, _ o: ManagedConfigOwner, _ pieces: [ManagedConfigPiece]) async throws -> [UInt8] {
        _ = try await lost(env, o, pieces)
        var text = try XCTUnwrap(env.read(env.claudeMD))
        for p in pieces { text = text.replacingOccurrences(of: p.text ?? "", with: "Mine, \(p.id).") }
        try env.write(text, env.claudeMD)
        return try XCTUnwrap(env.bytes(env.claudeMD))
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
        let registry = ExtensionRegistry(systemDir: nil, userDir: userDir, hostVersion: "2.0.0", defaults: scratchDefaults("mc-uninstall-declared"),
                                         services: MCHostServices(env.mc))
        let record = try registry.installLocal(from: source)
        registry.managedConfig = ManagedConfigProvider(env.mc)
        return (registry, record.loaded.directory)
    }

    /// The row's own refresh as `current` (restored by the caller's defer); its watcher is a recorder.
    @MainActor
    private func ownRefresh(_ env: MCEnv) -> ManagedConfigRefresh {
        let refresh = ManagedConfigRefresh(config: env.mc, watcher: MCFakeWatcher().seam, owners: { [] })
        ManagedConfigRefresh.current = refresh
        return refresh
    }

    // MARK: F1232-1

    @MainActor
    func testUninstallAdoptsAByteEqualUnrecordedDeclaredBlockAndRemovesItOnAllow() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        _ = try await Self.lost(env, o, [MCPieces.block()])
        refresh.declared[Self.extID] = [MCPieces.block()]

        try await registry.uninstall(id: Self.extID)
        XCTAssertEqual(env.consent.seen.map(\.action), [.apply, .remove], "the Remove sheet took the adopted block")
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n", "on Allow the block is gone, the person's bytes are as before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "the folder is removed")
        XCTAssertEqual(env.mc.ownerIDs(), [])
    }

    /// OQ-144 (b): an edited unrecorded declared block no longer stops the uninstall: the folder goes, the block's bytes
    /// stay, and Extensions settings' notice names it afterwards.
    @MainActor
    func testUninstallGoesOnPastAnEditedUnrecordedDeclaredBlockAndNamesItAfterward() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        let edited = try await Self.lostAndEdited(env, o, [MCPieces.block()])
        refresh.declared[Self.extID] = [MCPieces.block()]

        try await registry.uninstall(id: Self.extID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "the folder is removed")
        XCTAssertTrue(registry.record(id: Self.extID) == nil)
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "the block is left, the person's bytes are unchanged")
        XCTAssertEqual(env.consent.seen.map(\.action), [.apply], "no sheet from the uninstall")
        XCTAssertEqual(env.mc.ownerIDs(), [], "an edited block is not adopted")
        XCTAssertTrue(refresh.declared[Self.extID] == nil, "dropped with the uninstall")
        XCTAssertEqual(registry.uninstallNotices.count, 1)
        let notice = registry.uninstallNotices.last ?? ""
        XCTAssertTrue(notice.hasPrefix("Uninstalled \(Self.extID). "), notice)
        XCTAssertTrue(notice.contains(#"left in the file as they are: rules in "claude:CLAUDE.md"."#), notice)
        XCTAssertTrue(notice.contains("delete it from the file yourself"), notice)
    }

    /// OQ-144: a recorded piece goes through the Remove sheet as before; the unrecorded edited block beside it is left
    /// and named; only the recorded one is removed.
    @MainActor
    func testUninstallRemovesTheRecordedPieceAndNamesOnlyTheUnrecordedBlock() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        let edited = try await Self.lostAndEdited(env, o, [MCPieces.block()])
        try env.write("{}\n", env.settings)
        let r = await env.mc.apply([MCPieces.hook()], owner: o)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.mc.ownerIDs(), [o.id])
        refresh.declared[Self.extID] = [MCPieces.block(), MCPieces.hook()]

        try await registry.uninstall(id: Self.extID)
        XCTAssertEqual(env.consent.seen.map(\.action), [.apply, .apply, .remove], "the Remove sheet took the recorded one")
        XCTAssertFalse(env.read(env.settings)?.contains("kit-run pre") ?? true, "the recorded hook is removed")
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "the unrecorded block is left byte for byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let notice = registry.uninstallNotices.last ?? ""
        XCTAssertTrue(notice.contains(#"rules in "claude:CLAUDE.md"."#), notice)
        XCTAssertFalse(notice.contains("pre in "), notice)
    }

    /// OQ-144: a Remove sheet that is cancelled still stops the uninstall: no notice, the declaration kept.
    @MainActor
    func testCancelledRemoveStillStopsAndGivesNoNotice() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        let edited = try await Self.lostAndEdited(env, o, [MCPieces.block()])
        try env.write("{}\n", env.settings)
        _ = await env.mc.apply([MCPieces.hook()], owner: o)
        let settings = env.bytes(env.settings)
        refresh.declared[Self.extID] = [MCPieces.block(), MCPieces.hook()]
        let denying = MCRecordingConsent(false)
        registry.managedConfig = ManagedConfigProvider(ManagedConfig(roots: env.mc.roots, consent: denying))

        do {
            try await registry.uninstall(id: Self.extID)
            XCTFail("uninstalled although Remove was declined")
        } catch ExtensionError.managedConfigKept(let id, _) {
            XCTAssertEqual(id, Self.extID)
        }
        XCTAssertEqual(denying.seen.map(\.action), [.remove])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "the folder stays")
        XCTAssertEqual(env.bytes(env.claudeMD), edited)
        XCTAssertEqual(env.bytes(env.settings), settings)
        XCTAssertTrue(registry.uninstallNotices.isEmpty, "nothing was uninstalled, nothing to say")
        XCTAssertEqual(refresh.declared[Self.extID], [MCPieces.block(), MCPieces.hook()], "a stopped uninstall keeps it")
    }

    /// R1232-2 / OQ-144: the notices are capped (the newest kept) and Dismiss takes one out.
    @MainActor
    func testUninstallNoticesAreCappedAndDismissable() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, _) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        let edited = try await Self.lostAndEdited(env, o, [MCPieces.block()])
        let source = env.root.appendingPathComponent("source")
        for n in 1...(ExtensionRegistry.maxUninstallNotices + 1) {
            if n > 1 { _ = try registry.installLocal(from: source) }
            refresh.declared[Self.extID] = [MCPieces.block()]
            try await registry.uninstall(id: Self.extID)
        }
        XCTAssertEqual(ExtensionRegistry.maxUninstallNotices, 5)
        XCTAssertEqual(registry.uninstallNotices.count, 5, "at most five kept")
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "six uninstalls, the block untouched")
        registry.dismissUninstallNotice(at: 0)
        XCTAssertEqual(registry.uninstallNotices.count, 4)
        registry.dismissUninstallNotice(at: 99) // out of range: nothing
        XCTAssertEqual(registry.uninstallNotices.count, 4)
    }

    // MARK: F1232-2

    @MainActor
    func testDisabledExtensionWithAnEditedDeclaredBlockUninstallsAndLeavesTheBlock() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        let edited = try await Self.lostAndEdited(env, o, [MCPieces.block()])
        try registry.setEnabled(false, id: Self.extID)
        // a status hop that lands after the disable: the uninstall must still not read it
        refresh.declared[Self.extID] = [MCPieces.block()]

        try await registry.uninstall(id: Self.extID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "disable, then uninstall works in the same session")
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "the block stays in the file, untouched, byte for byte")
        XCTAssertEqual(env.consent.seen.map(\.action), [.apply], "no sheet: nothing recorded to remove")
        XCTAssertTrue(refresh.declared[Self.extID] == nil, "dropped with the uninstall")
    }

    @MainActor
    func testDisablingDropsTheDeclarationAndReenablingGivesNone() throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, _) = try installedRegistry(env)
        refresh.declared[Self.extID] = [MCPieces.block()]
        refresh.declared["com.test.other"] = [MCPieces.block()]
        try registry.setEnabled(false, id: Self.extID)
        XCTAssertTrue(refresh.declared[Self.extID] == nil, "disable drops it")
        try registry.setEnabled(true, id: Self.extID)
        XCTAssertTrue(refresh.declared[Self.extID] == nil, "re-enabled with no status call: no declaration")
        XCTAssertEqual(refresh.declared["com.test.other"], [MCPieces.block()], "another id's is kept")
    }

    @MainActor
    func testUninstallDropsTheDeclaration() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, dir) = try installedRegistry(env)
        try env.write("# mine\n", env.claudeMD)
        refresh.declared[Self.extID] = [MCPieces.block()] // declared but never applied: not in the file
        try await registry.uninstall(id: Self.extID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(refresh.declared[Self.extID] == nil, "a reinstall under the same id starts with none")
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertEqual(env.consent.seen.count, 0)
    }

    // MARK: R1232-2

    @MainActor
    func testOverTheCapNothingIsKept() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let o = ManagedConfigOwner(id: Self.extID, version: "1.0.0", kitSlug: "kit-a", extensionDir: env.ext)
        let atCap = (0..<KitManifest.maxPieces).map { MCPieces.block("p\($0)", text: "Rule \($0).") }
        XCTAssertEqual(atCap.count, 64)
        ManagedConfigLua.remember(atCap, of: o) // nonisolated; its hop runs on main
        for _ in 0..<1000 where refresh.declared[Self.extID]?.count != 64 { await Task.yield() }
        XCTAssertEqual(refresh.declared[Self.extID]?.count, 64, "at the cap the list is kept whole")
        ManagedConfigLua.remember(atCap + [MCPieces.block("p64", text: "One more.")], of: o)
        for _ in 0..<1000 where refresh.declared[Self.extID] != nil { await Task.yield() }
        XCTAssertTrue(refresh.declared[Self.extID] == nil, "over the cap nothing is kept, not a cut list")
    }

    func testNoticeWithSevenBlocksNamesFiveAndSaysTwoMore() async throws {
        let env = makeMCEnv()
        let o = ManagedConfigOwner(id: Self.extID, version: "1.0.0", kitSlug: "kit-a", extensionDir: env.ext)
        let pieces = (1...7).map { MCPieces.block("b\($0)", text: "Rule \($0).") }
        let edited = try await Self.lostAndEdited(env, o, pieces)
        let outcome = await ExtensionRegistry.removeManagedPieces(owner: o, declared: pieces, provider: ManagedConfigProvider(env.mc))
        XCTAssertTrue(outcome.stop == nil, "OQ-144 (b): no stop")
        let reason = try XCTUnwrap(outcome.left)
        for n in 1...5 { XCTAssertTrue(reason.contains("b\(n) in "), reason) }
        XCTAssertFalse(reason.contains("b6 in ") || reason.contains("b7 in "), reason)
        XCTAssertTrue(reason.contains(#"b5 in "claude:CLAUDE.md" and 2 more."#), reason)
        XCTAssertEqual(env.bytes(env.claudeMD), edited)
    }
}
