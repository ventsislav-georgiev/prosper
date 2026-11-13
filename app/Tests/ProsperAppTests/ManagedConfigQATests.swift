import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// A consent fake whose answer is scripted per call, and which can act on disk while the "sheet"
/// is up (A-INFO-6, D3).
final class MCScriptedConsent: ManagedConfigConsent, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [ManagedConfigChangeSet] = []
    private let script: @Sendable (_ call: Int, _ changes: ManagedConfigChangeSet) -> Bool

    init(_ script: @escaping @Sendable (_ call: Int, _ changes: ManagedConfigChangeSet) -> Bool) { self.script = script }

    func confirm(_ changes: ManagedConfigChangeSet) async -> Bool {
        let n = lock.withLock { () -> Int in _seen.append(changes); return _seen.count }
        return script(n, changes)
    }

    var seen: [ManagedConfigChangeSet] { lock.withLock { _seen } }
}

/// #870 P2 addendum: the QA #723 / #724 findings on the P1 core, each pinned by a test that is red
/// without its fix (mutants.txt names them).
final class ManagedConfigQATests: XCTestCase {
    private func stateFile(_ env: MCEnv) -> URL { env.state.appendingPathComponent("state.json") }

    private func backups(_ env: MCEnv, suffix: String) -> [String] { env.files(under: env.backups).filter { $0.hasSuffix(suffix) } }

    private func renderedBlock(_ env: MCEnv, _ piece: ManagedConfigPiece) -> String {
        ManagedTextBlock.render(owner: env.owner.id, piece: piece.id, version: env.owner.version, body: piece.text ?? "", syntax: .markdown)
    }

    // MARK: F1 (QA #723 FAIL): lost state adopts only the byte-equal block

    func testF1LostStateWithAnEditedBlockIsDriftNeverAdopted() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let piece = MCPieces.block()
        _ = await env.mc.apply([piece], owner: env.owner)
        try FileManager.default.removeItem(at: stateFile(env))
        let edited = try XCTUnwrap(env.read(env.claudeMD)).replacingOccurrences(of: "Follow the kit rules.", with: "Follow my rules instead.")
        try env.write(edited, env.claudeMD)
        let before = env.bytes(env.claudeMD)

