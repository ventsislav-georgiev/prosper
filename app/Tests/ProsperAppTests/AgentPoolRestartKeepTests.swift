import Network
import XCTest
@testable import ProsperApp

/// #1672: a fake upstream on 127.0.0.1:<ephemeral> that streams slowly: each reply sends its head and first chunk, then
/// waits for one release() before the rest and the end of the stream. No network, dummy tokens only.
private final class AgentPoolSlowUpstream: @unchecked Sendable {
    static let first = Data("data: {\"type\":\"message_start\"}\n\n".utf8)
    static let rest = [Data("data: {\"type\":\"content_block_delta\",\"text\":\"held across restart\"}\n\n".utf8),
                       Data("data: {\"type\":\"message_stop\"}\n\n".utf8)]
    static var whole: Data { rest.reduce(first, +) }

    private let queue = DispatchQueue(label: "ccpool.test.slow")
    private let listener: NWListener
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var live: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: p)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } else if case .failed = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    /// Lets one held reply send the rest of its stream.
    func release() { gate.signal() }

    func stop() {
        listener.cancel()
        lock.withLock { live }.forEach { $0.cancel() }
    }

    private static func chunk(_ d: Data) -> Data {
        var out = Data((String(d.count, radix: 16) + "\r\n").utf8)
        out.append(d)
        out.append(Data("\r\n".utf8))
        return out
    }

    private func serve(_ c: NWConnection) {
        lock.withLock { live.append(c) }
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ pending: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = pending
            if let data { buf.append(data) }
            if case .head(_, let len, let rest)? = AgentPoolRequestHead.parse(buf), rest.count >= len {
                var out = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
                out.append(Self.chunk(Self.first))
                c.send(content: out, completion: .contentProcessed { [gate] _ in
                    DispatchQueue.global().async {
                        guard gate.wait(timeout: .now() + 30) == .success else { return c.cancel() }
                        var tail = Self.rest.reduce(Data()) { $0 + Self.chunk($1) }
                        tail.append(Data("0\r\n\r\n".utf8))
                        c.send(content: tail, completion: .idempotent)
                    }
                })
                return
            }
            if done || error != nil { return c.cancel() }
            self.read(c, buf)
        }
    }
}

private final class RestartCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var _refused = 0
    private var _stop = false
    func bump(refused: Bool) { lock.withLock { n += 1; if refused { _refused += 1 } } }
    var total: Int { lock.withLock { n } }
    var refused: Int { lock.withLock { _refused } }
    var stopped: Bool { get { lock.withLock { _stop } } set { lock.withLock { _stop = newValue } } }
}

/// A relay held open by the slow upstream: the client's bytes so far, and the whole exchange once it ends.
private final class HeldRelay: @unchecked Sendable {
    let firstSeen = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var seen = false
    private var _raw: Data?
    var raw: Data? { lock.withLock { _raw } }

    init(port: UInt16) {
        let payload = Data(#"{"model":"claude-opus-5","max_tokens":1,"stream":true}"#.utf8)
        let out = Data(("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\ncontent-type: application/json\r\n"
                        + "authorization: Bearer client-token-should-be-replaced\r\nContent-Length: \(payload.count)\r\n\r\n").utf8) + payload
        DispatchQueue.global().async { [self] in
            let raw = AgentPoolTestClient.exchange(port: port, send: out, timeout: 30) { [self] d in
                let first = lock.withLock { () -> Bool in
                    guard !seen, d.range(of: AgentPoolSlowUpstream.first) != nil else { return false }
                    seen = true
                    return true
                }
                if first { firstSeen.signal() }
            }
            lock.withLock { _raw = raw }
            done.signal()
        }
    }

    /// The relay ended with the whole stream, byte for byte, and its terminating chunk.
    var completedWhole: Bool {
        guard let raw, let r = AgentPoolTestClient.parse(raw), r.status == 200 else { return false }
        return r.body == AgentPoolSlowUpstream.whole && raw.suffix(5) == Data("0\r\n\r\n".utf8)
    }
}

private final class KeepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func bump() -> Int { lock.withLock { n += 1; return n } }
    var count: Int { lock.withLock { n } }
}

/// A bound, not listening socket on 127.0.0.1:<ephemeral>: the probe-to-bind race a retry is for. close() runs once.
private final class KeepBoundPort: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound else { Darwin.close(fd); throw XCTSkip("bind failed") }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
    }

    func close() {
        let f = lock.withLock { () -> Int32 in defer { fd = -1 }; return fd }
        if f >= 0 { Darwin.close(f) }
    }

    deinit { close() }
}

final class AgentPoolRestartKeepTests: XCTestCase {
    private struct Rig {
        let up: AgentPoolSlowUpstream
        let service: AgentPoolService
        let log: AgentPoolCapturingLogger
        let port: UInt16
    }

