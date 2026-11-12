import Network
import os
import XCTest
@testable import ProsperApp

/// #877: the 0x01 attach / 0x02 create name checks of dch serve's on_attach, in its order (serve.c:990-1011
/// @v1.54.0), each before any dch call; and an interactive Claude created from the phone named after its
/// session as a Mac New session is (AgentIsland.naming, #847). Every dch is a recorder seam; frames go to
/// sendOverride, the NWConnection never starts.
final class DchCreateNameTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var spawned: [[String]] = []
        var listed = 0
    }

    private func rig(listed names: [String] = []) -> (DchConnection, DispatchQueue, Calls) {
        let queue = DispatchQueue(label: "test.dchconn.createname")
        let calls = Calls()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { @Sendable _ in })
        conn.sendOverride = { f in calls.lock.withLock { calls.frames.append(f) } }
        conn.clipboard.enabled = { false }
        conn.commands.enabled = { false }
        let rows = names.map { DchListRow(name: $0, alias: "", activityEpoch: 1, state: "", agents: 0) }
        conn.listSessions = { calls.lock.withLock { calls.listed += 1 }; return rows }
        conn.kill = { _ in }
        conn.rename = { _, _ in nil }
        // A recorder that never forks: a spawn that got this far answers spawnFailed.
        conn.spawn = { _, args, _, _, _, _ in
            calls.lock.withLock { calls.spawned.append(args) }
            throw PtyChild.PtyError.forkFailed
        }
        addTeardownBlock { queue.sync { conn.close() } }
        return (conn, queue, calls)
    }

    /// One frame of `type` with `payload`: the frames sent back, the spawns, the list reads.
    private func send(_ type: UInt8, _ payload: [String: Any], listed: [String] = []) -> (frames: [Data], spawned: [[String]], listed: Int) {
        let (conn, queue, calls) = rig(listed: listed)
        queue.sync { conn.ingest(DchFrame.encode(type, json: payload)) }
        return calls.lock.withLock { (calls.frames, calls.spawned, calls.listed) }
    }

    private static let dash = DchControlOps.error(DchControlOps.dashNameRefusal)
    private static let invalid = DchControlOps.error(DchCtl.invalidName)
    private static let needsName = DchControlOps.error(DchConnection.needsName)
    private static let types = [DchFrame.attach, DchFrame.create]

    // MARK: - The dash (QA #722 INFO-2, #727 INFO-4)

    /// serve.c:999-1003: a first byte "-" gets DASH_MSG, attach and create, before name_ok (a "/" or a control
    /// after it changes nothing) and before the list is read; no dch runs.
    func testADashNameIsRefusedBeforeAnyDchCall() {
        XCTAssertEqual(DchControlOps.dashNameRefusal, "a session name starting with - can't be passed to dch")
        for type in Self.types {
            for name in ["-work", "--all", "-", "-kl", "-a/b", "-\tx", "-m0123456789abcdef", "-\u{301}x"] {
                let r = send(type, ["name": name, "command": ["claude"], "cols": 80, "rows": 24])
                XCTAssertEqual(r.frames, [Self.dash], "0x\(String(type, radix: 16)) \(name.debugDescription)")
                XCTAssertEqual(r.spawned, [], "no dch for \(name.debugDescription)")
                XCTAssertEqual(r.listed, 0, "no list read for \(name.debugDescription)")
            }
        }
    }

    /// dch serve refuses an attach to a listed session whose name starts with "-" too (the check is before
    /// session_listed): Prosper the same.
    func testAListedDashSessionIsRefusedToo() {
        let r = send(DchFrame.attach, ["name": "-old", "cols": 80, "rows": 24], listed: ["-old"])
        XCTAssertEqual(r.frames, [Self.dash])
        XCTAssertEqual(r.spawned, [])
    }

    /// QA #727 INFO-4: the first byte, not the first Character: "-" then a combining mark is one grapheme.
    func testTheDashTestIsTheFirstByte() {
        XCTAssertFalse("-\u{301}x".hasPrefix("-"), "the grapheme trap this guards against")
        XCTAssertEqual(DchCtl.nameRefusal("-\u{301}x"), DchControlOps.dashNameRefusal)
        XCTAssertFalse(DchCtl.nameOK("-\u{301}x"))
        XCTAssertTrue(DchCtl.isFlag("-\u{301}x"))
        let (conn, queue, calls) = rig(listed: ["-\u{301}x"])
        queue.sync { conn.ingest(DchFrame.encode(DchFrame.rename, json: ["name": "-\u{301}x", "alias": "m0123456789abcdef"])) }
        XCTAssertEqual(calls.lock.withLock { calls.frames }, [Self.dash], "rename's dash case reads the byte too")
    }

    // MARK: - name_ok for every name (QA #727 INFO-1)

    func testNameOkRefusesEveryBadNameBeforeAnyDchCall() {
        for type in Self.types {
            for name in ["\twork", "work\n", "a/b", "x\u{1b}[2J", "a\u{202e}b", "a\u{7f}", "a\u{85}b", "a\u{2066}b"] {
                let r = send(type, ["name": name, "cols": 80, "rows": 24])
                XCTAssertEqual(r.frames, [Self.invalid], "0x\(String(type, radix: 16)) \(name.debugDescription)")
                XCTAssertEqual(r.spawned, [], "no dch for \(name.debugDescription)")
                XCTAssertEqual(r.listed, 0)
            }
        }
    }

    /// QA #727 INFO-2: name_ok before the list, so a listed id-shaped name padded with a control is refused
    /// (it was attached), while #850's exact listed id name still attaches.
    func testNameOkComesBeforeTheListedCheck() {
        let padded = "\tm0123456789abcdef", legacy = "m0123456789abcdef"
        var r = send(DchFrame.attach, ["name": padded, "cols": 80, "rows": 24], listed: [padded])
        XCTAssertEqual(r.frames, [Self.invalid])
        XCTAssertEqual(r.spawned, [])
        XCTAssertEqual(r.listed, 0, "refused before the list is read")
        r = send(DchFrame.attach, ["name": legacy, "cols": 80, "rows": 24], listed: [legacy])
        XCTAssertEqual(r.spawned, [DchCommand.spawnArgs(name: legacy, command: [], attach: true)])
        XCTAssertEqual(r.listed, 1)
    }

    /// QA #727 INFO-3: 255 bytes runs; 256 fails name_ok (NAME_CAP 255); 257 or more does not fit jstr's
    /// name[NAME_CAP + 2], so serve answers "attach needs a session name" first, attach and create, a dash
    /// name too. Bytes, not Characters: 128 two-byte "é" are 256 bytes.
    func testNameLengthBoundsFollowServe() {
        for type in Self.types {
            let at255 = send(type, ["name": String(repeating: "a", count: 255)])
            XCTAssertEqual(at255.spawned.count, 1, "255 bytes run: 0x\(String(type, radix: 16))")
            XCTAssertEqual(send(type, ["name": String(repeating: "a", count: 256)]).frames, [Self.invalid])
            XCTAssertEqual(send(type, ["name": String(repeating: "\u{e9}", count: 128)]).frames, [Self.invalid])
            for name in [String(repeating: "a", count: 257), "-" + String(repeating: "a", count: 300)] {
                let r = send(type, ["name": name])
                XCTAssertEqual(r.frames, [Self.needsName], "\(name.utf8.count) bytes")
                XCTAssertEqual(r.spawned, [])
            }
        }
    }

    /// serve.c:990-996: a name that is no string, or an attach with no name or "", gets "attach needs a session
    /// name"; a create with none or "" runs (dch picks the name).
    func testAnUnreadableOrMissingNameFollowsServe() {
        for type in Self.types {
            for bad: Any in [42, NSNull(), ["x"]] {
                let r = send(type, ["name": bad, "cols": 80, "rows": 24])
                XCTAssertEqual(r.frames, [Self.needsName], "0x\(String(type, radix: 16)) \(bad)")
                XCTAssertEqual(r.spawned, [])
            }
        }
        for payload: [String: Any] in [[:], ["name": ""]] {
            XCTAssertEqual(send(DchFrame.attach, payload).frames, [Self.needsName], "\(payload)")
            XCTAssertEqual(send(DchFrame.create, payload).spawned, [["-E"]], "\(payload)")
        }
        XCTAssertEqual(DchConnection.needsName, "attach needs a session name")
    }

    // MARK: - Naming Claude (QA #725 INFO-1)

    private func spawned(_ name: String?, _ command: [String]) -> [String]? {
        var payload: [String: Any] = ["command": command, "cols": 80, "rows": 24]
        if let name { payload["name"] = name }
        return send(DchFrame.create, payload).spawned.first
    }

    func testAPhoneCreatedClaudeIsNamedAfterItsSession() {
        XCTAssertEqual(spawned("work", ["claude"]), ["-E", "-n", "work", "--", "claude", "--name", "work"])
        XCTAssertEqual(spawned("work", ["/opt/bin/claude", "--model", "opus"]),
                       ["-E", "-n", "work", "--", "/opt/bin/claude", "--name", "work", "--model", "opus"])
    }

    func testAnythingElseRunsAsSent() {
        XCTAssertEqual(spawned("work", ["/bin/zsh"]), ["-E", "-n", "work", "--", "/bin/zsh"], "a shell")
        XCTAssertEqual(spawned("work", ["claude", "-p", "hi"]), ["-E", "-n", "work", "--", "claude", "-p", "hi"], "claude -p")
        XCTAssertEqual(spawned("work", []), ["-E", "-n", "work"], "the default shell")
    }

    func testAnExistingNameIsReplacedNotDoubled() {
        XCTAssertEqual(spawned("work", ["claude", "--name", "old", "-c"]), ["-E", "-n", "work", "--", "claude", "--name", "work", "-c"])
        XCTAssertEqual(spawned("work", ["claude", "-n", "old"]), ["-E", "-n", "work", "--", "claude", "--name", "work"])
    }

    /// No name: dch picks one Prosper does not know beforehand, so Claude stays unnamed.
    func testNoNameLeavesClaudeUnnamed() {
        XCTAssertEqual(spawned(nil, ["claude"]), ["-E", "--", "claude"])
        XCTAssertEqual(spawned("", ["claude"]), ["-E", "--", "claude"])
    }
}
