import XCTest
@testable import ProsperApp

// #1263: the log line of a throughput 429 says the request's shape (bytes, max_tokens, effort, speed, the NAMES of unusual
// response headers) and the attempts (attempt, retry, outcome); a served reply after throttles says its count and outcome.
// Privacy: the PUBLIC part holds counts, fixed words and header names that passed the name rule; the model, the body snippet
// and every header value stay private or out; the session id and the token are in no part. The logger here keeps the two
// parts apart, so a row asserts on the parts and never on a joined string. Fakes only; the stub upstream on an
// ephemeral loopback port; the wait recorder is installed FIRST in every rig; no row sleeps.

/// Records every note with its label, public text and private text apart.
final class SplitLog: CCPoolLogger, @unchecked Sendable {
    struct Line { var label: String?; var pub: String; var priv: String }
    private let lock = NSLock()
    private var _lines: [Line] = []
    var lines: [Line] { lock.withLock { _lines } }
    func note(_ label: String?, _ message: String) { lock.withLock { _lines.append(Line(label: label, pub: message, priv: "")) } }
    func note(_ label: String?, _ message: String, private detail: String) {
        lock.withLock { _lines.append(Line(label: label, pub: message, priv: detail)) }
    }
    /// The 429 notes, the served notes.
    var throttles: [Line] { lines.filter { $0.pub.hasPrefix("429 ") } }
    var served: [Line] { lines.filter { $0.pub.hasPrefix("served after ") } }
}

/// The stub upstream: tok-a answers its first call 200, then `throttles` throttles carrying `extra` headers; tok-b 200.
final class ShapeUpstream: @unchecked Sendable {
    private let lock = NSLock()
    private var aCalls = 0
    private var bCalls = 0
    private let throttles: Int
    private let bThrottles: Int
    private let extra: [(String, String)]
    static let busy = "SNIPPET-BUSY-TEXT"
    init(throttles: Int, bThrottles: Int = 0, extra: [(String, String)]) {
        self.throttles = throttles; self.bThrottles = bThrottles; self.extra = extra
    }
    func reply(_ head: CCPoolRequestHead, _ body: Data) -> CCPoolFakeServer.Reply {
        let token = String((head.header("authorization") ?? "").dropFirst("Bearer ".count))
        let n = lock.withLock { () -> Int in if token == "tok-a" { aCalls += 1 }; return aCalls }
        let m = lock.withLock { () -> Int in if token == "tok-b" { bCalls += 1 }; return bCalls }
        if (token == "tok-a" && n >= 2 && n <= 1 + throttles) || (token == "tok-b" && m <= bThrottles) {
            return .respond(429, [("content-type", "application/json")] + extra, Data(Self.busy.utf8))
        }
        return .respond(200, [("content-type", "application/json")], Data(#"{"type":"message","content":[]}"#.utf8))
    }
}

final class CCPoolThrottleLogTests: XCTestCase {
    let orgA = "Example Org A", orgB = "Example Org B"
    let sid = "sess-example-1"

    /// 106 bytes: the model, max_tokens 4096, speed fast, effort high.
    static let work = Data(#"{"model":"claude-opus-5","max_tokens":4096,"speed":"fast","output_config":{"effort":"high"},"messages":[]}"#.utf8)

    struct Rig {
        let log: SplitLog
        let rec: ThrottleWaitRecorder
        let port: UInt16
        func post(_ body: Data, sid: String?) -> CCPoolClientResponse? {
            var h = [("content-type", "application/json")]
            if let sid { h.append(("X-Claude-Code-Session-Id", sid)) }
            return CCPoolTestClient.request(port: port, headers: h, body: body)
        }
    }

    private func rig(throttles: Int, bThrottles: Int = 0, extra: [(String, String)] = []) throws -> Rig {
        // The delay recorder first: no row waits.
        let rec = ThrottleWaitRecorder()
        let saved = CCPoolConnection.throttleWait
        CCPoolConnection.throttleWait = { s, q, go in rec.wait(s, q, go) }
        addTeardownBlock { CCPoolConnection.throttleWait = saved }
        let up = ShapeUpstream(throttles: throttles, bThrottles: bThrottles, extra: extra)
        let server = try CCPoolFakeServer { h, b in up.reply(h, b) }
        XCTAssertNotEqual(server.port, 0)
        let log = SplitLog()
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { Date().timeIntervalSince1970 }, logger: log,
                                writer: { d, u in CCPoolStore.atomicWrite(d, u) })
        let secrets = CCPoolMemorySecrets()
        _ = try store.addAccount(label: orgA, token: "tok-a", secrets: secrets)
        _ = try store.addAccount(label: orgB, token: "tok-b", secrets: secrets)
        store.mutate { $0.current = orgA }
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(server.port)")!
        cfg.timeout = 10
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); server.stop() }
        return Rig(log: log, rec: rec, port: p)
    }

