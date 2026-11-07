import Network
import os
import XCTest
@testable import ProsperApp

/// #765: the 0x2e watch stream and the list served from Agent Island's cache. The hub runs on
/// a fake clock and fake timers; frames go to in-memory sinks. No socket, no dch, no sleep.
final class DchWatchStreamTests: XCTestCase {
    /// Timers that fire only when the test advances the clock.
    private final class Timers: @unchecked Sendable {
        final class Job: @unchecked Sendable {
            let due: TimeInterval, work: @Sendable () -> Void
            var done = false
            init(due: TimeInterval, work: @escaping @Sendable () -> Void) { (self.due, self.work) = (due, work) }
        }
        var t: TimeInterval = 0
        var jobs: [Job] = []

        var schedule: DchWatchHub.Schedule {
            { [self] delay, work in
                let j = Job(due: t + delay, work: work)
                jobs.append(j)
                return { j.done = true }
            }
        }

        var live: [TimeInterval] { jobs.filter { !$0.done }.map(\.due).sorted() }

        func advance(to target: TimeInterval) {
            while let j = jobs.filter({ !$0.done && $0.due <= target }).min(by: { $0.due < $1.due }) {
                t = j.due
                j.done = true
                j.work()
            }
            t = target
        }
    }

    private final class Sink: @unchecked Sendable {
        var frames: [Data] = []
        /// Frame i, or empty when there is none (a failed count must not crash the run).
        subscript(i: Int) -> Data { i < frames.count ? frames[i] : Data() }
        var closed = 0
        /// false: the socket never takes a frame (a phone that stopped reading).
        var completes = true
    }

    private final class Value: @unchecked Sendable {
        var sidekick = DchSidekickOps.Value(pattern: "-qa", updated: 0)
    }

    private static let dir = "/tmp/dch-test-remote"

    private func hub(_ timers: Timers, _ value: Value = Value()) -> DchWatchHub {
        let h = DchWatchHub(now: { [timers] in timers.t }, schedule: timers.schedule)
        h.remoteDir = { Self.dir }
        h.sidekick = { [value] in value.sidekick }
        return h
    }

