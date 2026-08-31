import XCTest
@testable import ProsperApp

final class FanReclaimRecoveryTests: XCTestCase {
    @MainActor
    func testStartupArmsRecoveryBeforeHelperRegistration() {
        let previousManualIntent = Preferences.fanManualEnabled
        Preferences.fanManualEnabled = false
        defer { Preferences.fanManualEnabled = previousManualIntent }

        FanControlHelper.reapplyFromPreferences()
        XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed)
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
