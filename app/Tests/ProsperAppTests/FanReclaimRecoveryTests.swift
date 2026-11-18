import AppKit
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

    /// #737: the launch re-apply marks saved intent pending before it starts, so a refused
    /// launch re-apply keeps a low preset instead of the floor dropping it.
    @MainActor
    func testLaunchReapplyMarksThePresetPending() {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent; FanControlHelper.presetPending = false }
        Preferences.fanManualEnabled = true
        FanControlHelper.presetPending = false
        var pendingAtStart: Bool?
        FanControlHelper.reapplyFromPreferences(start: { pendingAtStart = FanControlHelper.presetPending })
        XCTAssertEqual(pendingAtStart, true, "the re-apply started without the preset marked pending")
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
        XCTAssertTrue(FanControlHelper.firstEngageLanded(.engaged, since: FanControlHelper.reclaimGeneration))
        XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed, "a landed engage keeps its timer")
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.unavailable, since: FanControlHelper.reclaimGeneration))   // #259 eW1: the popup's path
        XCTAssertFalse(FanControlHelper.recoveryLifecycleArmed)

        Preferences.fanManualEnabled = true
        FanControlHelper.armRecoveryLifecycle()
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.refused, since: FanControlHelper.reclaimGeneration))
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.settling, since: FanControlHelper.reclaimGeneration))
        XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed)
        XCTAssertTrue(Preferences.fanManualEnabled, "a refusal never flips manual off")
        Preferences.fanManualEnabled = false
        await FanControlHelper.resetAll(teardown: true)
    }

    /// #263 ordering B, step 2: N landed late and was held for N+1; N+1 fails → everything is
    /// released. R1215-1: with manual on too (a timed-out first engage may still pin its fan);
    /// on success nothing is.
    @MainActor
    func testFailedFirstEngageReleasesTheHeldPin() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = false
        let released = expectation(description: "failed engage releases")
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.unavailable, since: FanControlHelper.reclaimGeneration, release: { released.fulfill() }))
        await fulfillment(of: [released], timeout: 1)

        let kept = expectation(description: "no release")
        kept.isInverted = true
        XCTAssertTrue(FanControlHelper.firstEngageLanded(.engaged, since: FanControlHelper.reclaimGeneration, release: { kept.fulfill() }))
        Preferences.fanManualEnabled = true
        XCTAssertTrue(FanControlHelper.firstEngageLanded(.engaged, since: FanControlHelper.reclaimGeneration, release: { kept.fulfill() }))
        await fulfillment(of: [kept], timeout: 0.3)

        // #347 (2): a failed reply after a willSleep (generation changed) releases exactly
        // once per reply, manual off or on.
        let twice = expectation(description: "failed reply after a sleep releases once each")   // over-fulfill fails
        twice.expectedFulfillmentCount = 2
        Preferences.fanManualEnabled = false
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.unavailable, since: 4, current: 5, sleeping: true, release: { twice.fulfill() }))
        Preferences.fanManualEnabled = true
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.refused, since: 4, current: 5, sleeping: true, release: { twice.fulfill() }))
        await fulfillment(of: [twice], timeout: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)   // room for a third release to over-fulfill
    }

    /// R1215-1, the manual-on half: a failed first engage with manual already on releases every fan
    /// (no teardown: manual on) and keeps the saved targets and intent for the recovery to re-apply.
    /// Fake connection only; the fast re-engage pref off; scratch defaults.
    @MainActor
    func testFailedFirstEngageWithManualOnHandsBackAndKeepsTheTargets() async {
        let manual = Preferences.fanManualEnabled, targets = Preferences.fanTargets, hold = Preferences.fanHoldUnlock
        let pending = FanControlHelper.presetPending
        defer {
            Preferences.fanManualEnabled = manual; Preferences.fanTargets = targets; Preferences.fanHoldUnlock = hold
            FanControlHelper.presetPending = pending
            FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        }
        Preferences.fanHoldUnlock = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        await FanControlHelper.resetAll(teardown: true)   // no connection: no call; drops any timer
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [0: 2000, 1: 3000]
        FanControlHelper.presetPending = false
        for failure in [FanManualReply.unavailable, .needsApproval, .writeFailed] {
            let released = expectation(description: "\(failure) released with manual on")
            XCTAssertFalse(FanControlHelper.firstEngageLanded(failure, since: FanControlHelper.reclaimGeneration,
                                                              release: { released.fulfill() }))
            await fulfillment(of: [released], timeout: 1)
            XCTAssertTrue(Preferences.fanManualEnabled, "\(failure)")
            XCTAssertEqual(Preferences.fanTargets, [0: 2000, 1: 3000], "\(failure): the saved targets changed")
            XCTAssertFalse(FanControlHelper.presetPending, "\(failure): the floor exemption was set")
        }
        // The default release on a fake: one reset, no teardown (manual on keeps the connection).
        let fake = FakeHelperConnection()
        let reset = expectation(description: "the default release reset the fans")
        reset.assertForOverFulfill = false   // the count below says it
        fake.proxy.onReset = { reset.fulfill() }
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.unavailable, since: FanControlHelper.reclaimGeneration))
        await fulfillment(of: [reset], timeout: 2)
        fake.proxy.onReset = nil
        XCTAssertEqual(fake.proxy.resets, 1)
        XCTAssertTrue(FanControlHelper.connection === fake, "a manual-on release tore the connection down")
        Preferences.fanManualEnabled = false
        await FanControlHelper.resetAll(teardown: true)
    }

    /// #269: a re-apply engage that timed out (ResumeOnce already resumed nil) and
    /// whose `true` lands later with manual off pins the fan → released. A late refusal is
    /// not. R1225-1: with manual on it is released too (it was held before).
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
        await fulfillment(of: [kept], timeout: 0.3)
        Preferences.fanManualEnabled = true
        let manualOn = expectation(description: "late engage released with manual on (R1225-1)")
        FanControlHelper.lateEngageLanded(true, inFlight: 0, release: { manualOn.fulfill() })
        await fulfillment(of: [manualOn], timeout: 1)
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
        FanControlHelper.lateEngageLanded(true, inFlight: 1, release: { kept.fulfill() })
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
            func helperInfo(withReply reply: @escaping (Int, Int) -> Void) {}
            func setFanManualRPMWithReason(_ index: Int, rpm: Double, withReply reply: @escaping (Int) -> Void) {}
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

    /// Asleep, a late engage is released even with manual on (#275). R1225-1: awake too (it was held).
    @MainActor
    func testLateEngageDuringSleepReleasesWithManualOn() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = true
        let released = expectation(description: "released during sleep")
        FanControlHelper.lateEngageLanded(true, inFlight: 0, release: { released.fulfill() })
        await fulfillment(of: [released], timeout: 1)
        let awake = expectation(description: "released awake")
        FanControlHelper.lateEngageLanded(true, inFlight: 0, release: { awake.fulfill() })
        await fulfillment(of: [awake], timeout: 1)
    }

    /// R1225-1: registration slower than the 45 s ceiling, then the 35 s reply wait gave up too, and the helper's
    /// true arrives after both: with manual on, awake and nothing in flight, the default release hands every fan
    /// back (one reset on the fake, no teardown), and manual and the saved targets stay for the recovery to
    /// re-apply. Fake connection only; the fast re-engage pref off; scratch defaults.
    @MainActor
    func testLatePinAfterBothTimeoutsWithManualOnHandsBack() async {
        let manual = Preferences.fanManualEnabled, targets = Preferences.fanTargets, hold = Preferences.fanHoldUnlock
        defer {
            Preferences.fanManualEnabled = manual; Preferences.fanTargets = targets; Preferences.fanHoldUnlock = hold
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
        }
        Preferences.fanHoldUnlock = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        await FanControlHelper.resetAll(teardown: true)   // no connection: no call; drops any timer
        FanControlHelper.inject(sleeping: false)
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [0: 2000, 1: 3000]
        let fake = FakeHelperConnection()
        let reset = expectation(description: "the late pin was handed back")
        reset.assertForOverFulfill = false   // the count below says it
        fake.proxy.onReset = { reset.fulfill() }
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        FanControlHelper.lateEngageLanded(true)   // every default: live sleeping, in flight and release
        await fulfillment(of: [reset], timeout: 2)
        fake.proxy.onReset = nil
        XCTAssertEqual(fake.proxy.resets, 1)
        XCTAssertTrue(FanControlHelper.connection === fake, "a manual-on release tore the connection down")
        XCTAssertTrue(Preferences.fanManualEnabled)
        XCTAssertEqual(Preferences.fanTargets, [0: 2000, 1: 3000], "the saved targets changed")
        Preferences.fanManualEnabled = false
        await FanControlHelper.resetAll(teardown: true)
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

    /// #393: a hand-edited plist with "1", "01" and "+1" keys must not trap the getter. #1223 (R1223-2): a
    /// non-canonical key is damage like an unusable speed: no targets at all, never the canonical fan alone.
    func testFanTargetsWithANonCanonicalKeyReadAsNoTargets() {
        let previousTargets = Preferences.fanTargets
        defer { Preferences.fanTargets = previousTargets }
        Preferences.defaults.set(["1": 2000.0, "01": 2500.0, "+1": 3000.0, "x": 1.0], forKey: "fanTargets")
        XCTAssertEqual(Preferences.fanTargets, [:])
        Preferences.defaults.set(["1": 2000.0, "01": 2500.0], forKey: "fanTargets")
        XCTAssertEqual(Preferences.fanTargets, [:])
        Preferences.defaults.set(["0": 2000.0, "1": 2500.0, "x": 1.0], forKey: "fanTargets")
        XCTAssertEqual(Preferences.fanTargets, [:])
        Preferences.defaults.set(["0": 2000.0, "1": 2500.0], forKey: "fanTargets")
        XCTAssertEqual(Preferences.fanTargets, [0: 2000, 1: 2500])
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

    /// #287 (b), #345: the popup's first engage landing after a willSleep since the popup
    /// captured the generation (asleep, or after the wake) is released and reported
    /// false, so the popup does not save the pref. No sleep since, it stands.
    @MainActor
    func testFirstEngageLandingAfterASleepIsReleased() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = false
        let released = expectation(description: "released after a willSleep")
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.engaged, since: 4, current: 5, release: { released.fulfill() }))
        await fulfillment(of: [released], timeout: 1)
        XCTAssertFalse(Preferences.fanManualEnabled)
        let kept = expectation(description: "no release without a sleep")
        kept.isInverted = true
        XCTAssertTrue(FanControlHelper.firstEngageLanded(.engaged, since: 5, current: 5, release: { kept.fulfill() }))
        await fulfillment(of: [kept], timeout: 0.3)
        // #347: captured while already asleep (generation unchanged) is released too.
        let asleep = expectation(description: "released when captured asleep")
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.engaged, since: 5, current: 5, sleeping: true,
                                                          release: { asleep.fulfill() }))
        await fulfillment(of: [asleep], timeout: 1)
        XCTAssertFalse(Preferences.fanManualEnabled)
    }

    /// #306: a later popup engage landing after a willSleep (asleep, or after the wake,
    /// #343) releases and returns false, so the loop stops and the pref stays unsaved.
    /// No sleep since the loop began, the loop goes on.
    @MainActor
    func testLaterEngageLandingAfterASleepIsReleased() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent }
        Preferences.fanManualEnabled = false
        let released = expectation(description: "released after a willSleep")
        XCTAssertFalse(FanControlHelper.laterEngageLanded(since: 4, current: 5, release: { released.fulfill() }))
        await fulfillment(of: [released], timeout: 1)
        XCTAssertFalse(Preferences.fanManualEnabled)
        let kept = expectation(description: "no release without a sleep")
        kept.isInverted = true
        XCTAssertTrue(FanControlHelper.laterEngageLanded(since: 5, current: 5, release: { kept.fulfill() }))
        await fulfillment(of: [kept], timeout: 0.3)
    }

    /// #343: a later engage waiting for the helper registration counts as in flight, so a
    /// willSleep then resets the first fan's pin; after the wake the loop releases and the
    /// pref stays unsaved. Registration and connection are fakes: no helper, no SMC.
    @MainActor
    func testSleepWhileALaterEngageWaitsForRegistrationResetsAndAbandons() async {
        let previousManualIntent = Preferences.fanManualEnabled, savedRegistration = LidSleepHelper.registration
        let fake = FakeHelperConnection()
        defer {
            Preferences.fanManualEnabled = previousManualIntent; LidSleepHelper.registration = savedRegistration
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
        }
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)   // fan 0's engage landed
        let parked = expectation(description: "fan 1's engage waits in registration")
        let gate = DispatchSemaphore(value: 0)
        LidSleepHelper.registration = { parked.fulfill(); gate.wait(); return .failed }
        let rest = Task { await FanControlHelper.engageRest([0: 2000, 1: 3000], skipping: 0) }
        await fulfillment(of: [parked], timeout: 2)
        XCTAssertTrue(FanControlHelper.sleepResetNeeded(), "an engage waiting for registration is in flight")
        FanControlHelper.willSleep()
        XCTAssertEqual(fake.proxy.resets, 1, "willSleep reset fan 0's pin")
        FanControlHelper.inject(sleeping: false)   // the wake
        gate.signal()
        let saved = await rest.value
        XCTAssertTrue(saved == nil, "the popup saved the pref after a sleep inside its engage loop")
        await waitForTeardown()
        XCTAssertEqual(fake.proxy.resets, 2, "the loop released after the wake")
        XCTAssertTrue(FanControlHelper.connection == nil, "the loop's release did not tear down")
    }

    /// #479: with a pin set, an XPC error during willSleep runs the error handler on
    /// XPC's own queue. Without @Sendable that closure is inferred MainActor and traps
    /// on its executor check; with it, willSleep returns at once, not at the 2 s bound.
    @MainActor
    func testWillSleepSurvivesAnXPCErrorOffMain() {
        let previousManualIntent = Preferences.fanManualEnabled
        let fake = FakeHelperConnection()
        fake.failOffMain = true
        defer {
            Preferences.fanManualEnabled = previousManualIntent
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
        }
        Preferences.fanManualEnabled = true
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        XCTAssertTrue(FanControlHelper.sleepResetNeeded())
        let start = Date()
        FanControlHelper.willSleep()
        XCTAssertEqual(fake.proxy.resets, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "only the off-main error handler can end the wait")
    }

    /// #345: the popup's FIRST engage waits in registration when willSleep fires; willSleep
    /// resets (the engage is in flight), the wake follows, then the engage replies. The flow
    /// (as in StatsPopupView.confirmManualAll, generation captured before the first engage)
    /// releases, never engages another fan and does not save the pref. Fakes only.
    @MainActor
    func testSleepWhileTheFirstEngageWaitsForRegistrationAbandons() async {
        let previousManualIntent = Preferences.fanManualEnabled, savedRegistration = LidSleepHelper.registration
        let fake = FakeHelperConnection()
        defer {
            Preferences.fanManualEnabled = previousManualIntent; LidSleepHelper.registration = savedRegistration
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
        }
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        let parked = expectation(description: "the first engage waits in registration")
        let gate = DispatchSemaphore(value: 0)
        LidSleepHelper.registration = { parked.fulfill(); gate.wait(); return .enabled }
        var restEngaged: [Int] = []
        let flow = Task { () -> Bool in
            let generation = FanControlHelper.reclaimGeneration
            let reply = await FanControlHelper.setManualReply(0, rpm: 2000)
            XCTAssertEqual(reply, .engaged)
            guard FanControlHelper.firstEngageLanded(reply, since: generation) else { return false }
            return await FanControlHelper.engageRest([0: 2000, 1: 3000], skipping: 0, since: generation,
                                                     engage: { i, _ in restEngaged.append(i); return .engaged }) == .engaged
        }
        await fulfillment(of: [parked], timeout: 2)
        FanControlHelper.willSleep()
        XCTAssertEqual(fake.proxy.resets, 1, "willSleep reset with the first engage in flight")
        FanControlHelper.inject(sleeping: false)   // the wake
        gate.signal()
        let saved = await flow.value
        XCTAssertFalse(saved, "the first engage stood after a whole sleep+wake")
        XCTAssertEqual(restEngaged, [], "the flow went on to engage the other fans")
        XCTAssertFalse(Preferences.fanManualEnabled)
        await waitForTeardown()
        XCTAssertEqual(fake.proxy.resets, 2, "the abandoned engage was released")
        XCTAssertTrue(FanControlHelper.connection == nil, "the release did not tear down")
    }

    /// #345: the popup engage flow reads any reclaimGeneration bump as a sleep, so the bump
    /// lives in exactly one place, willSleep in FanControlHelper.swift.
    func testReclaimGenerationIsBumpedOnlyByWillSleep() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var hits: [String] = []
        let write = try Regex(#"reclaimGeneration\s*(&\+=|\+=|-=|=(?!=))"#)
        for case let url as URL in files where url.pathExtension == "swift" {
            // Any write (&+=, +=, -=, =), not just the one literal (#347); the declaration is not a bump.
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            where line.contains(write) && !line.contains("private(set) static var reclaimGeneration = 0") {
                hits.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(hits, ["FanControlHelper.swift: reclaimGeneration &+= 1"])
    }

    /// #343 (2), the route QA #123 left open: a later engage reporting stop ends the loop,
    /// no fan after it is engaged, and the first fan is never re-engaged.
    @MainActor
    func testEngageRestStopsAtTheFirstStop() async {
        for stopAt in [2, Int.max] {
            var engaged: [Int] = [], checks = 0
            let saved = await FanControlHelper.engageRest([0: 1, 1: 1, 2: 1, 3: 1], skipping: 0,
                                                          engage: { i, _ in engaged.append(i); return .engaged },
                                                          landed: { _ in checks += 1; return checks < stopAt })
            XCTAssertEqual(engaged.count, stopAt == 2 ? 2 : 3, "stopAt=\(stopAt): \(engaged)")
            XCTAssertFalse(engaged.contains(0))
            XCTAssertEqual(saved, stopAt == 2 ? nil : .engaged)
        }
    }

    /// QA #103 M9: willSleep resets only with manual intent or an engage in flight.
    @MainActor
    func testWillSleepResetsOnlyWhenNeeded() {
        let previousManualIntent = Preferences.fanManualEnabled
        let fake = FakeHelperConnection()
        defer {
            Preferences.fanManualEnabled = previousManualIntent
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
        }
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        FanControlHelper.willSleep()
        XCTAssertEqual(fake.proxy.resets, 0, "nothing manual, nothing to reset")
        FanControlHelper.inject(connection: fake, engagesInFlight: 1)
        FanControlHelper.willSleep()
        XCTAssertEqual(fake.proxy.resets, 1)
    }

    /// QA #103 M10-M13 and laterEngageLanded's release: called without them, the
    /// sleeping / inFlight / generation defaults read the live state and the release
    /// default really releases (sleepSafeRelease with manual off tears the connection down).
    @MainActor
    func testEngageLandedDefaultsReadLiveState() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer {
            Preferences.fanManualEnabled = previousManualIntent
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
        }
        Preferences.fanManualEnabled = false
        // firstEngageLanded: `sleeping` default (#347): captured while asleep, generation unchanged.
        FanControlHelper.inject(connection: FakeHelperConnection(), engagesInFlight: 0)
        FanControlHelper.inject(sleeping: true)
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.engaged, since: FanControlHelper.reclaimGeneration),
                       "firstEngageLanded missed the sleeping flag")
        await waitForTeardown()
        XCTAssertTrue(FanControlHelper.connection == nil, "firstEngageLanded's sleeping release did not release")
        FanControlHelper.inject(sleeping: false)
        // firstEngageLanded: `current` and `release` defaults. The wake clears `sleeping`,
        // so only the generation the willSleep moved can stop it (QA #159).
        FanControlHelper.inject(connection: FakeHelperConnection(), engagesInFlight: 0)
        let firstGeneration = FanControlHelper.reclaimGeneration
        FanControlHelper.willSleep()   // nothing manual: bumps the generation, no reset
        FanControlHelper.inject(sleeping: false)   // the wake
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.engaged, since: firstGeneration),
                       "firstEngageLanded missed the willSleep")
        await waitForTeardown()
        XCTAssertTrue(FanControlHelper.connection == nil, "firstEngageLanded's default release did not release")
        // lateEngageLanded: `sleeping` default (manual on; asleep).
        Preferences.fanManualEnabled = true
        FanControlHelper.inject(sleeping: true)
        let released = expectation(description: "late engage released while asleep")
        FanControlHelper.lateEngageLanded(true, release: { released.fulfill() })
        await fulfillment(of: [released], timeout: 1)
        // lateEngageLanded: `inFlight` default.
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(sleeping: false)
        FanControlHelper.inject(connection: nil, engagesInFlight: 1)
        let kept = expectation(description: "held for the engage in flight")
        kept.isInverted = true
        FanControlHelper.lateEngageLanded(true, release: { kept.fulfill() })
        await fulfillment(of: [kept], timeout: 0.3)
        // lateEngageLanded: `release` default.
        FanControlHelper.inject(connection: FakeHelperConnection(), engagesInFlight: 0)
        FanControlHelper.lateEngageLanded(true)
        await waitForTeardown()
        XCTAssertTrue(FanControlHelper.connection == nil, "lateEngageLanded's default release did not release")
        // laterEngageLanded: `current` and `release` defaults.
        let fake = FakeHelperConnection()
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        let generation = FanControlHelper.reclaimGeneration
        FanControlHelper.willSleep()   // nothing manual: bumps the generation, no reset
        FanControlHelper.inject(sleeping: false)
        XCTAssertFalse(FanControlHelper.laterEngageLanded(since: generation), "laterEngageLanded missed the willSleep")
        await waitForTeardown()
        XCTAssertTrue(FanControlHelper.connection == nil, "laterEngageLanded's default release did not release")
        XCTAssertEqual(fake.proxy.resets, 1)
        XCTAssertTrue(FanControlHelper.laterEngageLanded(since: FanControlHelper.reclaimGeneration, release: {}),
                      "no willSleep since the loop began, yet laterEngageLanded stopped")
    }

    /// Runs the popup's Manual flow on the fan-control fakes with prefs saved and restored:
    /// manual off, a fake connection, awake. `body` gets the targets and the sentinel prefs.
    @MainActor
    private func withPopupFakes(_ body: ([Int: Double], [Int: Double]) async -> Void) async {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer {
            Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
        }
        Preferences.fanManualEnabled = false
        Preferences.fanTargets = [0: 1500]
        FanControlHelper.inject(sleeping: false)
        FanControlHelper.inject(connection: FakeHelperConnection(), engagesInFlight: 0)
        await body([0: 2000, 1: 3000], [0: 1500])
    }

    /// #390 (QA #159): a click after willSleep whose first reply lands after didWake. The
    /// generation did not move after the click, but the click was taken asleep: release,
    /// engage nothing else and write no pref.
    @MainActor
    func testClickWhileAsleepWhoseReplyLandsAfterWakeSavesNoPref() async {
        await withPopupFakes { targets, sentinel in
            FanControlHelper.willSleep()   // nothing manual: bumps the generation, no reset
            var restEngaged: [Int] = []
            let (saved, _) = await FanControlHelper.popupEngage(targets, first: 0,
                engageFirst: { FanControlHelper.inject(sleeping: false); return .engaged },   // the wake, then the reply
                engage: { i, _ in restEngaged.append(i); return .engaged })
            XCTAssertFalse(saved, "a click taken asleep saved the pref after the wake")
            XCTAssertEqual(restEngaged, [])
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, sentinel)
            await waitForTeardown()
            XCTAssertTrue(FanControlHelper.connection == nil, "the refused engage was not released")
        }
    }

    /// QA #156 (#345): popupEngage captures the generation at the click, before the first
    /// engage, and hands that one to engageRest. A sleep+wake inside the first engage stops
    /// the flow at the first fan; with the first let through (seam) the rest still stops.
    @MainActor
    func testPopupEngageStaleGenerationStopsTheRest() async {
        await withPopupFakes { targets, sentinel in
            let sleepAndWake: () async -> FanManualReply = {
                FanControlHelper.willSleep(); FanControlHelper.inject(sleeping: false); return .engaged
            }
            // Capture before the first engage: the first engage is refused.
            var restEngaged: [Int] = []
            var (saved, _) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: sleepAndWake,
                engage: { i, _ in restEngaged.append(i); return .engaged })
            XCTAssertFalse(saved, "the generation was captured after the first engage")
            XCTAssertEqual(restEngaged, [])
            await waitForTeardown()
            // since: pass-through: the rest checks the click's generation, not its own.
            FanControlHelper.inject(connection: FakeHelperConnection(), engagesInFlight: 0)
            (saved, _) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: sleepAndWake,
                firstLanded: { _, _, _ in true },
                engage: { i, _ in restEngaged.append(i); return .engaged })
            XCTAssertFalse(saved, "engageRest did not get the click's generation")
            XCTAssertEqual(restEngaged, [1], "the rest went on after the stale check")
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, sentinel)
            await waitForTeardown()
        }
    }

    /// QA #154 (#343): the popup saves the pref only when every later engage landed.
    @MainActor
    func testPopupEngageSavesOnlyWhenTheRestLanded() async {
        await withPopupFakes { targets, sentinel in
            var (saved, _) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { .engaged },
                engage: { _, _ in .engaged }, landed: { _ in false })
            XCTAssertFalse(saved, "the popup saved the pref after engageRest stopped")
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, sentinel)
            FanControlHelper.presetPending = true   // #737: a saved preset the engage now lands
            defer { FanControlHelper.presetPending = false }
            (saved, _) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { .engaged },
                engage: { _, _ in .engaged }, landed: { _ in true })
            XCTAssertTrue(saved)
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, targets)
            XCTAssertFalse(FanControlHelper.presetPending, "a landed popup engage kept the floor exemption")
        }
    }

    /// QA #154 (#343): the willSleep observer runs willSleep (the generation bump is its mark).
    /// In-process notification only: no real sleep, nothing manual, no connection.
    @MainActor
    func testWillSleepNotificationRunsWillSleep() async {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent; FanControlHelper.inject(sleeping: false) }
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.armRecoveryLifecycle()
        let generation = FanControlHelper.reclaimGeneration
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<100 where FanControlHelper.reclaimGeneration == generation {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(FanControlHelper.reclaimGeneration, generation &+ 1, "the willSleep observer did not run willSleep")
        FanControlHelper.removeSleepObservers()
        await FanControlHelper.resetAll(teardown: true)
    }

    /// Polls until a fire-and-forget release tore the connection down (or 2 s pass).
    @MainActor
    private func waitForTeardown() async {
        for _ in 0..<200 where FanControlHelper.connection != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - #737 preset while the overheat latch holds

    /// Drops what a pending save armed (timer, observers, cooldown, flag) so no real reclaim
    /// tick can reapply the saved targets later in the xctest process.
    @MainActor
    private func disarmPreset() async {
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        await FanControlHelper.resetAll(teardown: true)
        FanControlHelper.removeSleepObservers()
        FanControlHelper.deferReclaimRetry(now: .distantPast)
        FanControlHelper.presetPending = false
    }

    /// The latch's refusal (.refused below macOS's speed, .settling inside the window) saves
    /// intent and the targets, arms recovery with the next attempt one settle window out, hands
    /// macOS every fan (no teardown), and engages no other fan.
    @MainActor
    func testLatchRefusalSavesThePresetAndArmsRecovery() async {
        for refusal in [FanManualReply.refused, .settling] {
            await withPopupFakes { targets, _ in
                FanControlHelper.presetPending = false
                let fake = FakeHelperConnection()
                FanControlHelper.inject(connection: fake, engagesInFlight: 0)
                var restEngaged: [Int] = []
                let start = Date()
                let (saved, reply) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { refusal },
                    engage: { i, _ in restEngaged.append(i); return .engaged })
                XCTAssertTrue(saved, "\(refusal)")
                XCTAssertEqual(reply, refusal)
                XCTAssertTrue(Preferences.fanManualEnabled, "\(refusal): intent not saved")
                XCTAssertEqual(Preferences.fanTargets, targets)
                XCTAssertTrue(FanControlHelper.presetPending)
                XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed, "\(refusal): recovery not armed")
                XCTAssertEqual(restEngaged, [], "the rest engaged after a refusal")
                XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: start.addingTimeInterval(1)), "retry not deferred")
                XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: Date().addingTimeInterval(FanReclaimRecovery.retryCooldown)))
                for _ in 0..<200 where fake.proxy.resets == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
                XCTAssertEqual(fake.proxy.resets, 1, "macOS was not handed every fan")
                XCTAssertTrue(FanControlHelper.connection === fake, "a pending preset tore the connection down")
                await disarmPreset()
            }
        }
    }

    /// No reply from the helper (.unavailable, the 45 s ceiling's answer too, or .needsApproval)
    /// stays a failure: nothing saved, the timer the engage armed dropped, released.
    @MainActor
    func testUnavailableSavesNoPreset() async {
        for failure in [FanManualReply.unavailable, .needsApproval] {
            await withPopupFakes { targets, sentinel in
                FanControlHelper.presetPending = false
                FanControlHelper.armRecoveryLifecycle()   // what setManualReply does before the call
                let (saved, _) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { failure },
                    engage: { _, _ in XCTFail("engaged after a failure"); return .engaged })
                XCTAssertFalse(saved, "\(failure)")
                XCTAssertFalse(Preferences.fanManualEnabled, "\(failure) saved intent")
                XCTAssertEqual(Preferences.fanTargets, sentinel)
                XCTAssertFalse(FanControlHelper.presetPending)
                XCTAssertFalse(FanControlHelper.recoveryLifecycleArmed)
                await waitForTeardown()
                await disarmPreset()
            }
        }
    }

    /// The sleep checks hold for a refusal too (#345, #390): a willSleep during the engage, or a
    /// click taken asleep, saves no preset.
    @MainActor
    func testLatchRefusalAcrossASleepSavesNoPreset() async {
        let sleepDuring: () async -> FanManualReply = {
            FanControlHelper.willSleep(); FanControlHelper.inject(sleeping: false); return .refused
        }
        let clickedAsleep: () async -> FanManualReply = { FanControlHelper.inject(sleeping: false); return .settling }
        for (name, engageFirst) in [("sleep during", sleepDuring), ("clicked asleep", clickedAsleep)] {
            await withPopupFakes { targets, sentinel in
                FanControlHelper.presetPending = false
                if name == "clicked asleep" { FanControlHelper.willSleep() }
                let (saved, _) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: engageFirst,
                    engage: { _, _ in XCTFail("engaged after a sleep"); return .engaged })
                XCTAssertFalse(saved, name)
                XCTAssertFalse(Preferences.fanManualEnabled, "\(name): saved intent")
                XCTAssertEqual(Preferences.fanTargets, sentinel, name)
                XCTAssertFalse(FanControlHelper.presetPending, name)
                await waitForTeardown()
                await disarmPreset()
            }
        }
    }

    /// The popup's pending line: manual intent on and macOS holding every adjustable fan, with
    /// the preset's percent; nothing once the helper has any of them, or with intent off.
    func testPendingLineOnlyWhileMacOSHoldsEveryFan() throws {
        let auto = [FanReading(id: 0, min: 1000, max: 5000, current: 4000, manual: false),
                    FanReading(id: 1, min: 1000, max: 5000, current: 4000, manual: false),
                    FanReading(id: 2, min: 2000, max: 2000, current: 2000, manual: true)]   // no range: ignored
        let preset: [Int: Double] = [0: 3400, 1: 3400]   // 60 %
        let line = try XCTUnwrap(FanReclaimRecovery.pendingText(manualIntent: true, readings: auto, targets: preset))
        XCTAssertEqual(line, "Waiting for macOS to hand back the fans. "
                       + "Prosper sets 60% as soon as it can.")
        XCTAssertNil(FanReclaimRecovery.pendingText(manualIntent: false, readings: auto, targets: preset))
        var taken = auto
        taken[1] = FanReading(id: 1, min: 1000, max: 5000, current: 3400, manual: true)
        XCTAssertNil(FanReclaimRecovery.pendingText(manualIntent: true, readings: taken, targets: preset),
                     "the helper has a fan: not pending")
        XCTAssertNil(FanReclaimRecovery.pendingText(manualIntent: true, readings: [], targets: preset))
        XCTAssertNil(FanReclaimRecovery.pendingText(manualIntent: true, readings: auto, targets: [:]))
    }

    /// A slider commit the latch refused keeps the new targets as the preset (no revert) and
    /// hands macOS every fan; an unreachable helper, or Automatic landing first, does not.
    @MainActor
    func testCommitRefusalKeepsThePreset() async {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer { Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets }
        let dragged: [Int: Double] = [0: 1100, 1: 1200]
        for refusal in [FanManualReply.refused, .settling] {
            Preferences.fanManualEnabled = true
            Preferences.fanTargets = dragged   // the commit's own persist
            FanControlHelper.presetPending = false
            let reset = expectation(description: "\(refusal): every fan handed to macOS")
            let kept = StatsPopupView.settleCommit([refusal], dragged, previous: [0: 9, 1: 9], reset: { reset.fulfill() })
            XCTAssertTrue(kept.shown == dragged && kept.error == nil, "\(refusal) reverted the slider")
            await fulfillment(of: [reset], timeout: 1)
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, dragged, "\(refusal) reverted the preset")
            XCTAssertTrue(FanControlHelper.presetPending)
            XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed)
            await disarmPreset()
        }
        // #1033: no reply keeps the PREVIOUS targets as the preset and hands every fan back too.
        let previous: [Int: Double] = [0: 1500, 1: 1600]
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = dragged
        let handedBack = expectation(description: "no reply: every fan handed to macOS")
        let reverted = StatsPopupView.settleCommit([.unavailable], dragged, previous: previous, reset: { handedBack.fulfill() })
        XCTAssertTrue(reverted.shown == previous, "an unreachable helper kept the new targets")
        XCTAssertEqual(reverted.error, FanManualReply.unavailable.errorText)
        await fulfillment(of: [handedBack], timeout: 1)
        XCTAssertEqual(Preferences.fanTargets, previous)
        XCTAssertTrue(FanControlHelper.presetPending)
        await disarmPreset()
        let none = expectation(description: "no reset")
        none.isInverted = true
        let released = expectation(description: "Automatic landed during the commit: released")
        Preferences.fanManualEnabled = false   // Automatic (popup or phone) landed during the commit
        Preferences.fanTargets = [:]
        let late = StatsPopupView.settleCommit([.refused], dragged, previous: previous,
                                               reset: { none.fulfill() }, release: { released.fulfill() })
        XCTAssertTrue(late.shown == nil && late.error == nil)
        XCTAssertFalse(Preferences.fanManualEnabled, "a late refusal turned manual back on")
        XCTAssertEqual(Preferences.fanTargets, [:], "a late refusal wrote targets back over Automatic")
        await fulfillment(of: [released], timeout: 1)
        FanControlHelper.presetPending = true
        Preferences.fanManualEnabled = true
        let landed = StatsPopupView.settleCommit([.engaged, .engaged], dragged, previous: previous,
                                                 reset: { none.fulfill() }, release: { none.fulfill() })
        XCTAssertTrue(landed.shown == dragged && landed.error == nil)
        XCTAssertFalse(FanControlHelper.presetPending, "an engaged commit landed the targets")
        await fulfillment(of: [none], timeout: 0.3)
        await disarmPreset()
    }

    /// The floor: a pending preset under 20 % is held (refused → retry, accepted → restored), never
    /// dropped; a pin that already ran keeps the floor. Then recovery applies it once the seam
    /// accepts, and the flag clears, so a later reclaim of that pin has the floor again.
    @MainActor
    func testPendingPresetUnderTheFloorIsHeldAndApplied() async throws {
        XCTAssertEqual(FanReclaimRecovery.disposition(manualFraction: 0.05, reengaged: false, pending: true), .retry)
        XCTAssertEqual(FanReclaimRecovery.disposition(manualFraction: 0.05, reengaged: true, pending: true), .restored)
        XCTAssertEqual(FanReclaimRecovery.disposition(manualFraction: 0.05, reengaged: true), .abandonManualIntent)
        XCTAssertEqual(FanReclaimRecovery.disposition(manualFraction: .nan, reengaged: true, pending: true), .abandonManualIntent)

        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer { Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets }
        let low: [Int: Double] = [0: 1200, 1: 1200]   // 5 % of 1000...5000
        let reclaimed = [0, 1].map { FanReading(id: $0, min: 1000, max: 5000, current: 3000, manual: false) }
        let t = Date()
        var resets: [Bool] = []
        let fraction = try XCTUnwrap(FanReclaimRecovery.manualFraction(targets: low, readings: reclaimed))
        FanControlHelper.savePreset(low, now: t, reset: {})
        XCTAssertTrue(FanControlHelper.presetPending)
        XCTAssertLessThan(fraction, FanReclaimRecovery.minimumManualFraction)

        // Latched: the re-apply is refused; intent and the preset stay, one plain reset.
        var engaged: [Int: Double] = [:]
        let refused = await FanControlHelper.applySavedTargets(reclaimGeneration: FanControlHelper.reclaimGeneration,
            engage: { _, _, _ in false }, reset: { resets.append($0); return true })
        XCTAssertFalse(refused)
        await FanControlHelper.settleReclaim(FanReclaimRecovery.disposition(manualFraction: fraction, reengaged: refused,
                                                                            pending: FanControlHelper.presetPending),
                                             now: t) { resets.append($0); return true }
        XCTAssertTrue(Preferences.fanManualEnabled, "the floor dropped a pending preset")
        XCTAssertEqual(Preferences.fanTargets, low)
        XCTAssertEqual(resets, [false])
        XCTAssertTrue(FanControlHelper.presetPending)

        // The Mac cooled: the helper accepts, the preset lands on every fan with no click.
        let accepted = await FanControlHelper.applySavedTargets(reclaimGeneration: FanControlHelper.reclaimGeneration,
            engage: { i, rpm, _ in engaged[i] = rpm; return true }, reset: { resets.append($0); return true })
        XCTAssertTrue(accepted)
        XCTAssertEqual(engaged, low)
        XCTAssertFalse(FanControlHelper.presetPending, "a landed preset kept its floor exemption")
        XCTAssertEqual(resets, [false])
        await disarmPreset()
    }

    // MARK: - #926 split verdicts: one decision for every fan of a request

    @MainActor
    func testEngageOrderPutsTheRefusedFanFirstThenByIndex() {
        let targets: [Int: Double] = [2: 1, 0: 1, 1: 1]
        XCTAssertEqual(FanControlHelper.engageOrder(targets, refusedFirst: nil).map(\.key), [0, 1, 2])
        XCTAssertEqual(FanControlHelper.engageOrder(targets, refusedFirst: 2).map(\.key), [2, 0, 1])
        XCTAssertEqual(FanControlHelper.engageOrder(targets, refusedFirst: 7).map(\.key), [0, 1, 2])
        XCTAssertEqual(FanControlHelper.engageOrder([:], refusedFirst: 1).count, 0)
    }

    /// The slider commit's burst stops at the first fan that does not engage (no sibling pinned after
    /// it) and that reply is the request's; the refused fan goes first next time.
    @MainActor
    func testCommitBurstStopsAtTheFirstFailedFan() async {
        let previousRefused = FanControlHelper.lastRefusedFan
        defer { FanControlHelper.lastRefusedFan = previousRefused }
        FanControlHelper.lastRefusedFan = nil
        let targets: [Int: Double] = [0: 2000, 1: 2000, 2: 2000]
        var engaged: [Int] = []
        var replies = await FanControlHelper.engageAll(targets) { i, _ in engaged.append(i); return i == 1 ? .refused : .engaged }
        XCTAssertEqual(replies, [.engaged, .refused])
        XCTAssertEqual(engaged, [0, 1], "a fan after the refused one was pinned")
        FanControlHelper.lastRefusedFan = 1   // what setManualReply records for that refusal
        engaged = []
        replies = await FanControlHelper.engageAll(targets) { i, _ in engaged.append(i); return i == 1 ? .settling : .engaged }
        XCTAssertEqual(replies, [.settling])
        XCTAssertEqual(engaged, [1], "the retry pinned a sibling before the refused fan")
        engaged = []
        replies = await FanControlHelper.engageAll(targets) { i, _ in engaged.append(i); return .engaged }
        XCTAssertEqual(replies, [.engaged, .engaged, .engaged])
        XCTAssertEqual(engaged, [1, 0, 2])
    }

    /// QA #456 L2: the popup's first fan engaged, a later one refused. The request is refused as a
    /// whole: the targets become the pending preset (as for a refused first fan, #737), the retry
    /// waits one cooldown, and macOS gets the pinned fan back. Before #926 the split pin was saved.
    @MainActor
    func testALaterFansRefusalRefusesThePopupRequest() async {
        await withPopupFakes { targets, _ in
            FanControlHelper.presetPending = false
            let fake = FakeHelperConnection()
            FanControlHelper.inject(connection: fake, engagesInFlight: 0)
            var restEngaged: [Int] = []
            let start = Date()
            let (saved, reply) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { .engaged },
                engage: { i, _ in restEngaged.append(i); return .refused })
            XCTAssertEqual(restEngaged, [1])
            XCTAssertTrue(saved)
            XCTAssertEqual(reply, .refused, "the popup and the phone show the pending line")
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, targets)
            XCTAssertTrue(FanControlHelper.presetPending, "the split pin was saved as landed")
            XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed)
            XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: start.addingTimeInterval(1)), "retry not deferred")
            for _ in 0..<200 where fake.proxy.resets == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(fake.proxy.resets, 1, "fan 0's pin was not handed back")
            await disarmPreset()
        }
    }

    /// #1215 (was #926 r2's "settling keeps the preset"): fan 0 was just accepted, so a later fan's
    /// .settling is not the settle window but a write failure, named as the slider commit names it
    /// (#1033): not saved, .writeFailed, and fan 0's pin handed back once. Manual off before the click:
    /// nothing saved and the release tears down. Manual on with an earlier preset pending: that preset
    /// stays as it was and the connection stays for its recovery.
    @MainActor
    func testALaterFansSettlingIsAWriteFailureAndHandsBackThePin() async {
        for manualBefore in [false, true] {
            await withPopupFakes { targets, sentinel in
                Preferences.fanManualEnabled = manualBefore
                FanControlHelper.presetPending = manualBefore
                let fake = FakeHelperConnection()
                FanControlHelper.inject(connection: fake, engagesInFlight: 0)
                var restEngaged: [Int] = []
                let (saved, reply) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { .engaged },
                    engage: { i, _ in restEngaged.append(i); return .settling })
                XCTAssertEqual(restEngaged, [1], "manual \(manualBefore)")
                XCTAssertFalse(saved, "a write failure was saved as the latch's preset (manual \(manualBefore))")
                XCTAssertEqual(reply, .writeFailed, "manual \(manualBefore)")
                XCTAssertEqual(Preferences.fanManualEnabled, manualBefore)
                XCTAssertEqual(Preferences.fanTargets, sentinel, "the click's targets were saved")
                XCTAssertEqual(FanControlHelper.presetPending, manualBefore)
                for _ in 0..<200 where fake.proxy.resets == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
                XCTAssertEqual(fake.proxy.resets, 1, "fan 0's pin was not handed back (manual \(manualBefore))")
                if manualBefore {
                    XCTAssertTrue(FanControlHelper.connection === fake, "manual on: the release tore the connection down")
                } else {
                    await waitForTeardown()
                    XCTAssertTrue(FanControlHelper.connection == nil, "manual off: the release did not tear down")
                }
                await disarmPreset()
            }
        }
    }

    /// #926 r2: no reply from a later fan (a timeout or an XPC error) stays a failure, as on the first
    /// fan (#737): not saved, that reply, no pref and no preset, and fan 0's pin handed back. Manual
    /// was off before the click, so the release tears down like a failed first engage.
    @MainActor
    func testALaterFansNoReplySavesNothingAndHandsBackThePin() async {
        await withPopupFakes { targets, sentinel in
            FanControlHelper.presetPending = false
            let fake = FakeHelperConnection()
            FanControlHelper.inject(connection: fake, engagesInFlight: 0)
            var restEngaged: [Int] = []
            let (saved, reply) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { .engaged },
                engage: { i, _ in restEngaged.append(i); return .unavailable })
            XCTAssertEqual(restEngaged, [1])
            XCTAssertFalse(saved)
            XCTAssertEqual(reply, .unavailable)
            XCTAssertFalse(Preferences.fanManualEnabled, "a helper that did not answer saved intent")
            XCTAssertEqual(Preferences.fanTargets, sentinel)
            XCTAssertFalse(FanControlHelper.presetPending)
            for _ in 0..<200 where fake.proxy.resets == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(fake.proxy.resets, 1, "fan 0's pin was not handed back")
            await waitForTeardown()
            XCTAssertTrue(FanControlHelper.connection == nil, "manual off: the release did not tear down")
            await disarmPreset()
        }
    }

    /// #926 r2: a later fan's missing approval is no reply too. Here an earlier preset was pending
    /// before the click: it stays as it was (intent, targets, pending flag), fan 0's pin is handed
    /// back, and the connection stays for that preset's recovery (no teardown with manual on).
    @MainActor
    func testALaterFansMissingApprovalKeepsTheEarlierPresetAndHandsBackThePin() async {
        await withPopupFakes { targets, sentinel in
            Preferences.fanManualEnabled = true
            FanControlHelper.presetPending = true
            let fake = FakeHelperConnection()
            FanControlHelper.inject(connection: fake, engagesInFlight: 0)
            var restEngaged: [Int] = []
            let (saved, reply) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { .engaged },
                engage: { i, _ in restEngaged.append(i); return .needsApproval })
            XCTAssertEqual(restEngaged, [1])
            XCTAssertFalse(saved)
            XCTAssertEqual(reply, .needsApproval)
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, sentinel, "the click's targets replaced the earlier preset")
            XCTAssertTrue(FanControlHelper.presetPending)
            for _ in 0..<200 where fake.proxy.resets == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(fake.proxy.resets, 1, "fan 0's pin was not handed back")
            XCTAssertTrue(FanControlHelper.connection === fake, "manual on: the release tore the connection down")
            await disarmPreset()
        }
    }

    /// QA #456 L2 / #586 ceiling 2, against the helper's real core (fake clock, temperature and
    /// speeds; no XPC, no SMC). Latched and past the window, fan 0's preset is at or above macOS's
    /// speed, fan 1's below. The first attempt pins fan 0, is refused on fan 1 and the reset hands
    /// fan 0 back. Every retry engages fan 1 first and stops there: nothing pinned, nothing handed
    /// back, so the settle window is not restarted. Once macOS slows fan 1 to its preset, both land.
    @MainActor
    func testSplitVerdictRetryPinsNoSibling() async {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        let previousRefused = FanControlHelper.lastRefusedFan
        defer {
            Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets
            FanControlHelper.lastRefusedFan = previousRefused; FanControlHelper.presetPending = false
        }
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [0: 3103, 1: 2000]
        FanControlHelper.lastRefusedFan = nil
        final class Clock { var t = ContinuousClock.now }
        final class Conn {}
        let clock = Clock(), conn = Conn(), holder = ObjectIdentifier(conn)
        let core = FanControlCore(reset: { true }, maxCelsius: { nil }, now: { clock.t })
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: holder, maxCelsius: 50, macOSRPM: nil))
        XCTAssertEqual(core.supervise(maxCelsius: 96, isManualEngaged: { _ in true }), .fired)
        var macOS: [Int: Double] = [0: 2500, 1: 2500]
        var engaged: [Int] = []
        func attempt(after seconds: Double) async -> Bool {
            clock.t = clock.t.advanced(by: .seconds(seconds))
            engaged = []
            let ok = await FanControlHelper.applySavedTargets(reclaimGeneration: FanControlHelper.reclaimGeneration,
                engage: { i, rpm, _ in
                    engaged.append(i)
                    let pinned = core.manualRequest(index: i, rpm: rpm, holder: holder, maxCelsius: 90, macOSRPM: macOS[i])
                    if !pinned { FanControlHelper.lastRefusedFan = i }   // setManualReply's record of a live refusal
                    return pinned
                },
                reset: { _ in core.releaseAll() })
            if !ok { XCTAssertTrue(core.releaseAll()) }   // settleReclaim's .retry reset
            return ok
        }
        var landed = await attempt(after: FanReclaimRecovery.retryCooldown)
        XCTAssertFalse(landed)
        XCTAssertEqual(engaged, [0, 1])
        XCTAssertEqual(core.lastRefusal, .belowMacOS)
        for retry in 1...3 {
            landed = await attempt(after: FanReclaimRecovery.retryCooldown)
            XCTAssertFalse(landed, "retry \(retry)")
            XCTAssertEqual(engaged, [1], "retry \(retry) pinned a sibling before the refused fan")
            XCTAssertTrue(core.heldTargets.isEmpty, "retry \(retry)")
        }
        // macOS slowed fan 1 to 1900. One second later is past the window only if no retry restarted it.
        macOS[1] = 1900
        landed = await attempt(after: 1)
        XCTAssertTrue(landed)
        XCTAssertEqual(engaged, [1, 0])
        XCTAssertEqual(core.heldTargets, [0: 3103, 1: 2000])
        XCTAssertTrue(core.tripLatched)
    }

    /// QA #103 M8: the reclaim tick does not run while asleep, even with manual on.
    @MainActor
    func testReclaimTickNotAllowedWhileAsleep() {
        let previousManualIntent = Preferences.fanManualEnabled
        defer { Preferences.fanManualEnabled = previousManualIntent; FanControlHelper.inject(sleeping: false) }
        Preferences.fanManualEnabled = true
        FanControlHelper.inject(sleeping: true)
        XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: .distantFuture))
        FanControlHelper.inject(sleeping: false)
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: .distantFuture))
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

    /// #221 (3), #586: a failed reclaim re-apply holds the next attempt for the helper's
    /// settle window, so the retry after a trip lands past it.
    @MainActor
    func testFailedReapplyCoolsDownForTheSettleWindow() {
        let previousManualIntent = Preferences.fanManualEnabled
        defer {
            Preferences.fanManualEnabled = previousManualIntent
            FanControlHelper.deferReclaimRetry(now: .distantPast)
        }
        Preferences.fanManualEnabled = true
        let t = Date()
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: t))
        FanControlHelper.deferReclaimRetry(now: t)
        XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(9.9)))
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: t.addingTimeInterval(FanReclaimRecovery.retryCooldown)))
        XCTAssertEqual(FanReclaimRecovery.retryCooldown, 10)
        XCTAssertEqual(FanReclaimRecovery.retryCooldown, FanControlCore.reTakeSettleSeconds)
    }

    /// #586: the operator's lap. A 3103 RPM pin trips the kill-switch; macOS runs the
    /// fans at 2500. The reclaim re-apply, driven against the helper's real core
    /// (injected clock, temperature and speeds; no XPC, no SMC): the attempt inside the
    /// settle window is refused and keeps manual intent and targets, the retry one
    /// cooldown later takes the fans back.
    @MainActor
    func testReclaimReappliesAfterTheSettleWindowAndKeepsIntentOnRefusal() async throws {
        let previousManualIntent = Preferences.fanManualEnabled, previousTargets = Preferences.fanTargets
        defer {
            Preferences.fanManualEnabled = previousManualIntent; Preferences.fanTargets = previousTargets
            FanControlHelper.deferReclaimRetry(now: .distantPast)
        }
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [0: 3103, 1: 3103]
        final class Clock { var t = ContinuousClock.now }
        final class Conn {}
        let clock = Clock(), conn = Conn(), holder = ObjectIdentifier(conn)
        let core = FanControlCore(reset: { true }, maxCelsius: { nil }, now: { clock.t })
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: holder, maxCelsius: 50, macOSRPM: nil))
        XCTAssertEqual(core.supervise(maxCelsius: 96, isManualEngaged: { _ in true }), .fired)
        let trip = Date()
        let readings = [0, 1].map { FanReading(id: $0, min: 1350, max: 5777, current: 2500, manual: false) }
        XCTAssertTrue(FanReclaimRecovery.reclaimDetected(readings))
        let fraction = try XCTUnwrap(FanReclaimRecovery.manualFraction(targets: Preferences.fanTargets, readings: readings))
        var resets: [Bool] = []
        func reapply() async -> Bool {
            await FanControlHelper.applySavedTargets(
                reclaimGeneration: FanControlHelper.reclaimGeneration,
                engage: { i, rpm, _ in core.manualRequest(index: i, rpm: rpm, holder: holder, maxCelsius: 94, macOSRPM: 2500) },
                reset: { resets.append($0); return true })
        }

        clock.t = clock.t.advanced(by: .seconds(2))   // the next 2 s reclaim tick
        let refusedAt = trip.addingTimeInterval(2)
        let refused = await reapply()
        XCTAssertFalse(refused, "inside the settle window")
        await FanControlHelper.settleReclaim(FanReclaimRecovery.disposition(manualFraction: fraction, reengaged: false),
                                             now: refusedAt) { resets.append($0); return true }
        XCTAssertTrue(Preferences.fanManualEnabled, "a refusal keeps manual intent")
        XCTAssertEqual(Preferences.fanTargets, [0: 3103, 1: 3103], "and the saved targets")
        XCTAssertEqual(resets, [false], "one plain reset, no teardown")
        XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: refusedAt.addingTimeInterval(FanReclaimRecovery.retryCooldown - 0.1)))

        let retryAt = refusedAt.addingTimeInterval(FanReclaimRecovery.retryCooldown)
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(now: retryAt))
        clock.t = clock.t.advanced(by: .seconds(FanReclaimRecovery.retryCooldown))
        let retaken = await reapply()
        XCTAssertTrue(retaken, "past the window, the faster pin takes the fans back")
        XCTAssertEqual(core.heldTargets, [0: 3103, 1: 3103])
        XCTAssertTrue(core.tripLatched)
        XCTAssertLessThanOrEqual(retryAt.timeIntervalSince(trip), 30, "the user's speed is back within ~10-30 s")
    }

    /// #586: a live helper's false is named by the fan's speed, read through the seam
    /// only on a refusal. Fake connection, fake registration: no helper, no SMC.
    @MainActor
    func testSetManualReplyNamesARefusalByTheFanSpeed() async {
        let previousManualIntent = Preferences.fanManualEnabled, savedRegistration = LidSleepHelper.registration
        let fake = FakeHelperConnection()
        let previousRefused = FanControlHelper.lastRefusedFan
        defer {
            Preferences.fanManualEnabled = previousManualIntent; LidSleepHelper.registration = savedRegistration
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.lastRefusedFan = previousRefused
        }
        Preferences.fanManualEnabled = false
        LidSleepHelper.registration = { .enabled }
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        FanControlHelper.lastRefusedFan = nil
        let reads = LockedBox()
        let speed: @Sendable (Int) -> Double? = { _ in reads.set(true); return 2500 }
        var reply = await FanControlHelper.setManualReply(0, rpm: 3103, macOSRPM: speed)
        XCTAssertEqual(reply, .engaged)
        XCTAssertEqual(reads.get(), [], "no fan read on an engage")
        fake.proxy.manualReply = false
        reply = await FanControlHelper.setManualReply(0, rpm: 3103, macOSRPM: speed)
        XCTAssertEqual(reply, .settling)
        XCTAssertEqual(FanControlHelper.lastRefusedFan, 0, "#926: a live refusal names the fan to engage first")
        reply = await FanControlHelper.setManualReply(1, rpm: 2000, macOSRPM: speed)
        XCTAssertEqual(reply, .refused)
        XCTAssertEqual(reads.get().count, 2)
        XCTAssertEqual(FanControlHelper.lastRefusedFan, 1)
        fake.proxy.manualReply = true
        reply = await FanControlHelper.setManualReply(0, rpm: 3103, macOSRPM: speed)
        XCTAssertEqual(reply, .engaged)
        XCTAssertEqual(FanControlHelper.lastRefusedFan, 1, "an engage moved the refused fan")
        await FanControlHelper.resetAll(teardown: true)
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

    /// R1223-3: the recovery's trigger. macOS holding every fan acts as before; saved targets that read
    /// none act even while the helper holds pins, unless an engage is in flight (it saves new targets).
    func testRecoveryActsOnEmptyTargetsWhileThePinsStay() {
        let pinned = [FanReading(id: 0, min: 1000, max: 5000, current: 3000, manual: true),
                      FanReading(id: 1, min: 1000, max: 5000, current: 3000, manual: false)]
        let auto = [FanReading(id: 0, min: 1000, max: 5000, current: 3000, manual: false),
                    FanReading(id: 1, min: 1000, max: 5000, current: 3000, manual: false)]
        XCTAssertFalse(FanReclaimRecovery.shouldRecover(pinned, targetsEmpty: false, inFlight: 0), "pins, targets set")
        XCTAssertFalse(FanReclaimRecovery.shouldRecover(pinned, targetsEmpty: false, inFlight: 1), "pins, targets set, in flight")
        XCTAssertTrue(FanReclaimRecovery.shouldRecover(pinned, targetsEmpty: true, inFlight: 0), "pins, targets damaged")
        XCTAssertFalse(FanReclaimRecovery.shouldRecover(pinned, targetsEmpty: true, inFlight: 1), "pins, targets empty, in flight")
        XCTAssertTrue(FanReclaimRecovery.shouldRecover(auto, targetsEmpty: false, inFlight: 0), "macOS has every fan")
        XCTAssertTrue(FanReclaimRecovery.shouldRecover(auto, targetsEmpty: false, inFlight: 1), "macOS has every fan, in flight")
        XCTAssertTrue(FanReclaimRecovery.shouldRecover(auto, targetsEmpty: true, inFlight: 0), "macOS, targets empty")
        XCTAssertTrue(FanReclaimRecovery.shouldRecover(auto, targetsEmpty: true, inFlight: 1), "macOS, empty, in flight: as before")
        XCTAssertTrue(FanReclaimRecovery.shouldRecover([], targetsEmpty: true, inFlight: 0), "no reading, targets empty")
        XCTAssertFalse(FanReclaimRecovery.shouldRecover([], targetsEmpty: false, inFlight: 0), "no reading, targets set")
    }

    /// R1223-3 end to end through the reclaim tick (fake read, fake connection, scratch defaults, the fast
    /// re-engage pref off): manual on, targets empty, the helper holding a fan -> manual off and every fan
    /// handed back. With an engage in flight the same tick does nothing.
    @MainActor
    func testReclaimTickHandsBackPinsWhenTheTargetsReadEmpty() async {
        let manual = Preferences.fanManualEnabled, targets = Preferences.fanTargets, hold = Preferences.fanHoldUnlock
        defer {
            Preferences.fanManualEnabled = manual; Preferences.fanTargets = targets; Preferences.fanHoldUnlock = hold
            FanControlHelper.inject(connection: nil, engagesInFlight: 0)
            FanControlHelper.deferReclaimRetry(now: .distantPast)
        }
        let pinned: @Sendable () -> [FanReading] = {
            [FanReading(id: 0, min: 1000, max: 5000, current: 3000, manual: true),
             FanReading(id: 1, min: 1000, max: 5000, current: 3000, manual: true)]
        }
        Preferences.fanHoldUnlock = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        await FanControlHelper.resetAll(teardown: true)   // no connection: no call; drops any timer
        FanControlHelper.inject(sleeping: false)
        FanControlHelper.userAdjusting = false
        FanControlHelper.deferReclaimRetry(now: .distantPast)

        // An engage in flight: legitimate, nothing happens.
        let held = FakeHelperConnection()
        FanControlHelper.inject(connection: held, engagesInFlight: 1)
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = [:]
        FanControlHelper.reclaimTick(read: pinned)
        for _ in 0..<200 where !FanControlHelper.reclaimTickAllowed() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(FanControlHelper.reclaimTickAllowed(), "the tick's read never came back")
        XCTAssertTrue(Preferences.fanManualEnabled, "handed back during an engage")
        XCTAssertEqual(held.proxy.resets, 0)

        // Nothing in flight: manual off, one reset with teardown.
        let fake = FakeHelperConnection()
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        FanControlHelper.reclaimTick(read: pinned)
        await waitForTeardown()
        XCTAssertFalse(Preferences.fanManualEnabled, "the pins stayed with the targets reading empty")
        XCTAssertEqual(fake.proxy.resets, 1)
        XCTAssertTrue(FanControlHelper.connection == nil, "no teardown")
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
        let settling = try XCTUnwrap(FanManualReply.settling.errorText)
        XCTAssertFalse(settling.contains("held automatic"), "a faster pin is not held until the Mac cools")
        XCTAssertTrue(settling.contains("few seconds"))
        XCTAssertFalse(settling.contains("helper"))
        let missing = try XCTUnwrap(FanManualReply.unavailable.errorText)
        XCTAssertTrue(missing.contains("isn’t running or wasn’t approved"))
        XCTAssertNil(FanManualReply.engaged.errorText)
    }

    /// #586: the held text is only for a target below macOS's speed (or an unreadable one).
    func testRefusalIsNamedByMacOSSpeed() {
        XCTAssertEqual(FanManualReply.refusal(rpm: 3103, macOSRPM: 2500), .settling)
        XCTAssertEqual(FanManualReply.refusal(rpm: 2500, macOSRPM: 2500), .settling)
        XCTAssertEqual(FanManualReply.refusal(rpm: 2400, macOSRPM: 2500), .refused)
        XCTAssertEqual(FanManualReply.refusal(rpm: 3103, macOSRPM: nil), .refused)
        XCTAssertEqual(FanManualReply.refusal(rpm: 3103, macOSRPM: .nan), .refused)
        // QA #456 H1: the app names it by the daemon's rule, macOS's target counts too.
        XCTAssertEqual(FanManualReply.refusal(rpm: 2400, macOSRPM: FanControlCore.macOSSpeed(current: 2300, target: 2500)),
                       .refused)
    }
}