    private static func session(_ name: String, _ state: AgentState = .working, activity: TimeInterval = 100,
                                agents: Int = 0, dir: String = dir) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: "", activity: activity, state: state, agents: agents)
    }

    private static func cache(_ sessions: [AgentSession]) -> DchWatchHub.Cache? {
        DchWatchHub.cache(island: sessions, dirs: [dir], remote: dir)
    }

    private static func payload(_ sessions: [AgentSession]) -> Data { DchFrame.listPayload(cache(sessions)!.rows) }

    private func open(_ h: DchWatchHub, _ sink: Sink, device: String = "phone") -> (ObjectIdentifier, Bool) {
        let id = ObjectIdentifier(sink)
        let ok = h.open(id, device: device, send: { [sink] f, done in sink.frames.append(f); if sink.completes { done() } },
                        close: { [sink, h] in sink.closed += 1; h.remove(id) })
        return (id, ok)
    }

    private static func type(_ f: Data) -> UInt8 { f.first ?? 0 }
    private static func body(_ f: Data) -> Data { f.count > 5 ? f.subdata(in: 5..<f.count) : Data() }
    private static func json(_ f: Data) -> Any? { try? JSONSerialization.jsonObject(with: body(f)) }

    // MARK: - The stream

    func testSnapshotThenSidekick() {
        let timers = Timers(), value = Value(), h = hub(timers, value), sink = Sink()
        value.sidekick = .init(pattern: "-(qa|rev)$", updated: 1_784_995_200_000)
        h.island(Self.cache([Self.session("b"), Self.session("a", .blocked)]))
        XCTAssertTrue(open(h, sink).1)
        XCTAssertEqual(sink.frames.count, 2)
        XCTAssertEqual(Self.type(sink[0]), DchFrame.listResp)
        XCTAssertEqual(Self.body(sink[0]), Self.payload([Self.session("a", .blocked), Self.session("b")]))
        XCTAssertEqual(Self.type(sink[1]), DchFrame.ok)
        XCTAssertEqual(Self.json(sink[1]) as? NSDictionary,
                       ["sidekick": ["pattern": "-(qa|rev)$", "updated": 1_784_995_200_000]] as NSDictionary,
                       "the same pattern and updated 0x2d answers, under \"sidekick\"")
        XCTAssertEqual(DchFrame.watch, 0x2e)
    }

    /// The island publishes every activity tick and reorders by it; the phone's payload
    /// (name order, no activity) is unchanged, so nothing goes out and no flush is armed.
    func testUnchangedPayloadSendsNothing() {
        let timers = Timers(), h = hub(timers), sink = Sink()
        h.island(Self.cache([Self.session("a", activity: 1), Self.session("b", activity: 2)]))
        _ = open(h, sink)
        timers.advance(to: 5)
        h.island(Self.cache([Self.session("b", activity: 9), Self.session("a", activity: 8)]))
        XCTAssertEqual(sink.frames.count, 2)
        XCTAssertEqual(timers.live, [25], "only the heartbeat, armed by the snapshot")
    }

    func testCoalescesToOnePerSecondKeepingTheTrailingChange() {
        let timers = Timers(), h = hub(timers), sink = Sink()
        h.island(Self.cache([Self.session("a")]))
        _ = open(h, sink)
        timers.advance(to: 0.3)
        h.island(Self.cache([Self.session("a", .idle)]))
        timers.advance(to: 0.6)
        let last = [Self.session("a", .idle, agents: 2)]
        h.island(Self.cache(last))
        XCTAssertEqual(sink.frames.count, 2, "within a second of the snapshot: held")
        timers.advance(to: 0.99)
        XCTAssertEqual(sink.frames.count, 2)
        timers.advance(to: 1.0)
        XCTAssertEqual(sink.frames.count, 3, "one frame for the two changes")
        XCTAssertEqual(Self.type(sink[2]), DchFrame.listResp)
        XCTAssertEqual(Self.body(sink[2]), Self.payload(last), "the trailing change, not the first")
        // A change a second or more after the last list goes at once.
        timers.advance(to: 2.5)
        h.island(Self.cache([Self.session("a", .done)]))
        XCTAssertEqual(sink.frames.count, 4)
        XCTAssertEqual(Self.body(sink[3]), Self.payload([Self.session("a", .done)]))
        // A change that goes back to what was sent before its flush sends nothing.
        timers.advance(to: 2.7)
        h.island(Self.cache([Self.session("a", .blocked)]))
        h.island(Self.cache([Self.session("a", .done)]))
        timers.advance(to: 10)
        XCTAssertEqual(sink.frames.count, 4)
    }

    func testSidekickFrameOnPatternChange() {
        let timers = Timers(), value = Value(), h = hub(timers, value), sink = Sink()
        h.island(Self.cache([]))
        _ = open(h, sink)
        h.sidekickChanged()
        XCTAssertEqual(sink.frames.count, 2, "a row-details change that left the pattern alone sends nothing")
        XCTAssertEqual(timers.live, [25], "and arms nothing")
        timers.advance(to: 1)
        value.sidekick = .init(pattern: "-qa$", updated: 7)
        h.sidekickChanged()
        XCTAssertEqual(sink.frames.count, 3)
        XCTAssertEqual(Self.type(sink[2]), DchFrame.ok)
        XCTAssertEqual(Self.body(sink[2]), Self.body(DchSidekickOps.watchFrame(value.sidekick)))
        XCTAssertEqual(Self.json(sink[2]) as? NSDictionary, ["sidekick": ["pattern": "-qa$", "updated": 7]] as NSDictionary)
    }

    /// QA #606 INFO-5: Settings posts a change per keystroke; the phone gets one sidekick frame a
    /// second at most, the last edit kept, as the list.
    func testSidekickFramesCoalesceToOnePerSecondKeepingTheLastEdit() {
        let timers = Timers(), value = Value(), h = hub(timers, value), sink = Sink()
        h.island(Self.cache([]))
        let (id, _) = open(h, sink)   // the snapshot's sidekick frame at 0
        for (t, p) in [(0.2, "-q"), (0.5, "-qa"), (0.7, "-qa$")] {
            timers.advance(to: t)
            value.sidekick = .init(pattern: p, updated: Int64(t * 10))
            h.sidekickChanged()
        }
        XCTAssertEqual(sink.frames.count, 2, "within a second of the last sidekick frame: held")
        timers.advance(to: 0.99)
        XCTAssertEqual(sink.frames.count, 2)
        timers.advance(to: 1)
        XCTAssertEqual(sink.frames.count, 3, "one frame for the three edits")
        XCTAssertEqual(Self.json(sink[2]) as? NSDictionary, ["sidekick": ["pattern": "-qa$", "updated": 7]] as NSDictionary,
                       "the last edit, read when the gap ends")
        // An edit typed back to what the phone has before the gap ends sends nothing.
        timers.advance(to: 1.5)
        value.sidekick = .init(pattern: "-qa", updated: 15)
        h.sidekickChanged()
        value.sidekick = .init(pattern: "-qa$", updated: 7)
        timers.advance(to: 5)
        XCTAssertEqual(sink.frames.count, 3)
        // A second or more after the last one: at once.
        value.sidekick = .init(pattern: "-rev", updated: 50)
        h.sidekickChanged()
        XCTAssertEqual(sink.frames.count, 4)
        // A pending one goes with its stream.
        timers.advance(to: 5.5)
        value.sidekick = .init(pattern: "-x", updated: 55)
        h.sidekickChanged()
        h.remove(id)
        XCTAssertEqual(timers.live, [], "no sidekick timer outlives its stream")
        timers.advance(to: 10)
        XCTAssertEqual(sink.frames.count, 4)
    }

    func testHeartbeatEvery25SecondsOnlyWhileSilent() {
        let timers = Timers(), h = hub(timers), sink = Sink()
        h.island(Self.cache([Self.session("a")]))
        _ = open(h, sink)
        timers.advance(to: 20)
        h.island(Self.cache([Self.session("a", .idle)]))   // a list at 20 s: the heartbeat moves to 45 s
        XCTAssertEqual(sink.frames.count, 3)
        timers.advance(to: 44.9)
        XCTAssertEqual(sink.frames.count, 3, "no heartbeat 25 s after the snapshot: a list went since")
        timers.advance(to: 45)
        XCTAssertEqual(sink.frames.count, 4)
        XCTAssertEqual(Self.type(sink[3]), DchFrame.ok)
        XCTAssertEqual(Self.body(sink[3]), Data("{}".utf8))
        timers.advance(to: 70)
        XCTAssertEqual(sink.frames.count, 5, "and every 25 s of silence after")
        XCTAssertEqual(timers.live, [95])
    }

    func testFifthStreamOfADeviceClosesItsOldest() {
        let timers = Timers(), h = hub(timers)
        h.island(Self.cache([Self.session("a")]))
        let a = (0..<5).map { _ in Sink() }, b = Sink()
        _ = open(h, b, device: "100.64.0.8")   // the oldest of all, but another device's
        for s in a.prefix(4) { _ = open(h, s, device: "100.64.0.7") }
        XCTAssertEqual(a.map(\.closed), [0, 0, 0, 0, 0])
        XCTAssertEqual(timers.live.count, 5)
        _ = open(h, a[4], device: "100.64.0.7")
        XCTAssertEqual(a.map(\.closed), [1, 0, 0, 0, 0], "the oldest of that device only")
        XCTAssertEqual(b.closed, 0)
        XCTAssertEqual(h.streams.count, 5)
        XCTAssertFalse(h.streams.contains { $0.id == ObjectIdentifier(a[0]) })
        XCTAssertEqual(a[0].frames.count, 2)
        XCTAssertEqual(a[4].frames.count, 2, "the new stream still gets its snapshot")
        XCTAssertEqual(timers.live.count, 5, "the closed stream's heartbeat is cancelled")
        timers.advance(to: 30)
        XCTAssertEqual(a[0].frames.count, 2)
    }

    /// QA #606 INFO-7: Remote Terminal's dir changed under open streams (isolation toggled): the
    /// island's list is another dir's, so the streams close and the phone reconnects and polls.
    func testDirChangeClosesStreams() {
        let timers = Timers(), h = hub(timers), sink = Sink()
        h.island(Self.cache([Self.session("a")]))
        _ = open(h, sink)
        h.remoteDir = { "/tmp/dch-test-default" }
        h.island(Self.cache([Self.session("a", .idle)]))
        XCTAssertEqual(sink.closed, 1)
        XCTAssertEqual(sink.frames.count, 2, "no list of the old dir goes out")
        XCTAssertTrue(h.streams.isEmpty)
    }

    func testIslandStopClosesStreamsAndRefusesNewOnes() {
        let timers = Timers(), h = hub(timers), sink = Sink(), late = Sink()
        h.island(Self.cache([Self.session("a")]))
        _ = open(h, sink)
        h.island(nil)
        XCTAssertEqual(sink.closed, 1)
        XCTAssertTrue(h.streams.isEmpty)
        XCTAssertEqual(timers.live, [])
        XCTAssertFalse(open(h, late).1)
        XCTAssertEqual(late.frames, [])
    }

    func testAStreamWhosePhoneStopsReadingCloses() {
        let timers = Timers(), h = hub(timers), sink = Sink()
        sink.completes = false
        h.island(Self.cache([Self.session("a")]))
        _ = open(h, sink)
        timers.advance(to: 25 * Double(DchWatchHub.maxBacklog - 2))
        XCTAssertEqual(sink.frames.count, DchWatchHub.maxBacklog)
        XCTAssertEqual(sink.closed, 0)
        timers.advance(to: 25 * Double(DchWatchHub.maxBacklog - 1))
        XCTAssertEqual(sink.closed, 1)
        XCTAssertEqual(sink.frames.count, DchWatchHub.maxBacklog, "the frame past the backlog is not sent")
        XCTAssertEqual(timers.live, [])
    }

    // MARK: - The cache

    /// The island's rows encode to the bytes a fork of the same dch output does (meta,
    /// meta_epoch and the task counts old phones read included), in name order.
    func testCachedPayloadMatchesTheForkPayload() {
        let out = #"""
        [{"name":"a","alias":"","harness":"claude-a","activity_epoch":5,"state":"working","agents":2,"version":"1.28.0",
          "meta_epoch":1784995200,"meta":{"tasks":{"done":3,"total":7,"in_progress":1,"queued":2},
          "prs":{"open":[{"url":"https://github.com/o/prosper/pull/12","repo":"o/prosper","num":12,"title":"Fix"}],"merged":4}}},
         {"name":"b","alias":"Build","activity_epoch":6,"state":"blocked"},
         {"name":"c","activity_epoch":7,"state":"done"},{"name":"d","activity_epoch":8,"state":"idle"}]
        """#
        let island = AgentIsland.list(dirs: [Self.dir]) { args, _ in args == ["--ls-json"] ? Data(out.utf8) : nil }
        let fork = DchFrame.listPayload(DchCommand.parseListJSON(Data(out.utf8)))
        let cached = DchWatchHub.cache(island: Array(island.reversed()), dirs: [Self.dir], remote: Self.dir)
        XCTAssertEqual(cached.map { DchFrame.listPayload($0.rows) }, fork)
        let rows = (try? JSONSerialization.jsonObject(with: fork)) as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["meta_epoch"] as? Int, 1_784_995_200)
        XCTAssertEqual((rows.first?["meta"] as? [String: Any])?["tasks"] as? NSDictionary,
                       ["done": 3, "total": 7, "in_progress": 1, "queued": 2] as NSDictionary)
    }

    func testCacheOnlyForRemoteTerminalsDir() {
        let other = Self.session("x", dir: "/tmp/dch-test-default")
        XCTAssertNil(DchWatchHub.cache(island: nil, dirs: [Self.dir], remote: Self.dir), "the island stopped")
        XCTAssertNil(DchWatchHub.cache(island: [other], dirs: ["/tmp/dch-test-default"], remote: Self.dir),
                     "the island does not list Remote Terminal's dir: no cache, not an empty list")
        let c = DchWatchHub.cache(island: [other, Self.session("a")], dirs: ["/tmp/dch-test-default", Self.dir], remote: Self.dir)
        XCTAssertEqual(c?.rows.map(\.name), ["a"])
        // A cache for a dir that is no longer Remote Terminal's (isolation toggled) is none.
        let timers = Timers(), h = hub(timers)
        h.island(c)
        XCTAssertTrue(h.available())
        h.remoteDir = { "/tmp/dch-test-default" }
        XCTAssertFalse(h.available())
        XCTAssertNil(h.cachedList())
    }

    func testWatchInOps() {
        let ops = { (o: [String: Any]) in o["ops"] as? [String] ?? [] }
        XCTAssertTrue(ops(DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil, watch: true)).contains("watch"))
        XCTAssertFalse(ops(DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil)).contains("watch"))
        let timers = Timers(), h = hub(timers)
        XCTAssertFalse(h.available(), "no island list yet: the phone keeps polling")
        h.island(Self.cache([]))
        XCTAssertTrue(h.available(), "an empty list is a list")
    }

    // MARK: - Through DchConnection

    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
        var forks = 0
        var ran: [[String]] = []   // kill and rename, recorded: no test runs dch

        /// The first frame of `type`, waiting up to 5 s (a reply sent from off the queue).
        func first(_ type: UInt8) -> Data? {
            let end = Date().addingTimeInterval(5)
            repeat {
                if let f = lock.withLock({ all.first { $0.first == type } }) { return f }
                usleep(5_000)
            } while Date() < end
            return nil
        }
    }

    private func connection(_ h: DchWatchHub?, _ frames: Frames) -> (DchConnection, DispatchQueue) {
        let queue = DispatchQueue(label: "test.dchconn.watch")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        conn.watch = h
        conn.listSessions = { frames.lock.withLock { frames.forks += 1 }; return [DchListRow(name: "forked", alias: "", activityEpoch: 1, state: "idle", agents: 0)] }
        conn.sendOverride = { f in frames.lock.withLock { frames.all.append(f) } }
        conn.kill = { n in frames.lock.withLock { frames.ran.append(["-k", n]) } }
        conn.rename = { n, a in frames.lock.withLock { frames.ran.append(["-m", n, a]) } }
        var ops = DchControlOps()   // no binary: every verb refused, nothing forked
        ops.binary = { nil }
        ops.read = { _, _, _ in nil }
        ops.refresh = {}
        conn.ops = ops
        return (conn, queue)
    }

    private static func list(_ conn: DchConnection, _ queue: DispatchQueue) {
        queue.sync { conn.handle(type: DchFrame.list, payload: Data()) }
    }

    /// QA #606 F1: the phone relists right after a kill or rename and polls again 5-15 s later.
    /// dch has the change at once, the island a tick or a fetch later, and a publish that lands
    /// sooner than `settle` may carry a read from before it: the list forks until one lands after.
    func testListForksAfterKillOrRenameUntilAnIslandPublishSettles() {
        XCTAssertEqual(DchFrame.listChanging, [DchFrame.kill, DchFrame.rename, DchFrame.create,
                                               DchFrame.revive, DchFrame.restart, DchFrame.stop])
        for (type, ran) in [(DchFrame.kill, ["-k", "a"]), (DchFrame.rename, ["-m", "a", "A"])] {
            let timers = Timers(), h = hub(timers), frames = Frames()
            let (conn, queue) = connection(h, frames)
            queue.sync { h.island(Self.cache([Self.session("a"), Self.session("b")])) }
            Self.list(conn, queue)
            XCTAssertEqual(frames.forks, 0, "no change yet: the cache")
            queue.sync { conn.handle(type: type, payload: Data(#"{"name":"a","alias":"A"}"#.utf8)) }
            XCTAssertEqual(frames.ran, [ran])
            Self.list(conn, queue)
            XCTAssertEqual(frames.forks, 1, "the relist right after the reply: a fork")
            timers.advance(to: DchWatchHub.settle - 0.1)
            queue.sync { h.island(Self.cache([Self.session("a"), Self.session("b")])) }   // read before the change
            Self.list(conn, queue)
            XCTAssertEqual(frames.forks, 2, "a publish inside the settle window does not clear it")
            timers.advance(to: DchWatchHub.settle)
            queue.sync { h.island(Self.cache([Self.session("b")])) }
            Self.list(conn, queue)
            XCTAssertEqual(frames.forks, 2, "a publish settle s after: the cache again")
            XCTAssertEqual(frames.all.last.map(Self.body), Self.payload([Self.session("b")]))
        }
    }

    /// QA #606 F1: Stop, Restart and Resume run off the queue for as long as they take; their
    /// reply marks the list changed again, whatever the island published meanwhile.
    func testAControlVerbsReplyMarksTheListChanged() {
        let timers = Timers(), h = hub(timers), frames = Frames(), gate = DispatchSemaphore(value: 0)
        let (conn, queue) = connection(h, frames)
        conn.ops.binary = { _ = gate.wait(timeout: .now() + 5); return nil }
        queue.sync { h.island(Self.cache([Self.session("a")])) }
        queue.sync { conn.handle(type: DchFrame.stop, payload: Data(#"{"names":["a"]}"#.utf8)) }
        timers.advance(to: DchWatchHub.settle)
        queue.sync { h.island(Self.cache([Self.session("a")])) }
        Self.list(conn, queue)
        XCTAssertEqual(frames.forks, 0, "settled since it was sent")
        gate.signal()
        XCTAssertNotNil(frames.first(DchFrame.error), "Stop's reply (refused: no dch under XCTest)")
        Self.list(conn, queue)
        XCTAssertEqual(frames.forks, 1, "the reply marked it again")
    }

    /// QA #606 INFO-7: watch only on a connection of its own; one with a request in flight is refused.
    func testWatchRefusedWhileARequestIsInFlight() {
        let timers = Timers(), h = hub(timers), frames = Frames()
        let (conn, queue) = connection(h, frames)
        queue.sync { h.island(Self.cache([Self.session("a")])) }
        queue.sync {
            conn.handle(type: DchFrame.history, payload: Data())   // its reply comes back later, on the queue
            conn.handle(type: DchFrame.watch, payload: Data("{}".utf8))
        }
        let first = frames.lock.withLock { frames.all.first } ?? Data()
        XCTAssertEqual(Self.json(first) as? NSDictionary, ["message": "watch needs its own connection"] as NSDictionary)
        XCTAssertFalse(queue.sync { conn.watching })
        XCTAssertTrue(queue.sync { h.streams.isEmpty })
    }

    /// QA #606 INFO-7: machineInfoResp lists "watch" exactly while the hub has a list.
    func testMachineInfoAdvertisesWatchOnlyWithAnIslandList() {
        for listed in [true, false] {
            let h = hub(Timers()), frames = Frames()
            let (conn, queue) = connection(h, frames)
            if listed { queue.sync { h.island(Self.cache([])) } }
            queue.sync { conn.handle(type: DchFrame.machineInfo, payload: Data()) }
            let info = frames.first(DchFrame.machineInfoResp).flatMap(Self.json) as? [String: Any]
            XCTAssertNotNil(info)
            XCTAssertEqual((info?["ops"] as? [String] ?? []).contains("watch"), listed)
        }
    }

    /// QA #606 INFO-7: a watch stream is no keep-awake client; every other connection is.
    func testWatchStreamIsNoKeepAwakeClient() {
        let h = hub(Timers()), f1 = Frames(), f2 = Frames()
        let (watching, q1) = connection(h, f1), (plain, q2) = connection(h, f2)
        q1.sync { h.island(Self.cache([])) }
        XCTAssertEqual(DchSessionServer.keepAwakeClients([watching, plain]), 2)
        q1.sync { watching.handle(type: DchFrame.watch, payload: Data("{}".utf8)) }
        q2.sync { plain.handle(type: DchFrame.list, payload: Data()) }
        XCTAssertEqual(q1.sync { DchSessionServer.keepAwakeClients([watching, plain]) }, 1)
    }

    func testListServedFromTheIslandCacheWithoutAFork() {
        let timers = Timers(), h = hub(timers), frames = Frames()
        let sessions = [Self.session("a", .blocked, agents: 1)]
        h.island(Self.cache(sessions))
        let (conn, queue) = connection(h, frames)
        queue.sync { conn.handle(type: DchFrame.list, payload: Data()) }
        XCTAssertEqual(frames.forks, 0)
        XCTAssertEqual(frames.all.count, 1)
        XCTAssertEqual(Self.type(frames.all.first ?? Data()), DchFrame.listResp)
        XCTAssertEqual(Self.body(frames.all.first ?? Data()), Self.payload(sessions))
    }

    func testListForksWithoutACache() {
        let fallback = DchFrame.listPayload([DchListRow(name: "forked", alias: "", activityEpoch: 1, state: "idle", agents: 0)])
        for h in [nil, hub(Timers())] {
            let frames = Frames(), (conn, queue) = connection(h, frames)
            queue.sync { conn.handle(type: DchFrame.list, payload: Data()) }
            XCTAssertEqual(frames.forks, 1)
            XCTAssertEqual(frames.all.map(Self.body), [fallback])
            XCTAssertEqual(frames.all.map(Self.type), [DchFrame.listResp])
        }
    }

    func testWatchFrameOpensAStreamUntilTheConnectionCloses() {
        let timers = Timers(), h = hub(timers), frames = Frames()
        h.island(Self.cache([Self.session("a")]))
        let (conn, queue) = connection(h, frames)
        queue.sync { conn.handle(type: DchFrame.watch, payload: Data("{}".utf8)) }
        XCTAssertEqual(frames.all.map(Self.type), [DchFrame.listResp, DchFrame.ok])
        XCTAssertTrue(queue.sync { conn.watching })
        XCTAssertEqual(h.streams.map(\.device), ["127.0.0.1"], "{} carries no device_id: the peer address stands in")
        XCTAssertEqual(frames.forks, 0)
        queue.sync { conn.handle(type: DchFrame.attach, payload: Data(#"{"name":"a"}"#.utf8)) }
        XCTAssertEqual(Self.type(frames.all.last ?? Data()), DchFrame.error, "a watch connection never attaches")
        queue.sync { conn.close() }
        XCTAssertTrue(h.streams.isEmpty)
        XCTAssertEqual(timers.live, [], "no timer outlives the connection")
    }

    func testWatchRefusedWithoutAnIslandList() {
        let frames = Frames(), (conn, queue) = connection(hub(Timers()), frames)
        queue.sync { conn.handle(type: DchFrame.watch, payload: Data()) }
        XCTAssertEqual(frames.all.map(Self.type), [DchFrame.error])
        XCTAssertFalse(queue.sync { conn.watching })
        let h = hub(Timers())
        h.island(Self.cache([]))
        let f2 = Frames(), (c2, q2) = connection(h, f2)
        q2.sync { c2.handle(type: DchFrame.watch, payload: Data("[]".utf8)) }
        XCTAssertEqual(f2.all.map(Self.type), [DchFrame.error], "malformed")
        q2.sync { c2.handle(type: DchFrame.watch, payload: Data(#"{"device_id":"ABC"}"#.utf8)) }
        XCTAssertEqual(h.streams.map(\.device), ["ABC"])
    }
}
