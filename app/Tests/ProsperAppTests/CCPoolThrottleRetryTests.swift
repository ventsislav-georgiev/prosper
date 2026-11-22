import Network
import XCTest
@testable import ProsperApp

// #1256: a throughput 429 (nothing spent) is retried on the SAME account up to 3 times, waiting 1, 2, 4 s or a
// Retry-After of 1...10 s; a quota check (max_tokens == 1) and a body above the replay cap get the 429 at once.
// Ported from ccpool v1.9.0 test_ccpool_proxy.py ("A throttled conversation moves once", the retry and quota-check
// checks; the move itself is entry 1262). Fake upstream on an ephemeral loopback port, fake secrets, fake labels.
// No row sleeps: every row installs the wait recorder FIRST (rig()), which records the asked seconds and continues
// at once on the connection's own queue.

/// Records the waits the connection asks for, then runs the retry on the queue it was handed.
final class ThrottleWaitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _waits: [Int] = []
    private var _queues: [String] = []
    private var _ranOnMain: [Bool] = []
    private var _hold = false
    private var _held: [(DispatchQueue, @Sendable () -> Void)] = []
    /// Runs before each retry continues (off main, on the connection's queue).
    var beforeContinue: (@Sendable () -> Void)?
    let heldSignal = DispatchSemaphore(value: 0)

    var waits: [Int] { lock.withLock { _waits } }
    var queues: [String] { lock.withLock { _queues } }
    var ranOnMain: [Bool] { lock.withLock { _ranOnMain } }
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }

    /// The seam's test form. Called on the connection's queue.
    func wait(_ seconds: Int, _ queue: DispatchQueue, _ go: @escaping @Sendable () -> Void) {
        let hold = lock.withLock { () -> Bool in
            _waits.append(seconds)
            _queues.append(queue.label)
            if _hold { _held.append((queue, go)) }
            return _hold
        }
        if hold { heldSignal.signal(); return }
        let before = beforeContinue
        queue.async {
            self.lock.withLock { self._ranOnMain.append(Thread.isMainThread) }
            before?()
            go()
        }
    }

    /// Run every held retry on its own queue and return once each has run.
    func releaseHeld() {
        let held = lock.withLock { () -> [(DispatchQueue, @Sendable () -> Void)] in
            defer { _held = [] }
            return _held
        }
        for (q, go) in held { q.sync { go() } }
    }
}

/// Stands in for the upstream; each token answers its script in order, then 200.
final class ThrottleUpstream: @unchecked Sendable {
    /// `drop`: run the closure, then close the connection without an answer (a pooled connection the far end dropped).
    /// `bare` (#1878): a 429 with NO unified rate-limit headers (upstream refusing the request itself), its Retry-After
    /// and its body.
    enum Step { case throttle(String?), bare(String?, String), spent, status(Int), drop(@Sendable () -> Void) }
    private let lock = NSLock()
    private var script: [String: [Step]] = [:]
    private var _calls: [String: Int] = [:]
    private var _bodies: [Data] = []

    var calls: [String: Int] { lock.withLock { _calls } }
    var bodies: [Data] { lock.withLock { _bodies } }
    func set(_ token: String, _ steps: [Step]) { lock.withLock { script[token] = steps } }

