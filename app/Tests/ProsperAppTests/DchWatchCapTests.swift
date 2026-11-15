import Network
import os
import XCTest
@testable import ProsperApp

/// #987: the global ceiling on live 0x2e streams. Fakes only: a hub on a manual clock, in-memory
/// sinks, a DchConnection with its send seam; no listener, no dch.
final class DchWatchCapTests: XCTestCase {
    private static let dir = "/tmp/dch-test-remote"

    private final class Sink: @unchecked Sendable {
        var frames: [Data] = []
        var closed = 0
        var completes = true
    }

    private final class Clock: @unchecked Sendable { var t: TimeInterval = 0 }

    private func hub(_ clock: Clock = Clock()) -> DchWatchHub {
        let h = DchWatchHub(now: { [clock] in clock.t }, schedule: { _, _ in {} })
        h.remoteDir = { Self.dir }
        h.sidekick = { DchSidekickOps.Value(pattern: "-qa", updated: 0) }
        h.island(Self.cache("a"))
        return h
    }

    private static func cache(_ state: String, _ s: AgentState = .working) -> DchWatchHub.Cache? {
        DchWatchHub.cache(island: [AgentSession(key: AgentSessionKey(dir: dir, name: state), alias: "", activity: 1, state: s, agents: 0)],
                          dirs: [dir], remote: dir)
    }

    @discardableResult
    private func open(_ h: DchWatchHub, _ sink: Sink, device: String) -> Bool {
        let id = ObjectIdentifier(sink)
        return h.open(id, device: device, send: { [sink] f, done in sink.frames.append(f); if sink.completes { done() } },
                      close: { [sink, h] in sink.closed += 1; h.remove(id) })
    }

    private func fill(_ h: DchWatchHub, _ n: Int) -> [Sink] {
        (0..<n).map { i in let s = Sink(); XCTAssertTrue(open(h, s, device: "dev-\(i)")); return s }
    }

    func testCeilingIsAdmittedAcrossManyDevicesAndOneOverIsRefused() {
        let h = hub()
        let sinks = fill(h, DchWatchHub.maxStreams)
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams)
        XCTAssertEqual(DchWatchHub.maxStreams, 32)
        let over = Sink()
        XCTAssertTrue(open(h, over, device: "one-more") == false, "one past the ceiling: refused")
        XCTAssertTrue(over.frames.isEmpty, "nothing is sent to a refused stream by the hub")
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams)
        XCTAssertEqual(sinks.map(\.closed).reduce(0, +), 0, "no live stream is closed for it")
    }

    func testAnEndedStreamFreesItsSlot() {
        let h = hub()
        let sinks = fill(h, DchWatchHub.maxStreams)
        h.remove(ObjectIdentifier(sinks[3]))
        XCTAssertTrue(open(h, Sink(), device: "late"))
        XCTAssertTrue(open(h, Sink(), device: "later") == false)
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams)
    }

    func testAStreamEndedTwiceFreesOneSlotOnly() {
        let h = hub()
        let sinks = fill(h, DchWatchHub.maxStreams)
        h.remove(ObjectIdentifier(sinks[0]))
        h.remove(ObjectIdentifier(sinks[0]))
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams - 1)
        XCTAssertTrue(open(h, Sink(), device: "x"))
        XCTAssertTrue(open(h, Sink(), device: "y") == false, "the second end freed nothing")
    }

    func testADeviceAtItsCapStillReplacesItsOldestWhenTheCeilingIsFull() {
        let h = hub()
        let four = (0..<DchWatchHub.maxPerDevice).map { _ in Sink() }
        for s in four { XCTAssertTrue(open(h, s, device: "phone")) }
        _ = fill(h, DchWatchHub.maxStreams - four.count)
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams)
        XCTAssertTrue(open(h, Sink(), device: "phone"), "evicting its oldest frees the slot it takes")
        XCTAssertEqual(four.map(\.closed), [1, 0, 0, 0])
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams)
    }

    func testEveryEndPathReleasesItsSlot() {
        // the island stopping, and its dir changing
        let ends: [(DchWatchHub) -> Void] = [
            { $0.island(nil) },
            { $0.remoteDir = { "/tmp/dch-test-default" }; $0.island(Self.cache("a")) },
        ]
        for end in ends {
            let h = hub(), sinks = fill(h, DchWatchHub.maxStreams)
            end(h)
            XCTAssertTrue(h.streams.isEmpty)
            XCTAssertEqual(sinks.map(\.closed).reduce(0, +), DchWatchHub.maxStreams)
            h.island(Self.cache("a"))
            h.remoteDir = { Self.dir }
            h.island(Self.cache("a"))
            XCTAssertEqual(fill(h, DchWatchHub.maxStreams).count, DchWatchHub.maxStreams, "every slot is free again")
        }
        // a phone that stops reading: its backlog overflows and the stream is dropped
        let clock = Clock(), h = hub(clock), stuck = Sink()
        stuck.completes = false
        _ = fill(h, DchWatchHub.maxStreams - 1)
        XCTAssertTrue(open(h, stuck, device: "stuck"))
        for i in 0..<DchWatchHub.maxBacklog {
            clock.t += 2
            h.island(Self.cache("a", i % 2 == 0 ? .idle : .done))
        }
        XCTAssertEqual(stuck.closed, 1)
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams - 1)
        XCTAssertTrue(open(h, Sink(), device: "after"))
    }

    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
    }

    private func connection(_ h: DchWatchHub, _ frames: Frames, device: String) -> (DchConnection, DispatchQueue) {
        let queue = DispatchQueue(label: "test.dchconn.cap")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        conn.watch = h
        conn.sendOverride = { f in frames.lock.withLock { frames.all.append(f) } }
        queue.sync { conn.handle(type: DchFrame.watch, payload: Data("{\"device_id\":\"\(device)\"}".utf8)) }
        return (conn, queue)
    }

    func testTheConnectionClosingAndTheServerStoppingReleaseAndTheOverflowGetsTheBusyReply() {
        let h = hub()
        let held = fill(h, DchWatchHub.maxStreams - 2)
        let f1 = Frames(), (c1, q1) = connection(h, f1, device: "p1")
        let f2 = Frames(), (c2, q2) = connection(h, f2, device: "p2")
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams)
        XCTAssertEqual(f1.all.count, 2)
        let f3 = Frames(), (c3, q3) = connection(h, f3, device: "p3")
        XCTAssertEqual(f3.all, [DchWatchHub.busy], "the refusal is the one reply, and the connection closes")
        XCTAssertEqual(f3.all.first?.first, DchFrame.error)
        let o = (try? JSONSerialization.jsonObject(with: f3.all.first.map { $0.subdata(in: 5..<$0.count) } ?? Data())) as? [String: Any]
        XCTAssertEqual(o?["code"] as? String, "busy")
        XCTAssertTrue((o?["message"] as? String ?? "").contains("\(DchWatchHub.maxStreams)"))
        XCTAssertFalse(q3.sync { c3.watching })
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams, "the refused connection holds no slot")
        q1.sync { c1.close() }
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams - 1)
        q2.sync { c2.serverStop() }
        XCTAssertEqual(h.streams.count, DchWatchHub.maxStreams - 2)
        let f4 = Frames(), (c4, q4) = connection(h, f4, device: "p4")
        XCTAssertEqual(f4.all.count, 2, "a freed slot admits the next connection")
        q4.sync { c4.close() }
        XCTAssertEqual(held.count, DchWatchHub.maxStreams - 2)
    }
}
