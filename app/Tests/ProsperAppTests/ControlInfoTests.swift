import Foundation
import Sparkle
import StatsCore
import XCTest
@testable import ProsperApp

/// #1859: notify, stats.get, diagnostics, updates.check. Every source is a seam (clock, snapshot, text, probe); the
/// notice goes to a recorder, so nothing is shown and no Sparkle updater is built.
@MainActor
final class ControlInfoTests: XCTestCase {
    private var shown: [String] = []
    private var saved: (now: () -> Date, snap: @MainActor () -> StatsSnapshot, text: @MainActor () -> String,
                        probe: @MainActor () async -> AppUpdater.Probe?)?
    private var clock = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        saved = (ControlInfo.now, ControlInfo.snapshot, ControlInfo.diagnosticsText, ControlInfo.probe)
        ControlInfo.resetNotify()
        ControlInfo.resetProbe()
        ControlInfo.now = { [unowned self] in clock }
        Preferences.defaults.removeObject(forKey: Preferences.agentControlKey)
    }

    override func tearDown() async throws {
        if let s = saved { (ControlInfo.now, ControlInfo.snapshot, ControlInfo.diagnosticsText, ControlInfo.probe) = (s.now, s.snap, s.text, s.probe) }
        ControlInfo.resetNotify()
        ControlInfo.resetProbe()
        Preferences.defaults.removeObject(forKey: Preferences.agentControlKey)
    }

    private func call(_ cmd: String, _ args: [String: ControlJSON] = [:]) async -> ControlReply {
        var r = ControlRegistry()
        let changes = ControlChanges()
        changes.present = { [weak self] text, _ in self?.shown.append(text) }
        r.changes = changes
        ControlRegistry.registerInfo(&r)
        return await r.reply(to: try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
    }

    private func obj(_ r: ControlReply) -> [String: ControlJSON] {
        guard case .object(let o)? = r.result else { return [:] }
        return o
    }

    // MARK: - notify

    func testNotifyShowsACleanedNoticeAndIsNotUndoable() async {
        let r = await call("notify", ["title": .string("Build\u{202E} done"), "body": .string("all\u{0007} green")])
        XCTAssertTrue(r.ok, "\(r)")
        XCTAssertEqual(shown, ["Agent notified: Build done: all green"])
    }

    func testNotifyIsRefusedWhileTheSettingsSwitchIsOff() async {
        Preferences.agentControlEnabled = false
        let r = await call("notify", ["title": .string("x"), "body": .string("y")])
        XCTAssertEqual(r.error, ControlChanges.offError)
        XCTAssertTrue(shown.isEmpty)
    }

    func testNotifyRefusesAnEmptyTitleAfterCleaning() async {
        let r = await call("notify", ["title": .string("\u{200B}  "), "body": .string("y")])
        XCTAssertEqual(r.error, "argument 'title' is empty")
        XCTAssertTrue(shown.isEmpty)
    }

    func testNotifyIsLimitedToOnePerGap() async {
        let first = await call("notify", ["title": .string("a"), "body": .string("")])
        XCTAssertTrue(first.ok)
        clock = clock.addingTimeInterval(ControlInfo.notifyGap - 1)
        let early = await call("notify", ["title": .string("b"), "body": .string("")])
        XCTAssertEqual(early.error, "notify is limited to one per 10 seconds")
        clock = clock.addingTimeInterval(1)
        let later = await call("notify", ["title": .string("c"), "body": .string("")])
        XCTAssertTrue(later.ok)
        XCTAssertEqual(shown, ["Agent notified: a", "Agent notified: c"])
    }

    /// n179: a body that cleans to nothing leaves the title alone (an uncleaned body would add ": ").
    func testNotifyBodyOfOnlyAnUnseenCharacterIsDropped() async {
        let r = await call("notify", ["title": .string("t"), "body": .string("\u{200B}")])
        XCTAssertTrue(r.ok, "\(r)")
        XCTAssertEqual(shown, ["Agent notified: t"])
    }

    func testNotifyBoundsTitleAndBody() async {
        _ = await call("notify", ["title": .string(String(repeating: "t", count: 500)), "body": .string(String(repeating: "b", count: 500))])
        XCTAssertTrue((shown.last?.count ?? 999) <= "Agent notified: ".count + ControlChanges.summaryMax)
    }

    // MARK: - stats.get

    func testStatsReportsOnlySampledModulesAndNeverANonFiniteNumber() async {
        var s = StatsSnapshot()
        s.cpu = CPUSample(total: 0.25, performance: .nan, efficiency: .nan, system: 0.1, user: 0.15, idle: 0.75, perCore: [], loadAverage: [1, .nan, 3], uptimeSeconds: 60)
        s.gpu = GPUSample(utilization: .infinity, name: "Example GPU", usedMemory: 0)
        s.network = NetworkSample(uploadBytesPerSec: 1, downloadBytesPerSec: 2, totalUploaded: 3, totalDownloaded: 4,
                                  interfaceName: "en0", ipv4: "192.0.2.1", ssid: "ExampleNet")
        ControlInfo.snapshot = { s }
        let r = await call("stats.get")
        XCTAssertTrue(r.ok, "\(r)")
        let o = obj(r)
        XCTAssertEqual(Set(o.keys), ["cpu", "gpu", "network"])
        XCTAssertEqual(r.line.isEmpty, false)
        XCTAssertTrue(String(decoding: r.line, as: UTF8.self).contains("\"loadAverage\":[1,null,3]"))
        XCTAssertEqual(obj(ControlReply(ok: true, result: o["gpu"], error: nil))["utilization"], .null)
        let wire = String(decoding: r.line, as: UTF8.self)
        XCTAssertFalse(wire.contains("ExampleNet") || wire.contains("192.0.2.1") || wire.contains("en0"))
    }

    func testStatsWithNothingSampledIsAnEmptyObject() async {
        ControlInfo.snapshot = { StatsSnapshot() }
        let r = await call("stats.get")
        XCTAssertEqual(r, ControlReply(ok: true, result: .object([:]), error: nil))
    }

    // MARK: - diagnostics

    func testDiagnosticsRemovesSecretShapedText() async {
        ControlInfo.diagnosticsText = {
            "Prosper 1.0\n  1.2.3: bad key sk-abcdef123456789 in /Users/example/proj\n  \(String(repeating: "A", count: 40))\nTiers: specific=1"
        }
        let r = await call("diagnostics")
        guard case .string(let t)? = obj(r)["text"] else { return XCTFail("\(r)") }
        XCTAssertFalse(t.contains("sk-abc") || t.contains("/Users/example") || t.contains("AAAAAAAA"), t)
        XCTAssertTrue(t.contains("Prosper 1.0") && t.contains("Tiers: specific=1") && t.contains("[removed]"), t)
    }

    func testDiagnosticsKeepsAnOrdinaryReport() {
        let text = AgentDiagnostics.text(prosper: "1.0", dch: "1.23.0", version: "2.0.1", counts: [:], errors: ["2.0.1: unknown block"])
        XCTAssertEqual(ControlInfo.scrub(text), text)
    }

    // MARK: - updates.check

    func testUpdatesCheckAnswersFoundUpToDateAndFailed() async {
        ControlInfo.probe = { .found("9.9.9") }
        var o = obj(await call("updates.check"))
        XCTAssertEqual(o["updateAvailable"], .bool(true))
        XCTAssertEqual(o["latest"], .string("9.9.9"))
        ControlInfo.resetProbe()
        ControlInfo.probe = { .upToDate }
        o = obj(await call("updates.check"))
        XCTAssertEqual(o["updateAvailable"], .bool(false))
        XCTAssertTrue(o["latest"] == nil)
        ControlInfo.resetProbe()
        ControlInfo.probe = { .failed("offline") }
        var r = await call("updates.check")
        XCTAssertEqual(r.error, "update check failed: offline")
        ControlInfo.probe = { nil }
        r = await call("updates.check")
        XCTAssertEqual(r.error, "the updater is not available or a check is already running")
    }

    /// The gap: a second check within 10 minutes answers the kept result without a fetch; a failure is not kept.
    func testUpdatesCheckReusesTheLastAnswerWithinTheGap() async {
        var fetches = 0
        ControlInfo.probe = { fetches += 1; return .found("9.9.9") }
        var o = obj(await call("updates.check"))
        XCTAssertEqual(o["cached"], .bool(false))
        clock = clock.addingTimeInterval(ControlInfo.probeGap - 1)
        o = obj(await call("updates.check"))
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(o["cached"], .bool(true))
        XCTAssertEqual(o["latest"], .string("9.9.9"))
        clock = clock.addingTimeInterval(1)
        o = obj(await call("updates.check"))
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(o["cached"], .bool(false))
        ControlInfo.resetProbe()
        ControlInfo.probe = { fetches += 1; return .failed("offline") }
        _ = await call("updates.check")
        let again = await call("updates.check")
        XCTAssertEqual(fetches, 4)
        XCTAssertEqual(again.error, "update check failed: offline")
    }

    // MARK: - Sparkle cycle -> probe answer (n178)

    private let noUpdate = NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: [NSLocalizedDescriptionKey: "You're up to date!"])
    private let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                  userInfo: [NSLocalizedDescriptionKey: "offline"])

    /// Sparkle 2.10's up-to-date cycle: didNotFindUpdate, then didAbortWithError(SUNoUpdateError).
    func testNotFoundThenTheNoUpdateAbortIsUpToDate() {
        XCTAssertEqual(AppUpdater.probe(from: [.notFound, .aborted(noUpdate)]), .upToDate)
    }

    func testTheNoUpdateAbortAloneIsUpToDate() {
        XCTAssertEqual(AppUpdater.probe(from: [.aborted(noUpdate)]), .upToDate)
    }

    func testFoundThenAnyAbortKeepsFound() {
        XCTAssertEqual(AppUpdater.probe(from: [.found("2.0"), .aborted(noUpdate)]), .found("2.0"))
        XCTAssertEqual(AppUpdater.probe(from: [.found("2.0"), .aborted(offline)]), .found("2.0"))
    }

    func testARealAbortAloneIsFailed() {
        XCTAssertEqual(AppUpdater.probe(from: [.aborted(offline)]), .failed("offline"))
        XCTAssertTrue(AppUpdater.isNoUpdate(noUpdate) && !AppUpdater.isNoUpdate(offline))
    }

    /// Under XCTest no Sparkle updater exists: the real seam answers nil and starts nothing.
    func testTheRealProbeIsInertUnderTests() async {
        let p = await AppUpdater.shared.probeForUpdate()
        XCTAssertTrue(p == nil)
    }

    func testOnlyNotifyChangesState() async {
        var r = ControlRegistry()
        ControlRegistry.registerInfo(&r)
        XCTAssertEqual(r.commands.filter { $0.value.mutates }.keys.sorted(), ["notify"])
        XCTAssertEqual(r.commands.keys.sorted(), ["diagnostics", "notify", "stats.get", "updates.check"])
    }
}
