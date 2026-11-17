import Foundation
import XCTest
@testable import ProsperApp

/// Answers yes and, on the first ask only, runs `act` (a change made while the sheet is up). Records every sheet.
final class MCActingConsent: ManagedConfigConsent, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [ManagedConfigChangeSet] = []
    private let act: @Sendable () -> Void

    init(act: @escaping @Sendable () -> Void) { self.act = act }

    func confirm(_ changes: ManagedConfigChangeSet) async -> Bool {
        let first = lock.withLock { _seen.append(changes); return _seen.count == 1 }
        if first { act() }
        return true
    }

    var seen: [ManagedConfigChangeSet] { lock.withLock { _seen } }
}

/// #1244 (947 item 3b): an uninstall over a block with broken prosper markers leaves the file byte for byte and drops
/// Prosper's record of the block, after a sheet that says so. Every file is the row's own, under its tempDir().
@MainActor
final class ManagedConfigForgetTests: XCTestCase {
    static let endMarker = "<!-- <<< prosper:kit-a:rules <<< -->"
    static let forgetNote = "The rules block's prosper marker lines are broken (line(s) 3), so Prosper cannot tell where it ends: "
        + "its text stays in this file exactly as it is, and Prosper forgets the block. Delete that text yourself if you no longer want it."

    /// A recorded block in the row's CLAUDE.md whose end marker line was deleted by hand. Returns the broken bytes.
    private func brokenBlock(_ env: MCEnv) async throws -> [UInt8] {
        try env.write("# mine\n", env.claudeMD)
        let applied = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(applied.status, .done)
        let text = try XCTUnwrap(env.read(env.claudeMD))
        XCTAssertTrue(text.contains(Self.endMarker))
        try env.write(text.replacingOccurrences(of: Self.endMarker, with: ""), env.claudeMD)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.corrupt])
        return try XCTUnwrap(env.bytes(env.claudeMD))
    }

    func testUninstallOverBrokenMarkersAsksOnceThenLeavesTheBytesAndDropsTheRecord() async throws {
        let env = makeMCEnv()
        let broken = try await brokenBlock(env)
        let asked = env.consent.seen.count
        let backups = env.files(under: env.backups)

        let r = await env.mc.uninstall(owner: env.owner)

        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(r.pieces, [.init(id: "rules", action: .forget)])
        XCTAssertEqual(env.consent.seen.count, asked + 1, "the forget is asked once, before it happens")
        let sheet = try XCTUnwrap(env.consent.seen.last)
        XCTAssertEqual(sheet.action, .remove)
        XCTAssertEqual(sheet.files.count, 1)
        let file = try XCTUnwrap(sheet.files.first)
        XCTAssertEqual(file.path, env.claudeMD.path)
        XCTAssertTrue(file.leftAsItIs)
        XCTAssertTrue(file.lines.isEmpty, "no line is removed")
        XCTAssertEqual(file.notes, [Self.forgetNote])
        let shown = ManagedConfigConsentModel(changes: sheet) { _ in }.renderedStrings
        XCTAssertTrue(shown.contains(ManagedConfigConsentModel.leftAsItIsStatus), "\(shown)")
        XCTAssertTrue(shown.contains(Self.forgetNote), "\(shown)")
        XCTAssertFalse(shown.contains { $0.hasPrefix("Backup: ") }, "a forget makes no backup, so the sheet names none")

        XCTAssertEqual(env.bytes(env.claudeMD), broken, "the file is byte for byte as it was")
        XCTAssertEqual(env.files(under: env.backups), backups, "no copy written")
        XCTAssertTrue(env.mc.status(owner: env.owner).isEmpty, "Prosper's record of the block is gone")
        XCTAssertFalse(env.mc.ownerIDs().contains(env.owner.id))
        XCTAssertFalse(env.mc.recordedPaths().contains(env.claudeMD.path))
    }

    func testDeclinedForgetKeepsTheRecordAndTheBytes() async throws {
        let env = makeMCEnv()
        let broken = try await brokenBlock(env)
        let no = MCRecordingConsent(false) // the apply above said yes; the uninstall's sheet is declined
        let mc = ManagedConfig(roots: env.mc.roots, consent: no, writer: env.writer)

        let r = await mc.uninstall(owner: env.owner)

        XCTAssertEqual(r.status, .denied)
        XCTAssertEqual(no.seen.count, 1)
        XCTAssertTrue(no.seen.last?.files.first?.leftAsItIs ?? false)
        XCTAssertEqual(env.bytes(env.claudeMD), broken)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.corrupt], "the record stays")
    }

    /// Remove (host.config.remove, a kit's own) is unchanged: refused, now with the typed reason, nothing asked.
    func testPlainRemoveStillRefusesBrokenMarkersByTheTypedReason() async throws {
        let env = makeMCEnv()
        let broken = try await brokenBlock(env)
        let asked = env.consent.seen.count

        let r = await env.mc.remove(owner: env.owner)
        let a = await env.mc.apply([MCPieces.block()], owner: env.owner)

        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.reason), [.brokenMarkers(lines: [3])])
        XCTAssertEqual(a.refusals.map(\.reason), [.brokenMarkers(lines: [3])])
        XCTAssertEqual(r.message, "rules (claude:CLAUDE.md): corrupt: broken prosper markers at line(s) 3")
        XCTAssertEqual(env.consent.seen.count, asked)
        XCTAssertEqual(env.bytes(env.claudeMD), broken)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.corrupt])
    }

    func testUninstallOfAWellFormedBlockRemovesItAsBefore() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)

        let r = await env.mc.uninstall(owner: env.owner)

        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(r.pieces, [.init(id: "rules", action: .remove)])
        let file = try XCTUnwrap(env.consent.seen.last?.files.first)
        XCTAssertFalse(file.leftAsItIs)
        XCTAssertFalse(file.lines.isEmpty)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertTrue(env.mc.status(owner: env.owner).isEmpty)
    }

    /// The uninstall's own path (ExtensionRegistry.removeManagedPieces): broken markers are forgotten after one sheet, so the
    /// uninstall goes on; a well-formed block is still removed by the same call.
    func testUninstallPathForgetsBrokenMarkersAndStillRemovesAWellFormedBlock() async throws {
        let env = makeMCEnv()
        let broken = try await brokenBlock(env)
        let asked = env.consent.seen.count

        let stop = await ExtensionRegistry.removeManagedPieces(owner: env.owner, provider: ManagedConfigProvider(env.mc))

        XCTAssertTrue(stop == nil, stop ?? "")
        XCTAssertEqual(env.consent.seen.count, asked + 1, "the forget sheet is asked once")
        XCTAssertTrue(env.consent.seen.last?.files.first?.leftAsItIs ?? false)
        XCTAssertEqual(env.consent.seen.last?.files.first?.notes ?? [], [Self.forgetNote])
        XCTAssertEqual(env.bytes(env.claudeMD), broken, "the file is byte for byte as it was")
        XCTAssertTrue(env.mc.status(owner: env.owner).isEmpty, "the record is gone")

        let good = makeMCEnv()
        try good.write("# mine\n", good.claudeMD)
        _ = await good.mc.apply([MCPieces.block()], owner: good.owner)
        let removed = await ExtensionRegistry.removeManagedPieces(owner: good.owner, provider: ManagedConfigProvider(good.mc))
        XCTAssertTrue(removed == nil, removed ?? "")
        XCTAssertFalse(good.consent.seen.last?.files.first?.leftAsItIs ?? true)
        XCTAssertEqual(good.read(good.claudeMD), "# mine\n")
        XCTAssertTrue(good.mc.status(owner: good.owner).isEmpty)
    }

    /// The markers mended while the forget sheet is up: the commit sees other bytes, plans again, and the real Remove
    /// is asked for anew; the block goes, never an untouched well-formed block with its record dropped.
    func testMarkersMendedUnderTheForgetSheetAskAgainForTheRealRemove() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        let good = try XCTUnwrap(env.read(env.claudeMD))
        try env.write(good.replacingOccurrences(of: Self.endMarker, with: ""), env.claudeMD)
        let target = env.claudeMD
        let consent = MCActingConsent { try? Data(good.utf8).write(to: target) }
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)

        let r = await mc.uninstall(owner: env.owner)

        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(consent.seen.count, 2, "the Remove is a new sheet")
        XCTAssertTrue(consent.seen.first?.files.first?.leftAsItIs ?? false)
        XCTAssertFalse(consent.seen.last?.files.first?.leftAsItIs ?? true)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertTrue(mc.status(owner: env.owner).isEmpty)
    }
}