    func reply(_ head: CCPoolRequestHead, _ body: Data) -> CCPoolFakeServer.Reply {
        lock.withLock {
            let auth = head.header("authorization") ?? ""
            let token = String(auth.dropFirst("Bearer ".count))
            _calls[token, default: 0] += 1
            _bodies.append(body)
            let step = script[token]?.isEmpty == false ? script[token]?.removeFirst() : nil
            let reset = String(Int(Date().timeIntervalSince1970) + 3600)
            var spent = false
            if case .spent? = step { spent = true }
            var h: [(String, String)] = [
                ("5h-status", spent ? "rejected" : "allowed"), ("5h-utilization", spent ? "1.0" : "0.42"), ("5h-reset", reset),
                ("7d-status", "allowed"), ("7d-utilization", "0.10"), ("7d-reset", reset),
            ].map { ("anthropic-ratelimit-unified-\($0.0)", $0.1) }
            h.append(("content-type", "application/json"))
            switch step {
            case .throttle(let ra)?:
                if let ra { h.append(("Retry-After", ra)) }
                return .respond(429, h, Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"busy"}}"#.utf8))
            case .bare(let ra, let body)?:
                return .respond(429, [("content-type", "application/json")] + (ra.map { [("Retry-After", $0)] } ?? []), Data(body.utf8))
            case .spent?:
                return .respond(429, h, Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"spent"}}"#.utf8))
            case .drop(let before)?:
                before()
                return .drop
            case .status(let code)?:
                return .respond(code, [("content-type", "application/json")], Data(#"{"type":"error","error":{"message":"x"}}"#.utf8))
            case nil:
                return .respond(200, h, Data(#"{"type":"message","content":[{"type":"text","text":"hi"}]}"#.utf8))
            }
        }
    }
}

/// Captures lines and signals when the connection notes that its client left during a wait.
final class ThrottleLog: CCPoolLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    let leftSignal = DispatchSemaphore(value: 0)
    var lines: [String] { lock.withLock { _lines } }
    func note(_ label: String?, _ message: String) {
        lock.withLock { _lines.append("\(label ?? "-"): \(message)") }
        if message.contains("client left during a throttle wait") { leftSignal.signal() }
    }
}

let throttleLabels = ["Example Org A", "Example Org B", "Example Org C"]
let throttleTokens = ["Example Org A": "tok-a", "Example Org B": "tok-b", "Example Org C": "tok-c"]
/// Real work, not a quota check.
let throttleWork = Data(#"{"model":"claude-opus-5","max_tokens":4096,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
let throttleQuotaCheck = Data(#"{"model":"claude-opus-5","max_tokens":1}"#.utf8)

/// Counts token reads; everything else goes to the memory store.
final class ReadCountingSecrets: CCPoolSecrets, @unchecked Sendable {
    private let inner: CCPoolMemorySecrets
    private let lock = NSLock()
    private var _reads = 0
    init(_ inner: CCPoolMemorySecrets) { self.inner = inner }
    var reads: Int { lock.withLock { _reads } }
    func store(token: String, id: String, label: String) throws { try inner.store(token: token, id: id, label: label) }
    func token(id: String) throws -> String? { lock.withLock { _reads += 1 }; return try inner.token(id: id) }
    func remove(id: String) throws { try inner.remove(id: id) }
    func relabel(id: String, label: String) throws { try inner.relabel(id: id, label: label) }
}

final class CCPoolThrottleRetryTests: XCTestCase {
    struct Rig {
        let up: ThrottleUpstream
        let server: CCPoolFakeServer
        let service: CCPoolService
        let store: CCPoolStore
        let secrets: CCPoolMemorySecrets
        let log: ThrottleLog
        let rec: ThrottleWaitRecorder
        let port: UInt16
        func post(_ body: Data = throttleWork) -> CCPoolClientResponse? {
            CCPoolTestClient.request(port: port, body: body)
        }
        func cooldown(_ label: String) -> [String: Int] { store.snapshot.accounts[label]?.cooldown ?? [:] }
    }

    /// The wait recorder is installed FIRST, before any listener exists, and restored at teardown.
    /// `wrap`: what the service reads tokens through (a counting wrapper); the Rig's `secrets` stays the memory store under it.
    private func rig(_ count: Int = 2, replayCap: Int = 32 << 20,
                     wrap: ((CCPoolMemorySecrets) -> any CCPoolSecrets)? = nil) throws -> Rig {
        let rec = ThrottleWaitRecorder()
        let saved = CCPoolConnection.throttleWait
        CCPoolConnection.throttleWait = { s, q, go in rec.wait(s, q, go) }
        addTeardownBlock { CCPoolConnection.throttleWait = saved }
        let up = ThrottleUpstream()
        let server = try CCPoolFakeServer { h, b in up.reply(h, b) }
        XCTAssertNotEqual(server.port, 0)
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        for l in throttleLabels.prefix(count) { _ = try store.addAccount(label: l, token: throttleTokens[l] ?? "", secrets: secrets) }
        store.mutate { $0.current = throttleLabels.first }
        let log = ThrottleLog()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(server.port)")!
        cfg.replayCap = replayCap
        cfg.timeout = 10
        let service = CCPoolService(config: cfg, store: store, secrets: wrap?(secrets) ?? secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); server.stop() }
        return Rig(up: up, server: server, service: service, store: store, secrets: secrets, log: log, rec: rec, port: p)
    }

    // T 389-393: "a throttle that clears is served on the same account, no move".
    func testThrottleThatClearsIsServedOnTheSameAccount() throws {
        let r = try rig()
        r.up.set("tok-a", [.throttle(nil), .throttle(nil)])
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertEqual(r.up.calls, ["tok-a": 3])
        XCTAssertEqual(r.rec.waits, [1, 2])
    }

    // T 407-414 without the move (entry 1262): four 429s, three waits, one 429 back, nobody benched.
    func testThrottledFourTimesReturnsOne429OnThatAccountOnly() throws {
        let r = try rig()
        r.up.set("tok-a", [.throttle(nil), .throttle(nil), .throttle(nil), .throttle(nil)])
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429)
        XCTAssertTrue(resp.text.contains("upstream rate limit (not account quota)"), resp.text)
        XCTAssertTrue(resp.text.contains("rate_limit_error"), resp.text)
        XCTAssertEqual(r.up.calls, ["tok-a": 4], "four calls to that one account, none to another")
        XCTAssertEqual(r.rec.waits, [1, 2, 4])
        XCTAssertEqual(r.cooldown("Example Org A"), [:], "a throttle benches nobody")
        XCTAssertEqual(r.log.lines.filter { $0.contains("same-account retry") },
                       ["Example Org A: throttled; same-account retry 1 of 3 in 1s",
                        "Example Org A: throttled; same-account retry 2 of 3 in 2s",
                        "Example Org A: throttled; same-account retry 3 of 3 in 4s"])
    }

    // A Retry-After of 1...10 s is the wait; anything else takes the step (PY 437, 480).
    func testRetryAfterDecidesTheWait() throws {
        let rows: [(String, [Int])] = [
            ("3", [3]), ("1", [1]), ("10", [10]), ("0", [1]), ("11", [1]), ("600", [1]),
            ("Sun, 15 Nov 2026 10:00:00 GMT", [1]), ("soon", [1]), ("-4", [1]), ("3.5", [1]),
        ]
        for (header, want) in rows {
            let r = try rig(1)
            r.up.set("tok-a", [.throttle(header)])
            let resp = try XCTUnwrap(r.post(), header)
            XCTAssertEqual(resp.status, 200, header)
            XCTAssertEqual(r.rec.waits, want, header)
            XCTAssertEqual(r.up.calls, ["tok-a": 2], header)
        }
        let r = try rig(1)
        r.up.set("tok-a", [.throttle("3"), .throttle(nil), .throttle("7")])
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertEqual(r.rec.waits, [3, 2, 7])
    }

    func testThrottleDelayTable() {
        let rows: [(String?, Int, Int)] = [
            ("3", 0, 3), (nil, 0, 1), (nil, 1, 2), (nil, 2, 4), ("11", 2, 4), ("10", 1, 10), ("0", 1, 2), ("abc", 2, 4),
            (" 7 ", 0, 7), ("-1", 0, 1), ("9223372036854775807", 0, 1), ("99999999999999999999999", 1, 2),
            (nil, 3, 4), (nil, -1, 1), (nil, Int.max, 4), (nil, Int.min, 1),
        ]
        for (raw, n, want) in rows {
            XCTAssertEqual(CCPoolCore.throttleDelay(retryAfter: raw, retry: n), want, "\(raw ?? "nil") \(n)")
        }
        XCTAssertEqual(CCPoolCore.throttleBackoff, [1, 2, 4])
    }

    // T 417-422: "a 1-token quota check is answered at once: no retry".
    func testQuotaCheckGetsIts429AfterOneCallAndNoWait() throws {
        let r = try rig()
        r.up.set("tok-a", [.throttle("2"), .throttle(nil)])
        let resp = try XCTUnwrap(r.post(throttleQuotaCheck))
        XCTAssertEqual(resp.status, 429)
        XCTAssertTrue(resp.text.contains("not account quota"), resp.text)
        XCTAssertEqual(r.up.calls, ["tok-a": 1])
        XCTAssertEqual(r.rec.waits, [])
        XCTAssertEqual(resp.header("retry-after"), "2")
    }

    func testOnlyTheIntegerOneIsAQuotaCheck() throws {
        let rows: [(String, Bool)] = [
            (#"{"max_tokens":1}"#, true), (#"{"model":"m","max_tokens":1,"x":[]}"#, true), (#"{"max_tokens":2}"#, false),
            (#"{"max_tokens":0}"#, false), (#"{"max_tokens":-1}"#, false), (#"{"max_tokens":"1"}"#, false),
            (#"{"max_tokens":true}"#, false), (#"{"max_tokens":1.5}"#, false), (#"{"max_tokens":null}"#, false),
            (#"{"max_tokens":99999999999999999999999}"#, false), (#"{}"#, false), (#"[1]"#, false), ("not json", false),
        ]
        for (text, want) in rows {
            let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            XCTAssertEqual(CCPoolConnection.isQuotaCheck(obj), want, text)
        }
        // End to end: a string "1" is work, so it is retried.
        let r = try rig()
        r.up.set("tok-a", [.throttle(nil)])
        XCTAssertEqual(r.post(Data(#"{"model":"claude-opus-5","max_tokens":"1"}"#.utf8))?.status, 200)
        XCTAssertEqual(r.rec.waits, [1])
        XCTAssertEqual(r.up.calls, ["tok-a": 2])
    }

    // Spent quota, 401, 403 and 500 behave exactly as before: zero waits.
    func testSpentAndOtherStatusesNeverWait() throws {
        let rows: [(ThrottleUpstream.Step, Int, [String: Int])] = [
            (.spent, 200, ["tok-a": 1, "tok-b": 1]),
            (.status(401), 401, ["tok-a": 1]),
            (.status(403), 403, ["tok-a": 1]),
            (.status(500), 500, ["tok-a": 1]),
        ]
        for (step, status, calls) in rows {
            let r = try rig()
            r.up.set("tok-a", [step])
            let resp = try XCTUnwrap(r.post(), "\(status)")
            XCTAssertEqual(resp.status, status)
            XCTAssertEqual(r.up.calls, calls, "\(status)")
            XCTAssertEqual(r.rec.waits, [], "\(status)")
        }
    }

    // Entry decision: a body above the replay cap was streamed and cannot be resent; its 429 goes back at once.
    func testBodyOverTheReplayCapIsNotRetried() throws {
        let r = try rig(replayCap: 64 << 10)
        r.up.set("tok-a", [.throttle(nil), .throttle(nil)])
        let head = #"{"model":"claude-opus-5","max_tokens":4096,"pad":""#
        let tail = #""}"#
        let body = Data(head.utf8) + Data(repeating: 97, count: (100 << 10) - head.utf8.count - tail.utf8.count) + Data(tail.utf8)
        let resp = try XCTUnwrap(r.post(body))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertEqual(r.up.calls, ["tok-a": 1])
        XCTAssertEqual(r.up.bodies.map(\.count), [body.count])
        XCTAssertEqual(r.rec.waits, [])
    }

    func testResentBodyIsByteForByteTheFirst() throws {
        let r = try rig()
        r.up.set("tok-a", [.throttle(nil), .throttle(nil)])
        let body = Data(#"{"model":"claude-opus-5","max_tokens":4096,"messages":[{"role":"user","content":"caf"#.utf8)
            + Data([0xC3, 0xA9, 0x20, 0xE2, 0x82, 0xAC, 0x5C, 0x6E]) + Data(#""}]}"#.utf8)
        XCTAssertEqual(r.post(body)?.status, 200)
        XCTAssertEqual(r.up.bodies.count, 3)
        XCTAssertEqual(r.up.bodies, [body, body, body])
    }

    // The client sees the LAST reply's Retry-After on the final 429, and the proxy's own headers.
    func testFinal429CarriesTheLastRepliesHeaders() throws {
        let r = try rig()
        r.up.set("tok-a", [.throttle("3"), .throttle("5"), .throttle("7"), .throttle("9")])
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429)
        XCTAssertEqual(r.rec.waits, [3, 5, 7])
        XCTAssertEqual(resp.header("retry-after"), "9")
        XCTAssertEqual(resp.headers.map { $0.0.lowercased() }.sorted(),
                       ["connection", "content-length", "content-type", "retry-after", "server"])
        XCTAssertEqual(resp.header("server"), "ccpool")
        XCTAssertEqual(resp.header("content-type"), "application/json")
        XCTAssertEqual(r.up.calls, ["tok-a": 4])
    }

    // Pass bound accounts + 3: two spent rotations, then three retries on the third account still fit.
    func testPassBoundLeavesRoomForTheRetriesAfterARotation() throws {
        let r = try rig(3)
        r.up.set("tok-a", [.spent])
        r.up.set("tok-b", [.spent])
        r.up.set("tok-c", [.throttle(nil), .throttle(nil), .throttle(nil), .throttle(nil)])
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429)
        XCTAssertTrue(resp.text.contains("not account quota"), resp.text)
        XCTAssertEqual(r.up.calls, ["tok-a": 1, "tok-b": 1, "tok-c": 4])
        XCTAssertEqual(r.rec.waits, [1, 2, 4])
    }

    // Swift 6: the retry runs on the connection's real queue, never on main, while the test blocks main.
    func testRetryRunsOnTheConnectionQueueOffMain() throws {
        XCTAssertTrue(Thread.isMainThread, "this test blocks the main thread on purpose")
        let r = try rig()
        r.up.set("tok-a", [.throttle(nil), .throttle(nil)])
        XCTAssertEqual(r.post()?.status, 200, "a main-thread hop would deadlock here and time out")
        XCTAssertEqual(r.rec.queues, ["com.prosper.ccpool.conn", "com.prosper.ccpool.conn"])
        XCTAssertEqual(r.rec.ranOnMain, [false, false])
    }

    // A token gone during the wait: the retry never moves to another account; the last 429 goes back.
    func testTokenGoneDuringTheWaitNeverMovesTheRetry() throws {
        let r = try rig()
        r.up.set("tok-a", [.throttle("4")])
        let id = try XCTUnwrap(r.store.snapshot.accounts["Example Org A"]?.id)
        let secrets = r.secrets
        r.rec.beforeContinue = { try? secrets.remove(id: id) }
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429)
        XCTAssertEqual(resp.header("retry-after"), "4")
        XCTAssertEqual(r.up.calls, ["tok-a": 1], "no call to another account")
        XCTAssertEqual(r.rec.waits, [4])
    }

    // #1326 (c): an account removed during the wait is never sent, even when its Keychain item could not be deleted;
    // the log says "account removed", not a missing token; the last 429 goes back.
    func testAccountRemovedDuringTheWaitIsNeverSent() throws {
        for itemLeft in [true, false] {
            let r = try rig()
            r.up.set("tok-a", [.throttle("4")])
            let store = r.store, secrets = r.secrets
            secrets.refuseRemove = itemLeft
            r.rec.beforeContinue = { _ = try? store.removeAccount(label: "Example Org A", secrets: secrets) }
            let resp = try XCTUnwrap(r.post())
            XCTAssertEqual(resp.status, 429, "item left: \(itemLeft)")
            XCTAssertEqual(resp.header("retry-after"), "4")
            XCTAssertEqual(r.up.calls, ["tok-a": 1], "item left: \(itemLeft): no second call")
            XCTAssertTrue(store.snapshot.accounts["Example Org A"] == nil)
            XCTAssertEqual(r.log.lines.filter { $0 == "Example Org A: account removed; skipping this account" }.count, 1, "\(r.log.lines)")
            XCTAssertFalse(r.log.lines.contains { $0.contains("token unavailable") }, "\(r.log.lines)")
        }
    }

    // A client that left during the wait gets no upstream call.
    func testClientGoneDuringTheWaitGetsNoUpstreamCall() throws {
        let r = try rig()
        r.rec.hold = true
        r.up.set("tok-a", [.throttle(nil)])
        let raw = Data("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(r.port)\r\ncontent-type: application/json\r\ncontent-length: \(throttleWork.count)\r\n\r\n".utf8)
            + throttleWork
        let q = DispatchQueue(label: "ccpool.test.leaver")
        let c = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: r.port)!, using: .tcp)
        c.stateUpdateHandler = { state in
            if case .ready = state { c.send(content: raw, completion: .idempotent) }
        }
        c.start(queue: q)
        XCTAssertEqual(r.rec.heldSignal.wait(timeout: .now() + 10), .success, "the retry asked for its wait")
        c.cancel()
        XCTAssertEqual(r.log.leftSignal.wait(timeout: .now() + 10), .success, "the proxy saw the client leave")
        r.rec.releaseHeld()
        r.rec.hold = false
        // A later request on the same account: had the left one been resent, it would be counted before this one.
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertEqual(r.up.calls, ["tok-a": 2], "the throttled call and the later request only")
        XCTAssertEqual(r.rec.waits, [1])
    }

    // #1572 (O7, R1326-n1): a request that went out on a reused (pooled) connection which the far end dropped, on an
    // account removed meanwhile (its Keychain item left): the one resend is never sent. One request reached the
    // upstream for it, no fresh connection opened, the log says "account removed", and no token was read for the resend.
    func testPooledDropOnAnAccountRemovedBeforeOnDoneIsNeverResent() throws {
        var counter: ReadCountingSecrets?
        let r = try rig(1) { mem in
            let c = ReadCountingSecrets(mem)
            counter = c
            return c
        }
        let reads = try XCTUnwrap(counter)
        let store = r.store, secrets = r.secrets
        let id = try XCTUnwrap(store.snapshot.accounts["Example Org A"]?.id)
        r.up.set("tok-a", [.status(200), .drop {
            secrets.refuseRemove = true
            _ = try? store.removeAccount(label: "Example Org A", secrets: secrets)
        }])
        XCTAssertEqual(r.post()?.status, 200, "opens the pooled connection")
        XCTAssertEqual(r.server.accepted, 1)
        XCTAssertEqual(reads.reads, 1)
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertEqual(r.up.calls, ["tok-a": 2], "the first request and the dropped one; no resend")
        XCTAssertEqual(r.server.accepted, 1, "the second request rode the pooled connection and no fresh one was opened")
        XCTAssertTrue(store.snapshot.accounts["Example Org A"] == nil)
        XCTAssertTrue(try secrets.token(id: id) != nil, "its Keychain item was left behind")
        XCTAssertEqual(r.log.lines.filter { $0 == "Example Org A: account removed; skipping this account" }.count, 1, "\(r.log.lines)")
        XCTAssertFalse(r.log.lines.contains { $0.contains("retrying once") || $0.contains("token unavailable") }, "\(r.log.lines)")
        XCTAssertEqual(reads.reads, 2, "one read per first attempt; the resend read none")
    }
}