    private func rig() throws -> Rig {
        let up = try AgentPoolSlowUpstream()
        XCTAssertNotEqual(up.port, 0)
        let store = AgentPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = AgentPoolMemorySecrets()
        try store.addAccount(label: "api", token: "tok-api", secrets: secrets)
        let log = AgentPoolCapturingLogger()
        var cfg = AgentPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        let service = AgentPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        addTeardownBlock { service.stop(); up.stop() }
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        return Rig(up: up, service: service, log: log, port: p)
    }

    /// Restart while relays are mid-stream; returns how many completed whole of how many held.
    private func restartWithHeldRelays(_ r: Rig, count k: Int) -> Int {
        let held = (0..<k).map { _ in HeldRelay(port: r.port) }
        for h in held { XCTAssertEqual(h.firstSeen.wait(timeout: .now() + 15), .success, "the first chunk reached the client") }
        XCTAssertEqual(r.service.restart(), .running(port: r.port), "restarted on the same port")
        XCTAssertFalse(r.service.upstream.hasSession(accountID: idOf(r, "api")), "the idle upstream session was dropped")
        for _ in held { r.up.release() }
        for h in held { XCTAssertEqual(h.done.wait(timeout: .now() + 20), .success, "the relay ended") }
        return held.filter(\.completedWhole).count
    }

    private func idOf(_ r: Rig, _ label: String) -> String {
        r.service.store.snapshot.accounts[label]?.id ?? ""
    }

    // #1672 (F5): relays held mid-stream across Restart run to their end, byte for byte; a request after the restart is
    // served by the restarted state (a fresh upstream session).
    func testAgentPoolRestartKeepsInFlightRelaysByteExact() throws {
        let r = try rig()
        let listener = r.service.currentListener
        XCTAssertEqual(restartWithHeldRelays(r, count: 2), 2, "both relays completed byte-exact")
        XCTAssertTrue(listener != nil && r.service.currentListener === listener, "the listening socket was kept")
        XCTAssertEqual(r.log.lines.filter { $0.contains("proxy listening") }.count, 1, "one bind, at start")

        r.up.release()   // the next reply streams straight through
        let after = HeldRelay(port: r.port)
        XCTAssertEqual(after.done.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(after.completedWhole, "a new relay after the restart is served")
        XCTAssertTrue(r.service.upstream.hasSession(accountID: idOf(r, "api")), "on a fresh upstream session")
    }

    // #1678: Restart writes the held usage and event rows now (they otherwise wait for 64 rows or 5 s), the listener kept.
    func testAgentPoolRestartFlushesTheUsageAndEventRecords() throws {
        let r = try rig()
        let t = 1_800_000_000.25
        r.service.usageRecord.add(AgentPoolUsageRow(t: t, acct: "acct-example-1", model: "claude-opus-5", sess: nil, agent: nil,
                                                 path: "messages", st: 200, ms: 7, done: true, qc: false, att: 1, thr: 0,
                                                 mv: false, routed: "pick", harness: "claude", usage: nil, lim: [:]))
        r.service.eventRecord.add(AgentPoolEventRow(t: t, ev: .bench, acct: "Example Org A", from: nil, to: nil,
                                                 claim: "five_hour", reset: 1_900_000_000, sess: nil))
        r.service.usageRecord.settle()
        r.service.eventRecord.settle()
        func text(_ dir: URL) -> String {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.map { (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) ?? "" }.joined()
        }
        XCTAssertEqual(text(r.service.usageRecord.directory), "", "held, not yet written")
        XCTAssertEqual(text(r.service.eventRecord.directory), "")
        XCTAssertEqual(r.service.restart(), .running(port: r.port))
        XCTAssertTrue(text(r.service.usageRecord.directory).contains("\"acct\":\"acct-example-1\""), "the usage row is on disk")
        XCTAssertTrue(text(r.service.eventRecord.directory).contains("\"ev\":\"bench\""), "the event row is on disk")
    }

    // #1672 (F5): a client connecting in a loop across Restart is never refused (no unbound gap), and a relay held
    // across it completes. Prints the measured line.
    func testAgentPoolRestartRefusesNoConnectInALoop() throws {
        let r = try rig()
        let counts = RestartCount()
        let looped = DispatchSemaphore(value: 0)
        let port = r.port
        DispatchQueue.global().async {
            while !counts.stopped {
                counts.bump(refused: Self.connectRefused(port: port))
                usleep(5_000)
            }
            looped.signal()
        }
        let warm = Date().addingTimeInterval(10)
        while counts.total < 20, Date() < warm { usleep(10_000) }
        let k = 1
        let completed = restartWithHeldRelays(r, count: k)
        let atRestart = counts.total
        let cool = Date().addingTimeInterval(10)
        while counts.total < atRestart + 20, Date() < cool { usleep(10_000) }
        counts.stopped = true
        XCTAssertEqual(looped.wait(timeout: .now() + 10), .success)
        let m = counts.total, n = counts.refused
        print("MEASURE ccpool restart: refused \(n) of \(m), in-flight completed \(completed) of \(k)")
        XCTAssertGreaterThanOrEqual(m, 40, "connects before and after the restart")
        XCTAssertEqual(n, 0, "no connect refused across Restart")
        XCTAssertEqual(completed, k)
    }

    /// A service whose probe always says "free" on a port `held` binds (and is not listening on): every bind loses
    /// until `held` closes. `onProbe` gets the probe's call number.
    private func racedService(_ held: KeepBoundPort, store: AgentPoolStore? = nil, binds: KeepCounter,
                              onProbe: @escaping @Sendable (Int) -> Void = { _ in }) -> (AgentPoolService, AgentPoolCapturingLogger) {
        let probes = KeepCounter()
        var cfg = AgentPoolServiceConfig()
        cfg.port = held.port
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        cfg.portProbe = { _, _ in onProbe(probes.bump()); return .free }
        cfg.afterReady = { _ in _ = binds.bump() }
        let log = AgentPoolCapturingLogger()
        let svc = AgentPoolService(config: cfg, store: store ?? AgentPoolStore(directory: tempDir().appendingPathComponent("ccpool")),
                                secrets: AgentPoolMemorySecrets(), logger: log)
        addTeardownBlock { svc.stop() }
        return (svc, log)
    }

    // #1672 rider (R1665e n7): a toggle-off that lands during the probe of a retry tick is seen right before the bind:
    // the port is free by then and still nothing binds.
    func testAgentPoolBindRetryAsksStillWantedBeforeTheBind() throws {
        let held = try KeepBoundPort()
        let binds = KeepCounter(), wanted = KeepCounter()
        let (svc, log) = racedService(held, binds: binds) { n in
            if n == 2 { wanted.bump(); held.close() }   // the toggle-off, and the port frees with it
        }
        let began = Date()
        let s = svc.start(bindRetry: 30, stillWanted: { wanted.count == 0 })
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "out within a tick, not at the 30 s deadline")
        XCTAssertEqual(binds.count, 0, "no bind after the toggle-off")
        if case .running = s { XCTFail("nothing bound: \(s)") }
        XCTAssertEqual(log.lines.filter { $0.contains("start abandoned") }.count, 1, "\(log.lines)")
    }

