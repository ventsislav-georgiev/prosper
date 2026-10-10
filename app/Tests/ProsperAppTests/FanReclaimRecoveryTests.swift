import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

final class FanReclaimRecoveryTests: XCTestCase {
    /// #305: armRecoveryLifecycle installs real NSWorkspace sleep/wake observers; a real
    /// sleep+wake later in the xctest process would drive real fan writes. Remove them.
    override func tearDown() {
        MainActor.assumeIsolated { FanControlHelper.removeSleepObservers() }
        super.tearDown()
    }

    @MainActor
    func testRemoveSleepObserversLeavesNoObserver() async {
        let previousManualIntent = Preferences.fanManualEnabled
        Preferences.fanManualEnabled = false
        defer { Preferences.fanManualEnabled = previousManualIntent }

        FanControlHelper.armRecoveryLifecycle()
        XCTAssertEqual(FanControlHelper.sleepObserverTokens.count, 2)
        FanControlHelper.armRecoveryLifecycle()
        XCTAssertEqual(FanControlHelper.sleepObserverTokens.count, 2, "re-arming installs nothing twice")
        FanControlHelper.removeSleepObservers()
        XCTAssertEqual(FanControlHelper.sleepObserverTokens.count, 0)
        XCTAssertFalse(FanControlHelper.recoveryLifecycleArmed)
        await FanControlHelper.resetAll(teardown: true)
    }

    /// Launch with fan control never enabled must not install the 2 s reclaim timer
    /// (it used to run for the whole app lifetime: ~43k wakeups/day for nothing).
    @MainActor
    func testStartupWithoutManualIntentInstallsNothing() {
        let previousManualIntent = Preferences.fanManualEnabled
        Preferences.fanManualEnabled = false
        defer { Preferences.fanManualEnabled = previousManualIntent }

        FanControlHelper.reapplyFromPreferences()
        XCTAssertFalse(FanControlHelper.recoveryLifecycleArmed)
    }

