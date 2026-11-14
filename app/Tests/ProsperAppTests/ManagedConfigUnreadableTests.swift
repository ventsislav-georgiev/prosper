import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #1240 (QA F1235-1): an existing file that cannot be read is never planned as a new file, never
/// replaced and never replaced without a backup. The unreadable state is a mode only (0200), on files
/// the row made in its own tempDir(); every chmod is undone in a defer before the tempDir goes.
/// root reads a 0200 file, so every row skips when the suite runs as root.
final class ManagedConfigUnreadableTests: XCTestCase {
    private static let mine: [UInt8] = Array("# mine, known bytes\n".utf8)
    private static let sentence = "unreadable: the file exists but cannot be read"

    private func notRoot() throws { try XCTSkipIf(geteuid() == 0, "root reads a mode-0200 file: the unreadable state cannot be made") }

    private func writeOnly(_ bytes: [UInt8], _ url: URL, line: UInt = #line) {
        XCTAssertNoThrow(try Data(bytes).write(to: url), line: line)
        XCTAssertEqual(chmod(url.path, 0o200), 0, line: line)
    }

    private func stateFile(_ env: MCEnv) -> URL { env.state.appendingPathComponent("state.json") }

    /// Restores the mode, then the bytes are the row's own and nothing else was left beside them.
    private func assertUntouched(_ env: MCEnv, _ url: URL, _ bytes: [UInt8] = mine, line: UInt = #line) {
        XCTAssertEqual(chmod(url.path, 0o600), 0, line: line)
        XCTAssertEqual(env.bytes(url), bytes, "the person's bytes are unchanged", line: line)
        XCTAssertEqual(env.files(under: env.backups), [], "no backup was made", line: line)
        XCTAssertEqual(env.files(under: url.deletingLastPathComponent()).filter { $0.contains(".prosper-") }, [], "no temp file is left", line: line)
    }

    // MARK: at plan

    func testAWriteOnlyFileIsRefusedAtPlanNeverANewFile() async throws {
        try notRoot()
        let env = makeMCEnv()
        let url = env.claudeMD
        defer { _ = chmod(url.path, 0o600) }
        writeOnly(Self.mine, url)
        XCTAssertTrue(FileManager.default.contents(atPath: url.path) == nil, "the premise: contents(atPath:) answers nil")
        XCTAssertEqual(access(url.path, W_OK), 0, "the premise: resolve accepts it")

        let plan = env.mc.plan([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(plan.refusals.map(\.reason), [.unreadable])
        XCTAssertEqual(plan.refusals.map(\.description), ["rules (claude:CLAUDE.md): " + Self.sentence])
        XCTAssertFalse(plan.changes.files.contains { $0.newFile }, "no line calls it a new file")
        XCTAssertEqual(plan.files.count, 0, "nothing planned for it")
        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(env.consent.seen.count, 0, "refused before the sheet")
        XCTAssertEqual(env.writer.temps(url), 0)
        assertUntouched(env, url)
    }

    func testTheNewReasonsSentence() {
        XCTAssertEqual(ManagedConfigRefusalReason.unreadable.description, Self.sentence)
    }

    /// The existing rule: any refusal refuses the whole request before the sheet; no other file is written.
    func testTheOtherFilesOfTheRequestAreNotWritten() async throws {
        try notRoot()
        let env = makeMCEnv()
        let url = env.claudeMD
        defer { _ = chmod(url.path, 0o600) }
        writeOnly(Self.mine, url)
        let settings: [UInt8] = Array("{\n  \"theme\": \"dark\"\n}\n".utf8)
        try Data(settings).write(to: env.settings)

        let r = await env.mc.apply([MCPieces.hook(), MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.pieceID), ["rules"])
        XCTAssertEqual(r.refusals.map(\.reason), [.unreadable])
        XCTAssertEqual(env.bytes(env.settings), settings, "the readable file of the same request is not written")
        XCTAssertEqual(env.writer.temps(env.settings), 0)
        assertUntouched(env, url)
    }

    /// Remove and Repair plan through the same read: a file that became unreadable after the apply refuses.
    func testRemoveAndRepairOfAFileThatBecameUnreadableRefuse() async throws {
        try notRoot()
        let env = makeMCEnv()
        let url = env.claudeMD
        defer { _ = chmod(url.path, 0o600) }
        try Data(Self.mine).write(to: url)
        let applied = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(applied.status, .done)
        let written = try XCTUnwrap(env.bytes(url))
        let backups = env.files(under: env.backups)
        XCTAssertEqual(chmod(url.path, 0o200), 0)

        let removed = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(removed.refusals.map(\.reason), [.unreadable])
        let repaired = await env.mc.repair(owner: env.owner)
        XCTAssertEqual(repaired.refusals.map(\.reason), [.unreadable], "never a new file over it")
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.id), ["rules"], "the record stays")
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertEqual(env.bytes(url), written)
        XCTAssertEqual(env.files(under: env.backups), backups, "no new backup")
    }

