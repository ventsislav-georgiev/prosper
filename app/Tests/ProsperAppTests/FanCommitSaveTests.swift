import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

/// Entry 1234, second dispatch, part B: the slider commit's save after an Automatic (R1233-1), the late hook of
/// `setManualReply` and its in-time clear (R1234b-1), the run of late pins ended by an Automatic (N1234-d), and the
/// popup's inline unread-fan refusal (R1233-2). Fakes only: the fan connection is nil or `HeldConn` (no Mach service,
/// no helper, no SMC, no SMAppService: the registration is a seam), the identity throwaway factory returns nil, the
/// recovery lifecycle's arm is a no-op (no real reclaim timer, no sleep observer), the popup is never built. Manual,
/// the targets and the fast re-engage hold are set in the scratch defaults; the hold is off in every row.
@MainActor
final class FanCommitSaveTests: XCTestCase {

    /// A fan connection to nothing that keeps the Bool engage's reply until the row sends it (`hold`), as a helper
    /// queue that answers after the ceiling; with `hold` off it answers true at once. `resetAllFans` answers true at
    /// once and is counted; every other selector answers at once (none is sent by these rows).
    final class HeldConn: NSXPCConnection, @unchecked Sendable {
        var hold = true
        var held: ((Bool) -> Void)?
        var resets = 0
        var onReset: (() -> Void)?
        override func resume() {}
        override func invalidate() {}
        override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
            let p = Proxy()
            p.conn = self
            return p
        }

