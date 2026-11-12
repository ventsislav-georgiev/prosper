import Darwin
import XCTest
@testable import ProsperApp

final class CCPoolTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double
    init(_ t: Double) { self.t = t }
    var now: Double { lock.withLock { t } }
    func advance(_ s: Double) { lock.withLock { t += s } }
}

/// A pane model over a temp store, memory secrets, a fake upstream on an ephemeral loopback port
/// and a scratch defaults suite. The service is not started unless a test starts it.
struct CCPoolPaneRig {
    let anthropic: CCPoolFakeAnthropic
    let up: CCPoolFakeServer
    let clock: CCPoolTestClock
    let store: CCPoolStore
    let secrets: CCPoolMemorySecrets
    let service: CCPoolService
    let log: CCPoolCapturingLogger
    let defaults: UserDefaults
    let vault: URL
    let model: CCPoolPaneModel
    let trashed: CCPoolTrashRecorder

    var base: URL { URL(string: "http://127.0.0.1:\(up.port)")! }

    @MainActor
    func add(_ labels: [String]) throws {
        for l in labels { try store.addAccount(label: l, token: "tok-\(l)", secrets: secrets) }
        model.objectWillChange.send()
    }
}

final class CCPoolTrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func record(_ u: URL) { lock.withLock { _urls.append(u) } }
}

extension XCTestCase {
    /// 1_800_000_000 is Fri 08:00 UTC.
    @MainActor
    func ccpoolPaneRig(probeBase: URL? = nil, t0: Double = 1_800_000_000) throws -> CCPoolPaneRig {
        let anthropic = CCPoolFakeAnthropic()
        let up = try CCPoolFakeServer { h, b in anthropic.reply(h, b) }
        XCTAssertNotEqual(up.port, 0)
        let clock = CCPoolTestClock(t0)
        let log = CCPoolCapturingLogger()
        let dir = tempDir()
        let store = CCPoolStore(directory: dir.appendingPathComponent("ccpool"), clock: { clock.now }, logger: log)
        let secrets = CCPoolMemorySecrets()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        addTeardownBlock { service.stop(); up.stop() }
        let defaults = scratchDefaults("ccpool-pane")
        let trashed = CCPoolTrashRecorder()
        let vault = dir.appendingPathComponent("old").appendingPathComponent(CCPoolMigration.vaultFileName)
        let model = CCPoolPaneModel(store: store, secrets: secrets, service: service, logger: log, defaults: defaults,
                                    clock: { clock.now }, timeZone: TimeZone(identifier: "UTC")!,
                                    probeBase: probeBase ?? cfg.upstream, vaultURL: vault,
                                    trash: { trashed.record($0) })
        return CCPoolPaneRig(anthropic: anthropic, up: up, clock: clock, store: store, secrets: secrets, service: service,
                             log: log, defaults: defaults, vault: vault, model: model, trashed: trashed)
    }
}

/// #871 P2a: the pane model. Real queues, a fake upstream; never the production port or upstream.
@MainActor
final class CCPoolPaneModelTests: XCTestCase {
    private let t0 = 1_800_000_000

    private func row(_ m: CCPoolPaneModel, _ label: String) -> CCPoolPaneModel.Row? { m.rows.first { $0.label == label } }

