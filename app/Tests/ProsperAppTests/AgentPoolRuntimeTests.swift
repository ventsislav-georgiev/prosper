import Combine
import Darwin
import XCTest
@testable import ProsperApp

/// #871 P2b-1: the bundled ccpool extension and the one owner of the proxy's life cycle. Each test
/// builds its own runtime on a temp directory, memory secrets, an ephemeral port and a fake
/// upstream; the app's instance (`AgentPoolRuntime.shared`) is never built under XCTest.
@MainActor
final class AgentPoolRuntimeTests: XCTestCase {
    private var extensionsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    @MainActor
    private struct Rig {
        let runtime: AgentPoolRuntime
        let log: AgentPoolCapturingLogger
        let vault: URL
        var service: AgentPoolService { runtime.service }
        var model: AgentPoolPaneModel { runtime.model }
    }

    private func rig() throws -> Rig {
        let anthropic = AgentPoolFakeAnthropic()
        let up = try AgentPoolFakeServer { h, b in anthropic.reply(h, b) }
        let dir = tempDir()
        var cfg = AgentPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        let log = AgentPoolCapturingLogger()
        let vault = dir.appendingPathComponent("old").appendingPathComponent(AgentPoolVaultImport.vaultFileName)
        let rt = AgentPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: AgentPoolMemorySecrets(), config: cfg,
                               vaultURL: vault, defaults: scratchDefaults("ccpool-runtime"), probeBase: cfg.upstream,
                               logger: log, trash: { _ in })
        let service = rt.service
        addTeardownBlock { service.stop(); up.stop() }
        return Rig(runtime: rt, log: log, vault: vault)
    }

    private var stopped: AgentPoolService.Status { .stopped }

    private func port(_ r: Rig) -> UInt16? {
        if case .running(let p) = r.service.status { return p }
        return nil
    }

    /// Waits on the main actor (other tasks run) until `cond` holds, up to 10 s.
    private func eventually(_ what: String, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(cond(), what)
    }

    /// Spins the main thread WITHOUT running its run loop or the main actor's queue.
    private func blockMain(seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            usleep(20_000)
        }
        return done()
    }

    // Item 1: the shipped manifest; opt-in, so it is not live on a fresh install.
    func testAgentPoolExtensionManifestIsOptIn() throws {
        let dir = extensionsDir.appendingPathComponent("ccpool", isDirectory: true)
        let loaded = try ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: "0.0.0")
        let ext = loaded.manifest.extension
        XCTAssertEqual(ext.id, "com.prosper.agentpool")
        XCTAssertEqual(ext.isSystem, true)
        XCTAssertEqual(ext.defaultDisabled, true)
        XCTAssertEqual(ext.version, "1.2.0")
        XCTAssertEqual(loaded.manifest.contributes?.allSettingsSections.map(\.id), ["agentpool"])

        let system = tempDir("ccpool-ext").appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir, to: system.appendingPathComponent("ccpool", isDirectory: true))
        let reg = GateFixture(systemDir: system, userDir: system.deletingLastPathComponent().appendingPathComponent("user"),
                              defaults: scratchDefaults("ccpool-ext")).registry()
        let rec = try XCTUnwrap(reg.record(id: "com.prosper.agentpool"))
        XCTAssertFalse(rec.enabled)
        XCTAssertFalse(rec.isLive, "a fresh install runs no proxy")
    }

    // Launch and enable (mutants h1, h2): the proxy runs only while live AND the pool lists an account.
    func testAgentPoolProxyRunsOnlyWhileLiveWithAnAccount() async throws {
        let r = try rig()
        await r.runtime.setLive(true)?.value
        XCTAssertEqual(r.service.status, stopped, "live with no account: no listener")
        await r.runtime.setLive(false)?.value
        try r.runtime.store.addAccount(label: "alpha", token: "tok-alpha", secrets: r.runtime.secrets)
        await r.runtime.setLive(false)?.value
        XCTAssertEqual(r.service.status, stopped, "an account but not live: no listener")
        await r.runtime.setLive(true)?.value
        XCTAssertNotNil(port(r), "launch or enable with an account starts it: \(r.service.status)")
    }

    // Disable (mutant h10): the listener goes and the port is free again.
    func testAgentPoolDisableFreesThePort() async throws {
        let r = try rig()
        try r.runtime.store.addAccount(label: "alpha", token: "tok-alpha", secrets: r.runtime.secrets)
        await r.runtime.setLive(true)?.value
        let p = try XCTUnwrap(port(r), "\(r.service.status)")
        XCTAssertNotEqual(p, AgentPoolService.defaultPort)
        await r.runtime.setLive(false)?.value
        XCTAssertEqual(r.service.status, stopped)
        // The cancelled listener's socket closes asynchronously.
        await eventually("nothing listens after a disable") { AgentPoolPortProbe.probe(port: p, timeout: 1) == .free }
    }

    // Account added and removed through the pane (mutants h4, h3).
    func testAgentPoolFirstAccountStartsAndLastRemovalStops() async throws {
        let r = try rig()
        await r.runtime.setLive(true)?.value
        XCTAssertEqual(r.service.status, stopped)
        r.model.labelDraft = "alpha"
        r.model.tokenDraft = "tok-alpha"
        await r.model.addAccount().value
        XCTAssertEqual(r.model.notice, "Added alpha.")
        await eventually("the first account starts the proxy") { port(r) != nil }
        r.model.requestRemove("alpha")
        await r.model.confirmRemove()?.value
        XCTAssertFalse(r.runtime.store.hasAccounts)
        await eventually("the last removal stops the proxy") { r.service.status == stopped }
    }

    // Import finished: an import into an empty pool starts the proxy.
    func testAgentPoolImportIntoAnEmptyPoolStarts() async throws {
        let r = try rig()
        await r.runtime.setLive(true)?.value
        try FileManager.default.createDirectory(at: r.vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accounts": {"alpha": {"token": "tok-alpha"}}}"#.utf8).write(to: r.vault)
        await r.model.beginImport().value
        await r.model.runImport()?.value
        guard case .imported(let o) = r.model.importPhase else { return XCTFail("\(r.model.importPhase)") }
        XCTAssertEqual(o.imported, ["alpha"])
        await eventually("the import starts the proxy") { port(r) != nil }
    }

    // Restart click and quit.
    func testAgentPoolRestartRebindsAndQuitStops() async throws {
        let r = try rig()
        try r.runtime.store.addAccount(label: "alpha", token: "tok-alpha", secrets: r.runtime.secrets)
        await r.runtime.setLive(true)?.value
        XCTAssertNotNil(port(r))
        let binds = r.log.lines.filter { $0.contains("proxy listening") }.count
        let before = port(r)
        await r.model.restartProxy().value
        XCTAssertNotNil(port(r), "\(r.service.status)")
        XCTAssertEqual(port(r), before, "#1672: the listener is kept, same port")
        XCTAssertEqual(r.log.lines.filter { $0.contains("proxy listening") }.count, binds, "#1672: no new bind")
        XCTAssertEqual(r.log.lines.filter { $0.contains("proxy restarted; listener kept") }.count, 1)
        let p = try XCTUnwrap(port(r))
        r.runtime.quit()
        XCTAssertEqual(r.service.status, stopped)
        await eventually("nothing listens after quit") { AgentPoolPortProbe.probe(port: p, timeout: 1) == .free }
        await r.model.reconcileProxy()?.value
        XCTAssertEqual(r.service.status, stopped, "no queued event binds again after quit")
    }

    // Mutant h7, errata C7: the start an enable drives runs off main, on real queues, with main blocked.
    func testAgentPoolStartNeverRunsOnMain() async throws {
        let r = try rig()
        try r.runtime.store.addAccount(label: "alpha", token: "tok-alpha", secrets: r.runtime.secrets)
        r.log.forgetMain()
        let task = r.runtime.setLive(true)
        let service = r.service
        XCTAssertTrue(blockMain(seconds: 10) {
            if case .running = service.status { return true }
            return false
        }, "the start finished with main blocked")
        await task?.value
        XCTAssertTrue(r.log.lines.contains { $0.contains("proxy listening") })
        XCTAssertFalse(r.log.onMain, "no start step logged on main")
    }

    // Review carry b: a store change made off main reaches the pane at once, not on the 30 s tick.
    func testAgentPoolStoreChangeRepublishesThePane() async throws {
        let r = try rig()
        try r.runtime.store.addAccount(label: "alpha", token: "tok-alpha", secrets: r.runtime.secrets)
        try r.runtime.store.addAccount(label: "beta", token: "tok-beta", secrets: r.runtime.secrets)
        let changed = expectation(description: "objectWillChange")
        changed.assertForOverFulfill = false
        let store = r.runtime.store
        // Only the change made below counts (the adds above republish too, a little later).
        let sub = r.model.objectWillChange.sink { _ in if store.read({ $0.current }) == "beta" { changed.fulfill() } }
        Task.detached { store.mutate { $0.current = "beta" } }
        await fulfillment(of: [changed], timeout: 5)
        sub.cancel()
    }

    // Review carry e: an outside string the pane shows loses invisible characters and is capped.
    func testAgentPoolShownDropsInvisiblesAndCaps() {
        XCTAssertEqual(AgentPoolStore.shown("../x\u{202E}y\u{7}z\u{200B}"), "../xyz")
        let long = AgentPoolStore.shown(String(repeating: "a", count: 500))
        XCTAssertEqual(long.count, 160)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(AgentPoolStore.shown("short"), "short")
    }
}
