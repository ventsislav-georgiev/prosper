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