    func testATrulyAbsentFileIsStillPlannedAsNewAndWritten() async throws {
        let env = makeMCEnv()
        let plan = env.mc.plan([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(plan.refusals.count, 0)
        XCTAssertEqual(plan.changes.files.map(\.newFile), [true])
        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .done)
        XCTAssertTrue(env.read(env.claudeMD)?.contains("prosper:kit-a:rules") == true)
    }

    /// contents(atPath:) answers empty data for an empty readable file, never nil: an existing file with a backup.
    func testAZeroByteReadableFileIsNotUnreadable() async throws {
        let env = makeMCEnv()
        try Data().write(to: env.claudeMD)
        let plan = env.mc.plan([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(plan.refusals.count, 0)
        XCTAssertEqual(plan.changes.files.map(\.newFile), [false])
        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.files(under: env.backups).filter { $0.hasSuffix(".orig") }.count, 1, "the empty original is backed up")
    }

    // MARK: at commit

    /// Planned against an absent path; the file appears, unreadable, before the commit.
    func testAFileThatAppearsUnreadableAfterThePlanIsNeverWritten() async throws {
        try notRoot()
        let env = makeMCEnv()
        let url = env.claudeMD
        defer { _ = chmod(url.path, 0o600) }
        let plan = env.mc.plan([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(plan.changes.files.map(\.newFile), [true], "the premise: planned as a new file")
        writeOnly(Self.mine, url)

        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .refused, "the commit answered changed, the replan refuses")
        XCTAssertEqual(r.refusals.map(\.reason), [.unreadable])
        XCTAssertEqual(env.writer.temps(url), 0, "the pre-check stops it before any temp write")
        assertUntouched(env, url)
    }

    /// Two files: the readable one is first in the plan. The pre-check runs before any write, so it is not written either.
    func testAFileThatAppearsUnreadableAfterThePlanStopsTheWholeCommit() async throws {
        try notRoot()
        let env = makeMCEnv()
        let url = env.claudeMD
        defer { _ = chmod(url.path, 0o600) }
        let settings: [UInt8] = Array("{\n  \"theme\": \"dark\"\n}\n".utf8)
        try Data(settings).write(to: env.settings)
        let plan = env.mc.plan([MCPieces.hook(), MCPieces.block()], owner: env.owner)
        XCTAssertEqual(plan.files.map { $0.url.lastPathComponent }, ["settings.json", "CLAUDE.md"], "the premise: the readable file first")
        writeOnly(Self.mine, url)

        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.pieces, [], "nothing landed")
        XCTAssertEqual(env.bytes(env.settings), settings)
        XCTAssertEqual(env.writer.temps(env.settings), 0)
        assertUntouched(env, url)
    }

    /// The file appears, unreadable, after the temp write and before the re-check right before the rename.
    func testAFileThatAppearsUnreadableBeforeTheRenameIsNeverReplaced() async throws {
        try notRoot()
        let env = makeMCEnv()
        let url = env.claudeMD
        defer { _ = chmod(url.path, 0o600) }
        let mine = Self.mine
        env.writer.interleave { target, n in
            guard target.lastPathComponent == "CLAUDE.md", n == 1 else { return }
            try? Data(mine).write(to: url)
            _ = chmod(url.path, 0o200)
        }
        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)
        env.writer.interleave(nil)
        XCTAssertEqual(env.writer.temps(url), 1, "the premise: the file appeared after the temp write")
        XCTAssertEqual(env.writer.replaces(url), 0, "never renamed over it")
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.reason), [.unreadable])
        assertUntouched(env, url)
    }

    /// Existing behaviour, pinned here (no row plans an absent file and then makes it appear): a readable
    /// file that appears after the plan is replanned as an existing file, with its backup.
    func testAFileThatAppearsReadableAfterThePlanIsReplannedWithABackup() async throws {
        let env = makeMCEnv()
        let plan = env.mc.plan([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(plan.changes.files.map(\.newFile), [true])
        try Data(Self.mine).write(to: env.claudeMD)

        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.consent.seen.last?.files.map(\.newFile), [false], "asked again, as an existing file")
        XCTAssertTrue(env.bytes(env.claudeMD)?.starts(with: Self.mine) == true, "the person's lines are kept")
        XCTAssertEqual(env.files(under: env.backups).filter { $0.hasSuffix(".orig") }.count, 1)
    }

    /// A planned delete (Prosper created the file) of a file that became unreadable after the plan removes nothing.
    func testAPlannedDeleteOfAFileThatBecameUnreadableRemovesNothing() async throws {
        try notRoot()
        let env = makeMCEnv()
        let url = env.claudeMD
        defer { _ = chmod(url.path, 0o600) }
        let applied = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(applied.status, .done)
        let written = try XCTUnwrap(env.bytes(url))
        let plan = env.mc.planRemove(owner: env.owner)
        XCTAssertEqual(plan.files.map(\.delete), [true], "the premise: a delete is planned")
        XCTAssertEqual(chmod(url.path, 0o200), 0)

        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.reason), [.unreadable])
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.id), ["rules"], "the record stays")
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertEqual(env.bytes(url), written, "the file is still there, unchanged")
    }

    // MARK: Prosper's own state file

    func testAnUnreadableStateFileIsRefusedAndNeverReplaced() async throws {
        try notRoot()
        let env = makeMCEnv()
        let state = stateFile(env)
        defer { _ = chmod(state.path, 0o600) }
        try FileManager.default.createDirectory(at: env.state, withIntermediateDirectories: true)
        writeOnly(Self.mine, state)
        let piece = MCPieces.block()
        try env.write(ManagedTextBlock.render(owner: env.owner.id, piece: piece.id, version: env.owner.version,
                                              body: piece.text ?? "", syntax: .markdown), env.claudeMD)
        let block = try XCTUnwrap(env.bytes(env.claudeMD))

        XCTAssertFalse(env.mc.stateIsReadable())
        _ = env.mc.status(owner: env.owner, declared: [piece]) // adoption would save a state over it
        let r = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.reason), [.stateUnreadable])
        XCTAssertEqual(env.bytes(env.claudeMD), block)
        XCTAssertEqual(chmod(state.path, 0o600), 0)
        XCTAssertEqual(env.bytes(state), Self.mine, "state.json is unchanged")
    }

    func testAStateFileThatAppearsUnreadableAfterThePlanIsNeverReplaced() async throws {
        try notRoot()
        let env = makeMCEnv()
        let state = stateFile(env)
        defer { _ = chmod(state.path, 0o600) }
        let plan = env.mc.plan([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(plan.refusals.count, 0)
        try FileManager.default.createDirectory(at: env.state, withIntermediateDirectories: true)
        writeOnly(Self.mine, state)

        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.reason), [.stateUnreadable])
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.claudeMD.path), "nothing written")
        XCTAssertEqual(chmod(state.path, 0o600), 0)
        XCTAssertEqual(env.bytes(state), Self.mine, "state.json is unchanged")
    }
}
