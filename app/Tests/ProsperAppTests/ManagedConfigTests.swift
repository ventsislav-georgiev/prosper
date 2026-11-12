import Foundation
import XCTest
@testable import ProsperApp

// #870: fakes for the ManagedConfig seams. Every root is a tempDir(); nothing here can reach the
// real ~/.claude, ~/.config, ~/Library or the Keychain.

final class MCRecordingConsent: ManagedConfigConsent, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [ManagedConfigChangeSet] = []
    private let answer: Bool
    private var script: [Bool]

    /// `script`: answers for the first asks, in order; `answer` after it runs out.
    init(_ answer: Bool = true, script: [Bool] = []) { self.answer = answer; self.script = script }

    func confirm(_ changes: ManagedConfigChangeSet) async -> Bool {
        lock.withLock {
            _seen.append(changes)
            return script.isEmpty ? answer : script.removeFirst()
        }
    }

    var seen: [ManagedConfigChangeSet] { lock.withLock { _seen } }
}

/// Wraps the real POSIX writer: counts temp writes and renames per target, can fail the rename,
/// and can run a "concurrent writer" right after the temp is written (errata C9).
final class MCWriter: ManagedConfigFileWriter, @unchecked Sendable {
    private let real = ManagedConfigPOSIXWriter()
    private let lock = NSLock()
    private var _temps: [String: Int] = [:]
    private var _replaces: [String: Int] = [:]
    private var _interleave: (@Sendable (URL, Int) -> Void)?
    private var _failReplace = false
    private var _failOnly: String?

    func temps(_ url: URL) -> Int { lock.withLock { _temps[url.lastPathComponent, default: 0] } }
    func replaces(_ url: URL) -> Int { lock.withLock { _replaces[url.lastPathComponent, default: 0] } }
    /// Called with the target and its temp-write count, after the temp file exists.
    func interleave(_ f: (@Sendable (URL, Int) -> Void)?) { lock.withLock { _interleave = f } }
    /// `only`: fail just the rename onto that file name; otherwise every rename outside the state dir.
    func failReplace(_ on: Bool, only name: String? = nil) { lock.withLock { _failReplace = on; _failOnly = name } }

    func writeTemp(_ data: [UInt8], besides target: URL, mode: mode_t) throws -> URL {
        let temp = try real.writeTemp(data, besides: target, mode: mode)
        let (n, hook) = lock.withLock { () -> (Int, (@Sendable (URL, Int) -> Void)?) in
            _temps[target.lastPathComponent, default: 0] += 1
            return (_temps[target.lastPathComponent]!, _interleave)
        }
        hook?(target, n)
        return temp
    }

    func replace(_ target: URL, with temp: URL) throws {
        let fail = lock.withLock { () -> Bool in
            _replaces[target.lastPathComponent, default: 0] += 1
            return _failReplace && (_failOnly.map { target.lastPathComponent == $0 } ?? !target.path.contains("/state/"))
        }
        if fail { throw ManagedConfigPOSIXWriter.WriteError(step: "rename", code: EIO) }
        try real.replace(target, with: temp)
    }
}

final class MCClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { t += 1; return t } }
}

struct MCEnv {
    let root: URL
    let claude: URL
    let config: URL
    let state: URL
    let ext: URL
    let consent: MCRecordingConsent
    let writer: MCWriter
    let mc: ManagedConfig
    let owner: ManagedConfigOwner

    var claudeMD: URL { claude.appendingPathComponent("CLAUDE.md") }
    var settings: URL { claude.appendingPathComponent("settings.json") }
    var backups: URL { state.appendingPathComponent("backups") }

    func owner(_ id: String) -> ManagedConfigOwner {
        ManagedConfigOwner(id: id, version: "1.0.0", kitSlug: id, extensionDir: ext)
    }

    func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
    func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    func bytes(_ url: URL) -> [UInt8]? { (try? Data(contentsOf: url)).map(Array.init) }

    func files(under dir: URL) -> [String] {
        (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).sorted()
    }

    func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
}

extension XCTestCase {
    /// Roots under one tempDir(). The `claude:` root has a space in its path on purpose.
    func makeMCEnv(consent answer: Bool = true, label: String = #function) -> MCEnv {
        let root = tempDir(label)
        let claude = root.appendingPathComponent("claude home", isDirectory: true)
        let ext = root.appendingPathComponent("extensions/kit-a", isDirectory: true)
        for d in [claude, ext] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try? Data("# kit rules\n".utf8).write(to: ext.appendingPathComponent("CLAUDE.md"))
        try? Data("# your local notes\n".utf8).write(to: ext.appendingPathComponent("local.md"))
        let consent = MCRecordingConsent(answer)
        let writer = MCWriter()
        let clock = MCClock()
        let roots = ManagedConfigRoots(claude: claude, configHome: root.appendingPathComponent("config", isDirectory: true),
                                       stateDir: root.appendingPathComponent("state", isDirectory: true))
        let mc = ManagedConfig(roots: roots, consent: consent, writer: writer, now: { clock.now() })
        return MCEnv(root: root, claude: claude, config: roots.configHome, state: roots.stateDir, ext: ext, consent: consent, writer: writer,
                     mc: mc, owner: ManagedConfigOwner(id: "kit-a", version: "1.0.0", kitSlug: "kit-a", extensionDir: ext))
    }
}

enum MCPieces {
    static func block(_ id: String = "rules", target: String = "claude:CLAUDE.md", text: String = "Follow the kit rules.",
                      position: ManagedConfigPiece.Position = .bottom) -> ManagedConfigPiece {
        ManagedConfigPiece(id: id, kind: .block, target: target, text: text, position: position)
    }

