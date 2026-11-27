import XCTest
@testable import ProsperApp

// #2007 (design #2003 section 4, Token refresh; sections 10 and 11): Codex logins in the Keychain item and their
// single-holder refresh. A fake upstream and a fake auth server on 127.0.0.1 port 0, memory secrets, a temp-dir store
// and fake credentials only. Nothing dials a real host.

/// The fake auth server: counts refresh POSTs and answers what the row sets, after `delay`.
final class CodexFakeAuth: @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [Data] = []
    var status = 200
    var body = Data()
    var delay: TimeInterval = 0
    /// With a 3xx `status`: the Location the reply names.
    var location: String?
    var posts: [Data] { lock.withLock { _posts } }
    func set(_ f: (CodexFakeAuth) -> Void) { lock.withLock { f(self) } }

    func reply(_ head: CCPoolRequestHead, _ data: Data) -> CCPoolFakeServer.Reply {
        let (s, b, d, l) = lock.withLock { () -> (Int, Data, TimeInterval, String?) in
            _posts.append(data)
            return (status, body, delay, location)
        }
        if d > 0 { Thread.sleep(forTimeInterval: d) }
        return .respond(s, [("content-type", "application/json")] + (l.map { [("location", $0)] } ?? []), b)
    }
}

/// The fake Codex upstream: 200 for an accepted bearer, else 401. For each request it records the bearer and whether
/// the stored item already carried that access token when it arrived.
final class CodexFakeUpstream: @unchecked Sendable {
    private let lock = NSLock()
    private var _bearers: [String] = []
    private var _storedAtUse: [Bool] = []
    var accepted: Set<String> = []
    var stored: @Sendable () -> String? = { nil }
    var bearers: [String] { lock.withLock { _bearers } }
    var storedAtUse: [Bool] { lock.withLock { _storedAtUse } }
    func set(_ f: (CodexFakeUpstream) -> Void) { lock.withLock { f(self) } }

