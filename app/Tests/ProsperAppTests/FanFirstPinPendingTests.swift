import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

/// Entry 1041, item 1: a first-fan Manual engage that times out while an earlier preset is pending (manual on) and
/// then lands in the helper. Fakes only: the fan connection is `FanCommitSaveTests.HeldConn` (keeps the engage's
/// reply until the row sends it; no Mach service, no helper, no SMC), the registration is a seam (no SMAppService),
/// the identity throwaway factory returns nil, the recovery lifecycle's arm is a no-op (no real reclaim timer, no
/// sleep observer), the popup is never built. Manual, the targets and the hold (off) are in the scratch defaults.
@MainActor
final class FanFirstPinPendingTests: XCTestCase {
    typealias HeldConn = FanCommitSaveTests.HeldConn

    private var saved: (manual: Bool, hold: Bool, targets: [Int: Double], pending: Bool, refused: Int?) =
        (false, false, [:], false, nil)
    private var savedRegistration: (@Sendable () -> LidSleepHelper.RegisterOutcome)?
    private var savedFactory: (() -> NSXPCConnection?)?

    override func setUp() async throws {
        saved = (Preferences.fanManualEnabled, Preferences.fanHoldUnlock, Preferences.fanTargets,
                 FanControlHelper.presetPending, FanControlHelper.lastRefusedFan)
        Preferences.fanHoldUnlock = false
        Preferences.fanManualEnabled = false
        savedRegistration = LidSleepHelper.registration
        LidSleepHelper.registration = { .enabled }
        savedFactory = FanControlHelper.makeIdentityConnection
        FanControlHelper.makeIdentityConnection = { nil }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()   // no verdict: the Bool engage, which HeldConn can hold
        FanControlHelper.lateLandings = 0
        FanControlHelper.lastRefusedFan = nil     // fan 0 is the first fan
    }

    override func tearDown() async throws {
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()
        FanControlHelper.lateLandings = 0
        FanControlHelper.presetPending = saved.pending
        FanControlHelper.lastRefusedFan = saved.refused
        if let savedRegistration { LidSleepHelper.registration = savedRegistration }
        if let savedFactory { FanControlHelper.makeIdentityConnection = savedFactory }
        Preferences.fanManualEnabled = saved.manual
        Preferences.fanHoldUnlock = saved.hold
        Preferences.fanTargets = saved.targets
    }

    /// Entry 1041 item 1, the timeline of report section A.4: with an earlier preset pending, a Manual click (the
    /// popup's and the phone's shared engageManual) whose first fan gets no reply in time saves nothing and hands
    /// every fan back (reset 1); when the helper then pins that fan anyway (the held reply, sent on a background queue
    /// as XPC does), the late hook hands it back too (reset 2), with manual on: no fan stays at the click's speed.
    /// The earlier preset stays saved and pending, manual stays on, the connection is kept (no teardown); the recovery
    /// re-applies the saved targets afterwards (not run here: no real timer).
    func testALateFirstFanPinWithAPendingPresetIsHandedBackAndThePresetKept() async {
        let old: [Int: Double] = [0: 2000, 1: 2100]
        Preferences.fanManualEnabled = true   // the earlier preset, as savePreset leaves it (without its real arm)
        Preferences.fanTargets = old
        FanControlHelper.presetPending = true
        let conn = HeldConn()
        FanControlHelper.inject(connection: conn, engagesInFlight: 0)

        let first = expectation(description: "the timed-out first engage handed the fans back")
        conn.onReset = { first.fulfill() }
        let r = await StatsPopupView.engageManual([0: 4000, 1: 4100], firstReply: { @MainActor i, rpm in
            await FanControlHelper.setManualReply(i, rpm: rpm, timeout: 0, presentModal: false,
                                                  macOSRPM: { _ in nil }, arm: {})
        }, engage: { _, _ in XCTFail("a later fan was engaged after the first failed"); return .writeFailed })
        XCTAssertFalse(r.saved)
        XCTAssertEqual(r.reply, .unavailable)
        XCTAssertEqual(Preferences.fanTargets, old, "the timed-out click saved its targets")
        await fulfillment(of: [first], timeout: 5)
        conn.onReset = nil
        await Task { @MainActor in }.value   // resetAll's tail (after the reply) ran: no reset in flight
        XCTAssertEqual(conn.resets, 1)
        nonisolated(unsafe) let reply = conn.held
        XCTAssertTrue(reply != nil, "the fake did not hold the first fan's engage reply")

        let late = expectation(description: "the late first-fan pin handed back")
        conn.onReset = { late.fulfill() }
        DispatchQueue.global().async { reply?(true) }   // the helper pins fan 0 at 4000 after the ceiling
        await fulfillment(of: [late], timeout: 5)
        conn.onReset = nil
        await Task { @MainActor in }.value   // the late release's resetAll ended before the row ends
        XCTAssertEqual(conn.resets, 2, "the late first-fan pin was not handed back")
        XCTAssertEqual(FanControlHelper.lateLandings, 1, "the late reply did not reach lateReplyLanded")
        XCTAssertTrue(Preferences.fanManualEnabled)
        XCTAssertEqual(Preferences.fanTargets, old, "the earlier preset was not kept")
        XCTAssertTrue(FanControlHelper.presetPending)
        XCTAssertTrue(FanControlHelper.connection === conn, "a manual-on release tore the connection down")
    }
}