        XCTAssertEqual(env.mc.status(owner: env.owner, declared: [piece]).map(\.state), [.drifted])
        XCTAssertEqual(env.mc.status(owner: env.owner).count, 0, "status recorded no adoption")
        let r = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.reason), [.drifted])
        XCTAssertEqual(env.bytes(env.claudeMD), before, "the user's edit is untouched")
        XCTAssertEqual(env.consent.seen.count, 1, "only the first apply asked")
    }

    func testF1LostStateWithTheIdenticalBlockStillAdopts() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let piece = MCPieces.block()
        _ = await env.mc.apply([piece], owner: env.owner)
        let applied = env.bytes(env.claudeMD)
        try FileManager.default.removeItem(at: stateFile(env))
        let r = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(r.pieces.map(\.action), [.adopt])
        try FileManager.default.removeItem(at: stateFile(env))
        XCTAssertEqual(env.mc.status(owner: env.owner, declared: [piece]).map(\.state), [.adopted])
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied])
        XCTAssertEqual(env.bytes(env.claudeMD), applied)
    }

    // MARK: D8: the orig backup goes only with a Remove that wrote the file

    func testD8OrigBackupGoesWhenTheLastRemoveWritesTheFile() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(backups(env, suffix: ".orig").count, 1)
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.pieces.map(\.action), [.remove])
        XCTAssertEqual(backups(env, suffix: ".orig"), [], "the remove wrote the file: its fresh pre copy replaces the orig")
        XCTAssertEqual(backups(env, suffix: ".pre").count, 1)
    }

    func testD8OrigBackupStaysWhenTheLastPieceLeavesByForget() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        try env.write("# mine, rewritten by hand\n", env.claudeMD) // markers gone
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.pieces.map(\.action), [.forget])
        XCTAssertEqual(backups(env, suffix: ".orig").count, 1, "nothing was written: the orig is the only copy of the first state")
        XCTAssertEqual(env.read(env.claudeMD), "# mine, rewritten by hand\n")
    }

    // MARK: A-INFO-6: the path shape is re-checked after consent

    func testA6SymlinkAppearingWhileTheSheetIsUpReplansAndAsksAgain() async throws {
        let root = tempDir()
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        for d in [claude, dotfiles] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let link = claude.appendingPathComponent("CLAUDE.md")
        let real = dotfiles.appendingPathComponent("CLAUDE.md")
        try Data("# mine\n".utf8).write(to: link)
        let consent = MCScriptedConsent { call, _ in
            if call == 1 { // the user moves the file into a dotfiles repo while the sheet is up
                try? FileManager.default.moveItem(at: link, to: real)
                try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            }
            return true
        }
        let mc = ManagedConfig(roots: ManagedConfigRoots(claude: claude, configHome: root.appendingPathComponent("config"),
                                                         stateDir: root.appendingPathComponent("state")), consent: consent)
        let r = await mc.apply([MCPieces.block()], owner: ManagedConfigOwner(id: "kit-a", version: "1.0.0"))
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(consent.seen.count, 2, "the change set names another file: asked again")
        XCTAssertEqual(consent.seen.last?.files.first?.path, real.resolvingSymlinksInPath().path)
        var st = stat()
        XCTAssertEqual(lstat(link.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK, "the link stays a link")
        XCTAssertTrue((try String(contentsOf: real, encoding: .utf8)).contains("Follow the kit rules."))
    }

    // MARK: A-INFO-8: a newer state version is unreadable

    func testA8StateFromANewerVersionIsNeverRewritten() async throws {
        let env = makeMCEnv()
        let piece = MCPieces.block()
        try env.write("# mine\n\n" + renderedBlock(env, piece) + "\n", env.claudeMD)
        try FileManager.default.createDirectory(at: env.state, withIntermediateDirectories: true)
        let newer = #"{"version": 2, "records": [], "files": [], "futureField": {"keep": true}}"#
        try env.write(newer, stateFile(env))
        XCTAssertFalse(env.mc.stateIsReadable())
        let r = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(r.refusals.map(\.reason), [.stateUnreadable])
        XCTAssertEqual(env.mc.status(owner: env.owner, declared: [piece]).map(\.state), [.notApplied], "no adoption")
        XCTAssertEqual(env.read(stateFile(env)), newer, "not re-saved: the unknown field survives")
        XCTAssertNil(env.read(env.settings))
        XCTAssertTrue(env.consent.seen.isEmpty)
    }

    // MARK: A-INFO-11: one owner, one `set` per slot

    func testA11TwoSetPiecesOnOneSlotAreRefusedByName() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        let r = await env.mc.apply([MCPieces.statusLine("s1"), MCPieces.statusLine("s2", command: "other")], owner: env.owner)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(r.refusals.map(\.reason), [.invalidPiece("pieces s1 and s2 both set statusLine")])
        XCTAssertEqual(env.read(env.settings), "{\n  \"theme\": \"dark\"\n}\n")
        _ = await env.mc.apply([MCPieces.statusLine("s1")], owner: env.owner)
        let second = await env.mc.apply([MCPieces.statusLine("s1"), MCPieces.statusLine("s2", command: "other")], owner: env.owner)
        XCTAssertEqual(second.status, .refused)
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertFalse(try XCTUnwrap(env.read(env.settings)).contains("statusLine"), "a full Remove leaves no statusLine")
        XCTAssertEqual(env.read(env.settings), "{\n  \"theme\": \"dark\"\n}\n")
    }

    // MARK: A-INFO-5 (SHOULD): case-only variants, the marker file

    func testA5CaseOnlyVariantsAndTheMarkerFileAreRefused() async throws {
        let env = makeMCEnv()
        let r = await env.mc.apply([MCPieces.block("a", target: "kitconfig:Notes.md"), MCPieces.block("b", target: "kitconfig:notes.md")],
                                   owner: env.owner)
        XCTAssertEqual(r.status, .refused)
        XCTAssertTrue(r.refusals.contains { $0.reason == .badPath("kitconfig:Notes.md and kitconfig:notes.md differ only by case") }, "\(r.refusals)")
        for target in ["kitconfig:.prosper-kit", "kitconfig:.Prosper-KIT", "kitconfig:sub/.PROSPER-kit"] {
            let m = await env.mc.apply([MCPieces.seed(target: target)], owner: env.owner)
            XCTAssertEqual(m.refusals.map(\.reason), [.badPath(".prosper-kit is Prosper's")], target)
        }
        XCTAssertTrue(env.consent.seen.isEmpty)
    }

    // MARK: B-INFO-7: blocks only in file types whose comments the markers use

    func testB7BlocksAreRefusedInFilesWithoutAKnownCommentSyntax() async throws {
        for ext in ["json", "lua", "html"] {
            let env = makeMCEnv(label: "b7-\(ext)")
            let r = await env.mc.apply([MCPieces.block(target: "kitconfig:conf.\(ext)")], owner: env.owner)
            XCTAssertEqual(r.status, .refused, ext)
            guard case .wrongKind(let why)? = r.refusals.first?.reason else { return XCTFail("\(ext): \(r.refusals)") }
            XCTAssertTrue(why.contains(".md"), why)
            XCTAssertFalse(FileManager.default.fileExists(atPath: env.config.appendingPathComponent("kit-a").path), ext)
        }
        for (ext, marker) in [("md", "<!-- >>> prosper:kit-a:rules"), ("sh", "# >>> prosper:kit-a:rules")] {
            let env = makeMCEnv(label: "b7-ok-\(ext)")
            let r = await env.mc.apply([MCPieces.block(target: "kitconfig:conf.\(ext)")], owner: env.owner)
            XCTAssertEqual(r.status, .done, ext)
            XCTAssertTrue(env.read(env.config.appendingPathComponent("kit-a/conf.\(ext)"))?.hasPrefix(marker) ?? false, ext)
        }
    }

    // MARK: B-INFO-8: an end marker before the begin marker

    func testB8EndMarkerBeforeBeginIsCorrupt() {
        let end = ManagedTextBlock.end(owner: "o", piece: "p", syntax: .markdown)
        let begin = ManagedTextBlock.begin(owner: "o", piece: "p", version: "1", syntax: .markdown)
        let bytes = Array((end + "\n" + begin + "\n").utf8)
        // asserted by value inside XCTAssertTrue: a removed guard turns this red, it never reaches text(of:)
        XCTAssertTrue(ManagedTextBlock.find(owner: "o", piece: "p", in: bytes) == .corrupt(lines: [1, 2]))
    }

    // MARK: B-INFO-1: \u takes exactly four hex digits

    func testB1UnicodeEscapeNeedsFourHexDigits() {
        for bad in [#""\u+041""#, #""\u-000""#, #""\u 041""#, #""\u004""#] {
            XCTAssertThrowsError(try OrderedJSON(bad), bad)
        }
        guard case .string(let s)? = (try? OrderedJSON(#""Aé""#))?.root.value else { return XCTFail("valid escapes refused") }
        XCTAssertEqual(s, "Aé")
    }

    // MARK: D7 / g3: the held count is per (file, JSON path)

    func testD7SameHashUnderTwoEventsIsHeldPerPath() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        let a = env.owner, b = env.owner("kit-b")
        _ = await env.mc.apply([MCPieces.hook("post", event: "PostToolUse")], owner: b)
        _ = await env.mc.apply([MCPieces.hook()], owner: a)
        let applied = try XCTUnwrap(env.bytes(env.settings))
        try FileManager.default.removeItem(at: stateFile(env))
        let rb = await env.mc.apply([MCPieces.hook("post", event: "PostToolUse")], owner: b)
        XCTAssertEqual(rb.pieces.map(\.action), [.adopt])
        let ra = await env.mc.apply([MCPieces.hook()], owner: a)
        XCTAssertEqual(ra.pieces.map(\.action), [.adopt], "PostToolUse's holder does not hold PreToolUse's copy")
        XCTAssertEqual(env.bytes(env.settings), applied, "no duplicate PreToolUse group")
    }

    func testG3TwoClaudeRootsSharingOneStateHoldPerFile() async throws {
        let env = makeMCEnv()
        let claude2 = env.root.appendingPathComponent("claude two", isDirectory: true)
        try FileManager.default.createDirectory(at: claude2, withIntermediateDirectories: true)
        let settings2 = claude2.appendingPathComponent("settings.json")
        for f in [env.settings, settings2] { try env.write("{\n  \"theme\": \"dark\"\n}\n", f) }
        let clock = MCClock()
        let mc2 = ManagedConfig(roots: ManagedConfigRoots(claude: claude2, configHome: env.config, stateDir: env.state),
                                consent: env.consent, writer: env.writer, now: { clock.now().addingTimeInterval(500) })
        _ = await mc2.apply([MCPieces.hook()], owner: env.owner) // kit-a's group in root two
        try FileManager.default.removeItem(at: stateFile(env)) // kit-a's record lost
        _ = await env.mc.apply([MCPieces.hook()], owner: env.owner("kit-b")) // kit-b's record, root one
        let before = env.bytes(settings2)
        let r = await mc2.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(r.pieces.map(\.action), [.adopt], "kit-b's record in the other file holds nothing here")
        XCTAssertEqual(env.bytes(settings2), before)
    }

    // MARK: B-INFO-11/12/13: what the sheet's lines show

    func testSheetLinesForANewFileShowNoSkeleton() async throws {
        let env = makeMCEnv()
        _ = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        let file = try XCTUnwrap(env.consent.seen.first?.files.first)
        XCTAssertTrue(file.newFile)
        XCTAssertFalse(file.lines.contains { $0.sign == .removed }, "\(file.lines)")
        _ = await env.mc.remove(owner: env.owner)
        let gone = try XCTUnwrap(env.consent.seen.last?.files.first)
        XCTAssertTrue(gone.deletesFile)
        XCTAssertFalse(gone.lines.contains { $0.sign == .added }, "never +{}: \(gone.lines)")
        XCTAssertNil(env.read(env.settings))

        // two pieces into one new file: still one whole-file hunk, every written line added once
        let env2 = makeMCEnv(label: "two-steps")
        _ = await env2.mc.apply([MCPieces.hook(), MCPieces.statusLine()], owner: env2.owner)
        let two = try XCTUnwrap(env2.consent.seen.first?.files.first)
        let written = try XCTUnwrap(env2.read(env2.settings)).split(separator: "\n", omittingEmptySubsequences: false).count - 1
        XCTAssertTrue(two.newFile)
        XCTAssertTrue(two.lines.allSatisfy { $0.sign == .added }, "\(two.lines)")
        XCTAssertEqual(two.lines.count, written, "\(two.lines)")
    }

    func testSheetLinesNeverPrintTheUsersOwnHookGroupOrStatusLine() async throws {
        let env = makeMCEnv()
        try env.write("""
        {
          "hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-own-check --token=dummy-not-real"}]}]
          },
          "statusLine": {"type": "command", "command": "my-own-status --token=dummy-not-real"}
        }

        """, env.settings)
        _ = await env.mc.apply([MCPieces.hook(), MCPieces.statusLine()], owner: env.owner)
        let shown = try XCTUnwrap(env.consent.seen.first?.files.first).lines
        XCTAssertFalse(shown.contains { $0.text.contains("dummy-not-real") }, "\(shown)")
        XCTAssertTrue(shown.contains { $0.sign == .added && $0.text.contains("kit-run pre") })
        XCTAssertTrue(shown.contains { $0.sign == .removed && $0.text == ManagedConfigChangeSet.userValueLine })
        _ = await env.mc.remove(owner: env.owner)
        let back = try XCTUnwrap(env.consent.seen.last?.files.first).lines
        XCTAssertFalse(back.contains { $0.text.contains("dummy-not-real") }, "\(back)")
        XCTAssertTrue(back.contains { $0.sign == .added && $0.text == ManagedConfigChangeSet.userValueLine })
    }

    func testSheetLinesCarryTwoContextLinesAndMarkAMissingFinalNewline() async throws {
        let env = makeMCEnv()
        try env.write((1...10).map { "line \($0)" }.joined(separator: "\n"), env.claudeMD) // no final newline
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        let lines = try XCTUnwrap(env.consent.seen.first?.files.first).lines
        let context = lines.filter { $0.sign == .context }.map(\.text)
        XCTAssertEqual(context, ["line 8", "line 9", "line 10"], "two before, plus the user's last line that only gained a newline")
        XCTAssertFalse(lines.contains { $0.sign == .removed }, "\(lines)")
        XCTAssertEqual(lines.last?.noFinalNewline, true, "the file still ends without a newline, and the sheet says so")
        XCTAssertEqual(lines.filter(\.noFinalNewline).count, 1)
    }

    // MARK: SHOULD: A-INFO-14, B-INFO-16/6, B-INFO-3, B-INFO-2, B-INFO-4/9

    func testA14DeleteRechecksTheFileAndDropsItsBackup() async throws {
        let env = makeMCEnv()
        _ = await env.mc.apply([MCPieces.seed()], owner: env.owner)
        let local = env.config.appendingPathComponent("kit-a/local.md")
        XCTAssertNotNil(env.read(local))
        env.writer.interleave { target, _ in
            guard target.lastPathComponent.hasSuffix(".pre") else { return }
            try? Data("my edit\n".utf8).write(to: local) // the user saves while the Remove runs
        }
        let r = await env.mc.remove(owner: env.owner)
        env.writer.interleave(nil)
        XCTAssertEqual(r.pieces.map(\.action), [.keep], "re-planned: the edited seed is the user's now")
        XCTAssertEqual(env.read(local), "my edit\n", "never deleted under a concurrent edit")
        XCTAssertEqual(backups(env, suffix: ".pre"), [], "the round's backup went with it")
    }

    func testB16AppendAndSetReportMissingAndReplacedOnApply() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        _ = await env.mc.apply([MCPieces.hook(), MCPieces.statusLine()], owner: env.owner)
        var doc = try XCTUnwrap(env.read(env.settings))
        doc = doc.replacingOccurrences(of: "kit-status", with: "my-status")
        try env.write(doc, env.settings)
        let replaced = await env.mc.apply([MCPieces.statusLine()], owner: env.owner)
        XCTAssertEqual(replaced.refusals.map(\.reason), [.replaced])
        try env.write("{\n  \"theme\": \"dark\",\n  \"hooks\": {\"PreToolUse\": []}\n}\n", env.settings)
        let before = env.bytes(env.settings)
        let missing = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(missing.refusals.map(\.reason), [.missing])
        XCTAssertEqual(env.bytes(env.settings), before)
    }

    func testB6RemoveOnUnparsableSettingsKeepsTheRecord() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        _ = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        let broken = try XCTUnwrap(env.read(env.settings)) + "x"
        try env.write(broken, env.settings)
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(env.read(env.settings), broken)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.corrupt], "the record stays")
    }

    func testB3NestingCapIs256() {
        XCTAssertNoThrow(try OrderedJSON(String(repeating: "[", count: 256) + String(repeating: "]", count: 256)))
        XCTAssertThrowsError(try OrderedJSON(String(repeating: "[", count: 257) + String(repeating: "]", count: 257))) { error in
            XCTAssertEqual((error as? OrderedJSON.ParseError)?.reason, "nesting is too deep")
        }
    }

    func testB2LiteralsBeyondDoublePrecisionHashApart() throws {
        func h(_ s: String) throws -> String { OrderedJSON.hash(try OrderedJSON(s).root.value) }
        XCTAssertNotEqual(try h("9007199254740993"), try h("9007199254740992"))
        XCTAssertNotEqual(try h("1e400"), try h("1e500"))
        XCTAssertEqual(try h("1.50"), try h("1.5"))
        XCTAssertEqual(try h("1000"), try h("1e3"))
    }

    func testB4B9LineEndingsAreDecidedOnBytesByMajority() async throws {
        XCTAssertEqual(OrderedJSON.newline(of: Array("a\r\nb\nc\n".utf8)), "\n", "one stray CRLF does not make the file CRLF")
        XCTAssertEqual(OrderedJSON.newline(of: Array("a\r\nb\r\nc\n".utf8)), "\r\n")
        let env = makeMCEnv()
        let original = "{\r\n  \"hooks\": {\r\n    \"PreToolUse\": [\r\n      {\"matcher\": \"Read\", \"hooks\": []}\r\n    ]\r\n  }\r\n}\r\n"
        try env.write(original, env.settings)
        _ = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        let after = try XCTUnwrap(env.read(env.settings))
        XCTAssertTrue(after.contains("\r\n        \"matcher\": \"Bash\""), "the new group renders pretty on CRLF: \(after.debugDescription)")
        XCTAssertFalse(after.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare LF")
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.settings), original)
    }
}