        final class Proxy: NSObject, ProsperHelperProtocol, @unchecked Sendable {
            weak var conn: HeldConn?
            func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setRemoteWake(_ json: String, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setRemoteSessionActive(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func clearRemoteSession(withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func sleepNow(withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setFanManualRPM(_ index: Int, rpm: Double, withReply reply: @escaping (Bool) -> Void) {
                guard let conn, conn.hold else { reply(true); return }
                conn.held = reply
            }
            func setFanAuto(_ index: Int, holdUnlock: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func resetAllFans(withReply reply: @escaping (Bool) -> Void) {
                conn?.resets += 1
                conn?.onReset?()
                reply(true)
            }
            func helperInfo(withReply reply: @escaping (Int, Int) -> Void) { reply(0, 0) }
            func setFanManualRPMWithReason(_ index: Int, rpm: Double, withReply reply: @escaping (Int) -> Void) { reply(0) }
        }
    }

    private var saved: (manual: Bool, hold: Bool, targets: [Int: Double]) = (false, false, [:])
    private var savedRegistration: (@Sendable () -> LidSleepHelper.RegisterOutcome)?
    private var savedFactory: (() -> NSXPCConnection?)?

    override func setUp() async throws {
        saved = (Preferences.fanManualEnabled, Preferences.fanHoldUnlock, Preferences.fanTargets)
        Preferences.fanHoldUnlock = false
        Preferences.fanManualEnabled = false
        savedRegistration = LidSleepHelper.registration
        LidSleepHelper.registration = { .enabled }
        savedFactory = FanControlHelper.makeIdentityConnection
        FanControlHelper.makeIdentityConnection = { nil }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()   // no verdict: the Bool engage
        FanControlHelper.lateLandings = 0
    }

    override func tearDown() async throws {
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()
        FanControlHelper.lateLandings = 0
        if let savedRegistration { LidSleepHelper.registration = savedRegistration }
        if let savedFactory { FanControlHelper.makeIdentityConnection = savedFactory }
        Preferences.fanManualEnabled = saved.manual
        Preferences.fanHoldUnlock = saved.hold
        Preferences.fanTargets = saved.targets
    }

    /// R1233-1: the save of commitAll's work item (its static seam; no view, no timer). With no Automatic since the
    /// commit it saves the targets and returns the ones saved before; after an Automatic (manual off, targets
    /// cleared) it saves nothing, so the store keeps Automatic's empty targets.
    func testTheCommitSavesNothingAfterAnAutomatic() async {
        Preferences.fanTargets = [0: 2000]
        let previous = StatsPopupView.saveCommit([0: 3000, 1: 3100], since: FanControlHelper.automaticGeneration)
        XCTAssertEqual(previous, [0: 2000])
        XCTAssertEqual(Preferences.fanTargets, [0: 3000, 1: 3100])

        Preferences.fanManualEnabled = true
        let since = FanControlHelper.automaticGeneration   // captured at the commit
        await StatsPopupView.selectAuto(fanIDs: [0, 1], presentModal: false).value   // connection nil: no reset sent
        XCTAssertFalse(Preferences.fanManualEnabled)
        _ = StatsPopupView.saveCommit([0: 4000, 1: 4100], since: since)   // the work item, 0.4 s later
        XCTAssertEqual(Preferences.fanTargets, [:], "a commit saved its targets after an Automatic")
    }

    /// R1234b-1: an engage reply that comes after callReply gave up (the ceiling 0 gives up at once, the reply is held
    /// until the row sends it, on a background queue as XPC does) reaches setManualReply's late hook: lateReplyLanded
    /// counts it and the default release hands it back (one reset on the fake). An engage that lands in time then
    /// clears the count. The arm is a no-op: no real reclaim timer, no sleep observer.
    func testALateReplyIsCountedAndAnEngageInTimeClearsTheCount() async {
        Preferences.fanManualEnabled = true   // the release keeps the connection (no teardown); 1 < 3 keeps manual on
        let conn = HeldConn()
        FanControlHelper.inject(connection: conn, engagesInFlight: 0)
        var armed = 0
        let gaveUp = await FanControlHelper.setManualReply(0, rpm: 3103, timeout: 0, presentModal: false,
                                                           macOSRPM: { _ in nil }, arm: { armed += 1 })
        XCTAssertEqual(gaveUp, .unavailable)
        XCTAssertEqual(armed, 1)
        XCTAssertEqual(FanControlHelper.lateLandings, 0)
        nonisolated(unsafe) let reply = conn.held
        XCTAssertTrue(reply != nil, "the fake did not hold the engage reply")

        let released = expectation(description: "the late pin handed back")
        conn.onReset = { released.fulfill() }
        DispatchQueue.global().async { reply?(true) }
        await fulfillment(of: [released], timeout: 5)
        conn.onReset = nil
        XCTAssertEqual(conn.resets, 1)
        XCTAssertEqual(FanControlHelper.lateLandings, 1, "the late reply did not reach lateReplyLanded")
        XCTAssertTrue(Preferences.fanManualEnabled)

        conn.hold = false
        let inTime = await FanControlHelper.setManualReply(0, rpm: 3103, presentModal: false,
                                                           macOSRPM: { _ in nil }, arm: { armed += 1 })
        XCTAssertEqual(inTime, .engaged)
        XCTAssertEqual(armed, 2)
        XCTAssertEqual(FanControlHelper.lateLandings, 0, "an engage that landed in time kept the count")
    }

    /// N1234-d: every Automatic ends the run of late pins: selectAuto, and the inline refusal's counter bump.
    func testAnAutomaticEndsTheRunOfLatePins() async {
        Preferences.fanManualEnabled = true
        FanControlHelper.lateLandings = 2
        await StatsPopupView.selectAuto(fanIDs: [0], presentModal: false).value   // connection nil: no reset sent
        XCTAssertEqual(FanControlHelper.lateLandings, 0, "selectAuto kept the run of late pins")

        FanControlHelper.lateLandings = 2
        StatsPopupView.refuseUnreadInline(manualEnabled: false) { XCTFail("Automatic with manual off") }
        XCTAssertEqual(FanControlHelper.lateLandings, 0, "the refusal's bump kept the run of late pins")
    }

    /// R1233-2: the popup's unread-fan refusal: with manual off only the Automatic counter moves; with manual on it
    /// ends in the view's Automatic (which moves the counter itself, through selectAuto).
    func testTheInlineUnreadRefusalBumpsOnlyWithManualOff() {
        let before = FanControlHelper.automaticGeneration
        var autos = 0
        StatsPopupView.refuseUnreadInline(manualEnabled: false) { autos += 1 }
        XCTAssertEqual(autos, 0)
        XCTAssertEqual(FanControlHelper.automaticGeneration, before &+ 1)

        StatsPopupView.refuseUnreadInline(manualEnabled: true) { autos += 1 }
        XCTAssertEqual(autos, 1)
        XCTAssertEqual(FanControlHelper.automaticGeneration, before &+ 1)
    }
}
