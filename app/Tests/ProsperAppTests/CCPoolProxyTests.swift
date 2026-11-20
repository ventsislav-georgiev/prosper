import Network
import XCTest
@testable import ProsperApp

// #871: proxy checks ported from test_ccpool_proxy.py, against a fake upstream on an ephemeral
// loopback port. No network, no production port (errata C4), dummy tokens only (C5). Every test
// method is synchronous and blocks the main thread while the request runs: any main-actor hop in
// the proxy would deadlock and fail the test (errata C7).

/// Minimal HTTP/1.1 server on 127.0.0.1:<ephemeral>, keep-alive, Content-Length framing.
final class CCPoolFakeServer: @unchecked Sendable {
    enum Reply {
        case respond(Int, [(String, String)], Data)
        /// Read the request, close without answering (a stale pooled connection).
        case drop
        /// A chunked reply whose first chunk is whole and whose next chunk is cut by a hang-up (sent on releaseCut()).
        case respondCut(Int, [(String, String)], Data)
    }

    private let queue = DispatchQueue(label: "ccpool.test.fake")
    private let listener: NWListener
    private let lock = NSLock()
    private var live: [NWConnection] = []
    private var _accepted = 0
    private var _dropReused = 0
    private var _reusedDropped = 0
    private var cutReleased = false
    private var pendingCut: (() -> Void)?
    private(set) var port: UInt16 = 0
    let handler: @Sendable (CCPoolRequestHead, Data) -> Reply

    init(handler: @escaping @Sendable (CCPoolRequestHead, Data) -> Reply) throws {
        self.handler = handler
        let p = NWParameters.tcp
        p.requiredInterfaceType = .loopback
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: p)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { sem.signal() }
            if case .failed = state { sem.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var accepted: Int { lock.withLock { _accepted } }
    /// Read the next `n` requests that arrive on an already-used connection, then close it without
    /// answering: a pooled connection the far end dropped (B17, QA #733 F1).
    func dropReused(_ n: Int) { lock.withLock { _dropReused = n } }
    var reusedDropped: Int { lock.withLock { _reusedDropped } }

    private func takeReusedDrop() -> Bool {
        lock.withLock {
            guard _dropReused > 0 else { return false }
            _dropReused -= 1
            _reusedDropped += 1
            return true
        }
    }

    /// #1594: a .respondCut sends its hang-up only now. URLSession drops bytes that arrive with the hang-up before it
    /// hands them to its delegate, so the cut waits until the caller has seen the first bytes go through.
    func releaseCut() {
        let cut = lock.withLock { () -> (() -> Void)? in
            cutReleased = true
            defer { pendingCut = nil }
            return pendingCut
        }
        cut?()
    }

    func stop() {
        listener.cancel()
        lock.withLock { live }.forEach { $0.cancel() }
    }

    private func serve(_ c: NWConnection) {
        lock.withLock { _accepted += 1; live.append(c) }
        c.start(queue: queue)
        read(c, Data(), served: 0)
    }

    private func read(_ c: NWConnection, _ pending: Data, served: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = pending
            var served = served
            if let data { buf.append(data) }
            while case .head(let h, let len, let rest)? = CCPoolRequestHead.parse(buf), rest.count >= len {
                buf = Data(rest.dropFirst(len))
                if served > 0, self.takeReusedDrop() {
                    c.cancel()
                    return
                }
                served += 1
                switch self.handler(h, Data(rest.prefix(len))) {
                case .drop:
                    c.cancel()
                    return
                case .respondCut(let status, let headers, let body):
                    // #1588: the first bytes go out as one whole chunk; the hang-up inside the next chunk is a second
                    // send. #1594: that send waits for releaseCut(): on a loaded host both sends reached URLSession
                    // together and it failed the task without handing the first chunk on (DIAG1594 in ticket2.log).
                    var head = "HTTP/1.1 \(status) X\r\n"
                    for (k, v) in headers { head += "\(k): \(v)\r\n" }
                    head += "Transfer-Encoding: chunked\r\n\r\n" + String(body.count, radix: 16) + "\r\n"
                    var out = Data(head.utf8)
                    out.append(body)
                    out.append(Data("\r\n".utf8))
                    let cut = { c.send(content: Data("40\r\npartial".utf8), completion: .contentProcessed { _ in c.cancel() }) }
                    c.send(content: out, completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        let now = self.lock.withLock { () -> Bool in
                            if !self.cutReleased { self.pendingCut = cut }
                            return self.cutReleased
                        }
                        if now { cut() }
                    })
                    return
                case .respond(let status, let headers, let body):
                    var head = "HTTP/1.1 \(status) X\r\n"
                    for (k, v) in headers { head += "\(k): \(v)\r\n" }
                    head += "Content-Length: \(body.count)\r\n\r\n"
                    var out = Data(head.utf8)
                    out.append(body)
                    c.send(content: out, completion: .idempotent)
                }
            }
            if done || error != nil { c.cancel(); return }
            self.read(c, buf, served: served)
        }
    }
}

/// Stands in for api.anthropic.com and decides per token, like the Python fake upstream.
final class CCPoolFakeAnthropic: @unchecked Sendable {
    private let lock = NSLock()
    var spent: Set<String> = []        // 429 with a spent five_hour
    var overload: Set<String> = []     // 429 with nothing spent
    var longWait: Set<String> = []     // 429, nothing spent, Retry-After 7200
    var full: Set<String> = []         // 200 reporting 100% used
    var big: Set<String> = []          // 200 with a 400 KB body
    var usage: [String: Double] = [:]  // five_hour utilization per token
    var dropNext = 0                   // close this many requests without an answer
    var reject: [String: Int] = [:]    // token -> 401/403, no rate-limit headers
    var overloadRetryAfter: String?    // Retry-After sent with an overload 429 (P2a follow-up a)
    var errorPad = 0                   // bytes of padding in a 429 error body (QA #733 INFO-3)
    var cutAfterFirstBytes: Set<String> = []   // 200 whose body is cut short, the connection hung up (B12 / 3.8-M2)
    private(set) var heads: [[String: String]] = []   // every request head received, names lowercased (B10)
    var gzipReply: Data?               // #1264: a 200 body sent gzip-encoded, only to a request that asked for gzip
    private(set) var acceptEncodings: [String] = []   // accept-encoding values received
    private(set) var gzipServed = 0
    private(set) var seen: [String] = []       // Authorization values answered, in order
    private(set) var apiKeys: [String] = []    // x-api-key values received
    private(set) var bodySizes: [Int] = []
    private(set) var bodies: [Data] = []      // #1605: every request body received, raw
    var fixedReply: (headers: [(String, String)], body: Data)?   // #1605: a 200 with exactly these headers and this body
    private(set) var paths: [String] = []
    private(set) var dropped = 0
    private(set) var onMain = false

    func set(_ body: (CCPoolFakeAnthropic) -> Void) { lock.withLock { body(self) } }
    func get<T>(_ body: (CCPoolFakeAnthropic) -> T) -> T { lock.withLock { body(self) } }
    func clearSeen() { lock.withLock { seen = []; apiKeys = []; bodySizes = []; paths = []; heads = [] } }

