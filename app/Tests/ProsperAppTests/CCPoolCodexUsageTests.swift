import XCTest
@testable import ProsperApp

// #2010 (design #2003 sections 3 and 10, Phase 7): Refresh reads each Codex account's wham/usage, and the pane groups
// its rows by harness. A fake usage server and a fake auth server on 127.0.0.1 port 0, memory secrets, a temp-dir store
// and fake credentials only. Nothing dials a real host.

/// The fake wham/usage endpoint: answers `body` to an accepted bearer (all when `accepted` is nil), else 401. Records
/// each request's path and headers (names lowercased) and the bearers it saw.
final class CodexFakeUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var _heads: [[String: String]] = []
    private var _paths: [String] = []
    var accepted: Set<String>?
    var status = 200
    var body = Data(CodexFakeUsage.both.utf8)
    var headers: [(String, String)] = []
    var heads: [[String: String]] { lock.withLock { _heads } }
    var paths: [String] { lock.withLock { _paths } }
    var bearers: [String] { heads.map { String(($0["authorization"] ?? "").dropFirst("Bearer ".count)) } }
    func set(_ f: (CodexFakeUsage) -> Void) { lock.withLock { f(self) } }

    static let both = #"{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"#
        + #""primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1800003600},"#
        + #""secondary_window":{"used_percent":34,"limit_window_seconds":604800,"reset_after_seconds":7200}},"#
        + #""credits":{"has_credits":true,"unlimited":false,"balance":"5"}}"#

    func reply(_ head: CCPoolRequestHead, _ data: Data) -> CCPoolFakeServer.Reply {
        lock.withLock {
            _paths.append(head.path)
            _heads.append(Dictionary(head.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }))
            let bearer = String(head.header("authorization")?.dropFirst("Bearer ".count) ?? "")
            guard accepted?.contains(bearer) ?? true else {
                return .respond(401, [("content-type", "application/json")], Data(#"{"detail":"token expired"}"#.utf8))
            }
            return .respond(status, [("content-type", "application/json")] + headers, body)
        }
    }
}

final class CCPoolCodexUsageParseTests: XCTestCase {
    typealias L = CCPoolLimit
    let now = 1_800_000_000.0

    func parse(_ json: String) -> (limits: [String: CCPoolLimit], credits: String?, missing: String?) {
        CCPoolCodexHarness.parseUsage(Data(json.utf8), now: now)
    }