    /// Disabling fan control removes the timer, even with no helper connection open.
    @MainActor
    func testDisableRemovesTheReclaimTimer() async {
        let previousManualIntent = Preferences.fanManualEnabled
        Preferences.fanManualEnabled = false   // keeps any tick in this window a no-op
        defer { Preferences.fanManualEnabled = previousManualIntent }

        FanControlHelper.armRecoveryLifecycle()
        XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed)
        await FanControlHelper.resetAll(teardown: true)
        XCTAssertFalse(FanControlHelper.recoveryLifecycleArmed)
    }

    /// #221 (1): a failed popup first engage (no saved intent) drops the 2 s timer the
    /// engage armed; with saved intent (a later commit failing) the timer stays.
    @MainActor
    func testFailedFirstEngageDropsTheReclaimTimer() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = false
        FanControlHelper.armRecoveryLifecycle()
        XCTAssertTrue(FanControlHelper.firstEngageLanded(.engaged))
        XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed, "a landed engage keeps its timer")
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.unavailable))   // #259 eW1: the popup's path
        XCTAssertFalse(FanControlHelper.recoveryLifecycleArmed)

        Preferences.fanManualEnabled = true
        FanControlHelper.armRecoveryLifecycle()
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.refused))
        XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed)
        Preferences.fanManualEnabled = false
        await FanControlHelper.resetAll(teardown: true)
    }

    /// #263 ordering B, step 2: N landed late and was held for N+1; N+1 fails with
    /// manual off → everything is released. With manual on (a later commit failing),
    /// or on success, nothing is.
    @MainActor
    func testFailedFirstEngageReleasesTheHeldPin() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = false
        let released = expectation(description: "failed engage releases")
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.unavailable, release: { released.fulfill() }))
        await fulfillment(of: [released], timeout: 1)

        let kept = expectation(description: "no release")
        kept.isInverted = true
        XCTAssertTrue(FanControlHelper.firstEngageLanded(.engaged, release: { kept.fulfill() }))
        Preferences.fanManualEnabled = true
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.refused, release: { kept.fulfill() }))
        await fulfillment(of: [kept], timeout: 0.3)
    }

    /// #269: a re-apply engage that timed out (ResumeOnce already resumed nil) and
    /// whose `true` lands later with manual off pins the fan → released. With manual
    /// on, or a late refusal, nothing is.
    @MainActor
    func testLateEngageAfterTimeoutReleasesWithManualOff() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        var once: FanControlHelper.ResumeOnce?
        let timedOut: Bool? = await withCheckedContinuation { cont in
            once = FanControlHelper.ResumeOnce(cont)
            XCTAssertTrue(once!.resume(nil))   // the timeout wins
        }
        XCTAssertNil(timedOut)
        XCTAssertFalse(once!.resume(true))      // the helper's reply arrives late

        Preferences.fanManualEnabled = false
        let released = expectation(description: "late engage released")
        FanControlHelper.lateEngageLanded(true, release: { released.fulfill() })
        await fulfillment(of: [released], timeout: 1)

        let kept = expectation(description: "no release")
        kept.isInverted = true
        FanControlHelper.lateEngageLanded(false, release: { kept.fulfill() })
        Preferences.fanManualEnabled = true
        FanControlHelper.lateEngageLanded(true, release: { kept.fulfill() })
        await fulfillment(of: [kept], timeout: 0.3)
    }

    /// A late engage landing while the popup's first engage is in flight is held:
    /// manual is still off then, but that engage owns the fans (#282).
    @MainActor
    func testLateEngageHeldWhileEngageInFlight() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = false
        let kept = expectation(description: "no release")
        kept.isInverted = true
        FanControlHelper.lateEngageLanded(true, sleeping: false, inFlight: 1, release: { kept.fulfill() })
        await fulfillment(of: [kept], timeout: 0.3)
    }

    /// callReply wiring: the first reply resumes the continuation, a second
    /// (late) one goes to `late` exactly once with its value, never the first (#282).
    func testCallReplyRoutesLateReplyToLateHook() async {
        final class Proxy: NSObject, ProsperHelperProtocol {
            func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void) {}
            func setRemoteWake(_ json: String, withReply reply: @escaping (Bool) -> Void) {}
            func setRemoteSessionActive(_ on: Bool, withReply reply: @escaping (Bool) -> Void) {}
            func clearRemoteSession(withReply reply: @escaping (Bool) -> Void) {}
            func sleepNow(withReply reply: @escaping (Bool) -> Void) {}
            func setFanManualRPM(_ index: Int, rpm: Double, withReply reply: @escaping (Bool) -> Void) {}
            func setFanAuto(_ index: Int, holdUnlock: Bool, withReply reply: @escaping (Bool) -> Void) {}
            func resetAllFans(withReply reply: @escaping (Bool) -> Void) {}
        }
        final class Conn: NSXPCConnection {
            override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any { Proxy() }
        }
        let late = expectation(description: "late hook once")
        let lateValue = LockedBox()
        let result = await FanControlHelper.callReply(Conn(), timeout: 5, late: { ok in
            lateValue.set(ok); late.fulfill()
        }) { _, done in
            done(true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { done(false) }
        }
        XCTAssertEqual(result, true)   // a second resume would crash the checked continuation
        await fulfillment(of: [late], timeout: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(lateValue.get(), [false])
    }

    /// Asleep, a late engage is released even with manual on (#275).
    @MainActor
    func testLateEngageDuringSleepReleasesWithManualOn() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = true
        let released = expectation(description: "released during sleep")
        FanControlHelper.lateEngageLanded(true, sleeping: true, release: { released.fulfill() })
        await fulfillment(of: [released], timeout: 1)
        let kept = expectation(description: "no release awake")
        kept.isInverted = true
        FanControlHelper.lateEngageLanded(true, sleeping: false, release: { kept.fulfill() })
        await fulfillment(of: [kept], timeout: 0.3)
    }

    /// #263 (2): a teardown must not invalidate the connection an engage picked up
    /// while the reset was in flight. The fake points at a mach name nothing serves,
    /// so the reset errors out at once and no helper is involved.
    @MainActor
    func testTeardownKeepsTheConnectionAnEngageIsUsing() async {
        let fake = NSXPCConnection(machServiceName: "eu.illegible.prosper.tests.no-such-helper")
        fake.remoteObjectInterface = NSXPCInterface(with: ProsperHelperProtocol.self)
        fake.resume()
        defer { fake.invalidate(); FanControlHelper.inject(connection: nil, engagesInFlight: 0) }
        FanControlHelper.inject(connection: fake, engagesInFlight: 1)
        await FanControlHelper.resetAll(teardown: true)
        XCTAssertTrue(FanControlHelper.connection === fake, "an engage in flight keeps its connection")
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        await FanControlHelper.resetAll(teardown: true)
        XCTAssertNil(FanControlHelper.connection)
    }

    /// #267: Automatic landing while a re-apply is between fans stops the loop; the
    /// later fans are not pinned again. `engage` is a fake: no helper, no SMC.
    @MainActor
    func testDisableMidReapplyStopsTheRemainingFans() async {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer { Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets }
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [0: 2000, 1: 3000]
        var engaged: [Int] = []
        let reengaged = await FanControlHelper.applySavedTargets(reclaimGeneration: FanControlHelper.reclaimGeneration, engage: { index, _, _ in
            engaged.append(index)
            Preferences.fanManualEnabled = false   // the popup's Automatic, between fan 0 and fan 1
            return true
        }, reset: { _ in true })
        XCTAssertEqual(engaged.count, 1, "a fan after the disable was engaged: \(engaged)")
        XCTAssertFalse(reengaged)
    }

    /// #277: Automatic landing while the only engage is suspended (e.g. reconnecting) —
    /// the engage still pins, so applySavedTargets must release it and report false.
    @MainActor
    func testDisableDuringEngageReleasesThePin() async {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer { Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets }
        Preferences.fanTargets = [0: 2000]
        for disable in [true, false] {
            Preferences.fanManualEnabled = true
            var resets: [Bool] = []
            let reengaged = await FanControlHelper.applySavedTargets(
                reclaimGeneration: FanControlHelper.reclaimGeneration,
                engage: { _, _, _ in
                    if disable { Preferences.fanManualEnabled = false }
                    return true
                },
                reset: { resets.append($0); return true })
            XCTAssertEqual(resets, disable ? [true] : [], "disable=\(disable)")
            XCTAssertEqual(reengaged, !disable, "disable=\(disable)")
        }
    }

    /// #278: willSleep landing while the engage is suspended — release the pin, report false.
    @MainActor
    func testSleepDuringEngageReleasesThePin() async {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer { Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets
                FanControlHelper.inject(sleeping: false) }
        Preferences.fanTargets = [0: 2000]
        Preferences.fanManualEnabled = true
        var resets: [Bool] = []
        let reengaged = await FanControlHelper.applySavedTargets(
            reclaimGeneration: FanControlHelper.reclaimGeneration,
            engage: { _, _, _ in FanControlHelper.inject(sleeping: true); return true },
            reset: { resets.append($0); return true })
        XCTAssertEqual(resets, [false], "manual on: reset without teardown (#287)")
        XCTAssertFalse(reengaged)
    }

    /// #285: Automatic or willSleep landing while a FAILED engage is in flight still
    /// releases — an older late engage held for it (#282) may be pinned.
    @MainActor
    func testFailedEngageAfterAutomaticOrSleepReleasesTheHeldPin() async {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer { Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets
                FanControlHelper.inject(sleeping: false) }
        Preferences.fanTargets = [0: 2000]
        for sleep in [false, true] {
            Preferences.fanManualEnabled = true
            FanControlHelper.inject(sleeping: false)
            var resets: [Bool] = []
            let reengaged = await FanControlHelper.applySavedTargets(
                reclaimGeneration: FanControlHelper.reclaimGeneration,
                engage: { _, _, _ in
                    if sleep { FanControlHelper.inject(sleeping: true) } else { Preferences.fanManualEnabled = false }
                    return false
                },
                reset: { resets.append($0); return true })
            XCTAssertEqual(resets, [!sleep], "sleep=\(sleep): teardown only with manual off (#287)")
            XCTAssertFalse(reengaged, "sleep=\(sleep)")
        }
    }

    /// #287 item 3: Automatic landing during a failed engage of fan 0 stops the loop —
    /// fan 1 is never engaged, one releasing reset, result false.
    @MainActor
    func testAutomaticDuringFailedEngageStopsTheRemainingFans() async {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer { Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets }
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [0: 2000, 1: 3000]
        var engaged: [Int] = []
        var resets: [Bool] = []
        let reengaged = await FanControlHelper.applySavedTargets(
            reclaimGeneration: FanControlHelper.reclaimGeneration,
            engage: { index, _, _ in
                engaged.append(index)
                Preferences.fanManualEnabled = false
                return false
            },
            reset: { resets.append($0); return true })
        XCTAssertEqual(engaged.count, 1, "a fan after Automatic was engaged: \(engaged)")
        XCTAssertEqual(resets, [true])
        XCTAssertFalse(reengaged)
    }

    /// #287 (a): willSleep resets with an engage in flight even before the pref is saved.
    @MainActor
    func testSleepResetCoversAnEngageInFlight() {
        XCTAssertTrue(FanControlHelper.sleepResetNeeded(manualEnabled: false, inFlight: 1))
        XCTAssertTrue(FanControlHelper.sleepResetNeeded(manualEnabled: true, inFlight: 0))
        XCTAssertFalse(FanControlHelper.sleepResetNeeded(manualEnabled: false, inFlight: 0))
    }

    /// #287 (b): the popup's first engage landing on time while asleep is released and
    /// reported false, so the popup does not save the pref. Awake, it stands.
    @MainActor
    func testFirstEngageLandingAsleepIsReleased() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = false
        let released = expectation(description: "released while asleep")
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.engaged, sleeping: true, release: { released.fulfill() }))
        await fulfillment(of: [released], timeout: 1)
        let kept = expectation(description: "no release awake")
        kept.isInverted = true
        XCTAssertTrue(FanControlHelper.firstEngageLanded(.engaged, sleeping: false, release: { kept.fulfill() }))
        await fulfillment(of: [kept], timeout: 0.3)
    }

    /// #287 item 2: a sleep release with manual on keeps the reclaim timer (wake does
    /// not re-arm it when the helper is unreachable); with manual off it tears down.
    @MainActor
    func testSleepReleaseKeepsTheReclaimTimerWithManualOn() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = true
        FanControlHelper.armRecoveryLifecycle()
        await FanControlHelper.sleepSafeRelease()
        XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed)
        Preferences.fanManualEnabled = false
        await FanControlHelper.sleepSafeRelease()
        XCTAssertFalse(FanControlHelper.recoveryLifecycleArmed)
    }

    /// #221 (3): a failed reclaim re-apply holds the next attempt for 30 s.
    @MainActor
    func testFailedReapplyCoolsDownForThirtySeconds() {
        let previousManualIntent = Preferences.fanManualEnabled
        defer {
            Preferences.fanManualEnabled = previousManualIntent
            FanControlHelper.deferReclaimRetry(now: .distantPast)
        }
        Preferences.fanManualEnabled = true
        let t = Date()
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: t))
        FanControlHelper.deferReclaimRetry(now: t)
        XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(29)))
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(FanReclaimRecovery.retryCooldown)))
        XCTAssertEqual(FanReclaimRecovery.retryCooldown, 30)
    }

    /// #259 (QA #74 eW2): the timer's tick honours the cooldown — no fan read inside
    /// it, one after it. `read` is a fake: no SMC.
    @MainActor
    func testReclaimTickSkipsTheReadDuringTheCooldown() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer {
            Preferences.fanManualEnabled = previousManualIntent
            FanControlHelper.deferReclaimRetry(now: .distantPast)
        }
        Preferences.fanManualEnabled = true
        let t = Date()
        FanControlHelper.deferReclaimRetry(now: t)
        let early = expectation(description: "read inside the cooldown")
        early.isInverted = true
        FanControlHelper.reclaimTick(now: t.addingTimeInterval(1), read: { early.fulfill(); return [] })
        await fulfillment(of: [early], timeout: 0.3)
        let late = expectation(description: "read after the cooldown")
        FanControlHelper.reclaimTick(now: t.addingTimeInterval(FanReclaimRecovery.retryCooldown), read: { late.fulfill(); return [] })
        await fulfillment(of: [late], timeout: 2)
        // Let the read's MainActor hop clear the in-flight flag before the next test.
        for _ in 0..<200 where !FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(FanReclaimRecovery.retryCooldown)) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// #259 (QA #74 eW3): a `.retry` outcome starts the cooldown.
    @MainActor
    func testRetryOutcomeStartsTheCooldown() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer {
            Preferences.fanManualEnabled = previousManualIntent
            FanControlHelper.deferReclaimRetry(now: .distantPast)
        }
        Preferences.fanManualEnabled = true
        let t = Date()
        var resets: [Bool] = []
        await FanControlHelper.settleReclaim(.retry, now: t) { resets.append($0); return true }
        XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(1)))
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(FanReclaimRecovery.retryCooldown)))
        await FanControlHelper.settleReclaim(.restored, now: t) { resets.append($0); return true }
        await FanControlHelper.settleReclaim(.abandonManualIntent, now: t) {
            XCTAssertFalse(Preferences.fanManualEnabled, "abandon must drop the pref before the reset")
            resets.append($0); return true
        }
        XCTAssertEqual(resets, [false, true], "retry resets once, restored never, abandon tears down once")
    }

    func testReclaimKeepsEligibleIntentAcrossFailedRetry() {
        XCTAssertEqual(FanReclaimRecovery.disposition(manualFraction: 0.19, reengaged: true), .abandonManualIntent)
        XCTAssertEqual(FanReclaimRecovery.disposition(manualFraction: 0.20, reengaged: true), .restored)
        XCTAssertEqual(FanReclaimRecovery.disposition(manualFraction: 0.75, reengaged: false), .retry)
    }

    func testPersistentRecoveryDetectsOnlyFullReclaimAndUsesSavedTargets() {
        let reclaimed = [
            FanReading(id: 0, min: 1000, max: 5000, current: 1200, manual: false),
            FanReading(id: 1, min: 1000, max: 5000, current: 1200, manual: false),
        ]
        XCTAssertTrue(FanReclaimRecovery.reclaimDetected(reclaimed))
        XCTAssertEqual(FanReclaimRecovery.manualFraction(targets: [0: 1800, 1: 2600], readings: reclaimed) ?? -1,
                       0.3, accuracy: 0.000_001)
        XCTAssertFalse(FanReclaimRecovery.reclaimDetected([
            FanReading(id: 0, min: 1000, max: 5000, current: 1200, manual: true),
        ]))
        XCTAssertNil(FanReclaimRecovery.manualFraction(targets: [:], readings: reclaimed))
    }

    func testLifecycleRecoveryDoesNotRunWhileSleepingOrAlreadyRunning() {
        XCTAssertTrue(FanReclaimRecovery.canStartRecovery(manualIntent: true, sleeping: false, recoveryInFlight: false))
        XCTAssertFalse(FanReclaimRecovery.canStartRecovery(manualIntent: true, sleeping: true, recoveryInFlight: false))
        XCTAssertFalse(FanReclaimRecovery.canStartRecovery(manualIntent: true, sleeping: false, recoveryInFlight: true))
        XCTAssertFalse(FanReclaimRecovery.canStartRecovery(manualIntent: false, sleeping: false, recoveryInFlight: false))
    }
    // MARK: - Slider ownership (the mid-drag snap-back regression)

    /// The reported bug: slider reads 1%, user drags up, and on the next fan poll
    /// tick the popup re-seeds its targets from the store — which still holds 1%
    /// because the commit is debounced — snapping the value back, repeatedly.
    func testDragKeepsUserValueAgainstStaleStoreReSeeds() {
        let old: [Int: Double] = [0: 1040]        // ~1% of 1000…5000
        var owner = FanTargetOwner()
        owner.isDragging = true
        owner.userSet([0: 3000], store: old)
        XCTAssertEqual(owner.display(store: old), [0: 3000])   // poll tick mid-drag
        owner.userSet([0: 3400], store: old)
        XCTAssertEqual(owner.display(store: old), [0: 3400])   // and again, later in the drag
    }

    func testOwnershipHandsBackOnceTheCommitLands() {
        var owner = FanTargetOwner()
        owner.isDragging = true
        owner.userSet([0: 3000], store: [0: 1040])
        owner.isDragging = false                                // finger up
        XCTAssertEqual(owner.display(store: [0: 1040]), [0: 3000])  // commit not landed yet
        XCTAssertEqual(owner.display(store: [0: 3000]), [0: 3000])  // commit landed → hand back
        XCTAssertNil(owner.user)
        XCTAssertEqual(owner.display(store: [0: 4200]), [0: 4200])  // store owns again
    }

    /// A quick button (min/max) commits with no drag, and must survive the same
    /// debounce window; a third-party write (auto switch, reclaim) still wins.
    func testQuickButtonHeldAndThirdPartyWriteWins() {
        var owner = FanTargetOwner()
        owner.userSet([0: 5000], store: [0: 1040])
        XCTAssertEqual(owner.display(store: [0: 1040]), [0: 5000])
        XCTAssertEqual(owner.display(store: [:]), [:])          // switched to Automatic
        XCTAssertNil(owner.user)
    }

    func testReclaimRecoverySuspendedOnlyWhileTheUserIsAdjusting() {
        XCTAssertFalse(FanReclaimRecovery.canStartRecovery(manualIntent: true, sleeping: false,
                                                           recoveryInFlight: false, userAdjusting: true))
        XCTAssertTrue(FanReclaimRecovery.canStartRecovery(manualIntent: true, sleeping: false,
                                                          recoveryInFlight: false, userAdjusting: false))
    }
}

