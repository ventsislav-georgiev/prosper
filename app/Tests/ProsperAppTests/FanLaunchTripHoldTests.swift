import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

/// Entry 981 (OQ-142 b): a run whose helper latch refused the saved speed is remembered in the app's own store, and
/// the next launch holds that speed until the app's own complete reading is below the helper's re-arm line (80 °C).
/// Fakes only: the fan connection and the identity throwaway are `FanHelperIdentityTests.FakeConn` (no Mach service,
/// no helper, no SMC), the registration, the speed read, the temperature read and the recovery arm are seams; no
/// real timer or observer is installed. Every preference lives in the XCTest scratch defaults.
@MainActor
final class FanLaunchTripHoldTests: XCTestCase {
    typealias FakeConn = FanHelperIdentityTests.FakeConn

    private var saved: (manual: Bool, hold: Bool, targets: [Int: Double], trip: Bool, refused: Int?) =
        (false, false, [:], false, nil)
    private var savedRegistration: (@Sendable () -> LidSleepHelper.RegisterOutcome)?
    private var savedFactory: (() -> NSXPCConnection?)?
    private var savedCeiling: ((@escaping @Sendable @MainActor () -> Void) -> Void)?
    private var savedRetry: ((@escaping @Sendable @MainActor () -> Void) -> Void)?
    private var savedCelsius: (@Sendable () -> Double?)?

    override func setUp() async throws {
        saved = (Preferences.fanManualEnabled, Preferences.fanHoldUnlock, Preferences.fanTargets,
                 Preferences.fanTripHeld, FanControlHelper.lastRefusedFan)
        Preferences.fanHoldUnlock = false
        Preferences.fanManualEnabled = false
        Preferences.fanTripHeld = false
        FanControlHelper.launchTripHold = false
        savedRegistration = LidSleepHelper.registration
        LidSleepHelper.registration = { .enabled }
        savedFactory = FanControlHelper.makeIdentityConnection
        savedCeiling = FanControlHelper.identityCeiling
        savedRetry = FanControlHelper.identityRetry
        savedCelsius = FanControlHelper.tripHoldCelsius
        FanControlHelper.makeIdentityConnection = { nil }
        FanControlHelper.identityCeiling = { _ in }
        FanControlHelper.identityRetry = { _ in }
        FanControlHelper.tripHoldCelsius = { XCTFail("no temperature read expected"); return nil }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()
    }

    override func tearDown() async throws {
        Preferences.fanManualEnabled = false
        FanControlHelper.makeIdentityConnection = { nil }
        await FanControlHelper.resetAll(teardown: true)
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()
        FanControlHelper.presetPending = false
        FanControlHelper.launchTripHold = false
        if let savedRegistration { LidSleepHelper.registration = savedRegistration }
        if let savedFactory { FanControlHelper.makeIdentityConnection = savedFactory }
        if let savedCeiling { FanControlHelper.identityCeiling = savedCeiling }
        if let savedRetry { FanControlHelper.identityRetry = savedRetry }
        if let savedCelsius { FanControlHelper.tripHoldCelsius = savedCelsius }
        Preferences.fanManualEnabled = saved.manual
        Preferences.fanHoldUnlock = saved.hold
        Preferences.fanTargets = saved.targets
        Preferences.fanTripHeld = saved.trip
        FanControlHelper.lastRefusedFan = saved.refused
    }

    /// The verdict through the real ask, answered by a fake throwaway (as FanReasonReplyTests does).
    private func answer(_ mode: FakeConn.Mode) async {
        let t = FakeConn()
        t.mode = mode
        FanControlHelper.makeIdentityConnection = { t }
        let closed = expectation(description: "throwaway closed")
        t.onInvalidate = { closed.fulfill() }
        XCTAssertTrue(FanControlHelper.askHelperIdentityIfIdle())
        await fulfillment(of: [closed], timeout: 5)
        t.onInvalidate = nil
        FanControlHelper.makeIdentityConnection = { nil }
    }

    private func engage(rpm: Double) async -> FanManualReply {
        await FanControlHelper.setManualReply(0, rpm: rpm, presentModal: false, macOSRPM: { _ in 2500 }, arm: {})
    }

    /// A launch with the hold loaded: manual on, one saved fan, the hold in memory and on disk.
    private func heldLaunch() {
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [0: 2000]
        Preferences.fanTripHeld = true
        FanControlHelper.reapplyFromPreferences(start: {})
    }

    private func apply(engaged: LockedBox) async -> Bool {
        await FanControlHelper.applySavedTargets(reclaimGeneration: FanControlHelper.reclaimGeneration,
                                                 engage: { _, _, _ in engaged.set(true); return true },
                                                 reset: { _ in true })
    }

