import Foundation
import Network

/// The request line and headers of one client request.
struct CCPoolRequestHead: Sendable {
    var method: String
    var path: String
    /// In arrival order, original case.
    var headers: [(name: String, value: String)]

    func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name }?.value
    }

    enum Parse {
        case head(CCPoolRequestHead, contentLength: Int, rest: Data)
        case bad(String)
    }

    static let maxHead = 64 << 10

    /// nil while the header block is incomplete.
    static func parse(_ buffer: Data) -> Parse? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHead ? .bad("request header too large") : nil
        }
        guard let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .bad("malformed request") }
        var lines = text.components(separatedBy: "\r\n")
        let line = lines.removeFirst().split(separator: " ")
        guard line.count >= 2, line[1].hasPrefix("/") else { return .bad("malformed request line") }
        var headers: [(name: String, value: String)] = []
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers.append((name: l[..<c].trimmingCharacters(in: .whitespaces), value: l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)))
        }
        let head = CCPoolRequestHead(method: String(line[0]), path: String(line[1]), headers: headers)
        // Bodies are framed by Content-Length only; anything else would make the boundary a guess.
        if head.header("transfer-encoding") != nil { return .bad("chunked request bodies are not supported") }
        let lengths = headers.filter { $0.0.lowercased() == "content-length" }
        guard lengths.count <= 1 else { return .bad("duplicate Content-Length") }
        var length = 0
        if let raw = lengths.first?.1 {
            guard let n = Int(raw), n >= 0 else { return .bad("bad Content-Length") }
            length = n
        }
        return .head(head, contentLength: length, rest: Data(buffer[end.upperBound...]))
    }
}

/// One upstream attempt. Late callbacks of a superseded attempt are dropped by identity.
final class CCPoolExchange: CCPoolUpstreamHandler, @unchecked Sendable {
    enum Mode { case deciding, snippet, streaming }
    weak var connection: CCPoolConnection?
    let label: String
    let accountID: String
    let retried: Bool
    var task: URLSessionDataTask?
    var mode = Mode.deciding
    var snippet = Data()
    var pendingNote = ""
    var suspended = false

    init(connection: CCPoolConnection, label: String, accountID: String, retried: Bool) {
        self.connection = connection
        self.label = label
        self.accountID = accountID
        self.retried = retried
    }

    func upstreamResponse(_ response: HTTPURLResponse, decide: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let c = connection else { return decide(.cancel) }
        c.queue.async { c.onResponse(self, response, decide: decide) }
    }

    func upstreamData(_ data: Data) {
        guard let c = connection else { return }
        c.queue.async { c.onData(self, data) }
    }

    func upstreamDone(_ error: Error?) {
        guard let c = connection else { return }
        c.queue.async { c.onDone(self, error) }
    }
}