/// #215: a live helper's `false` (kill-switch latch) must not read as a missing helper,
/// and any failed commit must revert the slider (errorText non-nil ⇔ revert).
final class FanManualReplyTests: XCTestCase {
    func testRefusalReadsAsLatchNotMissingHelper() throws {
        let latched = try XCTUnwrap(FanManualReply.refused.errorText)
        XCTAssertTrue(latched.contains("held automatic until the Mac cools down"))
        XCTAssertFalse(latched.contains("helper"))
        let missing = try XCTUnwrap(FanManualReply.unavailable.errorText)
        XCTAssertTrue(missing.contains("isn’t running or wasn’t approved"))
        XCTAssertNil(FanManualReply.engaged.errorText)
    }

    func testCombineRefusalWinsThenUnavailable() {
        XCTAssertEqual(FanManualReply.combine([.engaged, .refused, .unavailable]), .refused)
        XCTAssertEqual(FanManualReply.combine([.engaged, .unavailable]), .unavailable)
        XCTAssertEqual(FanManualReply.combine([.engaged, .engaged]), .engaged)
    }
}

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: [Bool] = []
    func set(_ b: Bool) { lock.lock(); v.append(b); lock.unlock() }
    func get() -> [Bool] { lock.lock(); defer { lock.unlock() }; return v }
}