// MARK: - #946 (QA 742): A-INFO-7/9, A-INFO-10, A-INFO-1, A-INFO-3

extension ManagedConfigQATests {
    /// `needle` occurs in `hay` byte for byte (Data.range is byte-wise; String.contains is not).
    private func has(_ hay: [UInt8]?, _ needle: String) -> Bool { hay.map { Data($0).range(of: Data(needle.utf8)) != nil } ?? false }

    private func replacingBytes(_ bytes: [UInt8], _ a: String, _ b: String) -> [UInt8] {
        var d = Data(bytes)
        if let r = d.range(of: Data(a.utf8)) { d.replaceSubrange(r, with: Data(b.utf8)) }
        return Array(d)
    }

    /// The note text typed out once: the tests pin the words, not a reference to the constant.
    private static let changedNote = "This file changed after the sheet opened, in a place the diff does not show "
        + "(a hidden value or line endings): this approval is for the file as it is now."

    /// `sheet` with the changed-under-the-sheet note on its one file.
    private func withChangedNote(_ sheet: ManagedConfigChangeSet?) -> ManagedConfigChangeSet? {
        guard var sheet else { return nil }
        XCTAssertEqual(sheet.files.count, 1)
        // #1025 (a): an emptied sheet fails the count above, it never traps on an index
        if let i = sheet.files.indices.first { sheet.files[i].notes.append(Self.changedNote) }
        return sheet
    }

