import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #1025: a UTF-8 byte order mark at byte 0 of a managed file stays there through insert, replace and
/// remove of a top block, a block behind it is found, and a seed is copied byte for byte. The BOM is a
/// literal byte array and every assertion compares bytes: String(data:encoding:) and hasPrefix can hide
/// it. The other fixture text is ASCII (and the marker's U+00B7), which no String path changes.
/// Also #1025 rider (c): a chmod while the sheet is up survives the write.
final class ManagedConfigBOMTests: XCTestCase {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let mine = Array("# mine\n".utf8)
    private static let lf: [UInt8] = [0x0A]

    /// The kit-a "rules" block as written, typed out so the test pins the bytes.
    private static func block(_ version: String = "1.0.0") -> [UInt8] {
        Array(("<!-- >>> prosper:kit-a:rules v\(version) · managed by Prosper, edits show as drift >>> -->\n"
            + "Follow the kit rules.\n<!-- <<< prosper:kit-a:rules <<< -->").utf8)
    }

    func testTopBlockBehindABOMIsFoundKeepsTheBOMAtByteZeroAndRemoveRestoresTheBytes() async throws {
        let env = makeMCEnv()
        let original = Self.bom + Self.mine
        try Data(original).write(to: env.claudeMD)
        let piece = MCPieces.block(position: .top)

        let applied = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(applied.status, .done)
        XCTAssertEqual(env.bytes(env.claudeMD), Self.bom + Self.block() + Self.lf + Self.lf + Self.mine, "the BOM at byte 0, the block after it")
        let onDisk = try XCTUnwrap(env.bytes(env.claudeMD))
        XCTAssertEqual(ManagedTextBlock.find(owner: "kit-a", piece: "rules", in: onDisk), .present(begin: 0, end: 2))
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied])

        let again = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(again.status, .nothingToDo)
        XCTAssertEqual(again.pieces.map(\.action), [.noop])
        XCTAssertEqual(env.consent.seen.count, 1, "a noop asks nothing")

        // replace: a new version of the same piece rewrites the block in place, BOM kept
        let v2 = ManagedConfigOwner(id: "kit-a", version: "2.0.0", kitSlug: "kit-a", extensionDir: env.ext)
        let updated = await env.mc.apply([piece], owner: v2)
        XCTAssertEqual(updated.pieces.map(\.action), [.update])
        XCTAssertEqual(env.bytes(env.claudeMD), Self.bom + Self.block("2.0.0") + Self.lf + Self.lf + Self.mine)

        let removed = await env.mc.remove(owner: v2)
        XCTAssertEqual(removed.status, .done)
        XCTAssertEqual(removed.pieces.map(\.action), [.remove])
        XCTAssertEqual(env.bytes(env.claudeMD), original, "Remove restores the original bytes, BOM included")
    }

    /// A file that is only a BOM: the block goes right after it (either position), and Remove leaves the
    /// BOM alone, never an empty file and never a deletion (the file existed). The parent did the same
    /// for an empty file (an empty file back), and for a BOM-only file put the block at the bottom
    /// behind two newlines.
    func testBOMOnlyFileGetsTheBlockAfterTheBOMAndRemoveLeavesTheBOM() async throws {
        for position in [ManagedConfigPiece.Position.top, .bottom] {
            let env = makeMCEnv()
            try Data(Self.bom).write(to: env.claudeMD)
            _ = await env.mc.apply([MCPieces.block(position: position)], owner: env.owner)
            XCTAssertEqual(env.bytes(env.claudeMD), Self.bom + Self.block() + Self.lf, "\(position)")
            XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied], "\(position)")
            let removed = await env.mc.remove(owner: env.owner)
            XCTAssertEqual(removed.pieces.map(\.action), [.remove], "\(position)")
            XCTAssertEqual(env.bytes(env.claudeMD), Self.bom, "\(position): the BOM alone")
        }
    }

    /// Unchanged from the parent: a bottom block in a BOM file goes at the end, and Remove restores the bytes.
    func testBottomBlockInABOMFileIsUnchanged() async throws {
        let env = makeMCEnv()
        let original = Self.bom + Self.mine
        try Data(original).write(to: env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(env.bytes(env.claudeMD), original + Self.lf + Self.block() + Self.lf)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied])
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.bytes(env.claudeMD), original)
    }

    /// A BOM that is not at byte 0 is ordinary text: a begin marker behind it is not a marker (as before).
    func testABOMInsideTheFileIsOrdinaryText() {
        let block = Self.block()
        let inside = Self.mine + Self.bom + block + Self.lf
        XCTAssertEqual(ManagedTextBlock.find(owner: "kit-a", piece: "rules", in: inside), .corrupt(lines: [4]))
        XCTAssertEqual(ManagedTextBlock.find(owner: "kit-a", piece: "rules", in: Self.bom + block + Self.lf), .present(begin: 0, end: 2))
    }

    func testSeedSourceWithABOMIsCopiedByteForByte() async throws {
        let env = makeMCEnv()
        let source = Self.bom + Self.mine
        try Data(source).write(to: env.ext.appendingPathComponent("bom.md"))
        let r = await env.mc.apply([MCPieces.seed(source: "ext:bom.md")], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        let local = env.config.appendingPathComponent("kit-a/local.md")
        XCTAssertEqual(env.bytes(local), source, "the seed is its source, BOM included")
        let removed = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(removed.pieces.map(\.action), [.remove], "the record holds the same bytes: an unedited seed goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))

        // still refused: bytes that are not UTF-8
        try Data([0xFF, 0xFE, 0x41, 0x0A]).write(to: env.ext.appendingPathComponent("bad.md"))
        let bad = await env.mc.apply([MCPieces.seed(source: "ext:bad.md")], owner: env.owner)
        XCTAssertEqual(bad.refusals.map(\.reason), [.invalidPiece("seed source is missing or not UTF-8 text")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
    }

    /// #1025 rider (c): a chmod while the sheet is up changes no byte, so nothing re-plans; the write
    /// keeps the mode the file has at commit. The parent wrote the plan-time 0644 back.
    func testAChmodWhileTheSheetIsUpIsKept() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD
        try Data(Self.mine).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o644), 0)
        let consent = MCScriptedConsent { call, _ in
            if call == 1 { _ = chmod(url.path, 0o600) }
            return true
        }
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)
        let r = await mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(consent.seen.count, 1, "no byte changed: one sheet")
        XCTAssertEqual(env.bytes(url), Self.mine + Self.lf + Self.block() + Self.lf)
        XCTAssertEqual(env.mode(url), 0o600, "the user's chmod stays")
    }
}
