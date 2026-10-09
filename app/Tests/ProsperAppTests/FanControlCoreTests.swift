import XCTest
@testable import ProsperHelperProtocol

/// The one safety-critical invariant: a manually-pinned fan is ALWAYS returned to
/// OS control when the last client drops (crash) or on cold start — never left
/// wedged. Pure logic, no root/hardware (the `reset` closure stands in for
/// `SMCFanController.resetAll`).
final class FanControlCoreTests: XCTestCase {
    private func makeCore() -> (FanControlCore, () -> Int) {
        var resets = 0
        let core = FanControlCore(reset: { resets += 1 })
        return (core, { resets })
    }

    func testManualThenLastClientGoneResets() {
        let (core, resets) = makeCore()
        core.didSetManual()
        XCTAssertTrue(core.manualHeld)
        core.lastClientGone()
        XCTAssertEqual(resets(), 1, "crash/last-drop must reset fans when manual was held")
        XCTAssertFalse(core.manualHeld)
    }

    func testNoManualNoResetOnDrop() {
        let (core, resets) = makeCore()
        core.lastClientGone()
        XCTAssertEqual(resets(), 0, "never reset when nothing was pinned (don't fight the OS for no reason)")
    }

    func testExplicitResetDisarmsCrashReset() {
        let (core, resets) = makeCore()
        core.didSetManual()
        core.didResetAll()                 // clean disable / pre-sleep
        XCTAssertFalse(core.manualHeld)
        core.lastClientGone()
        XCTAssertEqual(resets(), 0, "already reset cleanly → last-drop must not double-reset")
    }

    func testReclaimAlwaysResetsAndDisarms() {
        let (core, resets) = makeCore()
        core.reclaimAtStartup()
        XCTAssertEqual(resets(), 1, "cold start always hands fans back to the OS")
        XCTAssertFalse(core.manualHeld)
    }

    func testIdempotentDoubleDrop() {
        let (core, resets) = makeCore()
        core.didSetManual()
        core.lastClientGone()
        core.lastClientGone()              // a second invalidation callback
        XCTAssertEqual(resets(), 1, "reset fires once per manual session, not per stray callback")
    }

    // MARK: - Temperature kill-switch

    func testKillSwitchFiresAtThresholdAndDisarms() {
        let (core, resets) = makeCore()
        core.didSetManual()
        XCTAssertTrue(core.temperatureTick(maxCelsius: FanControlCore.killSwitchCelsius),
                      "at/above threshold while manual held must fire")
        XCTAssertEqual(resets(), 1, "kill-switch hands fans back to the OS")
        XCTAssertFalse(core.manualHeld, "fired kill-switch disarms the manual hold")
        core.lastClientGone()
        XCTAssertEqual(resets(), 1, "post-fire client drop must not double-reset")
    }

    func testKillSwitchIgnoresBelowThreshold() {
        let (core, resets) = makeCore()
        core.didSetManual()
        XCTAssertFalse(core.temperatureTick(maxCelsius: FanControlCore.killSwitchCelsius - 0.1))
        XCTAssertEqual(resets(), 0)
        XCTAssertTrue(core.manualHeld, "below threshold keeps the manual hold (and crash-safety) armed")
    }

    func testKillSwitchIgnoresWhenNotHeld() {
        let (core, resets) = makeCore()
        XCTAssertFalse(core.temperatureTick(maxCelsius: 120),
                       "no manual hold → nothing to kill, never fight the OS")
        XCTAssertEqual(resets(), 0)
    }

    func testKillSwitchIgnoresNilAndNonFiniteReadings() {
        let (core, resets) = makeCore()
        core.didSetManual()
        XCTAssertFalse(core.temperatureTick(maxCelsius: nil), "unreadable sensors must not fire")
        XCTAssertFalse(core.temperatureTick(maxCelsius: .nan))
        XCTAssertEqual(resets(), 0)
        XCTAssertTrue(core.manualHeld, "bad readings leave the hold (and crash-safety) intact")
    }

    // MARK: - Kill-switch hysteresis (trip latch / re-arm)

    /// The reported loop: trip at the cut-off, the app re-applies ~1 s later into a
    /// chassis still above it, trip again. After a trip manual stays refused until the
    /// sensors are back below the re-arm threshold.
    func testTripLatchesUntilBelowReArm() {
        let (core, resets) = makeCore()
        core.didSetManual()
        XCTAssertTrue(core.temperatureTick(maxCelsius: 98))
        XCTAssertEqual(resets(), 1)
        XCTAssertFalse(core.mayEngageManual(maxCelsius: 98), "still above the cut-off")
        XCTAssertFalse(core.mayEngageManual(maxCelsius: FanControlCore.reArmCelsius),
                       "inside the band: not re-armed yet")
        XCTAssertFalse(core.mayEngageManual(maxCelsius: nil), "unreadable sensors keep the latch")
        XCTAssertFalse(core.mayEngageManual(maxCelsius: .nan))
        XCTAssertTrue(core.mayEngageManual(maxCelsius: FanControlCore.reArmCelsius - 0.1),
                      "below re-arm: manual allowed again")
        XCTAssertFalse(core.tripLatched, "re-arm clears the latch")
        XCTAssertTrue(core.mayEngageManual(maxCelsius: 94), "re-armed: no band any more")
    }