    // Retried three times, moved, served: every field of every line, in order, as a literal; the private parts apart.
    func testRetriedThreeTimesMovedAndServedLiteral() throws {
        let r = try rig(throttles: 4, extra: [("X-Trace-Id", "VALUE-TRACE-1"), ("x-queue-depth", "VALUE-DEPTH-2")])
        XCTAssertEqual(r.post(Self.work, sid: sid)?.status, 200, "the first request pins the session on A")
        XCTAssertEqual(r.post(Self.work, sid: sid)?.status, 200)
        XCTAssertEqual(r.rec.waits, [1, 2, 4])
        let common = "429 quota=NO unified rate-limit headers; retry-after=?; cooldown=none; bytes=106; max_tokens=4096; "
            + "effort=high; speed=fast; resp-headers=x-queue-depth,x-trace-id; "
        let outcomes = ["attempt=1; retry=0; outcome=retry", "attempt=2; retry=1; outcome=retry",
                        "attempt=3; retry=2; outcome=retry", "attempt=4; retry=3; outcome=move"]
        XCTAssertEqual(r.log.throttles.map(\.pub), outcomes.map { common + $0 + "; reason=no exhausted quota" })
        XCTAssertEqual(r.log.throttles.map(\.label), Array(repeating: orgA, count: 4))
        let priv = "; model=claude-opus-5; body=" + ShapeUpstream.busy
        XCTAssertEqual(r.log.throttles.map(\.priv), Array(repeating: priv, count: 4))
        XCTAssertEqual(r.log.served.map(\.pub),
                       ["served after 4 throttled attempt(s); attempt=5; retry=3; outcome=moved-served"])
        XCTAssertEqual(r.log.served.map(\.label), [orgB])
        // The public part never holds the model, the snippet or a header value.
        for l in r.log.lines {
            for secret in ["claude-opus-5", ShapeUpstream.busy, "VALUE-TRACE-1", "VALUE-DEPTH-2"] {
                XCTAssertFalse(l.pub.contains(secret), "\(secret) in the public part: \(l.pub)")
            }
        }
        XCTAssertTrue(r.log.throttles.allSatisfy { $0.pub.utf8.count < 640 }, "the line is bounded")
    }

    // Served after retries on the same account: the fixed word "served"; refused at the destination: "pinned-back".
    func testServedAndPinnedBackWords() throws {
        let a = try rig(throttles: 2)
        XCTAssertEqual(a.post(Self.work, sid: sid)?.status, 200)
        XCTAssertEqual(a.post(Self.work, sid: sid)?.status, 200)
        XCTAssertEqual(a.log.served.map(\.pub), ["served after 2 throttled attempt(s); attempt=3; retry=2; outcome=served"])
        let b = try rig(throttles: 4, bThrottles: 1)
        XCTAssertEqual(b.post(Self.work, sid: sid)?.status, 200)
        XCTAssertEqual(b.post(Self.work, sid: sid)?.status, 429)
        XCTAssertEqual(b.log.throttles.last.map { $0.pub.contains("attempt=5; retry=3; outcome=pinned-back; ") }, true)
        XCTAssertEqual(b.log.throttles.last?.label, orgB)
        XCTAssertTrue(b.log.served.isEmpty)
        // No session key: never moves, the 429 is returned.
        let c = try rig(throttles: 6)
        XCTAssertEqual(c.post(Self.work, sid: nil)?.status, 200)
        XCTAssertEqual(c.post(Self.work, sid: nil)?.status, 429)
        XCTAssertEqual(c.log.throttles.last.map { $0.pub.contains("attempt=4; retry=3; outcome=returned; ") }, true)
    }