/// One client connection: parse one request, relay it, close (B18: the downstream connection is
/// closed per response). Every method below runs on `queue`.
final class CCPoolConnection: @unchecked Sendable {
    /// Hop-by-hop headers plus the ones the proxy owns (B10). The client's own credential never
    /// goes upstream. accept-encoding: URLSession decodes what it asked for, so it asks itself.
    static let stripRequest: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                                            "te", "trailers", "transfer-encoding", "upgrade", "host",
                                            "authorization", "x-api-key", "content-length", "expect", "accept-encoding"]
    /// content-encoding: URLSession hands over decoded bytes, so the upstream's encoding no longer applies.
    static let stripResponse: Set<String> = ["connection", "transfer-encoding", "content-length", "keep-alive",
                                             "content-encoding"]
    /// Flow control: suspend the upstream task while this much is queued for a slow client.
    static let highWater = 4 << 20
    static let lowWater = 1 << 20
    /// How much of a streamed (above-cap) body is read before picking, to find the model.
    static let modelScan = 64 << 10
    /// At most this much of an upstream error body reaches the log (B28).
    static let snippetCap = 200

    let queue = DispatchQueue(label: "com.prosper.ccpool.conn")
    private let conn: NWConnection
    // X16: the dependencies are held strongly, never the service: a callback that outlives the
    // service (released without stop()) must find what it needs, not trap on a dead reference.
    private let config: CCPoolServiceConfig
    private let store: CCPoolStore
    private let secrets: CCPoolSecrets
    private let log: CCPoolLogger
    private let upstream: CCPoolUpstream
    /// The port the listener is bound to, for the Host check.
    private let boundPort: UInt16
    private let onClose: @Sendable (ObjectIdentifier) -> Void
    private var closed = false

    private var buffer = Data()
    private var head: CCPoolRequestHead?
    private var expected = 0
    private var body = Data()
    private var relayStarted = false

    // Above-cap body: streamed upstream once through a bound stream pair, never replayed (C1).
    private var streamed = false
    private var bodyOut: OutputStream?
    private var bodyIn: InputStream?
    private var pumped = 0
    private let pump = DispatchQueue(label: "com.prosper.ccpool.pump")
    private let abortLock = NSLock()
    private var aborted = false

    private var model: String?
    private var tried: Set<String> = []
    private var attempts = 0
    private var maxAttempts = 1
    private var exchange: CCPoolExchange?
    private var headSent = false
    private var outstanding = 0

    init(conn: NWConnection, config: CCPoolServiceConfig, store: CCPoolStore, secrets: CCPoolSecrets, logger: CCPoolLogger,
         upstream: CCPoolUpstream, boundPort: UInt16, onClose: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.conn = conn
        self.config = config
        self.store = store
        self.secrets = secrets
        self.log = logger
        self.upstream = upstream
        self.boundPort = boundPort
        self.onClose = onClose
    }

    /// The service went away without stop(): drop the client and the upstream attempt.
    deinit {
        exchange?.task?.cancel()
        conn.cancel()
    }

    /// Errata E6: only a local, non-browser caller is served. Host must appear once and be
    /// 127.0.0.1 or localhost, with or without the bound port; any Origin header is refused
    /// (DNS rebinding reads health and relays; a simple cross-origin POST spends quota).
    static func admits(_ head: CCPoolRequestHead, port: UInt16) -> Bool {
        let hosts = head.headers.filter { $0.name.lowercased() == "host" }.map { $0.value.lowercased() }
        guard hosts.count == 1, let host = hosts.first else { return false }
        guard head.header("origin") == nil else { return false }
        let allowed = ["127.0.0.1", "localhost"].flatMap { [$0, "\($0):\(port)"] }
        return allowed.contains(host)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let ex = exchange { exchange = nil; ex.task?.cancel() }
        abortPump()
        conn.cancel()
        onClose(ObjectIdentifier(self))
    }

    // MARK: Client side

    private func receive() {
        guard !closed else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var again = true
            if let data, !data.isEmpty { again = self.ingest(data) }
            if done || error != nil { self.close() } else if again { self.receive() }
        }
    }

    /// Returns false when the pump will call `receive()` itself once the bytes are written.
    private func ingest(_ data: Data) -> Bool {
        guard head != nil else {
            buffer.append(data)
            return parseHead()
        }
        return takeBody(data)
    }

    private func parseHead() -> Bool {
        switch CCPoolRequestHead.parse(buffer) {
        case nil: return true
        case .bad(let why):
            buffer = Data()
            head = CCPoolRequestHead(method: "", path: "", headers: [])
            relayStarted = true   // answered: later bytes are ignored
            fail(400, why, type: "invalid_request_error")
            return true
        case .head(let h, let length, let rest):
            buffer = Data()
            head = h
            expected = length
            guard Self.admits(h, port: boundPort) else {
                relayStarted = true
                log.note(nil, "refused a request: Host or Origin is not a local caller")
                fail(403, "forbidden", type: "permission_error")
                return true
            }
            if h.method == "GET", h.path == CCPoolService.healthPath {
                relayStarted = true
                sendHealth()
                return true
            }
            if h.header("expect")?.lowercased() == "100-continue", length > 0 {
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
            streamed = length > config.replayCap
            return takeBody(rest)
        }
    }

    private func takeBody(_ data: Data) -> Bool {
        if relayStarted {
            guard streamed, pumped < expected, !data.isEmpty else { return true }
            pumpBody(data.prefix(expected - pumped))
            return false
        }
        body.append(data.prefix(expected - body.count))
        if !streamed {
            guard body.count >= expected else { return true }
            model = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String
            startRelay()
            return true
        }
        guard body.count >= min(Self.modelScan, expected) else { return true }
        model = Self.scanModel(body)
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1 << 16, inputStream: &input, outputStream: &output)
        bodyIn = input
        bodyOut = output
        let prefix = body
        body = Data()
        startRelay()
        pumpBody(prefix)
        return false
    }

    /// Best-effort top-level "model" from the start of a JSON body too large to parse whole.
    static func scanModel(_ prefix: Data) -> String? {
        let text = String(decoding: prefix, as: UTF8.self)
        guard let r = text.range(of: #""model"\s*:\s*"([^"\\]{1,200})""#, options: .regularExpression) else { return nil }
        let m = text[r]
        guard let open = m.dropLast().lastIndex(of: "\"") else { return nil }
        return String(m[m.index(after: open)..<m.index(before: m.endIndex)])
    }

    /// Write body bytes into the bound stream on the pump queue, then resume reading the client.
    /// shortcut: polls hasSpaceAvailable (1 ms) instead of run-loop scheduling; only bodies above
    /// the replay cap take this path. Upgrade to a scheduled stream if that ever matters.
    private func pumpBody(_ chunk: Data) {
        guard bodyOut != nil else { return }
        let count = chunk.count
        let total = expected
        pump.async { [weak self] in
            guard let self, let out = self.bodyOut else { return }
            if out.streamStatus == .notOpen { out.open() }
            var off = 0
            chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                while off < count, !self.isAborted {
                    guard out.hasSpaceAvailable else { usleep(1000); continue }
                    let n = out.write(base + off, maxLength: count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            self.queue.async {
                self.pumped += count
                if self.pumped >= total { self.pump.async { self.bodyOut?.close() } }
                self.receive()
            }
        }
    }

    private var isAborted: Bool { abortLock.withLock { aborted } }

    private func abortPump() {
        abortLock.withLock { aborted = true }
        if bodyOut != nil { pump.async { [weak self] in self?.bodyOut?.close() } }
    }

    // MARK: Relay

    private func startRelay() {
        relayStarted = true
        maxAttempts = max(1, store.read { $0.order.count })
        attempt()
    }

    private func attempt() {
        guard !closed else { return }
        guard attempts < maxAttempts else { return noAccounts() }
        attempts += 1
        let now = store.now
        guard let label = store.read({ CCPoolCore.pick($0, model: model, exclude: tried, now: now) }) else { return noAccounts() }
        tried.insert(label)
        guard let id = store.read({ $0.accounts[label]?.id }) else { return attempt() }
        send(label: label, accountID: id, retried: false)
    }

    private func send(label: String, accountID: String, retried: Bool) {
        guard let head else { return }
        // The token lives in this request only: read per attempt, never kept on the connection.
        guard let token = (try? secrets.token(id: accountID)) ?? nil, !token.isEmpty else {
            log.note(label, "token unavailable; skipping this account")
            return attempt()
        }
        let base = config.upstream.absoluteString.hasSuffix("/")
            ? String(config.upstream.absoluteString.dropLast()) : config.upstream.absoluteString
        guard let url = URL(string: base + head.path) else { return fail(400, "bad request path", type: "invalid_request_error") }
        var req = URLRequest(url: url, timeoutInterval: config.timeout)
        req.httpMethod = head.method
        for (name, value) in head.headers where !Self.stripRequest.contains(name.lowercased()) {
            req.addValue(value, forHTTPHeaderField: name)
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if streamed {
            req.httpBodyStream = bodyIn
            bodyIn = nil
            req.setValue(String(expected), forHTTPHeaderField: "Content-Length")
        } else if !body.isEmpty {
            req.httpBody = body
        }
        let ex = CCPoolExchange(connection: self, label: label, accountID: accountID, retried: retried)
        exchange = ex
        ex.task = upstream.start(req, accountID: accountID, handler: ex)
    }

    private var replayable: Bool { !streamed && !headSent }

    func onResponse(_ ex: CCPoolExchange, _ response: HTTPURLResponse, decide: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard ex === exchange, !closed else { return decide(.cancel) }
        let label = ex.label
        let now = store.now
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let k = k as? String { headers[k.lowercased()] = "\(v)" }
        }
        let (limits, unknown) = CCPoolCore.parseLimits(headers)
        if !unknown.isEmpty { log.note(label, "unknown claim window \(unknown.joined(separator: ",")); not benching on it") }
        store.mutate { $0.remember(label) }

        if response.statusCode == 429 {
            var spent = CCPoolCore.exhaustedClaims(limits, now: now, threshold: config.exhaustedThreshold)
            let retry = headers["retry-after"]
            let wait = Int(retry?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            let detail = limits.isEmpty ? "NO unified rate-limit headers"
                : limits.keys.sorted().map { "\($0)=\(limits[$0]?.status ?? "?")/\(limits[$0]?.utilization ?? "?")" }.joined(separator: ", ")
            var reason = spent.isEmpty ? "no exhausted quota" : "reported exhausted quota"
            if spent.isEmpty, wait > CCPoolCore.longRetryAfter {
                // The cooldown belongs to the requested model's weekly claim, not every model.
                let claim = CCPoolCore.isKnownModel(model) ? CCPoolCore.claims(for: model).last! : CCPoolCore.fiveHour
                spent = [claim: Int(now) + wait]
                reason = "long Retry-After for requested model"
            }
            let line = "429 model=\(model ?? "none"); quota=\(detail); retry-after=\(retry ?? "?"); "
                + "cooldown=\(spent.isEmpty ? "none" : spent.keys.sorted().joined(separator: ",")); reason=\(reason)"
            if spent.isEmpty {
                // Upstream load, not quota: rotating would not help and benching would be a lie (B14).
                ex.mode = .snippet
                ex.pendingNote = line
                return decide(.allow)
            }
            log.note(label, line)
            store.mutate { st in for (claim, until) in spent { st.bench(label, claim: claim, until: until, now: now) } }
            let claims = spent.keys.sorted().joined(separator: ",")
            if replayable {
                log.note(label, "out on \(claims); rotating to another account and retrying request")
                exchange = nil
                decide(.cancel)
                return attempt()
            }
            // Errata C1: the body went upstream as a stream and cannot be sent again.
            log.note(label, "out on \(claims); request body above the replay cap, passing the 429 through")
        } else {
            // Retire before streaming: the body can take a minute to drain (B15).
            let spent = CCPoolCore.exhaustedClaims(limits, now: now, threshold: config.exhaustedThreshold)
            store.mutate { st in
                st.recordResets(label, limits: limits, now: now)
                for (claim, until) in spent { st.bench(label, claim: claim, until: until, now: now) }
            }
            if !spent.isEmpty {
                log.note(label, "now full on \(spent.keys.sorted().joined(separator: ",")); retired before it could reject anything")
            }
        }
        writeHead(response.statusCode, headers)
        ex.mode = .streaming
        decide(.allow)
    }

    func onData(_ ex: CCPoolExchange, _ data: Data) {
        guard ex === exchange, !closed else { return }
        switch ex.mode {
        case .deciding: return
        case .snippet:
            ex.snippet.append(data.prefix(Self.snippetCap - ex.snippet.count))
            if ex.snippet.count >= Self.snippetCap { finishSnippet(ex) }
        case .streaming:
            var frame = Data(String(data.count, radix: 16, uppercase: true).utf8)
            frame.append(contentsOf: [13, 10])
            frame.append(data)
            frame.append(contentsOf: [13, 10])
            outstanding += frame.count
            if outstanding > Self.highWater, !ex.suspended { ex.suspended = true; ex.task?.suspend() }
            let n = frame.count
            conn.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.outstanding -= n
                if error != nil { return self.close() }
                if ex.suspended, self.outstanding < Self.lowWater { ex.suspended = false; ex.task?.resume() }
            })
        }
    }

    func onDone(_ ex: CCPoolExchange, _ error: Error?) {
        guard ex === exchange, !closed else { return }
        switch ex.mode {
        case .deciding:
            let code = (error as? URLError)?.code
            if code == .networkConnectionLost, !ex.retried, !streamed {
                // A pooled connection the far end closed: nothing was processed, nothing went
                // downstream, so one fresh attempt on the same account is safe (B17).
                log.note(ex.label, "upstream connection dropped before a response; retrying once")
                return send(label: ex.label, accountID: ex.accountID, retried: true)
            }
            log.note(ex.label, "upstream unreachable (\(code.map { "\($0.rawValue)" } ?? "error"))")
            exchange = nil
            fail(502, "upstream unreachable", type: "api_error")
        case .snippet:
            finishSnippet(ex)
        case .streaming:
            exchange = nil
            guard error == nil else { return close() }
            conn.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }

    /// Log the pass-through 429 with at most 200 bytes of the upstream body, then answer it.
    private func finishSnippet(_ ex: CCPoolExchange) {
        guard ex === exchange else { return }
        exchange = nil
        ex.task?.cancel()
        log.note(ex.label, ex.pendingNote + "; body=" + String(decoding: ex.snippet.prefix(Self.snippetCap), as: UTF8.self))
        fail(429, "upstream rate limit (not account quota)", type: "rate_limit_error")
    }

    private func noAccounts() {
        exchange = nil
        let when = store.read { CCPoolCore.nextReset($0, model: model, now: store.now) }
        var hint = ""
        if let when {
            let f = DateFormatter()
            f.dateFormat = "EEE HH:mm"
            hint = " Earliest reset \(f.string(from: Date(timeIntervalSince1970: Double(when))))."
        }
        log.note(nil, "every account is benched.\(hint)")
        fail(429, "all pooled accounts are rate limited.\(hint)", type: "rate_limit_error")
    }

    // MARK: Writers

    private func writeHead(_ status: Int, _ headers: [String: String]) {
        headSent = true
        var h = "HTTP/1.1 \(status) \(Self.reason(status))\r\nServer: \(CCPoolService.serverHeader)\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) where !Self.stripResponse.contains(k) {
            h += "\(k): \(v)\r\n"
        }
        h += "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
        conn.send(content: Data(h.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func sendHealth() {
        sendComplete(200, contentType: "application/json", body: CCPoolService.healthBody(store: store))
    }

    func fail(_ status: Int, _ message: String, type: String) {
        let obj: [String: Any] = ["type": "error", "error": ["type": type, "message": "ccpool: \(message)"]]
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        sendComplete(status, contentType: "application/json", body: body)
    }

    private func sendComplete(_ status: Int, contentType: String, body: Data) {
        headSent = true
        var out = Data(("HTTP/1.1 \(status) \(Self.reason(status))\r\nServer: \(CCPoolService.serverHeader)\r\n"
            + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 429: return "Too Many Requests"
        case 502: return "Bad Gateway"
        default: return HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }
}
