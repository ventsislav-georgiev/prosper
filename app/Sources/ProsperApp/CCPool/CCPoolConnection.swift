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
    /// #1259: the account came from a pin (CCPoolCore.route), not from `pick`.
    let followedPin: Bool
    var task: URLSessionDataTask?
    var mode = Mode.deciding
    var snippet = Data()
    var pendingNote = ""
    /// #1263: the reason words and the response header names (already through the name rule) of that note.
    var pendingReason = ""
    var responseHeaders = ""
    /// The upstream x-should-retry word of that note ("true", "false", "absent" or "other").
    var shouldRetry = "absent"
    /// The private part of that note: the model and the upstream body (QA #733 INFO-3).
    var pendingPrivate = ""
    /// The upstream Retry-After of a pass-through 429, handed on to the client (P2a follow-up a).
    var retryAfter: String?
    /// #1878: that 429 carried the unified rate-limit headers (an account-level refusal); without them upstream refused
    /// the request itself, and neither a re-place nor a shun helps.
    var unified = false
    var suspended = false
    /// #1260, #1482: reads the usage off every relayed reply (the record); `fiveHour` is set only where learn runs
    /// (a 200 that is not a quota check). The status and the rate-limit rows go to the usage record.
    var tap: CCPoolUsageTap?
    var fiveHour: CCPoolLimit?
    var status = 0
    var limits: [String: CCPoolLimit] = [:]
    /// #2006: a Codex 429's response headers, kept for its spent check once the body snippet is in.
    var upstreamHeaders: [String: String] = [:]
    /// #2015: a Codex 400 after an account move, its head held back while its body is read for an encrypted-content error.
    var held400 = false
    /// #2007: the Codex access token this attempt sent (never logged), and whether its login can refresh.
    var codexAccess: String?
    var canRefresh = false

    init(connection: CCPoolConnection, label: String, accountID: String, retried: Bool, followedPin: Bool) {
        self.connection = connection
        self.label = label
        self.accountID = accountID
        self.retried = retried
        self.followedPin = followedPin
    }

    func upstreamResponse(_ response: HTTPURLResponse, decide: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let c = connection else { return decide(.cancel) }
        c.queue.async { c.onResponse(self, response, decide: decide) }
    }

    func upstreamData(_ data: Data) {
        guard let c = connection else { return }
        c.queue.async { c.onData(self, data) }
    }

    func upstreamDone(_ error: Error?, reused: Bool) {
        guard let c = connection else { return }
        c.queue.async { c.onDone(self, error, reused: reused) }
    }
}

/// One client connection: parse one request, relay it, close (B18: the downstream connection is
/// closed per response). Every method below runs on `queue`.
final class CCPoolConnection: @unchecked Sendable {
    /// Hop-by-hop headers plus the ones the proxy owns (B10). The client's own credential never
    /// goes upstream. accept-encoding: URLSession decodes what it asked for, so it asks itself.
    static let stripRequest = ClaudeHarness.stripRequest
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
    /// At most this many bytes of a client model name or an upstream Retry-After reach the log.
    static let logFieldCap = 64

    static func capped(_ s: String) -> String { String(decoding: s.utf8.prefix(logFieldCap), as: UTF8.self) }

    /// #2004: Claude's request rules live in ClaudeHarness; these names forward to them.
    static let oauthBeta = ClaudeHarness.oauthBeta
    static func withOAuthBeta(_ list: String?) -> String { ClaudeHarness.withOAuthBeta(list) }

    /// #1256 delay seam: run `go` on `queue` after `seconds`. Tests install a recorder that records the
    /// seconds and continues at once; no test runs this default.
    nonisolated(unsafe) static var throttleWait: @Sendable (_ seconds: Int, _ queue: DispatchQueue,
                                                            _ go: @escaping @Sendable () -> Void) -> Void = { seconds, queue, go in
        queue.asyncAfter(deadline: .now() + .seconds(seconds), execute: go)
    }

    static func isQuotaCheck(_ obj: [String: Any]?) -> Bool { ClaudeHarness.isQuotaCheck(obj) }
    static func pinKey(_ head: CCPoolRequestHead) -> String? { ClaudeHarness.pinKey(head) }

    let queue = DispatchQueue(label: "com.prosper.ccpool.conn")
    /// #1675: the client socket (CCPoolFDTransport in production; NWConnection before).
    private let conn: CCPoolTransport
    // X16: the dependencies are held strongly, never the service: a callback that outlives the
    // service (released without stop()) must find what it needs, not trap on a dead reference.
    private let config: CCPoolServiceConfig
    /// #2004: the harness this connection's request is for, chosen once from the head (#2005: `/codex` is Codex's).
    private var harness: any PoolHarness = ClaudeHarness()
    /// #2005: the upstream URL text of this request: the harness's upstream plus the path, the `/codex` prefix stripped.
    private var target = ""
    private let store: CCPoolStore
    private let secrets: CCPoolSecrets
    private let log: CCPoolLogger
    private let upstream: CCPoolUpstream
    /// The port the listener is bound to, for the Host check.
    private let boundPort: UInt16
    private let onClose: @Sendable (ObjectIdentifier) -> Void
    private let record: CCPoolUsageRecord?
    /// #1667: the event record (bench, rotate, retire, throttle-move, pin-back, all-benched), by account label.
    private let events: CCPoolEventRecord?
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
    /// #1263: "bytes=N; max_tokens=X; effort=E; speed=S" of the request, public words and counts only (CCPoolThrottleShape).
    private var shape = "bytes=0; max_tokens=none; effort=none; speed=none"
    private var tried: Set<String> = []
    private var attempts = 0
    private var maxAttempts = 1
    private var exchange: CCPoolExchange?
    private var headSent = false
    private var outstanding = 0
    /// #1256: the body is the client's quota check; its throughput 429 goes back at once.
    private var quotaCheck = false
    /// #1256: same-account retries of a throughput 429 made so far (at most throttleBackoff.count).
    private var throttleRetries = 0
    /// #1256: the 429 being retried, while its retry waits or is in flight; the retry never leaves its account.
    private var retryingThrottle: CCPoolExchange?
    /// #1259: the LAST route call of this request followed a pin; its reply does not move `current`.
    private var followedPin = false
    /// #1262: the first account's last throughput 429 once the conversation made its ONE move (Python `moved`, `back`).
    private var movedFrom: CCPoolExchange?
    /// #1855: the first account's 429 once a keyed quota check was re-placed (its ONE re-placement); nowhere else to go
    /// answers with it.
    private var replacedFrom: CCPoolExchange?
    /// #2015: the body was sent again without its encrypted reasoning items; a second encrypted 400 passes through.
    private var strippedReplay = false
    /// #2007: the Codex login was refreshed after a 401 and the request replayed (once); a second 401 marks it refused.
    private var refreshed401 = false
    /// #2007: the service's Codex refresher (nil: no refresh, a 401 marks the account refused at once).
    private let keeper: CodexTokenKeeper?
    /// #1482: when the relay started, and how the last account was chosen ("pin", "place" or "pick").
    private var startedAt = 0.0
    private var routed = "pick"

