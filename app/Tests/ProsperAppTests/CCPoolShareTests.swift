import XCTest
@testable import ProsperApp

// #1677 (QA R1670 n20): the pane's "Move off an account at" below 100 % is a soft preference for new placements. A
// reply at that share never benches the account, every account over it still serves (200, not 429), a pinned session
// stays, real exhaustion stays at 1.0. Fakes only: a stub upstream on an ephemeral loopback port, the store in tempDir().

/// The stub upstream: a 200 to every request; a token given limits answers with those rate-limit headers.
private final class ShareUpstream: @unchecked Sendable {
    private let lock = NSLock()
    private var _tokens: [String] = []
    private var limits: [String: [(String, String)]] = [:]
    var tokens: [String] { lock.withLock { _tokens } }
    /// 5h and 7d utilization (fractions) for `token`'s replies, both resetting at `reset`.
    func set(_ token: String, five: String, week: String, reset: Int) {
        let p = CCPoolCore.headerPrefix
        lock.withLock {
            limits[token] = [(p + "5h-status", "allowed"), (p + "5h-utilization", five), (p + "5h-reset", "\(reset)"),
                             (p + "7d-status", "allowed"), (p + "7d-utilization", week), (p + "7d-reset", "\(reset)")]
        }
    }
    func reply(_ head: CCPoolRequestHead) -> CCPoolFakeServer.Reply {
        let token = String((head.header("authorization") ?? "").dropFirst("Bearer ".count))
        let extra = lock.withLock { () -> [(String, String)] in _tokens.append(token); return limits[token] ?? [] }
        return .respond(200, [("content-type", "application/json")] + extra, Data(#"{"type":"message","content":[]}"#.utf8))
    }
}

final class CCPoolShareTests: XCTestCase {
    let orgA = "Example Org A", orgB = "Example Org B"

    private struct Rig {
        let up: ShareUpstream
        let store: CCPoolStore
        let service: CCPoolService
        let log: ThrottleLog
        let port: UInt16
        var now: Double { store.now }
        func setShare(_ v: Double) { service.config.exhaustedThreshold = v }
        func post(_ sid: String) -> CCPoolClientResponse? {
            CCPoolTestClient.request(port: port, headers: [("content-type", "application/json"), ("X-Claude-Code-Session-Id", sid)],
                                     body: throttleWork)
        }
        /// The token a new or pinned session's request went with, when it was answered 200.
        func via(_ sid: String) -> String? {
            let n = up.tokens.count
            guard post(sid)?.status == 200, up.tokens.count > n else { return nil }
            return up.tokens.last
        }
        /// A's learned row 12 $/pt, B's 1 $/pt, each with its running max `util` in a live window.
        func sample(_ label: String, util: Double) {
            let cap = label == "Example Org A" ? 3.0 : 0.25
            let reset = now + 3600
            store.mutate { st in
                guard let id = st.accounts[label]?.id else { return }
                st.capacity[id] = CCPoolCapacityState(reset: reset, maxUtilization: util, pendingDollars: 0, dollars: cap, points: 0.25)
            }
        }
        func eventKinds() -> [String] {
            service.eventRecord.flush()
            let dir = service.eventRecord.directory
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.flatMap { n -> [String] in
                let text = (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)) ?? ""
                return text.split(separator: "\n").compactMap { line in
                    (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["ev"] as? String
                }
            }
        }
    }

    private func rig(share: Double) throws -> Rig {
        let up = ShareUpstream()
        let server = try CCPoolFakeServer { h, _ in up.reply(h) }
        XCTAssertNotEqual(server.port, 0)
        let log = ThrottleLog()
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), logger: log)
        let secrets = CCPoolMemorySecrets()
        for l in [orgA, orgB] { _ = try store.addAccount(label: l, token: throttleTokens[l] ?? "", secrets: secrets) }
        store.mutate { $0.current = orgA }
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(server.port)")!
        cfg.timeout = 10
        cfg.exhaustedThreshold = share
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); server.stop() }
        return Rig(up: up, store: store, service: service, log: log, port: p)
    }

    /// Share 0.8, A at 0.85 (12 $/pt: score 1.8), B at 0.3 (1 $/pt: 0.7). At 1.0 the score takes A; at 0.8 the new
    /// session starts on B, with one "over share" note naming A. Raising and lowering the setting changes the next
    /// placement only (no residue): B then holds one session (0.35), A one after its placement (0.9).
    func testNewSessionStartsOnTheAccountUnderTheShareAndTheSettingLeavesNoResidue() throws {
        let r = try rig(share: 0.8)
        r.sample(orgA, util: 0.85)
        r.sample(orgB, util: 0.3)
        XCTAssertEqual(r.via("sess-example-1"), "tok-b")
        XCTAssertEqual(r.log.lines.filter { $0.contains("over share") },
                       ["Example Org A: over share; new conversation placed on Example Org B"])
        r.setShare(1.0)
        XCTAssertEqual(r.via("sess-example-2"), "tok-a", "at 1.0 the score decides, as before #1670")
        r.setShare(0.8)
        XCTAssertEqual(r.via("sess-example-3"), "tok-b")
        r.setShare(1.0)
        XCTAssertEqual(r.via("sess-example-4"), "tok-a")
        XCTAssertEqual(r.log.lines.filter { $0.contains("over share") }.count, 2, "one note per placement the share moved")
        XCTAssertFalse(r.log.lines.contains { $0.contains("now full") })
        XCTAssertEqual(r.store.snapshot.accounts.values.map(\.cooldown), [[:], [:]], "nothing benched")
    }

    /// The QA case: A's reply says 85 % and 90 % with the share at 0.8. Before #1677 that benched A until the reset
    /// ("now full", a retire row); now A is untouched and its pinned session stays on it while B is under the share.
    /// A real 100 % still retires it (exhaustion is fixed at 1.0).
    func testAccountOverTheShareIsNeverBenchedAndItsPinStays() throws {
        let r = try rig(share: 0.8)
        let reset = Int(r.now) + 3 * 86400
        r.up.set("tok-a", five: "0.85", week: "0.9", reset: reset)
        XCTAssertEqual(r.via("sess-example-1"), "tok-a", "no samples yet: the order places it on A")
        r.sample(orgB, util: 0.3)
        for round in 1...3 { XCTAssertEqual(r.via("sess-example-1"), "tok-a", "the pin stays: \(round)") }
        XCTAssertEqual(r.store.snapshot.accounts[orgA]?.cooldown, [:], "never benched for the share")
        XCTAssertEqual(r.store.snapshot.pins.mapValues(\.account), ["sess-example-1/": orgA])
        XCTAssertFalse(r.log.lines.contains { $0.contains("now full") })
        XCTAssertFalse(r.eventKinds().contains { $0 == "bench" || $0 == "retire" }, "no bench or retire row")
        r.up.set("tok-a", five: "1.0", week: "0.9", reset: reset)
        XCTAssertEqual(r.via("sess-example-1"), "tok-a")
        XCTAssertEqual(r.store.snapshot.accounts[orgA]?.cooldown, [CCPoolCore.fiveHour: reset], "100 % retires as before")
        XCTAssertTrue(r.log.lines.contains { $0.contains("Example Org A: now full on five_hour") })
    }

    /// Every account past the share: placed as today and served (200), never the 429 all-benched with capacity left.
    func testEveryAccountOverTheShareStillServes() throws {
        let r = try rig(share: 0.8)
        let reset = Int(r.now) + 3 * 86400
        r.up.set("tok-a", five: "0.85", week: "0.9", reset: reset)
        r.up.set("tok-b", five: "0.9", week: "0.95", reset: reset)
        for n in 1...4 { XCTAssertEqual(r.post("sess-example-\(n)")?.status, 200, "session \(n)") }
        XCTAssertEqual(Set(r.up.tokens), ["tok-a", "tok-b"], "both still take new sessions")
        XCTAssertEqual(r.store.snapshot.accounts.values.map(\.cooldown), [[:], [:]])
        XCTAssertFalse(r.log.lines.contains { $0.contains("every account is benched") })
    }
}
