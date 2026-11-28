import Foundation
import XCTest
@testable import ProsperApp

/// #2004: the harness seam. ClaudeHarness holds the values the pool used before it (pinned here as literals), the
/// old names forward to it, and a Claude-only state.json is written byte for byte as before `harness`, `kind` and the
/// per-harness `current` existed. Temp dirs only; nothing is dialled.
final class AgentPoolHarnessTests: XCTestCase {
    // MARK: state.json round trip

    /// Fixtures from AgentPoolCapacityPersistTests (stateText, goodRow), AgentPoolCarryTests (held) and a refused account
    /// (#1278), written with sorted keys as the store writes them.
    private let fixtures = [
        #"{"accounts":{"Example Org A":{"cooldown":{},"id":"id-example-a","reset":{}},"#
            + #""Example Org B":{"cooldown":{},"id":"id-example-b","reset":{}}},"#
            + #""current":"Example Org B","order":["Example Org B","Example Org A"],"pins":{"sess-example-1/main":"Example Org A"}}"#,
        #"{"accounts":{"Example Org A":{"cooldown":{},"id":"id-example-a","reset":{}},"#
            + #""Example Org B":{"cooldown":{},"id":"id-example-b","reset":{}}},"#
            + #""capacity":{"id-example-a":{"dollars":2,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":1900000000}},"#
            + #""current":"Example Org B","order":["Example Org B","Example Org A"],"pins":{"sess-example-1/main":"Example Org A"}}"#,
        #"{"accounts":{"Example Org A":{"cooldown":{"five_hour":1800003600},"held":1800003600,"id":"id-a","reset":{"seven_day":1800500000}},"#
            + #""Example Org B":{"cooldown":{},"id":"id-b","refused":1799999000,"reset":{}}},"order":["Example Org A","Example Org B"]}"#,
    ]

