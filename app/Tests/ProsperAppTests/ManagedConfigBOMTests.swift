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

    // MARK: #1227 R1025-1: a JSON target that starts with a mark

    private static func count(_ needle: [UInt8], in hay: [UInt8]?) -> Int {
        guard let hay, hay.count >= needle.count else { return 0 }
        return (0...(hay.count - needle.count)).filter { hay[$0..<$0 + needle.count].elementsEqual(needle) }.count
    }

    /// Set, append and union into a settings.json behind a mark write the mark plus exactly the bytes the
    /// same file without the mark gets, show the same sheet lines (none carries U+FEFF), and Remove gives
    /// back the original bytes, mark included. The parent refused every case as corrupt ("invalid JSON").
    func testJSONBehindAMarkKeepsItAtByteZeroThroughSetAppendAndRemove() async throws {
        // the last input: the root indented on line 0, so the mark must not count as indentation
        let inputs = ["{\n  \"theme\": \"dark\"\n}\n", "{}",
                      "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"my-own\"}\n}\n", "  {\n  }\n"]
        let pieces = [MCPieces.statusLine(), MCPieces.hook(), MCPieces.allow(["Bash(ls:*)"])]
        for (i, input) in inputs.enumerated() {
            for (j, piece) in pieces.enumerated() {
                let label = "bom-json-\(i)-\(j)"
                let marked = makeMCEnv(label: label + "-mark"), plain = makeMCEnv(label: label + "-plain")
                try Data(Self.bom + Array(input.utf8)).write(to: marked.settings)
                try Data(input.utf8).write(to: plain.settings)
                let a = await marked.mc.apply([piece], owner: marked.owner)
                let b = await plain.mc.apply([piece], owner: plain.owner)
                XCTAssertEqual(a.status, .done, label)
                XCTAssertEqual(b.status, .done, label)
                let written = try XCTUnwrap(plain.bytes(plain.settings), label)
                XCTAssertEqual(marked.bytes(marked.settings), Self.bom + written, "\(label): the mark at byte 0, the rest as without it")
                XCTAssertEqual(Self.count(Self.bom, in: marked.bytes(marked.settings)), 1, "\(label): one mark, never two")
                XCTAssertEqual(marked.consent.seen.first?.files.map(\.lines), plain.consent.seen.first?.files.map(\.lines), label)
                XCTAssertFalse(marked.consent.seen.first?.files.contains { $0.lines.contains { $0.text.unicodeScalars.contains("\u{FEFF}") } } ?? true, label)
                XCTAssertEqual(marked.mc.status(owner: marked.owner).map(\.state), plain.mc.status(owner: plain.owner).map(\.state), label)

                let removed = await marked.mc.remove(owner: marked.owner)
                _ = await plain.mc.remove(owner: plain.owner)
                XCTAssertEqual(removed.status, .done, label)
                let back = try XCTUnwrap(plain.bytes(plain.settings), label)
                XCTAssertEqual(marked.bytes(marked.settings), Self.bom + back, "\(label): Remove: the mark and what the file without it gets")
                // an emptied `{\n  }` comes back as `{}` (OrderedJSON.removingChild shortcut), with or without the mark
                if i < 3 { XCTAssertEqual(back, Array(input.utf8), "\(label): Remove restores the bytes") }
            }
        }
    }

    /// Still refused as corrupt, nothing asked, the file byte for byte as it was: a file that is only a mark
    /// (or a mark and whitespace), a mark before invalid JSON (with the reason the same bytes without the mark
    /// get), a second mark, a mark not at byte 0, and the UTF-16 marks. An empty file WITHOUT a mark is
    /// blank and gets the skeleton (unchanged); a mark-only file is not treated as blank.
    func testJSONMarkOnlyInvalidOrNotAtByteZeroIsRefusedAndLeftAsItWas() async throws {
        let refused: [[UInt8]] = [
            Self.bom,
            Self.bom + [0x20, 0x0A],
            Self.bom + Self.bom + Array("{}".utf8),
            Array("{".utf8) + Self.bom + Array("\"a\": 1}".utf8),
            [0x20] + Self.bom + Array("{}".utf8),
            [0xFE, 0xFF, 0x00, 0x7B, 0x00, 0x7D],
            [0xFF, 0xFE, 0x7B, 0x00, 0x7D, 0x00],
        ]
        for (i, bytes) in refused.enumerated() {
            let env = makeMCEnv(label: "bom-refused-\(i)")
            try Data(bytes).write(to: env.settings)
            let r = await env.mc.apply([MCPieces.statusLine()], owner: env.owner)
            XCTAssertEqual(r.status, .refused, "case \(i)")
            XCTAssertTrue(r.refusals.count == 1 && r.refusals.allSatisfy { r in guard case .corrupt = r.reason else { return false }; return true }, "case \(i)")
            XCTAssertEqual(env.consent.seen.count, 0, "case \(i): no sheet")
            XCTAssertEqual(env.bytes(env.settings), bytes, "case \(i): left as it was")
        }
        for invalid in ["{\"a\": 1,}", "{\"a\": 1} x"] {
            let marked = makeMCEnv(label: "bom-invalid-mark"), plain = makeMCEnv(label: "bom-invalid-plain")
            try Data(Self.bom + Array(invalid.utf8)).write(to: marked.settings)
            try Data(invalid.utf8).write(to: plain.settings)
            let a = await marked.mc.apply([MCPieces.statusLine()], owner: marked.owner)
            let b = await plain.mc.apply([MCPieces.statusLine()], owner: plain.owner)
            XCTAssertEqual(a.refusals.map(\.reason), b.refusals.map(\.reason), invalid)
            XCTAssertEqual(a.status, .refused, invalid)
            XCTAssertEqual(marked.bytes(marked.settings), Self.bom + Array(invalid.utf8), invalid)
        }
    }

    /// A mark inside a string value is a legal character: accepted as before and kept where it is.
    func testAMarkInsideAJSONStringIsKeptWhereItIs() async throws {
        let env = makeMCEnv()
        let original = Array("{\n  \"note\": \"a".utf8) + Self.bom + Array("b\"\n}\n".utf8)
        try Data(original).write(to: env.settings)
        let r = await env.mc.apply([MCPieces.statusLine()], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        let written = try XCTUnwrap(env.bytes(env.settings))
        XCTAssertFalse(written.starts(with: Self.bom), "not moved to byte 0")
        XCTAssertTrue(written.starts(with: original.prefix(original.count - 3)), "the user's value as it was, mark inside")
        XCTAssertEqual(Self.count(Self.bom, in: written), 1)
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.bytes(env.settings), original)
    }

    // MARK: #1227 R1025-3: what the sheet shows

    /// A top insert into a text file that starts with a mark: these literal lines, no U+FEFF on any of them.
    func testTopInsertIntoAMarkedTextFileShowsTheseSheetLines() async throws {
        let env = makeMCEnv()
        try Data(Self.bom + Self.mine).write(to: env.claudeMD)
        let r = await env.mc.apply([MCPieces.block(position: .top)], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        typealias Line = ManagedConfigChangeSet.Line
        XCTAssertEqual(env.consent.seen.count, 1)
        XCTAssertEqual(env.consent.seen.first?.files.map(\.lines), [[
            Line(sign: .added, text: "<!-- >>> prosper:kit-a:rules v1.0.0 \u{00B7} managed by Prosper, edits show as drift >>> -->"),
            Line(sign: .added, text: "Follow the kit rules."),
            Line(sign: .added, text: "<!-- <<< prosper:kit-a:rules <<< -->"),
            Line(sign: .added, text: ""),
            Line(sign: .context, text: "# mine"),
        ]])
        XCTAssertEqual(env.consent.seen.first?.files.map(\.notes), [["Read by new Claude Code sessions and after /compact."]])
    }

    /// A change that only drops or adds the mark (the user's save while the sheet is up; Prosper itself never
    /// makes one) leaves the lines equal, so it shows as the second sheet with the changed-under-the-sheet
    /// note; the write then keeps what the user saved. The added mark on a text file is QATests a7 (c).
    func testAMarkDroppedOrAddedUnderTheSheetIsAskedAgainWithTheNote() async throws {
        let text = Array("# one\n# two\n# three\n# four\n".utf8)
        let json = Array("{\n  \"theme\": \"dark\"\n}\n".utf8)
        let cases: [(label: String, file: String, before: [UInt8], during: [UInt8], piece: ManagedConfigPiece)] = [
            ("text-drop", "CLAUDE.md", Self.bom + text, text, MCPieces.block()),
            ("json-drop", "settings.json", Self.bom + json, json, MCPieces.statusLine()),
            ("json-add", "settings.json", json, Self.bom + json, MCPieces.statusLine()),
        ]
        for c in cases {
            let env = makeMCEnv(label: "bom-sheet-" + c.label)
            let url = env.claude.appendingPathComponent(c.file)
            try Data(c.before).write(to: url)
            let during = c.during
            // runs inside ManagedConfig.apply's task (cooperative pool), on the first sheet only
            let consent = MCScriptedConsent { call, _ in
                if call == 1 { try? Data(during).write(to: url) }
                return true
            }
            let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)
            let r = await mc.apply([c.piece], owner: env.owner)
            XCTAssertEqual(r.status, .done, c.label)
            XCTAssertEqual(consent.seen.count, 2, "\(c.label): the mark differs in bytes, asked again")
            XCTAssertEqual(consent.seen.first?.files.map(\.lines), consent.seen.last?.files.map(\.lines), "\(c.label): the same lines")
            XCTAssertEqual(consent.seen.first?.files.first?.notes.contains(ManagedConfigPlan.changedUnderSheetNote), false, c.label)
            XCTAssertEqual(consent.seen.last?.files.first?.notes.last, ManagedConfigPlan.changedUnderSheetNote, c.label)
            let written = env.bytes(url)
            XCTAssertEqual(written?.starts(with: Self.bom), c.during.starts(with: Self.bom), "\(c.label): the user's mark or none")
            XCTAssertEqual(Self.count(Self.bom, in: written), c.during.starts(with: Self.bom) ? 1 : 0, c.label)
        }
    }

    /// #1231 (N1227-c): the refusal a mark-only settings.json gets, word for word (nothing written, no sheet).
    func testAMarkOnlySettingsFileIsRefusedWithThisReason() async throws {
        let env = makeMCEnv()
        try Data(Self.bom).write(to: env.settings)
        let r = await env.mc.apply([MCPieces.statusLine()], owner: env.owner)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.reason.description),
                       ["corrupt: claude:settings.json does not parse: unexpected end of file (line 1)"])
        XCTAssertEqual(env.consent.seen.count, 0)
        XCTAssertEqual(env.bytes(env.settings), Self.bom)
    }
}
