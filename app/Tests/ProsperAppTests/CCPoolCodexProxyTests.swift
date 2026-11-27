import XCTest
@testable import ProsperApp

// #2005 (design #2003, phase 2): `/codex/...` is relayed to the Codex upstream under a pool account's ChatGPT login.
// A fake upstream on 127.0.0.1 port 0 stands in for both api.anthropic.com (root) and chatgpt.com/backend-api/codex;
// memory secrets, a temp-dir store, fake credentials only. Nothing dials a real host.

/// What the fake upstream received, and what it answers.
final class CCPoolCodexFake: @unchecked Sendable {
    private let lock = NSLock()
    private var _heads: [CCPoolRequestHead] = []
    var status = 200
    var headers: [(String, String)] = [("content-type", "application/json")]
    var body = Data(#"{"ok":true}"#.utf8)

    var heads: [CCPoolRequestHead] { lock.withLock { _heads } }
    func set(_ f: (CCPoolCodexFake) -> Void) { lock.withLock { f(self) } }

    func reply(_ head: CCPoolRequestHead, _ data: Data) -> CCPoolFakeServer.Reply {
        lock.withLock {
            _heads.append(head)
            return .respond(status, headers, body)
        }
    }
}

final class CCPoolCodexProxyTests: XCTestCase {
    static let accessToken = "at-example-codex-0001"
    static let accountID = "acct-example-codex-0001"
    static let item = #"{"access_token":"at-example-codex-0001","refresh_token":"rt-example","id_token":"id-example","account_id":"acct-example-codex-0001","last_refresh":"2026-11-27T00:00:00Z"}"#

    struct Rig {
        let up: CCPoolFakeServer
        let fake: CCPoolCodexFake
        let service: CCPoolService
        let store: CCPoolStore
        let log: CCPoolCapturingLogger
        var port: UInt16 {
            if case .running(let p) = service.status { return p }
            return 0
        }
        func codex(_ method: String = "POST", _ path: String = "/codex/responses", headers: [(String, String)] = [],
                   body: Data = Data(#"{"model":"gpt-5-codex","stream":true}"#.utf8)) -> CCPoolClientResponse? {
            CCPoolTestClient.request(port: port, method: method, path: path,
                                     headers: [("content-type", "application/json")] + headers, body: body)
        }
    }

    /// `claude`: Claude accounts by label (token "tok-<label>"). `codex`: Codex accounts by label -> (Keychain item, kind).
    private func rig(claude: [String] = ["one"], codex: [(String, String, String?)] = [("cx", CCPoolCodexProxyTests.item, CCPoolCodexHarness.chatgptKind)],
                     codexUpstream: Bool = true) throws -> Rig {
        let fake = CCPoolCodexFake()
        let up = try CCPoolFakeServer { h, b in fake.reply(h, b) }
        XCTAssertNotEqual(up.port, 0)
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        for l in claude { try store.addAccount(label: l, token: "tok-\(l)", secrets: secrets) }
        for (l, item, kind) in codex {
            try store.addAccount(label: l, token: item, secrets: secrets)
            store.mutate { $0.accounts[l]?.harness = CCPoolCodexHarness.id; $0.accounts[l]?.kind = kind }
        }
        let log = CCPoolCapturingLogger()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        if codexUpstream { cfg.codexUpstream = URL(string: "http://127.0.0.1:\(up.port)/backend-api/codex")! }
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); up.stop() }
        return Rig(up: up, fake: fake, service: service, store: store, log: log)
    }