    func testCCPoolPaneEveryRowState() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["a", "b", "c", "d", "e", "f", "g"])
        r.store.mutate { st in
            st.current = "a"
            st.bench("c", claim: "five_hour", until: t0 + 3600, now: Double(t0))
            st.bench("c", claim: "seven_day", until: t0 + 18000, now: Double(t0))
            st.hold("d", hours: 5, now: Double(t0))
        }
        r.anthropic.set { $0.reject = ["tok-e": 401, "tok-g": 403] }
        try r.secrets.remove(id: try XCTUnwrap(r.store.snapshot.accounts["f"]?.id))   // f's probe cannot answer
        await r.model.refreshUsage().value

        let want: [(String, CCPoolPaneModel.RowState, String)] = [
            ("a", .active, "active"),
            ("b", .ready, "ready"),
            ("c", .limited(until: t0 + 3600, claims: ["five_hour", "seven_day"]), "limited until Fri 09:00 (5h, week)"),
            ("d", .held(until: t0 + 18000), "held until Fri 13:00"),
            ("e", .rejected, "token rejected"),
            ("f", .unverified, "not verified"),
            ("g", .rejected, "token rejected"),
        ]
        XCTAssertEqual(r.model.rows.map(\.label), want.map(\.0))
        for (label, state, text) in want {
            XCTAssertEqual(row(r.model, label)?.state, state, label)
            XCTAssertEqual(row(r.model, label)?.stateText, text, label)
        }
        XCTAssertEqual(r.model.report?.rows.first { $0.label == "e" }?.status, 401)
        XCTAssertEqual(r.model.report?.rows.first { $0.label == "g" }?.status, 403)
        XCTAssertNotNil(r.model.poolText)

        // Limits lapse with the clock; a later good probe clears "rejected".
        r.clock.advance(18001)
        XCTAssertEqual(row(r.model, "c")?.state, .ready)
        XCTAssertEqual(row(r.model, "d")?.state, .ready)
        r.anthropic.set { $0.reject = [:] }
        await r.model.refreshUsage().value
        XCTAssertEqual(row(r.model, "e")?.state, .ready)
        XCTAssertEqual(row(r.model, "f")?.state, .unverified, "still no token: never healthy")
    }

    func testCCPoolPaneUtilisationAndItsAge() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["a", "b"])
        XCTAssertEqual(row(r.model, "a")?.usageText, "no usage seen yet")
        r.anthropic.set { $0.usage = ["tok-a": 0.5] }
        await r.model.refreshUsage().value
        XCTAssertEqual(row(r.model, "a")?.usageText, "5h 50% · week 10% · fable 34% · just now")
        r.clock.advance(180)
        XCTAssertEqual(row(r.model, "a")?.usageText, "5h 50% · week 10% · fable 34% · 3 min ago")
        r.clock.advance(2 * 3600)
        XCTAssertTrue(row(r.model, "b")?.usageText.hasSuffix("2 h ago") ?? false)
        XCTAssertEqual(CCPoolPaneModel.ageText(3 * 86400 + 5), "3 d ago")

        // Proxy traffic updates it too.
        r.store.mutate { $0.current = "b" }
        guard case .running(let port) = r.service.start() else { return XCTFail("\(r.service.status)") }
        r.anthropic.set { $0.usage = ["tok-b": 0.25] }
        XCTAssertEqual(CCPoolTestClient.request(port: port)?.status, 200)
        XCTAssertEqual(row(r.model, "b")?.usageText, "5h 25% · week 10% · fable 34% · just now")
    }

    func testCCPoolPaneRenameAndReorderSurviveAReload() throws {
        let r = try ccpoolPaneRig()
        try r.add(["a", "b", "c"])
        r.store.mutate { $0.current = "b" }
        r.store.recordUsage("b", limits: CCPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.2"]).limits)
        let idB = try XCTUnwrap(r.store.snapshot.accounts["b"]?.id)
        r.model.select("b")
        XCTAssertEqual(r.model.renameDraft, "b")
        r.model.rename("b", to: "  bee ")
        XCTAssertEqual(r.model.selected, "bee")
        r.model.move("c", by: -5)
        r.model.move("bee", by: 1)   // already last: clamped, no change
        XCTAssertEqual(r.model.rows.map(\.label), ["c", "a", "bee"])
        XCTAssertEqual(row(r.model, "bee")?.state, .active, "current follows the rename")
        XCTAssertTrue(row(r.model, "bee")?.usageText.hasPrefix("5h 20%") ?? false, "the usage sample follows")

        r.model.rename("a", to: "c")
        XCTAssertEqual(r.model.notice, CCPoolStoreError.duplicateLabel.description)
        r.model.rename("a", to: "  ")
        XCTAssertEqual(r.model.notice, CCPoolStoreError.emptyLabel.description)
        XCTAssertEqual(r.model.rows.map(\.label), ["c", "a", "bee"])

        let reloaded = CCPoolStore(directory: r.store.directory)
        XCTAssertEqual(reloaded.snapshot.order, ["c", "a", "bee"])
        XCTAssertEqual(reloaded.snapshot.current, "bee")
        XCTAssertEqual(reloaded.snapshot.accounts["bee"]?.id, idB, "rename keeps the opaque Keychain id")
        XCTAssertEqual(try r.secrets.token(id: idB), "tok-b", "and the secret is never rewritten")
        XCTAssertNil(reloaded.snapshot.accounts["b"])
    }

    func testCCPoolPaneHoldAndRelease() throws {
        let r = try ccpoolPaneRig()
        try r.add(["a", "b"])
        r.model.hold("a", hours: 2)
        XCTAssertEqual(row(r.model, "a")?.state, .held(until: t0 + 7200))
        XCTAssertEqual(row(r.model, "a")?.stateText, "held until Fri 10:00")
        XCTAssertEqual(r.store.snapshot.accounts["a"]?.cooldown["five_hour"], t0 + 7200, "a five_hour bench, like the Python hold")
        XCTAssertEqual(CCPoolStore(directory: r.store.directory).snapshot.accounts["a"]?.held, t0 + 7200, "persisted")
        r.model.customHours = "1.5"
        r.model.holdCustom("b")
        XCTAssertEqual(row(r.model, "b")?.state, .held(until: t0 + 5400))
        for bad in ["", "abc", "0", "-2", "inf", "nan"] {
            r.model.customHours = bad
            r.model.holdCustom("a")
            XCTAssertEqual(r.model.notice, "Hold for a number of hours above zero.", bad)
        }
        XCTAssertEqual(row(r.model, "a")?.state, .held(until: t0 + 7200), "a bad value changes nothing")
        r.model.release("a")
        XCTAssertEqual(row(r.model, "a")?.state, .ready)
        XCTAssertEqual(r.store.snapshot.accounts["a"]?.cooldown, [:])
        XCTAssertNil(r.store.snapshot.accounts["a"]?.held)
        // A limit under the hold shows once the hold is released.
        r.store.mutate { $0.bench("b", claim: "seven_day", until: t0 + 86400, now: Double(t0)) }
        XCTAssertEqual(row(r.model, "b")?.state, .held(until: t0 + 5400))
        r.store.mutate { $0.clear("b", claim: "five_hour") }
        XCTAssertEqual(row(r.model, "b")?.state, .limited(until: t0 + 86400, claims: ["seven_day"]))
        XCTAssertEqual(row(r.model, "b")?.stateText, "limited until Sat 08:00 (week)")
    }

    func testCCPoolPaneAddValidatesByOneProbe() async throws {
        let r = try ccpoolPaneRig()
        let m = r.model
        // 401 and 403: rejected, nothing stored.
        for (token, status) in [("tok-bad", 401), ("tok-org", 403)] {
            r.anthropic.set { $0.reject = [token: status] }
            m.labelDraft = "x"
            m.tokenDraft = token
            let task = m.addAccount()
            XCTAssertEqual(m.tokenDraft, "", "the buffer clears on commit, before the probe")
            XCTAssertTrue(m.busy)
            await task.value
            XCTAssertEqual(m.notice, "Token rejected: x was not added.")
            XCTAssertEqual(m.labelDraft, "x", "the label stays for a retry")
            XCTAssertEqual(r.secrets.count, 0)
            XCTAssertEqual(r.store.snapshot.order, [])
        }
        r.anthropic.set { $0.reject = [:] }
        let probes = r.anthropic.get { $0.seen.count }
        m.tokenDraft = "tok-good"
        await m.addAccount().value
        XCTAssertEqual(m.notice, "Added x.")
        XCTAssertEqual(r.anthropic.get { $0.seen.count }, probes + 1, "one probe")
        XCTAssertEqual(row(m, "x")?.state, .ready)
        XCTAssertTrue(row(m, "x")?.usageText.hasPrefix("5h 42%") ?? false)
        XCTAssertEqual(m.labelDraft, "")

        // Duplicate, empty: refused before any probe.
        for (label, token) in [("x", "tok-dup"), ("", "tok-e"), ("y", "  ")] {
            m.labelDraft = label
            m.tokenDraft = token
            await m.addAccount().value
            XCTAssertNotNil(m.notice)
        }
        XCTAssertEqual(r.anthropic.get { $0.seen.count }, probes + 1, "no probe for a refused add")
        XCTAssertEqual(r.secrets.count, 1)
    }

    // A probe that cannot answer is "not verified", never healthy.
    func testCCPoolPaneUnknownProbeIsNotHealthy() async throws {
        let r = try ccpoolPaneRig(probeBase: URL(string: "http://127.0.0.1:9")!)
        r.model.labelDraft = "z"
        r.model.tokenDraft = "tok-z"
        await r.model.addAccount().value
        XCTAssertEqual(r.model.notice, "Added z, not verified: the check could not reach Anthropic.")
        XCTAssertEqual(row(r.model, "z")?.state, .unverified)
        XCTAssertEqual(row(r.model, "z")?.stateText, "not verified")
        XCTAssertEqual(r.secrets.count, 1)
        await r.model.refreshUsage().value
        XCTAssertEqual(row(r.model, "z")?.state, .unverified, "Refresh could not answer either")
        XCTAssertNil(r.model.poolText, "no headroom from nothing")
    }

    func testCCPoolPaneRemoveAsksFirst() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["a", "b"])
        r.store.mutate { $0.current = "a" }
        XCTAssertEqual(r.model.currentText, "a")
        XCTAssertNil(r.model.confirmRemove(), "no confirm pending: nothing happens")
        r.model.select("a")
        r.model.requestRemove("a")
        XCTAssertEqual(r.model.confirmingRemove, "a")
        XCTAssertEqual(r.store.snapshot.order, ["a", "b"], "asking removes nothing")
        r.model.cancelRemove()
        XCTAssertNil(r.model.confirmRemove())
        XCTAssertEqual(r.secrets.count, 2)
        r.model.requestRemove("a")
        await r.model.confirmRemove()?.value
        XCTAssertEqual(r.store.snapshot.order, ["b"])
        XCTAssertEqual(r.secrets.count, 1)
        XCTAssertNil(r.model.selected)
        XCTAssertEqual(r.model.notice, "Removed a.")
        XCTAssertEqual(r.model.currentText, "none yet", "the proxy row names no removed account (P1 follow-up f)")
    }

    func testCCPoolPaneProxyRowToggleAndTerminal() async throws {
        let r = try ccpoolPaneRig()
        let m = r.model
        XCTAssertFalse(m.routeAgentSessions, "default off")
        XCTAssertNil(r.defaults.object(forKey: "ccpoolRouteAgentSessions"))
        XCTAssertEqual(CCPoolPaneModel.routeKey, "ccpoolRouteAgentSessions")
        XCTAssertEqual(m.proxyText, "Stopped")
        XCTAssertEqual(m.routeDisabledReason, "Add an account first.")
        try r.add(["a"])
        XCTAssertEqual(m.routeDisabledReason, "The proxy is not running.")
        XCTAssertEqual(m.currentText, "none yet")

        await m.startProxy().value
        guard case .running(let port) = r.service.status else { return XCTFail("\(r.service.status)") }
        XCTAssertFalse(m.proxyBusy)
        XCTAssertEqual(m.proxyText, "Running on 127.0.0.1:\(port)")
        XCTAssertNil(m.routeDisabledReason)
        m.routeAgentSessions = true
        XCTAssertTrue(r.defaults.bool(forKey: CCPoolPaneModel.routeKey), "written to the injected suite")
        XCTAssertEqual(m.terminalCommand, "ANTHROPIC_BASE_URL=http://127.0.0.1:\(port) claude")
        XCTAssertTrue(m.launcherText.contains("ccpool-launch"))

        // Another ccpool on the configured port: named, with its pid, never touched.
        var cfg = r.service.config
        cfg.port = port
        let second = CCPoolService(config: cfg, store: r.store, secrets: r.secrets, logger: r.log)
        let m2 = CCPoolPaneModel(store: r.store, secrets: r.secrets, service: second, logger: r.log, defaults: r.defaults,
                                 vaultURL: r.vault)
        await m2.startProxy().value
        XCTAssertEqual(second.status, .heldByCCPool(pid: Int(getpid())))
        XCTAssertTrue(m2.proxyText.contains("Another ccpool proxy (pid \(getpid())) holds port \(port)"), m2.proxyText)
        XCTAssertEqual(m2.routeDisabledReason, "The proxy is not running.")

        await m.restartProxy().value
        guard case .running = r.service.status else { return XCTFail("restart: \(r.service.status)") }
        r.service.stop()
        XCTAssertEqual(m.proxyText, "Stopped")
    }

    func testCCPoolPaneUnreachableKeysWarning() throws {
        let r = try ccpoolPaneRig()
        try r.add(["a"])
        XCTAssertNil(r.model.unreachableWarning)
        r.store.mutate { $0.accounts["a"]?.cooldown["mystery_claim"] = t0 + 60 }
        XCTAssertEqual(r.model.unreachableWarning,
                       "Cooldowns on limits no model reads never skip an account: mystery_claim")
    }

    func testCCPoolPaneImportFlow() async throws {
        let r = try ccpoolPaneRig()
        let m = r.model
        XCTAssertFalse(m.importVisible, "no old vault: no import row")
        try FileManager.default.createDirectory(at: r.vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accounts": {"a": {"token": "tok-new-a"}, "n": {"token": "tok-n"}}}"#.utf8).write(to: r.vault)
        XCTAssertTrue(m.importVisible)
        try r.add(["a"])
        await m.beginImport().value
        XCTAssertEqual(m.importPhase, .review(.init(labels: ["a", "n"], conflicts: ["a"])))
        XCTAssertFalse(m.canRunImport, "a conflict needs a choice first")
        XCTAssertNil(m.runImport())
        m.importChoices["a"] = .skip
        XCTAssertTrue(m.canRunImport)
        await m.runImport()?.value
        guard case .imported(let out) = m.importPhase else { return XCTFail("\(m.importPhase)") }
        XCTAssertEqual(out.imported, ["n"])
        XCTAssertEqual(out.skipped, ["a"])
        XCTAssertEqual(CCPoolPaneModel.summary(out), ["Imported: n", "Skipped: a"])
        m.finishImport(trash: false)
        XCTAssertEqual(r.trashed.urls, [], "Keep it moves nothing")
        guard case .finished = m.importPhase else { return XCTFail() }

        m.dismissImport()
        await m.beginImport().value
        m.importChoices["a"] = .replace
        m.importChoices["n"] = .replace
        let oldA = try XCTUnwrap(r.store.snapshot.accounts["a"]?.id)
        guard case .running = r.service.start() else { return XCTFail() }
        r.store.mutate { $0.current = "a" }
        XCTAssertEqual(CCPoolTestClient.request(port: r.model.port)?.status, 200)
        XCTAssertTrue(r.service.upstream.hasSession(accountID: oldA))
        await m.runImport()?.value
        XCTAssertFalse(r.service.upstream.hasSession(accountID: oldA), "a replaced token's session is dropped")
        m.finishImport(trash: true)
        XCTAssertEqual(r.trashed.urls, [r.vault], "the default moves the old vault to the Trash")
        XCTAssertEqual(m.importPhase, .finished("Moved the old vault to the Trash."))

        // A vault that will not parse: says so, imports nothing.
        m.dismissImport()
        try Data("{".utf8).write(to: r.vault)
        await m.beginImport().value
        XCTAssertEqual(m.importPhase, .idle)
        XCTAssertEqual(m.notice, CCPoolMigration.ReadError.notJSON.description)
    }

    // QA #739 F1 (follow-up A1): no account, no routing, whatever the stored choice; the toggle
    // shows off and says why, and the stored choice comes back with an account.
    func testCCPoolRoutingNeedsAnAccount() async throws {
        let r = try ccpoolPaneRig()
        let m = r.model
        guard case .running(let port) = r.service.start() else { return XCTFail("\(r.service.status)") }
        let base = CCPool.baseURL(port: port)
        m.routeAgentSessions = true
        for on in [true, false] {
            XCTAssertTrue(r.service.sessionEnv(command: ["claude"], on: on).isEmpty, "zero accounts, on: \(on)")
            XCTAssertTrue(r.service.sessionEnv(command: ["headroom"], on: on).isEmpty, "zero accounts, on: \(on)")
        }
        XCTAssertFalse(r.service.routable)
        XCTAssertFalse(m.routeToggleShown, "shown off")
        XCTAssertEqual(m.routeDisabledReason, "Add an account first.")
        XCTAssertTrue(r.defaults.bool(forKey: CCPoolPaneModel.routeKey), "the stored choice is not overwritten")

        try r.add(["a"])
        XCTAssertTrue(r.service.routable)
        XCTAssertTrue(m.routeToggleShown, "an account restores the stored choice")
        XCTAssertNil(m.routeDisabledReason)
        XCTAssertEqual(r.service.sessionEnv(command: ["claude"], on: m.routeAgentSessions).set["ANTHROPIC_BASE_URL"], base)

        // The last account removed: the next session is not routed.
        m.requestRemove("a")
        await m.confirmRemove()?.value
        XCTAssertEqual(r.store.snapshot.order, [])
        XCTAssertTrue(r.service.sessionEnv(command: ["claude"], on: m.routeAgentSessions).isEmpty, "the next session is not routed")
        XCTAssertFalse(r.service.routable)
        XCTAssertFalse(m.routeToggleShown)
        XCTAssertEqual(m.routeDisabledReason, "Add an account first.")
        XCTAssertTrue(m.routeAgentSessions, "the stored choice survives")

        try r.add(["b"])
        XCTAssertTrue(m.routeToggleShown)
        XCTAssertEqual(r.service.sessionEnv(command: ["claude"], on: m.routeAgentSessions).set["ANTHROPIC_BASE_URL"], base)
        m.routeAgentSessions = false
        XCTAssertFalse(m.routeToggleShown)
        XCTAssertTrue(r.service.sessionEnv(command: ["claude"], on: m.routeAgentSessions).isEmpty, "off stays off")
        r.service.stop()
        XCTAssertTrue(r.service.sessionEnv(command: ["claude"], on: true).isEmpty, "stopped: never routed")
        XCTAssertFalse(r.service.routable)
    }

    // QA #739 F2 (A2): a Replace import drops the old token's verdict and usage from its row.
    func testCCPoolReplaceImportDropsTheOldVerdictAndUsage() async throws {
        let r = try ccpoolPaneRig()
        let m = r.model
        try r.add(["a", "b", "c"])
        r.anthropic.set {
            $0.reject = ["tok-a": 401]
            $0.usage = ["tok-b": 0.5]
        }
        try r.secrets.remove(id: try XCTUnwrap(r.store.snapshot.accounts["c"]?.id))
        await m.refreshUsage().value
        XCTAssertEqual(row(m, "a")?.state, .rejected)
        XCTAssertTrue(row(m, "b")?.usageText.hasPrefix("5h 50%") ?? false, row(m, "b")?.usageText ?? "")
        XCTAssertEqual(row(m, "c")?.state, .unverified)

        try FileManager.default.createDirectory(at: r.vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accounts": {"a": {"token": "tok-a2"}, "b": {"token": "tok-b2"}, "c": {"token": "tok-c2"}}}"#.utf8).write(to: r.vault)
        await m.beginImport().value
        m.importChoices = ["a": .replace, "b": .replace, "c": .replace]
        await m.runImport()?.value
        guard case .imported(let o) = m.importPhase else { return XCTFail("\(m.importPhase)") }
        XCTAssertEqual(o.replaced, ["a", "b", "c"])
        XCTAssertEqual(row(m, "a")?.state, .ready, "the old token's rejection is gone")
        XCTAssertEqual(row(m, "a")?.stateText, "ready")
        XCTAssertEqual(row(m, "c")?.state, .ready, "the old token's \"not verified\" is gone")
        XCTAssertNil(r.store.usageSample("b"), "the old token's usage is dropped at the replace")
        XCTAssertEqual(row(m, "b")?.usageText, "no usage seen yet")
    }

    // Review carry 1 (A5): a Keychain delete that fails after the state was written names the account.
    func testCCPoolRemoveSaysWhenTheKeychainItemStays() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["a", "b"])
        r.secrets.refuseRemove = true
        r.model.requestRemove("a")
        await r.model.confirmRemove()?.value
        XCTAssertEqual(r.store.snapshot.order, ["b"], "the account is gone")
        XCTAssertEqual(r.secrets.count, 2, "its item stayed")
        XCTAssertEqual(r.model.notice, "Removed a, but its Keychain item could not be deleted; it stays in the Keychain, listed nowhere.")
        XCTAssertTrue(r.log.lines.contains("a: removed; its Keychain item could not be deleted"), "\(r.log.lines)")
        for t in [r.model.notice ?? ""] + r.log.lines { XCTAssertFalse(t.contains("tok-"), t) }
        r.secrets.refuseRemove = false
        r.model.requestRemove("b")
        await r.model.confirmRemove()?.value
        XCTAssertEqual(r.model.notice, "Removed b.")
        XCTAssertEqual(r.secrets.count, 1, "only the orphan is left")
    }

    // QA #739 INFO-10 (B6): an open Remove confirm does nothing while the model is busy.
    func testCCPoolRemoveConfirmWaitsWhileBusy() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["a"])
        r.model.requestRemove("a")
        r.model.labelDraft = "x"
        r.model.tokenDraft = "tok-x"
        let add = r.model.addAccount()
        XCTAssertTrue(r.model.busy)
        XCTAssertNil(r.model.confirmRemove(), "busy: nothing is removed")
        XCTAssertEqual(r.model.confirmingRemove, "a", "the confirm stays open")
        await add.value
        await r.model.confirmRemove()?.value
        XCTAssertEqual(r.store.snapshot.order, ["x"])
    }

    // QA #739 INFO-11 (B7): "not running" carries the service's fixed reason.
    func testCCPoolPaneSaysWhyTheProxyIsNotRunning() async throws {
        let r = try ccpoolPaneRig()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0   // the production upstream: refused under XCTest, a fixed reason
        let svc = CCPoolService(config: cfg, store: r.store, secrets: r.secrets, logger: r.log)
        let m = CCPoolPaneModel(store: r.store, secrets: r.secrets, service: svc, logger: r.log, defaults: r.defaults,
                                probeBase: r.base, vaultURL: r.vault)
        await m.startProxy().value
        XCTAssertEqual(m.proxyText, "Not running: ccpool: refusing the production upstream under XCTest")
        guard case .running = r.service.start() else { return XCTFail("\(r.service.status)") }
        r.service.listenerLost(.posix(.ENETDOWN))
        XCTAssertEqual(r.model.proxyText, "Not running: " + CCPoolService.reasonLost)
        XCTAssertFalse(r.model.proxyText.contains("POSIX"), "no raw system error text")
    }

    // QA #739 INFO-3 (B1): a vault that is a link is never trashed; the pane names its target.
    func testCCPoolVaultLinkIsNeverTrashed() async throws {
        let r = try ccpoolPaneRig()
        let m = r.model
        let target = tempDir().appendingPathComponent("elsewhere.json")
        try Data(#"{"accounts": {"a": {"token": "tok-a"}}}"#.utf8).write(to: target)
        try FileManager.default.createDirectory(at: r.vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: r.vault, withDestinationURL: target)
        XCTAssertTrue(m.importVisible)
        await m.beginImport().value
        await m.runImport()?.value
        guard case .imported(let o) = m.importPhase else { return XCTFail("\(m.importPhase)") }
        XCTAssertEqual(o.imported, ["a"])
        XCTAssertTrue(o.allHeld)
        XCTAssertEqual(o.vaultLink, target.path)
        let why = "The old vault is a link to \(target.path). Prosper moves nothing: delete that file yourself once you no longer need it."
        XCTAssertEqual(m.trashBlockedReason, why)
        m.finishImport(trash: true)
        XCTAssertEqual(r.trashed.urls, [], "neither the link nor its target goes to the Trash")
        XCTAssertEqual(m.importPhase, .finished(why))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: r.vault.path))
    }

    // QA #739 INFO-2 (B2): the Trash is offered only when every vault token is in the pool.
    func testCCPoolTrashOnlyWhenEveryTokenIsHeld() async throws {
        let r = try ccpoolPaneRig()
        let m = r.model
        try r.add(["a", "b"])
        try FileManager.default.createDirectory(at: r.vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accounts": {"a": {"token": "tok-a"}, "b": {"token": "tok-other"}, "n": {}}}"#.utf8).write(to: r.vault)
        await m.beginImport().value
        m.importChoices = ["a": .skip, "b": .skip]
        await m.runImport()?.value
        guard case .imported(let o) = m.importPhase else { return XCTFail("\(m.importPhase)") }
        XCTAssertEqual(o.skipped, ["a", "b"])
        XCTAssertEqual(o.notHeld, ["b"], "b keeps another token; a holds the same one")
        XCTAssertEqual(o.failures.map(\.label), ["n"])
        XCTAssertFalse(o.allHeld)
        let why = "Not every account in the old vault is in the pool, so it stays where it is."
        XCTAssertEqual(m.trashBlockedReason, why)
        m.finishImport(trash: true)
        XCTAssertEqual(r.trashed.urls, [], "an import with failures keeps the vault")
        XCTAssertEqual(m.importPhase, .finished(why))

        // Failures only (every kept label holds the same token): still kept.
        m.dismissImport()
        try Data(#"{"accounts": {"a": {"token": "tok-a"}, "n": {}}}"#.utf8).write(to: r.vault)
        await m.beginImport().value
        m.importChoices = ["a": .skip]
        await m.runImport()?.value
        XCTAssertEqual(m.trashBlockedReason, why)

        // A different token left alone (no failure): still kept.
        m.dismissImport()
        try Data(#"{"accounts": {"b": {"token": "tok-other"}}}"#.utf8).write(to: r.vault)
        await m.beginImport().value
        m.importChoices = ["b": .skip]
        await m.runImport()?.value
        XCTAssertEqual(m.trashBlockedReason, why)

        // Same token skipped, the rest imported: offered, and the default trashes it.
        m.dismissImport()
        try Data(#"{"accounts": {"a": {"token": " tok-a\n"}, "c": {"token": "tok-c"}}}"#.utf8).write(to: r.vault)
        await m.beginImport().value
        m.importChoices = ["a": .skip]
        await m.runImport()?.value
        guard case .imported(let ok) = m.importPhase else { return XCTFail("\(m.importPhase)") }
        XCTAssertTrue(ok.allHeld, "\(ok)")
        XCTAssertNil(m.trashBlockedReason)
        m.finishImport(trash: true)
        XCTAssertEqual(r.trashed.urls, [r.vault])
        XCTAssertEqual(m.importPhase, .finished("Moved the old vault to the Trash."))
    }

    // Errata C7 on real queues: an add (probe + Keychain + state), a proxy request and a refresh
    // all finish while the main thread is blocked. Only the final `finish*` hop needs main.
    func testCCPoolPaneModelWorkRunsWithMainBlocked() async throws {
        XCTAssertTrue(Thread.isMainThread)
        let r = try ccpoolPaneRig()
        try r.add(["one"])
        guard case .running(let port) = r.service.start() else { return XCTFail("\(r.service.status)") }
        r.log.forgetMain()

        r.model.labelDraft = "two"
        r.model.tokenDraft = "tok-two"
        let add = r.model.addAccount()
        XCTAssertTrue(blockMain(seconds: 10) { r.store.read { $0.accounts["two"] != nil } }, "the add finished with main blocked")

        r.store.mutate { $0.current = "two" }
        let resp = CCPoolTestClient.request(port: port)   // blocks main for the whole request
        XCTAssertEqual(resp?.status, 200)

        let seen = r.anthropic.get { $0.seen.count }
        let refresh = r.model.refreshUsage()
        XCTAssertTrue(blockMain(seconds: 10) { r.anthropic.get { $0.seen.count } >= seen + 2 && r.store.usageSample("one") != nil },
                      "the refresh probed every account with main blocked")
        let log = r.log, service = r.service
        let binds = log.lines.filter { $0.contains("proxy listening") }.count
        let restart = r.model.restartProxy()
        XCTAssertTrue(blockMain(seconds: 10) {
            guard case .running = service.status else { return false }
            return log.lines.filter { $0.contains("proxy listening") }.count > binds
        }, "restart finished with main blocked")
        await add.value
        await refresh.value
        await restart.value
        XCTAssertEqual(r.model.notice, "Added two.")
        XCTAssertNotNil(r.model.report)
        XCTAssertFalse(r.log.onMain, "no ccpool log line came from the main thread")
        XCTAssertFalse(r.anthropic.get { $0.onMain })
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
}
