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

    /// #263 ordering B, step 2: N landed late and was held for N+1; N+1 fails with
    /// manual off → everything is released. With manual on (a later commit failing),
    /// or on success, nothing is.
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
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.refused, since: FanControlHelper.reclaimGeneration, release: { kept.fulfill() }))
        await fulfillment(of: [kept], timeout: 0.3)

        // #347 (2): a failed reply after a willSleep (generation changed) releases exactly
        // once with manual off, and not at all with manual on.
        let once = expectation(description: "failed reply after a sleep releases once")   // over-fulfill fails
        Preferences.fanManualEnabled = false
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.unavailable, since: 4, current: 5, sleeping: true, release: { once.fulfill() }))
        Preferences.fanManualEnabled = true
        XCTAssertFalse(FanControlHelper.firstEngageLanded(.refused, since: 4, current: 5, sleeping: true, release: { once.fulfill() }))
        await fulfillment(of: [once], timeout: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)   // room for a second release to over-fulfill
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

    /// #393: a hand-edited plist with "1", "01" and "+1" keys must not trap the getter.
    func testFanTargetsDropsNonCanonicalKeysInsteadOfTrapping() {
        let previousTargets = Preferences.fanTargets
        defer { Preferences.fanTargets = previousTargets }
        Preferences.defaults.set(["1": 2000.0, "01": 2500.0, "+1": 3000.0, "x": 1.0], forKey: "fanTargets")
        XCTAssertEqual(Preferences.fanTargets, [1: 2000])
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
        XCTAssertFalse(saved, "the popup saved the pref after a sleep inside its engage loop")
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
                                                     engage: { i, _ in restEngaged.append(i); return true })
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
                                                          engage: { i, _ in engaged.append(i); return true },
                                                          landed: { _ in checks += 1; return checks < stopAt })
            XCTAssertEqual(engaged.count, stopAt == 2 ? 2 : 3, "stopAt=\(stopAt): \(engaged)")
            XCTAssertFalse(engaged.contains(0))
            XCTAssertEqual(saved, stopAt != 2)
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
        // lateEngageLanded: `sleeping` default (manual on, so only sleep releases).
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
                engage: { i, _ in restEngaged.append(i); return true })
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
                engage: { i, _ in restEngaged.append(i); return true })
            XCTAssertFalse(saved, "the generation was captured after the first engage")
            XCTAssertEqual(restEngaged, [])
            await waitForTeardown()
            // since: pass-through: the rest checks the click's generation, not its own.
            FanControlHelper.inject(connection: FakeHelperConnection(), engagesInFlight: 0)
            (saved, _) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: sleepAndWake,
                firstLanded: { _, _, _ in true },
                engage: { i, _ in restEngaged.append(i); return true })
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
                engage: { _, _ in true }, landed: { _ in false })
            XCTAssertFalse(saved, "the popup saved the pref after engageRest stopped")
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, sentinel)
            (saved, _) = await FanControlHelper.popupEngage(targets, first: 0, engageFirst: { .engaged },
                engage: { _, _ in true }, landed: { _ in true })
            XCTAssertTrue(saved)
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, targets)
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
        XCTAssertTrue(core.manualRequest(index: 0, rpm: 3103, holder: holder, maxCelsius: 50, currentRPM: nil))
        XCTAssertEqual(core.supervise(maxCelsius: 96, isManualEngaged: { _ in true }), .fired)
        let trip = Date()
        let readings = [0, 1].map { FanReading(id: $0, min: 1350, max: 5777, current: 2500, manual: false) }
        XCTAssertTrue(FanReclaimRecovery.reclaimDetected(readings))
        let fraction = try XCTUnwrap(FanReclaimRecovery.manualFraction(targets: Preferences.fanTargets, readings: readings))
        var resets: [Bool] = []
        func reapply() async -> Bool {
            await FanControlHelper.applySavedTargets(
                reclaimGeneration: FanControlHelper.reclaimGeneration,
                engage: { i, rpm, _ in core.manualRequest(index: i, rpm: rpm, holder: holder, maxCelsius: 96, currentRPM: 2500) },
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
        defer {
            Preferences.fanManualEnabled = previousManualIntent; LidSleepHelper.registration = savedRegistration
            FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        }
        Preferences.fanManualEnabled = false
        LidSleepHelper.registration = { .enabled }
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        let reads = LockedBox()
        let speed: @Sendable (Int) -> Double? = { _ in reads.set(true); return 2500 }
        var reply = await FanControlHelper.setManualReply(0, rpm: 3103, currentRPM: speed)
        XCTAssertEqual(reply, .engaged)
        XCTAssertEqual(reads.get(), [], "no fan read on an engage")
        fake.proxy.manualReply = false
        reply = await FanControlHelper.setManualReply(0, rpm: 3103, currentRPM: speed)
        XCTAssertEqual(reply, .settling)
        reply = await FanControlHelper.setManualReply(0, rpm: 2000, currentRPM: speed)
        XCTAssertEqual(reply, .refused)
        XCTAssertEqual(reads.get().count, 2)
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

    func testCombineRefusalWinsThenUnavailable() {
        XCTAssertEqual(FanManualReply.combine([.engaged, .refused, .unavailable]), .refused)
        XCTAssertEqual(FanManualReply.combine([.engaged, .unavailable]), .unavailable)
        XCTAssertEqual(FanManualReply.combine([.engaged, .engaged]), .engaged)
        XCTAssertEqual(FanManualReply.combine([.engaged, .settling, .unavailable]), .settling)
        XCTAssertEqual(FanManualReply.combine([.settling, .refused]), .refused)
    }

    /// #586: the held text is only for a target below macOS's speed (or an unreadable one).
    func testRefusalIsNamedByMacOSSpeed() {
        XCTAssertEqual(FanManualReply.refusal(rpm: 3103, currentRPM: 2500), .settling)
        XCTAssertEqual(FanManualReply.refusal(rpm: 2500, currentRPM: 2500), .settling)
        XCTAssertEqual(FanManualReply.refusal(rpm: 2400, currentRPM: 2500), .refused)
        XCTAssertEqual(FanManualReply.refusal(rpm: 3103, currentRPM: nil), .refused)
        XCTAssertEqual(FanManualReply.refusal(rpm: 3103, currentRPM: .nan), .refused)
    }
}

private final class LockedBox: @unchecked Sendable {
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
        func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func setRemoteWake(_ json: String, withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func setRemoteSessionActive(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func clearRemoteSession(withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func sleepNow(withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func setFanManualRPM(_ index: Int, rpm: Double, withReply reply: @escaping (Bool) -> Void) { reply(manualReply) }
        func setFanAuto(_ index: Int, holdUnlock: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
        func resetAllFans(withReply reply: @escaping (Bool) -> Void) { resets += 1; if replies { reply(true) } }
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
