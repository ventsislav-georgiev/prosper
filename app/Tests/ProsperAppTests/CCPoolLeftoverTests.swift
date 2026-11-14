import XCTest
@testable import ProsperApp

private final class LeftoverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

/// Holds the first start between its listener's .ready and its publish (the afterReady seam).
private final class LeftoverStartGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = true
    private var _port: UInt16 = 0
    var port: UInt16 { lock.withLock { _port } }

    func hold(_ port: UInt16) {
        guard lock.withLock({ () -> Bool in
            defer { armed = false }
            _port = armed ? port : _port
            return armed
        }) else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 10)   // bounded: the row releases it long before
    }
}

/// #1190: leftovers of the P2b-1 read. quit() stops on the life cycle's queue, a bench follows the
/// account (its Keychain id) and not its label, the store's change hook, and AppDelegate's three hooks.
/// Temp directories, memory secrets, ephemeral loopback ports and fake upstreams only; the app is
/// never launched and its delegate methods never run.
@MainActor
final class CCPoolLeftoverTests: XCTestCase {
    private let dead = URL(string: "http://127.0.0.1:9")!

    private func runtime(_ tweak: (inout CCPoolServiceConfig) -> Void = { _ in }) -> CCPoolRuntime {
        let dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = dead
        tweak(&cfg)
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old").appendingPathComponent(CCPoolMigration.vaultFileName),
                               defaults: scratchDefaults("ccpool-leftover"), probeBase: dead,
                               logger: CCPoolCapturingLogger(), trash: { _ in })
        let service = rt.service
        addTeardownBlock { service.stop() }
        return rt
    }

    /// Waits on the main actor (other tasks run) until `cond` holds, up to 10 s.
    private func eventually(_ what: String, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(cond(), what)
    }

    // INFO-1: a start in flight when the app quits. Its listener is published after quit's wait ran
    // out; the stop quit queued behind it still closes it, and nothing binds again.
    func testCCPoolQuitStopsAStartStillInFlight() async throws {
        let gate = LeftoverStartGate()
        let rt = runtime { $0.afterReady = { l in gate.hold(l.port?.rawValue ?? 0) } }
        try rt.store.addAccount(label: "Example Org", token: "tok-example", secrets: rt.secrets)
        let start = rt.setLive(true)
        // The start runs on the life cycle's queue, never on main: waiting here is safe (bounded).
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 10), .success, "the start reached its listener")
        let begun = Date()
        rt.quit(timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(begun), 5, "quit waits at most its bound on main")
        XCTAssertEqual(rt.service.status, .stopped, "nothing was published yet")
        gate.release.signal()
        await start?.value
        await eventually("the stop queued by quit closes the late listener") { rt.service.status == .stopped }
        let port = gate.port
        XCTAssertNotEqual(port, 0)
        await eventually("nothing listens after quit") { CCPoolPortProbe.probe(port: port, timeout: 1) == .free }
        await rt.model.reconcileProxy()?.value
        XCTAssertEqual(rt.service.status, .stopped, "no event after quit binds again")
        XCTAssertTrue(rt.lifecycle.quit(timeout: 5), "with nothing in flight the queued stop runs within the bound")
    }

    // INFO-2: the label "Example Org" moves to another account while a request of the first is in
    // flight. The first one's 429 benches the first one (renamed), never the account that carries
    // the label now, which still serves.
    nonisolated func testCCPoolBenchFollowsTheAccountNotItsLabel() throws {
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "Example Org", token: "tok-first", secrets: secrets)
        try store.addAccount(label: "spare", token: "tok-spare", secrets: secrets)
        let anthropic = CCPoolFakeAnthropic()
        anthropic.set { $0.spent = ["tok-first"] }
        let moved = LeftoverCounter()
        let up = try CCPoolFakeServer { h, b in
            if moved.count == 0, h.header("authorization")?.contains("tok-first") == true {
                moved.bump()
                try? store.renameAccount("Example Org", to: "Example Org (old)")
                try? store.addAccount(label: "Example Org", token: "tok-second", secrets: secrets)
            }
            return anthropic.reply(h, b)
        }
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: CCPoolCapturingLogger())
        defer { service.stop(); up.stop() }
        guard case .running(let port) = service.start(), port != 0 else { return XCTFail("\(service.status)") }

        store.mutate { $0.current = "Example Org" }
        XCTAssertEqual(CCPoolTestClient.request(port: port)?.status, 200, "rotated past the spent account")
        XCTAssertEqual(moved.count, 1, "the label moved while the request was in flight")
        let snap = store.snapshot
        XCTAssertNotNil(snap.accounts["Example Org (old)"]?.cooldown[CCPoolCore.fiveHour], "the account that answered 429 is benched")
        XCTAssertEqual(snap.accounts["Example Org"]?.cooldown, [:], "the account that carries the label now is not")

        anthropic.clearSeen()
        store.mutate { $0.current = "Example Org" }
        XCTAssertEqual(CCPoolTestClient.request(port: port)?.status, 200)
        XCTAssertEqual(anthropic.get { $0.seen }, ["Bearer tok-second"], "it still serves")
    }

    /// #1205 (R1190-1): a Refresh whose probe is answered by a fake upstream on an ephemeral port that, while
    /// answering `token`, runs `move` on the store (a rename, a remove and add).
    nonisolated private func refreshWhileMoving(_ store: CCPoolStore, _ secrets: CCPoolSecrets, _ anthropic: CCPoolFakeAnthropic,
                                                token: String, _ move: @escaping @Sendable () -> Void) async throws -> CCPoolUsage.Report {
        let moved = LeftoverCounter()
        let up = try CCPoolFakeServer { h, b in
            if moved.count == 0, h.header("authorization")?.contains(token) == true {
                moved.bump()
                move()
            }
            return anthropic.reply(h, b)
        }
        defer { up.stop() }
        let report = await CCPoolUsage.refresh(store: store, secrets: secrets, base: URL(string: "http://127.0.0.1:\(up.port)")!,
                                               logger: CCPoolCapturingLogger())
        XCTAssertEqual(moved.count, 1, "the label moved while the probe was in flight")
        return report
    }

    // #1205 (R1190-1), mutant r1: the Refresh probe's verdict (bench, resets, usage sample, report row) follows the
    // account probed, renamed during the probe, and never lands on the account that took its label.
    nonisolated func testCCPoolRefreshVerdictFollowsTheAccountNotItsLabel() async throws {
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "Example Org", token: "tok-first", secrets: secrets)
        let anthropic = CCPoolFakeAnthropic()
        anthropic.set { $0.usage = ["tok-first": 0.995, "tok-second": 0.10] }
        let report = try await refreshWhileMoving(store, secrets, anthropic, token: "tok-first") {
            try? store.renameAccount("Example Org", to: "Example Org (old)")
            try? store.addAccount(label: "Example Org", token: "tok-second", secrets: secrets)
        }
        XCTAssertEqual(report.rows.map(\.label), ["Example Org (old)"], "the row names the account probed, as it is called now")
        let snap = store.snapshot
        XCTAssertNotNil(snap.accounts["Example Org (old)"]?.cooldown[CCPoolCore.fiveHour], "the account probed is benched")
        XCTAssertNotNil(snap.accounts["Example Org (old)"]?.reset[CCPoolCore.fiveHour], "and its rollover recorded")
        XCTAssertEqual(snap.accounts["Example Org"]?.cooldown, [:], "the account that took the label is not benched")
        XCTAssertEqual(snap.accounts["Example Org"]?.reset, [:], "nor given its resets")
        XCTAssertTrue(store.usageSample("Example Org") == nil, "nor its usage sample")
        XCTAssertTrue(store.usageSample("Example Org (old)") != nil)
    }

    // #1205 (R1190-1), mutant g1: an account removed during the probe gets nothing (it is gone), and neither does the
    // new account that took its label: no bench, no resets, no usage, and no row (the pane flags accounts by a row's
    // label). Once with a spent answer, once with a rejected token.
    nonisolated func testCCPoolRefreshOfAnAccountRemovedMidProbeWritesNothing() async throws {
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        let anthropic = CCPoolFakeAnthropic()
        anthropic.set { $0.usage = ["tok-first": 0.995, "tok-second": 0.10, "tok-third": 0.10]; $0.reject = ["tok-rejected": 401] }
        for (old, new) in [("tok-first", "tok-second"), ("tok-rejected", "tok-third")] {
            try store.addAccount(label: "Example Org", token: old, secrets: secrets)
            let report = try await refreshWhileMoving(store, secrets, anthropic, token: old) {
                _ = try? store.removeAccount(label: "Example Org", secrets: secrets)
                try? store.addAccount(label: "Example Org", token: new, secrets: secrets)
            }
            XCTAssertEqual(report.rows.count, 0, "\(old): a gone account has no row, the new holder of its label none either")
            XCTAssertEqual(store.snapshot.accounts["Example Org"]?.cooldown, [:], "\(old): the new holder is not benched")
            XCTAssertEqual(store.snapshot.accounts["Example Org"]?.reset, [:], "\(old): nor given resets")
            XCTAssertTrue(store.usageSample("Example Org") == nil, "\(old): nor a usage sample")
            _ = try store.removeAccount(label: "Example Org", secrets: secrets)
        }
    }

    // INFO-5 (a), mutant v3: the store's change hook (the pane's republish) runs once per change that
    // took, never for a body that changed nothing, and never for an account change whose write failed
    // and was undone.
    nonisolated func testCCPoolStoreHookRunsOncePerChangeThatTook() throws {
        final class WriteSwitch: @unchecked Sendable {
            private let lock = NSLock()
            private var on = true
            var writes: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
        }
        let sw = WriteSwitch()
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"),
                                writer: { data, url in sw.writes && CCPoolStore.atomicWrite(data, url) })
        let hooks = LeftoverCounter()
        store.onChange = { hooks.bump() }

        XCTAssertTrue(store.mutateOrUndo { $0.order.append("x"); $0.accounts["x"] = .init(id: "id-x") }.saved)
        XCTAssertEqual(hooks.count, 1, "a saved account change republishes once")
        _ = store.mutateOrUndo { _ in }
        XCTAssertEqual(hooks.count, 1, "no change, no republish")
        sw.writes = false
        XCTAssertFalse(store.mutateOrUndo { $0.accounts["y"] = .init(id: "id-y") }.saved)
        XCTAssertEqual(hooks.count, 1, "a failed write is undone and republishes nothing")
        XCTAssertTrue(store.snapshot.accounts["y"] == nil, "undone")
        sw.writes = true

        store.mutate { $0.current = "x" }
        XCTAssertEqual(hooks.count, 2, "a rotation change republishes once")
        store.mutate { $0.current = "x" }
        XCTAssertEqual(hooks.count, 2, "the same value is no change")
        sw.writes = false
        store.mutate { $0.current = nil }
        XCTAssertEqual(hooks.count, 3, "rotation state stays in memory when its write fails, and is shown")
    }

    // INFO-5 (b): the push AppDelegate makes, on a slot the row owns. Off builds nothing; the first
    // live push builds once and starts; later pushes reuse it; off stops it.
    func testCCPoolPushBuildsOnceAndFollowsTheFlag() async throws {
        let builds = LeftoverCounter()
        let made = runtime()
        try made.store.addAccount(label: "Example Org", token: "tok-example", secrets: made.secrets)
        var slot: CCPoolRuntime?
        let build: () -> CCPoolRuntime? = { builds.bump(); return made }

        let none = CCPoolRuntime.push(false, into: &slot, build: build)
        XCTAssertTrue(none == nil, "off with nothing built: no task")
        XCTAssertTrue(slot == nil)
        XCTAssertEqual(builds.count, 0, "a disabled extension builds nothing")
        await CCPoolRuntime.push(true, into: &slot, build: build)?.value
        XCTAssertTrue(slot === made)
        guard case .running = made.service.status else { return XCTFail("live with an account: \(made.service.status)") }
        await CCPoolRuntime.push(true, into: &slot, build: build)?.value
        XCTAssertEqual(builds.count, 1, "built once")
        await CCPoolRuntime.push(false, into: &slot, build: build)?.value
        XCTAssertEqual(made.service.status, .stopped, "a disable stops it")
        XCTAssertTrue(slot === made, "kept for the life of the process")
    }

    // INFO-5 (b): which AppDelegate hook calls what, read from the source (the delegate never runs here).
    nonisolated func testCCPoolAppDelegateHooks() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AppDelegate.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        /// From `marker` to the first line that closes at `indent` spaces.
        func body(_ marker: String, indent: Int) -> String {
            guard let start = text.range(of: marker) else { return "" }
            let close = "\n" + String(repeating: " ", count: indent) + "}\n"
            let end = text.range(of: close, range: start.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
            return String(text[start.lowerBound..<end])
        }
        let launch = body("func applicationDidFinishLaunching(", indent: 4)
        let enable = body("extensions.onEnabledChanged = {", indent: 8)
        let quit = body("func applicationWillTerminate(", indent: 4)
        XCTAssertTrue(launch.contains("CCPoolRuntime.setExtensionLive(ccpoolExtLive)"), "launch pushes the live flag")
        XCTAssertTrue(launch.contains(enable) && !enable.isEmpty, "the enable callback is set at launch")
        XCTAssertTrue(enable.contains("CCPoolRuntime.setExtensionLive(self.ccpoolExtLive)"), "enable and disable push it")
        XCTAssertTrue(quit.contains("CCPoolRuntime.shared?.quit()"), "quit stops the proxy")
        XCTAssertEqual(text.components(separatedBy: "CCPoolRuntime.").count - 1, 3, "no other ccpool hook")
        XCTAssertTrue(text.contains(#"record(id: "com.prosper.ccpool")?.isLive ?? false"#), "live = enabled and trusted")
    }
}
