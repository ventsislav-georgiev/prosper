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
}
