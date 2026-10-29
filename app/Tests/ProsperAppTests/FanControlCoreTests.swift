import XCTest
@testable import ProsperHelperProtocol
import SMCKit

/// The one safety-critical invariant: a manually-pinned fan is ALWAYS returned to
/// OS control when the last client drops (crash) or on cold start — never left
/// wedged. Pure logic, no root/hardware (the `reset` closure stands in for
/// `SMCFanController.resetAll`).
final class FanControlCoreTests: XCTestCase {
    private func makeCore() -> (FanControlCore, () -> Int) {
        var resets = 0
        let core = FanControlCore(reset: { resets += 1; return true }, maxCelsius: { nil })
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
        core.reclaimAtStartup(maxCelsius: nil)
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
        XCTAssertFalse(core.mayEngageManual(rpm: 3000, maxCelsius: 98, macOSRPM: nil), "still above the cut-off")
        XCTAssertFalse(core.mayEngageManual(rpm: 3000, maxCelsius: FanControlCore.reArmCelsius, macOSRPM: nil),
                       "inside the band: not re-armed yet")
        XCTAssertFalse(core.mayEngageManual(rpm: 3000, maxCelsius: nil, macOSRPM: nil), "unreadable sensors keep the latch")
        XCTAssertFalse(core.mayEngageManual(rpm: 3000, maxCelsius: .nan, macOSRPM: nil))
        XCTAssertTrue(core.mayEngageManual(rpm: 3000, maxCelsius: FanControlCore.reArmCelsius - 0.1, macOSRPM: nil),
                      "below re-arm: manual allowed again")
        XCTAssertFalse(core.tripLatched, "re-arm clears the latch")
        XCTAssertTrue(core.mayEngageManual(rpm: 3000, maxCelsius: 94, macOSRPM: nil), "re-armed: no band any more")
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
        XCTAssertFalse(core.mayEngageManual(rpm: 3000, maxCelsius: 90, macOSRPM: nil), "fresh connection, chassis still hot")
        XCTAssertTrue(core.tripLatched)
        XCTAssertTrue(core.mayEngageManual(rpm: 3000, maxCelsius: 79, macOSRPM: nil))
    }

    func testFullResetDoesNotClearTheLatch() {
        let (core, _) = makeCore()
        core.didSetManual()
        core.temperatureTick(maxCelsius: 98)
        core.didResetAll()   // the app's reclaim retry sends resetAllFans too
        XCTAssertFalse(core.mayEngageManual(rpm: 3000, maxCelsius: 98, macOSRPM: nil))
    }

    /// Choosing Automatic with the fast-re-engage hold keeps the controller unlocked
    /// (a supervised hazard) but must not re-open manual into a hot chassis.
    func testAutoWithHoldDoesNotClearTheLatch() {
        let (core, _) = makeCore()
        core.didSetManual()
        core.temperatureTick(maxCelsius: 98)
        core.didAutoWithHold()
        XCTAssertFalse(core.mayEngageManual(rpm: 3000, maxCelsius: 90, macOSRPM: nil))
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
        core.reclaimAtStartup(maxCelsius: nil)
        XCTAssertFalse(core.tripLatched)
    }

    func testUnlatchedEngageReadsNoTemperature() {
        let (core, _) = makeCore()
        var reads = 0
        func read() -> Double? { reads += 1; return 120 }
        var rpmReads = 0
        func rpm() -> Double? { rpmReads += 1; return 5000 }
        XCTAssertTrue(core.mayEngageManual(rpm: 3000, maxCelsius: read(), macOSRPM: rpm()))
        XCTAssertEqual(reads, 0, "the common path must not cost an SMC temperature sweep")
        XCTAssertEqual(rpmReads, 0, "nor a fan speed read")
    }

    // MARK: - Re-take after a trip (#586): a pin faster than macOS takes the fans back

    /// The injected clock: tests move it, the core never reads the real time.
    private final class Clock {
        var t = ContinuousClock.now
        func advance(_ s: Double) { t = t.advanced(by: .seconds(s)) }
    }