    /// One apply whose file the user saves as `during` while the first sheet is up. `second`: the
    /// answer on any later sheet.
    private func applyWhileSaving(_ label: String, file: String, before: String, during: String, piece: ManagedConfigPiece,
                                  second: Bool) async throws -> (consent: MCScriptedConsent, result: ManagedConfigResult, bytes: [UInt8]?) {
        let env = makeMCEnv(label: label)
        let url = env.claude.appendingPathComponent(file)
        try env.write(before, url)
        let consent = MCScriptedConsent { call, _ in
            if call == 1 { try? Data(during.utf8).write(to: url) }
            return call == 1 || second
        }
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)
        let result = await mc.apply([piece], owner: env.owner)
        return (consent, result, env.bytes(url))
    }

    /// A-INFO-7/9: the consent covers the exact bytes. A change the sheet's lines cannot show (a masked
    /// env value, a line ending, a BOM outside the context lines) asks again; a no on that sheet writes
    /// nothing. A replan whose written bytes are the same does not ask again.
    func testA7ConsentCoversTheExactBytesNotTheMaskedLines() async throws {
        // (a) the env value sits on a masked context line: dummy-a and dummy-b show the same lines
        let during = "{\n  \"env\": {\"API_TOKEN\": \"dummy-b\"},\n  \"theme\": \"dark\"\n}\n"
        let env = try await applyWhileSaving("a7-env", file: "settings.json",
                                             before: "{\n  \"env\": {\"API_TOKEN\": \"dummy-a\"},\n  \"theme\": \"dark\"\n}\n",
                                             during: during, piece: MCPieces.hook(), second: false)
        XCTAssertEqual(env.consent.seen.count, 2, "other bytes under the same masked lines: asked again")
        XCTAssertEqual(env.consent.seen.last, withChangedNote(env.consent.seen.first), "the second sheet says why it is back")
        XCTAssertFalse(env.consent.seen.first?.files.first?.notes.contains(ManagedConfigPlan.changedUnderSheetNote) ?? true, "not on the first")
        XCTAssertTrue(env.consent.seen.first?.files.first?.lines.contains { $0.text == ManagedConfigChangeSet.maskedLine } ?? false)
        XCTAssertEqual(env.result.status, .denied)
        XCTAssertEqual(env.bytes, Array(during.utf8), "a no on the second sheet: nothing written under the first")

        // (b) the file turns CRLF: line texts carry no terminator, the block would go in with CRLF
        let crlf = try await applyWhileSaving("a7-crlf", file: "CLAUDE.md", before: "# one\n# two\n# three\n# four\n",
                                              during: "# one\r\n# two\r\n# three\r\n# four\r\n", piece: MCPieces.block(), second: true)
        XCTAssertEqual(crlf.consent.seen.count, 2, "LF to CRLF differs in bytes: asked again")
        XCTAssertEqual(crlf.consent.seen.last, withChangedNote(crlf.consent.seen.first))
        XCTAssertFalse(crlf.consent.seen.first?.files.first?.notes.contains(ManagedConfigPlan.changedUnderSheetNote) ?? true)
        XCTAssertEqual(crlf.result.status, .done)
        XCTAssertTrue(has(crlf.bytes, "# four\r\n\r\n<!-- >>> prosper:kit-a:rules "))

        // (c) a BOM on line 1, outside the two context lines
        let bom = try await applyWhileSaving("a7-bom", file: "CLAUDE.md", before: "# one\n# two\n# three\n# four\n",
                                             during: "\u{FEFF}# one\n# two\n# three\n# four\n", piece: MCPieces.block(), second: true)
        XCTAssertEqual(bom.consent.seen.count, 2, "a BOM differs in bytes: asked again")
        XCTAssertEqual(bom.consent.seen.last, withChangedNote(bom.consent.seen.first))
        XCTAssertFalse(bom.consent.seen.first?.files.first?.notes.contains(ManagedConfigPlan.changedUnderSheetNote) ?? true)
        XCTAssertEqual(bom.result.status, .done)
        XCTAssertEqual(bom.bytes.map { Array($0.prefix(3)) }, [0xEF, 0xBB, 0xBF], "the user's BOM is kept")

        // (d) the user's own statusLine changes under the sheet; Prosper writes the same bytes either way
        let same = try await applyWhileSaving("a7-same", file: "settings.json",
                                              before: "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"my-a\"}\n}\n",
                                              during: "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"my-b\"}\n}\n",
                                              piece: MCPieces.statusLine(), second: false)
        XCTAssertEqual(same.consent.seen.count, 1, "same lines, same written bytes: not asked twice")
        XCTAssertEqual(same.consent.seen.first?.files.first?.notes.contains(ManagedConfigPlan.changedUnderSheetNote), false)
        XCTAssertEqual(same.result.status, .done)
        XCTAssertTrue(has(same.bytes, "kit-status") && !has(same.bytes, "my-b"))
    }

    /// A-INFO-10: an edited block is drift for Remove too. Remove asks (spec 2.5: "shows the hand edits
    /// that will be lost and asks first") and the sheet now says the block holds hand edits.
    func testA10RemoveOfAnEditedBlockNamesTheDriftInTheSheet() async throws {
        let clean = makeMCEnv(label: "a10-clean")
        try clean.write("# mine\n", clean.claudeMD)
        _ = await clean.mc.apply([MCPieces.block()], owner: clean.owner)
        _ = await clean.mc.remove(owner: clean.owner)
        XCTAssertEqual(clean.consent.seen.count, 2)
        XCTAssertEqual(clean.consent.seen.last?.files.first?.notes, [], "nothing edited: no drift note")

        let env = makeMCEnv(label: "a10-edited")
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        try env.write(try XCTUnwrap(env.read(env.claudeMD)).replacingOccurrences(of: "Follow the kit rules.", with: "Follow the kit rules, and mine."),
                      env.claudeMD)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.drifted])
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(r.pieces, [.init(id: "rules", action: .remove)])
        XCTAssertEqual(env.consent.seen.count, 2, "the Remove asked")
        XCTAssertEqual(env.consent.seen.last?.files.first?.notes,
                       ["The rules block was edited by hand: Remove deletes those edits too (the file as it is now goes to the backups)."])
        XCTAssertTrue(env.consent.seen.last?.files.first?.lines.contains(.init(sign: .removed, text: "Follow the kit rules, and mine.")) ?? false)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        let pre = backups(env, suffix: ".pre")
        XCTAssertEqual(pre.count, 1, "the edited file went to the backups first")
        if let name = pre.first { XCTAssertTrue(env.read(env.backups.appendingPathComponent(name))?.contains("and mine.") ?? false) }
    }

    /// A-INFO-1: a block edited after its record was lost. Apply refuses it as drift, repair by ids knows
    /// only records; Repair by the declared piece replaces it after the sheet shows the edit, records it,
    /// and a later Remove (the uninstall path) takes it out byte for byte. A no writes nothing.
    func testA1LostRecordEditedBlockIsRepairedByThePieceAfterShowingTheEdit() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let piece = MCPieces.block()
        _ = await env.mc.apply([piece], owner: env.owner)
        let applied = try XCTUnwrap(env.bytes(env.claudeMD))
        try FileManager.default.removeItem(at: stateFile(env))
        try env.write(try XCTUnwrap(env.read(env.claudeMD)).replacingOccurrences(of: "Follow the kit rules.", with: "Follow my rules instead."),
                      env.claudeMD)
        let edited = env.bytes(env.claudeMD)

        let byIDs = await env.mc.repair(owner: env.owner)
        XCTAssertEqual(byIDs.status, .nothingToDo, "repair by ids knows only records")
        let no = ManagedConfig(roots: env.mc.roots, consent: MCRecordingConsent(false), writer: env.writer)
        let denied = await no.repair([piece], owner: env.owner)
        XCTAssertEqual(denied.status, .denied)
        XCTAssertEqual(env.bytes(env.claudeMD), edited, "declined: the user's text stays")

        let r = await env.mc.repair([piece], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(r.pieces, [.init(id: "rules", action: .update)])
        XCTAssertEqual(env.consent.seen.count, 2)
        let file = env.consent.seen.last?.files.first
        XCTAssertTrue(file?.lines.contains(.init(sign: .removed, text: "Follow my rules instead.")) ?? false, "the sheet shows the edit it replaces")
        XCTAssertTrue(file?.notes.contains("The rules block was edited by hand: Repair replaces those edits too (the file as it is now goes to the backups).") ?? false)
        XCTAssertEqual(env.bytes(env.claudeMD), applied)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied], "recorded now")
        let removed = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(removed.status, .done)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n", "Remove, and so uninstall, can take it now")
    }

    /// A-INFO-3: a block re-saved in NFD differs in bytes from the NFC block Prosper wrote. Swift's ==
    /// takes the two for one; the core does not: drift, not applied, never a noop, never adopted.
    func testA3NFDResaveOfABlockIsDriftByBytes() async throws {
        let nfc = "Ask Zo\u{00EB} before a release.", nfd = "Ask Zoe\u{0308} before a release."
        XCTAssertTrue(nfc == nfd, "the premise: String == takes them for one")
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let piece = MCPieces.block(text: nfc)
        _ = await env.mc.apply([piece], owner: env.owner)
        let applied = try XCTUnwrap(env.bytes(env.claudeMD))
        let resaved = replacingBytes(applied, nfc, nfd)
        XCTAssertNotEqual(resaved, applied)
        try Data(resaved).write(to: env.claudeMD)

        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.drifted])
        let again = await env.mc.apply([piece], owner: env.owner)
        XCTAssertEqual(again.refusals.map(\.reason), [.drifted], "not a noop over other bytes")
        XCTAssertEqual(env.bytes(env.claudeMD), resaved)
        try FileManager.default.removeItem(at: stateFile(env))
        XCTAssertEqual(env.mc.status(owner: env.owner, declared: [piece]).map(\.state), [.drifted], "never adopted")
        XCTAssertEqual(env.mc.status(owner: env.owner).count, 0)
    }

    /// A-INFO-3: union strings are matched by bytes, as JSON (RFC 8259 8.3) and Claude Code compare them.
    /// The user's NFD entry does not make the piece's NFC one present; Remove takes back only Prosper's.
    func testA3UnionStringsAreMatchedByBytes() async throws {
        let mine = "Read(/Users/example/Zoe\u{0308}/**)", ours = "Read(/Users/example/Zo\u{00EB}/**)"
        let env = makeMCEnv()
        let original = "{\n  \"permissions\": {\n    \"allow\": [\(OrderedJSON.quote(mine))]\n  }\n}\n"
        try env.write(original, env.settings)
        let r = await env.mc.apply([MCPieces.allow([ours])], owner: env.owner)
        XCTAssertEqual(r.pieces, [.init(id: "perms", action: .insert)])
        let after = env.bytes(env.settings)
        XCTAssertTrue(has(after, OrderedJSON.quote(ours)) && has(after, OrderedJSON.quote(mine)), "both forms, as written")
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied])
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.bytes(env.settings), Array(original.utf8), "the user's NFD entry stays, ours goes")
    }
}