    func testUsageParseTable() {
        let rows: [(String, String, [String: L], String?)] = [
            ("both windows, reset_at and reset_after_seconds", CodexFakeUsage.both,
             ["five_hour": L(status: "allowed", utilization: "0.12", reset: "1800003600"),
              "seven_day": L(status: "allowed", utilization: "0.34", reset: "1800007200")], nil),
            ("weekly primary, no secondary",
             #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800}}}"#,
             ["seven_day": L(status: "allowed", utilization: "0.1", reset: nil)], nil),
            ("reset_at wins over reset_after_seconds",
             #"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_at":1800000500,"reset_after_seconds":60}}}"#,
             ["five_hour": L(status: "allowed", utilization: "0.0", reset: "1800000500")], nil),
            ("spent at 100", #"{"rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":18000}}}"#,
             ["five_hour": L(status: "rejected", utilization: "1.0", reset: nil)], nil),
            ("limit_reached under 100 rejects the fullest window",
             #"{"rate_limit":{"limit_reached":true,"primary_window":{"used_percent":80,"limit_window_seconds":18000},"secondary_window":{"used_percent":10,"limit_window_seconds":604800}}}"#,
             ["five_hour": L(status: "rejected", utilization: "0.8", reset: nil),
              "seven_day": L(status: "allowed", utilization: "0.1", reset: nil)], nil),
            ("non-number fields dropped",
             #"{"rate_limit":{"primary_window":{"used_percent":"12","limit_window_seconds":18000,"reset_at":true,"reset_after_seconds":60}}}"#,
             ["five_hour": L(status: nil, utilization: nil, reset: "1800000060")], nil),
            ("other window length", #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":86400}}}"#,
             ["window_1440m": L(status: "allowed", utilization: "0.05", reset: nil)], nil),
            ("missing rate_limit", #"{"plan_type":"plus"}"#, [:], "rate_limit"),
            ("no usable window", #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":"18000"}}}"#,
             [:], "rate_limit.primary_window"),
            ("not JSON", "<html>", [:], "a JSON object"),
            ("a JSON array", "[1,2]", [:], "a JSON object"),
        ]
        for (name, json, limits, missing) in rows {
            let p = parse(json)
            XCTAssertEqual(p.limits, limits, name)
            XCTAssertEqual(p.missing, missing, name)
        }
    }

    func testOversizedAnswerIsRefusedByTheParser() {
        let big = Data((String(CodexFakeUsage.both.dropLast(1)) + #","pad":""# + String(repeating: "x", count: 70_000) + #""}"#).utf8)
        let p = CCPoolCodexHarness.parseUsage(big, now: now)
        XCTAssertTrue(p.limits.isEmpty)
        XCTAssertEqual(p.missing, "an answer under 64 KiB")
    }

    func testCreditsText() {
        XCTAssertEqual(parse(CodexFakeUsage.both).credits, "credits $5.00")
        XCTAssertEqual(CCPoolCodexHarness.creditsText(["unlimited": true, "has_credits": true]), "unlimited credits")
        XCTAssertEqual(CCPoolCodexHarness.creditsText(["has_credits": true, "balance": 12.5]), "credits $12.50")
        XCTAssertTrue(CCPoolCodexHarness.creditsText(["has_credits": false, "balance": "3"]) == nil)
        XCTAssertTrue(CCPoolCodexHarness.creditsText(["balance": "lots"]) == nil)
        XCTAssertTrue(CCPoolCodexHarness.creditsText(["balance": "nan"]) == nil)
        XCTAssertTrue(CCPoolCodexHarness.creditsText(nil) == nil)
    }

    func testUsageURLSitsNextToTheCodexUpstream() {
        XCTAssertEqual(CCPoolCodexHarness.usageURL(codexUpstream: CCPoolCodexHarness.upstream).absoluteString,
                       "https://chatgpt.com/backend-api/wham/usage")
    }
}

/// The probe against the fake usage server, alone and through CCPoolUsage.refresh with the keeper.
final class CCPoolCodexUsageProbeTests: XCTestCase {
    typealias K = CodexTokenKeeperTests

    struct Rig {
        let usage: CodexFakeUsage
        let auth: CodexFakeAuth
        let usageServer: CCPoolFakeServer
        let store: CCPoolStore
        let secrets: CCPoolMemorySecrets
        let log: CCPoolCapturingLogger
        let keeper: CodexTokenKeeper
        var base: URL { URL(string: "http://127.0.0.1:\(usageServer.port)/backend-api/codex")! }
        var harness: CCPoolCodexHarness {
            var h = CCPoolCodexHarness()
            h.keeper = keeper
            return h
        }
        func refresh() async -> CCPoolUsage.Report {
            await CCPoolUsage.refresh(store: store, secrets: secrets, base: base, logger: log, harness: harness)
        }
        var storedAccess: String? {
            let id = store.snapshot.accounts["cx"]?.id ?? ""
            return ((try? secrets.token(id: id)) ?? nil).flatMap(CodexCredential.decode)?.accessToken
        }
        var rowText: String? {
            guard let a = store.snapshot.accounts["cx"] else { return nil }
            let s = CCPoolPaneModel.rowState(label: "cx", account: a, current: nil, now: store.now, rejected: [], unverified: [])
            return CCPoolPaneModel.stateText(s, timeZone: TimeZone(identifier: "UTC")!)
        }
    }

    private func rig(item: String = K.item(access: K.freshAccess)) throws -> Rig {
        let usage = CodexFakeUsage()
        let usageServer = try CCPoolFakeServer { h, b in usage.reply(h, b) }
        let auth = CodexFakeAuth()
        auth.body = Data(#"{"access_token":"\#(K.accessNew)","refresh_token":"\#(K.refreshNew)","id_token":"\#(K.idNew)"}"#.utf8)
        let authServer = try CCPoolFakeServer { h, b in auth.reply(h, b) }
        XCTAssertNotEqual(usageServer.port, 0)
        XCTAssertNotEqual(authServer.port, 0)
        addTeardownBlock { usageServer.stop(); authServer.stop() }
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "cx", token: item, secrets: secrets)
        store.mutate { $0.accounts["cx"]?.harness = CCPoolCodexHarness.id; $0.accounts["cx"]?.kind = CCPoolCodexHarness.chatgptKind }
        let log = CCPoolCapturingLogger()
        let keeper = CodexTokenKeeper(store: store, secrets: secrets, url: URL(string: "http://127.0.0.1:\(authServer.port)/oauth/token")!,
                                      logger: log)
        return Rig(usage: usage, auth: auth, usageServer: usageServer, store: store, secrets: secrets, log: log, keeper: keeper)
    }

    private func assertNoSecrets(_ r: Rig, file: StaticString = #filePath, line: UInt = #line) {
        let lines = r.log.lines
        XCTAssertFalse(lines.isEmpty, "the flow logged something", file: file, line: line)
        for l in lines {
            for s in [K.freshAccess, K.refreshOld, K.idOld, K.accessNew, K.refreshNew, K.idNew] where l.contains(s) {
                XCTFail("a token reached the log: \(l.prefix(40))…", file: file, line: line)
            }
        }
    }

    func testProbeSendsBearerAndAccountIDAndNoCookie() async throws {
        let r = try rig()
        r.usage.set { $0.headers = [("set-cookie", "probe=example-cookie; Path=/")] }
        let first = await r.harness.probe(token: K.item(access: K.freshAccess), base: r.base, timeout: 10)
        let second = await r.harness.probe(token: K.item(access: K.freshAccess), base: r.base, timeout: 10)
        XCTAssertEqual(first?.limits["five_hour"]?.utilization, "0.12")
        XCTAssertEqual(second?.limits["seven_day"]?.utilization, "0.34")
        XCTAssertEqual(first?.credits, "credits $5.00")
        XCTAssertEqual(r.usage.paths, ["/backend-api/wham/usage", "/backend-api/wham/usage"])
        XCTAssertEqual(r.usage.heads.count, 2)
        for h in r.usage.heads {
            XCTAssertEqual(h["authorization"], "Bearer \(K.freshAccess)")
            XCTAssertEqual(h["chatgpt-account-id"], K.account)
            XCTAssertTrue(h["cookie"] == nil, "no cookie goes out, not even one the server set")
        }
        XCTAssertTrue(r.auth.posts.isEmpty, "a fresh login is never refreshed by the probe")
    }

    func testRedirectIsNotFollowed() async throws {
        let r = try rig()
        r.usage.set { $0.status = 302; $0.headers = [("location", "/elsewhere")] }
        let p = await r.harness.probe(token: K.item(access: K.freshAccess), base: r.base, timeout: 10)
        XCTAssertEqual(p?.status, 302)
        XCTAssertEqual(p?.limits, [:])
        XCTAssertEqual(r.usage.paths, ["/backend-api/wham/usage"], "the Location was never dialled")
    }

    func testOversizedAnswerIsRefusedOnTheWire() async throws {
        let r = try rig()
        r.usage.set { $0.body = Data((#"{"pad":""# + String(repeating: "x", count: 70_000) + #""}"#).utf8) }
        let report = await r.refresh()
        XCTAssertEqual(report.rows.count, 1)
        XCTAssertTrue(report.rows.first?.limits == nil)
        XCTAssertTrue(r.log.lines.contains { $0.contains("lacked an answer under 64 KiB") }, "\(r.log.lines)")
        assertNoSecrets(r)
    }

    func testRefreshRecordsCodexUsageOnItsAccount() async throws {
        let r = try rig()
        let report = await r.refresh()
        XCTAssertEqual(report.rows.map(\.label), ["cx"])
        XCTAssertEqual(report.rows.first?.credits, "credits $5.00")
        let sample = r.store.usageSample("cx")
        XCTAssertEqual(sample?.util["five_hour"], 0.12)
        XCTAssertEqual(sample?.util["seven_day"], 0.34)
        assertNoSecrets(r)
    }

    // A 401 gets one keeper refresh and one retry with the new access token: the auth server sees exactly one POST.
    func test401RefreshesOnceThenRetries() async throws {
        let r = try rig()
        r.usage.set { $0.accepted = [K.accessNew] }
        let report = await r.refresh()
        XCTAssertEqual(r.auth.posts.count, 1)
        XCTAssertEqual(r.usage.bearers, [K.freshAccess, K.accessNew])
        XCTAssertEqual(report.rows.first?.status, 200)
        XCTAssertEqual(report.rows.first?.limits?["five_hour"]?.utilization, "0.12")
        XCTAssertEqual(r.storedAccess, K.accessNew, "the keeper stored the new login")
        XCTAssertTrue(r.store.snapshot.accounts["cx"]?.refused == nil)
        assertNoSecrets(r)
    }

    // A reused refresh token signs the account out as the proxy does: the row says sign in again, no second POST.
    func testReusedRefreshTokenSignsOut() async throws {
        let r = try rig()
        r.usage.set { $0.accepted = [] }
        r.auth.set { $0.status = 400; $0.body = Data(#"{"error":{"code":"refresh_token_reused"}}"#.utf8) }
        let report = await r.refresh()
        XCTAssertEqual(r.auth.posts.count, 1)
        XCTAssertEqual(r.usage.bearers, [K.freshAccess], "no retry after a sign-out")
        XCTAssertEqual(report.rows.first?.status, 401)
        XCTAssertTrue(r.store.snapshot.accounts["cx"]?.refused != nil)
        XCTAssertEqual(r.rowText, CCPoolPaneModel.signedOutText)
        assertNoSecrets(r)
    }

    // QA R2010 F1: a 401 whose keeper refresh FAILS (auth host 5xx or hang-up) says nothing about the login: no answer, no
    // refused stamp, and the keeper still POSTs on a later trigger. Old: the 401 stood and the account was marked refused.
    private func assertFailedRefreshKeepsTheAccount(_ r: Rig, file: StaticString = #filePath, line: UInt = #line) async throws {
        r.usage.set { $0.accepted = [K.accessNew] }
        let report = await r.refresh()
        XCTAssertEqual(r.auth.posts.count, 1, file: file, line: line)
        XCTAssertTrue(report.rows.first?.status == nil, "could not answer, not a 401", file: file, line: line)
        XCTAssertTrue(r.store.snapshot.accounts["cx"]?.refused == nil, "not refused", file: file, line: line)
        XCTAssertNotEqual(r.rowText, CCPoolPaneModel.signedOutText, file: file, line: line)
        XCTAssertTrue(r.log.lines.contains { $0.contains("login refresh failed") }, "\(r.log.lines)", file: file, line: line)
        // The keeper is not shut off: a working auth host gets another POST.
        r.auth.set { $0.status = 200; $0.drop = false }
        let id = try XCTUnwrap(r.store.snapshot.accounts["cx"]?.id)
        let outcome = await withCheckedContinuation { c in r.keeper.refresh(id: id, stale: K.freshAccess) { c.resume(returning: $0) } }
        XCTAssertEqual(r.auth.posts.count, 2, file: file, line: line)
        if case .refreshed = outcome {} else { XCTFail("\(outcome)", file: file, line: line) }
        assertNoSecrets(r, file: file, line: line)
    }

    func test401ThenAuthHost5xxIsNotASignOut() async throws {
        let r = try rig()
        r.auth.set { $0.status = 500; $0.body = Data("{}".utf8) }
        try await assertFailedRefreshKeepsTheAccount(r)
    }

    func test401ThenAuthHostHangUpIsNotASignOut() async throws {
        let r = try rig()
        r.auth.set { $0.drop = true }
        try await assertFailedRefreshKeepsTheAccount(r)
    }

    // A login that is due is refreshed through the keeper before the probe, never by the probe itself.
    func testDueLoginIsRefreshedFirstThroughTheKeeper() async throws {
        let r = try rig(item: K.item(access: K.jwt(exp: Date().timeIntervalSince1970 + 60, tag: "due")))
        let report = await r.refresh()
        XCTAssertEqual(r.auth.posts.count, 1)
        XCTAssertEqual(r.usage.bearers, [K.accessNew])
        XCTAssertEqual(report.rows.first?.status, 200)
    }

    // Under XCTest the production usage host is never dialled.
    func testProductionUsageHostIsRefusedUnderTest() async {
        let p = await CCPoolCodexHarness().probe(token: K.item(access: K.freshAccess), base: CCPoolCodexHarness.upstream, timeout: 1)
        XCTAssertTrue(p == nil)
    }
}

/// The pane: Refresh runs both harnesses; rows grouped by harness with headers only when both exist.
@MainActor
final class CCPoolCodexUsagePaneTests: XCTestCase {
    typealias K = CodexTokenKeeperTests

    func testRefreshRunsBothHarnessesAndGroupsRows() async throws {
        let usage = CodexFakeUsage()
        let usageServer = try CCPoolFakeServer { h, b in usage.reply(h, b) }
        addTeardownBlock { usageServer.stop() }
        let r = try ccpoolPaneRig(codexUpstream: URL(string: "http://127.0.0.1:\(usageServer.port)/backend-api/codex")!)
        try r.add(["a"])
        try r.store.addAccount(label: "cx", token: K.item(access: K.freshAccess), secrets: r.secrets)
        r.store.mutate { $0.accounts["cx"]?.harness = CCPoolCodexHarness.id; $0.accounts["cx"]?.kind = CCPoolCodexHarness.chatgptKind }

        let before = r.model.rowGroups.last?.rows.first { $0.label == "cx" }
        XCTAssertEqual(before?.usageText, "no usage seen yet", "a Codex row with no answer yet reads as Claude's does")

        await r.model.refreshUsage()?.value
        XCTAssertEqual(usage.paths, ["/backend-api/wham/usage"])
        XCTAssertEqual(r.store.usageSample("a")?.util["five_hour"], 0.42)
        XCTAssertEqual(r.store.usageSample("cx")?.util["five_hour"], 0.12)
        XCTAssertEqual(r.store.usageSample("cx")?.util["seven_day"], 0.34)

        let groups = r.model.rowGroups
        XCTAssertEqual(groups.map(\.title), ["Claude", "Codex"])
        XCTAssertEqual(groups.map { $0.rows.map(\.label) }, [["a"], ["cx"]])
        let cx = try XCTUnwrap(groups.last?.rows.first)
        XCTAssertTrue(cx.usageText.hasPrefix("5h 12%"), cx.usageText)
        XCTAssertTrue(cx.usageText.contains("week 34%"), cx.usageText)
        XCTAssertEqual(cx.credits, "credits $5.00")
        XCTAssertTrue(CCPoolPane.rowSubtitle(cx).hasSuffix(" · credits $5.00"), CCPoolPane.rowSubtitle(cx))
        XCTAssertTrue(groups.first?.rows.first?.credits == nil)
        for l in r.log.lines where l.contains(K.freshAccess) { XCTFail("a token reached the log: \(l.prefix(40))…") }
    }

    func testOneHarnessHasNoHeader() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["a", "b"])
        XCTAssertEqual(r.model.rowGroups.count, 1)
        XCTAssertTrue(r.model.rowGroups.first?.title == nil)
        XCTAssertEqual(r.model.rowGroups.first?.rows.map(\.label), ["a", "b"])

        typealias Row = CCPoolPaneModel.Row
        let codexOnly = [Row(label: "x", state: .ready, stateText: "ready", usageText: "", harness: CCPoolCodexHarness.id)]
        XCTAssertEqual(CCPoolPaneModel.groups(codexOnly).map(\.title), [nil])
        let mixed = codexOnly + [Row(label: "c", state: .ready, stateText: "ready", usageText: ""),
                                 Row(label: "o", state: .ready, stateText: "ready", usageText: "", harness: "other")]
        XCTAssertEqual(CCPoolPaneModel.groups(mixed).map(\.title), ["Claude", "Codex", "Other"])
        XCTAssertEqual(CCPoolPaneModel.groups(mixed).map { $0.rows.map(\.label) }, [["c"], ["x"], ["o"]])
    }
}
