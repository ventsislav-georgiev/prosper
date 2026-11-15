import XCTest
@testable import ProsperApp

// #1262: after the three same-account retries of a throughput 429 a keyed conversation moves ONCE to the account
// route()/place() gives with the refusing account excluded; refused there too, it is pinned back and one 429 goes out.
// Ported from ccpool v1.9.0 test_ccpool_proxy.py 386-427 ("A throttled conversation moves once, and back if that did
// not help"). Fakes only; the stub upstream on an ephemeral loopback port; the wait recorder is installed FIRST.

final class CCPoolThrottleMoveTests: XCTestCase {
    let orgA = "Example Org A", orgB = "Example Org B", orgC = "Example Org C"
    let sid = "sess-example-1", key = "sess-example-1/"

    struct Rig {
        let up: PinUpstream
        let store: CCPoolStore
        let secrets: CCPoolMemorySecrets
        let log: ThrottleLog
        let rec: ThrottleWaitRecorder
        let seams: PinSeams
        let port: UInt16
        func post(_ sid: String?, body: Data = throttleWork) -> CCPoolClientResponse? {
            var h = [("content-type", "application/json")]
            if let sid { h.append(("X-Claude-Code-Session-Id", sid)) }
            return CCPoolTestClient.request(port: port, headers: h, body: body)
        }
        var pins: [String: String] { store.snapshot.pins.mapValues(\.account) }
        /// Upstream calls per token from the `from`-th call on.
        func calls(from: Int) -> [String: Int] { up.tokens.dropFirst(from).reduce(into: [:]) { $0[$1, default: 0] += 1 } }
    }