    func testReArmBandSitsBelowTheCutOff() {
        XCTAssertLessThan(FanControlCore.reArmCelsius, FanControlCore.killSwitchCelsius)
    }

    /// QA #14 F1: the app relaunches (Sparkle update, crash) right after a trip and
    /// re-applies its saved pin over a NEW connection; the old one closed. That fresh
    /// engage must still be refused until the chassis is under re-arm.
    func testLatchSurvivesReconnect() {
        let (core, resets) = makeCore()
        core.didSetManual()
        core.temperatureTick(maxCelsius: 98)
        core.lastClientGone()   // old connection dropped: nothing held, no second reset
        XCTAssertEqual(resets(), 1)
        XCTAssertFalse(core.mayEngageManual(maxCelsius: 90), "fresh connection, chassis still hot")
        XCTAssertTrue(core.tripLatched)
        XCTAssertTrue(core.mayEngageManual(maxCelsius: 79))
    }

    func testFullResetDoesNotClearTheLatch() {
        let (core, _) = makeCore()
        core.didSetManual()
        core.temperatureTick(maxCelsius: 98)
        core.didResetAll()   // the app's reclaim retry sends resetAllFans too
        XCTAssertFalse(core.mayEngageManual(maxCelsius: 98))
    }

    /// Choosing Automatic with the fast-re-engage hold keeps the controller unlocked
    /// (a supervised hazard) but must not re-open manual into a hot chassis.
    func testAutoWithHoldDoesNotClearTheLatch() {
        let (core, _) = makeCore()
        core.didSetManual()
        core.temperatureTick(maxCelsius: 98)
        core.didAutoWithHold()
        XCTAssertFalse(core.mayEngageManual(maxCelsius: 90))
    }

    func testTripOnHeldUnlockLatchesNothing() {
        let (core, _) = makeCore()
        core.didAutoWithHold()
        XCTAssertTrue(core.temperatureTick(maxCelsius: 98))
        XCTAssertFalse(core.tripLatched, "no manual speed was running, so there is nothing to hold off")
    }

    func testBelowCutOffTickLatchesNothing() {
        let (core, _) = makeCore()
        core.didSetManual()
        XCTAssertFalse(core.temperatureTick(maxCelsius: 90))
        XCTAssertFalse(core.tripLatched)
    }

    func testColdStartClearsTheLatch() {
        let (core, _) = makeCore()
        core.didSetManual()
        core.temperatureTick(maxCelsius: 98)
        core.reclaimAtStartup()
        XCTAssertFalse(core.tripLatched)
    }

    func testUnlatchedEngageReadsNoTemperature() {
        let (core, _) = makeCore()
        var reads = 0
        func read() -> Double? { reads += 1; return 120 }
        XCTAssertTrue(core.mayEngageManual(maxCelsius: read()))
        XCTAssertEqual(reads, 0, "the common path must not cost an SMC temperature sweep")
    }

    // MARK: - Held unlock (fast re-engage) — same supervision as a manual pin

    func testAutoWithHoldStaysSupervised() {
        let (core, _) = makeCore()
        core.didSetManual()
        core.didAutoWithHold()
        XCTAssertFalse(core.manualHeld)
        XCTAssertTrue(core.unlockHeld)
        XCTAssertTrue(core.needsSupervision, "a held unlock is a latent hazard — timer must stay armed")
    }

    func testUnlockHeldLastClientGoneResets() {
        let (core, resets) = makeCore()
        core.didSetManual()
        core.didAutoWithHold()
        core.lastClientGone()
        XCTAssertEqual(resets(), 1, "client drop with a held unlock must clear Ftst via full reset")
        XCTAssertFalse(core.unlockHeld)
    }

    func testKillSwitchFiresOnUnlockHeldAlone() {
        let (core, resets) = makeCore()
        core.didAutoWithHold()
        XCTAssertTrue(core.temperatureTick(maxCelsius: FanControlCore.killSwitchCelsius))
        XCTAssertEqual(resets(), 1)
        XCTAssertFalse(core.unlockHeld, "fired kill-switch clears the held unlock too")
    }

    func testExplicitResetClearsUnlockHold() {
        let (core, resets) = makeCore()
        core.didAutoWithHold()
        core.didResetAll()
        XCTAssertFalse(core.unlockHeld)
        core.lastClientGone()
        XCTAssertEqual(resets(), 0, "cleanly reset → no double-reset on drop")
    }

    func testColdStartClearsUnlockHold() {
        let (core, resets) = makeCore()
        core.didAutoWithHold()
        core.reclaimAtStartup()
        XCTAssertEqual(resets(), 1)
        XCTAssertFalse(core.unlockHeld)
    }

    func testManualSupersedesUnlockHold() {
        let (core, _) = makeCore()
        core.didAutoWithHold()
        core.didSetManual()
        XCTAssertTrue(core.manualHeld)
        XCTAssertFalse(core.unlockHeld, "manual is strictly more held — no dual flags")
    }
}