    static func hook(_ id: String = "pre", event: String = "PreToolUse", matcher: String = "Bash", command: String = "kit-run pre") -> ManagedConfigPiece {
        ManagedConfigPiece(id: id, kind: .json, target: "claude:settings.json", path: ["hooks", event], op: .append,
                           value: #"{"matcher": "\#(matcher)", "hooks": [{"type": "command", "command": "\#(command)"}]}"#)
    }

    static func allow(_ values: [String], id: String = "perms") -> ManagedConfigPiece {
        ManagedConfigPiece(id: id, kind: .json, target: "claude:settings.json", path: ["permissions", "allow"], op: .union,
                           value: "[" + values.map { OrderedJSON.quote($0) }.joined(separator: ", ") + "]")
    }

    static func statusLine(_ id: String = "status", command: String = "kit-status") -> ManagedConfigPiece {
        ManagedConfigPiece(id: id, kind: .json, target: "claude:settings.json", path: ["statusLine"], op: .set,
                           value: #"{"type": "command", "command": "\#(command)"}"#)
    }

    static func seed(_ id: String = "local", target: String = "kitconfig:local.md", source: String = "ext:local.md") -> ManagedConfigPiece {
        ManagedConfigPiece(id: id, kind: .seed, target: target, source: source)
    }
}

/// #870 P1: the managed-config core against temp roots. Numbers in test names map to spec 2.8.
final class ManagedConfigTests: XCTestCase {

    // MARK: 2.8-1 block round trip

    func test1BlockInsertRemoveRoundTripIsByteIdentical() async throws {
        let inputs = ["", "no trailing newline", "line one\nline two\n", "a\r\nb\r\n", "crlf no final\r\nlast", "\n\n", "x\n\n\ny\n"]
        for input in inputs {
            for position in [ManagedConfigPiece.Position.top, .bottom] {
                let env = makeMCEnv()
                try env.write(input, env.claudeMD)
                let applied = await env.mc.apply([MCPieces.block(position: position)], owner: env.owner)
                XCTAssertEqual(applied.status, .done, "\(input.debugDescription) \(position)")
                let text = try XCTUnwrap(env.read(env.claudeMD))
                XCTAssertTrue(text.contains(">>> prosper:kit-a:rules v1.0.0 · managed by Prosper"))
                XCTAssertTrue(text.contains("<!-- <<< prosper:kit-a:rules <<< -->"))
                if input.contains("\r\n") {
                    XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF kept: \(input.debugDescription)")
                }
                if !input.isEmpty, !input.hasSuffix("\n"), position == .bottom { XCTAssertFalse(text.hasSuffix("\n")) }
                XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied])
                let removed = await env.mc.remove(owner: env.owner)
                XCTAssertEqual(removed.status, .done)
                XCTAssertEqual(env.bytes(env.claudeMD), Array(input.utf8), "\(input.debugDescription) \(position)")
            }
        }
    }

    func test1BlockRoundTripBesideAnotherOwnersBlock() async throws {
        for (first, second) in [(ManagedConfigPiece.Position.bottom, ManagedConfigPiece.Position.bottom), (.top, .top), (.bottom, .top), (.top, .bottom)] {
            let env = makeMCEnv()
            try env.write("# mine\n\nkeep this\n", env.claudeMD)
            _ = await env.mc.apply([MCPieces.block(position: first)], owner: env.owner("kit-b"))
            let withB = try XCTUnwrap(env.bytes(env.claudeMD))
            _ = await env.mc.apply([MCPieces.block(position: second)], owner: env.owner)
            _ = await env.mc.remove(owner: env.owner)
            XCTAssertEqual(env.bytes(env.claudeMD), withB, "\(first) then \(second)")
            _ = await env.mc.remove(owner: env.owner("kit-b"))
            XCTAssertEqual(env.read(env.claudeMD), "# mine\n\nkeep this\n")
        }
    }

