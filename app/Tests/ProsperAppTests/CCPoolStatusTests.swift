import XCTest
@testable import ProsperApp

/// #915 (spec 3.5): host.ccpool.status() is read-only and label-level: running, port, current and each account's
/// label, state and until. Never a token, a Keychain id, a header value or a usage figure. A temp store, memory
/// secrets and an ephemeral loopback port; the upstream is 127.0.0.1:9 and is never dialled.
final class CCPoolStatusTests: XCTestCase {
    private let now: Double = 1_700_000_000
    /// The only keys the answer may carry, at any depth.
    private static let allowed: Set<String> = ["running", "port", "current", "accounts", "label", "state", "until"]

    private func rig() throws -> (service: CCPoolService, store: CCPoolStore, secrets: CCPoolMemorySecrets) {
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: CCPoolCapturingLogger())
        addTeardownBlock { service.stop() }
        for label in ["alpha", "beta", "gamma", "delta"] {
            _ = try store.addAccount(label: label, token: "tok-\(label)", secrets: secrets)
        }
        let now = self.now
        store.mutate { st in
            _ = st.bench("beta", claim: CCPoolCore.fiveHour, until: Int(now) + 3600, now: now)
            _ = st.hold("gamma", hours: 2, now: now)
            st.accounts["delta"]?.refused = Int(now) - 60
        }
        return (service, store, secrets)
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func keys(_ value: Any) -> Set<String> {
        if let d = value as? [String: Any] { return d.reduce(into: Set(d.keys)) { $0.formUnion(keys($1.value)) } }
        if let a = value as? [Any] { return a.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } }
        return []
    }

    private func rows(_ obj: [String: Any]) -> [String] {
        (obj["accounts"] as? [[String: Any]] ?? []).map { row in
            let until = (row["until"] as? Int).map(String.init) ?? "-"
            return "\(row["label"] as? String ?? "?"):\(row["state"] as? String ?? "?"):\(until)"
        }
    }

    // Stopped, then running, a benched and a held account with until, a refused one, current nil then set.
    func testStatusStoppedRunningBenchedAndCurrent() throws {
        let r = try rig()
        let stopped = try decode(r.service.statusJSON(now: now))
        XCTAssertEqual(stopped["running"] as? Bool, false)
        XCTAssertEqual(stopped["port"] as? Int, 0, "stopped: the configured port")
        XCTAssertTrue(stopped["current"] == nil, "no current account: the key is absent (Lua nil)")
        // #1838: alphabetical, never the stored order.
        XCTAssertEqual(rows(stopped), ["alpha:ready:-", "beta:limited:\(Int(now) + 3600)",
                                       "delta:refused:-", "gamma:held:\(Int(now) + 7200)"])

        guard case .running(let port) = r.service.start() else { return XCTFail("\(r.service.status)") }
        r.store.mutate { $0.current = "alpha" }
        let running = try decode(r.service.statusJSON(now: now))
        XCTAssertEqual(running["running"] as? Bool, true)
        XCTAssertEqual(running["port"] as? Int, Int(port), "running: the bound port")
        XCTAssertEqual(running["current"] as? String, "alpha")
        XCTAssertEqual(rows(running).first, "alpha:active:-")

        r.service.stop()
        XCTAssertEqual(try decode(r.service.statusJSON(now: now))["running"] as? Bool, false)
    }

    // Literal key list, set equality: every key the answer can carry is present here, and none other.
    func testStatusCarriesNoKeyOutsideTheLabelLevelSet() throws {
        let r = try rig()
        _ = r.service.start()
        r.store.mutate { $0.current = "alpha" }
        let json = r.service.statusJSON(now: now)
        XCTAssertEqual(keys(try decode(json)), Self.allowed)
        let ids = r.store.snapshot.accounts.values.map(\.id)
        XCTAssertEqual(ids.count, 4)
        for needle in ids + ["tok-alpha", "tok-beta", "tok-gamma", "tok-delta"] {
            XCTAssertFalse(json.contains(needle), "the answer names a Keychain id or a token")
        }
    }

    // Nothing built (the extension never enabled): not running, no accounts, the off answer's own key set.
    func testStatusWithNoRuntime() throws {
        let obj = try decode(CCPoolService.statusJSON(running: false, port: 7, state: nil, now: now))
        XCTAssertEqual(obj["running"] as? Bool, false)
        XCTAssertEqual(obj["port"] as? Int, 7)
        XCTAssertEqual((obj["accounts"] as? [Any])?.count, 0)
        XCTAssertTrue(keys(obj).isSubset(of: Self.allowed))
        XCTAssertTrue(keys(try decode(ExtensionPoolStatus.off)).isSubset(of: Self.allowed))
    }

    // The app's push registers the answer for host.ccpool.status(); under XCTest nothing is built, so it is "off".
    @MainActor
    func testExtensionLivePushRegistersTheOffAnswerUnderTest() throws {
        let before = ExtensionPoolStatus.source
        defer { ExtensionPoolStatus.source = before }
        ExtensionPoolStatus.source = nil
        CCPoolRuntime.setExtensionLive(false)
        XCTAssertTrue(CCPoolRuntime.shared == nil)
        let obj = try decode(ExtensionPoolStatus.json())
        XCTAssertEqual(obj["running"] as? Bool, false)
        XCTAssertEqual(obj["port"] as? Int, Int(CCPoolService.defaultPort), "the production port, named, never dialled")
        XCTAssertEqual((obj["accounts"] as? [Any])?.count, 0)
    }
}