    func reply(_ head: CCPoolRequestHead, _ body: Data) -> CCPoolFakeServer.Reply {
        lock.withLock {
            if Thread.isMainThread { onMain = true }
            if dropNext > 0 { dropNext -= 1; dropped += 1; return .drop }
            let auth = head.header("authorization") ?? ""
            seen.append(auth)
            if let k = head.header("x-api-key") { apiKeys.append(k) }
            bodySizes.append(body.count)
            bodies.append(body)
            paths.append(head.path)
            heads.append(Dictionary(head.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }))
            let accept = head.header("accept-encoding")
            if let accept { acceptEncodings.append(accept) }
            let has = { (set: Set<String>) in set.contains { auth.contains($0) } }
            if let status = reject.first(where: { auth.contains($0.key) })?.value {
                return .respond(status, [("content-type", "application/json")],
                                Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid"}}"#.utf8))
            }
            let isSpent = has(spent), isOverload = has(overload), isLong = has(longWait)
            let reset = Int(Date().timeIntervalSince1970) + 3600
            let util = usage.first { auth.contains($0.key) }?.value
            var h: [(String, String)] = [
                ("5h-status", isSpent || (util ?? 0) >= 0.98 ? "rejected" : "allowed"),
                ("5h-utilization", isSpent || has(full) ? "1.0" : util.map { String($0) } ?? "0.42"),
                ("5h-reset", String(reset)),
                ("7d-status", "allowed"), ("7d-utilization", "0.10"), ("7d-reset", String(reset + 86400)),
                ("7d-overage-included-status", "allowed"), ("7d-overage-included-utilization", "0.34"),
                ("overage-status", "rejected"),
            ].map { ("anthropic-ratelimit-unified-\($0.0)", $0.1) }
            h.append(("content-type", "application/json"))
            let limited = isSpent || isOverload || isLong
            if isLong { h.append(("Retry-After", "7200")) }
            if isOverload, !isLong, let ra = overloadRetryAfter { h.append(("Retry-After", ra)) }
            var out = Data(limited ? #"{"type":"error","error":{"message":"limit\#(String(repeating: "p", count: errorPad))"}}"#.utf8
                : #"{"type":"message","content":[{"type":"text","text":"hi"}]}"#.utf8)
            if has(big), !limited { out = Data(#"{"type":"message","pad":""#.utf8) + Data(repeating: 120, count: 400_000) + Data(#""}"#.utf8) }
            if let gz = gzipReply, !limited, accept?.lowercased().contains("gzip") == true {
                h.append(("Content-Encoding", "gzip"))
                out = gz
                gzipServed += 1
            }
            if let f = fixedReply, !limited { return .respond(200, f.headers, f.body) }
            if has(cutAfterFirstBytes), !limited { return .respondCut(200, h, out) }
            return .respond(limited ? 429 : 200, h, out)
        }
    }
}

final class CCPoolCapturingLogger: CCPoolLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _onMain = false
    func note(_ label: String?, _ message: String) {
        lock.withLock {
            _lines.append("\(label ?? "-"): \(message)")
            if Thread.isMainThread { _onMain = true }
        }
    }
    private var _publicLines: [String] = []
    func note(_ label: String?, _ message: String, private detail: String) {
        note(label, message + detail)
        lock.withLock { _publicLines.append("\(label ?? "-"): \(message)") }
    }
    /// What the unified log would show in the clear for the lines written with a private part.
    var publicLines: [String] { lock.withLock { _publicLines } }
    var lines: [String] { lock.withLock { _lines } }
    var onMain: Bool { lock.withLock { _onMain } }
    func forgetMain() { lock.withLock { _onMain = false } }   // the test's own start() call logs on main
}

struct CCPoolClientResponse {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
    func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name }?.1 }
}

enum CCPoolTestClient {
    /// One raw HTTP/1.1 request to 127.0.0.1:<port>, read to EOF (the proxy closes per response).
    static func request(port: UInt16, method: String = "POST", path: String = "/v1/messages",
                        headers: [(String, String)] = [("content-type", "application/json"),
                                                       ("authorization", "Bearer client-token-should-be-replaced")],
                        body: Data? = nil, model: String = "claude-opus-5", host: [String]? = nil,
                        timeout: TimeInterval = 15) -> CCPoolClientResponse? {
        let payload = method == "GET" ? Data() : (body ?? Data(#"{"model":"\#(model)","max_tokens":1}"#.utf8))
        var head = "\(method) \(path) HTTP/1.1\r\n"
        // nil: the usual local Host; [] sends none; several send that many Host lines.
        for h in host ?? ["127.0.0.1:\(port)"] { head += "Host: \(h)\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if method != "GET" { head += "Content-Length: \(payload.count)\r\n" }
        var out = Data((head + "\r\n").utf8)
        out.append(payload)
        guard let raw = exchange(port: port, send: out, timeout: timeout) else { return nil }
        return parse(raw)
    }

    final class Box: @unchecked Sendable { var data = Data(); var ok = false }

    /// `onData` sees everything read so far after each read (on the client's queue).
    static func exchange(port: UInt16, send: Data, readAtMost: Int? = nil, timeout: TimeInterval,
                         onData: (@Sendable (Data) -> Void)? = nil) -> Data? {
        let q = DispatchQueue(label: "ccpool.test.client")
        let c = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        @Sendable func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                if let d { box.data.append(d); onData?(box.data) }
                if let n = readAtMost, box.data.count >= n { box.ok = true; sem.signal(); return }
                if done || err != nil { box.ok = err == nil || done; sem.signal(); return }
                read()
            }
        }
        c.stateUpdateHandler = { state in
            if case .ready = state {
                c.send(content: send, completion: .idempotent)
                read()
            }
            if case .failed = state { sem.signal() }
        }
        c.start(queue: q)
        let timedOut = sem.wait(timeout: .now() + timeout) == .timedOut
        c.cancel()
        return q.sync { timedOut || !box.ok ? nil : box.data }
    }

    static func parse(_ raw: Data) -> CCPoolClientResponse? {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: raw[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
        let headers = lines.dropFirst().compactMap { l -> (String, String)? in
            guard let c = l.firstIndex(of: ":") else { return nil }
            return (String(l[..<c]), l[l.index(after: c)...].trimmingCharacters(in: .whitespaces))
        }
        var body = Data(raw[end.upperBound...])
        if headers.contains(where: { $0.0.lowercased() == "transfer-encoding" && $0.1.lowercased() == "chunked" }) {
            body = dechunk(body)
        }
        return CCPoolClientResponse(status: status, headers: headers, body: body)
    }

    static func dechunk(_ d: Data) -> Data {
        var out = Data()
        var i = d.startIndex
        while let crlf = d.range(of: Data([13, 10]), in: i..<d.endIndex),
              let n = Int(String(decoding: d[i..<crlf.lowerBound], as: UTF8.self), radix: 16), n > 0 {
            let start = crlf.upperBound
            guard d.endIndex - start >= n else { out.append(d[start...]); break }
            out.append(d[start..<start + n])
            i = start + n + 2
            if i > d.endIndex { break }
        }
        return out
    }
}

/// #1595: the anthropic-beta values a fake upstream received, in order.
final class CCPoolBetaBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func add(_ v: String) { lock.withLock { _values.append(v) } }
    var values: [String] { lock.withLock { _values } }
}

final class CCPoolProxyTests: XCTestCase {
    struct Rig {
        let up: CCPoolFakeServer
        let anthropic: CCPoolFakeAnthropic
        let service: CCPoolService
        let store: CCPoolStore
        let secrets: CCPoolMemorySecrets
        let log: CCPoolCapturingLogger
        var port: UInt16 {
            if case .running(let p) = service.status { return p }
            return 0
        }
        func post(_ model: String = "claude-opus-5", body: Data? = nil) -> CCPoolClientResponse? {
            CCPoolTestClient.request(port: port, body: body, model: model)
        }
        func cooldown(_ label: String) -> [String: Int] { store.snapshot.accounts[label]?.cooldown ?? [:] }
        func setCurrent(_ label: String) { store.mutate { $0.current = label } }
    }