    // A refusal by the helper's latch (Bool method named by the speed read, and the reason method's codes 1 and 2)
    // is written to disk; an accept and a write failure are not.
    func testALatchRefusalIsRememberedOnDisk() async {
        let fan = FakeConn()
        FanControlHelper.inject(connection: fan, engagesInFlight: 0)
        fan.boolReply = true
        var reply = await engage(rpm: 2000)
        XCTAssertEqual(reply, .engaged)
        XCTAssertFalse(Preferences.fanTripHeld, "an accept is no trip")
        fan.boolReply = false
        reply = await engage(rpm: 2000)
        XCTAssertEqual(reply, .refused, "Bool method, below macOS's 2500")
        XCTAssertTrue(Preferences.fanTripHeld, "Bool method: the refusal is remembered")

        await answer(.answers(helperProtocolVersion, helperCapabilityFanReason))
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)
        for (code, rpm, want, held) in [(1, 3103.0, FanManualReply.settlingReported, true), (2, 2000, .refused, true),
                                        (3, 3103, .writeFailed, false), (0, 3103, .engaged, false)] {
            Preferences.fanTripHeld = false
            fan.reasonCode = code
            reply = await engage(rpm: rpm)
            XCTAssertEqual(reply, want, "code \(code)")
            XCTAssertEqual(Preferences.fanTripHeld, held, "code \(code)")
        }
    }

    // The launch re-apply loads the hold from disk; with nothing on disk there is no hold.
    func testTheLaunchLoadsTheHoldFromDisk() {
        heldLaunch()
        XCTAssertTrue(FanControlHelper.launchTripHold)
        Preferences.fanTripHeld = false
        FanControlHelper.reapplyFromPreferences(start: {})
        XCTAssertFalse(FanControlHelper.launchTripHold)
    }

    // Held: 85, exactly 80, no reading, NaN and infinity engage nothing and keep the hold in memory and on disk
    // (the preset stays pending); 79.5 ends the hold in both and the saved speed is applied.
    func testTheHeldSpeedWaitsForAReadingBelowTheReArmLine() async {
        heldLaunch()
        let engaged = LockedBox()
        for c in [85.0, FanControlCore.reArmCelsius, nil, .nan, .infinity] as [Double?] {
            FanControlHelper.tripHoldCelsius = { c }
            let ok = await apply(engaged: engaged)
            XCTAssertFalse(ok, "\(String(describing: c))")
            XCTAssertEqual(engaged.get().count, 0, "\(String(describing: c)): nothing engaged")
            XCTAssertTrue(FanControlHelper.launchTripHold && Preferences.fanTripHeld, "\(String(describing: c)): still held")
            XCTAssertTrue(FanControlHelper.presetPending, "\(String(describing: c)): the preset stays pending")
        }
        FanControlHelper.tripHoldCelsius = { 79.5 }
        let ok = await apply(engaged: engaged)
        XCTAssertTrue(ok)
        XCTAssertEqual(engaged.get().count, 1)
        XCTAssertFalse(FanControlHelper.launchTripHold, "the hold ends in memory")
        XCTAssertFalse(Preferences.fanTripHeld, "and on disk")
        XCTAssertFalse(FanControlHelper.presetPending)
    }

    // No hold: the re-apply reads no temperature (setUp's seam fails the row on a read) and engages as before.
    func testNoHoldReadsNoTemperature() async {
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [0: 2000]
        FanControlHelper.reapplyFromPreferences(start: {})
        let engaged = LockedBox()
        let ok = await apply(engaged: engaged)
        XCTAssertTrue(ok)
        XCTAssertEqual(engaged.get().count, 1)
    }

    // The user's Automatic ends the hold in memory and on disk.
    func testAutomaticEndsTheHold() async {
        heldLaunch()
        await StatsPopupView.selectAuto(fanIDs: [], presentModal: false).value
        XCTAssertFalse(FanControlHelper.launchTripHold)
        XCTAssertFalse(Preferences.fanTripHeld)
    }

    // A Manual click the helper accepted ends this launch's hold (the helper gated it); the disk flag stays until a
    // reading below the re-arm line or Automatic.
    func testALandedManualClickEndsTheLaunchHold() async {
        heldLaunch()
        let (saved, reply) = await FanControlHelper.popupEngage([0: 2000], first: 0, engageFirst: { .engaged },
                                                                firstLanded: { _, _, _ in true },
                                                                engage: { _, _ in .engaged }, landed: { _ in true })
        XCTAssertTrue(saved)
        XCTAssertEqual(reply, .engaged)
        XCTAssertFalse(FanControlHelper.launchTripHold)
        XCTAssertTrue(Preferences.fanTripHeld)
    }
}