    // `/codex/responses` reaches `<fake>/backend-api/codex/responses` under the pool's login; the client's credential,
    // account id and cookie never go upstream; Codex's own headers pass through.
    func testCodexResponsesCarriesThePoolLoginOnly() throws {
        let r = try rig()
        XCTAssertTrue(r.service.config.codexReach.lastServed == nil, "#2009: no /codex request served yet")
        let resp = try XCTUnwrap(r.codex(headers: [
            ("Authorization", "Bearer client-token-should-be-replaced"),
            ("ChatGPT-Account-Id", "client-account-should-be-replaced"),
            ("Cookie", "client-cookie=1"),
            ("OpenAI-Organization", "client-org"), ("OpenAI-Project", "client-project"),
            ("originator", "codex_cli_rs"), ("version", "0.167.2"), ("session_id", "sess-example"),
            ("OpenAI-Beta", "responses=experimental"), ("User-Agent", "codex-example/1"),
        ]))
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertTrue(r.service.config.codexReach.lastServed != nil, "#2009: the served /codex request reaches the detector")
        let heads = r.fake.heads
        XCTAssertEqual(heads.count, 1)
        let h = try XCTUnwrap(heads.last)
        XCTAssertEqual(h.path, "/backend-api/codex/responses")
        XCTAssertEqual(h.headers.filter { $0.name.lowercased() == "authorization" }.map(\.value), ["Bearer \(Self.accessToken)"])
        XCTAssertEqual(h.headers.filter { $0.name.lowercased() == "chatgpt-account-id" }.map(\.value), [Self.accountID])
        XCTAssertTrue(h.header("cookie") == nil)
        XCTAssertTrue(h.header("openai-organization") == nil)
        XCTAssertTrue(h.header("openai-project") == nil)
        XCTAssertFalse(h.headers.contains { $0.value.contains("client-") }, "no client credential value went upstream")
        XCTAssertEqual(h.header("originator"), "codex_cli_rs")
        XCTAssertEqual(h.header("version"), "0.167.2")
        XCTAssertEqual(h.header("session_id"), "sess-example")
        XCTAssertEqual(h.header("openai-beta"), "responses=experimental")
        XCTAssertEqual(h.header("user-agent"), "codex-example/1")
        XCTAssertTrue(h.header("anthropic-beta") == nil, "Claude's OAuth beta is Claude's")
    }