    // #1672 rider (R1665e n7): the retry loop asks stillWanted on every tick, before the next probe: a toggle-off during
    // the tick's sleep costs no further probe and no bind.
    func testAgentPoolBindRetryAsksStillWantedOnEveryTick() throws {
        let held = try KeepBoundPort()
        let binds = KeepCounter(), asked = KeepCounter(), probes = KeepCounter()
        let (svc, _) = racedService(held, binds: binds) { _ in _ = probes.bump() }
        // Wanted at the first tick and its pre-bind check; the second tick's check is the toggle-off (the port frees too).
        let s = svc.start(bindRetry: 30, stillWanted: {
            let n = asked.bump()
            if n == 3 { held.close() }
            return n < 3
        })
        XCTAssertEqual(probes.count, 1, "the second tick stopped before its probe")
        XCTAssertEqual(binds.count, 0)
        if case .running = s { XCTFail("nothing bound: \(s)") }
    }

    // #1672 rider (R1665e n7): quit while the life cycle's start is in its TIME_WAIT retry. The retry sees shouldRun turn
    // false, so the quit's stop runs within its timeout, and no bind lands after it even once the port is free.
    func testAgentPoolQuitDuringABindRetryNeverBindsAfter() async throws {
        let held = try KeepBoundPort()
        let store = AgentPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        try store.addAccount(label: "api", token: "tok-api", secrets: AgentPoolMemorySecrets())
        let binds = KeepCounter(), probes = KeepCounter()
        let (svc, _) = racedService(held, store: store, binds: binds) { _ in _ = probes.bump() }
        let life = AgentPoolLifecycle(service: svc)
        life.live = true
        let settle = Task.detached { await life.settle() }
        let deadline = Date().addingTimeInterval(10)
        while probes.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThanOrEqual(probes.count, 2, "the start is retrying")
        let quick = life.quit(timeout: 2)
        if !quick { svc.stop() }   // AgentPoolRuntime.quit's fall-through
        held.close()               // the port is free: a retry still running would bind now
        await settle.value
        await life.settle()        // everything queued before has run
        XCTAssertTrue(quick, "the queued stop ran within the quit timeout")
        XCTAssertEqual(binds.count, 0, "no bind after quit")
        XCTAssertEqual(svc.status, .stopped)
    }

    /// One blocking connect to 127.0.0.1:`port`, closed at once. True only for ECONNREFUSED (nothing listening).
    private static func connectRefused(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc != 0 && errno == ECONNREFUSED
    }
}
