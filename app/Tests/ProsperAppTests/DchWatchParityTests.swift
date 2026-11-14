import Network
import os
import XCTest
@testable import ProsperApp

/// #1178: dch 1.66.0 serve parity of the 0x2e watch stream. Driven in process through DchConnection.ingest,
/// frames to an in-memory sink, the hub on a frozen clock whose timers never fire, kill and rename and the
/// pty spawn counted on recorders: no socket is opened, no dch and no process runs.
final class DchWatchParityTests: XCTestCase {
    private final class Rec: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var ran: [[String]] = []
        var spawns = 0
        var closes = 0
        var forks = 0
        var count: Int { lock.withLock { frames.count } }
        var last: Data { lock.withLock { frames.last } ?? Data() }
    }

    private static let dir = "/tmp/dch-test-1178"

    /// A hub holding a one-session island list for `dir`; its timers are recorded and never run.
    private static func hub() -> DchWatchHub {
        let h = DchWatchHub(now: { 0 }, schedule: { _, _ in {} })
        h.remoteDir = { dir }
        h.sidekick = { DchSidekickOps.Value(pattern: "-qa", updated: 0) }
        let api = AgentSession(key: AgentSessionKey(dir: dir, name: "api"), alias: "", activity: 100, state: .working, agents: 0)
        h.island(DchWatchHub.cache(island: [api], dirs: [dir], remote: dir))
        return h
    }

    private func connection(_ h: DchWatchHub, _ r: Rec) -> (DchConnection, DispatchQueue) {
        let queue = DispatchQueue(label: "test.dchconn.1178")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"),
                                 onClose: { _ in r.lock.withLock { r.closes += 1 } })
        conn.watch = h
        conn.sendOverride = { f in r.lock.withLock { r.frames.append(f) } }
        conn.kill = { n in r.lock.withLock { r.ran.append(["-k", n]) } }
        conn.rename = { n, a in r.lock.withLock { r.ran.append(["-m", n, a]) }; return nil }
        conn.listSessions = { r.lock.withLock { r.forks += 1 }; return [] }
        conn.spawn = { _, _, _, _, _, _ in
            r.lock.withLock { r.spawns += 1 }
            throw PtyChild.PtyError.forkFailed
        }
        var ops = DchControlOps()   // no binary: nothing forked
        ops.binary = { nil }
        ops.read = { _, _, _ in nil }
        ops.refresh = {}
        conn.ops = ops
        addTeardownBlock { queue.sync { conn.close() } }
        return (conn, queue)
    }

    private static func send(_ conn: DchConnection, _ queue: DispatchQueue, _ type: UInt8, _ body: String) {
        queue.sync { conn.ingest(DchFrame.encode(type, Array(body.utf8))) }
    }

    /// A connection that sent 0x2e and got its snapshot and sidekick frames.
    private func watching(_ h: DchWatchHub, _ r: Rec) -> (DchConnection, DispatchQueue) {
        let (conn, queue) = connection(h, r)
        Self.send(conn, queue, 0x2e, #"{"device_id":"fake-device-1"}"#)
        XCTAssertTrue(queue.sync { conn.watching })
        XCTAssertEqual(r.count, 2, "listResp, then ok {sidekick}")
        return (conn, queue)
    }

    /// serve v1.66.0 on_kill_rename (serve.c:1175-1179): a watch connection's 0x04 and 0x06 get one
    /// 0x13 with serve's text, run no dch, and the stream stays open; nothing marks the list changed.
    func testKillAndRenameOnAWatchStreamAreRefusedWithServesText() {
        let text = Data(#"{"message":"watch connections cannot kill or rename"}"#.utf8)
        let refusal = Data([0x13, 0, 0, 0, UInt8(text.count)]) + text
        for (type, body) in [(UInt8(0x04), #"{"name":"api"}"#), (UInt8(0x06), #"{"name":"api","alias":"api-qa"}"#)] {
            let h = Self.hub(), r = Rec()
            let (conn, queue) = watching(h, r)
            Self.send(conn, queue, type, body)
            XCTAssertEqual(r.count, 3, "one frame for \(type)")
            XCTAssertEqual(r.last, refusal, "\(type)")
            XCTAssertEqual(r.lock.withLock { r.ran }, [], "\(type): the fake dch -k / -m was never called")
            XCTAssertEqual(r.lock.withLock { r.closes }, 0, "\(type): the stream stays open")
            XCTAssertTrue(queue.sync { conn.watching })
            XCTAssertEqual(queue.sync { h.streams.count }, 1)
            XCTAssertTrue(queue.sync { h.listReply() != nil }, "\(type): no list change marked, the cache still serves")
        }
    }

    /// The refusal is the watch stream's only: on an ordinary connection kill and rename run as before.
    func testKillAndRenameOnAnOrdinaryConnectionStillRun() {
        let h = Self.hub(), r = Rec()
        let (conn, queue) = connection(h, r)
        Self.send(conn, queue, 0x04, #"{"name":"api"}"#)
        XCTAssertEqual(r.last, Data([0x14, 0, 0, 0, 0]))
        Self.send(conn, queue, 0x06, #"{"name":"api","alias":"api-qa"}"#)
        XCTAssertEqual(r.last, Data([0x14, 0, 0, 0, 0]))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.lock.withLock { r.ran }, [["-k", "api"], ["-m", "api", "api-qa"]])
        XCTAssertEqual(r.lock.withLock { r.closes }, 0)
    }

    /// Unchanged: attach and create on a watch stream keep their own refusal, and nothing spawns.
    func testAttachAndCreateOnAWatchStreamStillRefused() {
        let text = Data(#"{"message":"watch connections cannot attach or create"}"#.utf8)
        let refusal = Data([0x13, 0, 0, 0, UInt8(text.count)]) + text
        for type in [UInt8(0x01), UInt8(0x02)] {
            let h = Self.hub(), r = Rec()
            let (conn, queue) = watching(h, r)
            Self.send(conn, queue, type, #"{"name":"api","cols":80,"rows":24}"#)
            XCTAssertEqual(r.count, 3, "\(type)")
            XCTAssertEqual(r.last, refusal, "\(type)")
            XCTAssertEqual(r.lock.withLock { r.spawns }, 0, "\(type)")
            XCTAssertEqual(r.lock.withLock { r.closes }, 0, "\(type)")
            XCTAssertTrue(queue.sync { conn.watching })
        }
    }

    /// remote-frames.md: "Unknown frame types are ignored: no reply, the connection stays open". 0x35 with an
    /// empty body (dch issue 339's proposal, unserved here): no frame, no close, and the next 0x03 is answered.
    /// On a fresh connection and on a watch stream; an attached one takes the same `default: break` (no row:
    /// an attached connection needs a forked pty).
    func testUnknownFrameTypeIsIgnoredAndTheConnectionStaysOpen() {
        for watch in [false, true] {
            let h = Self.hub(), r = Rec()
            let (conn, queue) = watch ? watching(h, r) : connection(h, r)
            let before = r.count
            queue.sync { conn.ingest(Data([0x35, 0, 0, 0, 0])) }
            XCTAssertEqual(r.count, before, "watch \(watch): no reply")
            XCTAssertEqual(r.lock.withLock { r.closes }, 0, "watch \(watch): still open")
            Self.send(conn, queue, 0x03, "")
            XCTAssertEqual(r.count, before + 1, "watch \(watch)")
            XCTAssertEqual(r.last.first, 0x11, "watch \(watch): the list answered")
            XCTAssertEqual(r.lock.withLock { r.closes }, 0, "watch \(watch)")
        }
    }
}
