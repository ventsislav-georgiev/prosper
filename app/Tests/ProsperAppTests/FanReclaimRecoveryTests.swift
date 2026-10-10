import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

final class FanReclaimRecoveryTests: XCTestCase {
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

    /// #263 (2): a teardown must not invalidate the connection an engage picked up
    /// while the reset was in flight. The fake points at a mach name nothing serves,
    /// so the reset errors out at once and no helper is involved.
    @MainActor
    func testTeardownKeepsTheConnectionAnEngageIsUsing() async {
        let fake = NSXPCConnection(machServiceName: "eu.illegible.prosper.tests.no-such-helper")
        fake.remoteObjectInterface = NSXPCInterface(with: ProsperHelperProtocol.self)
        fake.resume()
        defer { fake.invalidate(); FanControlHelper.connection = nil; FanControlHelper.engagesInFlight = 0 }
        FanControlHelper.connection = fake
        FanControlHelper.engagesInFlight = 1
        await FanControlHelper.resetAll(teardown: true)
        XCTAssertTrue(FanControlHelper.connection === fake, "an engage in flight keeps its connection")
        FanControlHelper.engagesInFlight = 0
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
        let reengaged = await FanControlHelper.applySavedTargets(reclaimGeneration: FanControlHelper.reclaimGeneration) { index, _, _ in
            engaged.append(index)
            Preferences.fanManualEnabled = false   // the popup's Automatic, between fan 0 and fan 1
            return true
        }
        XCTAssertEqual(engaged.count, 1, "a fan after the disable was engaged: \(engaged)")
        XCTAssertFalse(reengaged)
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
        await FanControlHelper.settleReclaim(.retry, now: t)
        XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(1)))
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(FanReclaimRecovery.retryCooldown)))
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