/// #946 round 2: every byte compare the A-INFO-3 change introduced, pinned by a literal case that a
/// String == (or a Set<String>) gets wrong. NFC and NFD of one path: String == takes them for one.
extension ManagedConfigQATests {
    private static let nfc = "Read(/Users/example/Zo\u{00EB}/**)", nfd = "Read(/Users/example/Zoe\u{0308}/**)"
    private static let plain = "{\n  \"theme\": \"dark\"\n}\n"

    /// permissions.allow as the bytes of each string, in file order.
    private func allowed(_ env: MCEnv) -> [[UInt8]] {
        guard let bytes = env.bytes(env.settings), let doc = try? OrderedJSON(bytes: bytes),
              case .array(let els)? = doc.node(at: ["permissions", "allow"])?.value else { return [] }
        return els.compactMap { if case .string(let s) = $0.value { return Array(s.utf8) } else { return nil } }
    }

    private var nfcBytes: [UInt8] { Array(Self.nfc.utf8) }
    private var nfdBytes: [UInt8] { Array(Self.nfd.utf8) }

    /// 1a status, 1f the .missing refusal, 1e the "present" test of toDrop: Prosper's NFC entry
    /// replaced by hand with the NFD twin.
    func testA3R2UnionEntryReplacedByItsTwinIsMissing() async throws {
        XCTAssertTrue(Self.nfc == Self.nfd, "the premise")
        let env = makeMCEnv()
        try env.write(Self.plain, env.settings)
        _ = await env.mc.apply([MCPieces.allow([Self.nfc])], owner: env.owner)
        let applied = try XCTUnwrap(env.bytes(env.settings))
        try Data(replacingBytes(applied, OrderedJSON.quote(Self.nfc), OrderedJSON.quote(Self.nfd))).write(to: env.settings)
        XCTAssertEqual(allowed(env), [nfdBytes])
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.missing], "1a: ours is gone, the twin is the user's")
        let again = await env.mc.apply([MCPieces.allow([Self.nfc])], owner: env.owner)
        XCTAssertEqual(again.refusals.map(\.reason), [.missing], "1f: the twin does not make ours present")
        let repaired = await env.mc.repair([MCPieces.allow([Self.nfd])], owner: env.owner)
        XCTAssertEqual(repaired.pieces, [.init(id: "perms", action: .noop)], "1e: the claimed NFC is not in the file: nothing to drop")
        XCTAssertEqual(allowed(env), [nfdBytes])
    }

    /// 1b removeLastString: the user's twin sits after Prosper's entry; Remove takes Prosper's.
    func testA3R2RemoveTakesOursWhenTheUsersTwinComesAfterIt() async throws {
        let env = makeMCEnv()
        try env.write(Self.plain, env.settings)
        _ = await env.mc.apply([MCPieces.allow([Self.nfc])], owner: env.owner)
        let applied = try XCTUnwrap(env.bytes(env.settings))
        let q = OrderedJSON.quote(Self.nfc)
        try Data(replacingBytes(applied, q, q + ", " + OrderedJSON.quote(Self.nfd))).write(to: env.settings)
        XCTAssertEqual(allowed(env), [nfcBytes, nfdBytes])
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.pieces, [.init(id: "perms", action: .remove)])
        XCTAssertEqual(allowed(env), [nfdBytes], "1b: ours went, the user's later twin stays")
    }

    /// 1c Remove's others, 1e others in toDrop and in claimed: two owners holding the two twins.
    func testA3R2TwoOwnersHoldingTwinsEachKeepTheirOwn() async throws {
        // 1c: A claims NFC, B claims NFD. Remove of A takes A's string; B's is no claim on it.
        let env = makeMCEnv(label: "twins-c")
        let b = env.owner("kit-b")
        try env.write(Self.plain, env.settings)
        _ = await env.mc.apply([MCPieces.allow([Self.nfc])], owner: env.owner)
        _ = await env.mc.apply([MCPieces.allow([Self.nfd])], owner: b)
        XCTAssertEqual(allowed(env), [nfcBytes, nfdBytes])
        let removed = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(removed.pieces, [.init(id: "perms", action: .remove)])
        XCTAssertEqual(allowed(env), [nfdBytes], "1c: A's NFC went")
        XCTAssertEqual(env.mc.status(owner: b).map(\.state), [.applied])

        // 1e toDrop others: A moves from NFC to NFD while B holds NFD: A's NFC is dropped, NFD shared.
        let upd = makeMCEnv(label: "twins-e")
        let b2 = upd.owner("kit-b")
        try upd.write(Self.plain, upd.settings)
        _ = await upd.mc.apply([MCPieces.allow([Self.nfc])], owner: upd.owner)
        _ = await upd.mc.apply([MCPieces.allow([Self.nfd])], owner: b2)
        let moved = await upd.mc.apply([MCPieces.allow([Self.nfd])], owner: upd.owner)
        XCTAssertEqual(moved.pieces, [.init(id: "perms", action: .update)])
        XCTAssertEqual(allowed(upd), [nfdBytes], "1e: B's NFD is no claim on A's NFC")
        _ = await upd.mc.remove(owner: b2)
        XCTAssertEqual(allowed(upd), [nfdBytes], "A claims the NFD too")
        _ = await upd.mc.remove(owner: upd.owner)
        XCTAssertEqual(upd.bytes(upd.settings), Array(Self.plain.utf8))

        // 1e claimed others: the user's NFC, B's NFD. A declaring NFC claims nothing (B's NFD is not it).
        let mine = makeMCEnv(label: "twins-claimed")
        let b3 = mine.owner("kit-b")
        let original = "{\n  \"permissions\": {\n    \"allow\": [\(OrderedJSON.quote(Self.nfc))]\n  }\n}\n"
        try mine.write(original, mine.settings)
        _ = await mine.mc.apply([MCPieces.allow([Self.nfd])], owner: b3)
        let a = await mine.mc.apply([MCPieces.allow([Self.nfc])], owner: mine.owner)
        XCTAssertEqual(a.pieces, [.init(id: "perms", action: .noop)])
        _ = await mine.mc.remove(owner: mine.owner)
        XCTAssertEqual(allowed(mine), [nfcBytes, nfdBytes], "1e: the user's NFC stays after A's Remove")
        _ = await mine.mc.remove(owner: b3)
        XCTAssertEqual(mine.bytes(mine.settings), Array(original.utf8))
    }

    /// 1d the piece's own list, 1e toAdd in claimed: a piece declaring both forms over the user's NFC.
    func testA3R2APieceDeclaringBothFormsWritesAndClaimsOnlyWhatItAdds() async throws {
        let env = makeMCEnv()
        let original = "{\n  \"permissions\": {\n    \"allow\": [\(OrderedJSON.quote(Self.nfc))]\n  }\n}\n"
        try env.write(original, env.settings)
        let r = await env.mc.apply([MCPieces.allow([Self.nfc, Self.nfd])], owner: env.owner)
        XCTAssertEqual(r.pieces, [.init(id: "perms", action: .insert)])
        XCTAssertEqual(allowed(env), [nfcBytes, nfdBytes], "1d: both forms, NFD added")
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.bytes(env.settings), Array(original.utf8), "1e: only the NFD was claimed; the user's NFC stays")
    }

    /// 1e strings in toDrop, existing.claimed in claimed: a piece updated from the NFC string to the NFD one.
    func testA3R2APieceUpdatedFromNFCToNFDSwapsItsEntry() async throws {
        // the file holds only Prosper's NFC: dropped, NFD added and claimed, Remove restores the file
        let env = makeMCEnv(label: "swap-own")
        try env.write(Self.plain, env.settings)
        _ = await env.mc.apply([MCPieces.allow([Self.nfc])], owner: env.owner)
        let r = await env.mc.apply([MCPieces.allow([Self.nfd])], owner: env.owner)
        XCTAssertEqual(r.pieces, [.init(id: "perms", action: .update)])
        XCTAssertEqual(allowed(env), [nfdBytes], "1e: the NFC entry is dropped, the NFD one added")
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.bytes(env.settings), Array(Self.plain.utf8), "the NFD was claimed: Remove restores the file")

        // the user's own NFD was there first: the update drops ours and claims nothing
        let mine = makeMCEnv(label: "swap-users")
        let original = "{\n  \"permissions\": {\n    \"allow\": [\(OrderedJSON.quote(Self.nfd))]\n  }\n}\n"
        try mine.write(original, mine.settings)
        _ = await mine.mc.apply([MCPieces.allow([Self.nfc])], owner: mine.owner)
        let u = await mine.mc.apply([MCPieces.allow([Self.nfd])], owner: mine.owner)
        XCTAssertEqual(u.pieces, [.init(id: "perms", action: .update)])
        XCTAssertEqual(allowed(mine), [nfdBytes])
        _ = await mine.mc.remove(owner: mine.owner)
        XCTAssertEqual(mine.bytes(mine.settings), Array(original.utf8), "1e: the record's NFC is no claim on the user's NFD")
    }

    /// 1i claims() as an array: two other owners hold the two twins; a Set would keep one of them.
    func testA3R2ClaimsOfOtherOwnersKeepBothTwins() async throws {
        let env = makeMCEnv()
        let b = env.owner("kit-b"), c = env.owner("kit-c")
        try env.write(Self.plain, env.settings)
        _ = await env.mc.apply([MCPieces.allow([Self.nfc, Self.nfd])], owner: b)
        _ = await env.mc.apply([MCPieces.allow([Self.nfd])], owner: env.owner)
        _ = await env.mc.apply([MCPieces.allow([Self.nfc])], owner: c)
        XCTAssertEqual(allowed(env), [nfcBytes, nfdBytes])
        _ = await env.mc.remove(owner: b)
        XCTAssertEqual(allowed(env), [nfcBytes, nfdBytes], "1i: A holds the NFD, C the NFC: B's Remove takes neither")
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied])
        XCTAssertEqual(env.mc.status(owner: c).map(\.state), [.applied])
    }

    /// 1h: Remove of a block re-saved in NFD names the drift in the sheet.
    func testA3R2RemoveOfAnNFDResavedBlockNamesTheDrift() async throws {
        let nfcText = "Ask Zo\u{00EB} before a release.", nfdText = "Ask Zoe\u{0308} before a release."
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block(text: nfcText)], owner: env.owner)
        try Data(replacingBytes(try XCTUnwrap(env.bytes(env.claudeMD)), nfcText, nfdText)).write(to: env.claudeMD)
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.consent.seen.last?.files.first?.notes,
                       ["The rules block was edited by hand: Remove deletes those edits too (the file as it is now goes to the backups)."])
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
    }

    /// r2 item 2: a third round over the bytes the second sheet showed is not asked again (the note is
    /// not part of what was consented). Round 1 sees a hidden value change, round 2 the user's own
    /// statusLine (shown as one line either way, and replaced by the same bytes).
    func testA7R2ThirdRoundOverTheApprovedBytesIsNotAskedAgain() async throws {
        let env = makeMCEnv()
        let url = env.settings
        func file(_ token: String, _ command: String) -> String {
            "{\n  \"env\": {\"API_TOKEN\": \"\(token)\"},\n  \"statusLine\": {\"type\": \"command\", \"command\": \"\(command)\"}\n}\n"
        }
        try env.write(file("dummy-a", "my-a"), url)
        let r1 = file("dummy-b", "my-a"), r2 = file("dummy-b", "my-b")
        let consent = MCScriptedConsent { call, _ in
            try? Data((call == 1 ? r1 : r2).utf8).write(to: url)
            return true
        }
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)
        let r = await mc.apply([MCPieces.statusLine()], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(consent.seen.count, 2, "round 3 writes what round 2 approved: no third sheet")
        XCTAssertEqual(consent.seen.last, withChangedNote(consent.seen.first))
        XCTAssertFalse(consent.seen.first?.files.first?.notes.contains(Self.changedNote) ?? true)
        XCTAssertTrue(has(env.bytes(url), "dummy-b") && has(env.bytes(url), "kit-status") && !has(env.bytes(url), "\"my-b\""), "dummy-b holds the text my-b: match the quoted command")
    }

    /// r2 item 3b: a file Prosper created and Remove deletes, re-saved with CRLF under the sheet. The
    /// deletion's lines carry no terminators, so only the base bytes tell the two files apart.
    func testA7R2DeletionOfAFileResavedUnderTheSheetAsksAgain() async throws {
        let env = makeMCEnv()
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(env.consent.seen.first?.files.first?.notes.contains(Self.changedNote), false, "a plain apply: no note")
        let url = env.claudeMD
        let lf = try XCTUnwrap(env.read(url))
        let consent = MCScriptedConsent { call, _ in
            if call == 1 { try? Data(lf.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: url) }
            return true
        }
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)
        let r = await mc.remove(owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(consent.seen.first?.files.first?.deletesFile, true)
        XCTAssertEqual(consent.seen.count, 2, "another file under the same lines: asked again")
        XCTAssertEqual(consent.seen.last, withChangedNote(consent.seen.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// #1025 (b): two files in one sheet, one re-saved under the sheet with other bytes under the same
    /// lines (LF to CRLF): the second sheet carries the note on that file only.
    func testA7R2TwoFilesOnlyTheResavedOneCarriesTheNote() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD, notes = env.claude.appendingPathComponent("NOTES.md")
        try env.write("# one\n# two\n# three\n# four\n", url)
        try env.write("# notes\n", notes)
        let consent = MCScriptedConsent { call, _ in
            if call == 1 { try? Data("# one\r\n# two\r\n# three\r\n# four\r\n".utf8).write(to: url) }
            return true
        }
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent, writer: env.writer)
        let r = await mc.apply([MCPieces.block(), MCPieces.block("notes", target: "claude:NOTES.md")], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(consent.seen.count, 2, "CLAUDE.md differs in bytes: asked again")
        var expected = try XCTUnwrap(consent.seen.first)
        XCTAssertEqual(expected.files.map(\.target), ["claude:CLAUDE.md", "claude:NOTES.md"])
        let i = try XCTUnwrap(expected.files.firstIndex(where: { $0.target == "claude:CLAUDE.md" }))
        expected.files[i].notes.append(Self.changedNote)
        XCTAssertEqual(consent.seen.last, expected, "the note on the re-saved file only")
        XCTAssertEqual(consent.seen.last?.files.first(where: { $0.target == "claude:NOTES.md" })?.notes.contains(Self.changedNote), false)
        XCTAssertTrue(has(env.bytes(url), "# four\r\n\r\n<!-- >>> prosper:kit-a:rules "))
        XCTAssertTrue(has(env.bytes(notes), "# notes\n\n<!-- >>> prosper:kit-a:notes "))
    }
}
