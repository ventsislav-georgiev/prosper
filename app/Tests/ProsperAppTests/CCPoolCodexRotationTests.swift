import XCTest
@testable import ProsperApp

// #2006 (design #2003, phase 3): Codex limits, claims, the 429 bench and rotation, pins, the usage tap and prices.
// A fake upstream on 127.0.0.1 port 0 answers per pool account (by the access token it sees); memory secrets, a
// temp-dir store on a fixed clock, fake credentials only. Nothing dials a real host.

/// Answers per account: the reply for the access token in the request's Authorization header.
final class CCPoolCodexAccountsFake: @unchecked Sendable {
    typealias Answer = (status: Int, headers: [(String, String)], body: Data)
    private let lock = NSLock()
    private var _heads: [CCPoolRequestHead] = []
    private var answers: [String: Answer] = [:]
    static let ok: Answer = (200, [("content-type", "application/json")], Data(#"{"ok":true}"#.utf8))

    var heads: [CCPoolRequestHead] { lock.withLock { _heads } }
    /// The access tokens the upstream saw, in order.
    var tokens: [String] { heads.map { ($0.header("authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "") } }
    func answer(_ token: String, _ a: Answer) { lock.withLock { answers[token] = a } }

    func reply(_ head: CCPoolRequestHead, _ data: Data) -> CCPoolFakeServer.Reply {
        lock.withLock {
            _heads.append(head)
            let token = (head.header("authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
            let a = answers[token] ?? Self.ok
            return .respond(a.status, a.headers, a.body)
        }
    }
}

final class CCPoolCodexRotationTests: XCTestCase {
    static let now = 1_800_000_000
    static func item(_ l: String) -> String { #"{"access_token":"at-example-\#(l)","account_id":"acct-example-\#(l)"}"# }
    static func token(_ l: String) -> String { "at-example-\(l)" }

    struct Rig {
        let up: CCPoolFakeServer
        let fake: CCPoolCodexAccountsFake
        let service: CCPoolService
        let store: CCPoolStore
        let log: CCPoolCapturingLogger
        var port: UInt16 {
            if case .running(let p) = service.status { return p }
            return 0
        }
        func codex(headers: [(String, String)] = [], body: String = #"{"model":"gpt-5-codex","stream":true}"#) -> CCPoolClientResponse? {
            CCPoolTestClient.request(port: port, method: "POST", path: "/codex/responses",
                                     headers: [("content-type", "application/json")] + headers, body: Data(body.utf8))
        }
        func cooldown(_ l: String) -> [String: Int] { store.read { $0.accounts[l]?.cooldown ?? [:] } }
        func rows() -> [[String: Any]] {
            service.usageRecord.flush()
            let files = (try? FileManager.default.contentsOfDirectory(at: store.usageDirectory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.lastPathComponent.hasPrefix("usage-") }
                .flatMap { (try? String(contentsOf: $0, encoding: .utf8))?.split(separator: "\n") ?? [] }
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }

    /// `claude`: Claude accounts by label; `codex`: Codex accounts by label, in this order.
    private func rig(claude: [String] = [], codex: [String] = ["a", "b"], replayCap: Int = 32 << 20) throws -> Rig {
        let fake = CCPoolCodexAccountsFake()
        let up = try CCPoolFakeServer { h, b in fake.reply(h, b) }
        XCTAssertNotEqual(up.port, 0)
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { Double(Self.now) })
        let secrets = CCPoolMemorySecrets()
        for l in claude { try store.addAccount(label: l, token: "tok-\(l)", secrets: secrets) }
        for l in codex {
            try store.addAccount(label: l, token: Self.item(l), secrets: secrets)
            store.mutate { $0.accounts[l]?.harness = CCPoolCodexHarness.id; $0.accounts[l]?.kind = CCPoolCodexHarness.chatgptKind }
        }
        let log = CCPoolCapturingLogger()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.replayCap = replayCap
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        cfg.codexUpstream = URL(string: "http://127.0.0.1:\(up.port)/backend-api/codex")!
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        let saved = CCPoolConnection.throttleWait
        CCPoolConnection.throttleWait = { _, q, go in q.async(execute: go) }
        addTeardownBlock { CCPoolConnection.throttleWait = saved; service.stop(); up.stop() }
        return Rig(up: up, fake: fake, service: service, store: store, log: log)
    }

    // MARK: 429 and rotation

    // A 429 whose body (a long message first, so the 200-byte snippet alone could not parse it) says
    // usage_limit_reached, with no limit headers: A is benched on both claims until resets_in_seconds, and the request
    // is replayed on B before the first byte; the client sees B's 200.
    func testUsageLimitReachedBodyBenchesAndReplaysOnTheNextAccount() throws {
        let r = try rig()
        let msg = String(repeating: "The usage limit has been reached. ", count: 10)
        r.fake.answer(Self.token("a"), (429, [("content-type", "application/json")],
                                        Data(#"{"error":{"message":"\#(msg)","type":"usage_limit_reached","resets_in_seconds":3600}}"#.utf8)))
        let resp = try XCTUnwrap(r.codex())
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertEqual(r.fake.tokens, [Self.token("a"), Self.token("b")], "one try on A, then B; never A again")
        XCTAssertEqual(r.cooldown("a"), ["five_hour": Self.now + 3600, "seven_day": Self.now + 3600])
        XCTAssertTrue(r.cooldown("b").isEmpty)
        let lines = r.log.lines
        XCTAssertTrue(lines.contains("a: out on five_hour,seven_day; rotating to another account and retrying request"), "\(lines)")
        XCTAssertFalse(r.log.publicLines.contains { $0.contains("The usage limit") }, "the body is never public: \(r.log.publicLines)")
    }

    // #2025 (QA R2006 n2): a spent 429 whose request body is above the replay cap cannot be replayed: A is benched and
    // the 429 passes through, and the exchange is logged ONCE (not by rotateSpentCodex and again by the throttle path).
    func testSpentAboveReplayCapLogsOneLine() throws {
        let r = try rig(replayCap: 64 << 10)
        r.fake.answer(Self.token("a"), (429, [("content-type", "application/json")],
                                        Data(#"{"error":{"type":"usage_limit_reached","resets_in_seconds":3600}}"#.utf8)))
        let big = #"{"model":"gpt-5-codex","stream":true,"pad":""# + String(repeating: "x", count: 70_000) + #""}"#
        XCTAssertEqual(r.codex(body: big)?.status, 429)
        XCTAssertEqual(r.fake.tokens, [Self.token("a")], "never replayed")
        XCTAssertEqual(r.cooldown("a")["five_hour"], Self.now + 3600, "still benched")
        let mine = r.log.lines.filter { $0.hasPrefix("a: ") && ($0.contains("usage limit reached") || $0.contains("out on") || $0.contains("outcome=")) }
        XCTAssertEqual(mine.count, 1, "\(r.log.lines)")
    }

    // #2025 (QA R2006 n1): every Codex account benched: Codex's answer is usage_limit_reached with the pool's next Codex
    // reset (resets_at, resets_in_seconds, Retry-After), never Claude's rate_limit_error; nothing is sent upstream.
    func testAllBenchedAnswersCodexUsageLimitReached() throws {
        let r = try rig()
        r.store.mutate { st in
            st.accounts["a"]?.cooldown = ["five_hour": Self.now + 600, "seven_day": Self.now + 900]
            st.accounts["b"]?.cooldown = ["five_hour": Self.now + 700, "seven_day": Self.now + 800]
        }
        let resp = try XCTUnwrap(r.codex())
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertFalse(resp.text.contains("rate_limit_error"), resp.text)
        let err = try XCTUnwrap(((try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any])?["error"] as? [String: Any])
        XCTAssertEqual(err["type"] as? String, "usage_limit_reached")
        XCTAssertEqual(err["resets_at"] as? Int, Self.now + 800)
        XCTAssertEqual(err["resets_in_seconds"] as? Int, 800)
        XCTAssertTrue((err["message"] as? String)?.isEmpty == false)
        XCTAssertEqual(resp.headers.first { $0.0.lowercased() == "retry-after" }?.1, "800")
        XCTAssertEqual(r.fake.heads.count, 0)
    }

    // #2025 (QA R2006 n1), Claude's half: the same state on a Claude request keeps Claude's rate_limit_error answer.
    func testAllBenchedClaudeAnswerIsUnchanged() throws {
        let r = try rig(claude: ["c"], codex: [])
        let until = Self.now + 600
        r.store.mutate { st in st.accounts["c"]?.cooldown = Dictionary(uniqueKeysWithValues: ClaudeHarness().claims(for: "claude-opus-5").map { ($0, until) }) }
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertTrue(resp.text.contains("rate_limit_error") && resp.text.contains("all pooled accounts are rate limited"), resp.text)
        XCTAssertFalse(resp.text.contains("usage_limit_reached"), resp.text)
    }

    // QA #2005 n1, second half: a 429 whose headers show the default window spent (used 100%) is never retried on the
    // same account: A is benched until the header reset and B serves.
    func testSpentHeadersNeverRetryTheSameAccount() throws {
        let r = try rig()
        r.fake.answer(Self.token("a"), (429, [("content-type", "application/json"), ("retry-after", "0"),
                                              ("x-codex-primary-used-percent", "100"), ("x-codex-primary-window-minutes", "300"),
                                              ("x-codex-primary-reset-at", "\(Self.now + 1000)")], Data("{}".utf8)))
        XCTAssertEqual(r.codex()?.status, 200)
        XCTAssertEqual(r.fake.tokens, [Self.token("a"), Self.token("b")])
        XCTAssertEqual(r.cooldown("a")["five_hour"], Self.now + 1000)
    }

    // QA #2005 n1, first half: a long Retry-After with nothing spent benches a claim selection reads (seven_day is a
    // Codex claim), so A is no longer eligible and the next request goes to B without trying A.
    func testLongRetryAfterCooldownIsReadBySelection() throws {
        let r = try rig()
        r.fake.answer(Self.token("a"), (429, [("content-type", "application/json"), ("retry-after", "7200")], Data("{}".utf8)))
        XCTAssertEqual(r.codex()?.status, 200)
        XCTAssertEqual(r.cooldown("a")["seven_day"], Self.now + 7200)
        let st = r.store.read { $0 }
        XCTAssertFalse(CCPoolCore.eligible(st.accounts["a"], model: "gpt-5-codex", now: Double(Self.now), harness: CCPoolCodexHarness()))
        XCTAssertEqual(CCPoolCore.nextReset(st, model: "gpt-5-codex", now: Double(Self.now), harness: CCPoolCodexHarness()), Self.now + 7200)
        r.store.mutate { $0.currents[CCPoolCodexHarness.id] = "a" }   // even as current, A is skipped
        XCTAssertEqual(r.codex()?.status, 200)
        XCTAssertEqual(r.fake.tokens, [Self.token("a"), Self.token("b"), Self.token("b")])
    }

    // A 429 with nothing spent is a throttle: the same-account backoff (3 retries), B is never tried without a pin key,
    // nothing is benched. Another limit id's window at 100% is recorded, never benched.
    func testThrottleStaysOnItsAccountAndAnotherLimitIdNeverBenches() throws {
        let r = try rig()
        r.fake.answer(Self.token("a"), (429, [("content-type", "application/json"), ("retry-after", "0"),
                                              ("x-other-primary-used-percent", "100"), ("x-other-primary-window-minutes", "300")],
                                        Data(#"{"error":{"type":"rate_limit_exceeded"}}"#.utf8)))
        XCTAssertEqual(r.codex()?.status, 429)
        XCTAssertEqual(r.fake.tokens, Array(repeating: Self.token("a"), count: 1 + CCPoolCore.throttleBackoff.count))
        XCTAssertTrue(r.cooldown("a").isEmpty, "\(r.cooldown("a"))")
        XCTAssertEqual(r.store.usageSample("a")?.util["other.five_hour"], 1)
    }

    // MARK: pins

    // A conversation (session_id) stays on the account it was placed on, even when another account is made current;
    // x-codex-turn-state is relayed untouched both ways.
    func testPinHoldsAcrossRequests() throws {
        let r = try rig()
        r.fake.answer(Self.token("a"), (200, [("content-type", "application/json"), ("x-codex-turn-state", "ts-back")], Data("{}".utf8)))
        r.fake.answer(Self.token("b"), (200, [("content-type", "application/json"), ("x-codex-turn-state", "ts-back")], Data("{}".utf8)))
        let hs = [("session_id", "sess-example-1"), ("x-codex-turn-state", "ts-out")]
        let first = try XCTUnwrap(r.codex(headers: hs))
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.header("x-codex-turn-state"), "ts-back")
        XCTAssertEqual(r.fake.heads.last?.header("x-codex-turn-state"), "ts-out")
        let home = try XCTUnwrap(r.fake.tokens.last)
        let homeLabel = home == Self.token("a") ? "a" : "b", other = homeLabel == "a" ? "b" : "a"
        XCTAssertEqual(r.store.read { $0.pins["codex/sess-example-1"]?.account }, homeLabel)
        for _ in 0..<3 {
            r.store.mutate { $0.currents[CCPoolCodexHarness.id] = other }
            XCTAssertEqual(r.codex(headers: hs)?.status, 200)
        }
        XCTAssertEqual(r.fake.tokens, Array(repeating: home, count: 4))
        XCTAssertFalse(r.log.lines.contains { $0.contains("sess-example-1") }, "the session id is never logged")
    }

    // MARK: usage rows

    // Each served Codex request writes one usage row with its account's Keychain id, the model word and the tap's
    // counts; no session id is written.
    func testUsageRowsAreRecordedPerAccount() throws {
        let r = try rig()
        let usage = Data(#"{"id":"resp_1","usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":40},"output_tokens":7}}"#.utf8)
        for l in ["a", "b"] { r.fake.answer(Self.token(l), (200, [("content-type", "application/json")], usage)) }
        r.store.mutate { $0.currents[CCPoolCodexHarness.id] = "a" }
        XCTAssertEqual(r.codex(body: #"{"model":"gpt-5-codex"}"#)?.status, 200)
        r.store.mutate { $0.currents[CCPoolCodexHarness.id] = "b"; $0.hold("a", hours: 1, now: Double(Self.now)) }
        XCTAssertEqual(r.codex(body: #"{"model":"gpt-5-codex"}"#)?.status, 200)
        let ids = r.store.read { st in ["a", "b"].map { st.accounts[$0]?.id ?? "" } }
        let rows = r.rows()
        XCTAssertEqual(rows.compactMap { $0["acct"] as? String }, ids, "\(rows)")
        for row in rows {
            XCTAssertEqual(row["model"] as? String, "gpt-5-codex")
            XCTAssertEqual(row["in"] as? Int, 60)
            XCTAssertEqual(row["cr"] as? Int, 40)
            XCTAssertEqual(row["out"] as? Int, 7)
            XCTAssertEqual(row["cw5"] as? Int, 0)
            XCTAssertTrue(row["sess"] == nil)
        }
    }

    // MARK: harness filters with two harnesses (QA #2004 n2)

    // lastResort counts this harness's accounts only: with the one Codex account refused and an untried Claude account
    // beside it, the Codex request still takes the refused Codex token as its last resort.
    func testLastResortCountsOnlyThisHarnessAccounts() throws {
        let r = try rig(claude: ["one"], codex: ["a"])
        r.store.mutate { $0.accounts["a"]?.refused = Self.now - 10 }
        XCTAssertEqual(r.codex()?.status, 200)
        XCTAssertEqual(r.fake.tokens, [Self.token("a")])
        XCTAssertTrue(r.log.lines.contains("a: no other account is routable; trying a rejected token"), "\(r.log.lines)")
    }

    // nextReset reads this harness's accounts only: the Claude account's earlier five_hour cooldown is not Codex's.
    func testNextResetReadsOnlyThisHarnessAccounts() {
        let st = CCPoolState(order: ["one", "a"], accounts: [
            "one": .init(id: "id-one", cooldown: ["five_hour": Self.now + 100]),
            "a": .init(id: "id-a", cooldown: ["five_hour": Self.now + 500], harness: CCPoolCodexHarness.id, kind: CCPoolCodexHarness.chatgptKind),
        ])
        XCTAssertEqual(CCPoolCore.nextReset(st, model: "gpt-5-codex", now: Double(Self.now), harness: CCPoolCodexHarness()), Self.now + 500)
        XCTAssertEqual(CCPoolCore.nextReset(st, model: "claude-opus-5", now: Double(Self.now)), Self.now + 100)
    }

    // The usage refresh probes this harness's accounts only: Codex's (no probe yet) lists its own account, never Claude's.
    func testUsageRefreshListsOnlyThisHarnessAccounts() async throws {
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { Double(Self.now) })
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "one", token: "tok-one", secrets: secrets)
        try store.addAccount(label: "a", token: Self.item("a"), secrets: secrets)
        store.mutate { $0.accounts["a"]?.harness = CCPoolCodexHarness.id; $0.accounts["a"]?.kind = CCPoolCodexHarness.chatgptKind }
        let report = await CCPoolUsage.refresh(store: store, secrets: secrets, base: URL(string: "http://127.0.0.1:9")!,
                                               logger: CCPoolCapturingLogger(), harness: CCPoolCodexHarness())
        XCTAssertEqual(report.rows.map(\.label), ["a"])
    }
}

/// The pure parts: the header parser (with malformed values), claims and names, the 429 spent check, the pin key,
/// the usage tap and the price table.
final class CCPoolCodexLimitsTests: XCTestCase {
    let now = 1_800_000_000.0
    func parse(_ h: [String: String]) -> (limits: [String: CCPoolLimit], unknown: [String]) {
        CCPoolCodexHarness.parseLimits(h, now: now)
    }

    func testParserTable() {
        typealias L = CCPoolLimit
        let rows: [(String, [String: String], [String: L], [String])] = [
            ("primary 5h", ["x-codex-primary-used-percent": "42.5", "x-codex-primary-window-minutes": "300",
                            "x-codex-primary-reset-at": "1800003600"],
             ["five_hour": L(status: "allowed", utilization: "0.425", reset: "1800003600")], []),
            ("secondary week spent", ["X-Codex-Secondary-Used-Percent": "100", "x-codex-secondary-window-minutes": "10080",
                                      "x-codex-secondary-reset-at": "1800500000"],
             ["seven_day": L(status: "rejected", utilization: "1.0", reset: "1800500000")], []),
            ("weekly primary, no secondary", ["x-codex-primary-used-percent": "10", "x-codex-primary-window-minutes": "10080"],
             ["seven_day": L(status: "allowed", utilization: "0.1", reset: nil)], []),
            ("other window", ["x-codex-primary-used-percent": "0", "x-codex-primary-window-minutes": "1440"],
             ["window_1440m": L(status: "allowed", utilization: "0.0", reset: nil)], []),
            ("reset-after-seconds", ["x-codex-primary-window-minutes": "300", "x-codex-primary-reset-after-seconds": "60"],
             ["five_hour": L(status: nil, utilization: nil, reset: "1800000060")], []),
            ("reset-at wins", ["x-codex-primary-window-minutes": "300", "x-codex-primary-reset-after-seconds": "60",
                               "x-codex-primary-reset-at": "1800000999"],
             ["five_hour": L(status: nil, utilization: nil, reset: "1800000999")], []),
            ("bad percent dropped", ["x-codex-primary-used-percent": "abc", "x-codex-primary-window-minutes": "300"],
             ["five_hour": L()], []),
            ("nan/inf/negative dropped", ["x-codex-primary-used-percent": "nan", "x-codex-primary-window-minutes": "300",
                                          "x-codex-primary-reset-at": "-5", "x-codex-secondary-used-percent": "inf",
                                          "x-codex-secondary-window-minutes": "10080", "x-codex-secondary-reset-after-seconds": "1e300"],
             ["five_hour": L(), "seven_day": L()], []),
            ("bad windows are unknown", ["x-codex-primary-used-percent": "50", "x-codex-primary-window-minutes": "x",
                                         "x-codex-secondary-used-percent": "50", "x-codex-secondary-window-minutes": "300.5"],
             [:], ["codex-primary", "codex-secondary"]),
            ("no window at all", ["x-codex-primary-used-percent": "50"], [:], ["codex-primary"]),
            ("zero or huge window", ["x-codex-primary-window-minutes": "0", "x-codex-secondary-window-minutes": "1e9"],
             [:], ["codex-primary", "codex-secondary"]),
            ("another limit id", ["x-other-primary-used-percent": "100", "x-other-primary-window-minutes": "300"],
             ["other.five_hour": L(status: "rejected", utilization: "1.0", reset: nil)], []),
            ("ignored headers", ["x-codex-credits-balance": "5", "x-codex-credits-has-credits": "true",
                                 "x-codex-rate-limit-reached-type": "primary", "x-codex-active-limit": "codex",
                                 "x-codex-primary-over-secondary-limit-percent": "3", "anthropic-ratelimit-unified-5h-status": "rejected",
                                 "x--primary-used-percent": "1"], [:], []),
        ]
        for (name, headers, limits, unknown) in rows {
            let got = parse(headers)
            XCTAssertEqual(got.limits, limits, name)
            XCTAssertEqual(got.unknown, unknown, name)
        }
        // #2025 (QA R2006 n4): two slots on one window at equal use: the later reset, then the first slot name, whatever the
        // swap of the two slots (Dictionary order is not stable); a fuller slot still beats a later reset.
        func slots(_ p: (String, String), _ q: (String, String), first: Bool) -> [String: CCPoolLimit] {
            let a: [(String, String)] = [("x-codex-primary-used-percent", p.0), ("x-codex-primary-window-minutes", "300"), ("x-codex-primary-reset-at", p.1),
                                         ("x-codex-secondary-used-percent", q.0), ("x-codex-secondary-window-minutes", "300"), ("x-codex-secondary-reset-at", q.1)]
            return parse(Dictionary(uniqueKeysWithValues: first ? a : a.reversed())).limits
        }
        for first in [true, false] {
            XCTAssertEqual(slots(("50", "1800001000"), ("50", "1800002000"), first: first)["five_hour"]?.reset, "1800002000", "later reset wins")
            XCTAssertEqual(slots(("50", "1800002000"), ("50", "1800001000"), first: first)["five_hour"]?.reset, "1800002000", "later reset wins")
            XCTAssertEqual(slots(("50", "1800001000"), ("60", "1800000500"), first: first)["five_hour"]?.utilization, "0.6", "fuller wins")
            XCTAssertEqual(slots(("50", "1800001000"), ("50", "1800001000"), first: first)["five_hour"], L(status: "allowed", utilization: "0.5", reset: "1800001000"))
        }
        XCTAssertEqual(Array(CCPoolCodexHarness.benchable(parse(rows.last(where: { $0.0 == "another limit id" })!.1).limits).keys), [])
    }

    func testClaimsAndNames() {
        let h = CCPoolCodexHarness()
        XCTAssertEqual(h.claims(for: "gpt-5-codex"), ["five_hour", "seven_day"])
        XCTAssertEqual(h.claims(for: nil), ["five_hour", "seven_day"])
        XCTAssertTrue(h.isKnownModel("gpt-5"))
        XCTAssertFalse(h.isKnownModel(""))
        XCTAssertFalse(h.isKnownModel(nil))
        XCTAssertEqual(h.displayOrder, ["five_hour", "seven_day"])
        XCTAssertEqual(h.display, ["five_hour": "5h", "seven_day": "week"])
        for (claim, word) in [("five_hour", "5h"), ("seven_day", "week"), ("window_1440m", "1d"), ("window_120m", "2h"),
                              ("window_90m", "90m"), ("window_xm", "window_xm"), ("other.five_hour", "other.5h"),
                              ("other.window_2880m", "other.2d")] {
            XCTAssertEqual(CCPoolCodexHarness.displayName(claim), word, claim)
        }
        XCTAssertFalse(h.isQuotaCheck(["max_tokens": 1]))
    }

    func testSpent429() {
        func spent(_ body: String, _ headers: [String: String] = [:]) -> (spent: Bool, reset: Int?) {
            CCPoolCodexHarness.spent429(headers: headers, body: Data(body.utf8), now: now)
        }
        XCTAssertTrue(spent(#"{"error":{"type":"usage_limit_reached","resets_at":1800009999}}"#) == (true, 1_800_009_999))
        XCTAssertTrue(spent(#"{"error":{"type":"usage_limit_reached","resets_in_seconds":60}}"#) == (true, 1_800_000_060))
        XCTAssertTrue(spent(#"{"error":{"type":"usage_limit_reached","resets_at":"abc","resets_in_seconds":1e300}}"#) == (true, nil))
        XCTAssertTrue(spent(#"{"error":{"type":"usage_limit_reached","resets_at":true}}"#) == (true, nil))
        XCTAssertTrue(spent("{}", ["x-codex-rate-limit-reached-type": "primary", "x-codex-primary-used-percent": "99",
                                   "x-codex-primary-window-minutes": "300", "x-codex-primary-reset-at": "1800001234",
                                   "x-codex-secondary-used-percent": "20", "x-codex-secondary-window-minutes": "10080",
                                   "x-codex-secondary-reset-at": "1800500000"]) == (true, 1_800_001_234))
        XCTAssertTrue(spent("{}", ["x-codex-rate-limit-reached-type": " "]) == (false, nil))
        XCTAssertTrue(spent(#"{"error":{"type":"rate_limit_exceeded","resets_at":1800009999}}"#) == (false, nil))
        XCTAssertTrue(spent(#"{"error":{"type":"usage_limit_reached""#) == (false, nil), "a cut body is not read")
        XCTAssertTrue(spent("not json") == (false, nil))
        let big = #"{"error":{"type":"usage_limit_reached","pad":""# + String(repeating: "x", count: 5000) + #""}}"#
        XCTAssertTrue(spent(big) == (false, nil), "only the first 4 KiB are read")
    }

    func testPinKey() {
        let h = CCPoolCodexHarness()
        func key(_ hs: [(String, String)]) -> String? {
            h.pinKey(CCPoolRequestHead(method: "POST", path: "/codex/responses", headers: hs.map { (name: $0.0, value: $0.1) }))
        }
        XCTAssertEqual(key([("session_id", "s1")]), "codex/s1")
        XCTAssertEqual(key([("Session_Id", "s1"), ("conversation_id", "c1")]), "codex/s1")
        XCTAssertEqual(key([("conversation_id", "c1")]), "codex/c1")
        XCTAssertEqual(key([("session_id", ""), ("conversation_id", "c1")]), "codex/c1")
        XCTAssertTrue(key([("session_id", "has space")]) == nil)
        XCTAssertTrue(key([("session_id", String(repeating: "s", count: 128))]) == nil, "the whole key is at most 128")
        XCTAssertTrue(key([("x-codex-turn-state", "t1")]) == nil, "the turn state is never a key")
        XCTAssertTrue(key([]) == nil)
    }

    func testTapCountsOnlyAfterCompleted() {
        let h = CCPoolCodexHarness()
        let usage = #"{"input_tokens":100,"input_tokens_details":{"cached_tokens":40},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":3}}"#
        let head = "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"usage\":null}}\n\n"
            + "event: response.in_progress\ndata: {\"type\":\"response.in_progress\",\"response\":{\"usage\":\(usage)}}\n\n"
            + "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n"
        let done = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":\(usage)}}\n\n"
        var cut = h.usageTap(contentType: "text/event-stream")
        cut.feed(Data(head.utf8))
        XCTAssertTrue(cut.result() == nil, "no completed event: nothing counts")
        var half = cut
        half.feed(Data(done.prefix(60).utf8))
        XCTAssertTrue(half.result() == nil, "a cut completed line counts nothing")
        var whole = cut
        for b in Data(done.utf8) { whole.feed(Data([b])) }   // split at every byte
        XCTAssertEqual(whole.result(), CCPoolTokenUsage(input: 60, output: 7, cacheRead: 40))
        var json = h.usageTap(contentType: "application/json")
        json.feed(Data(#"{"id":"resp_1","usage":\#(usage)}"#.utf8))
        XCTAssertEqual(json.result(), CCPoolTokenUsage(input: 60, output: 7, cacheRead: 40))
        for bad in [#"{"usage":{"input_tokens":"5","output_tokens":1}}"#, #"{"usage":{"input_tokens":5}}"#,
                    #"{"usage":{"input_tokens":5,"output_tokens":1,"input_tokens_details":{"cached_tokens":6}}}"#,
                    #"{"usage":{"input_tokens":-1,"output_tokens":1}}"#, #"{"usage":{"input_tokens":true,"output_tokens":1}}"#,
                    #"{"usage":{"input_tokens":5,"output_tokens":1,"input_tokens_details":{"cached_tokens":"x"}}}"#,
                    #"{"usage":null}"#, #"{"ok":true}"#, "not json"] {
            var t = h.usageTap(contentType: "application/json")
            t.feed(Data(bad.utf8))
            XCTAssertTrue(t.result() == nil, bad)
        }
        var noCache = h.usageTap(contentType: "application/json")
        noCache.feed(Data(#"{"usage":{"input_tokens":5,"output_tokens":1,"input_tokens_details":null}}"#.utf8))
        XCTAssertEqual(noCache.result(), CCPoolTokenUsage(input: 5, output: 1))
        // Claude's tap is unchanged by the Codex mode: an Anthropic stream still needs its message_stop.
        var claude = ClaudeHarness().usageTap(contentType: "text/event-stream")
        claude.feed(Data(done.utf8))
        XCTAssertTrue(claude.result() == nil)
    }

    func testPrices() {
        let u = CCPoolTokenUsage(input: 1e6, output: 1e6, cacheRead: 1e6)
        let t = CCPoolCodexHarness.prices
        XCTAssertEqual(CCPoolCapacity.dollars(model: "gpt-5-codex", usage: u, table: t)!, 1.25 + 10 + 0.125, accuracy: 1e-9)
        XCTAssertEqual(CCPoolCapacity.dollars(model: "gpt-5-mini", usage: u, table: t)!, 0.25 + 2 + 0.025, accuracy: 1e-9)
        XCTAssertEqual(CCPoolCapacity.dollars(model: "codex-mini-latest", usage: u, table: t)!, 1.5 + 6 + 0.375, accuracy: 1e-9)
        XCTAssertEqual(CCPoolCapacity.dollars(model: "o9-unknown", usage: u, table: t)!, 1.25 + 10 + 0.125, accuracy: 1e-9,
                       "an unknown model takes the last row")
        XCTAssertEqual(CCPoolCapacity.dollars(model: nil, usage: u)!, 4 + 20 + 0.2, accuracy: 1e-9, "Claude's default is opus")
        XCTAssertTrue(CCPoolCapacity.dollars(model: "gpt-5", usage: u, table: []) == nil)
    }
}