    // An SSE reply is relayed byte for byte.
    func testCodexSSEReplyIsRelayedByteExact() throws {
        let r = try rig()
        let sse = Data("event: response.created\ndata: {\"type\":\"response.created\"}\n\nevent: response.output_text.delta\ndata: {\"delta\":\"h\\u00e9\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\"}\n\n".utf8)
        r.fake.set { $0.headers = [("content-type", "text/event-stream")]; $0.body = sse }
        let resp = try XCTUnwrap(r.codex())
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.header("content-type"), "text/event-stream")
        XCTAssertEqual(resp.body, sse)
    }

    // `GET /codex/models?client_version=1` keeps its query; a bare `/codex` and a look-alike root path do not mix.
    func testCodexModelsKeepsItsQuery() throws {
        let r = try rig()
        let resp = try XCTUnwrap(r.codex("GET", "/codex/models?client_version=1"))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(r.fake.heads.last?.path, "/backend-api/codex/models?client_version=1")
        XCTAssertEqual(CCPoolCodexHarness.rest(of: "/codex"), "")
        XCTAssertEqual(CCPoolCodexHarness.rest(of: "/codex?x=1"), "?x=1")
        XCTAssertEqual(CCPoolCodexHarness.rest(of: "/codex/responses/compact"), "/responses/compact")
        XCTAssertTrue(CCPoolCodexHarness.rest(of: "/codexfoo") == nil)
        XCTAssertTrue(CCPoolCodexHarness.rest(of: "/v1/messages") == nil)
    }

    // A Claude request on the same service reaches `upstream` with today's headers and the Claude account; a Codex
    // request takes the Codex account, never the Claude one.
    func testClaudeAndCodexKeepTheirOwnAccounts() throws {
        let r = try rig()
        let claude = try XCTUnwrap(CCPoolTestClient.request(port: r.port, headers: [
            ("content-type", "application/json"), ("authorization", "Bearer client-token-should-be-replaced"),
            ("chatgpt-account-id", "kept-for-claude"),
        ]))
        XCTAssertEqual(claude.status, 200, claude.text)
        let codex = try XCTUnwrap(r.codex())
        XCTAssertEqual(codex.status, 200, codex.text)
        let heads = r.fake.heads
        XCTAssertEqual(heads.count, 2)
        let c = try XCTUnwrap(heads.first), x = try XCTUnwrap(heads.last)
        XCTAssertEqual(c.path, "/v1/messages")
        XCTAssertEqual(c.header("authorization"), "Bearer tok-one")
        XCTAssertEqual(c.header("anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(c.header("chatgpt-account-id"), "kept-for-claude", "Claude's strip set is unchanged")
        XCTAssertEqual(x.path, "/backend-api/codex/responses")
        XCTAssertEqual(x.header("authorization"), "Bearer \(Self.accessToken)")
    }

    // A Claude request with only Codex accounts gets Claude's no-accounts answer and is never sent.
    func testClaudeNeverTakesACodexAccount() throws {
        let r = try rig(claude: [])
        let resp = try XCTUnwrap(CCPoolTestClient.request(port: r.port))
        XCTAssertEqual(resp.status, 429, resp.text)
        XCTAssertTrue(resp.text.contains("all pooled accounts are rate limited"), resp.text)
        XCTAssertEqual(r.fake.heads.count, 0)
        XCTAssertTrue(r.service.config.codexReach.lastServed == nil, "#2009: a request at the root is not a /codex one")
    }

    // No Codex account (none at all, or only one of a kind Phase 2 does not route) answers 503 and sends nothing.
    func testNoCodexAccountAnswers503() throws {
        for codex in [[], [("cx", Self.item, nil)], [("cx", Self.item, "openai-key")]] as [[(String, String, String?)]] {
            let r = try rig(codex: codex)
            let resp = try XCTUnwrap(r.codex())
            XCTAssertEqual(resp.status, 503, resp.text)
            XCTAssertEqual(resp.text, "ccpool: no Codex accounts in the pool\n")
            XCTAssertEqual(r.fake.heads.count, 0, "the Claude account is never used for Codex")
        }
    }

    // An item that does not decode, or lacks either field, is skipped like a missing token: nothing is sent.
    func testUndecodableCodexItemIsNeverSent() throws {
        let items = ["at-example-raw-secret", #"{"access_token":"at-example-raw-secret"}"#,
                     #"{"account_id":"acct-example-raw"}"#, #"{"access_token":"","account_id":"acct-example-raw"}"#,
                     #"{"access_token":"at-example-raw-secret","account_id":""}"#]
        for item in items {
            let r = try rig(codex: [("cx", item, CCPoolCodexHarness.chatgptKind)])
            let resp = try XCTUnwrap(r.codex())
            XCTAssertNotEqual(resp.status, 200, item)
            XCTAssertEqual(r.fake.heads.count, 0, item)
            let lines = r.log.lines
            XCTAssertTrue(lines.contains("cx: token unavailable; skipping this account"), "\(lines)")
            XCTAssertFalse(lines.contains { $0.contains("example-raw") }, "\(lines)")
        }
    }

    // A WebSocket upgrade on a Codex path answers 501 and is never relayed.
    func testCodexWebSocketUpgradeAnswers501() throws {
        let r = try rig()
        let resp = try XCTUnwrap(r.codex("GET", "/codex/responses", headers: [("Connection", "Upgrade"), ("Upgrade", "websocket"),
                                                                             ("Sec-WebSocket-Version", "13")]))
        XCTAssertEqual(resp.status, 501, resp.text)
        XCTAssertTrue(resp.text.contains("WebSocket"), resp.text)
        XCTAssertEqual(r.fake.heads.count, 0)
    }

    // Neither the access token nor the account id reaches the log, on a served reply or a refused one; a Codex
    // exchange without limit headers writes no usage sample; #2006: it writes usage rows like the Claude one beside it.
    func testCodexExchangeLogsNoCredentialAndWritesNoUsage() throws {
        let r = try rig()
        XCTAssertEqual(r.codex()?.status, 200)
        r.fake.set { $0.status = 429; $0.headers = [("content-type", "application/json"), ("retry-after", "0")]
            $0.body = Data(#"{"error":{"type":"usage_limit_reached"}}"#.utf8) }
        let saved = CCPoolConnection.throttleWait
        CCPoolConnection.throttleWait = { _, q, go in q.async(execute: go) }
        addTeardownBlock { CCPoolConnection.throttleWait = saved }
        XCTAssertEqual(r.codex()?.status, 429)
        let lines = r.log.lines
        XCTAssertFalse(lines.isEmpty, "the 429 was logged")
        XCTAssertFalse(lines.contains { $0.contains(Self.accessToken) || $0.contains(Self.accountID) }, "\(lines)")
        XCTAssertTrue(r.store.usageSample("cx") == nil)
        r.fake.set { $0.status = 200 }
        XCTAssertEqual(CCPoolTestClient.request(port: r.port)?.status, 200)
        r.service.usageRecord.flush()
        let files = (try? FileManager.default.contentsOfDirectory(at: r.store.usageDirectory, includingPropertiesForKeys: nil)) ?? []
        let rows = files.filter { $0.lastPathComponent.hasPrefix("usage-") }.flatMap { (try? String(contentsOf: $0, encoding: .utf8))?.split(separator: "\n") ?? [] }
        XCTAssertEqual(rows.count, 3, "Codex's 200, the pool's all-benched 429 after the spent one, and Claude's: \(rows)")
        XCTAssertFalse(rows.contains { $0.contains(Self.accessToken) || $0.contains(Self.accountID) }, "\(rows)")
    }

    // Under XCTest the OpenAI hosts are refused like Claude's, and a Codex request with the default upstream is
    // answered by the pool, never dialled.
    func testOpenAIHostsAreRefusedUnderTest() throws {
        // A mutant that stops refusing a host must end the row here, before the rig below could dial it.
        continueAfterFailure = false
        XCTAssertTrue(CCPoolService.refusesUnderTest(URL(string: "https://chatgpt.com/backend-api/codex")!))
        XCTAssertTrue(CCPoolService.refusesUnderTest(URL(string: "https://api.openai.com/v1")!))
        XCTAssertTrue(CCPoolService.refusesUnderTest(URL(string: "https://auth.openai.com/oauth/token")!))
        XCTAssertTrue(CCPoolService.refusesUnderTest(CCPoolService.productionUpstream))
        XCTAssertFalse(CCPoolService.refusesUnderTest(URL(string: "http://127.0.0.1:9/backend-api/codex")!))
        XCTAssertEqual(CCPoolServiceConfig().codexUpstream.absoluteString, "https://chatgpt.com/backend-api/codex")
        let r = try rig(codexUpstream: false)
        let resp = try XCTUnwrap(r.codex())
        XCTAssertEqual(resp.status, 502, resp.text)
        XCTAssertTrue(resp.text.contains("refusing the production upstream"), resp.text)
        XCTAssertEqual(r.fake.heads.count, 0)
    }

    // CCPoolCodexHarness alone: the pool's login on the request, nothing set for an unusable item, the P2 stubs.
    func testCodexHarnessAuthorizeAndStubs() {
        let h: any PoolHarness = CCPoolCodexHarness()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:9/backend-api/codex/responses")!)
        XCTAssertTrue(h.authorize(&req, token: Self.item))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.accessToken)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "chatgpt-account-id"), Self.accountID)
        var bad = URLRequest(url: URL(string: "http://127.0.0.1:9/x")!)
        XCTAssertFalse(h.authorize(&bad, token: "{"))
        XCTAssertTrue(bad.value(forHTTPHeaderField: "Authorization") == nil)
        XCTAssertEqual(h.id, "codex")
        XCTAssertTrue(h.accepts(kind: "codex-chatgpt"))
        XCTAssertFalse(h.accepts(kind: nil))
        XCTAssertTrue(ClaudeHarness().accepts(kind: nil))
        XCTAssertTrue(h.stripRequest.isSuperset(of: ClaudeHarness.stripRequest))
        XCTAssertTrue(h.stripRequest.isSuperset(of: ["chatgpt-account-id", "openai-organization", "openai-project", "cookie"]))
        XCTAssertTrue(h.stripRequest.isDisjoint(with: ["originator", "version", "session_id", "openai-beta", "user-agent"]))
        XCTAssertTrue(h.parseLimits(["x-codex-primary-used-percent": "50"]).limits.isEmpty)
        XCTAssertEqual(h.claims(for: "gpt-5-codex"), ["five_hour", "seven_day"])
        XCTAssertFalse(h.isQuotaCheck(["max_tokens": 1]))
        XCTAssertEqual(h.pinKey(CCPoolRequestHead(method: "POST", path: "/codex/responses", headers: [(name: "session_id", value: "s")])), "codex/s")
        var tap = h.usageTap(contentType: "application/json")
        tap.feed(Data(#"{"usage":{"input_tokens":5}}"#.utf8))
        XCTAssertTrue(tap.result() == nil, "no Anthropic parsing of an OpenAI reply")
    }
}
