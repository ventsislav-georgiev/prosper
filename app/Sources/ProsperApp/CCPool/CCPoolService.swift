import Foundation
import Network

struct CCPoolServiceConfig: Sendable {
    var port: UInt16 = CCPoolService.defaultPort
    /// Upstream base (Python `CCPOOL_UPSTREAM`), a test seam only.
    var upstream: URL = CCPoolService.productionUpstream
    /// Request bodies up to this are buffered and can be replayed on another account; larger ones
    /// are streamed upstream once (errata C1).
    var replayCap: Int = 32 << 20
    var timeout: TimeInterval = 900
    var exhaustedThreshold: Double = CCPoolCore.exhaustedDefault
    /// How long the start-up probe of an occupied port waits for an answer.
    var probeTimeout: TimeInterval = 2
    /// The start-up port probe, a test seam: a bound socket that is not listening makes the real
    /// probe wait for it, so only an injected "free" can stage the bind race start(bindRetry:) retries.
    var portProbe: @Sendable (_ port: UInt16, _ timeout: TimeInterval) -> CCPoolPortProbe.Result = CCPoolPortProbe.probe
    /// Test seam (QA follow-up A6): runs on start()'s thread after the listener said .ready and
    /// before it is published, so a test can deliver a state change into that window. nil in production.
    var afterReady: (@Sendable (NWListener) -> Void)? = nil
}

/// #871: the in-process ccpool proxy. HTTP/1.1 on Network.framework, loopback only. Clients point
/// `ANTHROPIC_BASE_URL` at it; every request is relayed upstream under the pool's current account,
/// and a quota 429 benches that account and replays the request on the next one before any byte
/// reaches the client. Nothing in the app starts it in P1.
///
/// Isolation: not actor-isolated. Listener callbacks run on `queue`, each connection on its own
/// serial queue, URLSession callbacks on per-session delegate queues; shared state is behind locks
/// (`CCPoolStore`, `lock` here). No closure handed to Network or URLSession comes from @MainActor code.
final class CCPoolService: @unchecked Sendable {
    static let defaultPort: UInt16 = 8790
    static let productionUpstream = URL(string: "https://api.anthropic.com")!
    static let healthPath = "/ccpool/health"
    static let serviceName = "ccpool-proxy"
    /// First token of the `Server` header: how a probe tells a ccpool proxy from anything else.
    static let serverHeader = "ccpool"

    enum Status: Equatable, Sendable {
        case stopped
        case running(port: UInt16)
        /// Another ccpool proxy (the Python one, or another Prosper) holds the port. Never killed.
        case heldByCCPool(pid: Int?)
        /// Something that is not ccpool holds the port.
        case heldByOther
        case failed(String)
    }