    /// `dropping`: that token's requests are read and the connection closed unanswered; every other reply then says
    /// "Connection: close", so no request rides a pooled connection and none is resent (one call, literal).
    private func rig(_ count: Int = 2, replayCap: Int = 32 << 20, dropping: String? = nil) throws -> Rig {
        let rec = ThrottleWaitRecorder()
        let saved = CCPoolConnection.throttleWait
        CCPoolConnection.throttleWait = { s, q, go in rec.wait(s, q, go) }
        addTeardownBlock { CCPoolConnection.throttleWait = saved }
        let up = PinUpstream()
        let server = try CCPoolFakeServer { h, b in
            let reply = up.reply(h, b)
            guard let dropping else { return reply }
            if h.header("authorization") == "Bearer \(dropping)" { return .drop }
            guard case .respond(let status, let headers, let body) = reply else { return reply }
            return .respond(status, headers + [("Connection", "close")], body)
        }
        XCTAssertNotEqual(server.port, 0)
        let seams = PinSeams(now: Date().timeIntervalSince1970)
        let log = ThrottleLog()
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { seams.now }, logger: log,
                                writer: { d, u in seams.write(d, u) })
        let secrets = CCPoolMemorySecrets()
        for l in throttleLabels.prefix(count) { _ = try store.addAccount(label: l, token: throttleTokens[l] ?? "", secrets: secrets) }
        store.mutate { $0.current = orgA }
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(server.port)")!
        cfg.replayCap = replayCap
        cfg.timeout = 10
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); server.stop() }
        return Rig(up: up, store: store, secrets: secrets, log: log, rec: rec, seams: seams, port: p)
    }

    /// The session pinned to Example Org A by a first request (place ties by order), before anything is scripted.
    private func pinnedOnA(_ r: Rig) {
        XCTAssertEqual(r.post(sid)?.status, 200)
        XCTAssertEqual(r.pins, [key: orgA])
    }

    private let fourThrottles: [ThrottleUpstream.Step] = [.throttle(nil), .throttle(nil), .throttle(nil), .throttle("6")]

    // PT 395-405: served by another account after the retries; the pin moves there (one write), `current` stays.
    func testMoveAndServe() throws {
        let r = try rig()
        pinnedOnA(r)
        r.up.set("tok-a", fourThrottles)
        let n = r.up.tokens.count, w = r.seams.writes
        let resp = try XCTUnwrap(r.post(sid))
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertEqual(r.calls(from: n), ["tok-a": 4, "tok-b": 1])
        XCTAssertEqual(r.up.tokens.last, "tok-b")
        XCTAssertEqual(r.pins, [key: orgB])
        XCTAssertEqual(r.seams.writes, w + 1, "the move is the one write")
        XCTAssertEqual(r.store.snapshot.current, orgA, "the move does not move current")
        XCTAssertEqual(r.rec.waits, [1, 2, 4])
        XCTAssertEqual(r.log.lines.filter { $0.contains("moving the conversation once") },
                       ["Example Org A: throttled after 3 same-account retries; moving the conversation once"])
        // Once moved it goes straight there: its cache lives there.
        let m = r.up.tokens.count
        XCTAssertEqual(r.post(sid)?.status, 200)
        XCTAssertEqual(r.calls(from: m), ["tok-b": 1])
    }

    // PT 406-416: refused at the destination too: 4 + 1 calls, never a third account, the pin back on A (written
    // once), ONE 429 with the destination's Retry-After, nothing waited at the destination.
    func testMoveAndRefusePinsBackAndNeverWalks() throws {
        let r = try rig(3)
        pinnedOnA(r)
        r.up.set("tok-a", fourThrottles)
        r.up.set("tok-b", [.throttle("7")])
        let n = r.up.tokens.count, w = r.seams.writes
        let resp = try XCTUnwrap(r.post(sid))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertTrue(resp.text.contains("upstream rate limit (not account quota)"), resp.text)
        XCTAssertEqual(resp.header("retry-after"), "7")
        XCTAssertEqual(r.calls(from: n), ["tok-a": 4, "tok-b": 1], "no third account")
        XCTAssertEqual(r.pins, [key: orgA])
        XCTAssertEqual(r.seams.writes, w + 2, "the move, then the pin back")
        XCTAssertEqual(r.rec.waits, [1, 2, 4], "no wait at the destination")
        XCTAssertEqual(r.log.lines.filter { $0.contains("pinned back") }.count, 1)
        for l in [orgA, orgB] { XCTAssertEqual(r.store.snapshot.accounts[l]?.cooldown, [:], "a throttle benches nobody") }
    }

    // Nowhere to go (one account; the other benched): 4 and 0, the pin unchanged and not rewritten, one 429.
    func testNowhereToMoveReturnsTheLast429() throws {
        for benched in [false, true] {
            let r = try rig(benched ? 2 : 1)
            pinnedOnA(r)
            if benched {
                let now = r.seams.now
                r.store.mutate { $0.bench(orgB, claim: CCPoolCore.fiveHour, until: Int(now) + 3600, now: now) }
            }
            r.up.set("tok-a", fourThrottles)
            let n = r.up.tokens.count, w = r.seams.writes
            let resp = try XCTUnwrap(r.post(sid), "\(benched)")
            XCTAssertEqual(resp.status, 429, "\(benched)")
            XCTAssertTrue(resp.text.contains("not account quota"), resp.text)
            XCTAssertEqual(resp.header("retry-after"), "6", "\(benched)")
            XCTAssertEqual(r.calls(from: n), ["tok-a": 4], "\(benched)")
            XCTAssertEqual(r.pins, [key: orgA], "\(benched)")
            XCTAssertEqual(r.seams.writes, w, "\(benched)")
            XCTAssertEqual(r.rec.waits, [1, 2, 4], "\(benched)")
        }
    }

    // PY 486: a request with no session id never moves and makes no pin.
    func testNoSessionIdNeverMoves() throws {
        let r = try rig()
        r.up.set("tok-a", fourThrottles)
        let resp = try XCTUnwrap(r.post(nil))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertEqual(r.calls(from: 0), ["tok-a": 4])
        XCTAssertEqual(r.pins, [:])
        XCTAssertEqual(r.rec.waits, [1, 2, 4])
    }

    // PT 417-421: a quota check is answered at once: one call, no retry, no move, the pin where it was.
    func testQuotaCheckNeverMoves() throws {
        let r = try rig()
        pinnedOnA(r)
        r.up.set("tok-a", [.throttle("2"), .throttle(nil)])
        let n = r.up.tokens.count
        let resp = try XCTUnwrap(r.post(sid, body: throttleQuotaCheck))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertEqual(r.calls(from: n), ["tok-a": 1])
        XCTAssertEqual(r.pins, [key: orgA])
        XCTAssertEqual(r.rec.waits, [])
    }

    // A body above the replay cap went upstream as a stream: no retry, no move (CCPoolConnection finishSnippet).
    func testBodyAboveTheReplayCapNeverMoves() throws {
        let r = try rig(replayCap: 64 << 10)
        pinnedOnA(r)
        r.up.set("tok-a", [.throttle(nil), .throttle(nil)])
        let head = #"{"model":"claude-opus-5","max_tokens":4096,"pad":""#
        let tail = #""}"#
        let body = Data(head.utf8) + Data(repeating: 97, count: (100 << 10) - head.utf8.count - tail.utf8.count) + Data(tail.utf8)
        let n = r.up.tokens.count
        let resp = try XCTUnwrap(r.post(sid, body: body))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertEqual(r.calls(from: n), ["tok-a": 1])
        XCTAssertEqual(r.pins, [key: orgA])
        XCTAssertEqual(r.rec.waits, [])
    }

    // The destination's token is gone: nothing walks on to a third account; back on A, A's last 429 goes out.
    func testTokenMissingAtTheDestinationPinsBack() throws {
        let r = try rig(3)
        pinnedOnA(r)
        r.up.set("tok-a", fourThrottles)
        let id = try XCTUnwrap(r.store.snapshot.accounts[orgB]?.id)
        try r.secrets.remove(id: id)
        let n = r.up.tokens.count
        let resp = try XCTUnwrap(r.post(sid))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertEqual(resp.header("retry-after"), "6")
        XCTAssertEqual(r.calls(from: n), ["tok-a": 4])
        XCTAssertEqual(r.pins, [key: orgA])
    }

    // R1262-a: after the one move the destination closes the connection unanswered (a transport failure): the pool's
    // own 502 goes out and the conversation is pinned back on A first (one write), no second move, no retry.
    func testTransportFailureAtTheDestinationPinsBack() throws {
        let r = try rig(3, dropping: "tok-b")
        pinnedOnA(r)
        r.up.set("tok-a", fourThrottles)
        let n = r.up.tokens.count, w = r.seams.writes
        let resp = try XCTUnwrap(r.post(sid))
        XCTAssertEqual(resp.status, 502, resp.text)
        XCTAssertTrue(resp.text.contains("upstream unreachable"), resp.text)
        XCTAssertEqual(r.calls(from: n), ["tok-a": 4, "tok-b": 1], "no third account, no resend")
        XCTAssertEqual(r.pins, [key: orgA])
        XCTAssertEqual(r.seams.writes, w + 2, "the move, then the pin back")
        XCTAssertEqual(r.rec.waits, [1, 2, 4], "no wait at the destination")
        XCTAssertEqual(r.log.lines.filter { $0.contains("pinned back") }, ["Example Org A: conversation pinned back after its one move"])
        // The next turn goes where the cache is.
        let m = r.up.tokens.count
        XCTAssertEqual(r.post(sid)?.status, 200)
        XCTAssertEqual(r.calls(from: m), ["tok-a": 1])
    }
}
