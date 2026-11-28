import XCTest
@testable import ProsperApp

// #1278 step B: an account whose token answers 401 on /v1/messages leaves routing (persisted in accounts.<label>.refused)
// until a 2xx reply, Release or a new token; every account refused: one is tried anyway (not for a move, never over a
// bench). The 401 itself is passed through unchanged. Fakes only; the stub upstream on an ephemeral loopback port; the
// wait recorder is installed FIRST; the store in tempDir() on the seams clock.

final class AgentPoolAuthRefusedTests: XCTestCase {
    let orgA = "Example Org A", orgB = "Example Org B"
    let sid = "sess-example-1", key = "sess-example-1/"
    let markLine = "Example Org A: token rejected (401); not routed until a reply succeeds, Refresh, Release or a new token"

    struct Rig {
        let up: PinUpstream
        let store: AgentPoolStore
        let dir: URL
        let log: ThrottleLog
        let seams: PinSeams
        let port: UInt16
        func post(_ sid: String? = nil, path: String = "/v1/messages", body: Data = throttleWork) -> AgentPoolClientResponse? {
            var h = [("content-type", "application/json")]
            if let sid { h.append(("X-Claude-Code-Session-Id", sid)) }
            return AgentPoolTestClient.request(port: port, path: path, headers: h, body: body)
        }
        var pins: [String: String] { store.snapshot.pins.mapValues(\.account) }
        func refused(_ l: String) -> Int? { store.snapshot.accounts[l]?.refused }
        func refuse(_ l: String, at stamp: Int) { store.mutate { $0.accounts[l]?.refused = stamp } }
        func bench(_ l: String) {
            let now = seams.now
            store.mutate { $0.bench(l, claim: AgentPoolCore.fiveHour, until: Int(now) + 3600, now: now) }
        }
        func calls(from: Int) -> [String: Int] { up.tokens.dropFirst(from).reduce(into: [:]) { $0[$1, default: 0] += 1 } }
    }

