import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #1226: the commit path. (1) The block compare is on the file's bytes: an invalid byte where the
/// record has U+FFFD decodes to the same String, and is still an edit. (2) The replaced file carries
/// the mode the file has when it is replaced, on apply, Remove and Repair alike, for a chmod while the
/// sheet is up (INFO-5, R1025-2), after the temp write and right before the rename (R1025-4).
/// Every file is under the row's tempDir(); every chmod is undone in a defer. Byte fixtures are arrays.
final class ManagedConfigCommitTests: XCTestCase {
    private static let replacement: [UInt8] = [0xEF, 0xBF, 0xBD] // U+FFFD as UTF-8
    private static let removeNote = "The rules block was edited by hand: Remove deletes those edits too. A copy of the file as it is now goes to the backups, which keep the copies from Prosper's last 5 writes to this file."

    private func replacing(_ bytes: [UInt8], _ old: [UInt8], with new: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [], i = 0
        while i < bytes.count {
            if bytes[i...].starts(with: old) { out += new; i += old.count } else { out.append(bytes[i]); i += 1 }
        }
        return out
    }

    // MARK: the compare (INFO-2)

    /// The literal example of the report: the record's EF BF BD turned into FF on disk.
    func testAnInvalidByteWhereTheRecordHasUFFFDIsAnEdit() async throws {
        let piece = MCPieces.block(text: "Ask caf\u{FFFD} first.")
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let applied = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(applied.status, .done)
        let written = try XCTUnwrap(env.bytes(env.claudeMD))
        let edited = replacing(written, Self.replacement, with: [0xFF])
        XCTAssertEqual(edited.count, written.count - 2, "the premise: one EF BF BD became one FF")
        XCTAssertEqual(String(decoding: edited, as: UTF8.self), String(decoding: written, as: UTF8.self), "the premise: a lossy decode takes them for one")
        try Data(edited).write(to: env.claudeMD)

        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.drifted])
        let again = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(again.refusals.map(\.reason), [.drifted], "not a noop over other bytes")
        XCTAssertEqual(env.bytes(env.claudeMD), edited)
        let removed = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(removed.status, .done)
        XCTAssertEqual(env.consent.seen.last?.files.first?.notes, [Self.removeNote], "the sheet names the edit")
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")

        // lost state: the edited block is never adopted
        let lost = makeMCEnv(label: "lost")
        try Data(edited).write(to: lost.claudeMD)
        XCTAssertTrue(lost.mc.status(owner: lost.owner, declared: [piece]).map(\.state) == [.drifted])
    }

    /// A valid-text edit is drift as before; an unchanged block in a file with invalid bytes around it is not.
    func testValidTextEditsDriftAndInvalidBytesOutsideAnUnchangedBlockDoNot() async throws {
        let text = makeMCEnv(label: "text")
        try text.write("# mine\n", text.claudeMD)
        _ = await text.mc.apply([MCPieces.block()], owner: text.owner)
        XCTAssertEqual(text.mc.status(owner: text.owner).map(\.state), [.applied])
        try text.write(try XCTUnwrap(text.read(text.claudeMD)).replacingOccurrences(of: "kit rules", with: "Kit rules"), text.claudeMD)
        XCTAssertEqual(text.mc.status(owner: text.owner).map(\.state), [.drifted])

        let env = makeMCEnv(label: "around")
        try Data(Array("# mine ".utf8) + [0xFF, 0x0A]).write(to: env.claudeMD)
        let piece = MCPieces.block()
        let first = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(first.status, .done)
        let around = try XCTUnwrap(env.bytes(env.claudeMD)) + [0xFE, 0x0A]
        try Data(around).write(to: env.claudeMD)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied])
        let again = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(again.status, .nothingToDo)
        XCTAssertEqual(env.consent.seen.count, 1, "no second sheet")
        let removed = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(removed.status, .done)
        XCTAssertEqual(env.consent.seen.last?.files.first?.notes, [], "nothing edited: no drift note")
        XCTAssertEqual(env.bytes(env.claudeMD), Array("# mine ".utf8) + [0xFF, 0x0A, 0xFE, 0x0A])
    }

    // MARK: the mode (INFO-5, R1025-2, R1025-4)

    enum Op: String { case apply, remove, repair }
    enum Point: String, CaseIterable { case none, sheet, afterTempWrite, beforeRename }

    /// Runs `op` on a CLAUDE.md at 0644 (0600 for `.none`); a chmod to 0600 lands at `point`.
    /// Returns the result and the file's mode and bytes after it.
    private func run(_ op: Op, chmodAt point: Point) async throws -> (ManagedConfigResult, Int, [UInt8]?) {
        let env = makeMCEnv(label: "\(op)-\(point)")
        let url = env.claudeMD
        let piece = MCPieces.block()
        try env.write("# mine\n", url)
        if op != .apply {
            let first = await env.mc.apply([piece], owner: env.owner)
            XCTAssertEqual(first.status, .done)
        }
        if op == .repair {
            try env.write(try XCTUnwrap(env.read(url)).replacingOccurrences(of: "kit rules", with: "rules, edited"), url)
        }
        XCTAssertEqual(chmod(url.path, point == .none ? 0o600 : 0o644), 0)
        defer { _ = chmod(url.path, 0o644) }
        let name = url.lastPathComponent
        let narrow: @Sendable () -> Void = { _ = chmod(url.path, 0o600) }
        let consent = MCScriptedConsent { call, _ in
            if point == .sheet, call == 1 { narrow() }
            return true
        }
        if point == .afterTempWrite { env.writer.interleave { t, _ in if t.lastPathComponent == name { narrow() } } }
        if point == .beforeRename { env.writer.beforeReplace { t in if t.lastPathComponent == name { narrow() } } }
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)
        let r: ManagedConfigResult
        switch op {
        case .apply: r = await mc.apply([piece], owner: env.owner)
        case .remove: r = await mc.remove(owner: env.owner)
        case .repair: r = await mc.repair(owner: env.owner)
        }
        XCTAssertEqual(consent.seen.count, 1, "\(op) \(point): a mode change re-asks nothing")
        return (r, env.mode(url), env.bytes(url))
    }

    private func assertModeKept(_ op: Op, expect: (Point, [UInt8]?) -> Void) async throws {
        for point in Point.allCases {
            let (r, mode, bytes) = try await run(op, chmodAt: point)
            XCTAssertEqual(r.status, .done, "\(op) \(point): \(r.message)")
            XCTAssertEqual(mode, 0o600, "\(op) \(point): the file keeps the user's 0600, never 0644")
            expect(point, bytes)
        }
    }

    func testApplyKeepsTheUsersModeFromTheSheetToTheRename() async throws {
        try await assertModeKept(.apply) { point, bytes in
            XCTAssertTrue(bytes.map { String(decoding: $0, as: UTF8.self).contains("Follow the kit rules.") } ?? false, "\(point)")
        }
    }

    func testRemoveKeepsTheUsersModeFromTheSheetToTheRename() async throws {
        try await assertModeKept(.remove) { point, bytes in XCTAssertEqual(bytes, Array("# mine\n".utf8), "\(point)") }
    }

    func testRepairKeepsTheUsersModeFromTheSheetToTheRename() async throws {
        try await assertModeKept(.repair) { point, bytes in
            let text = bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
            XCTAssertTrue(text.contains("Follow the kit rules.") && !text.contains("rules, edited"), "\(point)")
        }
    }

    /// The new failure point: the replacement cannot take the user's new mode (its temp is gone), so
    /// nothing is replaced: the file keeps its bytes and the user's mode, no temp and no backup is left.
    func testAFailedModeCopyLeavesTheFileAsItWas() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD, dir = env.claude
        let original = Array("# mine\n".utf8)
        try Data(original).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o644), 0)
        defer { _ = chmod(url.path, 0o644) }
        let prefix = "." + url.lastPathComponent + ".prosper-"
        env.writer.interleave { t, _ in
            guard t.lastPathComponent == url.lastPathComponent else { return }
            _ = chmod(url.path, 0o600)
            for name in ManagedConfig.entries(of: dir) ?? [] where name.hasPrefix(prefix) {
                _ = unlink(dir.appendingPathComponent(name).path)
            }
        }
        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.message.contains("chmod"), r.message)
        XCTAssertEqual(env.bytes(url), original)
        XCTAssertEqual(env.mode(url), 0o600)
        XCTAssertEqual((ManagedConfig.entries(of: dir) ?? []).filter { $0.hasPrefix(prefix) }, [])
        XCTAssertEqual(env.files(under: env.backups).filter { $0.hasSuffix(".orig") }, [], "the backup of a write that never landed goes")
    }

    // MARK: #1231 (R1226-1, N1226-a). The hooks are @Sendable and run inside ManagedConfig.apply's task.

    /// A chmod of the old file in the last instant before the rename AND one of the new file after it:
    /// the later one, on the file the user now has, stays (the late copy no longer overwrites it).
    func testAChmodAfterTheRenameIsKept() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD, name = url.lastPathComponent
        try env.write("# mine\n", url)
        XCTAssertEqual(chmod(url.path, 0o644), 0)
        defer { _ = chmod(url.path, 0o644) }
        env.writer.beforeReplace { t in if t.lastPathComponent == name { _ = chmod(url.path, 0o600) } }
        env.writer.afterReplace { t in if t.lastPathComponent == name { _ = chmod(url.path, 0o640) } }
        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(env.mode(url), 0o640, "the chmod made after the rename stays")
        XCTAssertTrue(env.read(url)?.contains("Follow the kit rules.") ?? false)
    }

    /// Prosper's temp replaced by a link (inside the row's tempDir) before the commit opens it: the open
    /// refuses the link, nothing is renamed over the user's file, temp and backup go, the decoy is untouched.
    func testATempSwappedForALinkFailsClosed() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD, dir = env.claude
        let original = Array("# mine\n".utf8)
        try Data(original).write(to: url)
        let decoy = env.root.appendingPathComponent("decoy.md")
        try env.write("# decoy\n", decoy)
        let prefix = "." + url.lastPathComponent + ".prosper-"
        env.writer.interleave { t, _ in
            guard t.lastPathComponent == url.lastPathComponent else { return }
            for name in ManagedConfig.entries(of: dir) ?? [] where name.hasPrefix(prefix) {
                let temp = dir.appendingPathComponent(name).path
                _ = unlink(temp)
                _ = symlink(decoy.path, temp)
            }
        }
        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.message.contains("open temp failed"), r.message)
        XCTAssertEqual(env.bytes(url), original)
        XCTAssertTrue((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil, "still a regular file")
        XCTAssertEqual(env.read(decoy), "# decoy\n")
        XCTAssertEqual((ManagedConfig.entries(of: dir) ?? []).filter { $0.hasPrefix(prefix) }, [], "the link is gone")
        XCTAssertEqual(env.files(under: env.backups).filter { $0.hasSuffix(".orig") }, [])
    }

    /// #947 (R1231-1): a link swapped in at the resolved path after the commit's shape check, to a file with the
    /// same bytes and a narrower mode: the old file's open (O_NOFOLLOW) refuses it and the commit fails closed.
    /// The link stays a link, its target (inside the row's tempDir) keeps its bytes and mode, no temp or backup
    /// is left. Parent: the link was replaced by a regular file with the link target's mode (.done).
    func testALinkSwappedInAtTheResolvedPathFailsClosed() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD, dir = env.claude
        let original = Array("# mine\n".utf8)
        try Data(original).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o644), 0)
        let moved = env.root.appendingPathComponent("moved.md"), decoy = env.root.appendingPathComponent("decoy.md")
        try Data(original).write(to: decoy)
        XCTAssertEqual(chmod(decoy.path, 0o600), 0)
        defer { _ = chmod(decoy.path, 0o644); _ = chmod(url.path, 0o644) }
        env.writer.interleave { t, _ in
            guard t.lastPathComponent == url.lastPathComponent else { return }
            _ = rename(url.path, moved.path)
            _ = symlink(decoy.path, url.path)
        }
        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .failed, r.message)
        XCTAssertTrue(r.message.contains("open target failed"), r.message)
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: url.path), decoy.path, "still the link")
        XCTAssertEqual(env.bytes(decoy), original)
        XCTAssertEqual(env.mode(decoy), 0o600)
        XCTAssertEqual(env.bytes(moved), original)
        XCTAssertEqual(env.mode(moved), 0o644)
        let prefix = "." + url.lastPathComponent + ".prosper-"
        XCTAssertEqual((ManagedConfig.entries(of: dir) ?? []).filter { $0.hasPrefix(prefix) }, [], "no temp left")
        XCTAssertEqual(env.files(under: env.backups).filter { $0.hasSuffix(".orig") }, [], "no backup left")
    }
}