    init(conn: CCPoolTransport, config: CCPoolServiceConfig, store: CCPoolStore, secrets: CCPoolSecrets, logger: CCPoolLogger,
         upstream: CCPoolUpstream, boundPort: UInt16, record: CCPoolUsageRecord? = nil, events: CCPoolEventRecord? = nil,
         keeper: CodexTokenKeeper? = nil, onClose: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.conn = conn
        self.config = config
        self.store = store
        self.secrets = secrets
        self.log = logger
        self.upstream = upstream
        self.boundPort = boundPort
        self.record = record
        self.events = events
        self.keeper = keeper
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
        conn.start(queue: queue) { [weak self] in self?.close() }
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        if retryingThrottle != nil, exchange == nil { log.note(nil, "client left during a throttle wait; no retry") }
        if let ex = exchange {
            exchange = nil
            ex.task?.cancel()
            // The client left while the reply streamed: still a relayed reply, not a clean end.
            if ex.mode == .streaming { recordRow(ex, done: false) }
        }
        abortPump()
        conn.cancel()
        onClose(ObjectIdentifier(self))
    }

    // MARK: Client side

    private func receive() {
        guard !closed else { return }
        conn.receive { [weak self] data, done, error in
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
            // P2a (b): the query string does not make health a relayed request.
            if h.method == "GET", h.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first == Substring(CCPoolService.healthPath) {
                relayStarted = true
                sendHealth()
                return true
            }
            let bare = String(h.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            if Self.controlRoutes.contains(bare) {
                relayStarted = true   // #1674: answered here, never relayed; the body is ignored
                control(bare, h, bodyLength: length)
                return true
            }
            // #2005: the harness is chosen once, here, before any account is picked.
            let codexRest = CCPoolCodexHarness.rest(of: h.path)
            if codexRest != nil {
                harness = CCPoolCodexHarness()
                // The socket speaks HTTP/1.1 only: a WebSocket upgrade is answered, never relayed as a plain GET.
                if h.header("upgrade")?.lowercased().contains("websocket") == true {
                    relayStarted = true
                    sendText(501, "ccpool: Codex over WebSocket is not supported by the pool; use HTTP (SSE)")
                    return true
                }
                config.codexReach.served()   // #2009: once per request (the routed-but-silent detector)
            }
            let base = (codexRest == nil ? config.upstream : config.codexUpstream).absoluteString
            target = (base.hasSuffix("/") ? String(base.dropLast()) : base) + (codexRest ?? h.path)
            if h.header("expect")?.lowercased() == "100-continue", length > 0 {
                conn.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: nil)
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
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            model = obj?["model"] as? String
            quotaCheck = harness.isQuotaCheck(obj)
            shape = CCPoolThrottleShape.request(bytes: body.count, obj)
            startRelay()
            return true
        }
        guard body.count >= min(Self.modelScan, expected) else { return true }
        model = Self.scanModel(body)
        shape = CCPoolThrottleShape.request(bytes: expected, nil)
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
        startedAt = store.now
        // #1256: accounts + the throttle retries (Python's bound), so the retries never cut the walk short.
        maxAttempts = max(1, store.read { $0.order.count }) + CCPoolCore.throttleBackoff.count
        // #2005: this harness's accounts of a login kind it cannot use are never tried (Claude accepts every kind).
        let h = harness
        tried = store.read { st in Set(st.accounts.filter { $0.value.harness == h.id && !h.accepts(kind: $0.value.kind) }.keys) }
        attempt()
    }

    /// #1262: `last` is set only for the one move: nowhere to go then ends the request with that 429, never a walk.
    /// #1667: `rotatingFrom` is the benched account a rotation left; its rotate row (and a move's row) is written here,
    /// where the destination is known (`to` nil: nowhere to go, the all-benched or pin-back row follows).
    private func attempt(moving last: CCPoolExchange? = nil, rotatingFrom: String? = nil) {
        guard !closed else { return }
        func went(_ to: String?) {
            if let rotatingFrom { event(.rotate, from: rotatingFrom, to: to) }
            if let last { event(.throttleMove, from: last.label, to: to) }
        }
        guard attempts < maxAttempts else { went(nil); return noAccounts() }
        attempts += 1
        let now = store.now
        // #1259: a keyed request follows (and pins) its session; no usable key = `pick` as before, nothing changed.
        let key = head.flatMap({ harness.pinKey($0) })
        let picked: String?
        // #1278: a refused token is skipped (pins too). Nothing else left and not the move: a last resort routes once
        // more ignoring refusal only (cooldowns still count), so the result can only be a refused account.
        // R1278b-a: only when no account outside the refused ones is left at all; one that is merely benched could
        // serve later, so the client gets today's 429 with its reset time instead of a rejected token's 401.
        func lastResort(_ st: CCPoolState) -> Bool {
            last == nil && replacedFrom == nil && !st.accounts.contains { $0.value.harness == harness.id && !tried.contains($0.key) && $0.value.refused == nil }
        }
        var anyway = false
        if key == nil {
            picked = store.read { st -> String? in
                if let n = CCPoolCore.pick(st, model: model, exclude: tried.union(st.refusedLabels), now: now, harness: harness) { return n }
                guard lastResort(st) else { return nil }
                anyway = true
                return CCPoolCore.pick(st, model: model, exclude: tried, now: now, harness: harness)
            }
            followedPin = false
            routed = "pick"
        } else {
            var followed = false
            // #1677: the pane's "Move off an account at" steers new placements only; exhaustion stays at 1.0.
            let share = config.exhaustedThreshold
            var skipped: String?
            picked = store.mutate { st -> String? in
                var exclude = tried.union(st.refusedLabels)
                var (name, next, f) = CCPoolCore.route(st, key: key, quotaCheck: quotaCheck, model: model,
                                                       exclude: exclude, now: now, share: share, harness: harness)
                if name == nil, lastResort(st) {
                    anyway = true
                    exclude = tried
                    (name, next, f) = CCPoolCore.route(st, key: key, quotaCheck: quotaCheck, model: model, exclude: exclude, now: now, share: share,
                                                       harness: harness)
                }
                // The account a placement at 1.0 would have taken, when the share moved it elsewhere (only below 1.0).
                if share < CCPoolCore.exhaustedDefault, !f, let name,
                   let plain = CCPoolCore.place(st, model: model, exclude: exclude, now: now, harness: harness), plain != name {
                    skipped = plain
                }
                st = next
                followed = f
                return name
            }
            if let skipped, let picked { log.note(skipped, "over share; new conversation placed on \(picked)") }
            // #1262: the move does not move `current` (Python's move calls place(), not choose()'s remember_last).
            // #1855: nor does a quota check's re-placement.
            followedPin = followed || last != nil || replacedFrom != nil
            routed = followed ? "pin" : "place"
        }
        went(picked)
        guard let label = picked else {
            if let last { return pinBack(last, answer: last) }
            // #1855: no other account for the re-placed quota check: the first refusal goes out, not "every account is benched".
            if let first = replacedFrom { return answerThrottle(first) }
            return noAccounts()
        }
        if anyway { log.note(label, "no other account is routable; trying a rejected token") }
        tried.insert(label)
        guard let id = store.read({ $0.accounts[label]?.id }) else { return last.map { pinBack($0, answer: $0) } ?? attempt() }
        send(label: label, accountID: id, retried: false)
    }

    /// `given`: the item a refresh just stored (#2007), used instead of reading the secret again.
    private func send(label: String, accountID: String, retried: Bool, token given: String? = nil) {
        guard let head, !closed else { return }
        // The token lives in this request only: read per attempt, never kept on the connection.
        // #1326 (c): a retry (throttle wait, pooled resend) can outlive its account: a removed one is never sent, even
        // when its Keychain item stayed behind.
        let removed = store.read { $0.label(ofID: accountID) } == nil
        func skip(_ why: String) {
            log.note(label, why)
            // #1256: a throttle retry never moves to another account: its last 429 goes back instead.
            if let last = retryingThrottle { retryingThrottle = nil; return answerThrottle(last) }
            // #1262: after the one move nothing walks on: the conversation goes back, the first account's 429 goes out.
            if let first = movedFrom { return pinBack(first, answer: first) }
            return attempt()
        }
        guard !removed, let token = given ?? (try? secrets.token(id: accountID)) ?? nil, !token.isEmpty else {
            return skip(removed ? "account removed; skipping this account" : "token unavailable; skipping this account")
        }
        let codexLogin = harness.id == CCPoolCodexHarness.id ? CodexCredential.decode(token) : nil
        // #2007: a Codex login due for refresh (exp within 1 h, last refresh over 7 days) is refreshed first; the keeper
        // stores the new item before it comes back here. No answer: the stored login is used as it is.
        if given == nil, let keeper, let c = codexLogin, CodexTokenKeeper.due(c, now: store.now) {
            return keeper.refresh(id: accountID, stale: c.accessToken) { [weak self] outcome in
                guard let self else { return }
                self.queue.async {
                    switch outcome {
                    case .refreshed(let item): self.send(label: label, accountID: accountID, retried: retried, token: item)
                    case .failed: self.send(label: label, accountID: accountID, retried: retried, token: token)
                    case .signedOut: self.signedOut(label: label, accountID: accountID)
                    }
                }
            }
        }
        guard let url = URL(string: target) else {
            // #1572 (O11): the pool's own 400 after a relay began is one usage row too (acct of this attempt).
            recordAnswer(400, acct: accountID)
            return fail(400, "bad request path", type: "invalid_request_error")
        }
        // #2005: the Codex upstream is a config value of its own; under XCTest no production host is ever dialled.
        guard !CCPoolService.refusesUnderTest(url) else {
            recordAnswer(502, acct: accountID)
            return fail(502, "refusing the production upstream under XCTest", type: "api_error")
        }
        var req = URLRequest(url: url, timeoutInterval: config.timeout)
        req.httpMethod = head.method
        for (name, value) in head.headers where !harness.stripRequest.contains(name.lowercased()) {
            req.addValue(value, forHTTPHeaderField: name)
        }
        // #2005: a secret the harness cannot read (a Codex item that does not decode) is skipped like a missing token.
        guard harness.authorize(&req, token: token) else { return skip("token unavailable; skipping this account") }
        if streamed {
            req.httpBodyStream = bodyIn
            bodyIn = nil
            req.setValue(String(expected), forHTTPHeaderField: "Content-Length")
        } else if !body.isEmpty {
            req.httpBody = body
        }
        let ex = CCPoolExchange(connection: self, label: label, accountID: accountID, retried: retried, followedPin: followedPin)
        ex.codexAccess = codexLogin?.accessToken
        ex.canRefresh = codexLogin?.canRefresh ?? false
        exchange = ex
        ex.task = upstream.start(req, accountID: accountID, handler: ex)
    }

    private var replayable: Bool { !streamed && !headSent }

    /// #2007: the account's refresh token was refused (the keeper stamped it refused): the client hears so, no retry.
    private func signedOut(label: String, accountID: String) {
        exchange = nil
        log.note(label, "Codex login signed out; not routed until it signs in again")
        recordAnswer(401, acct: accountID)
        fail(401, "the Codex account's login is signed out: sign in again", type: "authentication_error")
    }

    /// #2007: after a 401 the login was refreshed: the request goes again ONCE on the same account with the new item.
    private func after401(_ outcome: CodexTokenKeeper.Outcome, label: String, accountID: String) {
        guard !closed else { return }
        switch outcome {
        case .refreshed(let item):
            log.note(label, "login refreshed; replaying the request once")
            send(label: label, accountID: accountID, retried: false, token: item)
        case .signedOut: signedOut(label: label, accountID: accountID)
        case .failed:
            recordAnswer(502, acct: accountID)
            fail(502, "the Codex login could not be refreshed; try again", type: "api_error")
        }
    }

    func onResponse(_ ex: CCPoolExchange, _ response: HTTPURLResponse, decide: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard ex === exchange, !closed else { return decide(.cancel) }
        retryingThrottle = nil
        let label = ex.label
        let now = store.now
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let k = k as? String { headers[k.lowercased()] = "\(v)" }
        }
        let (limits, unknown) = harness.parseLimits(headers)
        if !unknown.isEmpty { log.note(label, "unknown claim window \(unknown.joined(separator: ",")); not benching on it") }
        // #2006: a Codex limit id other than the default is recorded and shown, never benched (Claude's are all benchable).
        let codex = harness.id == CCPoolCodexHarness.id
        let benchable = codex ? CCPoolCodexHarness.benchable(limits) : limits
        // #1190 INFO-2: what this answer says belongs to the account that sent it, by its Keychain id: the
        // label may have moved to another account (rename, remove and add, a Replace) while it was in flight.
        let id = ex.accountID, code = response.statusCode
        // #2007: a Codex 401 on a login that can refresh: refresh through the keeper (one in flight per account) and,
        // while the request is replayable, replay it once. Not replayable: the refresh is for the next request, and
        // this 401 passes through unmarked.
        let refreshes = codex && code == 401 && ex.canRefresh && !refreshed401 && keeper != nil
        if refreshes, let keeper, let stale = ex.codexAccess {
            refreshed401 = true
            if replayable {
                exchange = nil
                decide(.cancel)
                log.note(label, "token rejected (401); refreshing the login")
                return keeper.refresh(id: id, stale: stale) { [weak self] outcome in
                    guard let self else { return }
                    self.queue.async { self.after401(outcome, label: label, accountID: id) }
                }
            }
            keeper.refresh(id: id, stale: stale) { _ in }
            log.note(label, "token rejected (401); refreshing the login for the next request (body above the replay cap)")
        }
        // #1278: a 401 to /v1/messages* takes the account out of routing (the first stamp kept: a second 401 writes
        // nothing) and never makes it `current`; a 2xx puts it back. One write with `current`; the reply is unchanged.
        // #2007: on Codex, a 401 that is not refreshed (a login that cannot refresh, or the second 401) marks it too.
        let marks = code == 401 && (head?.path.hasPrefix("/v1/messages") == true || (codex && !refreshes))
        let refusal = store.mutate { st -> Bool? in
            guard let owner = st.label(ofID: id) else { return nil }
            if !ex.followedPin, code != 401 { st.remember(owner) }
            if marks, st.accounts[owner]?.refused == nil, now.isFinite, (0..<1e12).contains(now) {
                st.accounts[owner]?.refused = Int(now)
                return true
            }
            if (200...299).contains(code), st.accounts[owner]?.refused != nil {
                st.accounts[owner]?.refused = nil
                return false
            }
            return nil   // no change to refusal
        }
        if refusal == true { log.note(label, "token rejected (401); not routed until a reply succeeds, Refresh, Release or a new token") }
        if refusal == false { log.note(label, "token accepted again; back in routing") }
        // #1219: the usage sample (display only) goes to that account, its label resolved under the lock of the write.
        store.recordUsage(id: id, limits: limits)

        if response.statusCode == 429 {
            ex.shouldRetry = CCPoolThrottleShape.shouldRetry(headers["x-should-retry"])
            var spent = CCPoolCore.exhaustedClaims(benchable, now: now)
            let retry = headers["retry-after"]
            let wait = CCPoolCore.retryAfterSeconds(retry)
            let unified = !limits.isEmpty
            let detail = !unified ? "NO unified rate-limit headers"
                : limits.keys.sorted().map { "\($0)=\(limits[$0]?.status ?? "?")/\(limits[$0]?.utilization ?? "?")" }.joined(separator: ", ")
            var reason = spent.isEmpty ? "no exhausted quota" : "reported exhausted quota"
            if spent.isEmpty, wait > CCPoolCore.longRetryAfter {
                // The cooldown belongs to the requested model's weekly claim, not every model.
                let claim = harness.isKnownModel(model) ? harness.claims(for: model).last! : CCPoolCore.fiveHour
                spent = [claim: Int(now) + wait]
                reason = "long Retry-After for requested model"
            }
            // QA #733 INFO-3: the model and the upstream body go to the private part of the log line;
            // what is printed of the model and Retry-After is capped at 64 bytes.
            let lead = "429 quota=\(detail); retry-after=\(Self.capped(retry ?? "?")); "
                + "cooldown=\(spent.isEmpty ? "none" : spent.keys.sorted().joined(separator: ",")); "
            let line = lead + "reason=\(reason)"
            let privateDetail = "; model=\(Self.capped(model ?? "none"))"
            if spent.isEmpty {
                // Upstream load, not quota: rotating would not help and benching would be a lie (B14).
                ex.mode = .snippet
                // #1263: the shape and the attempts go between the cooldown and the reason; finishSnippet adds them.
                ex.pendingNote = lead
                ex.pendingReason = "reason=\(reason)"
                ex.unified = unified
                ex.responseHeaders = CCPoolThrottleShape.headers(response.allHeaderFields.keys.compactMap { $0 as? String })
                ex.pendingPrivate = privateDetail
                // Header-safe: one line, printable ASCII only.
                ex.retryAfter = retry.map { String($0.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }) }
                if codex { ex.upstreamHeaders = headers }
                return decide(.allow)
            }
            log.note(label, line, private: privateDetail)
            let benched = store.mutate { st -> String? in
                guard let owner = st.label(ofID: id) else { return nil }
                for (claim, until) in spent { st.bench(owner, claim: claim, until: until, now: now) }
                return owner
            }
            if let benched { for (claim, until) in spent.sorted(by: { $0.key < $1.key }) { event(.bench, acct: benched, claim: claim, reset: until) } }
            let claims = spent.keys.sorted().joined(separator: ",")
            if replayable {
                log.note(label, "out on \(claims); rotating to another account and retrying request")
                exchange = nil
                decide(.cancel)
                return attempt(rotatingFrom: label)
            }
            // Errata C1: the body went upstream as a stream and cannot be sent again.
            log.note(label, "out on \(claims); request body above the replay cap, passing the 429 through")
        } else {
            // #1263: a reply after throttles (retries, plus the move that the last 429 caused): a count and fixed words.
            // #1263 (R1263-q1): the status is the reply's own Int; a non-2xx reply is "answered", never "served".
            if throttleRetries > 0 || movedFrom != nil {
                let moved = movedFrom != nil, code = response.statusCode
                let word = !(200...299).contains(code) ? "answered" : moved ? "moved-served" : "served"
                log.note(label, "served after \(throttleRetries + (moved ? 1 : 0)) throttled attempt(s); status=\(code); "
                    + "attempt=\(attempts); retry=\(throttleRetries); outcome=\(word)")
            }
            // Retire before streaming: the body can take a minute to drain (B15).
            let spent = CCPoolCore.exhaustedClaims(benchable, now: now)
            let retired = store.mutate { st -> String? in
                guard let owner = st.label(ofID: id) else { return nil }
                st.recordResets(owner, limits: limits, now: now)
                for (claim, until) in spent { st.bench(owner, claim: claim, until: until, now: now) }
                return owner
            }
            if !spent.isEmpty {
                log.note(label, "now full on \(spent.keys.sorted().joined(separator: ",")); retired before it could reject anything")
                if let retired { for (claim, until) in spent.sorted(by: { $0.key < $1.key }) { event(.retire, acct: retired, claim: claim, reset: until) } }
            }
            // #2015: a Codex 400 may be an account refusing reasoning another account sealed (a move, this turn or an
            // earlier one): its head waits while the body (4 KiB at most) is read; finish400 decides. Nothing else reads it.
            if codex, code == 400, !strippedReplay, replayable {
                ex.held400 = true
                ex.upstreamHeaders = headers
                ex.status = code
                ex.limits = limits
                ex.mode = .snippet
                return decide(.allow)
            }
        }
        writeHead(response.statusCode, headers)
        // #1482: the tap reads every relayed reply for the usage record.
        ex.tap = harness.usageTap(contentType: headers["content-type"])
        ex.status = response.statusCode
        ex.limits = limits
        // #1260 (D5): learn keeps its gate: only a 200 that is real work.
        if response.statusCode == 200, !quotaCheck {
            ex.fiveHour = limits[CCPoolCore.fiveHour]
        }
        ex.mode = .streaming
        decide(.allow)
    }

    func onData(_ ex: CCPoolExchange, _ data: Data) {
        guard ex === exchange, !closed else { return }
        switch ex.mode {
        case .deciding: return
        case .snippet:
            // #2015: the held 400 keeps every byte (it may still go to the client); decided at 4 KiB or at its end.
            if ex.held400 {
                ex.snippet.append(data)
                if ex.snippet.count >= CCPoolCodexHarness.bodyCap { finish400(ex, error: nil, done: false, reused: false) }
                return
            }
            // #2006: a Codex 429 body is read up to 4 KiB for its usage_limit_reached type (still only on a 429).
            let cap = harness.id == CCPoolCodexHarness.id ? CCPoolCodexHarness.bodyCap : Self.snippetCap
            ex.snippet.append(data.prefix(cap - ex.snippet.count))
            if ex.snippet.count >= cap { finishSnippet(ex) }
        case .streaming:
            var frame = Data(String(data.count, radix: 16, uppercase: true).utf8)
            frame.append(contentsOf: [13, 10])
            frame.append(data)
            frame.append(contentsOf: [13, 10])
            outstanding += frame.count
            if outstanding > Self.highWater, !ex.suspended { ex.suspended = true; ex.task?.suspend() }
            let n = frame.count
            conn.send(frame) { [weak self] error in
                guard let self else { return }
                self.outstanding -= n
                if error != nil { return self.close() }
                if ex.suspended, self.outstanding < Self.lowWater { ex.suspended = false; ex.task?.resume() }
            }
            // #1260: the tap reads its own copy after the frame is handed to the client; it cannot fail the relay.
            ex.tap?.feed(data)
        }
    }

    /// B17, QA #733 F1: resend only a request that went out on a REUSED (pooled) connection the far
    /// end had closed (URLSessionTaskMetrics said so), once, with a body that can be sent again.
    /// A fresh connection that drops may have run the request: resending would spend quota twice.
    static func shouldResend(_ code: URLError.Code?, retried: Bool, streamed: Bool, reused: Bool) -> Bool {
        code == .networkConnectionLost && !retried && !streamed && reused
    }

    func onDone(_ ex: CCPoolExchange, _ error: Error?, reused: Bool) {
        guard ex === exchange, !closed else { return }
        switch ex.mode {
        case .deciding:
            let code = (error as? URLError)?.code
            if Self.shouldResend(code, retried: ex.retried, streamed: streamed, reused: reused) {
                // #1572 (O7): an account removed meanwhile is never resent; send() logs that instead of a retry.
                if store.read({ $0.label(ofID: ex.accountID) }) != nil {
                    log.note(ex.label, "pooled upstream connection dropped before a response; retrying once")
                }
                return send(label: ex.label, accountID: ex.accountID, retried: true)
            }
            log.note(ex.label, "upstream unreachable (\(code.map { "\($0.rawValue)" } ?? "error")\(reused ? ", pooled" : ""))")
            exchange = nil
            // #1263 (R1262-a): the destination of the one move never answered: the conversation goes back where its cache is.
            if let first = movedFrom { pinBack(first, answer: nil) }
            recordAnswer(502, acct: ex.accountID)
            fail(502, "upstream unreachable", type: "api_error")
        case .snippet:
            if ex.held400 { return finish400(ex, error: error, done: true, reused: reused) }
            finishSnippet(ex)
        case .streaming:
            exchange = nil
            recordRow(ex, done: error == nil)
            // #1594: a cut upstream still hands the client every frame already queued: sends complete in order, so the
            // hang-up (FIN, no terminating chunk) and the cancel come after them. A bare close() could drop them.
            guard error == nil else {
                return conn.finish { [weak self] in self?.close() }
            }
            conn.send(Data("0\r\n\r\n".utf8)) { [weak self] _ in self?.close() }
            learn(ex)
        }
    }

    /// #1260: the normal end of a tapped reply feeds the pure learn step (CCPoolCapacity.learn), in memory only.
    /// Nothing is learned without usage, a five-hour utilization and its reset stamp, or once the account is gone.
    private func learn(_ ex: CCPoolExchange) {
        guard let usage = ex.tap?.result(), let row = ex.fiveHour.map({ [CCPoolCore.fiveHour: $0] }),
              let util = CCPoolCore.utils(row)[CCPoolCore.fiveHour],
              let reset = CCPoolCore.resets(row)[CCPoolCore.fiveHour] else { return }
        let id = ex.accountID, m = model.map(Self.capped), h = harness
        store.mutate { st in
            guard st.label(ofID: id) != nil else { return }
            st.capacity[id] = CCPoolCapacity.learn(st.capacity[id] ?? CCPoolCapacityState(), model: m, usage: usage,
                                                   utilization: util, reset: Double(reset), table: h.prices)
            // Bounded by the account set: a removed account's numbers go.
            let ids = Set(st.accounts.values.map(\.id))
            st.capacity = st.capacity.filter { ids.contains($0.key) }
        }
    }

    /// #1482: the one usage row of this request, handed to the writer's own queue. Ids from the pin key's headers
    /// only when the whole key is valid; the account by its Keychain id, never its label.
    private func recordRow(_ ex: CCPoolExchange, done: Bool) {
        addRow(acct: ex.accountID, st: ex.status, done: done, usage: ex.tap?.result(), lim: ex.limits)
    }

    /// #1482 step b: the row of an answer the pool made itself after a relay began (its 429s, its 502): the status
    /// sent, no usage, done. `acct` is "" when no account was reached (all benched). Called once per request: each
    /// caller has just cleared `exchange`, so close() adds no second row.
    private func recordAnswer(_ st: Int, acct: String) {
        addRow(acct: acct, st: st, done: true, usage: nil, lim: [:])
    }

    /// #1667: one event row, handed to the writer's own queue. Labels only; `sess` is the pin key, written only when valid.
    private func event(_ ev: CCPoolEventRow.Kind, acct: String? = nil, from: String? = nil, to: String? = nil,
                       claim: String? = nil, reset: Int? = nil) {
        events?.add(CCPoolEventRow(t: store.now, ev: ev, acct: acct, from: from, to: to, claim: claim, reset: reset,
                                   sess: head.flatMap({ harness.pinKey($0) })))
    }

    private func addRow(acct: String, st: Int, done: Bool, usage: CCPoolTokenUsage?, lim: [String: CCPoolLimit]) {
        guard let record else { return }
        let end = store.now
        // #2006: a Codex row carries no session id (its session_id is never written); the account and model word only.
        let keyed = harness.id == ClaudeHarness.id && head.flatMap({ harness.pinKey($0) }) != nil
        let ms = (end - startedAt) * 1000
        // #2042: the account's harness now; "" (none reached) or a removed account takes this request's harness.
        let hid = store.read { st in st.accounts.values.first { $0.id == acct }?.harness } ?? harness.id
        record.add(CCPoolUsageRow(t: end, acct: acct, model: CCPoolUsageRow.modelWord(model),
                                  sess: keyed ? head?.header("x-claude-code-session-id") : nil,
                                  agent: keyed ? head?.header("x-claude-code-agent-id") ?? "" : nil,
                                  path: CCPoolUsageRow.pathWord(head?.path ?? ""), st: st,
                                  ms: ms.isFinite && ms >= 0 && ms < 1e12 ? Int(ms) : 0, done: done, qc: quotaCheck,
                                  att: attempts, thr: throttleRetries, mv: movedFrom != nil, routed: routed, harness: hid,
                                  usage: usage, lim: lim))
    }

    /// Log the pass-through 429 with at most 200 bytes of the upstream body, then answer it.
    private func finishSnippet(_ ex: CCPoolExchange) {
        guard ex === exchange else { return }
        exchange = nil
        ex.task?.cancel()
        if harness.id == CCPoolCodexHarness.id, rotateSpentCodex(ex) { return }
        // #1263 (R1263-a): what this 429 leads to is decided ONCE; its word is logged and the switch below acts on it.
        // Each later `if` overrides the earlier ones: retry beats pinned-back beats move beats returned. #1855: re-placed is
        // for quota checks only, which never retry or move.
        var next = ThrottleNext.returned
        // #1262: after the same-account retries, ONE move (Python relay() 486-496). No usable key, a quota check or a
        // body that cannot be sent again never moves.
        if replayable, !quotaCheck, attempts < maxAttempts, head.flatMap({ harness.pinKey($0) }) != nil {
            next = .move
        }
        // #1262: refused at the destination too (Python relay() 497-502): back where the cache is, never a second move.
        if movedFrom != nil { next = .pinnedBack }
        // #1855: a keyed quota check (nothing spent: this is the snippet path) is re-placed ONCE on another account,
        // the refusing one excluded (it is in `tried`); no same-account retry, no wait. A second refusal is returned.
        // #1878: only a 429 with the unified rate-limit headers; one without them is upstream refusing the check itself
        // (every account refuses it while serving real work), so a second account would only spend a second refusal.
        if replayable, quotaCheck, replacedFrom == nil, attempts < maxAttempts, head.flatMap({ harness.pinKey($0) }) != nil, ex.unified {
            next = .replace
        }
        // #1855: an account that refused a placement ranks last in place() for a short while (memory only, no write).
        // #1878: and only for a 429 with the unified headers, quota check or real work: one without them says nothing
        // about the account, and a shun would rank a healthy account last for every new session.
        if routed == "place", ex.unified {
            let now = store.now, id = ex.accountID, secs = CCPoolCore.shunSeconds(retryAfter: ex.retryAfter)
            store.mutate { st in if let owner = st.label(ofID: id) { st.shun(owner, seconds: secs, now: now) } }
        }
        // #1256: a throughput 429 is retried on the SAME account, up to 3 times, unless the body is the
        // client's quota check or could not be sent again (above the replay cap). Python relay() 478-485.
        if replayable, !quotaCheck, throttleRetries < CCPoolCore.throttleBackoff.count, attempts < maxAttempts {
            next = .retry
        }
        log.note(ex.label, ex.pendingNote + shape + "; beta=" + CCPoolThrottleShape.beta(head?.header("anthropic-beta"))
                 + "; should-retry=" + ex.shouldRetry + "; resp-headers=" + ex.responseHeaders
                 + "; error=" + CCPoolThrottleShape.errorType(ex.snippet) + "; attempt=\(attempts); retry=\(throttleRetries); outcome=\(next.rawValue); " + ex.pendingReason,
                 private: ex.pendingPrivate + "; body=" + String(decoding: ex.snippet.prefix(Self.snippetCap), as: UTF8.self))
        switch next {
        case .retry:
            let delay = CCPoolCore.throttleDelay(retryAfter: ex.retryAfter, retry: throttleRetries)
            throttleRetries += 1
            attempts += 1
            retryingThrottle = ex
            log.note(ex.label, "throttled; same-account retry \(throttleRetries) of \(CCPoolCore.throttleBackoff.count) in \(delay)s")
            let label = ex.label, id = ex.accountID
            // Runs on `queue` (the seam is handed it); a @Sendable closure from this nonisolated method, no actor.
            Self.throttleWait(delay, queue) { [weak self] in
                guard let self, !self.closed else { return }
                self.send(label: label, accountID: id, retried: false)
            }
        case .pinnedBack:
            // One 429, no retry. `movedFrom` is set whenever `next` is pinnedBack.
            pinBack(movedFrom ?? ex, answer: ex)
        case .move:
            // route() with every tried account excluded places and pins the conversation (#1261); one send there.
            movedFrom = ex
            log.note(ex.label, "throttled after \(throttleRetries) same-account retries; moving the conversation once")
            attempt(moving: ex)
        case .replace:
            replacedFrom = ex
            log.note(ex.label, "quota check refused with nothing spent; re-placing it once on another account")
            attempt()
        case .returned:
            answerThrottle(ex)
        }
    }

    /// #2006: a Codex 429 that its limits did not show as spent, but its reached-type header or a usage_limit_reached
    /// body does: the account's claims are benched until the reset (the body's, else the fullest window's, else the
    /// Retry-After, else the short unconfirmed bench) and the request goes to the next account before the first byte,
    /// as a spent claim does in onResponse. False: a throttle (or a body above the replay cap), handled as before.
    private func rotateSpentCodex(_ ex: CCPoolExchange) -> Bool {
        let now = store.now
        let found = CCPoolCodexHarness.spent429(headers: ex.upstreamHeaders, body: ex.snippet, now: now)
        guard found.spent, now.isFinite, (0...1e11).contains(now) else { return false }
        let wait = CCPoolCore.retryAfterSeconds(ex.retryAfter)
        let until = found.reset.flatMap { Double($0) > now ? $0 : nil }
            ?? Int(now) + (wait > 0 ? wait : CCPoolCore.unconfirmedBench)
        let claims = harness.claims(for: model).sorted()
        let id = ex.accountID
        let benched = store.mutate { st -> String? in
            guard let owner = st.label(ofID: id) else { return nil }
            for claim in claims { st.bench(owner, claim: claim, until: until, now: now) }
            return owner
        }
        if let benched { for claim in claims { event(.bench, acct: benched, claim: claim, reset: until) } }
        // #2025 (QA R2006 n2): above the replay cap the throttle path logs this exchange once (its reason is in that line).
        guard replayable else { return false }
        log.note(ex.label, ex.pendingNote + "reason=usage limit reached", private: ex.pendingPrivate)
        log.note(ex.label, "out on \(claims.joined(separator: ",")); rotating to another account and retrying request")
        attempt(rotatingFrom: ex.label)
        return true
    }

    /// #2015 (design #2003 section 4, R3): the held Codex 400. An encrypted-content error replays ONCE on the
    /// same account without the encrypted reasoning items; anything else (another error, a compaction item, nothing to
    /// strip) goes to the client as it came, the held bytes first. Counts only in the log, never body content.
    private func finish400(_ ex: CCPoolExchange, error: Error?, done: Bool, reused: Bool) {
        guard ex === exchange else { return }
        ex.held400 = false
        if CCPoolCodexHarness.encryptedError(ex.snippet) {
            let lead = "encrypted content refused; "
            switch CCPoolCodexHarness.stripEncrypted(body) {
            case .stripped(let out, let removed, let kept):
                // shortcut: every turn after a move pays one 400 round trip, and B's own sealed reasoning is stripped too
                // (the blobs don't say which account sealed them); upgrade: per-session memory of a moved conversation if
                // the extra round trip shows up in latency
                exchange = nil
                ex.task?.cancel()
                body = out
                strippedReplay = true
                log.note(ex.label, lead + "replaying once without \(removed) encrypted reasoning item(s); \(kept) item(s) kept")
                return send(label: ex.label, accountID: ex.accountID, retried: false)
            case .blocked:
                log.note(ex.label, lead + "the conversation holds a compaction or other encrypted item; passing the 400 through: start a new Codex session")
            case .nothing:
                log.note(ex.label, lead + "nothing to strip; passing the 400 through")
            }
        }
        writeHead(ex.status, ex.upstreamHeaders)
        ex.tap = harness.usageTap(contentType: ex.upstreamHeaders["content-type"])
        ex.mode = .streaming
        let held = ex.snippet
        ex.snippet = Data()
        if !held.isEmpty { onData(ex, held) }
        if done { onDone(ex, error, reused: reused) }
    }

    /// #1263: what a throughput 429 leads to; the raw value is the logged outcome word.
    private enum ThrottleNext: String { case retry, pinnedBack = "pinned-back", move, replace = "re-placed", returned }

    /// #1262: the move did not help: the conversation's pin goes back to the first account (one write, a fresh
    /// stamp; no write when it is already there) and ONE 429 goes out, `answer`'s Retry-After. #1263 (R1262-a):
    /// `answer` nil = the pool answers itself (its 502 after a transport failure at the destination).
    private func pinBack(_ first: CCPoolExchange, answer: CCPoolExchange?) {
        if let key = head.flatMap({ harness.pinKey($0) }) {
            let now = store.now, id = first.accountID
            store.mutate { st in if let owner = st.label(ofID: id) { st.pin(key, to: owner, now: now) } }
        }
        log.note(first.label, "conversation pinned back after its one move")
        event(.pinBack, acct: first.label)
        if let answer { answerThrottle(answer) }
    }

    private func answerThrottle(_ ex: CCPoolExchange) {
        let extra: [(String, String)] = ex.retryAfter.map { $0.isEmpty ? [] : [("retry-after", $0)] } ?? []
        recordAnswer(429, acct: ex.accountID)
        fail(429, "upstream rate limit (not account quota)", type: "rate_limit_error", headers: extra)
    }

    private func noAccounts() {
        exchange = nil
        // #2005: no account of this login kind at all is not "benched": Codex says so plainly (Claude's answer unchanged).
        let h = harness
        if h.id == CCPoolCodexHarness.id,
           !store.read({ st in st.accounts.values.contains { $0.harness == h.id && h.accepts(kind: $0.kind) } }) {
            log.note(nil, "no Codex accounts in the pool")
            return sendText(503, "ccpool: no Codex accounts in the pool")
        }
        let when = store.read { CCPoolCore.nextReset($0, model: model, now: store.now, harness: harness) }
        var hint = ""
        if let when {
            let f = DateFormatter()
            f.dateFormat = "EEE HH:mm"
            hint = " Earliest reset \(f.string(from: Date(timeIntervalSince1970: Double(when))))."
        }
        log.note(nil, "every account is benched.\(hint)")
        event(.allBenched, reset: when)
        recordAnswer(429, acct: "")
        if h.id == CCPoolCodexHarness.id { return failCodexLimit(reset: when) }
        fail(429, "all pooled accounts are rate limited.\(hint)", type: "rate_limit_error")
    }

    /// #2025 (QA R2006 n1): the answer the Codex CLI understands when no Codex account can serve: usage_limit_reached,
    /// with the pool's next Codex reset as resets_at / resets_in_seconds and Retry-After. No known reset: none of the
    /// three is sent (no time is invented).
    private func failCodexLimit(reset: Int?) {
        var err: [String: Any] = ["type": "usage_limit_reached", "message": "ccpool: all pooled Codex accounts are rate limited."]
        var extra: [(String, String)] = []
        let now = store.now
        if let reset, now.isFinite, (0...1e11).contains(now) {
            let secs = Int(max(0, min(1e9, Double(reset) - now)))
            err["resets_at"] = reset
            err["resets_in_seconds"] = secs
            extra = [("retry-after", "\(secs)")]
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["error": err], options: [.sortedKeys])) ?? Data()
        sendComplete(429, contentType: "application/json", body: body, headers: extra)
    }

    // MARK: Writers

    private func writeHead(_ status: Int, _ headers: [String: String]) {
        headSent = true
        var h = "HTTP/1.1 \(status) \(Self.reason(status))\r\nServer: \(CCPoolService.serverHeader)\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) where !Self.stripResponse.contains(k) {
            h += "\(k): \(v)\r\n"
        }
        h += "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
        conn.send(Data(h.utf8)) { [weak self] error in
            if error != nil { self?.close() }
        }
    }

    // MARK: Loopback control (#1674)

    static let holdPath = "/ccpool/hold"
    static let clearPath = "/ccpool/clear"
    static let controlRoutes = [holdPath, clearPath]
    /// A custom header forces a browser preflight, which the proxy never grants; admits() already refuses any Origin.
    static let controlHeader = "x-ccpool-control"
    static let controlBodyCap = 4 << 10

    /// POST /ccpool/hold?label=&hours= and POST /ccpool/clear?label=: the pane's Hold and Release, the same store calls.
    private func control(_ route: String, _ h: CCPoolRequestHead, bodyLength: Int) {
        guard h.method == "POST" else {
            return fail(405, "use POST", type: "invalid_request_error", headers: [("Allow", "POST")])
        }
        guard h.header(Self.controlHeader) == "1" else {
            log.note(nil, "refused a control request: no \(Self.controlHeader) header")
            return fail(403, "forbidden", type: "permission_error")
        }
        guard bodyLength <= Self.controlBodyCap else { return fail(413, "request body too large", type: "invalid_request_error") }
        let items = URLComponents(string: h.path)?.queryItems ?? []
        func one(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            guard values.count == 1, let v = values.first?.value, !v.isEmpty else { return nil }
            return v
        }
        guard let label = one("label") else { return fail(400, "label missing", type: "invalid_request_error") }
        let now = store.now
        let found: Bool
        if route == Self.holdPath {
            // The pane's rule (CCPoolPaneModel.hold): a finite number of hours above zero.
            guard let hours = one("hours").flatMap(Double.init), hours.isFinite, hours > 0 else {
                return fail(400, "hours must be a number above zero", type: "invalid_request_error")
            }
            found = store.mutate { $0.hold(label, hours: hours, now: now) }
            if found { log.note(label, "held for \(hours) h by a loopback request") }
        } else {
            found = store.mutate { s -> Bool in
                guard s.accounts[label] != nil else { return false }
                s.clear(label)
                return true
            }
            if found { log.note(label, "released by a loopback request") }
        }
        guard found, let row = CCPoolService.statusRow(label: label, state: store.snapshot, now: now),
              let body = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else {
            return fail(404, "no such account", type: "not_found_error")
        }
        sendComplete(200, contentType: "application/json", body: body)
    }

    /// #2005: a short plain-text answer (the Codex 503 and 501).
    private func sendText(_ status: Int, _ text: String) {
        sendComplete(status, contentType: "text/plain; charset=utf-8", body: Data((text + "\n").utf8))
    }

    private func sendHealth() {
        sendComplete(200, contentType: "application/json", body: CCPoolService.healthBody(store: store))
    }

    func fail(_ status: Int, _ message: String, type: String, headers: [(String, String)] = []) {
        let obj: [String: Any] = ["type": "error", "error": ["type": type, "message": "ccpool: \(message)"]]
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        sendComplete(status, contentType: "application/json", body: body, headers: headers)
    }

    private func sendComplete(_ status: Int, contentType: String, body: Data, headers: [(String, String)] = []) {
        headSent = true
        let extra = headers.map { "\($0.0): \($0.1)\r\n" }.joined()
        var out = Data(("HTTP/1.1 \(status) \(Self.reason(status))\r\nServer: \(CCPoolService.serverHeader)\r\n"
            + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n").utf8)
        out.append(body)
        conn.send(out) { [weak self] _ in self?.close() }
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

extension CCPoolState {
    /// #1190 INFO-2: the label the account with Keychain id `id` carries now; nil once it is gone.
    func label(ofID id: String) -> String? { accounts.first { $0.value.id == id }?.key }
}

/// #1263: the public part of a throughput 429 line. Every piece of outside data is a count, a fixed word, or a header
/// name that passed the fixed rule; a header value, a model name, a body byte and a session id never get here.
enum CCPoolThrottleShape {
    /// ccpool v1.9.0 ccpool_proxy.py ROUTINE (602-606): the response headers every reply carries.
    static let routine: Set<String> = ["date", "content-type", "content-length", "connection", "server", "request-id", "cf-ray",
                                       "via", "cf-cache-status", "x-robots-tag", "strict-transport-security",
                                       "anthropic-organization-id", "x-envoy-upstream-service-time", "retry-after"]
    /// ccpool_proxy.py PREFIX (59): the rate-limit headers the pool reads.
    static let routinePrefix = "anthropic-ratelimit-unified-"
    /// Request values chosen from a small set (the public API values; the reference prints them raw): else "other".
    static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]
    static let speeds: Set<String> = ["standard", "fast"]
    static let maxTokensLimit: Int64 = 1 << 20
    static let nameMax = 40
    static let namesShown = 8

    /// An integer (not a bool, not a float) in 1...maxTokensLimit, else "none". NSNumber: no Int() of outside text.
    static func maxTokens(_ obj: [String: Any]?) -> String {
        guard let n = obj?["max_tokens"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)) else { return "none" }
        let v = n.int64Value
        return v >= 1 && v <= maxTokensLimit ? String(v) : "none"
    }

    private static func word(_ v: Any?, _ allowed: Set<String>) -> String {
        guard let v else { return "none" }
        guard let s = v as? String, allowed.contains(s) else { return "other" }
        return s
    }

    /// "bytes=N; max_tokens=X; effort=E; speed=S"; `obj` nil (a body above the replay cap, never parsed) reads "none".
    static func request(bytes: Int, _ obj: [String: Any]?) -> String {
        let effort = (obj?["output_config"] as? [String: Any])?["effort"]
        return "bytes=\(max(0, bytes)); max_tokens=\(maxTokens(obj)); effort=\(word(effort, efforts)); speed=\(word(obj?["speed"], speeds))"
    }

    static let betaMax = 120

    /// The request's anthropic-beta list for the log: only letters, digits and "._,-" kept (flag names are public API
    /// words; spaces and anything else are dropped), cut at 120 bytes with a trailing "+"; "none" when absent or empty.
    static func beta(_ value: String?) -> String {
        let kept = String(decoding: (value ?? "").utf8.filter {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x2e || $0 == 0x5f || $0 == 0x2c
        }, as: UTF8.self)
        if kept.isEmpty { return "none" }
        return kept.utf8.count > betaMax ? String(kept.prefix(betaMax)) + "+" : kept
    }

    /// #1878: the upstream error.type words the log may print; anything else is "other".
    static let errorTypes: Set<String> = ["rate_limit_error", "overloaded_error", "api_error", "invalid_request_error",
                                          "permission_error", "authentication_error", "not_found_error", "request_too_large"]

    /// #1878: the body's error.type as a fixed word: an allow-listed type, else "other"; "none" when the held snippet
    /// (at most snippetCap bytes, so possibly cut mid-body) has no `"error":{..."type":"..."` to read. A scan, not a JSON
    /// parse: the real bodies are longer than the snippet. The message text is never returned.
    static func errorType(_ snippet: Data) -> String {
        let text = String(decoding: snippet.prefix(CCPoolConnection.snippetCap), as: UTF8.self)
        guard let m = text.firstMatch(of: #/"error"\s*:\s*\{[^{}]*?"type"\s*:\s*"([^"\\]{0,64})"/#) else { return "none" }
        let word = String(m.1)
        return errorTypes.contains(word) ? word : "other"
    }

    /// The upstream x-should-retry value as a fixed word: "true", "false", "absent" (no header) or "other".
    static func shouldRetry(_ value: String?) -> String {
        guard let value else { return "absent" }
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        return v == "true" || v == "false" ? v : "other"
    }

    /// The unusual response header names (not ROUTINE, no rate-limit prefix) that pass the name rule: ASCII letters,
    /// digits and "-", 1...40 characters, lowercased, sorted, at most 8 printed then " +N more"; names that fail the
    /// rule are only counted ("; odd-headers=K"). "-" when none.
    static func headers(_ names: [String]) -> String {
        var good = Set<String>(), odd = 0
        for raw in names {
            let ok = !raw.isEmpty && raw.utf8.count <= nameMax && raw.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d
            }
            guard ok else { odd += 1; continue }
            let n = raw.lowercased()
            if !routine.contains(n), !n.hasPrefix(routinePrefix) { good.insert(n) }
        }
        let sorted = good.sorted()
        var text = sorted.isEmpty ? "-" : sorted.prefix(namesShown).joined(separator: ",")
        if sorted.count > namesShown { text += " +\(sorted.count - namesShown) more" }
        if odd > 0 { text += "; odd-headers=\(odd)" }
        return text
    }
}