    // Effort and speed outside the allow-list are the fixed word "other", never the raw text, in either part.
    func testEffortAndSpeedOutsideTheAllowListAreOther() throws {
        let r = try rig(throttles: 3)
        let body = Data(#"{"model":"claude-opus-5","max_tokens":10,"speed":"RAW-SPEED-ZZ","output_config":{"effort":"RAW-EFFORT-ZZ"}}"#.utf8)
        XCTAssertEqual(r.post(body, sid: nil)?.status, 200)
        XCTAssertEqual(r.post(body, sid: nil)?.status, 200)
        let first = try XCTUnwrap(r.log.throttles.first)
        XCTAssertTrue(first.pub.contains("max_tokens=10; effort=other; speed=other; "), first.pub)
        for l in r.log.lines {
            XCTAssertFalse(l.pub.contains("RAW-EFFORT-ZZ") || l.pub.contains("RAW-SPEED-ZZ"), l.pub)
        }
    }

    // max_tokens as a string on the wire logs "none" (the value rows below cover the rest).
    func testStringMaxTokensOnTheWireLogsNone() throws {
        let r = try rig(throttles: 1)
        let body = Data(#"{"model":"claude-opus-5","max_tokens":"4096"}"#.utf8)
        XCTAssertEqual(r.post(body, sid: nil)?.status, 200)
        XCTAssertEqual(r.post(body, sid: nil)?.status, 200)
        let first = try XCTUnwrap(r.log.throttles.first)
        XCTAssertTrue(first.pub.contains("; max_tokens=none; effort=none; speed=none; "), first.pub)
    }

    func testMaxTokensForms() {
        func mt(_ json: String) -> String {
            CCPoolThrottleShape.maxTokens(try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        XCTAssertEqual(mt(#"{"max_tokens":4096}"#), "4096")
        XCTAssertEqual(mt(#"{"max_tokens":1}"#), "1")
        XCTAssertEqual(mt(#"{"max_tokens":1048576}"#), "1048576")
        for none in [#"{}"#, #"{"max_tokens":"4096"}"#, #"{"max_tokens":-5}"#, #"{"max_tokens":0}"#, #"{"max_tokens":1048577}"#,
                     #"{"max_tokens":99999999999999999999999999}"#, #"{"max_tokens":18446744073709551615}"#,
                     #"{"max_tokens":true}"#, #"{"max_tokens":4096.5}"#, #"{"max_tokens":null}"#,
                     #"{"max_tokens":[1]}"#, #"{"max_tokens":1e400}"#] {
            XCTAssertEqual(mt(none), "none", none)
        }
        XCTAssertEqual(CCPoolThrottleShape.maxTokens(nil), "none")
        XCTAssertEqual(CCPoolThrottleShape.request(bytes: 7, nil), "bytes=7; max_tokens=none; effort=none; speed=none")
        XCTAssertEqual(CCPoolThrottleShape.request(bytes: -1, nil), "bytes=0; max_tokens=none; effort=none; speed=none")
    }

    func testEffortAndSpeedLists() {
        let sets: [(String, Set<String>)] = [("effort", CCPoolThrottleShape.efforts), ("speed", CCPoolThrottleShape.speeds)]
        XCTAssertEqual(sets[0].1, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(sets[1].1, ["standard", "fast"])
        let line = CCPoolThrottleShape.request(bytes: 1, ["speed": 5, "output_config": ["effort": ["high"]]])
        XCTAssertEqual(line, "bytes=1; max_tokens=none; effort=other; speed=other")
        XCTAssertEqual(CCPoolThrottleShape.request(bytes: 1, ["output_config": "x"]), "bytes=1; max_tokens=none; effort=none; speed=none")
    }

    // 12 unusual names, one of 60 characters, a non-ASCII one and a control one: 8 printed sorted, the rest counted, the
    // bad ones counted and not printed; no header value anywhere in either part.
    func testTwelveUnusualHeaderNamesCapAtEightSorted() throws {
        let long = "x-" + String(repeating: "a", count: 58)
        var extra: [(String, String)] = (1...12).reversed().map { (String(format: "X-H%02d", $0), "VALUE-LEAK-\($0)") }
        extra.append((long, "VALUE-LEAK-LONG"))
        extra.append(("retry-after-ish-not", "VALUE-LEAK-ODD"))
        extra.append(("anthropic-ratelimit-unified-extra", "VALUE-LEAK-PFX"))
        let r = try rig(throttles: 1, extra: extra)
        XCTAssertEqual(r.post(Self.work, sid: nil)?.status, 200)
        XCTAssertEqual(r.post(Self.work, sid: nil)?.status, 200)
        let first = try XCTUnwrap(r.log.throttles.first)
        XCTAssertTrue(first.pub.contains("; resp-headers=retry-after-ish-not,x-h01,x-h02,x-h03,x-h04,x-h05,x-h06,x-h07 +5 more; odd-headers=1; "),
                      first.pub)
        for l in r.log.lines {
            XCTAssertFalse((l.pub + l.priv).contains("VALUE-LEAK"), "a header value in a log part: \(l.pub)\(l.priv)")
            XCTAssertFalse(l.pub.contains(long))
        }
    }

    func testHeaderNameRule() {
        let names = ["Date", "Content-Type", "Retry-After", "anthropic-ratelimit-unified-5h-status", "X-Zeta", "x-alpha", "X-ALPHA",
                     "x-caf\u{e9}", "x-k\u{212A}", "x-bad\u{7}", "x-bad\r", "x bad", "", "x_under", String(repeating: "b", count: 41)]
        XCTAssertEqual(CCPoolThrottleShape.headers(names), "x-alpha,x-zeta; odd-headers=8")
        XCTAssertEqual(CCPoolThrottleShape.headers(["Date", "Server"]), "-")
        XCTAssertEqual(CCPoolThrottleShape.headers([String(repeating: "b", count: 40)]), String(repeating: "b", count: 40))
        let many = (1...9).map { "x-n\($0)" }
        XCTAssertEqual(CCPoolThrottleShape.headers(many), "x-n1,x-n2,x-n3,x-n4,x-n5,x-n6,x-n7,x-n8 +1 more")
    }

    // The session id and the token are in neither part of any line (labels apart: an account label is private).
    func testSessionIdAndTokenAreInNeitherPart() throws {
        let r = try rig(throttles: 4, extra: [("x-queue-depth", "VALUE-DEPTH-2")])
        XCTAssertEqual(r.post(Self.work, sid: sid)?.status, 200)
        XCTAssertEqual(r.post(Self.work, sid: sid)?.status, 200)
        XCTAssertFalse(r.log.lines.isEmpty)
        for l in r.log.lines {
            for secret in [sid, "sess-example", "tok-a", "tok-b", "Bearer"] {
                XCTAssertFalse(l.pub.contains(secret) || l.priv.contains(secret), "\(secret) in: \(l.pub)\(l.priv)")
            }
        }
        XCTAssertFalse(r.log.throttles.isEmpty)
        XCTAssertTrue(r.log.throttles.allSatisfy { !$0.pub.contains(orgA) && !$0.pub.contains(orgB) }, "the label is its own argument")
    }
}
