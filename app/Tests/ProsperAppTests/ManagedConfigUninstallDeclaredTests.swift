import Foundation
import XCTest
@testable import ProsperApp

/// #1232 round 2: the uninstall adopts a byte-equal declared block with no record (F1232-1), a disabled extension's
/// declaration is dropped and never stops its uninstall (F1232-2), the kept declaration is capped and the stop names at
/// most five blocks (R1232-2). Every file is the row's own, inside its tempDir() (a made-up home and fake kit ids); the
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

    @MainActor
    func testUninstallStillStopsOnAnEditedUnrecordedDeclaredBlockAndNamesIt() async throws {
        let env = makeMCEnv()
        let saved = ManagedConfigRefresh.current
        defer { ManagedConfigRefresh.current = saved }
        let refresh = ownRefresh(env)
        let (registry, dir) = try installedRegistry(env)
        let o = try XCTUnwrap(registry.record(id: Self.extID)).loaded.managedConfigOwner
        let edited = try await Self.lostAndEdited(env, o, [MCPieces.block()])
        refresh.declared[Self.extID] = [MCPieces.block()]

        do {
            try await registry.uninstall(id: Self.extID)
            XCTFail("uninstalled with an edited unrecorded block left in the file")
        } catch ExtensionError.managedConfigKept(let id, let reason) {
            XCTAssertEqual(id, Self.extID)
            XCTAssertTrue(reason.contains(#"rules in "claude:CLAUDE.md""#), reason)
            XCTAssertTrue(reason.contains("turn the extension off, then uninstall it"), reason)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "the folder stays")
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "the person's bytes are unchanged")
        XCTAssertEqual(env.consent.seen.map(\.action), [.apply], "no sheet from the uninstall")
        XCTAssertEqual(env.mc.ownerIDs(), [], "an edited block is not adopted")
        XCTAssertEqual(refresh.declared[Self.extID], [MCPieces.block()], "a stopped uninstall keeps the declaration")
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

    func testStopWithSevenBlocksNamesFiveAndSaysTwoMore() async throws {
        let env = makeMCEnv()
        let o = ManagedConfigOwner(id: Self.extID, version: "1.0.0", kitSlug: "kit-a", extensionDir: env.ext)
        let pieces = (1...7).map { MCPieces.block("b\($0)", text: "Rule \($0).") }
        let edited = try await Self.lostAndEdited(env, o, pieces)
        let stop = await ExtensionRegistry.removeManagedPieces(owner: o, declared: pieces, provider: ManagedConfigProvider(env.mc))
        let reason = try XCTUnwrap(stop)
        for n in 1...5 { XCTAssertTrue(reason.contains("b\(n) in "), reason) }
        XCTAssertFalse(reason.contains("b6 in ") || reason.contains("b7 in "), reason)
        XCTAssertTrue(reason.contains(#"b5 in "claude:CLAUDE.md" and 2 more."#), reason)
        XCTAssertEqual(env.bytes(env.claudeMD), edited)
    }
}