    private func encoded(_ st: AgentPoolState) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(st), as: UTF8.self)
    }

    func testOldStateFixturesRoundTripByteIdentical() throws {
        for text in fixtures {
            let st = try JSONDecoder().decode(AgentPoolState.self, from: Data(text.utf8))
            XCTAssertTrue(st.accounts.values.allSatisfy { $0.harness == "claude" && $0.kind == nil }, text)
            XCTAssertEqual(try encoded(st), text)
        }
    }

    /// The store's own write (its encoder is unchanged by #2004) of a loaded old file holds the same JSON, no new key.
    func testStoreRewriteOfAnOldFileAddsNoKey() throws {
        for (i, text) in fixtures.enumerated() {
            let dir = tempDir("harness-\(i)")
            try Data(text.utf8).write(to: dir.appendingPathComponent("state.json"))
            let store = AgentPoolStore(directory: dir, clock: { 1_800_000_000 })
            store.mutate { $0.order.reverse() }
            store.mutate { $0.order.reverse() }   // back to the loaded state: this write is the plain rewrite
            let data = try Data(contentsOf: store.stateURL)
            let written = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
            let old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
            XCTAssertEqual(written, old, text)
            let file = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(file.contains("\"harness\"") || file.contains("\"kind\"") || file.contains("\"currents\""), file)
        }
    }

    func testLegacyCurrentIsClaudesAndEncodesBackTheSameWay() throws {
        let st = try JSONDecoder().decode(AgentPoolState.self, from: Data(fixtures[0].utf8))
        XCTAssertEqual(st.currents, ["claude": "Example Org B"])
        XCTAssertEqual(st.current, "Example Org B")
        var none = st
        none.current = nil
        XCTAssertTrue(none.currents.isEmpty)
        XCTAssertFalse(try encoded(none).contains("\"current\""), "no current: no key, as before")
    }

    func testANonClaudeAccountKeepsItsHarnessAndKind() throws {
        var st = AgentPoolState(order: ["a"], accounts: ["a": .init(id: "id-a", harness: "other", kind: "example-kind")])
        let text = try encoded(st)
        XCTAssertTrue(text.contains(#""harness":"other""#) && text.contains(#""kind":"example-kind""#), text)
        let back = try JSONDecoder().decode(AgentPoolState.self, from: Data(text.utf8))
        XCTAssertEqual(back.accounts["a"]?.harness, "other")
        XCTAssertEqual(back.accounts["a"]?.kind, "example-kind")
        st.remember("a")
        XCTAssertTrue(st.current == nil, "another harness's account never becomes Claude's current")
        XCTAssertEqual(st.currents, ["other": "a"])
    }

    /// Claude routing never picks or places an account of another harness, nor follows a pin to one.
    func testClaudeRoutingSkipsAnotherHarnessAccounts() {
        var st = AgentPoolState(order: ["a", "b"], accounts: ["a": .init(id: "id-a", harness: "other"), "b": .init(id: "id-b")])
        st.currents["other"] = "a"
        XCTAssertEqual(AgentPoolCore.pick(st, model: nil, exclude: [], now: 1000), "b")
        XCTAssertEqual(AgentPoolCore.place(st, model: nil, exclude: [], now: 1000), "b")
        st.pins["sess-1/"] = AgentPoolState.Pin(account: "a", seen: 1000)
        let r = AgentPoolCore.route(st, key: "sess-1/", quotaCheck: false, model: nil, exclude: [], now: 1000)
        XCTAssertEqual(r.account, "b")
        XCTAssertFalse(r.followed)
        st.accounts["b"] = nil
        st.order = ["a"]
        XCTAssertTrue(AgentPoolCore.pick(st, model: nil, exclude: [], now: 1000) == nil)
    }

    // MARK: ClaudeHarness returns today's values

    func testClaudeHarnessHoldsTodaysValues() {
        let h: any PoolHarness = ClaudeHarness()
        XCTAssertEqual(h.id, "claude")
        XCTAssertEqual(h.upstream.absoluteString, "https://api.anthropic.com")
        XCTAssertEqual(AgentPoolService.productionUpstream, h.upstream)
        XCTAssertEqual(h.stripRequest, ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                                        "te", "trailers", "trailer", "proxy-connection", "transfer-encoding", "upgrade", "host",
                                        "authorization", "x-api-key", "content-length", "expect", "accept-encoding"])
        XCTAssertEqual(AgentPoolConnection.stripRequest, h.stripRequest)
        XCTAssertEqual(h.claims(for: "claude-opus-5"), ["five_hour", "seven_day", "seven_day_opus"])
        XCTAssertEqual(h.claims(for: "claude-fable-5"), ["five_hour", "seven_day", "seven_day_overage_included"])
        XCTAssertEqual(h.claims(for: "claude-sonnet-4-5"), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(h.claims(for: "claude-haiku-4-5"), ["five_hour", "seven_day"])
        XCTAssertEqual(h.claims(for: nil), ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included"])
        XCTAssertTrue(h.isKnownModel("claude-haiku-4-5"))
        XCTAssertFalse(h.isKnownModel("mystery-model"))
        XCTAssertEqual(h.displayOrder, ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included"])
        XCTAssertEqual(h.display, ["five_hour": "5h", "seven_day": "week", "seven_day_opus": "opus",
                                   "seven_day_sonnet": "sonnet", "seven_day_overage_included": "fable"])
        XCTAssertEqual(AgentPoolCore.displayOrder, h.displayOrder)
        XCTAssertEqual(AgentPoolCore.display, h.display)
        XCTAssertEqual(h.prices.map(\.family), ["fable", "mythos", "opus", "sonnet", "haiku"])
        XCTAssertEqual(h.prices.map { [$0.input, $0.output, $0.read] },
                       [[8, 40, 0.2], [8, 40, 0.2], [4, 20, 0.2], [2, 10, 0.1], [0.1, 0.5, 0.01]])
        XCTAssertEqual(AgentPoolCapacity.prices.map(\.family), h.prices.map(\.family))
        XCTAssertEqual(h.env.key, "ANTHROPIC_BASE_URL")
        XCTAssertEqual(h.env.programs, ["claude"])
        XCTAssertEqual(AgentPool.baseURLKey, h.env.key)
        XCTAssertEqual(AgentPoolUsage.probeModel, "claude-haiku-4-5-20251001")
        XCTAssertTrue(h.isQuotaCheck(["max_tokens": 1]))
        XCTAssertFalse(h.isQuotaCheck(["max_tokens": 1.0]))
        XCTAssertFalse(h.isQuotaCheck(["max_tokens": true]))
        XCTAssertTrue(h.usageTap(contentType: "text/event-stream").stream)
        XCTAssertFalse(h.usageTap(contentType: "application/json").stream)
    }

    func testClaudeHarnessParsesTheUnifiedHeaders() {
        let h: any PoolHarness = ClaudeHarness()
        let r = h.parseLimits(["Anthropic-Ratelimit-Unified-5h-Utilization": "0.5", "anthropic-ratelimit-unified-7d-status": "allowed",
                               "anthropic-ratelimit-unified-7d-opus-reset": "1800000000",
                               "anthropic-ratelimit-unified-overage-status": "rejected", "anthropic-ratelimit-unified-9x-status": "ok"])
        XCTAssertEqual(r.limits, ["five_hour": AgentPoolLimit(utilization: "0.5"), "seven_day": AgentPoolLimit(status: "allowed"),
                                  "seven_day_opus": AgentPoolLimit(reset: "1800000000")])
        XCTAssertEqual(r.unknown, ["9x"])
        XCTAssertEqual(AgentPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.5"]).limits, ["five_hour": AgentPoolLimit(utilization: "0.5")])
    }

    func testClaudeHarnessPinKeyAndAuthorize() {
        let h: any PoolHarness = ClaudeHarness()
        let head = AgentPoolRequestHead(method: "POST", path: "/v1/messages",
                                     headers: [(name: "X-Claude-Code-Session-Id", value: "sess-1"), (name: "x-claude-code-agent-id", value: "ag")])
        XCTAssertEqual(h.pinKey(head), "sess-1/ag")
        XCTAssertTrue(h.pinKey(AgentPoolRequestHead(method: "POST", path: "/v1/messages", headers: [])) == nil)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:9/v1/messages")!)
        req.setValue("example-beta", forHTTPHeaderField: "anthropic-beta")
        h.authorize(&req, token: "tok-example")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-example")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "example-beta,oauth-2025-04-20")
        var bare = URLRequest(url: URL(string: "http://127.0.0.1:9/v1/messages")!)
        h.authorize(&bare, token: "tok-example")
        XCTAssertEqual(bare.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    /// The session env rule through the harness: claude routed, headroom and anything else untouched.
    func testSessionEnvRuleIsClaudes() {
        let base = "http://127.0.0.1:9"
        func env(_ argv: [String]) -> [String: String] {
            AgentPool.sessionEnv(command: argv, base: base, on: true, healthy: true, hasAccounts: true).set
        }
        XCTAssertEqual(env(["claude"]), ["ANTHROPIC_BASE_URL": base])
        XCTAssertEqual(env(["/usr/local/bin/claude", "--resume"]), ["ANTHROPIC_BASE_URL": base])
        XCTAssertEqual(env(["headroom"]), [:])
        XCTAssertEqual(env(["zsh"]), [:])
    }
}