    func testBlockOnMissingFileCreatesAndRemoveDeletesIt() async throws {
        let env = makeMCEnv()
        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.mode(env.claudeMD), 0o644)
        XCTAssertEqual(env.files(under: env.backups), [], "nothing existed, nothing to back up")
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.claudeMD.path))
    }

    // MARK: 2.8-2 idempotence

    func test2ApplyTwiceWritesOnceKeepsMtimeAndOneBackup() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        let pieces = [MCPieces.block(), MCPieces.hook()]
        let first = await env.mc.apply(pieces, owner: env.owner)
        XCTAssertEqual(first.status, .done)
        let mtimes = try [env.claudeMD, env.settings].map { try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let bytes = [env.bytes(env.claudeMD), env.bytes(env.settings)]
        let second = await env.mc.apply(pieces, owner: env.owner)
        XCTAssertEqual(second.status, .nothingToDo)
        XCTAssertEqual(env.writer.replaces(env.claudeMD), 1)
        XCTAssertEqual(env.writer.replaces(env.settings), 1)
        XCTAssertEqual(env.consent.seen.count, 1)
        XCTAssertEqual([env.bytes(env.claudeMD), env.bytes(env.settings)], bytes)
        XCTAssertEqual(try [env.claudeMD, env.settings].map { try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }, mtimes)
        let backups = env.files(under: env.backups).filter { $0.hasSuffix(".orig") || $0.hasSuffix(".pre") }
        XCTAssertEqual(backups.count, 2, "\(backups)")
        XCTAssertTrue(backups.allSatisfy { $0.hasSuffix(".orig") })
        // The first-write backup is the user's file as it was (mutant: drop the backup).
        let orig = try XCTUnwrap(backups.first { $0.hasPrefix("claude/settings.json.") })
        XCTAssertEqual(env.read(env.backups.appendingPathComponent(orig)), "{\n  \"theme\": \"dark\"\n}\n")
    }

    // MARK: 2.8-3 drift

    func test3DriftMissingAndCorruptStates() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        let applied = try XCTUnwrap(env.read(env.claudeMD))

        try env.write(applied.replacingOccurrences(of: "Follow the kit rules.", with: "Follow the kit rules.\nhand edit"), env.claudeMD)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.drifted])
        let refused = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(refused.refusals.map(\.reason), [.drifted])
        let repaired = await env.mc.repair(owner: env.owner)
        XCTAssertEqual(repaired.status, .done)
        XCTAssertTrue(env.consent.seen.last?.files.first?.lines.contains(.init(sign: .removed, text: "hand edit")) ?? false,
                      "Repair shows the hand edit it overwrites")
        XCTAssertEqual(env.read(env.claudeMD), applied)

        try env.write("# mine\n", env.claudeMD)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.missing])
        let missing = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(missing.refusals.map(\.reason), [.missing])

        try env.write(applied.replacingOccurrences(of: "<!-- <<< prosper:kit-a:rules <<< -->", with: ""), env.claudeMD)
        let corrupt = try XCTUnwrap(env.read(env.claudeMD))
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.corrupt])
        let a = await env.mc.apply([MCPieces.block()], owner: env.owner)
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(a.status, .refused)
        XCTAssertEqual(r.status, .refused)
        XCTAssertTrue(r.message.contains("line(s) 3"), r.message)
        XCTAssertEqual(env.read(env.claudeMD), corrupt, "a corrupt piece is never written")
    }

    func testRemovingADriftedBlockShowsTheLostEditsFirst() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        try env.write(try XCTUnwrap(env.read(env.claudeMD)).replacingOccurrences(of: "Follow the kit rules.", with: "my own line"), env.claudeMD)
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertTrue(env.consent.seen.last?.files.first?.lines.contains(.init(sign: .removed, text: "my own line")) ?? false)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
    }

    // MARK: 2.8-4 hooks append

    func test4HookAppendLeavesTheUsersSameMatcherGroup() async throws {
        let env = makeMCEnv()
        let original = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": "my-own-check"}]
              }
            ]
          }
        }

        """
        try env.write(original, env.settings)
        let r = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        let doc = try OrderedJSON(try XCTUnwrap(env.read(env.settings)))
        guard case .array(let groups)? = doc.node(at: ["hooks", "PreToolUse"])?.value else { return XCTFail("no PreToolUse array") }
        XCTAssertEqual(groups.count, 2, "a new element, never merged into the user's group")
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.settings), original, "the user's group and key stay; only ours left")

        // The user adds a same-matcher group AFTER ours: remove still takes ours, by deep equality.
        _ = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        let ours = try OrderedJSON(try XCTUnwrap(env.read(env.settings)))
        let later = #"{"matcher": "Bash", "hooks": [{"type": "command", "command": "added-later"}]}"#
        let withLater = String(decoding: ours.appendingElement(try OrderedJSON(later).root.value, toArrayAt: ["hooks", "PreToolUse"]), as: UTF8.self)
        try env.write(withLater, env.settings)
        _ = await env.mc.remove(owner: env.owner)
        let left = try XCTUnwrap(env.read(env.settings))
        XCTAssertTrue(left.contains("added-later") && left.contains("my-own-check") && !left.contains("kit-run pre"), left)
    }

    func test4HookContainersDroppedOnlyWhenProsperMadeThem() async throws {
        let env = makeMCEnv()
        let original = "{\n  \"hooks\": {\n    \"PostToolUse\": []\n  },\n  \"theme\": \"dark\"\n}\n"
        try env.write(original, env.settings)
        _ = await env.mc.apply([MCPieces.hook(), MCPieces.hook("post", event: "PostToolUse")], owner: env.owner)
        _ = await env.mc.apply([MCPieces.hook("pre-b", command: "kit-b pre")], owner: env.owner("kit-b"))
        _ = await env.mc.remove(owner: env.owner)
        let mid = try OrderedJSON(try XCTUnwrap(env.read(env.settings)))
        XCTAssertNotNil(mid.node(at: ["hooks", "PreToolUse"]), "kit-b still has a group there")
        _ = await env.mc.remove(owner: env.owner("kit-b"))
        XCTAssertEqual(env.read(env.settings), original, "PreToolUse made by Prosper is dropped; the user's PostToolUse and hooks stay")
    }

    /// Supervisor R1 reverses the first P1 rule here: a user group deep-equal to ours with no record
    /// looks exactly like lost state, so it is adopted and Remove takes it (and the containers that
    /// held only it). This is R1's documented cost.
    func test4UserGroupDeepEqualToOursIsAdopted() async throws {
        let env = makeMCEnv()
        let group = #"{"matcher": "Bash", "hooks": [{"type": "command", "command": "kit-run pre"}]}"#
        let original = "{\n  \"hooks\": {\n    \"PreToolUse\": [\n      \(group)\n    ]\n  }\n}\n"
        try env.write(original, env.settings)
        let r = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(r.pieces.map(\.action), [.adopt])
        XCTAssertEqual(env.read(env.settings), original, "adoption writes nothing")
        XCTAssertEqual(env.consent.seen.count, 0, "and asks nothing")
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.settings), "{}\n", "known cost: the hand-typed copy and its containers go")
    }

    // MARK: 2.8-5 union refcount

    func test5UnionRefcountAcrossOwnersAndUserEntries() async throws {
        let env = makeMCEnv()
        let original = "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(git:*)\"\n    ]\n  }\n}\n"
        try env.write(original, env.settings)
        _ = await env.mc.apply([MCPieces.allow(["Bash(rtk:*)", "Bash(git:*)"])], owner: env.owner)
        _ = await env.mc.apply([MCPieces.allow(["Bash(rtk:*)"])], owner: env.owner("kit-b"))
        func allowList() throws -> [String] {
            guard case .array(let els)? = try OrderedJSON(try XCTUnwrap(env.read(env.settings))).node(at: ["permissions", "allow"])?.value else { return [] }
            return els.compactMap { if case .string(let s) = $0.value { return s } else { return nil } }
        }
        XCTAssertEqual(try allowList(), ["Bash(git:*)", "Bash(rtk:*)"])
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(try allowList(), ["Bash(git:*)", "Bash(rtk:*)"], "kit-b still claims rtk; git was the user's")
        _ = await env.mc.remove(owner: env.owner("kit-b"))
        XCTAssertEqual(env.read(env.settings), original)
    }

    // MARK: 2.8-6 set

    func test6StatusLineSetRestoreReplacedConflict() async throws {
        let env = makeMCEnv()
        let original = "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"my-line\"},\n  \"theme\": \"dark\"\n}\n"
        try env.write(original, env.settings)
        _ = await env.mc.apply([MCPieces.statusLine()], owner: env.owner)
        XCTAssertTrue(try XCTUnwrap(env.read(env.settings)).contains("kit-status"))
        let conflict = await env.mc.apply([MCPieces.statusLine(command: "other")], owner: env.owner("kit-b"))
        XCTAssertEqual(conflict.refusals.map(\.reason), [.conflict(owner: "kit-a")])
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.settings), original, "previous value restored byte for byte")

        _ = await env.mc.apply([MCPieces.statusLine()], owner: env.owner)
        let mine = try XCTUnwrap(env.read(env.settings)).replacingOccurrences(of: "kit-status", with: "my-new-line")
        try env.write(mine, env.settings)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.replaced])
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.pieces, [.init(id: "status", action: .keep)])
        XCTAssertEqual(env.read(env.settings), mine, "a slot the user changed is not clobbered")
    }

    func test6SetOnAbsentSlotIsRemovedAgain() async throws {
        let env = makeMCEnv()
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try env.write(original, env.settings)
        _ = await env.mc.apply([MCPieces.statusLine()], owner: env.owner)
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.settings), original)
    }

    /// r3 (R3-2): a restore that changes no byte appends no step, so it must not mark another step
    /// hidden. Reached by: the user's statusLine is written exactly as the planner renders it, a kit
    /// sets its own value over it, then updates its piece to the user's value. Remove then restores
    /// the user's raw text over identical bytes. The kit's `allow` removal earlier in the same file
    /// is the step the old code wrongly hid.
    func test6NoOpRestoreDoesNotHideTheStepBeforeIt() async throws {
        let env = makeMCEnv()
        let user = try OrderedJSON(#"{"type": "command", "command": "my-line"}"#).root.value
        let skeleton = "{\n  \"permissions\": {\n    \"allow\": [\"Mine(*)\"]\n  },\n  \"statusLine\": 0\n}\n"
        let original = String(decoding: try OrderedJSON(skeleton).replacingValue(at: ["statusLine"], with: user), as: UTF8.self)
        try env.write(original, env.settings)
        _ = await env.mc.apply([MCPieces.allow(["Kit(*)"]), MCPieces.statusLine()], owner: env.owner)
        XCTAssertTrue(try XCTUnwrap(env.read(env.settings)).contains("kit-status"))
        _ = await env.mc.apply([MCPieces.allow(["Kit(*)"]), MCPieces.statusLine(command: "my-line")], owner: env.owner)
        let updated = try XCTUnwrap(env.read(env.settings))
        XCTAssertEqual(updated.replacingOccurrences(of: #","Kit(*)""#, with: ""), original,
                       "precondition: the slot now holds the user's value in the user's own bytes")
        let seen = env.consent.seen.count
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.read(env.settings), original, "byte for byte")
        XCTAssertEqual(env.consent.seen.count, seen + 1)
        let lines = try XCTUnwrap(env.consent.seen.last?.files.first).lines
        XCTAssertFalse(lines.contains { $0.text == ManagedConfigChangeSet.userValueLine }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.text.contains("Mine(*)") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.sign == .removed && $0.text.contains("Kit(*)") }, "\(lines)")
    }

    // MARK: 2.8-7 key order and formatting

    func test7FortyKeyFixtureKeepsOrderAndFormatting() async throws {
        let env = makeMCEnv()
        var members: [String] = []
        for i in 0..<40 {
            let key = ["zeta", "alpha", "mike", "bravo"][i % 4] + "\(39 - i)"
            switch i % 5 {
            case 0: members.append("  \"\(key)\": 1.50")
            case 1: members.append("  \"\(key)\": \"caf\\u00e9 \\/ \\\"q\\\"\"")
            case 2: members.append("  \"\(key)\": [1,2,  3]")
            case 3: members.append("  \"\(key)\" : {\"b\": true, \"a\": null}")
            default: members.append("  \"\(key)\": 1e3")
            }
        }
        let original = "{\n" + members.joined(separator: ",\n") + "\n}\n"
        try env.write(original, env.settings)
        let pieces = [MCPieces.hook(), MCPieces.allow(["Read(*)"]), MCPieces.statusLine()]
        _ = await env.mc.apply(pieces, owner: env.owner)
        let applied = try XCTUnwrap(env.read(env.settings))
        let old = original.split(separator: "\n", omittingEmptySubsequences: false)
        let new = applied.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(Array(new.prefix(40)), Array(old.prefix(40)), "the brace and the first 39 members are untouched")
        XCTAssertEqual(new[40], old[40] + ",", "the last member only gains the separator")
        XCTAssertEqual(new.last, "", "final newline kept")
        XCTAssertEqual(new[new.count - 2], "}")
        let again = await env.mc.apply(pieces, owner: env.owner)
        XCTAssertEqual(again.status, .nothingToDo)
        XCTAssertEqual(env.read(env.settings), applied)
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.settings), original)
    }

    // MARK: 2.8-8 allowlist

    func test8AllowlistRefusesTheWholeSet() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let outside = env.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // QA #724 INFO-14: the link points at a temp file, never a real system file. Our own file there, so
        // the refusal is the type check (a link to another user's file needs a file this runner cannot make).
        try env.write("outside\n", outside.appendingPathComponent("x.txt"))
        try FileManager.default.createSymbolicLink(atPath: env.claude.appendingPathComponent("rootowned.md").path,
                                                   withDestinationPath: outside.appendingPathComponent("x.txt").path)
        let bad: [(ManagedConfigPiece, ManagedConfigRefusalReason)] = [
            (MCPieces.block("a", target: "claude:../x.md"), .badPath("'..' component")),
            (MCPieces.block("b", target: "claude:/etc/x.md"), .badPath("absolute path")),
            (MCPieces.block("c", target: "claude:../../etc/x"), .badPath("'..' component")),
            (MCPieces.block("d", target: "claude:sub/../CLAUDE.md"), .badPath("'..' component")),
            (MCPieces.block("e", target: "claude:rootowned.md"), .wrongKind("the symlink points to a different file type")),
            (ManagedConfigPiece(id: "f", kind: .json, target: "claude:settings.json", path: ["env", "FOO"], op: .set, value: "\"x\""),
             .refusedJSONPath("env.FOO")),
            (MCPieces.block("g", target: "claude:hook.sh"), .wrongKind("claude: blocks go in a .md file directly under the root")),
            (MCPieces.block("h", target: "claude:a/b/c/d/e.md"), .badPath("more than 4 components")),
            (MCPieces.block("i", target: "home:x.md"), .badPath("unknown root home:")),
            (MCPieces.block("j", target: "ext:CLAUDE.md"), .wrongKind("ext: is read-only")),
            (ManagedConfigPiece(id: "k", kind: .json, target: "claude:settings.json", path: ["permissions", "defaultMode"], op: .set, value: "\"x\""),
             .refusedJSONPath("permissions.defaultMode")),
            (ManagedConfigPiece(id: "l", kind: .json, target: "claude:settings.json", path: ["model"], op: .set, value: "\"x\""),
             .refusedJSONPath("model")),
            (ManagedConfigPiece(id: "m", kind: .json, target: "claude:settings.json", path: ["disableAllHooks"], op: .set, value: "true"),
             .refusedJSONPath("disableAllHooks")),
        ]
        for (piece, reason) in bad {
            let r = await env.mc.apply([MCPieces.block(), MCPieces.hook(), piece], owner: env.owner)
            XCTAssertEqual(r.status, .refused, piece.target)
            XCTAssertEqual(r.refusals.map(\.reason), [reason], piece.target)
        }
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n", "nothing written for the whole set")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.settings.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.state.path))
        XCTAssertTrue(env.consent.seen.isEmpty)
    }

    func test8KitconfigDirSymlinkEscapeAndForeignDirRefused() async throws {
        let env = makeMCEnv()
        let outside = env.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kitDir = env.config.appendingPathComponent("kit-a", isDirectory: true)
        try FileManager.default.createDirectory(at: kitDir, withIntermediateDirectories: true)
        try Data("kit-a\n".utf8).write(to: kitDir.appendingPathComponent(".prosper-kit"))
        try FileManager.default.createSymbolicLink(at: kitDir.appendingPathComponent("sub"), withDestinationURL: outside)
        let escape = await env.mc.apply([MCPieces.seed(target: "kitconfig:sub/x.md")], owner: env.owner)
        XCTAssertEqual(escape.refusals.map(\.reason), [.outsideRoot])

        let foreign = env.config.appendingPathComponent("git", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let git = ManagedConfigOwner(id: "git-kit", version: "1", kitSlug: "git", extensionDir: env.ext)
        let r = await env.mc.apply([MCPieces.seed()], owner: git)
        XCTAssertEqual(r.refusals.map(\.reason), [.foreignDir])
        XCTAssertEqual(env.files(under: foreign), [], "another program's dir is never written")
        XCTAssertEqual(env.files(under: outside), [])
    }

    func testSymlinkedTargetIsWrittenThroughAndStaysALink() async throws {
        let env = makeMCEnv()
        let dotfiles = env.root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("claude.md")
        try env.write("# from dotfiles\n", real)
        try FileManager.default.createSymbolicLink(at: env.claudeMD, withDestinationURL: real)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: env.claudeMD.path), real.path)
        XCTAssertTrue(try XCTUnwrap(env.read(real)).contains("prosper:kit-a:rules"))
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(real), "# from dotfiles\n")
    }

    /// Supervisor R2 (a): applied to a regular file, later moved into a dotfiles repo and linked back.
    /// Apply, Remove and status follow the link; the link stays a link.
    func testRemoveFollowsATargetThatBecameASymlink() async throws {
        for (piece, name, original) in [(MCPieces.hook(), "settings.json", "{\n  \"theme\": \"dark\"\n}\n"),
                                         (MCPieces.block(), "CLAUDE.md", "# mine\n")] {
          for reapply in [false, true] { // false: Remove is the first action after the move
            let env = makeMCEnv(label: "toLink-\(name)")
            let live = env.claude.appendingPathComponent(name)
            try env.write(original, live)
            let first = await env.mc.apply([piece], owner: env.owner)
            XCTAssertEqual(first.status, .done, name)
            let dotfiles = env.root.appendingPathComponent("dotfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            let real = dotfiles.appendingPathComponent(name)
            try FileManager.default.moveItem(at: live, to: real)
            try FileManager.default.createSymbolicLink(at: live, withDestinationURL: real)
            XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied], name)
            if reapply {
                let again = await env.mc.apply([piece], owner: env.owner)
                XCTAssertEqual(again.status, .done, "\(name): \(again.message)")
                XCTAssertEqual(again.pieces.map(\.action), [.noop], name)
            }
            let removed = await env.mc.remove(owner: env.owner)
            XCTAssertEqual(removed.status, .done, "\(name): \(removed.message)")
            XCTAssertEqual(removed.pieces.map(\.action), [.remove], name)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: live.path), real.path, "\(name): still a link")
            XCTAssertEqual(env.read(real), original, name)
          }
        }
    }

    /// Supervisor R2 (b): applied through a dotfiles link, later the link was replaced by a regular
    /// copy. Remove edits the live file and leaves the old dotfiles file alone.
    func testRemoveFollowsATargetWhoseSymlinkWasReplacedByAFile() async throws {
        for (piece, name, original) in [(MCPieces.hook(), "settings.json", "{\n  \"theme\": \"dark\"\n}\n"),
                                         (MCPieces.block(), "CLAUDE.md", "# mine\n")] {
            let env = makeMCEnv(label: "fromLink-\(name)")
            let live = env.claude.appendingPathComponent(name)
            let dotfiles = env.root.appendingPathComponent("dotfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            let real = dotfiles.appendingPathComponent(name)
            try env.write(original, real)
            try FileManager.default.createSymbolicLink(at: live, withDestinationURL: real)
            let first = await env.mc.apply([piece], owner: env.owner)
            XCTAssertEqual(first.status, .done, name)
            let dotApplied = env.bytes(real)
            try FileManager.default.removeItem(at: live)
            try FileManager.default.copyItem(at: real, to: live)
            let removed = await env.mc.remove(owner: env.owner)
            XCTAssertEqual(removed.status, .done, "\(name): \(removed.message)")
            XCTAssertEqual(removed.pieces.map(\.action), [.remove], name)
            XCTAssertEqual(env.read(live), original, "\(name): the live file is restored")
            XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: live.path), name)
            XCTAssertEqual(env.bytes(real), dotApplied, "\(name): the old dotfiles file is not touched")
        }
    }

    func testReadOnlyTargetIsUnwritable() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        chmod(env.claudeMD.path, 0o444)
        defer { chmod(env.claudeMD.path, 0o644) }
        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.refusals.map(\.reason), [.unwritable("read-only file")])
    }

    func testSettingsLocalJSONIsRefusedUnderClaudeRoot() async throws { // errata A8
        let env = makeMCEnv()
        let json = ManagedConfigPiece(id: "p", kind: .json, target: "claude:settings.local.json", path: ["permissions", "allow"],
                                      op: .union, value: "[\"Read(*)\"]")
        let block = MCPieces.block("q", target: "claude:settings.local.json")
        for piece in [json, block] {
            let r = await env.mc.apply([piece], owner: env.owner)
            XCTAssertEqual(r.refusals.map(\.reason), [.localSettings])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.claude.appendingPathComponent("settings.local.json").path))
    }

    // MARK: 2.8-9 atomicity, errata C9

    func test9WriterFailureLeavesTargetAndNoTempFile() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        env.writer.failReplace(true)
        let r = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(env.read(env.settings), "{\n  \"theme\": \"dark\"\n}\n")
        XCTAssertEqual(env.files(under: env.claude).filter { $0.contains(".prosper-") }, [])
        XCTAssertTrue(env.mc.status(owner: env.owner).isEmpty, "no state record for a failed write")
    }

    /// Supervisor R3: files land one by one; a failure on the second file reports only the first.
    func test9FailureOnTheSecondFileReportsOnlyWhatLanded() async throws {
        let env = makeMCEnv()
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try env.write("# mine\n", env.claudeMD)
        try env.write(original, env.settings)
        let pieces = [MCPieces.block(), MCPieces.hook()]
        env.writer.failReplace(true, only: "settings.json")
        let r = await env.mc.apply(pieces, owner: env.owner)
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(r.pieces, [.init(id: "rules", action: .insert)], "only the piece whose file landed")
        XCTAssertTrue(r.message.contains("claude:settings.json"), r.message)
        XCTAssertTrue(try XCTUnwrap(env.read(env.claudeMD)).contains("prosper:kit-a:rules"))
        XCTAssertEqual(env.read(env.settings), original)
        XCTAssertEqual(env.files(under: env.claude).filter { $0.contains(".prosper-") }, [])
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.id), ["rules"], "state matches disk after the first file")
        env.writer.failReplace(false)
        let mdRenames = env.writer.replaces(env.claudeMD)
        let done = await env.mc.apply(pieces, owner: env.owner)
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.pieces.map(\.action), [.noop, .insert])
        XCTAssertEqual(env.writer.replaces(env.claudeMD), mdRenames, "file 1 is not written again")
        XCTAssertTrue(try XCTUnwrap(env.read(env.settings)).contains("kit-run pre"))
    }

    func test9ChangeBetweenPlanAndApplyIsReplannedBeforeAnyWrite() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        let plan = env.mc.plan([MCPieces.hook()], owner: env.owner)
        try env.write("{\n  \"theme\": \"light\"\n}\n", env.settings) // Claude Code's /config, say
        let r = await env.mc.apply(plan)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.writer.temps(env.settings), 1, "the stale plan never reached a temp write (spec 2.5 step 1)")
        let text = try XCTUnwrap(env.read(env.settings))
        XCTAssertTrue(text.contains("\"light\"") && text.contains("kit-run pre"), text)
    }

    func testC9ConcurrentWriteBeforeRenameIsReplanned() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\",\n  \"verbose\": false\n}\n", env.settings)
        let settings = env.settings
        env.writer.interleave { target, n in
            if target.lastPathComponent == "settings.json", n == 1 {
                try? Data("{\n  \"theme\": \"light\",\n  \"verbose\": false\n}\n".utf8).write(to: settings)
            }
        }
        let r = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(env.writer.temps(env.settings), 2)
        let text = try XCTUnwrap(env.read(env.settings))
        XCTAssertTrue(text.contains("\"light\""), "the concurrent write is kept")
        XCTAssertTrue(text.contains("kit-run pre"))
        XCTAssertEqual(env.consent.seen.count, 1, "same diff after the replan: not asked twice")
        XCTAssertEqual(env.files(under: env.claude).filter { $0.contains(".prosper-") }, [])
    }

    func testC9ThreeReplansThenFileChangedRetry() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        let settings = env.settings
        env.writer.interleave { target, n in
            if target.lastPathComponent == "settings.json" { try? Data("{\n  \"theme\": \"user-\(n)\"\n}\n".utf8).write(to: settings) }
        }
        let r = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(r.status, .fileChanged)
        XCTAssertEqual(r.message, "file changed, retry")
        XCTAssertEqual(env.writer.temps(env.settings), 1 + ManagedConfig.maxReplans)
        XCTAssertEqual(env.read(env.settings), "{\n  \"theme\": \"user-4\"\n}\n", "the user's last bytes are never lost")
        XCTAssertEqual(env.files(under: env.claude).filter { $0.contains(".prosper-") }, [])
        XCTAssertTrue(env.mc.status(owner: env.owner).isEmpty)
    }

    // MARK: 2.8-10 modes, errata C10

    func test10ModesArePreservedAndBackupsArePrivate() async throws {
        let env = makeMCEnv()
        try env.write("{\n  \"theme\": \"dark\"\n}\n", env.settings)
        chmod(env.settings.path, 0o600)
        try env.write("# mine\n", env.claudeMD)
        chmod(env.claudeMD.path, 0o644)
        _ = await env.mc.apply([MCPieces.hook(), MCPieces.block()], owner: env.owner)
        XCTAssertEqual(env.mode(env.settings), 0o600)
        XCTAssertEqual(env.mode(env.claudeMD), 0o644)
        XCTAssertEqual(env.mode(env.state), 0o700)
        XCTAssertEqual(env.mode(env.backups), 0o700)
        XCTAssertEqual(env.mode(env.backups.appendingPathComponent("claude")), 0o700)
        XCTAssertEqual(env.mode(env.state.appendingPathComponent("state.json")), 0o600)
        let backups = env.files(under: env.backups).filter { $0.hasSuffix(".orig") }
        XCTAssertEqual(backups.count, 2)
        for b in backups { XCTAssertEqual(env.mode(env.backups.appendingPathComponent(b)), 0o600, b) }
    }

    func testC10BackupRetentionFirstWritePlusLastFive() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        for v in 1...8 {
            var owner = env.owner
            owner.version = "\(v).0.0"
            let r = await env.mc.apply([MCPieces.block()], owner: owner)
            XCTAssertEqual(r.status, .done)
        }
        let all = env.files(under: env.backups.appendingPathComponent("claude"))
        XCTAssertEqual(all.filter { $0.hasSuffix(".orig") }.count, 1)
        XCTAssertEqual(all.filter { $0.hasSuffix(".pre") }.count, ManagedConfig.preWriteBackupsKept)
        let orig = try XCTUnwrap(all.first { $0.hasSuffix(".orig") })
        XCTAssertEqual(env.read(env.backups.appendingPathComponent("claude/\(orig)")), "# mine\n")
        var last = env.owner
        last.version = "8.0.0"
        _ = await env.mc.remove(owner: last)
        let after = env.files(under: env.backups.appendingPathComponent("claude"))
        XCTAssertEqual(after.filter { $0.hasSuffix(".orig") }, [], "first-write backup goes with the last piece on the file")
        XCTAssertEqual(after.filter { $0.hasSuffix(".pre") }.count, ManagedConfig.preWriteBackupsKept)
    }

    // MARK: 2.8-11 crash adoption

    func test11BlockWithNoStateRecordIsAdopted() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        try FileManager.default.removeItem(at: env.state.appendingPathComponent("state.json")) // crash before the state write
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [])
        XCTAssertEqual(env.mc.status(owner: env.owner, declared: [MCPieces.block()]).map(\.state), [.adopted])
        XCTAssertEqual(env.mc.status(owner: env.owner, declared: [MCPieces.block()]).map(\.state), [.applied])
        XCTAssertEqual(env.mc.status(owner: env.owner, declared: [MCPieces.block("other")]).map(\.state), [.applied, .notApplied])
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
    }

    // MARK: 2.8-12 (P1 part): consent

    /// Supervisor R1: JSON values on disk with no record (crash before the state save, wiped
    /// Application Support, hand-deleted state.json) are adopted, never written a second time.
    func testLostStateAdoptsJSONValuesInsteadOfDuplicating() async throws {
        let env = makeMCEnv()
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try env.write(original, env.settings)
        let pieces = [MCPieces.hook(), MCPieces.statusLine()]
        let first = await env.mc.apply(pieces, owner: env.owner)
        XCTAssertEqual(first.status, .done)
        let applied = try XCTUnwrap(env.bytes(env.settings))
        let backups = env.files(under: env.backups)
        try FileManager.default.removeItem(at: env.state.appendingPathComponent("state.json"))
        let again = await env.mc.apply(pieces, owner: env.owner)
        XCTAssertEqual(again.status, .done)
        XCTAssertEqual(again.pieces.map(\.action), [.adopt, .adopt])
        XCTAssertEqual(env.bytes(env.settings), applied, "byte-identical: one group, one statusLine")
        XCTAssertEqual(env.files(under: env.backups), backups, "no second backup")
        XCTAssertEqual(env.consent.seen.count, 1, "adoption writes no user file and asks nothing")
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied, .applied])
        let removed = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(removed.status, .done)
        XCTAssertEqual(env.read(env.settings), original, "Remove takes the adopted group, its containers and the statusLine")
    }

    /// Supervisor F2: adoption never takes an element another record holds. Two owners with
    /// byte-identical groups get two elements; lost state still adopts both.
    func testTwoOwnersWithIdenticalHookGroupsKeepTwoElements() async throws {
        let env = makeMCEnv()
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try env.write(original, env.settings)
        let a = env.owner, b = env.owner("kit-b")
        func count() throws -> Int {
            let doc = try OrderedJSON(bytes: XCTUnwrap(env.bytes(env.settings)))
            guard case .array(let els)? = doc.node(at: ["hooks", "PreToolUse"])?.value else { return 0 }
            return els.count
        }
        let ra = await env.mc.apply([MCPieces.hook()], owner: a)
        let rb = await env.mc.apply([MCPieces.hook()], owner: b)
        XCTAssertEqual([ra.pieces.map(\.action), rb.pieces.map(\.action)], [[.insert], [.insert]])
        XCTAssertEqual(try count(), 2)
        _ = await env.mc.remove(owner: a)
        XCTAssertEqual(try count(), 1)
        XCTAssertEqual(env.mc.status(owner: b).map(\.state), [.applied])
        _ = await env.mc.remove(owner: b)
        XCTAssertEqual(env.read(env.settings), original)
        // lost state: both applied, state.json deleted; each owner adopts one of the two, nothing is written
        _ = await env.mc.apply([MCPieces.hook()], owner: a)
        _ = await env.mc.apply([MCPieces.hook()], owner: b)
        let both = try XCTUnwrap(env.bytes(env.settings))
        try FileManager.default.removeItem(at: env.state.appendingPathComponent("state.json"))
        let la = await env.mc.apply([MCPieces.hook()], owner: a)
        let lb = await env.mc.apply([MCPieces.hook()], owner: b)
        XCTAssertEqual([la.pieces.map(\.action), lb.pieces.map(\.action)], [[.adopt], [.adopt]])
        XCTAssertEqual(env.bytes(env.settings), both)
        XCTAssertEqual([env.mc.status(owner: a).count, env.mc.status(owner: b).count], [1, 1], "two records")
        _ = await env.mc.remove(owner: a)
        _ = await env.mc.remove(owner: b)
        XCTAssertEqual(env.read(env.settings), original, "the adopted copies and their containers go")
    }

    /// Supervisor F1: a state.json that exists but does not decode is never overwritten.
    func testUnreadableStateIsRefusedAndNeverOverwritten() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let first = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(first.status, .done)
        let stateURL = env.state.appendingPathComponent("state.json")
        try env.write(#"{"version": 99, "records": "written by a newer Prosper"}"#, stateURL)
        let stateBytes = env.bytes(stateURL)
        let md = env.bytes(env.claudeMD)
        let asked = env.consent.seen.count
        XCTAssertFalse(env.mc.stateIsReadable())
        let runs: [ManagedConfigResult] = [await env.mc.apply([MCPieces.block(), MCPieces.hook()], owner: env.owner),
                                           await env.mc.remove(owner: env.owner),
                                           await env.mc.repair(owner: env.owner)]
        for r in runs {
            XCTAssertEqual(r.status, .refused)
            XCTAssertEqual(r.refusals.map(\.reason), [.stateUnreadable])
        }
        // status with a declared block whose markers are on disk: reported, nothing adopted or written
        XCTAssertEqual(env.mc.status(owner: env.owner, declared: [MCPieces.block()]).map(\.state), [.notApplied])
        XCTAssertEqual(env.bytes(stateURL), stateBytes, "state.json byte-identical")
        XCTAssertEqual(env.bytes(env.claudeMD), md)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.settings.path))
        XCTAssertEqual(env.consent.seen.count, asked, "consent never asked")
    }

    func test12DeniedConsentWritesNothing() async throws {
        let env = makeMCEnv(consent: false)
        try env.write("# mine\n", env.claudeMD)
        let r = await env.mc.apply([MCPieces.block(), MCPieces.hook(), MCPieces.seed()], owner: env.owner)
        XCTAssertEqual(r.status, .denied)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.pieces, [], "QA #743 F1: nothing landed, nothing named")
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.settings.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.config.path), "no kitconfig dir before consent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.state.path))
        XCTAssertEqual(env.consent.seen.count, 1)
    }

    func testConsentModelListsFilesDiffBackupsAndHookSentences() async throws {
        let env = makeMCEnv()
        _ = await env.mc.apply([MCPieces.hook(), MCPieces.statusLine()], owner: env.owner)
        let set = try XCTUnwrap(env.consent.seen.first)
        XCTAssertEqual(set.action, .apply)
        XCTAssertEqual(set.owner, "kit-a")
        let file = try XCTUnwrap(set.files.first)
        XCTAssertEqual(file.path, env.settings.resolvingSymlinksInPath().path)
        XCTAssertTrue(file.backupDirectory.hasSuffix("/state/backups/claude"))
        XCTAssertTrue(file.lines.contains { $0.sign == .added && $0.text.contains("kit-run pre") })
        XCTAssertTrue(file.notes.contains("Claude Code will run `kit-run pre` on `PreToolUse` (`Bash`) in every session."))
        XCTAssertTrue(file.notes.contains("Claude Code will run `kit-status` as the status line in every session."))
        XCTAssertTrue(file.notes.contains("Applies to open Claude Code sessions immediately."))
        XCTAssertEqual(set.pieces, [.init(id: "pre", action: .insert), .init(id: "status", action: .insert)])
    }

    // MARK: errata C11

    func testC11EnvSecretNeverReachesConsentStateOrErrors() async throws {
        let env = makeMCEnv()
        let secret = "dummy-secret-not-real-0000"
        let original = "{\n  \"theme\": \"dark\",\n  \"env\": {\"ANTHROPIC_AUTH_TOKEN\": \"\(secret)\"}\n}\n"
        try env.write(original, env.settings)
        let refused = await env.mc.apply([ManagedConfigPiece(id: "e", kind: .json, target: "claude:settings.json",
                                                             path: ["env", "ANTHROPIC_AUTH_TOKEN"], op: .set, value: "\"x\"")], owner: env.owner)
        let r = await env.mc.apply([MCPieces.hook(), MCPieces.statusLine()], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        XCTAssertTrue(try XCTUnwrap(env.read(env.settings)).contains(secret), "the user's env is left in place")
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.settings), original)
        try env.write("{\n  \"env\": {\"K\": \"\(secret)\"},\n}\n", env.settings)
        let corrupt = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        XCTAssertEqual(corrupt.status, .refused)

        var surfaced = [refused.message, r.message, corrupt.message] + (refused.refusals + corrupt.refusals).map(\.description)
        for set in env.consent.seen {
            for f in set.files { surfaced += f.lines.map(\.text) + f.notes + [f.path, f.backupDirectory] }
        }
        XCTAssertTrue(env.consent.seen.flatMap(\.files).flatMap(\.lines).contains { $0.text == ManagedConfigChangeSet.maskedLine },
                      "the env line that gains a separator is masked")
        for s in surfaced { XCTAssertFalse(s.contains(secret), s) }
        XCTAssertFalse(try XCTUnwrap(env.read(env.state.appendingPathComponent("state.json"))).contains(secret))
    }

    // MARK: JSON edge files

    func testJSONMissingEmptyAndWhitespaceFilesRoundTrip() async throws {
        for initial in [nil, "", "\n  \n"] as [String?] {
            let env = makeMCEnv()
            if let initial { try env.write(initial, env.settings) }
            let r = await env.mc.apply([MCPieces.hook()], owner: env.owner)
            XCTAssertEqual(r.status, .done, initial.debugDescription)
            let doc = try OrderedJSON(try XCTUnwrap(env.read(env.settings)))
            XCTAssertNotNil(doc.node(at: ["hooks", "PreToolUse"]))
            if initial == nil { XCTAssertEqual(env.mode(env.settings), 0o600) }
            _ = await env.mc.remove(owner: env.owner)
            XCTAssertEqual(env.read(env.settings), initial, initial.debugDescription)
        }
    }

    func testInvalidJSONIsRefusedAndNeverRewritten() async throws {
        let cases = [
            ("{ \"a\": 1, }", "a trailing comma is not allowed"),
            ("{\n  // mine\n  \"a\": 1\n}\n", "comments are not allowed"),
            ("{\n  \"a\": 1,\n  \"a\": 2\n}\n", "duplicate key"),
            ("{ \"a\": [1, 2 }", "expected ',' or ']'"),
        ]
        for (text, reason) in cases {
            let env = makeMCEnv()
            try env.write(text, env.settings)
            let r = await env.mc.apply([MCPieces.hook()], owner: env.owner)
            XCTAssertEqual(r.status, .refused, text)
            XCTAssertTrue(r.message.contains(reason), r.message)
            XCTAssertEqual(env.read(env.settings), text)
            XCTAssertTrue(env.consent.seen.isEmpty)
        }
    }

    func testCRLFAndNoTrailingNewlineJSONKeptAsFound() async throws {
        let env = makeMCEnv()
        let original = "{\r\n  \"theme\": \"dark\"\r\n}"
        try env.write(original, env.settings)
        _ = await env.mc.apply([MCPieces.hook()], owner: env.owner)
        let text = try XCTUnwrap(env.read(env.settings))
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every new line is CRLF")
        XCTAssertFalse(text.hasSuffix("\n"))
        _ = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(env.read(env.settings), original)
    }

    // MARK: seed + kitconfig

    func testSeedCreatesOnceNeverOverwritesAndRemovesOnlyUnedited() async throws {
        let env = makeMCEnv()
        let r = await env.mc.apply([MCPieces.seed(), MCPieces.seed("notes", target: "kitconfig:my notes/today.md")], owner: env.owner)
        XCTAssertEqual(r.status, .done)
        let kitDir = env.config.appendingPathComponent("kit-a")
        XCTAssertEqual(env.mode(kitDir), 0o700)
        XCTAssertEqual(env.read(kitDir.appendingPathComponent(".prosper-kit")), "kit-a\n")
        let local = kitDir.appendingPathComponent("local.md")
        XCTAssertEqual(env.read(local), "# your local notes\n")
        XCTAssertEqual(env.read(kitDir.appendingPathComponent("my notes/today.md")), "# your local notes\n", "a path with a space")
        try env.write("# I wrote this\n", local)
        let again = await env.mc.apply([MCPieces.seed()], owner: env.owner)
        XCTAssertEqual(again.status, .nothingToDo)
        XCTAssertEqual(env.read(local), "# I wrote this\n", "never overwritten")
        let removed = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(Set(removed.pieces.map(\.action)), [.keep, .remove])
        XCTAssertEqual(env.read(local), "# I wrote this\n", "an edited seed is the user's now")
        XCTAssertFalse(FileManager.default.fileExists(atPath: kitDir.appendingPathComponent("my notes/today.md").path))
    }

    /// QA #724 INFO-15: the user file the link and `..` reach exists, so only the containment check
    /// stops the copy; each refusal is asserted by its reason.
    func testSeedSourceCannotLeaveTheExtensionDir() async throws {
        let env = makeMCEnv()
        try env.write("a user file\n", env.root.appendingPathComponent("extensions/x.md"))
        try env.write("a user file\n", env.root.appendingPathComponent("x.md"))
        try FileManager.default.createSymbolicLink(at: env.ext.appendingPathComponent("leak.md"), withDestinationURL: env.root.appendingPathComponent("x.md"))
        let cases: [(String, ManagedConfigRefusalReason)] = [
            ("ext:leak.md", .outsideRoot), ("ext:../x.md", .badPath("'..' component")), ("/etc/hosts", .invalidPiece("seed source must be ext:<path>")),
        ]
        for (source, reason) in cases {
            let r = await env.mc.apply([MCPieces.seed(source: source)], owner: env.owner)
            XCTAssertEqual(r.status, .refused, source)
            XCTAssertEqual(r.refusals.map(\.reason), [reason], source)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.config.appendingPathComponent("kit-a/local.md").path))
    }

    // MARK: status extras (errata A3, A12) and the production roots (A11)

    func testImportTargetMissingAndOrphanedStates() async throws {
        let env = makeMCEnv()
        let kitMD = env.ext.appendingPathComponent("CLAUDE.md").path.replacingOccurrences(of: " ", with: "\\ ")
        _ = await env.mc.apply([MCPieces.block(text: "@\(kitMD)")], owner: env.owner)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.applied])
        try FileManager.default.removeItem(at: env.ext.appendingPathComponent("CLAUDE.md"))
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.importMissing])
        try FileManager.default.removeItem(at: env.ext)
        XCTAssertEqual(env.mc.status(owner: env.owner).map(\.state), [.orphaned])
        let r = await env.mc.remove(owner: env.owner)
        XCTAssertEqual(r.status, .done, "Remove stays available for an orphan")
    }

    func testHooksDisabledAtUserScope() throws {
        let env = makeMCEnv()
        XCTAssertFalse(env.mc.hooksDisabledAtUserScope())
        try env.write("{\"disableAllHooks\": true}", env.settings)
        XCTAssertTrue(env.mc.hooksDisabledAtUserScope())
    }

    func testProductionRootsHonourClaudeConfigDirFromTheInjectedEnv() throws {
        let custom = try ManagedConfigRoots.production(loginEnvironment: ["CLAUDE_CONFIG_DIR": "/nonexistent/scratch-claude"]).get()
        XCTAssertEqual(custom.claude.path, "/nonexistent/scratch-claude")
        let plain = try ManagedConfigRoots.production(loginEnvironment: [:]).get()
        XCTAssertTrue(plain.claude.path.hasSuffix("/.claude"))
        XCTAssertTrue(plain.stateDir.path.hasSuffix("/Library/Application Support/Prosper/managed-config"))
        XCTAssertEqual(try ManagedConfigRoots.production(loginEnvironment: ["CLAUDE_CONFIG_DIR": ""]).get(), plain, "empty = unset")
    }

    /// A-INFO-12: a relative CLAUDE_CONFIG_DIR is refused by name, never swapped for ~/.claude. No I/O.
    func testRelativeClaudeConfigDirIsRefusedNotReplaced() {
        for dir in ["relative", "claude-dir/x", "./x"] {
            guard case .failure(let why) = ManagedConfigRoots.production(loginEnvironment: ["CLAUDE_CONFIG_DIR": dir]) else {
                return XCTFail("\(dir) was accepted")
            }
            XCTAssertTrue(why.description.contains("CLAUDE_CONFIG_DIR"), why.description)
        }
    }

    func testRemoveAndRepairOfUnknownIdsAreRefused() async {
        let env = makeMCEnv()
        let r = await env.mc.remove(owner: env.owner, ids: ["nope"])
        XCTAssertEqual(r.refusals.map(\.reason), [.unknownPiece])
        let other = await env.mc.apply([MCPieces.block()], owner: env.owner("kit-b"))
        XCTAssertEqual(other.status, .done)
        let cross = await env.mc.remove(owner: env.owner, ids: ["rules"])
        XCTAssertEqual(cross.refusals.map(\.reason), [.unknownPiece], "an owner sees only its own pieces")
    }
}
