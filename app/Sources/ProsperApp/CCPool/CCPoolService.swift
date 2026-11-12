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

    init(config: CCPoolServiceConfig, store: CCPoolStore, secrets: CCPoolSecrets, logger: CCPoolLogger = CCPoolOSLog()) {
        self.config = config
        self.store = store
        self.secrets = secrets
        self.logger = logger
    }

    var status: Status { lock.withLock { _status } }

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
            switch CCPoolPortProbe.probe(port: config.port, timeout: config.probeTimeout) {
            case .free: break
            case .ccpool(let pid, _):
                return finishStart(.heldByCCPool(pid: pid), note: "port held by another ccpool proxy; not binding")
            case .other:
                return finishStart(.heldByOther, note: "port held by another program; not binding")
            }
        }
        let l: NWListener
        do { l = try NWListener(using: Self.listenerParameters(port: config.port)) } catch {
            return finishStart(.failed("listener: \(error)"), note: "listener could not be created")
        }
        final class Outcome: @unchecked Sendable { var status: Status = .failed("bind timed out") }
        let outcome = Outcome()
        let sem = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak l] state in
            switch state {
            case .ready:
                outcome.status = .running(port: l?.port?.rawValue ?? 0)
                sem.signal()
            case .failed(let e), .waiting(let e):
                if case .posix(.EADDRINUSE) = e { outcome.status = .heldByOther } else { outcome.status = .failed("\(e)") }
                sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        guard case .running = outcome.status else {
            l.stateUpdateHandler = nil
            l.cancel()
            return finishStart(outcome.status, note: "listener did not start")
        }
        lock.withLock { listener = l }
        return finishStart(outcome.status, note: "proxy listening on loopback")
    }

    private func finishStart(_ s: Status, note: String) -> Status {
        lock.withLock { _status = s }
        logger.note(nil, note)
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