final class LockedBox: @unchecked Sendable {   // shared with FanCommitRuleTests (R1218-1)
    private let lock = NSLock(); private var v: [Bool] = []
    func set(_ b: Bool) { lock.lock(); v.append(b); lock.unlock() }
    func get() -> [Bool] { lock.lock(); defer { lock.unlock() }; return v }
}

/// A helper connection to nothing: every proxy is a recorder that replies true at once,
/// and invalidate only records. No daemon, no SMC.
private final class FakeHelperConnection: NSXPCConnection, @unchecked Sendable {
    final class Proxy: NSObject, ProsperHelperProtocol, @unchecked Sendable {
        var resets = 0
        var replies = true
        var manualReply = true
        /// Called on each reset: the release seam a row waits on with an expectation, never a poll.
        var onReset: (@Sendable () -> Void)?
        func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func setRemoteWake(_ json: String, withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func setRemoteSessionActive(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func clearRemoteSession(withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func sleepNow(withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func setFanManualRPM(_ index: Int, rpm: Double, withReply reply: @escaping (Bool) -> Void) { reply(manualReply) }
        func setFanAuto(_ index: Int, holdUnlock: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func resetAllFans(withReply reply: @escaping (Bool) -> Void) { resets += 1; onReset?(); if replies { reply(true) } }
        // Entry 1208: the app never sends these on the fan connection.
        func helperInfo(withReply reply: @escaping (Int, Int) -> Void) { XCTFail("helperInfo on the fan connection") }
        func setFanManualRPMWithReason(_ index: Int, rpm: Double, withReply reply: @escaping (Int) -> Void) { XCTFail("reason engage") }
    }
    let proxy = Proxy()
    /// Set: replies are dropped and the error handler fires on a background queue,
    /// as XPC does for a helper that is gone (#479).
    var failOffMain = false
    override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
        if failOffMain {
            proxy.replies = false
            DispatchQueue.global().async { handler(CocoaError(.xpcConnectionInterrupted)) }
        }
        return proxy
    }
    override func invalidate() {}
}
