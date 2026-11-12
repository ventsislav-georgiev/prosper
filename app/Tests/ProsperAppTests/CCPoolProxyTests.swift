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
    }

    private let queue = DispatchQueue(label: "ccpool.test.fake")
    private let listener: NWListener
    private let lock = NSLock()
    private var live: [NWConnection] = []
    private var _accepted = 0
    private var _dropReused = 0
    private var _reusedDropped = 0
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
    private(set) var seen: [String] = []       // Authorization values answered, in order
    private(set) var apiKeys: [String] = []    // x-api-key values received
    private(set) var bodySizes: [Int] = []
    private(set) var paths: [String] = []
    private(set) var dropped = 0
    private(set) var onMain = false

    func set(_ body: (CCPoolFakeAnthropic) -> Void) { lock.withLock { body(self) } }
    func get<T>(_ body: (CCPoolFakeAnthropic) -> T) -> T { lock.withLock { body(self) } }
    func clearSeen() { lock.withLock { seen = []; apiKeys = []; bodySizes = []; paths = [] } }

    func reply(_ head: CCPoolRequestHead, _ body: Data) -> CCPoolFakeServer.Reply {
        lock.withLock {
            if Thread.isMainThread { onMain = true }
            if dropNext > 0 { dropNext -= 1; dropped += 1; return .drop }
            let auth = head.header("authorization") ?? ""
            seen.append(auth)
            if let k = head.header("x-api-key") { apiKeys.append(k) }
            bodySizes.append(body.count)
            paths.append(head.path)
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

    static func exchange(port: UInt16, send: Data, readAtMost: Int? = nil, timeout: TimeInterval) -> Data? {
        let q = DispatchQueue(label: "ccpool.test.client")
        let c = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        @Sendable func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                if let d { box.data.append(d) }
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