    let config: CCPoolServiceConfig
    let store: CCPoolStore
    let secrets: CCPoolSecrets
    let logger: CCPoolLogger
    let upstream = CCPoolUpstream()
    private let queue = DispatchQueue(label: "com.prosper.ccpool.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: CCPoolConnection] = [:]
    private var _status: Status = .stopped
    /// The last start() failed at bind time after the probe found the port free (TIME_WAIT, a
    /// socket bound but not listening): the case a brief retry can win.
    private var bindRaced = false

    /// Fixed reasons a `.failed` status carries (QA #739 INFO-11): never a raw system error text.
    static let reasonCreate = "the listener could not be created"
    static let reasonBind = "the port could not be bound"
    static let reasonTimeout = "the bind timed out"
    static let reasonLost = "the listener stopped after it started"

    init(config: CCPoolServiceConfig, store: CCPoolStore, secrets: CCPoolSecrets, logger: CCPoolLogger = CCPoolOSLog()) {
        self.config = config
        self.store = store
        self.secrets = secrets
        self.logger = logger
    }

    var status: Status { lock.withLock { _status } }

    /// The published listener (tests deliver its state changes through its own handler, A6).
    var currentListener: NWListener? { lock.withLock { listener } }

    /// QA #739 F1: new sessions route only while the listener runs AND the pool lists an account.
    var routable: Bool {
        guard case .running = status else { return false }
        return store.hasAccounts
    }

    /// The env delta for a new Agent Session (P2b's one call): base URL, health and accounts all
    /// come from this service, so no caller can route to a stopped proxy or an empty pool.
    func sessionEnv(command: [String], on: Bool) -> CCPool.EnvDelta {
        guard case .running(let port) = status else { return CCPool.EnvDelta() }
        return CCPool.sessionEnv(command: command, base: CCPool.baseURL(port: port), on: on, healthy: true,
                                 hasAccounts: store.hasAccounts)
    }

    /// Under XCTest the proxy never binds the production port and never dials the production
    /// upstream: the operator's own proxy may be on that port, and tests never reach the network.
    static func refusalUnderTest(_ config: CCPoolServiceConfig) -> String? {
        guard NSClassFromString("XCTestCase") != nil else { return nil }
        if config.port == defaultPort { return "ccpool: refusing the production port under XCTest" }
        if refusesUnderTest(config.upstream) { return "ccpool: refusing the production upstream under XCTest" }
        return nil
    }

    /// True under XCTest for the production upstream host: tests never dial it.
    static func refusesUnderTest(_ url: URL) -> Bool {
        NSClassFromString("XCTestCase") != nil && url.host?.lowercased() == productionUpstream.host
    }

    /// TCP on 127.0.0.1 only, loopback interface only. No address reuse: binding beside a live
    /// listener on the same port must fail, never share it.
    static func listenerParameters(port: UInt16) -> NWParameters {
        let p = NWParameters.tcp
        p.requiredInterfaceType = .loopback
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        p.allowLocalEndpointReuse = false
        return p
    }

    /// Bind and serve. Blocks up to a few seconds (port probe + bind): call it off the main thread.
    @discardableResult
    func start() -> Status {
        if case .running = status { return status }
        if let why = Self.refusalUnderTest(config) { return finishStart(.failed(why), note: why) }
        if config.port != 0 {
            switch config.portProbe(config.port, config.probeTimeout) {
            case .free: break
            case .ccpool(let pid, _):
                return finishStart(.heldByCCPool(pid: pid), note: "port held by another ccpool proxy; not binding")
            case .other:
                return finishStart(.heldByOther, note: "port held by another program; not binding")
            }
        }
        let l: NWListener
        do { l = try NWListener(using: Self.listenerParameters(port: config.port)) } catch {
            return finishStart(.failed(Self.reasonCreate), note: "listener could not be created", detail: " \(error)")
        }
        final class Outcome: @unchecked Sendable {
            var status: Status = .failed(CCPoolService.reasonTimeout)
            var inUse = false, settled = false
            /// A6 (b): a state change after .ready that came before start() published the listener.
            var lost = false
        }
        let outcome = Outcome()
        let sem = DispatchSemaphore(value: 0)
        // Runs on `queue` (Network's callbacks); formed in a nonisolated method, never @MainActor.
        l.stateUpdateHandler = { [weak self, weak l] state in
            // After .ready, every state but .ready/.setup means the listener no longer serves (A6):
            // .waiting (a), .failed, .cancelled. Before start() published it, `lost` tells start();
            // after, listenerLost() finds it by identity.
            if outcome.settled {
                // A freed listener is never the published one (the service holds that); and a nil
                // `from` would mean "the current listener" to listenerLost.
                guard let l else { return }
                switch state {
                case .waiting(let e), .failed(let e):
                    outcome.lost = true
                    self?.listenerLost(e, from: l)
                case .cancelled:
                    outcome.lost = true
                    self?.listenerLost(nil, from: l)
                default: break
                }
                return
            }
            switch state {
            case .ready:
                outcome.status = .running(port: l?.port?.rawValue ?? 0)
                outcome.settled = true
                sem.signal()
            case .failed(let e), .waiting(let e):
                if case .posix(.EADDRINUSE) = e { outcome.status = .heldByOther; outcome.inUse = true } else { outcome.status = .failed(CCPoolService.reasonBind) }
                outcome.settled = true
                sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        if case .running = outcome.status { config.afterReady?(l) }
        // A6 (b): decided on the listener's own queue, so a state change after .ready was either
        // seen above (`lost`) or runs after `listener = l` and is matched by identity.
        let published: Bool = queue.sync {
            outcome.settled = true   // a late .ready after the 5 s timeout changes nothing
            guard case .running = outcome.status else { return false }
            if outcome.lost { outcome.status = .failed(CCPoolService.reasonLost); return false }
            lock.withLock { listener = l }
            return true
        }
        guard published else {
            l.stateUpdateHandler = nil
            l.cancel()
            lock.withLock { bindRaced = outcome.inUse }
            return finishStart(outcome.status, note: "listener did not start")
        }
        return finishStart(outcome.status, note: "proxy listening on loopback")
    }

    /// P2a (d): start, and while the bind itself loses to a port the probe found free (P1 note 5:
    /// stop() then start() can meet TIME_WAIT; endpoint reuse stays off), retry for up to
    /// `bindRetry` seconds. A port held by a live listener is never retried. Blocks: off main only.
    @discardableResult
    func start(bindRetry: TimeInterval) -> Status {
        let deadline = Date().addingTimeInterval(bindRetry)
        while true {
            lock.withLock { bindRaced = false }
            let s = start()
            guard case .heldByOther = s, lock.withLock({ bindRaced }), Date() < deadline else { return s }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// The Settings "Restart proxy": a listener restart (B25). Blocks: off main only.
    @discardableResult
    func restart(bindRetry: TimeInterval = 3) -> Status {
        // Wait for the old listener to be gone: a probe racing its cancel would be answered by it
        // (and read as "another ccpool holds the port") or reset (read as "something else").
        let gone = DispatchSemaphore(value: 0)
        let old = lock.withLock { listener }
        old?.stateUpdateHandler = { if case .cancelled = $0 { gone.signal() } }
        stop()
        if old != nil { _ = gone.wait(timeout: .now() + 2) }
        return start(bindRetry: bindRetry)
    }

    /// Remove an account and drop its upstream URLSession with it (P2a follow-up e). False when the
    /// account is gone but its Keychain item could not be deleted (the caller says so).
    @discardableResult
    func removeAccount(label: String) throws -> Bool {
        let (id, deleted) = try store.removeAccount(label: label, secrets: secrets)
        upstream.drop(accountID: id)
        return deleted
    }

    /// QA #734 / A6: the running listener stopped serving (`from` nil means the current one; `error`
    /// nil for a cancel nobody asked for). The status says so and the listener is dropped, so the
    /// pane offers Start again and no session routes to it.
    func listenerLost(_ error: NWError?, from failed: NWListener? = nil) {
        let lost = lock.withLock { () -> NWListener? in
            guard let l = listener, failed == nil || failed === l else { return nil }
            listener = nil
            _status = .failed(Self.reasonLost)
            return l
        }
        guard let lost else { return }
        lost.stateUpdateHandler = nil
        lost.cancel()
        logger.note(nil, "listener stopped after start: \(error.map { "\($0)" } ?? "cancelled")")
    }

    private func finishStart(_ s: Status, note: String, detail: String = "") -> Status {
        lock.withLock { _status = s }
        if detail.isEmpty { logger.note(nil, note) } else { logger.note(nil, note, private: detail) }
        return s
    }

    deinit { listener?.cancel() }

    func stop() {
        let (l, conns) = lock.withLock { () -> (NWListener?, [CCPoolConnection]) in
            defer { listener = nil; connections.removeAll(); _status = .stopped }
            return (listener, Array(connections.values))
        }
        l?.cancel()
        conns.forEach { c in c.queue.async { c.close() } }
        upstream.invalidateAll()
    }

    private func accept(_ nw: NWConnection) {
        let port: UInt16
        if case .running(let p) = status { port = p } else { port = 0 }
        let c = CCPoolConnection(conn: nw, config: config, store: store, secrets: secrets, logger: logger,
                                 upstream: upstream, boundPort: port) { [weak self] id in
            self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) }
        }
        lock.withLock { connections[ObjectIdentifier(c)] = c }
        c.start()
    }

    /// The local health answer: names the proxy, never relayed upstream (B9). `current` is a label,
    /// returned to loopback only (errata C6).
    func healthBody() -> Data { Self.healthBody(store: store) }

    static func healthBody(store: CCPoolStore) -> Data {
        var obj: [String: Any] = ["service": Self.serviceName, "pid": Int(getpid()), "impl": "prosper"]
        obj["current"] = store.snapshot.current.map { $0 as Any } ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// What holds a loopback port (Python `ccpool_proxy.probe`): nothing, a ccpool proxy (first
/// `Server` header token "ccpool"; pid from its health answer when it has one), or anything else.
enum CCPoolPortProbe {
    enum Result: Equatable, Sendable {
        case free
        case ccpool(pid: Int?, impl: String?)
        case other
    }

    static func probe(port: UInt16, timeout: TimeInterval) -> Result {
        guard let p = NWEndpoint.Port(rawValue: port) else { return .other }
        let q = DispatchQueue(label: "com.prosper.ccpool.probe")
        let conn = NWConnection(host: .ipv4(.loopback), port: p, using: .tcp)
        final class Box: @unchecked Sendable {
            var data = Data()
            var result: Result?
            let sem = DispatchSemaphore(value: 0)
        }
        let box = Box()
        @Sendable func finish(_ r: Result) {
            guard box.result == nil else { return }
            box.result = r
            conn.cancel()
            box.sem.signal()
        }
        @Sendable func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                if let d { box.data.append(d) }
                if let r = parse(box.data, complete: done || err != nil || box.data.count > 1 << 16) { finish(r) } else { read() }
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let req = "GET \(CCPoolService.healthPath) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
                read()
            case .waiting(let e), .failed(let e):
                if case .posix(.ECONNREFUSED) = e { finish(.free) } else { finish(.other) }
            default: break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { finish(.other) }
        box.sem.wait()
        return q.sync { box.result ?? .other }
    }

    /// nil while more bytes are needed.
    static func parse(_ data: Data, complete: Bool) -> Result? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return complete ? .other : nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let fields = head.dropFirst().compactMap { line -> (String, String)? in
            guard let c = line.firstIndex(of: ":") else { return nil }
            return (line[..<c].lowercased(), line[line.index(after: c)...].trimmingCharacters(in: .whitespaces))
        }
        let server = fields.first { $0.0 == "server" }?.1 ?? ""
        guard server.split(separator: " ").first.map(String.init) == CCPoolService.serverHeader else { return .other }
        let body = data[end.upperBound...]
        if !complete, let len = fields.first(where: { $0.0 == "content-length" }).flatMap({ Int($0.1) }), body.count < len { return nil }
        if !complete, fields.first(where: { $0.0 == "content-length" }) == nil { return nil }
        let ok = head.first?.split(separator: " ").dropFirst().first == "200"
        guard ok, let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else { return .ccpool(pid: nil, impl: nil) }
        return .ccpool(pid: obj["pid"] as? Int, impl: obj["impl"] as? String)
    }
}