    /// `current` is left nil: unkeyed requests pick by order (A first) until a reply remembers one.
    private func rig(_ count: Int = 2) throws -> Rig {
        let rec = ThrottleWaitRecorder()
        let saved = AgentPoolConnection.throttleWait
        AgentPoolConnection.throttleWait = { s, q, go in rec.wait(s, q, go) }
        addTeardownBlock { AgentPoolConnection.throttleWait = saved }
        let up = PinUpstream()
        let server = try AgentPoolFakeServer { h, b in up.reply(h, b) }
        XCTAssertNotEqual(server.port, 0)
        let seams = PinSeams(now: Date().timeIntervalSince1970.rounded())
        let log = ThrottleLog()
        let dir = tempDir().appendingPathComponent("ccpool")
        let store = AgentPoolStore(directory: dir, clock: { seams.now }, logger: log, writer: { d, u in seams.write(d, u) })
        let secrets = AgentPoolMemorySecrets()
        for l in throttleLabels.prefix(count) { _ = try store.addAccount(label: l, token: throttleTokens[l] ?? "", secrets: secrets) }
        var cfg = AgentPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(server.port)")!
        cfg.timeout = 10
        let service = AgentPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); server.stop() }
        return Rig(up: up, store: store, dir: dir, log: log, seams: seams, port: p)
    }

    // B1: a 401 is passed through, marks A with the clock's epoch, never makes A current; the next request goes to B.
    func testB1A401MarksPassesThroughAndIsNotCurrent() throws {
        let r = try rig()
        r.up.set("tok-a", [.status(401)])
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 401, resp.text)
        XCTAssertEqual(r.calls(from: 0), ["tok-a": 1])
        XCTAssertEqual(r.refused(orgA), Int(r.seams.now))
        XCTAssertTrue(r.store.snapshot.current == nil, "a refused account never becomes current")
        XCTAssertEqual(r.log.lines.filter { $0.contains("token rejected (401)") }, [markLine])
        let n = r.up.tokens.count
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertEqual(r.calls(from: n), ["tok-b": 1])
        XCTAssertEqual(r.refused(orgA), Int(r.seams.now), "a reply of another account clears nothing")
    }

    // B2: a second 401 keeps the first stamp and writes nothing (A reached by the last resort, B refused too: since
    // R1278b-a a merely benched B answers 429 instead of reaching the last resort).
    func testB2ASecond401WritesNothing() throws {
        let r = try rig()
        let stamp = Int(r.seams.now)
        r.refuse(orgA, at: stamp)
        r.refuse(orgB, at: stamp)
        r.seams.now += 60
        r.up.set("tok-a", [.status(401)])
        let w = r.seams.writes
        XCTAssertEqual(r.post()?.status, 401)
        XCTAssertEqual(r.calls(from: 0), ["tok-a": 1])
        XCTAssertEqual(r.refused(orgA), stamp, "the first stamp is kept")
        XCTAssertEqual(r.seams.writes, w)
        XCTAssertEqual(r.log.lines.filter { $0.contains("token rejected (401)") }, [])
    }

    // B3: a pinned conversation whose account answers 401 is re-placed on the next turn: never back to A.
    // Writes: +1 for the 401 (the mark; the pin it followed is only touched), then +2 (the re-pin, and current A -> B,
    // since the re-placed reply did not follow a pin).
    func testB3APinnedConversationLeavesARefusedAccount() throws {
        let r = try rig()
        XCTAssertEqual(r.post(sid)?.status, 200)
        XCTAssertEqual(r.pins, [key: orgA])
        r.up.set("tok-a", [.status(401)])
        let n = r.up.tokens.count, w = r.seams.writes
        XCTAssertEqual(r.post(sid)?.status, 401)
        XCTAssertEqual(r.calls(from: n), ["tok-a": 1])
        XCTAssertEqual(r.seams.writes, w + 1)
        let m = r.up.tokens.count
        XCTAssertEqual(r.post(sid)?.status, 200)
        XCTAssertEqual(r.calls(from: m), ["tok-b": 1])
        XCTAssertEqual(r.pins, [key: orgB])
        XCTAssertEqual(r.seams.writes, w + 3)
    }

    // B4: the mark survives a restart; a state.json written by the code before #1278 loads with refused nil and is
    // written back byte for byte.
    func testB4RefusalIsPersistedAndAnOldFileRoundTrips() throws {
        let r = try rig()
        r.up.set("tok-a", [.status(401)])
        XCTAssertEqual(r.post()?.status, 401)
        let stamp = try XCTUnwrap(r.refused(orgA))
        let t = r.seams.now
        XCTAssertEqual(AgentPoolStore(directory: r.dir, clock: { t }).snapshot.accounts[orgA]?.refused, stamp)

        let old = """
            {
              "accounts" : {
                "Example Org A" : {
                  "cooldown" : {
                    "five_hour" : 1800003600
                  },
                  "id" : "id-example-a",
                  "reset" : {
                    "five_hour" : 1800003600
                  }
                }
              },
              "current" : "Example Org A",
              "order" : [
                "Example Org A"
              ]
            }
            """
        let dir = tempDir().appendingPathComponent("ccpool")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.json")
        try Data(old.utf8).write(to: url)
        let st = AgentPoolStore(directory: dir, clock: { 1_800_000_000 })
        XCTAssertTrue(st.snapshot.accounts[orgA] != nil)
        XCTAssertTrue(st.snapshot.accounts[orgA]?.refused == nil)
        // Two real writes through the store's own encoder; the second puts the content back.
        st.mutate { $0.current = nil }
        st.mutate { $0.current = "Example Org A" }
        let back = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: back, as: UTF8.self).contains("refused"))
        XCTAssertEqual(String(decoding: back, as: UTF8.self), old)
    }

    // B5: a 403 never marks: passed through, and the next request goes to the same account.
    func testB5A403NeverMarks() throws {
        let r = try rig()
        r.up.set("tok-a", [.status(403)])
        XCTAssertEqual(r.post()?.status, 403)
        XCTAssertTrue(r.refused(orgA) == nil)
        let n = r.up.tokens.count
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertEqual(r.calls(from: n), ["tok-a": 1])
    }

    // B6 (OQ2): a 401 off /v1/messages marks nothing; one on /v1/messages with a query does.
    func testB6A401OffTheMessagesPathDoesNotMark() throws {
        let r = try rig()
        r.up.set("tok-a", [.status(401), .status(401)])
        XCTAssertEqual(r.post(path: "/v1/other")?.status, 401)
        XCTAssertTrue(r.refused(orgA) == nil)
        XCTAssertEqual(r.post(path: "/v1/messages?beta=true")?.status, 401)
        XCTAssertEqual(r.refused(orgA), Int(r.seams.now))
        XCTAssertEqual(r.calls(from: 0), ["tok-a": 2])
    }

    // B7: a 500 and a throughput 429 leave the mark; a 2xx clears it (logged); Release clears it; a Replace makes a
    // fresh account with none.
    func testB7WhatClearsARefusal() throws {
        let r = try rig(1)
        let stamp = Int(r.seams.now)
        r.refuse(orgA, at: stamp)
        r.up.set("tok-a", [.status(500), .throttle(nil)])
        XCTAssertEqual(r.post()?.status, 500)
        XCTAssertEqual(r.refused(orgA), stamp, "a 500 does not clear")
        XCTAssertEqual(r.post(body: throttleQuotaCheck)?.status, 429)
        XCTAssertEqual(r.refused(orgA), stamp, "a throughput 429 does not clear")
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertTrue(r.refused(orgA) == nil, "a 2xx clears")
        XCTAssertEqual(r.log.lines.filter { $0.contains("back in routing") }, ["Example Org A: token accepted again; back in routing"])
        XCTAssertEqual(r.calls(from: 0), ["tok-a": 3])

        r.refuse(orgA, at: stamp)
        r.store.mutate { $0.clear(orgA) }
        XCTAssertTrue(r.refused(orgA) == nil, "Release clears")

        let st = AgentPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { 1_800_000_000 })
        let secrets = AgentPoolMemorySecrets()
        try st.addAccount(label: orgA, token: "tok-a", secrets: secrets)
        st.mutate { $0.accounts[orgA]?.refused = 1_800_000_000 }
        let vault = tempDir().appendingPathComponent(AgentPoolVaultImport.vaultFileName)
        try Data(#"{"accounts": {"Example Org A": {"token": "tok-a2"}}}"#.utf8).write(to: vault)
        let out = try AgentPoolVaultImport.run(vault: vault, store: st, secrets: secrets, choices: [orgA: .replace], now: 1_800_000_000)
        XCTAssertEqual(out.replaced, [orgA])
        XCTAssertTrue(st.snapshot.accounts[orgA]?.refused == nil, "a new token is a fresh account")
    }

    // B8: every account refused: one is tried anyway; its 2xx clears it, the other stays refused.
    func testB8LastResortWhenEveryAccountIsRefused() throws {
        let r = try rig()
        let stamp = Int(r.seams.now)
        r.refuse(orgA, at: stamp)
        r.refuse(orgB, at: stamp)
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertEqual(r.calls(from: 0), ["tok-a": 1])
        XCTAssertTrue(r.refused(orgA) == nil)
        XCTAssertEqual(r.refused(orgB), stamp)
        XCTAssertEqual(r.log.lines.filter { $0.contains("trying a rejected token") },
                       ["Example Org A: no other account is routable; trying a rejected token"])
    }

    // B9: all benched beats the last resort: today's 429, no upstream call.
    func testB9AllBenchedBeatsTheLastResort() throws {
        let r = try rig()
        r.refuse(orgA, at: Int(r.seams.now))
        r.bench(orgA)
        r.bench(orgB)
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertTrue(resp.text.contains("all pooled accounts are rate limited. Earliest reset "), resp.text)
        XCTAssertEqual(r.up.tokens.count, 0)
    }

    // B10: the one move never lands on a refused account: nowhere to go, pinned back on A (no write), A's 429.
    func testB10AMoveNeverLandsOnARefusedAccount() throws {
        let r = try rig()
        XCTAssertEqual(r.post(sid)?.status, 200)
        XCTAssertEqual(r.pins, [key: orgA])
        r.refuse(orgB, at: Int(r.seams.now))
        r.up.set("tok-a", [.throttle(nil), .throttle(nil), .throttle(nil), .throttle("6")])
        let n = r.up.tokens.count, w = r.seams.writes
        let resp = try XCTUnwrap(r.post(sid))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertTrue(resp.text.contains("upstream rate limit (not account quota)"), resp.text)
        XCTAssertEqual(resp.header("retry-after"), "6")
        XCTAssertEqual(r.calls(from: n), ["tok-a": 4], "never tok-b")
        XCTAssertEqual(r.pins, [key: orgA])
        XCTAssertEqual(r.seams.writes, w)
        XCTAssertTrue(r.log.lines.contains("Example Org A: conversation pinned back after its one move"))
        XCTAssertEqual(r.log.lines.filter { $0.contains("trying a rejected token") }, [])
    }

    // R1278b-a (a): a healthy account that is only benched beats the last resort: A refused, B benched (five_hour) ->
    // today's 429 with B's reset, zero upstream calls, no last-resort line. (b), every account refused, is B8.
    func testB12ABenchedHealthyAccountBeatsTheLastResort() throws {
        let r = try rig()
        r.refuse(orgA, at: Int(r.seams.now))
        r.bench(orgB)
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertTrue(resp.text.contains("all pooled accounts are rate limited. Earliest reset "), resp.text)
        XCTAssertEqual(r.up.tokens.count, 0)
        XCTAssertEqual(r.log.lines.filter { $0.contains("trying a rejected token") }, [])
        // The same request keyed: route() finds nothing and the last resort stays off too.
        let keyed = try XCTUnwrap(r.post(sid))
        XCTAssertEqual(keyed.status, 429, keyed.text)
        XCTAssertEqual(r.up.tokens.count, 0)
        // (c) Both refused and both benched: the last resort is reached but still honours cooldowns (B9 no longer
        // reaches it: its B is not refused).
        r.refuse(orgB, at: Int(r.seams.now))
        r.bench(orgA)
        let benched = try XCTUnwrap(r.post())
        XCTAssertEqual(benched.status, 429, benched.text)
        XCTAssertTrue(benched.text.contains("all pooled accounts are rate limited. Earliest reset "), benched.text)
        XCTAssertEqual(r.up.tokens.count, 0)
    }
}
