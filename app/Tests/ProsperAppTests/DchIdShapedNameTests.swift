import Network
import os
import XCTest
@testable import ProsperApp

/// #850: dch 1.46.1 serve refuses a session_id-shaped new name (attach/create, serve.c:998) and alias
/// (rename, serve.c:1159) with 0x13 "name looks like a session_id", before any dch runs. Every dch here
/// is a recorder seam; frames go to sendOverride, the NWConnection never starts.
final class DchIdShapedNameTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var spawned: [[String]] = []
        var renamed: [[String]] = []
        var listed = 0
    }

    private func rig(listed names: [String] = []) -> (DchConnection, DispatchQueue, Calls) {
        let queue = DispatchQueue(label: "test.dchconn.idshaped")
        let calls = Calls()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { @Sendable _ in })
        conn.sendOverride = { f in calls.lock.withLock { calls.frames.append(f) } }
        conn.clipboard.enabled = { false }
        conn.commands.enabled = { false }
        let rows = names.map { DchListRow(name: $0, alias: "", activityEpoch: 1, state: "", agents: 0) }
        conn.listSessions = { calls.lock.withLock { calls.listed += 1 }; return rows }
        conn.kill = { _ in }
        conn.rename = { n, a in calls.lock.withLock { calls.renamed.append([n, a]) }; return nil }
        // A recorder that never forks: a spawn that got this far answers spawnFailed.
        conn.spawn = { _, args, _, _, _, _ in
            calls.lock.withLock { calls.spawned.append(args) }
            throw PtyChild.PtyError.forkFailed
        }
        addTeardownBlock { queue.sync { conn.close() } }
        return (conn, queue, calls)
    }

    private static let refusal = Data("{\"message\":\"name looks like a session_id\"}".utf8)
    private static let refusalFrame = Data([0x13, 0, 0, 0, 42]) + refusal

    private func frames(_ c: Calls) -> [Data] { c.lock.withLock { c.frames } }

    // MARK: - The predicate (dch's tests/xray_unit.c:88-101 cases, plus the any-case rule)

    func testPredicateMatchesDchEdges() {
        let yes = ["m0123456789abcdef", "M0123456789ABCDEF", "m0123456789AbCdEf", "M0123456789abcdef",
                   "  m0123456789abcdef", "m0123456789abcdef \n", "\tm0123456789abcdef\r", "\u{0B}m0123456789abcdef\u{0C}"]
        for s in yes { XCTAssertTrue(DchControlOps.idShaped(s), "\(s.debugDescription)") }
        let no = ["", "   ", "m", "M", "m0123456789abcde", "m0123456789abcdef0", "n0123456789abcdef",
                  "m0123456789abcdeg", "m0123456789abcdeG", "m0123456789abcdef x", "m 0123456789abcdef",
                  "m0123456789abcde\u{e9}", "\u{A0}m0123456789abcdef", "0123456789abcdefm", "mm0123456789abcdef"]
        for s in no { XCTAssertFalse(DchControlOps.idShaped(s), "\(s.debugDescription)") }
        XCTAssertEqual(DchControlOps.idShapedRefusal, "name looks like a session_id")
    }

    // MARK: - attach / create

    func testAnIdShapedNewNameIsRefusedOnAttachAndCreateBeforeAnySpawn() {
        for type in [DchFrame.attach, DchFrame.create] {
            for name in ["m0123456789abcdef", "M0123456789ABCDEF", " m0123456789abcdef"] {
                let (conn, queue, calls) = rig()
                queue.sync { conn.ingest(DchFrame.encode(type, json: ["name": name, "cols": 80, "rows": 24])) }
                XCTAssertEqual(frames(calls), [Self.refusalFrame], "0x\(String(type, radix: 16)) \(name.debugDescription)")
                XCTAssertEqual(calls.lock.withLock { calls.spawned }, [], "no dch spawned for \(name.debugDescription)")
            }
        }
    }

    /// #863: dch 1.46.1 serve.c:991-996 runs name_ok before :998, so a name padded with \t-\r (a control
    /// to cp_ctl) gets "invalid session name"; one padded with spaces passes name_ok and gets :1001's text.
    func testAPaddedIdShapedNameGetsNameOksRefusalFirst() {
        let invalid = DchControlOps.error("invalid session name")
        for type in [DchFrame.attach, DchFrame.create] {
            for name in ["\tm0123456789abcdef\r", "m0123456789abcdef\n", "\u{0B}M0123456789ABCDEF", "\u{0C}m0123456789abcdef "] {
                let (conn, queue, calls) = rig()
                queue.sync { conn.ingest(DchFrame.encode(type, json: ["name": name, "cols": 80, "rows": 24])) }
                XCTAssertEqual(frames(calls), [invalid], "0x\(String(type, radix: 16)) \(name.debugDescription)")
                XCTAssertEqual(calls.lock.withLock { calls.spawned }, [], "no dch spawned for \(name.debugDescription)")
            }
            for name in [" m0123456789abcdef", "m0123456789abcdef  "] {
                let (conn, queue, calls) = rig()
                queue.sync { conn.ingest(DchFrame.encode(type, json: ["name": name, "cols": 80, "rows": 24])) }
                XCTAssertEqual(frames(calls), [Self.refusalFrame], "spaces pass name_ok: \(name.debugDescription)")
            }
        }
    }

    func testAnOrdinaryNameStillSpawns() {
        for type in [DchFrame.attach, DchFrame.create] {
            for name in ["work", "m0123456789abcde", "m0123456789abcdef0"] {
                let (conn, queue, calls) = rig()
                queue.sync { conn.ingest(DchFrame.encode(type, json: ["name": name, "cols": 80, "rows": 24])) }
                XCTAssertEqual(calls.lock.withLock { calls.spawned.count }, 1, "\(name)")
                XCTAssertNotEqual(frames(calls).first, Self.refusalFrame, "\(name)")
                XCTAssertEqual(calls.lock.withLock { calls.listed }, 0, "only an id-shaped name lists: \(name)")
            }
        }
        let (conn, queue, calls) = rig()
        queue.sync { conn.ingest(DchFrame.encode(DchFrame.create, json: ["command": [] as [String]])) }
        XCTAssertEqual(calls.lock.withLock { calls.spawned.count }, 1, "a nameless create")
    }

    /// serve.c:998's session_listed: a legacy session listed under an id-shaped name keeps attaching by
    /// its exact name; a case or padding variant of it is not listed, so it is refused.
    func testALegacyListedIdNameAttachesByItsExactName() {
        let legacy = "m0123456789abcdef"
        for type in [DchFrame.attach, DchFrame.create] {
            let (conn, queue, calls) = rig(listed: ["other", legacy])
            queue.sync { conn.ingest(DchFrame.encode(type, json: ["name": legacy, "cols": 80, "rows": 24])) }
            XCTAssertEqual(calls.lock.withLock { calls.spawned }, [DchCommand.spawnArgs(name: legacy, command: [], attach: type == DchFrame.attach)])
            XCTAssertNotEqual(frames(calls).first, Self.refusalFrame)
            for variant in ["M0123456789ABCDEF", " m0123456789abcdef"] {
                let (conn, queue, calls) = rig(listed: [legacy])
                queue.sync { conn.ingest(DchFrame.encode(type, json: ["name": variant, "cols": 80, "rows": 24])) }
                XCTAssertEqual(frames(calls), [Self.refusalFrame], variant.debugDescription)
                XCTAssertEqual(calls.lock.withLock { calls.spawned }, [])
            }
        }
    }

    // MARK: - rename

    func testAnIdShapedAliasIsRefusedBeforeDchRuns() {
        for alias in ["m0123456789abcdef", "M0123456789ABCDEF", "m0123456789abcdef\n"] {
            for payload: [String: Any] in [["name": "work", "alias": alias], ["alias": alias]] {
                let (conn, queue, calls) = rig(listed: ["work"])
                queue.sync { conn.ingest(DchFrame.encode(DchFrame.rename, json: payload)) }
                XCTAssertEqual(frames(calls), [Self.refusalFrame], "\(payload)")
                XCTAssertEqual(calls.lock.withLock { calls.renamed }, [], "no dch -m for \(payload)")
            }
        }
    }

    /// #863: dch 1.46.1 serve.c:1154-1158 refuses a name starting with "-" before :1159's alias check.
    func testADashNameWithAnIdShapedAliasGetsTheDashRefusal() {
        let dash = DchControlOps.error(DchControlOps.dashNameRefusal)
        for alias in ["m0123456789abcdef", "M0123456789ABCDEF\t"] {
            let (conn, queue, calls) = rig(listed: ["-work"])
            queue.sync { conn.ingest(DchFrame.encode(DchFrame.rename, json: ["name": "-work", "alias": alias])) }
            XCTAssertEqual(frames(calls), [dash], alias.debugDescription)
            XCTAssertEqual(calls.lock.withLock { calls.renamed }, [])
        }
        // Text only: a dash name with any other alias still runs dch -m (remote-frames.md, 0x06).
        let (conn, queue, calls) = rig()
        queue.sync { conn.ingest(DchFrame.encode(DchFrame.rename, json: ["name": "-work", "alias": "Work"])) }
        XCTAssertEqual(calls.lock.withLock { calls.renamed }, [["-work", "Work"]])
    }

    func testAnOrdinaryAliasAndAnIdShapedNameStillRename() {
        for (name, alias) in [("work", "Work"), ("work", ""), ("m0123456789abcdef", "Legacy")] {
            let (conn, queue, calls) = rig()
            queue.sync { conn.ingest(DchFrame.encode(DchFrame.rename, json: ["name": name, "alias": alias])) }
            XCTAssertEqual(calls.lock.withLock { calls.renamed }, [[name, alias]])
            XCTAssertEqual(frames(calls), [DchFrame.encode(DchFrame.ok, [])])
        }
    }
}