    func reply(_ head: CCPoolRequestHead, _ data: Data) -> CCPoolFakeServer.Reply {
        let bearer = String(head.header("authorization")?.dropFirst("Bearer ".count) ?? "")
        let item = lock.withLock { stored }()
        return lock.withLock {
            _bearers.append(bearer)
            _storedAtUse.append(item.flatMap(CodexCredential.decode)?.accessToken == bearer)
            return accepted.contains(bearer) ? .respond(200, [("content-type", "application/json")], Data(#"{"ok":true}"#.utf8))
                : .respond(401, [("content-type", "application/json")], Data(#"{"error":{"code":"token_expired"}}"#.utf8))
        }
    }
}

final class CodexTokenKeeperTests: XCTestCase {
    static let refreshOld = "rt-example-old-0001"
    static let idOld = "id-example-old-0001"
    static let accessNew = "at-example-new-0002"
    static let refreshNew = "rt-example-new-0002"
    static let idNew = "id-example-new-0002"
    static let account = "acct-example-codex-0001"

    /// A JWT-shaped access token (unsigned) with `exp`, made unique by `tag`.
    static func jwt(exp: Double, tag: String = "old") -> String {
        let payload = Data(#"{"exp":\#(Int(exp)),"sub":"example-\#(tag)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(payload).sig-example"
    }

    static func item(access: String, refresh: String? = refreshOld, last: Double? = Date().timeIntervalSince1970) -> String {
        CodexCredential(accessToken: access, accountID: account, refreshToken: refresh, idToken: refresh == nil ? nil : idOld,
                        lastRefresh: last).encoded()!
    }

    static let freshAccess = jwt(exp: Date().timeIntervalSince1970 + 10 * 86400)

    struct Rig {
        let service: CCPoolService
        let store: CCPoolStore
        let secrets: CCPoolMemorySecrets
        let log: CCPoolCapturingLogger
        let auth: CodexFakeAuth
        let upstream: CodexFakeUpstream
        var port: UInt16 {
            if case .running(let p) = service.status { return p }
            return 0
        }
        func codex() -> CCPoolClientResponse? {
            CCPoolTestClient.request(port: port, path: "/codex/responses", headers: [("content-type", "application/json")],
                                     body: Data(#"{"model":"gpt-5-codex","stream":false}"#.utf8))
        }
        var storedItem: CodexCredential? {
            let id = store.snapshot.accounts["cx"]?.id ?? ""
            return ((try? secrets.token(id: id)) ?? nil).flatMap(CodexCredential.decode)
        }
        var refused: Int? { store.snapshot.accounts["cx"]?.refused }
        var rowText: String? {
            guard let a = store.snapshot.accounts["cx"] else { return nil }
            let s = CCPoolPaneModel.rowState(label: "cx", account: a, current: nil, now: store.now, rejected: [], unverified: [])
            return CCPoolPaneModel.stateText(s, timeZone: TimeZone(identifier: "UTC")!)
        }
    }

    /// One Codex account "cx" holding `item`; the upstream accepts `accepted`.
    private func rig(item: String, accepted: Set<String>) throws -> Rig {
        let auth = CodexFakeAuth()
        auth.body = Data(#"{"access_token":"\#(Self.accessNew)","refresh_token":"\#(Self.refreshNew)","id_token":"\#(Self.idNew)"}"#.utf8)
        let authServer = try CCPoolFakeServer { h, b in auth.reply(h, b) }
        let upstream = CodexFakeUpstream()
        upstream.accepted = accepted
        let upServer = try CCPoolFakeServer { h, b in upstream.reply(h, b) }
        XCTAssertNotEqual(authServer.port, 0)
        XCTAssertNotEqual(upServer.port, 0)
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "cx", token: item, secrets: secrets)
        store.mutate { $0.accounts["cx"]?.harness = CCPoolCodexHarness.id; $0.accounts["cx"]?.kind = CCPoolCodexHarness.chatgptKind }
        let id = store.snapshot.accounts["cx"]?.id ?? ""
        upstream.stored = { (try? secrets.token(id: id)) ?? nil }
        let log = CCPoolCapturingLogger()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(upServer.port)")!
        cfg.codexUpstream = URL(string: "http://127.0.0.1:\(upServer.port)/backend-api/codex")!
        cfg.codexRefreshURL = URL(string: "http://127.0.0.1:\(authServer.port)/oauth/token")!
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); upServer.stop(); authServer.stop() }
        return Rig(service: service, store: store, secrets: secrets, log: log, auth: auth, upstream: upstream)
    }

    /// No log line carries any fixture token (old or new access, refresh or id token).
    private func assertNoSecrets(_ r: Rig, _ extra: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        let secrets = [Self.refreshOld, Self.idOld, Self.accessNew, Self.refreshNew, Self.idNew] + extra
        let lines = r.log.lines
        XCTAssertFalse(lines.isEmpty, "the flow logged something", file: file, line: line)
        for l in lines {
            for s in secrets where l.contains(s) { XCTFail("a token reached the log: \(l.prefix(40))…", file: file, line: line) }
        }
    }

    // A 401 refreshes the login (one POST, Codex's grant), stores the new item and only then replays it: the upstream
    // sees the new access token when the store already holds it. Old: the 401 went back to the client.
    func testRefreshedLoginIsStoredBeforeTheUpstreamSeesIt() throws {
        let old = "at-example-old-0001"
        let r = try rig(item: Self.item(access: old), accepted: [Self.accessNew])
        let resp = try XCTUnwrap(r.codex())
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertEqual(r.auth.posts.count, 1)
        let post = try XCTUnwrap(r.auth.posts.last.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(post["grant_type"], "refresh_token")
        XCTAssertEqual(post["refresh_token"], Self.refreshOld)
        XCTAssertEqual(post["client_id"], CodexTokenKeeper.clientID)
        XCTAssertEqual(r.upstream.bearers, [old, Self.accessNew])
        XCTAssertEqual(r.upstream.storedAtUse, [true, true], "each access token was in the store before it went out")
        let stored = try XCTUnwrap(r.storedItem)
        XCTAssertEqual(stored.accessToken, Self.accessNew)
        XCTAssertEqual(stored.refreshToken, Self.refreshNew)
        XCTAssertEqual(stored.idToken, Self.idNew)
        XCTAssertEqual(stored.accountID, Self.account)
        XCTAssertTrue(stored.lastRefresh != nil)
        XCTAssertTrue(r.refused == nil)
        assertNoSecrets(r, [old])
    }

    // Several requests hitting 401 together spend the refresh token once: the others wait on that one refresh.
    func testConcurrent401sSpendTheRefreshTokenOnce() throws {
        let old = "at-example-old-0003"
        let r = try rig(item: Self.item(access: old), accepted: [Self.accessNew])
        r.auth.set { $0.delay = 0.5 }
        let statuses = CCPoolBetaBox()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in statuses.add("\(r.codex()?.status ?? 0)") }
        XCTAssertEqual(statuses.values, ["200", "200", "200", "200"])
        XCTAssertEqual(r.auth.posts.count, 1, "one refresh for every concurrent 401")
        XCTAssertTrue(r.upstream.bearers.filter { $0 == old }.count >= 2, "the 401s did overlap")
        assertNoSecrets(r, [old])
    }

    // Each refusal of the refresh token signs the account out at once: the client hears 401, the row says so, and a
    // later request posts nothing more. Old: no refresh, no sign-out.
    func testEachRefusalSignsTheAccountOut() throws {
        let bodies = [
            #"{"error":{"code":"refresh_token_reused","message":"Token reuse detected."}}"#,
            #"{"error":{"code":"invalid_refresh_token","message":"Token is not valid."}}"#,
            #"{"error":{"message":"Your refresh token was already used to get a new token."}}"#,
            #"{"error":"invalid_grant","error_description":"Grant is not valid."}"#,
            #"{"error":{"message":"The Refresh Token has expired after a plan change."}}"#,
        ]
        for body in bodies {
            let old = "at-example-old-0004"
            let r = try rig(item: Self.item(access: old), accepted: [Self.accessNew])
            r.auth.set { $0.status = 400; $0.body = Data(body.utf8) }
            let first = try XCTUnwrap(r.codex())
            XCTAssertEqual(first.status, 401, body)
            XCTAssertTrue(first.text.contains("sign in again"), first.text)
            XCTAssertTrue(r.refused != nil, body)
            XCTAssertEqual(r.rowText, "Signed out: sign in again", body)
            XCTAssertEqual(r.storedItem?.refreshToken, Self.refreshOld, "a refused refresh writes nothing")
            let second = try XCTUnwrap(r.codex())
            XCTAssertEqual(second.status, 401, body)
            XCTAssertEqual(r.auth.posts.count, 1, "no second POST: \(body)")
            assertNoSecrets(r, [old])
        }
    }

    // An auth error that names no dead chain (a throttle, a 5xx that says "refresh token") is not a sign-out: the client
    // hears 502, the account stays routed and the next 401 tries again.
    func testAnotherRefreshErrorIsNotASignOut() throws {
        for (status, body) in [(400, #"{"error":"temporarily_unavailable"}"#), (503, #"{"error":"refresh token service down"}"#)] {
            let old = "at-example-old-0005"
            let r = try rig(item: Self.item(access: old), accepted: [Self.accessNew])
            r.auth.set { $0.status = status; $0.body = Data(body.utf8) }
            XCTAssertEqual(r.codex()?.status, 502, body)
            XCTAssertTrue(r.refused == nil, body)
            XCTAssertEqual(r.codex()?.status, 502, body)
            XCTAssertEqual(r.auth.posts.count, 2, "tried again on the next trigger: \(body)")
            assertNoSecrets(r, [old])
        }
    }

    // A second 401 after the refresh marks the account refused (the #1278 state on the Codex path); one refresh only.
    func testSecond401AfterTheRefreshSignsOut() throws {
        let old = "at-example-old-0006"
        let r = try rig(item: Self.item(access: old), accepted: [])
        XCTAssertEqual(r.codex()?.status, 401)
        XCTAssertEqual(r.auth.posts.count, 1)
        XCTAssertEqual(r.upstream.bearers, [old, Self.accessNew])
        XCTAssertTrue(r.refused != nil)
        XCTAssertEqual(r.rowText, "Signed out: sign in again")
        assertNoSecrets(r, [old])
    }

    // exp within 1 h and last_refresh over 7 days each refresh before use; a fresh login is used as it is.
    func testDueLoginsRefreshBeforeUseAndFreshOnesDoNot() throws {
        let now = Date().timeIntervalSince1970
        let soon = Self.jwt(exp: now + 600, tag: "soon")
        let old = Self.jwt(exp: now + 10 * 86400, tag: "aged")
        let cases: [(String, String, Int)] = [
            ("exp within 1 h", Self.item(access: soon), 1),
            ("last refresh 8 days ago", Self.item(access: old, last: now - 8 * 86400), 1),
            ("fresh", Self.item(access: Self.freshAccess, last: now - 86400), 0),
        ]
        for (name, item, posts) in cases {
            let access = CodexCredential.decode(item)?.accessToken ?? ""
            let r = try rig(item: item, accepted: [access, Self.accessNew])
            XCTAssertEqual(r.codex()?.status, 200, name)
            XCTAssertEqual(r.auth.posts.count, posts, name)
            XCTAssertEqual(r.upstream.bearers, [posts == 1 ? Self.accessNew : access], name)
            XCTAssertEqual(r.upstream.storedAtUse, [true], name)
            assertNoSecrets(r, [access])
        }
        let c = { (item: String) in CodexCredential.decode(item)! }
        XCTAssertTrue(CodexTokenKeeper.due(c(Self.item(access: soon)), now: now))
        XCTAssertTrue(CodexTokenKeeper.due(c(Self.item(access: Self.jwt(exp: now - 5))), now: now), "already expired")
        XCTAssertFalse(CodexTokenKeeper.due(c(Self.item(access: Self.freshAccess)), now: now))
        XCTAssertFalse(CodexTokenKeeper.due(c(Self.item(access: "not-a-jwt")), now: now), "no exp, recent refresh")
        XCTAssertTrue(CodexTokenKeeper.due(c(Self.item(access: "not-a-jwt", last: now - 8 * 86400)), now: now))
        XCTAssertFalse(CodexTokenKeeper.due(c(Self.item(access: soon, refresh: nil)), now: now), "cannot refresh")
    }

    // The #2005 two-field item still routes and is never refreshed, even when due; its 401 marks it refused.
    func testTwoFieldItemRoutesAndIsNeverRefreshed() throws {
        let access = Self.jwt(exp: Date().timeIntervalSince1970 + 60, tag: "two")
        let item = #"{"access_token":"\#(access)","account_id":"\#(Self.account)"}"#
        let r = try rig(item: item, accepted: [access])
        XCTAssertEqual(r.codex()?.status, 200)
        XCTAssertEqual(r.upstream.bearers, [access])
        r.upstream.set { $0.accepted = [] }
        XCTAssertEqual(r.codex()?.status, 401)
        XCTAssertEqual(r.auth.posts.count, 0, "never refreshed")
        XCTAssertTrue(r.refused != nil, "#1278 on the Codex path")
        XCTAssertEqual(r.rowText, "Signed out: sign in again")
        assertNoSecrets(r, [access])
    }

    // The credential: both item shapes decode, auth.json's nested tokens flatten, nothing secret is ever described.
    func testCredentialShapesAndNoDescription() throws {
        let two = try XCTUnwrap(CodexCredential.decode(#"{"access_token":"at-x","account_id":"acct-x"}"#))
        XCTAssertFalse(two.canRefresh)
        XCTAssertTrue(CodexCredential.decode(#"{"access_token":"","account_id":"acct-x"}"#) == nil)
        XCTAssertTrue(CodexCredential.decode(#"{"access_token":"at-x"}"#) == nil)
        XCTAssertTrue(CodexCredential.decode("raw-claude-token") == nil)
        let auth = Data(#"{"OPENAI_API_KEY":null,"tokens":{"id_token":"\#(Self.idOld)","access_token":"at-auth","refresh_token":"\#(Self.refreshOld)","account_id":"\#(Self.account)"},"last_refresh":"2026-11-20T08:15:30.123456Z"}"#.utf8)
        let flat = try XCTUnwrap(CodexCredential.flatItem(fromAuthJSON: auth))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(flat.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["access_token", "refresh_token", "id_token", "account_id", "last_refresh"])
        XCTAssertEqual(obj["last_refresh"] as? String, "2026-11-20T08:15:30Z")
        let cred = try XCTUnwrap(CodexCredential.decode(flat))
        XCTAssertTrue(cred.canRefresh)
        XCTAssertEqual(cred.refreshToken, Self.refreshOld)
        XCTAssertEqual(CodexCredential.decode(try XCTUnwrap(cred.encoded())), cred, "round trip")
        XCTAssertTrue(CodexCredential.flatItem(fromAuthJSON: Data(#"{"access_token":"at-x","account_id":"a"}"#.utf8)) == nil, "no tokens object")
        var dumped = ""
        dump(cred, to: &dumped)
        for text in ["\(cred)", String(reflecting: cred), dumped, "\([cred])"] {
            for s in ["at-auth", Self.refreshOld, Self.idOld, Self.account] { XCTAssertFalse(text.contains(s), text) }
        }
        XCTAssertEqual(CodexCredential.jwtExp(Self.jwt(exp: 1_800_000_000)), 1_800_000_000)
        XCTAssertTrue(CodexCredential.jwtExp("a.b") == nil)
        XCTAssertTrue(CodexCredential.jwtExp("a.!!!.c") == nil)
    }

    // The refusal words, alone: a 4xx naming one signs out; a 2xx or 5xx never does.
    func testRefusalWords() {
        for w in ["refresh_token_reused", "invalid_refresh_token", "Refresh token was already used", "invalid_grant", "bad Refresh Token"] {
            XCTAssertTrue(CodexTokenKeeper.signsOut(status: 400, body: Data(#"{"error":"\#(w)"}"#.utf8)), w)
            XCTAssertTrue(CodexTokenKeeper.signsOut(status: 401, body: Data(#"{"error":"\#(w)"}"#.utf8)), w)
            XCTAssertFalse(CodexTokenKeeper.signsOut(status: 500, body: Data(#"{"error":"\#(w)"}"#.utf8)), w)
        }
        XCTAssertFalse(CodexTokenKeeper.signsOut(status: 400, body: Data(#"{"error":"slow_down"}"#.utf8)))
    }

    final class OutcomeBox: @unchecked Sendable { var value: CodexTokenKeeper.Outcome? }

    /// Runs the service's keeper on account "cx" (its stored access token is the stale one), calls `during` once the POST
    /// is out, and returns the outcome.
    private func refresh(_ r: Rig, during: () throws -> Void = {}) throws -> CodexTokenKeeper.Outcome? {
        let id = try XCTUnwrap(r.store.snapshot.accounts["cx"]?.id)
        let stale = try XCTUnwrap(r.storedItem?.accessToken)
        let box = OutcomeBox()
        let settled = expectation(description: "refresh settled")
        r.service.codexKeeper.refresh(id: id, stale: stale) { o in box.value = o; settled.fulfill() }
        try during()
        wait(for: [settled], timeout: 10)
        return box.value
    }

    // QA R2007 F1: a 3xx from the auth host is the answer, never followed: the Location host hears nothing (the refresh
    // token would be re-POSTed to it), the refresh fails and the account is not signed out. Old: followed, refreshed.
    func testRedirectFromTheAuthHostIsNotFollowed() throws {
        let r = try rig(item: Self.item(access: "at-example-old-0007"), accepted: [])
        let hits = CCPoolBetaBox()
        let auth = r.auth
        let other = try CCPoolFakeServer { h, _ in
            hits.add(h.path)
            return .respond(200, [("content-type", "application/json")], auth.body)
        }
        addTeardownBlock { other.stop() }
        XCTAssertNotEqual(other.port, 0)
        r.auth.set { $0.status = 307; $0.location = "http://127.0.0.1:\(other.port)/oauth/token" }
        XCTAssertEqual(try refresh(r), .failed)
        XCTAssertEqual(hits.values, [], "the Location host received nothing")
        XCTAssertEqual(r.auth.posts.count, 1)
        XCTAssertTrue(r.refused == nil, "a redirect is not a sign-out")
        XCTAssertEqual(r.storedItem?.refreshToken, Self.refreshOld)
        assertNoSecrets(r)
    }

    // QA R2007 F2: an account removed while its refresh is in flight stays removed: its Keychain item is not re-created.
    // Old: the upsert re-added the item with live tokens and no row left to remove it.
    func testRemovalDuringTheRefreshIsNotUndone() throws {
        let r = try rig(item: Self.item(access: "at-example-old-0008"), accepted: [])
        let id = try XCTUnwrap(r.store.snapshot.accounts["cx"]?.id)
        r.auth.set { $0.delay = 0.5 }
        let outcome = try refresh(r) { try r.store.removeAccount(label: "cx", secrets: r.secrets) }
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(r.auth.posts.count, 1, "the POST was out before the removal")
        XCTAssertEqual(r.secrets.count, 0, "the item was not re-created")
        XCTAssertTrue(r.log.lines.contains { $0.contains("account removed during refresh") }, "\(r.log.lines)")
        // The update-only write, alone: a missing item throws and stays missing.
        XCTAssertThrowsError(try r.secrets.replace(token: "x", id: id, label: "cx"))
        XCTAssertEqual(r.secrets.count, 0)
        assertNoSecrets(r)
    }

    // QA R2007 F2: an item deleted under a row that still stands (Keychain Access, a failed add) is not re-created by a
    // refresh that lands afterwards. Old: the upsert wrote it back.
    func testItemDeletedDuringTheRefreshIsNotRecreated() throws {
        let r = try rig(item: Self.item(access: "at-example-old-0009"), accepted: [])
        let id = try XCTUnwrap(r.store.snapshot.accounts["cx"]?.id)
        r.auth.set { $0.delay = 0.5 }
        XCTAssertEqual(try refresh(r) { try r.secrets.remove(id: id) }, .failed)
        XCTAssertEqual(r.auth.posts.count, 1)
        XCTAssertEqual(r.secrets.count, 0, "the item was not re-created")
        XCTAssertTrue(r.store.snapshot.accounts["cx"] != nil)
        assertNoSecrets(r)
    }

    // QA R2007 F2: a rename while the refresh is in flight stands: the refreshed item carries the new label. Old: the
    // label read before the POST was written back.
    func testRenameDuringTheRefreshKeepsTheNewLabel() throws {
        let r = try rig(item: Self.item(access: "at-example-old-0010"), accepted: [])
        let id = try XCTUnwrap(r.store.snapshot.accounts["cx"]?.id)
        r.auth.set { $0.delay = 0.5 }
        let outcome = try refresh(r) { try r.store.renameAccount("cx", to: "cx-renamed", secrets: r.secrets) }
        guard case .refreshed? = outcome else { return XCTFail("not refreshed") }
        XCTAssertEqual(r.secrets.label(id: id), "cx-renamed")
        XCTAssertEqual(((try? r.secrets.token(id: id)) ?? nil).flatMap(CodexCredential.decode)?.accessToken, Self.accessNew)
        assertNoSecrets(r)
    }

    // Under XCTest the keeper never dials the production auth host.
    func testProductionAuthHostIsRefusedUnderTest() {
        XCTAssertTrue(CCPoolService.refusesUnderTest(CodexTokenKeeper.productionURL))
        XCTAssertEqual(CCPoolServiceConfig().codexRefreshURL, CodexTokenKeeper.productionURL)
    }
}