    private func rig(_ labels: [String] = ["one", "two", "three"], replayCap: Int = 32 << 20) throws -> Rig {
        let anthropic = CCPoolFakeAnthropic()
        let up = try CCPoolFakeServer { h, b in anthropic.reply(h, b) }
        XCTAssertNotEqual(up.port, 0)
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        for l in labels { try store.addAccount(label: l, token: "tok-\(l)", secrets: secrets) }
        let log = CCPoolCapturingLogger()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        cfg.replayCap = replayCap
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); up.stop() }
        return Rig(up: up, anthropic: anthropic, service: service, store: store, secrets: secrets, log: log)
    }

    // B12: a live session survives a limit hit.
    func testCCPoolRotationClientSees200() throws {
        let r = try rig()
        r.anthropic.set { $0.spent = ["tok-one"] }
        r.setCurrent("one")
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertFalse(resp.text.contains("limit"), "it never learns a rotation happened")
        let seen = r.anthropic.get { $0.seen }
        XCTAssertGreaterThanOrEqual(seen.count, 2)
        XCTAssertTrue(seen.first?.contains("tok-one") ?? false, "upstream saw the exhausted account first: \(seen)")
        XCTAssertFalse(seen.last?.contains("tok-one") ?? true)
        XCTAssertNotNil(r.cooldown("one")["five_hour"], "the exhausted account is benched")
        XCTAssertEqual(r.cooldown("two"), [:])
        XCTAssertEqual(r.cooldown("three"), [:])
        XCTAssertEqual(resp.header("server"), "ccpool", "the proxy names itself first")
        XCTAssertEqual(resp.header("transfer-encoding"), "chunked")
        XCTAssertEqual(resp.header("connection"), "close")
    }

    // B10: the client's own credential is never forwarded.
    func testCCPoolClientCredentialNeverForwarded() throws {
        let r = try rig()
        r.setCurrent("two")
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: [
            ("content-type", "application/json"),
            ("Authorization", "Bearer client-token-should-be-replaced"),
            ("x-api-key", "client-key-should-be-dropped"),
            ("anthropic-version", "2023-06-01"),
        ]))
        XCTAssertEqual(resp.status, 200)
        let (seen, keys) = r.anthropic.get { ($0.seen, $0.apiKeys) }
        XCTAssertEqual(seen, ["Bearer tok-two"])
        XCTAssertEqual(keys, [], "x-api-key never goes upstream")
    }

    // #1595: the relay sends the pool's OAuth token, so anthropic-beta carries oauth-2025-04-20 (an API-key client sends none).
    private func upstreamBeta(_ clientBeta: String?) throws -> String? {
        let r = try rig()
        r.setCurrent("two")
        var headers = [("content-type", "application/json"), ("x-api-key", "client-key-should-be-dropped")]
        if let clientBeta { headers.append(("anthropic-beta", clientBeta)) }
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: headers))
        XCTAssertEqual(resp.status, 200)
        let heads = r.anthropic.get { $0.heads }
        XCTAssertEqual(heads.count, 1)
        return heads.last?["anthropic-beta"]
    }

    func testCCPoolOAuthBetaAddedForAPIKeyClient() throws {
        XCTAssertEqual(try upstreamBeta(nil), "oauth-2025-04-20")
    }

    func testCCPoolOAuthBetaAppendedToClientList() throws {
        XCTAssertEqual(try upstreamBeta("a,b"), "a,b,oauth-2025-04-20", "the client's betas kept, in order")
    }

    func testCCPoolOAuthBetaNeverDuplicated() throws {
        XCTAssertEqual(try upstreamBeta("a, OAuth-2025-04-20 ,b"), "a, OAuth-2025-04-20 ,b", "any case or spacing: unchanged")
        XCTAssertEqual(try upstreamBeta("oauth-2025-04-20"), "oauth-2025-04-20")
        XCTAssertEqual(CCPoolConnection.withOAuthBeta("  "), "oauth-2025-04-20", "a blank list is no list")
        XCTAssertEqual(CCPoolConnection.withOAuthBeta("oauth-2025-04-200"), "oauth-2025-04-200,oauth-2025-04-20", "whole tokens only")
    }

    // #1605: auto mode's server-side check. The client sends a "safeguards" body field and anthropic-beta as a pair: both
    // must reach the upstream unchanged (the body byte for byte, the beta list kept plus oauth-2025-04-20), and the answer
    // (safeguard_results, tool_use ids) must come back byte for byte.
    private static let safeguardsBody = Data(#"{"model":"claude-opus-5","max_tokens":1,"safeguards":{"mode":"auto","rules":["r1","r2"],"nested":{"x":[1,2,{"y":null}]}},"unknown_future_field":{"a":"b"},"messages":[{"role":"user","content":"hi"}]}"#.utf8)
    private static let safeguardsJSON = Data(#"{"type":"message","content":[{"type":"tool_use","id":"toolu_example01","name":"Bash","input":{"command":"ls"}}],"safeguard_results":[{"id":"toolu_example01","verdict":"allow","extra":{"k":[1,2]}}],"unknown_future_field":true}"#.utf8)
    private static let safeguardsSSE = Data([
        #"event: content_block_start"#, #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_example01","name":"Bash","input":{}}}"#, "",
        #"event: safeguard_results"#, #"data: {"type":"safeguard_results","results":[{"id":"toolu_example01","verdict":"allow"}],"future":1}"#, "",
        #"event: message_stop"#, #"data: {"type":"message_stop","safeguard_results":[{"id":"toolu_example01"}]}"#, "", "",
    ].joined(separator: "\n").utf8)

    private func safeguardsExchange(contentType: String, reply: Data) throws -> (resp: CCPoolClientResponse, bodies: [Data], heads: [[String: String]]) {
        let r = try rig()
        r.setCurrent("two")
        r.anthropic.set { $0.fixedReply = ([("content-type", contentType)], reply) }
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: [
            ("content-type", "application/json"), ("anthropic-beta", "auto-mode-2026-01-01,safeguards-2026-01-01"),
        ], body: Self.safeguardsBody))
        XCTAssertEqual(resp.status, 200, resp.text)
        return (resp, r.anthropic.get { $0.bodies }, r.anthropic.get { $0.heads })
    }

    func testCCPoolSafeguardsRequestBodyAndBetaReachUpstreamUnchanged() throws {
        let x = try safeguardsExchange(contentType: "application/json", reply: Self.safeguardsJSON)
        XCTAssertEqual(x.bodies.count, 1)
        XCTAssertTrue(x.bodies.last == Self.safeguardsBody, "the request body arrives byte-identical: \(String(decoding: x.bodies.last ?? Data(), as: UTF8.self))")
        XCTAssertEqual(x.heads.last?["anthropic-beta"], "auto-mode-2026-01-01,safeguards-2026-01-01,oauth-2025-04-20", "the client list kept in order")
    }

    func testCCPoolSafeguardResultsJSONResponseByteIdentical() throws {
        let x = try safeguardsExchange(contentType: "application/json", reply: Self.safeguardsJSON)
        XCTAssertTrue(x.resp.body == Self.safeguardsJSON, "safeguard_results and tool_use ids kept: \(x.resp.text)")
    }

    func testCCPoolSafeguardResultsSSEResponseByteIdentical() throws {
        let x = try safeguardsExchange(contentType: "text/event-stream", reply: Self.safeguardsSSE)
        XCTAssertEqual(x.resp.header("content-type"), "text/event-stream")
        XCTAssertTrue(x.resp.body == Self.safeguardsSSE, "every stream event kept: \(x.resp.text)")
    }

    // #1595: the usage probe still sends exactly oauth-2025-04-20 itself.
    func testCCPoolProbeBetaUnchanged() async throws {
        let seen = CCPoolBetaBox()
        let server = try CCPoolFakeServer { head, _ in
            seen.add(head.header("anthropic-beta") ?? "<none>")
            return .respond(200, [], Data())
        }
        defer { server.stop() }
        let probe = await CCPoolUsage.probe(token: "tok-probe", base: URL(string: "http://127.0.0.1:\(server.port)")!, timeout: 10)
        XCTAssertEqual(probe?.status, 200)
        XCTAssertEqual(seen.values, ["oauth-2025-04-20"])
    }

    // B10: the client's hop-by-hop headers, Host and Content-Length never go upstream (#1576).
    // Trailer and Proxy-Connection are separate rows: see testCCPoolTrailerNeverForwarded.
    func testCCPoolClientHopByHopHeadersNeverForwarded() throws {
        let r = try rig()
        r.setCurrent("two")
        let body = Data(#"{"model":"claude-opus-5","max_tokens":1}"#.utf8)
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: [
            ("content-type", "application/json"),
            ("Connection", "client-hop-conn"),
            ("Keep-Alive", "client-hop-timeout=99"),
            ("Proxy-Authorization", "Basic client-hop-proxy"),
            ("Proxy-Authenticate", "client-hop-proxy-auth"),
            ("TE", "client-hop-te"),
            ("Upgrade", "client-hop-upgrade"),
            ("x-keep-me", "client-keep-me"),
        ], body: body, host: ["localhost:\(r.port)"]))
        XCTAssertEqual(resp.status, 200, resp.text)
        let heads = r.anthropic.get { $0.heads }
        XCTAssertEqual(heads.count, 1)
        let h = heads.last ?? [:]
        for name in ["connection", "keep-alive", "proxy-authorization", "proxy-authenticate", "te", "upgrade"] {
            XCTAssertFalse((h[name] ?? "").contains("client-hop"), "\(name) reached the upstream: \(h[name] ?? "")")
        }
        XCTAssertEqual(h["x-keep-me"], "client-keep-me", "an end-to-end header still goes through")
        XCTAssertEqual(h["host"], "127.0.0.1:\(r.up.port)", "Host is the upstream's, never the client's localhost:\(r.port)")
        // The length is the proxy's own for the body it forwards, never a copy of the client's header.
        XCTAssertEqual(h["content-length"], String(body.count))
        XCTAssertEqual(r.anthropic.get { $0.bodySizes }, [body.count])
    }

    // B10: a chunked request body is refused before anything is relayed, so Transfer-Encoding never goes upstream.
    func testCCPoolClientTransferEncodingNeverForwarded() throws {
        let r = try rig()
        r.setCurrent("two")
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: [
            ("content-type", "application/json"), ("Transfer-Encoding", "chunked"),
        ]))
        XCTAssertEqual(resp.status, 400, resp.text)
        XCTAssertEqual(r.anthropic.get { $0.heads }.count, 0, "nothing reached the upstream")
    }

    // B10: Trailer is hop-by-hop (RFC 9110 7.6.1). The code strips "trailers" (sic), so this row is the check.
    func testCCPoolTrailerNeverForwarded() throws {
        let r = try rig()
        r.setCurrent("two")
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: [
            ("content-type", "application/json"), ("Trailer", "client-hop-trailer"),
        ]))
        XCTAssertEqual(resp.status, 200)
        XCTAssertFalse((r.anthropic.get { $0.heads }.last?["trailer"] ?? "").contains("client-hop"))
    }

    // B10: Proxy-* are hop-by-hop; Proxy-Connection (the non-standard one) is a Proxy-* header too.
    func testCCPoolProxyConnectionNeverForwarded() throws {
        let r = try rig()
        r.setCurrent("two")
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: [
            ("content-type", "application/json"), ("Proxy-Connection", "client-hop-proxyconn"),
        ]))
        XCTAssertEqual(resp.status, 200)
        XCTAssertFalse((r.anthropic.get { $0.heads }.last?["proxy-connection"] ?? "").contains("client-hop"))
    }

    // B12 / 3.8-M2: the upstream dies after its first bytes went downstream: no replay on another account, and the client
    // sees the stream cut (no terminating chunk), never a clean end or a second answer.
    func testCCPoolUpstreamCutAfterFirstByteIsNotReplayed() throws {
        let r = try rig(["one", "two"])
        r.anthropic.set { $0.cutAfterFirstBytes = ["tok-one"] }
        r.setCurrent("one")
        let req = Data("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(r.port)\r\ncontent-type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        // #1594: the upstream hangs up once the client holds the first bytes; if they never come, no cut, and the 15 s ends it red.
        let raw = try XCTUnwrap(CCPoolTestClient.exchange(port: r.port, send: req, timeout: 15, onData: { [up = r.up] got in
            if got.range(of: Data(#"{"type":"message""#.utf8)) != nil { up.releaseCut() }
        }))
        XCTAssertEqual(r.anthropic.get { $0.seen }, ["Bearer tok-one"], "one upstream attempt, no replay to two")
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), "the head went out before the cut: \(text.prefix(80))")
        XCTAssertTrue(text.contains(#"{"type":"message""#), "the first bytes reached the client")
        XCTAssertFalse(text.hasSuffix("0\r\n\r\n"), "no clean end of stream: the cut is visible")
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1").count, 2, "one response only")
        XCTAssertEqual(r.cooldown("two"), [:])
    }

    // B5: one account at a time, never a gratuitous switch.
    func testCCPoolStaysOnOneHealthyAccount() throws {
        let r = try rig()
        r.setCurrent("two")
        for _ in 0..<5 { XCTAssertEqual(r.post()?.status, 200) }
        XCTAssertEqual(r.anthropic.get { $0.seen }, Array(repeating: "Bearer tok-two", count: 5))
    }

    // B15: full accounts retire on success, never on rejection.
    func testCCPoolRetireOnFull200() throws {
        let r = try rig()
        r.setCurrent("one")
        r.anthropic.set { $0.full = ["tok-one"] }
        XCTAssertEqual(r.post()?.status, 200, "the request itself still succeeds")
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 1, "no rotation was needed for it")
        XCTAssertNotNil(r.cooldown("one")["five_hour"], "the drained account is benched immediately")
        XCTAssertNotNil(r.store.snapshot.accounts["one"]?.reset["five_hour"], "its rollover is recorded")
        r.anthropic.clearSeen()
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertFalse(r.anthropic.get { $0.seen }.contains { $0.contains("tok-one") }, "the next request never touches it")
    }

    // B17: a pooled upstream connection the far end dropped is retried once, never more.
    func testCCPoolStaleConnectionRetriedOnceNeverSentTwice() throws {
        let r = try rig()
        r.setCurrent("three")
        XCTAssertEqual(r.post()?.status, 200, "opens three's pooled connection")
        XCTAssertEqual(r.up.accepted, 1)
        r.anthropic.clearSeen()
        r.up.dropReused(1)
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertEqual(r.up.reusedDropped, 1, "the request went out on the pooled connection, which dropped it")
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 1, "answered once, on the retry")
        XCTAssertEqual(r.up.accepted, 2, "the retry opened a fresh connection")

        // The retry fails too: a real error, no third attempt.
        r.anthropic.clearSeen()
        r.up.dropReused(1)
        r.anthropic.set { $0.dropNext = 10 }
        let again = try XCTUnwrap(r.post())
        XCTAssertEqual(again.status, 502, "a second failure is a real error")
        XCTAssertEqual(r.up.reusedDropped, 2)
        XCTAssertEqual(r.anthropic.get { $0.dropped }, 1, "exactly one retry")
        XCTAssertEqual(r.store.snapshot.accounts.values.map(\.cooldown), [[:], [:], [:]], "transport failures bench nobody")
    }

    // QA #733 F1: a FRESH connection that drops after reading the whole request may have run it:
    // 502, never resent (the quota is not spent twice).
    func testCCPoolDropOnFreshConnectionIsNotResent() throws {
        let r = try rig(["one"])
        r.anthropic.set { $0.dropNext = 1 }
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 502, resp.text)
        XCTAssertEqual(r.anthropic.get { $0.dropped }, 1, "the fake read exactly one request")
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 0, "and no second one")
        XCTAssertEqual(r.up.accepted, 1)
        XCTAssertFalse(r.log.lines.contains { $0.contains("retrying once") }, r.log.lines.joined(separator: "\n"))
        XCTAssertEqual(r.cooldown("one"), [:])
    }

    func testCCPoolResendDecisionTable() {
        let lost = URLError.Code.networkConnectionLost
        let rows: [(URLError.Code?, Bool, Bool, Bool, Bool, String)] = [
            (lost, false, false, true, true, "pooled connection dropped: one resend"),
            (lost, false, false, false, false, "fresh connection: may have run, no resend"),
            (lost, true, false, true, false, "already retried"),
            (lost, false, true, true, false, "streamed body cannot be sent again"),
            (.timedOut, false, false, true, false, "a timeout is not a stale connection"),
            (nil, false, false, true, false, "not a URLError"),
        ]
        for (code, retried, streamed, reused, want, why) in rows {
            XCTAssertEqual(CCPoolConnection.shouldResend(code, retried: retried, streamed: streamed, reused: reused), want, why)
        }
    }

    // QA #733 F2: Retry-After is clamped to 0...maxBench before any arithmetic.
    func testCCPoolRetryAfterClamp() {
        let max = CCPoolCore.maxBench
        let rows: [(String?, Int)] = [
            ("9223372036854775807", max), (String(10 * max), max), ("-5", 0), ("abc", 0), (" 30 ", 30),
            ("99999999999999999999999", 0), (nil, 0), ("", 0), ("7200", 7200),
        ]
        for (raw, want) in rows { XCTAssertEqual(CCPoolCore.retryAfterSeconds(raw), want, raw ?? "nil") }
    }

    func testCCPoolHugeRetryAfterNoTrap() throws {
        for (header, benched) in [("9223372036854775807", true), ("-5", false), ("abc", false), (" 30 ", false)] {
            let r = try rig(["one"])
            r.anthropic.set { $0.overload = ["tok-one"]; $0.overloadRetryAfter = header }
            let now = Int(Date().timeIntervalSince1970)
            let resp = try XCTUnwrap(r.post(), header)
            XCTAssertTrue([429, 503].contains(resp.status), "\(header): \(resp.status)")
            let bench = r.cooldown("one").values.max()
            if benched {
                let until = try XCTUnwrap(bench, header)
                XCTAssertLessThanOrEqual(until, now + CCPoolCore.maxBench + 5, "no bench past now + maxBench")
                XCTAssertGreaterThan(until, now + CCPoolCore.maxBench - 60)
            } else {
                XCTAssertNil(bench, "\(header): a short or bad Retry-After benches nobody")
            }
        }
    }

    // B18: a client that hangs up mid-stream cannot corrupt the next response.
    func testCCPoolAbandonedStreamNotSpliced() throws {
        let r = try rig()
        r.setCurrent("three")
        r.anthropic.set { $0.big = ["tok-three"] }
        let payload = Data(#"{"model":"claude-opus-5"}"#.utf8)
        var req = Data("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(r.port)\r\ncontent-type: application/json\r\ncontent-length: \(payload.count)\r\n\r\n".utf8)
        req.append(payload)
        XCTAssertNotNil(CCPoolTestClient.exchange(port: r.port, send: req, readAtMost: 64, timeout: 10), "take a sip, then walk away")
        r.anthropic.set { $0.big = [] }
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 200)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        XCTAssertEqual(((obj?["content"] as? [[String: Any]])?.first?["text"]) as? String, "hi", "the next response is complete and its own")
    }

    // B18: a large body streams down whole, chunked.
    func testCCPoolLargeResponseStreamsWhole() throws {
        let r = try rig()
        r.setCurrent("one")
        r.anthropic.set { $0.big = ["tok-one"] }
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.body.count, 400_000 + #"{"type":"message","pad":""}"#.utf8.count)
    }

    // B14: upstream congestion is not an account problem.
    func testCCPoolUpstreamCongestionPassesThroughNobodyBenched() throws {
        let r = try rig()
        r.anthropic.set { $0.overload = ["tok-one", "tok-two", "tok-three"]; $0.errorPad = 600 }
        let before = r.store.snapshot.accounts
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429)
        XCTAssertTrue(resp.text.contains("not account quota"), resp.text)
        XCTAssertTrue(resp.text.contains("rate_limit_error"))
        XCTAssertEqual(r.store.snapshot.accounts.mapValues(\.cooldown), before.mapValues(\.cooldown), "nobody gets benched for it")
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 1, "and nothing rotates")
        let line = try XCTUnwrap(r.log.lines.first { $0.contains("429") })
        XCTAssertTrue(line.contains("reason=no exhausted quota; model=claude-opus-5; body="), line)
        let snippet = line.components(separatedBy: "body=").last ?? ""
        XCTAssertEqual(snippet.utf8.count, 200, "a 600-byte body is cut to 200 bytes")
        // QA #733 INFO-3: the model and the body are in the private part only.
        let open = try XCTUnwrap(r.log.publicLines.first { $0.contains("429") })
        XCTAssertFalse(open.contains("body="), open)
        XCTAssertFalse(open.contains("claude-opus-5"), open)
    }

    // QA #733 INFO-3: the model and Retry-After printed in a 429 line are capped at 64 bytes.
    func testCCPoolLogCapsModelAndRetryAfter() throws {
        let r = try rig(["one"])
        let long = String(repeating: "9", count: 100)
        r.anthropic.set { $0.overload = ["tok-one"]; $0.overloadRetryAfter = long }
        XCTAssertEqual(r.post(String(repeating: "m", count: 100))?.status, 429)
        let line = try XCTUnwrap(r.log.lines.first { $0.contains("429") })
        XCTAssertTrue(line.contains("retry-after=\(String(repeating: "9", count: 64));"), line)
        XCTAssertTrue(line.contains("model=\(String(repeating: "m", count: 64));"), line)
        XCTAssertFalse(line.contains(String(repeating: "m", count: 65)))
        XCTAssertFalse(line.contains(String(repeating: "9", count: 65)))
    }

    // B13: a long Fable Retry-After does not hold Opus.
    func testCCPoolLongRetryAfterBenchesOnlyTheModelClaim() throws {
        let r = try rig()
        r.anthropic.set { $0.longWait = ["tok-three"] }
        r.setCurrent("three")
        let resp = try XCTUnwrap(r.post("claude-fable-5"))
        XCTAssertEqual(resp.status, 200, resp.text)
        let seen = r.anthropic.get { $0.seen }
        XCTAssertTrue(seen.first?.contains("tok-three") ?? false)
        XCTAssertFalse(seen.last?.contains("tok-three") ?? true)
        let cd = r.cooldown("three")
        XCTAssertGreaterThan(Double(cd["seven_day_overage_included"] ?? 0), Date().timeIntervalSince1970 + 3600)
        XCTAssertNil(cd["five_hour"], "only Fable's weekly claim is benched")
        r.anthropic.set { $0.longWait = [] }
        r.anthropic.clearSeen()
        r.setCurrent("three")
        XCTAssertEqual(r.post("claude-opus-5")?.status, 200)
        XCTAssertEqual(r.anthropic.get { $0.seen }, ["Bearer tok-three"], "an Opus request can still use that account")
    }

    // B13: unknown model + long Retry-After keeps the conservative five_hour bench.
    func testCCPoolLongRetryAfterUnknownModelBenchesFiveHour() throws {
        let r = try rig(["one", "two"])
        r.anthropic.set { $0.longWait = ["tok-one"] }
        r.setCurrent("one")
        XCTAssertEqual(r.post("mystery-model")?.status, 200)
        XCTAssertNotNil(r.cooldown("one")["five_hour"])
    }

    // B11: the model comes from the request body.
    func testCCPoolModelFromBodyDrivesEligibility() throws {
        let r = try rig(["one", "two"])
        r.setCurrent("one")
        r.store.mutate { $0.bench("one", claim: "seven_day_sonnet", until: Int(Date().timeIntervalSince1970) + 3600, now: Date().timeIntervalSince1970) }
        XCTAssertEqual(r.post("claude-sonnet-4-5")?.status, 200)
        XCTAssertEqual(r.store.snapshot.current, "two", "the Sonnet request moved off the Sonnet-benched account")
        r.setCurrent("one")   // the move is sticky (B5); put it back to see Opus stay on "one"
        XCTAssertEqual(r.post("claude-opus-5")?.status, 200)
        XCTAssertEqual(r.anthropic.get { $0.seen }, ["Bearer tok-two", "Bearer tok-one"])
    }

    // B16: whole pool exhausted is reported honestly.
    func testCCPoolAllBenchedReturns429WithReset() throws {
        let r = try rig()
        r.anthropic.set { $0.spent = ["tok-one", "tok-two", "tok-three"] }
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429)
        XCTAssertTrue(resp.text.contains("all pooled accounts"), resp.text)
        XCTAssertTrue(resp.text.lowercased().contains("reset"), resp.text)
        XCTAssertTrue(resp.text.contains("rate_limit_error"))
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 3, "each account tried once")
        r.anthropic.clearSeen()
        XCTAssertEqual(r.post()?.status, 429)
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 0, "a benched pool costs no upstream call")
    }

    // B9: the health path is answered locally, never relayed.
    func testCCPoolHealthAnsweredLocallyNeverUpstream() throws {
        let r = try rig()
        r.setCurrent("two")
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, method: "GET", path: CCPoolService.healthPath, headers: []))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.header("server"), "ccpool")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
        XCTAssertEqual(obj["service"] as? String, "ccpool-proxy")
        XCTAssertEqual(obj["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(obj["current"] as? String, "two")
        XCTAssertEqual(obj["impl"] as? String, "prosper")
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 0)
        XCTAssertEqual(r.up.accepted, 0, "upstream never saw it")
        XCTAssertEqual(CCPoolPortProbe.probe(port: r.port, timeout: 5), .ccpool(pid: Int(getpid()), impl: "prosper"))
    }

    // P2a follow-up (a): the B14 pass-through 429 hands the upstream Retry-After on to the client.
    func testCCPoolPassThrough429KeepsRetryAfter() throws {
        let r = try rig(["one"])
        r.anthropic.set { $0.overload = ["tok-one"]; $0.overloadRetryAfter = "17" }
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429)
        XCTAssertTrue(resp.text.contains("not account quota"), resp.text)
        XCTAssertEqual(resp.header("retry-after"), "17")
        XCTAssertEqual(r.cooldown("one"), [:], "still nobody benched")
        r.anthropic.set { $0.overloadRetryAfter = nil }
        let bare = try XCTUnwrap(r.post())
        XCTAssertEqual(bare.status, 429)
        XCTAssertNil(bare.header("retry-after"), "none invented when upstream sent none")
    }

    /// #1264 gap 10, a FACT row (pins today's behaviour): the client asks for gzip, the upstream answers gzip
    /// bytes with their header. The native pool lets URLSession ask for and decode the encoding, so the client
    /// gets the decoded bytes, no Content-Encoding and no Content-Length (chunked framing carries the length):
    /// self-consistent, and readable by a client that asked for gzip (identity is always acceptable).
    func testCCPoolGzipReplyReachesTheClientDecoded() throws {
        let plain = Data(#"{"type":"message","content":[{"type":"text","text":"hi from a gzip reply"}]}"#.utf8)
        // `gzip -9 -n` of `plain`.
        let gz = Data([
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0xab, 0x56, 0x2a, 0xa9, 0x2c, 0x48, 0x55, 0xb2, 0x52, 0xca,
            0x4d, 0x2d, 0x2e, 0x4e, 0x4c, 0x4f, 0x55, 0xd2, 0x51, 0x4a, 0xce, 0xcf, 0x2b, 0x49, 0xcd, 0x2b, 0x51, 0xb2, 0x8a, 0xae,
            0x86, 0x49, 0x96, 0xa4, 0x56, 0x94, 0x00, 0x65, 0xc0, 0x94, 0x95, 0x52, 0x46, 0xa6, 0x42, 0x5a, 0x51, 0x7e, 0xae, 0x42,
            0xa2, 0x42, 0x7a, 0x55, 0x66, 0x81, 0x42, 0x51, 0x6a, 0x41, 0x4e, 0xa5, 0x52, 0x6d, 0x6c, 0x2d, 0x00, 0x63, 0x16, 0x96,
            0x1d, 0x4c, 0x00, 0x00, 0x00,
        ])
        let r = try rig(["one"])
        r.anthropic.set { $0.gzipReply = gz }
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: [
            ("content-type", "application/json"), ("authorization", "Bearer client-token-should-be-replaced"),
            ("accept-encoding", "gzip"),
        ]))
        XCTAssertEqual(r.anthropic.get { $0.gzipServed }, 1, "the upstream really answered gzip")
        XCTAssertTrue(r.anthropic.get { $0.acceptEncodings }.last?.lowercased().contains("gzip") == true,
                      "the upstream was asked for gzip (by URLSession: the client's own header is not forwarded)")
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.body, plain, "decoded bytes")
        XCTAssertTrue(resp.header("content-encoding") == nil, "no encoding claimed for decoded bytes")
        XCTAssertTrue(resp.header("content-length") == nil, "no stale gzip length")
        XCTAssertEqual(resp.header("transfer-encoding")?.lowercased(), "chunked", "the chunked framing carries the length")
    }

    // #1674: the pane's Hold and Release over a loopback POST on the proxy port.
    private func control(_ r: Rig, _ path: String, method: String = "POST", headers: [(String, String)] = [("x-ccpool-control", "1")],
                         body: Data = Data()) throws -> CCPoolClientResponse {
        try XCTUnwrap(CCPoolTestClient.request(port: r.port, method: method, path: path, headers: headers, body: body))
    }

    func testCCPoolLoopbackHoldSetsHeldWithItsUntil() throws {
        let r = try rig()
        let before = Int(Date().timeIntervalSince1970)
        // Percent-encoded and exact: "tw%6F" is the label "two".
        let resp = try control(r, CCPoolConnection.holdPath + "?label=tw%6F&hours=2")
        let after = Int(Date().timeIntervalSince1970) + 1
        XCTAssertEqual(resp.status, 200, resp.text)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any], resp.text)
        XCTAssertEqual(obj["label"] as? String, "two")
        XCTAssertEqual(obj["state"] as? String, "held")
        let until = try XCTUnwrap(obj["until"] as? Int)
        XCTAssertTrue((before + 7200...after + 7200).contains(until), "\(until) not two hours on")
        XCTAssertEqual(r.store.snapshot.accounts["two"]?.held, until, "the store holds what the answer says")
        XCTAssertEqual(r.cooldown("two")["five_hour"], until)
        XCTAssertEqual(r.cooldown("one"), [:])
        XCTAssertEqual(Set(obj.keys), ["label", "state", "until"], "never a token, key or Keychain id")
        XCTAssertFalse(resp.text.contains("tok-"), resp.text)
        XCTAssertEqual(r.log.lines.filter { $0.contains("by a loopback request") }, ["two: held for 2.0 h by a loopback request"])
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 0)
        XCTAssertEqual(r.up.accepted, 0, "never relayed")
        // Health still answers beside the new routes.
        XCTAssertEqual(CCPoolTestClient.request(port: r.port, method: "GET", path: CCPoolService.healthPath, headers: [])?.status, 200)
    }

    func testCCPoolLoopbackClearReleasesEveryCooldown() throws {
        let r = try rig()
        let now = r.store.now
        r.store.mutate { s in
            _ = s.hold("one", hours: 1, now: now)
            _ = s.bench("one", claim: "seven_day", until: Int(now) + 900, now: now)
        }
        XCTAssertEqual(r.cooldown("one").count, 2)
        let resp = try control(r, CCPoolConnection.clearPath + "?label=one")
        XCTAssertEqual(resp.status, 200, resp.text)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any], resp.text)
        XCTAssertEqual(obj["label"] as? String, "one")
        XCTAssertEqual(obj["state"] as? String, "ready")
        XCTAssertTrue(obj["until"] == nil, "no until once released")
        XCTAssertEqual(r.cooldown("one"), [:])
        XCTAssertTrue(r.store.snapshot.accounts["one"]?.held == nil)
        XCTAssertEqual(r.log.lines.filter { $0.contains("by a loopback request") }, ["one: released by a loopback request"])
        XCTAssertEqual(r.up.accepted, 0, "never relayed")
    }

    func testCCPoolLoopbackUnknownLabelIs404AndChangesNothing() throws {
        let r = try rig()
        let before = r.store.snapshot
        for path in [CCPoolConnection.holdPath + "?label=nobody&hours=1", CCPoolConnection.clearPath + "?label=nobody",
                     CCPoolConnection.holdPath + "?label=TWO&hours=1", CCPoolConnection.clearPath + "?label=tw"] {
            XCTAssertEqual(try control(r, path).status, 404, path)
        }
        XCTAssertTrue(r.store.snapshot == before, "nothing changed")
        XCTAssertEqual(r.up.accepted, 0)
    }

    func testCCPoolLoopbackBadHoursOrLabelIs400AndChangesNothing() throws {
        let r = try rig()
        let before = r.store.snapshot
        for query in ["?label=two&hours=0", "?label=two&hours=-1", "?label=two&hours=nan", "?label=two&hours=inf",
                      "?label=two&hours=abc", "?label=two&hours=", "?label=two", "?hours=1", "?label=&hours=1",
                      "?label=two&label=one&hours=1", "?label=two&hours=1&hours=2", ""] {
            XCTAssertEqual(try control(r, CCPoolConnection.holdPath + query).status, 400, query)
        }
        for query in ["", "?label=", "?label=one&label=two"] {
            XCTAssertEqual(try control(r, CCPoolConnection.clearPath + query).status, 400, query)
        }
        XCTAssertTrue(r.store.snapshot == before, "nothing changed")
        XCTAssertEqual(r.up.accepted, 0)
    }

    func testCCPoolLoopbackGetIs405() throws {
        let r = try rig()
        let before = r.store.snapshot
        for path in [CCPoolConnection.holdPath + "?label=two&hours=1", CCPoolConnection.clearPath + "?label=two"] {
            let resp = try control(r, path, method: "GET")
            XCTAssertEqual(resp.status, 405, path)
            XCTAssertEqual(resp.header("allow"), "POST")
        }
        XCTAssertTrue(r.store.snapshot == before, "nothing changed")
        XCTAssertEqual(r.up.accepted, 0)
    }

    // A web page can POST to 127.0.0.1 without a preflight: no control header, or any Origin, is refused.
    func testCCPoolLoopbackNeedsTheHeaderAndNoOrigin() throws {
        let r = try rig()
        let before = r.store.snapshot
        let hold = CCPoolConnection.holdPath + "?label=two&hours=1"
        let clear = CCPoolConnection.clearPath + "?label=two"
        for headers in [[], [("x-ccpool-control", "0")], [("x-ccpool-control", "true")],
                        [("x-ccpool-control", "1"), ("Origin", "https://example.com")],
                        [("x-ccpool-control", "1"), ("origin", "null")]] as [[(String, String)]] {
            XCTAssertEqual(try control(r, hold, headers: headers).status, 403, "\(headers)")
            XCTAssertEqual(try control(r, clear, headers: headers).status, 403, "\(headers)")
        }
        XCTAssertTrue(r.store.snapshot == before, "nothing changed")
        XCTAssertEqual(r.up.accepted, 0)
        XCTAssertEqual(try control(r, hold).status, 200, "the same request with the header and no Origin is served")
    }

    func testCCPoolLoopbackBodyOverTheCapIsRefused() throws {
        let r = try rig()
        let before = r.store.snapshot
        let hold = CCPoolConnection.holdPath + "?label=two&hours=1"
        XCTAssertEqual(try control(r, hold, body: Data(count: CCPoolConnection.controlBodyCap + 1)).status, 413)
        XCTAssertTrue(r.store.snapshot == before, "nothing changed")
        XCTAssertEqual(try control(r, hold, body: Data(count: CCPoolConnection.controlBodyCap)).status, 200, "a body at the cap is ignored")
        XCTAssertEqual(r.up.accepted, 0)
    }

    // P2a follow-up (b): a query string does not send the health path upstream.
    func testCCPoolHealthWithQueryAnsweredLocally() throws {
        let r = try rig()
        for path in [CCPoolService.healthPath + "?x=1", CCPoolService.healthPath + "?"] {
            let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port, method: "GET", path: path, headers: []))
            XCTAssertEqual(resp.status, 200, path)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any], path)
            XCTAssertEqual(obj["service"] as? String, "ccpool-proxy")
        }
        XCTAssertEqual(r.up.accepted, 0, "upstream never saw it")
        XCTAssertEqual(CCPoolPortProbe.probe(port: r.port, timeout: 5), .ccpool(pid: Int(getpid()), impl: "prosper"))
    }

    // E6/X2: a caller naming any host but this loopback proxy is refused before upstream or state is touched.
    func testCCPoolRefusesForeignHostBeforeUpstream() throws {
        let r = try rig()
        r.setCurrent("two")
        let p = r.port
        let hostile: [[String]] = [["api.example.test"], ["127.0.0.1.evil.example"], ["localhost.evil.example:\(p)"],
                                   ["127.0.0.1:\(p).evil.example"], ["127.0.0.1:1"], [], ["127.0.0.1:\(p)", "127.0.0.1:\(p)"]]
        for host in hostile {
            for (method, path) in [("POST", "/v1/messages"), ("GET", CCPoolService.healthPath)] {
                let resp = try XCTUnwrap(CCPoolTestClient.request(port: p, method: method, path: path, host: host), "\(host) \(path)")
                XCTAssertEqual(resp.status, 403, "\(host) \(path): \(resp.text)")
                XCTAssertFalse(resp.text.contains("current"), "health detail never reaches a foreign page: \(host)")
                XCTAssertFalse(resp.text.contains("two"))
            }
        }
        XCTAssertEqual(r.up.accepted, 0, "upstream never saw a refused request")
        XCTAssertEqual(r.anthropic.get { $0.seen }.count, 0)
        XCTAssertEqual(r.store.snapshot.current, "two", "state untouched")
    }

    // E6/X2: any Origin header means a browser page; refused, health included.
    func testCCPoolRefusesAnyOrigin() throws {
        let r = try rig()
        let p = r.port
        for origin in ["http://127.0.0.1:\(p)", "http://localhost:\(p)", "null", "https://evil.example"] {
            for (method, path) in [("POST", "/v1/messages"), ("GET", CCPoolService.healthPath)] {
                let resp = try XCTUnwrap(CCPoolTestClient.request(port: p, method: method, path: path,
                                                                  headers: [("content-type", "application/json"), ("Origin", origin)]))
                XCTAssertEqual(resp.status, 403, "\(origin) \(path): \(resp.text)")
            }
        }
        XCTAssertEqual(r.up.accepted, 0)
    }

    // E6/X2: the local host forms are served, with or without the bound port, in any case.
    func testCCPoolServesLocalHostForms() throws {
        let r = try rig()
        let p = r.port
        for host in ["127.0.0.1:\(p)", "localhost:\(p)", "127.0.0.1", "localhost", "LocalHost:\(p)"] {
            XCTAssertEqual(CCPoolTestClient.request(port: p, host: [host])?.status, 200, host)
            XCTAssertEqual(CCPoolTestClient.request(port: p, method: "GET", path: CCPoolService.healthPath, headers: [], host: [host])?.status, 200, host)
        }
    }

    // X16: releasing the service while a request is in flight never crashes the app.
    func testCCPoolServiceReleasedMidRequestSurvives() throws {
        let arrived = DispatchSemaphore(value: 0)
        let up = try CCPoolFakeServer { _, _ in
            arrived.signal()
            Thread.sleep(forTimeInterval: 0.5)
            return .respond(200, [("content-type", "application/json")], Data(#"{"type":"message"}"#.utf8))
        }
        defer { up.stop() }
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "one", token: "tok-one", secrets: secrets)
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        var service: CCPoolService? = CCPoolService(config: cfg, store: store, secrets: secrets, logger: CCPoolCapturingLogger())
        guard case .running(let port)? = service?.start() else { return XCTFail("proxy did not start") }
        weak let released = service
        final class Out: @unchecked Sendable { var status: Int? }
        let out = Out()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            out.status = CCPoolTestClient.request(port: port, timeout: 10)?.status
            done.signal()
        }
        XCTAssertEqual(arrived.wait(timeout: .now() + 10), .success, "the request reached upstream")
        service = nil
        XCTAssertNil(released, "the service is gone while its request is in flight")
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success)
        if let s = out.status { XCTAssertEqual(s, 200, "a finished answer is whole") }
    }

    // 3.2: a port held by another ccpool proxy or by anything else is detected and left alone.
    func testCCPoolForeignOrPythonListenerIsRefused() throws {
        let python = try CCPoolFakeServer { _, _ in
            .respond(200, [("Server", "ccpool"), ("content-type", "application/json")], Data(#"{"service":"ccpool-proxy","pid":4242}"#.utf8))
        }
        let old = try CCPoolFakeServer { _, _ in .respond(404, [("Server", "ccpool"), ("Server", "upstream")], Data("not found".utf8)) }
        let foreign = try CCPoolFakeServer { _, _ in .respond(200, [("Server", "nginx")], Data("{}".utf8)) }
        defer { python.stop(); old.stop(); foreign.stop() }

        XCTAssertEqual(CCPoolPortProbe.probe(port: python.port, timeout: 5), .ccpool(pid: 4242, impl: nil))
        XCTAssertEqual(CCPoolPortProbe.probe(port: old.port, timeout: 5), .ccpool(pid: nil, impl: nil), "a proxy from before HEALTH is still recognised")
        XCTAssertEqual(CCPoolPortProbe.probe(port: foreign.port, timeout: 5), .other)

        let store = CCPoolStore(directory: tempDir())
        for (fake, want) in [(python, CCPoolService.Status.heldByCCPool(pid: 4242)), (foreign, .heldByOther)] {
            var cfg = CCPoolServiceConfig()
            cfg.port = fake.port
            cfg.upstream = URL(string: "http://127.0.0.1:9")!
            let svc = CCPoolService(config: cfg, store: store, secrets: CCPoolMemorySecrets(), logger: CCPoolCapturingLogger())
            XCTAssertEqual(svc.start(), want)
            XCTAssertEqual(svc.status, want, "not bound, never killed")
            svc.stop()
        }
        let freed = try CCPoolFakeServer { _, _ in .drop }
        let freePort = freed.port
        freed.stop()
        let deadline = Date().addingTimeInterval(3)
        var probe = CCPoolPortProbe.probe(port: freePort, timeout: 2)
        while probe != .free, Date() < deadline { probe = CCPoolPortProbe.probe(port: freePort, timeout: 2) }
        XCTAssertEqual(probe, .free, "nothing listening reads as free")
    }

    // Errata C1, below the cap: the body is buffered and replayed on the next account.
    func testCCPoolBodyBelowReplayCapIsReplayed() throws {
        let r = try rig(["one", "two"], replayCap: 64 << 10)
        r.anthropic.set { $0.spent = ["tok-one"] }
        r.setCurrent("one")
        let body = Self.body(size: 32 << 10)
        let resp = try XCTUnwrap(r.post(body: body))
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertEqual(r.anthropic.get { $0.seen }, ["Bearer tok-one", "Bearer tok-two"])
        XCTAssertEqual(r.anthropic.get { $0.bodySizes }, [body.count, body.count], "the replay carries the whole body")
    }

    // Errata C1, above the cap: streamed upstream once, never replayed; the 429 passes through and
    // the account is still benched.
    func testCCPoolBodyAboveReplayCapStreamsOnceNoReplay() throws {
        let r = try rig(["one", "two"], replayCap: 64 << 10)
        r.anthropic.set { $0.spent = ["tok-one"] }
        r.setCurrent("one")
        let body = Self.body(size: 100 << 10)
        let resp = try XCTUnwrap(r.post(body: body))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertEqual(r.anthropic.get { $0.seen }, ["Bearer tok-one"], "sent once, never replayed")
        XCTAssertEqual(r.anthropic.get { $0.bodySizes }, [body.count], "the stream carried the whole body")
        XCTAssertNotNil(r.cooldown("one")["five_hour"], "still benched")
        r.anthropic.clearSeen()
        let next = try XCTUnwrap(r.post(body: body))
        XCTAssertEqual(next.status, 200, "the next request goes to the next account")
        XCTAssertEqual(r.anthropic.get { $0.seen }, ["Bearer tok-two"])
        XCTAssertEqual(r.anthropic.get { $0.bodySizes }, [body.count])
    }

    /// A JSON body of exactly `size` bytes with the model first, as Claude Code sends it.
    static func body(size: Int, model: String = "claude-opus-5") -> Data {
        let head = #"{"model":"\#(model)","pad":""#
        let tail = #""}"#
        return Data(head.utf8) + Data(repeating: 97, count: size - head.utf8.count - tail.utf8.count) + Data(tail.utf8)
    }

    func testCCPoolScanModelFromBodyPrefix() {
        XCTAssertEqual(CCPoolConnection.scanModel(Data(#"{ "model" : "claude-fable-5", "x": 1"#.utf8)), "claude-fable-5")
        XCTAssertNil(CCPoolConnection.scanModel(Data(#"{"messages":[]"#.utf8)))
    }

    // Errata C7: the main thread is blocked for the whole request; it completes only because no
    // part of the proxy (listener queue, connection queue, URLSession delegate queue) hops to main.
    func testCCPoolEndToEndOnRealQueuesWithoutMainActor() throws {
        XCTAssertTrue(Thread.isMainThread, "this test blocks the main thread on purpose")
        let r = try rig(["one", "two"])
        r.log.forgetMain()
        r.anthropic.set { $0.spent = ["tok-one"] }
        r.setCurrent("one")
        let resp = try XCTUnwrap(r.post(), "a main-thread hop would deadlock here and time out")
        XCTAssertEqual(resp.status, 200)
        XCTAssertFalse(r.log.lines.isEmpty)
        XCTAssertFalse(r.log.onMain, "no proxy callback ran on the main thread")
        XCTAssertFalse(r.anthropic.get { $0.onMain })
    }

    // B20/B21: Refresh probes each account, records what it paid to learn.
    func testCCPoolRefreshUsageRecordsBenchesResetsAndHeadroom() async throws {
        let anthropic = CCPoolFakeAnthropic()
        let up = try CCPoolFakeServer { h, b in anthropic.reply(h, b) }
        defer { up.stop() }
        let store = CCPoolStore(directory: tempDir())
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "s-full", token: "tok-quota-s-full", secrets: secrets)
        try store.addAccount(label: "s-ok", token: "tok-ok-s-ok", secrets: secrets)
        anthropic.set { $0.usage = ["tok-quota-s-full": 0.995, "tok-ok-s-ok": 0.10] }
        let log = CCPoolCapturingLogger()
        let base = URL(string: "http://127.0.0.1:\(up.port)")!
        var report = await CCPoolUsage.refresh(store: store, secrets: secrets, base: base, logger: log)
        XCTAssertEqual(report.rows.map(\.label), ["s-full", "s-ok"])
        XCTAssertEqual(anthropic.get { $0.paths }, ["/v1/messages", "/v1/messages"])
        XCTAssertEqual(report.rows[1].limits?["seven_day_overage_included"]?.utilization, "0.34", "fable reported under its own claim")
        XCTAssertEqual(Array(report.rows[0].spent.keys), ["five_hour"], "the full one is flagged as benched")
        let st = store.snapshot
        XCTAssertGreaterThan(Double(st.accounts["s-full"]?.cooldown["five_hour"] ?? 0), Date().timeIntervalSince1970 + 1800,
                             "the reset is Anthropic's, not a 15-minute guess")
        XCTAssertEqual(st.accounts["s-ok"]?.cooldown, [:], "the healthy one is not benched")
        XCTAssertNotNil(st.accounts["s-ok"]?.reset["five_hour"], "only its rollover recorded")

        store.mutate { $0.hold("s-ok", hours: 24, now: Date().timeIntervalSince1970) }
        report = await CCPoolUsage.refresh(store: store, secrets: secrets, base: base, logger: log)
        XCTAssertEqual(Array(report.rows[1].held.keys), ["five_hour"], "a hand-held account says so, on which claim")
        XCTAssertEqual(report.pool.first { $0.claim == "five_hour" }?.free ?? -1, 0, accuracy: 1e-9, "and stops counting toward headroom")

        store.mutate { $0.accounts["s-ok"]?.cooldown = ["seven_day_overage_included": Int(Date().timeIntervalSince1970) + 4 * 86400] }
        report = await CCPoolUsage.refresh(store: store, secrets: secrets, base: base, logger: log)
        XCTAssertEqual(Array(report.rows[1].held.keys), ["seven_day_overage_included"], "the hold names Fable")
        XCTAssertGreaterThan(report.pool.first { $0.claim == "five_hour" }?.free ?? 0, 0, "its 5h still counts")
        XCTAssertEqual(report.pool.first { $0.claim == "seven_day_overage_included" }?.free ?? -1, 0, accuracy: 1e-9, "its Fable does not")

        let unreachable = await CCPoolUsage.probe(token: "tok-x", base: URL(string: "http://127.0.0.1:9")!, timeout: 2)
        XCTAssertNil(unreachable, "a probe that cannot answer is unknown, never healthy")
    }

    // Leak guard: add, proxy, rotation, refresh, every error string, the health body and the state
    // file never contain a dummy token.
    func testCCPoolLeakGuardNoTokenAnywhere() async throws {
        let r = try rig(["one", "two", "three"])
        var texts: [String] = []
        for bad in [("", "tok-empty-label"), ("one", "tok-dup"), ("four", "")] {
            do { try r.store.addAccount(label: bad.0, token: bad.1, secrets: r.secrets) } catch { texts.append("\(error)") }
        }
        texts += [CCPoolSecretsError.unavailable, .failed(-25300)].map { "\($0)" }
        r.anthropic.set { $0.spent = ["tok-one"]; $0.overload = ["tok-three"] }
        r.setCurrent("one")
        texts.append(r.post()?.text ?? "")                     // rotation one -> two
        r.anthropic.set { $0.spent = ["tok-one", "tok-two"] }
        texts.append(r.post()?.text ?? "")                     // rotation two -> three, 429 passes through
        r.anthropic.set { $0.spent = ["tok-one", "tok-two", "tok-three"]; $0.overload = [] }
        r.store.mutate { $0.clear("three") }
        texts.append(r.post()?.text ?? "")                     // all benched
        texts.append(CCPoolTestClient.request(port: r.port, method: "GET", path: CCPoolService.healthPath, headers: [])?.text ?? "")
        texts.append(String(decoding: r.service.healthBody(), as: UTF8.self))
        _ = await CCPoolUsage.refresh(store: r.store, secrets: r.secrets, base: r.service.config.upstream, logger: r.log)
        texts.append("\(r.service.status)")
        texts += r.log.lines
        texts.append(try String(contentsOf: r.store.stateURL, encoding: .utf8))
        XCTAssertGreaterThan(r.anthropic.get { $0.seen }.count, 3, "the flows really ran")
        XCTAssertTrue(r.anthropic.get { $0.seen }.contains("Bearer tok-two"), "the upstream did get the token")
        for t in texts { XCTAssertFalse(t.contains("tok-"), "token leaked into: \(t.prefix(300))") }
        XCTAssertFalse(r.log.lines.contains { $0.lowercased().contains("bearer") || $0.lowercased().contains("authorization") })
    }
}