    /// A core whose 3103 RPM pin on fan 0 just tripped the kill-switch at `clock.t`.
    private func makeTripped(_ clock: Clock) -> FanControlCore {
        let core = FanControlCore(reset: { true }, maxCelsius: { nil }, now: { clock.t })
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 50, macOSRPM: nil))
        XCTAssertEqual(core.supervise(maxCelsius: 96, isManualEngaged: { _ in true }), .fired)
        XCTAssertTrue(core.tripLatched)
        return core
    }

    func testSettleWindowIsTenSeconds() {
        XCTAssertEqual(FanControlCore.reTakeSettleSeconds, 10)
    }

    func testInsideTheSettleWindowEvenAFasterPinIsRefused() {
        let clock = Clock(), core = makeTripped(clock)
        clock.advance(FanControlCore.reTakeSettleSeconds - 0.01)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        XCTAssertEqual(core.lastRefusal, .settling)
        XCTAssertFalse(core.manualHeld, "refused engage arms nothing")
        XCTAssertNil(core.holder)
        XCTAssertTrue(core.heldTargets.isEmpty)
    }

    /// The operator's case: macOS runs the fans at ~2500 on a hot lap, the pin is 3103.
    func testAfterTheWindowAPinAtOrAboveMacOSTakesTheFansBackAndKeepsTheLatch() {
        let clock = Clock(), core = makeTripped(clock)
        clock.advance(FanControlCore.reTakeSettleSeconds)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        XCTAssertTrue(core.manualRequest(index: 1, rpm: 2500, holder: idA, maxCelsius: 96, macOSRPM: 2500),
                      "equal to macOS's speed is not below it")
        XCTAssertTrue(core.tripLatched, "a re-take does not re-arm: the next engage is judged again")
        XCTAssertTrue(core.manualHeld)
        XCTAssertEqual(core.holder, idA)
        XCTAssertEqual(core.heldTargets, [0: 3103, 1: 2500])
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 2000, holder: idA, maxCelsius: 96, macOSRPM: 3103),
                       "still latched: lowering under the running speed is refused")
        XCTAssertEqual(core.heldTargets[0], 3103, "a refusal leaves the held pin alone")
    }

    func testAfterTheWindowAPinBelowMacOSIsRefusedUntilReArm() {
        let clock = Clock(), core = makeTripped(clock)
        clock.advance(60)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 2400, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        XCTAssertEqual(core.lastRefusal, .belowMacOS)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 2400, holder: idA, maxCelsius: FanControlCore.reArmCelsius,
                                          macOSRPM: 2500), "inside the band: not re-armed yet")
        XCTAssertFalse(core.manualRequest(index: 0, rpm: .nan, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        XCTAssertFalse(core.manualHeld)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 2400, holder: idA, maxCelsius: 79, macOSRPM: 2500))
        XCTAssertFalse(core.tripLatched, "below re-arm clears the latch, as before")
        XCTAssertNil(core.lastRefusal)
    }

    func testUnreadableTemperatureOrSpeedWhileLatchedRefuses() {
        let clock = Clock(), core = makeTripped(clock)
        clock.advance(60)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: nil))
        XCTAssertEqual(core.lastRefusal, .unreadable)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: .nan))
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: nil, macOSRPM: 2500))
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: .nan, macOSRPM: 2500))
        XCTAssertEqual(core.lastRefusal, .unreadable)
        XCTAssertFalse(core.manualHeld)
        XCTAssertTrue(core.tripLatched)
    }

    func testBelowReArmIsAllowedEvenInsideTheWindow() {
        let clock = Clock(), core = makeTripped(clock)
        clock.advance(1)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 1500, holder: idA, maxCelsius: 79, macOSRPM: 2500))
        XCTAssertFalse(core.tripLatched)
    }

    func testASecondTripRestartsTheWindow() {
        let clock = Clock(), core = makeTripped(clock)
        clock.advance(FanControlCore.reTakeSettleSeconds)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        clock.advance(30)   // the daemon's next supervision tick, still hot
        XCTAssertEqual(core.supervise(maxCelsius: 96, isManualEngaged: { _ in true }), .fired)
        XCTAssertNil(core.lastRefusal, "a new trip is a new episode: its first refusal logs again")
        clock.advance(FanControlCore.reTakeSettleSeconds - 0.01)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        XCTAssertEqual(core.lastRefusal, .settling)
        clock.advance(0.01)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
    }

    /// The pre-#209 loop: the app re-pinned ~1 s after every trip. With an app that
    /// asks every second, no re-pin lands sooner than the window after a trip.
    func testTripHandbackRepinCycleCannotRunFasterThanTheWindow() {
        let clock = Clock()
        let core = FanControlCore(reset: { true }, maxCelsius: { nil }, now: { clock.t })
        var engagedAt: Double?, trips: [Double] = [], engages: [Double] = []
        for second in 0..<300 {
            let t = Double(second)
            if !core.manualHeld,
               core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500) {
                engagedAt = t; engages.append(t)
            } else if let e = engagedAt, t - e >= 30,   // the daemon's timer: first tick 30 s after arming
                      core.supervise(maxCelsius: 96, isManualEngaged: { _ in true }) == .fired {
                trips.append(t); engagedAt = nil
            }
            clock.advance(1)
        }
        XCTAssertGreaterThan(trips.count, 3, "the cycle runs: Prosper keeps taking the fans back")
        for trip in trips {
            let next = engages.first { $0 > trip }
            XCTAssertGreaterThanOrEqual((next ?? .infinity) - trip, FanControlCore.reTakeSettleSeconds)
        }
    }

    /// The daemon logs a refusal only when its reason changes: retries keep the reason.
    func testRefusalReasonIsStableAcrossRetries() {
        let clock = Clock(), core = makeTripped(clock)
        for _ in 0..<3 { _ = core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500) }
        XCTAssertEqual(core.lastRefusal, .settling)
        clock.advance(60)
        _ = core.manualRequest(index: 0, rpm: 2000, holder: idA, maxCelsius: 96, macOSRPM: 2500)
        XCTAssertEqual(core.lastRefusal, .belowMacOS)
        XCTAssertTrue(core.manualRequest(index: 1, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        XCTAssertEqual(core.lastRefusal, .belowMacOS, "a re-take between refusals does not re-log the same reason")
    }

    /// A cold start into a chassis at the cut-off latches and starts the window then.
    func testColdStartIntoHotChassisStartsTheWindow() {
        let clock = Clock()
        let core = FanControlCore(reset: { true }, maxCelsius: { 96 }, now: { clock.t })
        core.reclaimAtStartup()
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        clock.advance(FanControlCore.reTakeSettleSeconds)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        XCTAssertFalse(core.manualRequest(index: 1, rpm: 2000, holder: idA, maxCelsius: 96, macOSRPM: 2500))
    }

    /// QA #456 H1: macOS's speed is the higher of F<i>Ac and F<i>Tg; unreadable fails closed.
    func testMacOSSpeedIsMaxOfActualAndTarget() {
        XCTAssertEqual(FanControlCore.macOSSpeed(current: 2273, target: 2305), 2305, "ramping up: Tg leads")
        XCTAssertEqual(FanControlCore.macOSSpeed(current: 2493, target: 2464), 2493, "spinning down: Ac leads")
        XCTAssertNil(FanControlCore.macOSSpeed(current: nil, target: 2305))
        XCTAssertNil(FanControlCore.macOSSpeed(current: 2273, target: nil))
        XCTAssertNil(FanControlCore.macOSSpeed(current: .nan, target: 2305))
        XCTAssertNil(FanControlCore.macOSSpeed(current: 2273, target: .nan))
        XCTAssertNil(FanControlCore.macOSSpeed(current: 2273, target: .infinity))
    }

    /// QA #456 H1: macOS still ramping (Ac 2300, Tg 3200): a 3103 pin is above Ac but
    /// below where macOS is heading, so it must not take the fans.
    func testAfterTheWindowAPinAboveActualButBelowTargetIsRefused() {
        let clock = Clock(), core = makeTripped(clock)
        clock.advance(FanControlCore.reTakeSettleSeconds)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96,
                                          macOSRPM: FanControlCore.macOSSpeed(current: 2300, target: 3200)))
        XCTAssertEqual(core.lastRefusal, .belowMacOS)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96,
                                          macOSRPM: FanControlCore.macOSSpeed(current: 2300, target: nil)))
        XCTAssertEqual(core.lastRefusal, .unreadable, "an unreadable target fails closed, not Ac alone")
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96,
                                         macOSRPM: FanControlCore.macOSSpeed(current: 2300, target: 2500)))
    }

    /// QA #456 L1: every way a re-taken pin goes back to macOS while latched restarts
    /// the settle window, as a trip does.
    func testAPinHandedBackWhileLatchedRestartsTheWindow() {
        let handbacks: [(String, (FanControlCore) -> Void)] = [
            ("didResetAll", { $0.didResetAll() }),
            ("releaseAll", { XCTAssertTrue($0.releaseAll()) }),
            ("holder drop", { $0.connectionClosed(self.idA) }),
            ("lastClientGone", { $0.lastClientGone() }),
            ("setFanAuto", { _ = $0.autoApplied(index: 0, holdUnlock: false, hasFtst: false) }),
            ("supervise .release", { core in
                XCTAssertEqual(core.supervise(maxCelsius: 90, isManualEngaged: { _ in false }), .reassert([0]))
                guard case .release = core.supervise(maxCelsius: 90, isManualEngaged: { _ in false }) else {
                    return XCTFail("expected .release") }
                XCTAssertTrue(core.releaseAll())
            }),
        ]
        for (name, handBack) in handbacks {
            let clock = Clock(), core = makeTripped(clock)
            clock.advance(60)
            XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500), name)
            handBack(core)
            XCTAssertTrue(core.tripLatched, name)
            clock.advance(2)   // the app's next reclaim tick, Ac still reading the pin
            XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500), name)
            XCTAssertEqual(core.lastRefusal, .settling, name)
            clock.advance(FanControlCore.reTakeSettleSeconds - 2)
            XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500), name)
        }
    }

    /// The app's reset after a refused re-apply hands no pin back: the window stays,
    /// so the retry one window later is not pushed into a new one.
    func testAResetWithNoPinHeldLeavesTheWindow() {
        let clock = Clock(), core = makeTripped(clock)
        clock.advance(5)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
        core.didResetAll()
        XCTAssertTrue(core.releaseAll())
        clock.advance(FanControlCore.reTakeSettleSeconds - 5)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 96, macOSRPM: 2500))
    }

    /// Unlatched, a handback is just a reset: no latch, no window, the next engage passes.
    func testAResetWhileNotLatchedSetsNoLatchOrWindow() {
        let clock = Clock()
        let core = FanControlCore(reset: { true }, maxCelsius: { nil }, now: { clock.t })
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 50, macOSRPM: nil))
        core.didResetAll()
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: idA, maxCelsius: 50, macOSRPM: nil))
        core.connectionClosed(idA)
        XCTAssertFalse(core.tripLatched)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 1500, holder: idA, maxCelsius: 90, macOSRPM: 2500),
                      "no window and no below-macOS rule without a trip")
        XCTAssertNil(core.lastRefusal)
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
        core.reclaimAtStartup(maxCelsius: nil)
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

    // MARK: - XPC entry points (main.swift only translates and writes; QA #14 F2)

    private final class Conn {}
    private let a = Conn(), b = Conn()
    private var idA: ObjectIdentifier { ObjectIdentifier(a) }
    private var idB: ObjectIdentifier { ObjectIdentifier(b) }

    /// setFanManualRPM must go through the trip latch and record nothing when refused.
    func testManualRequestIsGatedByTheLatch() {
        let (core, _) = makeCore()
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil))
        XCTAssertEqual(core.supervise(maxCelsius: 98, isManualEngaged: { _ in true }), .fired)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3000, holder: idB, maxCelsius: 90, macOSRPM: nil),
                       "latched: a re-pin into a hot chassis is refused")
        XCTAssertFalse(core.manualHeld, "refused engage arms nothing")
        XCTAssertNil(core.holder)
        XCTAssertTrue(core.heldTargets.isEmpty)
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3000, holder: idB, maxCelsius: 79, macOSRPM: nil))
        XCTAssertTrue(core.manualHeld)
        XCTAssertEqual(core.holder, idB)
        XCTAssertEqual(core.heldTargets, [0: 3000])
    }

    /// The 30 s tick must run the kill-switch and clear the holder and targets.
    func testSuperviseRunsTheKillSwitch() {
        let (core, resets) = makeCore()
        XCTAssertEqual(core.supervise(maxCelsius: 120, isManualEngaged: { _ in true }), .stop,
                       "nothing held: stop the timer")
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        XCTAssertEqual(core.supervise(maxCelsius: 90, isManualEngaged: { _ in true }), .keep)
        XCTAssertEqual(core.supervise(maxCelsius: 98, isManualEngaged: { _ in true }), .fired)
        XCTAssertEqual(resets(), 1)
        XCTAssertTrue(core.tripLatched)
        XCTAssertNil(core.holder)
        XCTAssertTrue(core.heldTargets.isEmpty)
        XCTAssertEqual(core.supervise(maxCelsius: 98, isManualEngaged: { _ in true }), .stop)
    }

    func testSuperviseReassertsOnceThenReleases() {
        let (core, _) = makeCore()
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        _ = core.manualRequest(index: 1, rpm: 3100, holder: idA, maxCelsius: 50, macOSRPM: nil)
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { $0 == 0 }), .reassert([1]))
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in true }), .keep,
                       "healthy tick refills the budget")
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .reassert([0, 1]))
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .release([0, 1]))
        core.didResetAll()   // the daemon's reset succeeded
        XCTAssertNil(core.holder)
        XCTAssertTrue(core.heldTargets.isEmpty)
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .stop)
    }

    /// #221 (6): the release reset failed (no didResetAll). The fans are still held,
    /// so the next tick must release again instead of going quiet.
    func testFailedReleaseResetIsRetriedNextTick() {
        let (core, _) = makeCore()
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .reassert([0]))
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .release([0]))
        XCTAssertTrue(core.manualHeld)
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .release([0]),
                       "failed reset: still supervised, retried")
        XCTAssertEqual(core.holder, idA, "a holder drop still resets meanwhile")
    }

    /// #259 (QA #74 eW4): the daemon's `.release` goes through `releaseAll`. A failed
    /// reset must not disarm (fans still pinned, nothing supervising); a later
    /// successful one does.
    func testReleaseAllDisarmsOnlyOnASuccessfulReset() {
        var resetWorks = false
        let core = FanControlCore(reset: { resetWorks }, maxCelsius: { nil })
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .reassert([0]))
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .release([0]))
        XCTAssertFalse(core.releaseAll())
        XCTAssertTrue(core.manualHeld, "failed reset keeps supervision armed")
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .release([0]))
        resetWorks = true
        XCTAssertTrue(core.releaseAll())
        XCTAssertFalse(core.manualHeld)
        XCTAssertEqual(core.supervise(maxCelsius: 60, isManualEngaged: { _ in false }), .stop)
    }

    /// #259 (QA #74 eW5): the daemon's cold start is `reclaimAtStartup()`, which reads
    /// the injected hottest sensor itself — a hot start latches, a cool one doesn't.
    func testColdStartReadsTheInjectedTemperature() {
        let hot = FanControlCore(reset: { true }, maxCelsius: { 100 })
        hot.reclaimAtStartup()
        XCTAssertTrue(hot.tripLatched)
        XCTAssertFalse(hot.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 90, macOSRPM: nil))
        let cool = FanControlCore(reset: { true }, maxCelsius: { 60 })
        cool.reclaimAtStartup()
        XCTAssertFalse(cool.tripLatched)
        XCTAssertTrue(cool.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 60, macOSRPM: nil))
    }

    /// #221 (5): setFanAuto on the last pinned fan (the per-client release #219 took
    /// out) must not clear a standing trip latch.
    func testAutoAppliedKeepsTheLatch() {
        let (core, _) = makeCore()
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        XCTAssertEqual(core.supervise(maxCelsius: 98, isManualEngaged: { _ in true }), .fired)
        XCTAssertTrue(core.autoApplied(index: 0, holdUnlock: true, hasFtst: true))
        XCTAssertTrue(core.tripLatched)
        XCTAssertFalse(core.autoApplied(index: 0, holdUnlock: false, hasFtst: true))
        XCTAssertTrue(core.tripLatched)
        core.connectionClosed(idA)
        XCTAssertTrue(core.tripLatched)
    }

    /// #221 (4): the latch is helper memory only and the helper idle-exits; a cold
    /// start into a chassis at the cut-off latches again.
    func testColdStartIntoHotChassisLatches() {
        let (core, resets) = makeCore()
        core.reclaimAtStartup(maxCelsius: FanControlCore.killSwitchCelsius)
        XCTAssertEqual(resets(), 1)
        XCTAssertTrue(core.tripLatched)
        XCTAssertFalse(core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 90, macOSRPM: nil))
        core.reclaimAtStartup(maxCelsius: FanControlCore.killSwitchCelsius - 0.1)
        XCTAssertFalse(core.tripLatched)
        core.reclaimAtStartup(maxCelsius: .nan)
        XCTAssertFalse(core.tripLatched)
    }

    /// #221 (2): the re-arm read must fail as a whole when any sensor fails — a max
    /// over the rest can sit under re-arm while the hottest one is unreadable.
    func testHottestCompleteFailsOnAnyMissingRead() {
        XCTAssertNil(SMCFanController.hottest([60, nil, 70], complete: true))
        XCTAssertNil(SMCFanController.hottest([60, .nan], complete: true))
        XCTAssertEqual(SMCFanController.hottest([60, nil, 70], complete: false), 70,
                       "kill-switch tick still sees the readable sensors")
        XCTAssertEqual(SMCFanController.hottest([60, 5, 140, 70], complete: true), 70,
                       "implausible values are skipped, not failures")
        XCTAssertNil(SMCFanController.hottest([], complete: true))
    }

    /// resetAllFans goes through didResetAll: holder and targets go with it, so a
    /// later drop or tick has nothing to act on.
    func testResetAllClearsHolderAndTargets() {
        let (core, resets) = makeCore()
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        core.didResetAll()
        XCTAssertNil(core.holder)
        XCTAssertTrue(core.heldTargets.isEmpty)
        XCTAssertEqual(core.supervise(maxCelsius: 98, isManualEngaged: { _ in false }), .stop)
        core.connectionClosed(idA)
        XCTAssertEqual(resets(), 0)
    }

    /// setFanAuto: one fan back to auto keeps the pin on the others; the last one
    /// with the hold kept arms supervision of the unlock.
    func testAutoAppliedDropsTargetAndHoldsUnlockOnLastFan() {
        let (core, _) = makeCore()
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        _ = core.manualRequest(index: 1, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        var ftstReads = 0
        func ftst() -> Bool { ftstReads += 1; return true }
        XCTAssertFalse(core.autoApplied(index: 0, holdUnlock: true, hasFtst: ftst()))
        XCTAssertEqual(core.heldTargets, [1: 3000])
        XCTAssertTrue(core.manualHeld, "a sibling is still pinned")
        XCTAssertEqual(ftstReads, 0, "no SMC read while a fan is still pinned")
        XCTAssertTrue(core.autoApplied(index: 1, holdUnlock: true, hasFtst: ftst()))
        XCTAssertTrue(core.unlockHeld)
        XCTAssertFalse(core.manualHeld)
        XCTAssertTrue(core.heldTargets.isEmpty)
    }

    func testAutoAppliedWithoutHoldOrFtstArmsNothing() {
        let (core, _) = makeCore()
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        XCTAssertFalse(core.autoApplied(index: 0, holdUnlock: false, hasFtst: true))
        XCTAssertFalse(core.unlockHeld)
        XCTAssertTrue(core.manualHeld, "single-fan auto does not disarm the crash reset")
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        XCTAssertFalse(core.autoApplied(index: 0, holdUnlock: true, hasFtst: false))
        XCTAssertFalse(core.unlockHeld)
    }

    /// Only the holder's drop resets; the lid connection closing is a no-op.
    func testOnlyTheHoldersDropResets() {
        let (core, resets) = makeCore()
        _ = core.manualRequest(index: 0, rpm: 3000, holder: idA, maxCelsius: 50, macOSRPM: nil)
        core.connectionClosed(idB)
        XCTAssertEqual(resets(), 0)
        XCTAssertTrue(core.manualHeld)
        core.connectionClosed(idA)
        XCTAssertEqual(resets(), 1)
        XCTAssertNil(core.holder)
        XCTAssertTrue(core.heldTargets.isEmpty)
    }
}
