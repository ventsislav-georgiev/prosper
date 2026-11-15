import XCTest
@testable import ProsperApp

// #1259: a request follows its session's pin (ccpool v1.9.0 ccpool_proxy.py conversation() 83-85, choose() 114-147;
// test_ccpool_proxy.py 306-333 and 426-427). #1261: a key with no usable pin is placed by the score (CCPoolPlacementTests).
// Fakes only; the stub upstream on an ephemeral loopback port; every rig installs the wait recorder FIRST.

/// The stub upstream: records which token each request went with; a scripted token answers ThrottleUpstream's script,
/// every other request a plain 200 with no rate-limit headers (so nothing but a pin can change the state).
final class PinUpstream: @unchecked Sendable {
    let script = ThrottleUpstream()
    private let lock = NSLock()
    private var _tokens: [String] = []
    private var scripted: Set<String> = []
    var tokens: [String] { lock.withLock { _tokens } }
    func set(_ token: String, _ steps: [ThrottleUpstream.Step]) {
        _ = lock.withLock { scripted.insert(token) }
        script.set(token, steps)
    }
    func reply(_ head: CCPoolRequestHead, _ body: Data) -> CCPoolFakeServer.Reply {
        let token = String((head.header("authorization") ?? "").dropFirst("Bearer ".count))
        if lock.withLock({ () -> Bool in _tokens.append(token); return scripted.contains(token) }) { return script.reply(head, body) }
        return .respond(200, [("content-type", "application/json")], Data(#"{"type":"message","content":[]}"#.utf8))
    }
}

/// The store's clock and write seams.
final class PinSeams: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Double
    private var _writes = 0
    init(now: Double) { _now = now }
    var now: Double {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    var writes: Int { lock.withLock { _writes } }
    func write(_ data: Data, _ url: URL) -> Bool {
        lock.withLock { _writes += 1 }
        return CCPoolStore.atomicWrite(data, url)
    }
}

final class CCPoolPinRoutingTests: XCTestCase {
    let orgA = "Example Org A", orgB = "Example Org B"
    let t0: Double = 1_800_000_000

    // MARK: The pure function

    private func acct(_ id: String, benchedUntil: Int? = nil) -> CCPoolState.Account {
        CCPoolState.Account(id: id, cooldown: benchedUntil.map { [CCPoolCore.fiveHour: $0] } ?? [:])
    }

    private func pool(pins: [String: CCPoolState.Pin] = [:], benchB: Bool = false, order: [String]? = nil) -> CCPoolState {
        CCPoolState(current: orgA, order: order ?? [orgA, orgB],
                    accounts: [orgA: acct("id-a"), orgB: acct("id-b", benchedUntil: benchB ? Int(t0) + 600 : nil)], pins: pins)
    }

    private func route(_ st: CCPoolState, _ key: String?, quota: Bool = false, exclude: Set<String> = [])
        -> (account: String?, state: CCPoolState, followed: Bool) {
        CCPoolCore.route(st, key: key, quotaCheck: quota, model: "claude-opus-5", exclude: exclude, now: t0)
    }

    private func accounts(_ st: CCPoolState) -> [String: String] { st.pins.mapValues(\.account) }

    func testNoKeyFollowsCurrentAndChangesNothing() {
        let st = pool(pins: ["sess-example-1/": .init(account: orgB, seen: t0 - 10)])
        for key in [nil, "", "sess example-1/", String(repeating: "s", count: 129), "sess-\u{e9}/"] as [String?] {
            let r = route(st, key)
            XCTAssertEqual(r.account, orgA, key ?? "nil")
            XCTAssertEqual(r.state, st, key ?? "nil")
            XCTAssertEqual(r.state.pins["sess-example-1/"]?.seen, t0 - 10, "no touch")
        }
    }

    func testNewConversationIsPinnedWhereThePoolPicksToday() {
        let r = route(pool(), "sess-example-1/")
        XCTAssertEqual(r.account, orgA)
        XCTAssertEqual(accounts(r.state), ["sess-example-1/": orgA])
        XCTAssertEqual(r.state.pins["sess-example-1/"]?.seen, t0)
        let q = route(pool(), "sess-example-1/", quota: true)
        XCTAssertEqual(q.account, orgA)
        XCTAssertTrue(q.state.pins.isEmpty, "a quota check never creates a pin")
    }

    func testPinnedConversationKeepsItsAccountAndIsTouched() {
        let st = pool(pins: ["sess-example-1/": .init(account: orgB, seen: t0 - 10)])
        for quota in [false, true] {
            let r = route(st, "sess-example-1/", quota: quota)
            XCTAssertEqual(r.account, orgB, "\(quota)")
            XCTAssertEqual(accounts(r.state), ["sess-example-1/": orgB], "\(quota)")
            XCTAssertEqual(r.state.pins["sess-example-1/"]?.seen, t0, "touched \(quota)")
            XCTAssertEqual(r.state, st, "a touch is not a change of what the file holds \(quota)")
        }
    }

    func testSubagentFollowsItsSession() {
        let st = pool(pins: ["sess-example-1/": .init(account: orgB, seen: t0 - 10)])
        let r = route(st, "sess-example-1/agent-example-1")
        XCTAssertEqual(r.account, orgB)
        XCTAssertEqual(accounts(r.state), ["sess-example-1/": orgB, "sess-example-1/agent-example-1": orgB])
        let q = route(st, "sess-example-1/agent-example-1", quota: true)
        XCTAssertEqual(q.account, orgB)
        XCTAssertEqual(accounts(q.state), ["sess-example-1/": orgB], "a quota check of a subagent pins nothing")
        // The main conversation first, then the latest sibling (Python sorts (is main, seen) descending).
        let two = pool(pins: ["sess-example-1/": .init(account: orgB, seen: t0 - 500),
                              "sess-example-1/agent-example-2": .init(account: orgA, seen: t0 - 5)])
        XCTAssertEqual(route(two, "sess-example-1/agent-example-3").account, orgB)
        let noMain = pool(pins: ["sess-example-1/agent-example-1": .init(account: orgA, seen: t0 - 500),
                                 "sess-example-1/agent-example-2": .init(account: orgB, seen: t0 - 5)])
        XCTAssertEqual(route(noMain, "sess-example-1/agent-example-3").account, orgB)
        // Another session's pins are not siblings: "sess-example-11/" does not start with "sess-example-1/".
        let other = pool(pins: ["sess-example-11/": .init(account: orgB, seen: t0 - 5)])
        XCTAssertEqual(route(other, "sess-example-1/agent-example-1").account, orgA)
    }

    func testBadAgentValueIsNoSessionIdEvenWhenTheSessionIsPinned() {
        let st = pool(pins: ["sess-example-1/": .init(account: orgB, seen: t0 - 10)])
        for key in ["sess-example-1/agent \u{e9}", "sess-example-1/" + String(repeating: "a", count: 114)] {
            let r = route(st, key)
            XCTAssertEqual(r.account, orgA, "follows current, not the session's pin")
            XCTAssertEqual(r.state, st)
        }
        XCTAssertEqual(route(st, "sess-example-1/" + String(repeating: "a", count: 113)).account, orgB, "128 is a key")
    }

    func testUnusablePinnedAccountMovesTheSession() {
        let pinB: [String: CCPoolState.Pin] = ["sess-example-1/": .init(account: orgB, seen: t0 - 10)]
        let rows: [(String, CCPoolState, Set<String>)] = [
            ("benched", pool(pins: pinB, benchB: true), []),
            ("not in order", pool(pins: pinB, order: [orgA]), []),
            ("tried (spent or no token)", pool(pins: pinB), [orgB]),
        ]
        for (why, st, exclude) in rows {
            let r = route(st, "sess-example-1/", exclude: exclude)
            XCTAssertEqual(r.account, orgA, why)
            XCTAssertEqual(accounts(r.state), ["sess-example-1/": orgA], "moved: \(why)")
            let q = route(st, "sess-example-1/", quota: true, exclude: exclude)
            XCTAssertEqual(q.account, orgA, why)
            XCTAssertEqual(accounts(q.state), ["sess-example-1/": orgB], "a quota check never moves a pin: \(why)")
        }
        var gone = pool(pins: pinB)
        gone.accounts.removeValue(forKey: orgB)
        XCTAssertEqual(route(gone, "sess-example-1/").account, orgA)
        let none = route(pool(pins: pinB), "sess-example-1/", exclude: [orgA, orgB])
        XCTAssertTrue(none.account == nil)
        XCTAssertEqual(accounts(none.state), ["sess-example-1/": orgB])
    }

    func testExpiredPinIsReplacedAndALookupLeavesExpiredPinsInPlace() {
        let st = pool(pins: ["sess-example-1/": .init(account: orgB, seen: t0 - 3601),
                             "sess-example-9/": .init(account: orgB, seen: t0 - 4000),
                             "sess-example-2/": .init(account: orgB, seen: t0 - 5)])
        let follow = route(st, "sess-example-2/")
        XCTAssertEqual(follow.account, orgB)
        XCTAssertEqual(follow.state, st, "a lookup alone changes nothing the file holds")
        let r = route(st, "sess-example-1/")
        XCTAssertEqual(r.account, orgA)
        XCTAssertEqual(accounts(r.state), ["sess-example-1/": orgA, "sess-example-2/": orgB], "a new pin drops the expired")
    }

    func testPinKeyFromHeaders() {
        func key(_ h: [(String, String)]) -> String? { CCPoolConnection.pinKey(CCPoolRequestHead(method: "POST", path: "/v1/messages", headers: h.map { (name: $0.0, value: $0.1) })) }
        XCTAssertEqual(key([("X-Claude-Code-Session-Id", "sess-example-1")]), "sess-example-1/")
        XCTAssertEqual(key([("x-claude-code-session-id", "sess-example-1"), ("X-CLAUDE-CODE-AGENT-ID", "agent-example-1")]),
                       "sess-example-1/agent-example-1")
        XCTAssertTrue(key([("x-claude-code-agent-id", "agent-example-1")]) == nil, "an agent without a session is no key")
        XCTAssertTrue(key([("x-claude-code-session-id", "")]) == nil)
        XCTAssertTrue(key([("x-claude-code-session-id", "sess example")]) == nil)
        XCTAssertTrue(key([("x-claude-code-session-id", "sess-\u{e9}")]) == nil)
        XCTAssertTrue(key([("x-claude-code-session-id", "sess-\u{7}")]) == nil)
        XCTAssertTrue(key([("x-claude-code-session-id", String(repeating: "s", count: 128))]) == nil, "129 with the slash")
        XCTAssertEqual(key([("x-claude-code-session-id", String(repeating: "s", count: 127))])?.count, 128)
        XCTAssertTrue(key([]) == nil)
    }

    // MARK: Through the stub upstream

    struct Rig {
        let up: PinUpstream
        let store: CCPoolStore
        let secrets: CCPoolMemorySecrets
        let log: ThrottleLog
        let rec: ThrottleWaitRecorder
        let seams: PinSeams
        let port: UInt16
        func post(_ sid: String?, _ agent: String? = nil, body: Data = throttleWork) -> CCPoolClientResponse? {
            var h = [("content-type", "application/json")]
            if let sid { h.append(("X-Claude-Code-Session-Id", sid)) }
            if let agent { h.append(("x-claude-code-agent-id", agent)) }
            return CCPoolTestClient.request(port: port, headers: h, body: body)
        }
        /// The token the request went with, when it was answered 200 and reached the upstream.
        func via(_ sid: String?, _ agent: String? = nil, body: Data = throttleWork) -> String? {
            let n = up.tokens.count
            guard post(sid, agent, body: body)?.status == 200, up.tokens.count > n else { return nil }
            return up.tokens.last
        }
        func setCurrent(_ label: String) { store.mutate { $0.current = label } }
    }

    private func rig() throws -> Rig {
        let rec = ThrottleWaitRecorder()
        let saved = CCPoolConnection.throttleWait
        CCPoolConnection.throttleWait = { s, q, go in rec.wait(s, q, go) }
        addTeardownBlock { CCPoolConnection.throttleWait = saved }
        let up = PinUpstream()
        let server = try CCPoolFakeServer { h, b in up.reply(h, b) }
        XCTAssertNotEqual(server.port, 0)
        let seams = PinSeams(now: Date().timeIntervalSince1970)
        let log = ThrottleLog()
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { seams.now }, logger: log,
                                writer: { d, u in seams.write(d, u) })
        let secrets = CCPoolMemorySecrets()
        for l in [orgA, orgB] { _ = try store.addAccount(label: l, token: throttleTokens[l] ?? "", secrets: secrets) }
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
        return Rig(up: up, store: store, secrets: secrets, log: log, rec: rec, seams: seams, port: p)
    }

    /// Two sessions pinned to different accounts, and `current` where the last pick put it (Example Org B).
    private func twoPinned() throws -> Rig {
        let r = try rig()
        XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        r.setCurrent(orgB)
        XCTAssertEqual(r.via("sess-example-2"), "tok-b")
        XCTAssertEqual(r.store.snapshot.current, orgB)
        XCTAssertEqual(r.store.snapshot.pins.mapValues(\.account), ["sess-example-1/": orgA, "sess-example-2/": orgB])
        return r
    }

    func testTwoConversationsKeepTheirAccountsAndCurrentStaysWhereThePickPutIt() throws {
        let r = try twoPinned()
        let w0 = r.seams.writes
        for round in 1...4 {
            XCTAssertEqual(r.via("sess-example-1"), "tok-a", "round \(round)")
            XCTAssertEqual(r.store.snapshot.current, orgB, "a reply that followed a pin does not move current: \(round)")
            XCTAssertEqual(r.via("sess-example-2"), "tok-b", "round \(round)")
            XCTAssertEqual(r.store.snapshot.current, orgB, "round \(round)")
        }
        XCTAssertEqual(r.via("sess-example-1", "agent-example-1"), "tok-a", "a subagent follows its session")
        XCTAssertEqual(r.store.snapshot.current, orgB)
        XCTAssertEqual(r.seams.writes, w0 + 1, "eight alternations write nothing; only the subagent's new pin is saved")
        XCTAssertEqual(r.rec.waits, [], "no wait")
    }

    func testRequestWithoutSessionIdGoesToCurrentNotToTheAccountThatAnsweredLast() throws {
        let r = try twoPinned()
        XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        XCTAssertEqual(r.via(nil), "tok-b", "current (the last pick), not the pinned account that answered last")
        XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        XCTAssertEqual(r.via(nil), "tok-b")
        XCTAssertEqual(r.store.snapshot.current, orgB)
    }

    func testMovedConversationsReplyDoesMoveCurrent() throws {
        let r = try rig()
        r.setCurrent(orgA)
        XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        let until = Int(r.seams.now) + 600
        r.store.mutate { $0.accounts[orgA]?.cooldown[CCPoolCore.fiveHour] = until }
        XCTAssertEqual(r.via("sess-example-1"), "tok-b", "the pinned account is benched: the session moves")
        XCTAssertEqual(r.store.snapshot.pins.mapValues(\.account), ["sess-example-1/": orgB])
        XCTAssertEqual(r.store.snapshot.current, orgB, "that reply came from pick: current moves with it")
    }

    func testRouteSaysWhetherAPinGaveTheAnswer() {
        let pinB: [String: CCPoolState.Pin] = ["sess-example-1/": .init(account: orgB, seen: t0 - 10)]
        XCTAssertTrue(route(pool(pins: pinB), "sess-example-1/").followed, "its own pin")
        XCTAssertTrue(route(pool(pins: pinB), "sess-example-1/", quota: true).followed, "a quota check that follows a pin")
        XCTAssertTrue(route(pool(pins: pinB), "sess-example-1/agent-example-1").followed, "the sibling's pin")
        XCTAssertFalse(route(pool(), "sess-example-1/").followed, "a new conversation")
        XCTAssertFalse(route(pool(pins: pinB, benchB: true), "sess-example-1/").followed, "a move")
        XCTAssertFalse(route(pool(pins: pinB), "sess-example-1/", exclude: [orgB]).followed, "a move (tried)")
        XCTAssertFalse(route(pool(pins: pinB), nil).followed, "no key")
        XCTAssertFalse(route(pool(pins: pinB), "sess example/").followed, "no usable key")
        XCTAssertFalse(route(pool(), "sess-example-1/", quota: true).followed, "a quota check without a usable pin")
        XCTAssertFalse(route(pool(pins: pinB, benchB: true), "sess-example-1/", quota: true).followed, "a quota check, pin unusable")
    }

    func testQuotaCheckNeverRevivesAnExpiredPinButARealRequestDoes() {
        let st = pool(pins: ["sess-example-1/": .init(account: orgA, seen: t0 - 3601)])
        let q = route(st, "sess-example-1/", quota: true)
        XCTAssertEqual(q.account, orgA)
        XCTAssertFalse(q.followed, "an expired pin is not followed")
        XCTAssertEqual(q.state, st, "a quota check changes nothing")
        XCTAssertEqual(q.state.pins["sess-example-1/"]?.seen, t0 - 3601, "not re-stamped")
        var after = q.state
        XCTAssertTrue(after.pinnedAccount("sess-example-1/", now: t0) == nil, "still expired")
        let real = route(st, "sess-example-1/")
        XCTAssertEqual(real.account, orgA)
        XCTAssertEqual(real.state.pins["sess-example-1/"]?.seen, t0, "a real request pins it again")
        var live = real.state
        XCTAssertEqual(live.pinnedAccount("sess-example-1/", now: t0), orgA)
        XCTAssertEqual(real.state, st, "the same account: the file content is the same, no write")
    }

    func testQuotaCheckCreatesNoPinAndFollowsAnExistingOne() throws {
        let r = try rig()
        let before = r.store.snapshot
        XCTAssertEqual(r.via("sess-example-1", body: throttleQuotaCheck), "tok-a")
        XCTAssertEqual(r.store.snapshot, before, "state compared before and after")
        XCTAssertTrue(r.store.snapshot.pins.isEmpty)
        r.store.mutate { $0.order = [orgB, orgA] }   // #1261: a new key is placed, ties by order (no longer `current`)
        XCTAssertEqual(r.via("sess-example-2"), "tok-b")
        r.setCurrent(orgA)
        XCTAssertEqual(r.via("sess-example-2", body: throttleQuotaCheck), "tok-b", "follows the pin")
        XCTAssertEqual(r.store.snapshot.pins.mapValues(\.account), ["sess-example-2/": orgB])
    }

    func testBadHeaderValueIsTreatedAsNoSessionIdAndNoValueIsLogged() throws {
        let r = try rig()
        r.store.mutate { $0.order = [orgB, orgA] }   // #1261: a new key is placed, ties by order (no longer `current`)
        XCTAssertEqual(r.via("sess-example-1", "agent-example-1"), "tok-b")
        r.setCurrent(orgA)
        let bad: [(String, String?)] = [("sess example-2", nil), (String(repeating: "s", count: 129), nil),
                                        ("sess-example-1", "agent example-1"),
                                        ("sess-example-1", String(repeating: "a", count: 114))]
        for (sid, agent) in bad {
            XCTAssertEqual(r.via(sid, agent), "tok-a", "follows current: \(sid.count) \(agent?.count ?? 0)")
        }
        // Non-ASCII values are not sent here: whether URLSession forwards such a header is not this entry's
        // question, and the pure rows testPinKeyFromHeaders and testBadAgentValueIsNoSessionIdEvenWhenTheSessionIsPinned
        // pin the rule (R1259-c).
        XCTAssertEqual(Set(r.store.snapshot.pins.keys), ["sess-example-1/agent-example-1"], "no bad value became a key")
        let lines = r.log.lines
        let leaked = lines.filter { l in ["sess-example", "sess example", "agent-example", "agent example", "aaaaaaaaaa",
                                          "ssssssssss"].contains { l.contains($0) } }
        XCTAssertEqual(leaked, [], "no header value in any log line")
    }

    func testThrottleRetryOfAPinnedRequestStaysOnItsAccount() throws {
        let r = try rig()
        r.store.mutate { $0.order = [orgB, orgA] }   // #1261: a new key is placed, ties by order (no longer `current`)
        XCTAssertEqual(r.via("sess-example-1"), "tok-b")
        r.setCurrent(orgA)
        r.up.set("tok-b", [.throttle(nil), .throttle("3")])
        XCTAssertEqual(r.via("sess-example-1"), "tok-b")
        XCTAssertEqual(r.up.tokens, ["tok-b", "tok-b", "tok-b", "tok-b"], "every retry on the pinned account")
        XCTAssertEqual(r.rec.waits, [1, 3])
        XCTAssertEqual(r.store.snapshot.pins.mapValues(\.account), ["sess-example-1/": orgB])
        // A spent 429 benches the account and moves the session (Python's spent move).
        r.up.set("tok-b", [.spent])
        XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        XCTAssertEqual(r.store.snapshot.pins.mapValues(\.account), ["sess-example-1/": orgA])
        XCTAssertEqual(r.rec.waits, [1, 3], "a spent rotation waits for nothing")
    }

    func testMissingTokenMovesTheSession() throws {
        let r = try rig()
        r.store.mutate { $0.order = [orgB, orgA] }   // #1261: a new key is placed, ties by order (no longer `current`)
        XCTAssertEqual(r.via("sess-example-1"), "tok-b")
        r.setCurrent(orgB)
        let id = try XCTUnwrap(r.store.snapshot.accounts[orgB]?.id)
        try r.secrets.remove(id: id)
        XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        XCTAssertEqual(r.store.snapshot.pins.mapValues(\.account), ["sess-example-1/": orgA])
    }

    func testTouchDoesNotWriteTheStateFileButANewPinDoes() throws {
        let r = try rig()
        let w0 = r.seams.writes
        XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        let w1 = r.seams.writes
        XCTAssertEqual(w1, w0 + 1, "a new pin is saved")
        let file = try Data(contentsOf: r.store.stateURL)
        let at = r.seams.now
        for step in 1...3 {
            r.seams.now = at + Double(step * 100)
            XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        }
        XCTAssertEqual(r.seams.writes, w1, "three touches, no write")
        XCTAssertEqual(try Data(contentsOf: r.store.stateURL), file)
        XCTAssertEqual(r.store.snapshot.pins["sess-example-1/"]?.seen, at + 300, "the touch is kept in memory")
        XCTAssertEqual(r.via("sess-example-2"), "tok-b", "#1261: placed by the score, orgA holds a live session")
        XCTAssertEqual(r.seams.writes, w1 + 2, "another new pin is saved, and current moves to the placed account")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: r.store.stateURL)) as? [String: Any]
        XCTAssertEqual(obj?["pins"] as? [String: String], ["sess-example-1/": orgA, "sess-example-2/": orgB])
    }

    // MARK: Removal and rename

    func testRemovingAnAccountDropsItsPinsAndARenameMovesThem() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        let t0 = self.t0
        let store = CCPoolStore(directory: dir, clock: { t0 }, logger: ThrottleLog())
        let secrets = CCPoolMemorySecrets()
        for l in [orgA, orgB] { _ = try store.addAccount(label: l, token: throttleTokens[l] ?? "", secrets: secrets) }
        store.mutate { st in
            _ = st.pin("sess-example-1/", to: orgA, now: t0)
            _ = st.pin("sess-example-2/", to: orgB, now: t0)
            _ = st.pin("sess-example-2/agent-example-1", to: orgB, now: t0)
        }
        try store.renameAccount(orgB, to: "Example Org C")
        XCTAssertEqual(store.snapshot.pins.mapValues(\.account),
                       ["sess-example-1/": orgA, "sess-example-2/": "Example Org C", "sess-example-2/agent-example-1": "Example Org C"])
        XCTAssertEqual(store.mutate { $0.pinnedAccount("sess-example-2/", now: t0) }, "Example Org C")
        XCTAssertEqual(CCPoolStore(directory: dir, clock: { t0 }, logger: ThrottleLog()).snapshot.pins.mapValues(\.account),
                       ["sess-example-1/": orgA, "sess-example-2/": "Example Org C", "sess-example-2/agent-example-1": "Example Org C"])
        try store.removeAccount(label: "Example Org C", secrets: secrets)
        XCTAssertEqual(store.snapshot.pins.mapValues(\.account), ["sess-example-1/": orgA])
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any]
        XCTAssertEqual(obj?["pins"] as? [String: String], ["sess-example-1/": orgA], "the file drops them too")
    }
}
