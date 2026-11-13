import XCTest
@testable import ProsperHelperProtocol

/// Covers the remote-wake decisions without root/IOKit/network: debounce
/// collapses powerd's multi-notify, fail-safe sleeps on a bad poll, the battery
/// floor blocks promote (but still re-arms), residency gates idle-exit, and a
/// corrupt config disables rather than arming the root daemon.
final class RemoteWakeCoreTests: XCTestCase {

    /// Records effects + drives poll result and a mock clock.
    private final class Spy {
        var scheduled: [Double] = []
        var cancels = 0
        var promotes = 0
        var polls = 0
        var pollToken: String?    // nil = no request; a string = current request token
        var clock = Date(timeIntervalSince1970: 1_000_000)
        func tick(_ s: Double) { clock = clock.addingTimeInterval(s) }
    }

    private func make(_ spy: Spy, debounce: Double = 10) -> RemoteWakeCore {
        RemoteWakeCore(
            schedule: { spy.scheduled.append($0) },
            cancelAll: { spy.cancels += 1 },
            poll: { spy.polls += 1; return spy.pollToken },
            promote: { spy.promotes += 1 },
            now: { spy.clock },
            debounce: debounce)
    }

    private func cfg(enabled: Bool = true, ac: Double = 30, batt: Double = 300,
                     floor: Int = 20, url: String = "https://prosper.ventsislav-georgiev.com/wake/abc") -> RemoteWakeConfig {
        RemoteWakeConfig(enabled: enabled, pollURL: url, intervalAC: ac, intervalBatt: batt, batteryFloor: floor)
    }

    func testEnableGoesResidentAndArms() {
        let spy = Spy(); let core = make(spy)
        XCTAssertEqual(core.applyConfig(cfg(), onAC: false), .armResident)
        XCTAssertTrue(core.isResident)
        XCTAssertEqual(spy.scheduled, [300])            // battery interval first arm
    }

    func testEnableOnACUsesACInterval() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(ac: 90), onAC: true)
        XCTAssertEqual(spy.scheduled, [90])
    }

    // MARK: - #767 J19: AC floor 60 s and the AC back-off

    func testACIntervalFloorIs60() {
        // An app older than #767 still sends openlid's old 30 s; the daemon wakes at most once a minute on AC.
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(ac: 30), onAC: true)
        XCTAssertEqual(spy.scheduled, [60])
    }

    /// One acted AC wake `after` seconds from now; returns the interval it re-armed.
    private func acWake(_ core: RemoteWakeCore, _ spy: Spy, after: Double, userWake: Bool = false) -> Double? {
        spy.tick(after)
        _ = core.onWake(onAC: true, battPct: 90, userWake: userWake)
        return spy.scheduled.last
    }

    func testACBacksOffEveryTwoQuietHoursUpTo5Min() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: true)                            // quiet from here
        XCTAssertEqual(acWake(core, spy, after: 2 * 3600 - 60), 60)        // < 2 h: base
        XCTAssertEqual(acWake(core, spy, after: 120), 120)                 // 2 h: ×2
        XCTAssertEqual(acWake(core, spy, after: 2 * 3600), 240)            // 4 h: ×4
        XCTAssertEqual(acWake(core, spy, after: 2 * 3600), 300)            // 6 h: capped at the battery cadence
        XCTAssertEqual(acWake(core, spy, after: 48 * 3600), 300)           // stays capped
    }

    func testPromoteResetsTheBackoff() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: true)
        XCTAssertEqual(acWake(core, spy, after: 5 * 3600), 240)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(acWake(core, spy, after: 240), 60, "a real request re-arms at the base cadence")
        XCTAssertEqual(spy.promotes, 1)
    }

    func testUserWakeResetsTheBackoff() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: true)
        XCTAssertEqual(acWake(core, spy, after: 5 * 3600), 240)
        XCTAssertEqual(acWake(core, spy, after: 240, userWake: true), 60)
        XCTAssertEqual(acWake(core, spy, after: 60), 60, "quiet stretch restarted at the user wake")
    }

    func testLongWorkingSessionDoesNotCountAsQuiet() {
        // QA #598 F1: user wake at 08:00, 10 h of use, lid closed. The first dark
        // wake after that sleep must re-arm at the base, not at the 10 h level.
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: true)
        XCTAssertEqual(acWake(core, spy, after: 60, userWake: true), 60)
        XCTAssertEqual(acWake(core, spy, after: 10 * 3600), 60, "quiet counts from the sleep, not the user wake")
        XCTAssertEqual(acWake(core, spy, after: 2 * 3600 + 60), 120, "then backs off from there")
    }

    func testDebouncedUserWakeStillResets() {
        // A user wake that lands inside the debounce window is not acted on, but it
        // still ends the quiet stretch.
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: true)
        XCTAssertEqual(acWake(core, spy, after: 5 * 3600), 240)
        spy.tick(5)
        XCTAssertEqual(core.onWake(onAC: true, battPct: 90, userWake: true), .ignored)   // debounced
        XCTAssertEqual(acWake(core, spy, after: 20), 60)
    }

    func testACNeverSlowerThanTheConfiguredBatteryCadence() {
        // QA #598 INFO-3: battery set to 2 minutes caps the AC back-off at 120 s.
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(batt: 120), onAC: true)
        XCTAssertEqual(acWake(core, spy, after: 9 * 3600), 120)
    }

    func testBackoffStaysCappedAfterWeeksOfQuiet() {
        // The level is clamped before the shift; an unclamped 1 << level overflows to 0.
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: true)
        XCTAssertEqual(acWake(core, spy, after: 60 * 24 * 3600), 300)
    }

    func testReapplyConfigResetsTheBackoff() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: true)
        XCTAssertEqual(acWake(core, spy, after: 9 * 3600), 300)
        _ = core.applyConfig(cfg(), onAC: true)
        XCTAssertEqual(spy.scheduled.last, 60)
    }

    func testBatteryIntervalNeverBacksOff() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(batt: 300), onAC: false)
        spy.tick(9 * 3600)
        _ = core.onWake(onAC: false, battPct: 90)
        XCTAssertEqual(spy.scheduled, [300, 300])
    }

    func testACConfigAboveTheCapKeepsItsValue() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(ac: 900), onAC: true)
        XCTAssertEqual(acWake(core, spy, after: 9 * 3600), 900)
    }

    func testDisableCancelsAndIdleExits() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: false)
        XCTAssertEqual(core.applyConfig(cfg(enabled: false), onAC: false), .idleExit)
        XCTAssertFalse(core.isResident)
        XCTAssertEqual(spy.cancels, 1)
    }

    func testWakeWhileDisabledIgnored() {
        let spy = Spy(); let core = make(spy)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .ignored)
        XCTAssertEqual(spy.promotes, 0)
        XCTAssertTrue(spy.scheduled.isEmpty)
    }

    func testDebounceCollapsesMultiNotify() {
        let spy = Spy(); let core = make(spy, debounce: 10)
        _ = core.applyConfig(cfg(), onAC: false)        // scheduled: [300]
        spy.pollToken = nil
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .slept)
        spy.tick(3)                                     // within debounce
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .ignored)
        spy.tick(8)                                     // now past debounce
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .slept)
        XCTAssertEqual(spy.scheduled, [300, 300, 300])  // arm + 2 acted wakes, not 3
    }

    func testFailSafeSleepsOnBadPoll() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: false)
        spy.pollToken = nil
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .slept)
        XCTAssertEqual(spy.promotes, 0)
    }

    func testPromotesOnCleanFlag() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: false)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .promoted)
        XCTAssertEqual(spy.promotes, 1)
        XCTAssertTrue(core.isResident)                  // stays resident for next sleep
        XCTAssertEqual(spy.scheduled, [300, 300])       // re-armed after promote
    }

    func testBatteryFloorBlocksPromoteButReArms() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(floor: 50), onAC: false)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 30), .slept)  // below floor
        XCTAssertEqual(spy.promotes, 0)
        XCTAssertEqual(spy.scheduled, [300, 300])       // re-armed — plug in → next promotes
    }

    /// Below the floor we must NOT hit the network: a request couldn't promote, so
    /// skip the GET to save the radio. Leaving `lastWakeToken` untouched means the same
    /// pending token still reads as new once the battery recovers.
    func testBelowFloorSkipsPollEntirely() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(floor: 50), onAC: false)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 30), .slept)
        XCTAssertEqual(spy.polls, 0, "polled below floor — wasted the radio for a wake we can't act on")
    }

    func testAtOrAboveFloorStillPolls() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(floor: 50), onAC: false)
        spy.pollToken = nil
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 50), .slept)  // exactly at floor
        XCTAssertEqual(spy.polls, 1)
    }

    func testBatteryFloorIgnoredOnAC() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(floor: 50), onAC: true)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: true, battPct: 5), .promoted)  // charging → floor moot
        XCTAssertEqual(spy.promotes, 1)
    }

    func testUnknownBatteryDoesNotStrandPromote() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(floor: 50), onAC: false)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: -1), .promoted)
        XCTAssertEqual(spy.promotes, 1)
    }

    /// Edge-trigger: the SAME token sitting in KV across polls must wake exactly once,
    /// never re-promote — that re-promote-every-poll loop was the whole-night drain bug.
    func testSameTokenPromotesOnlyOnce() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: false)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .promoted)
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .slept)    // same token → no re-wake
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .slept)
        XCTAssertEqual(spy.promotes, 1)
    }

    /// A fresh request (new token from a new POST) after a prior wake must promote
    /// again — re-requesting a wake has to work.
    func testNewTokenPromotesAgain() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: false)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"; spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .promoted)
        spy.pollToken = "22222222-2222-4222-8222-222222222222"; spy.tick(11)                            // new POST → new token
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .promoted)
        XCTAssertEqual(spy.promotes, 2)
    }

    /// Captive-portal fail-safe: a hotel/airport proxy answers the GET with 200 + an
    /// HTML login page, which `poll` returns as a non-nil body. That must NOT read as a
    /// wake (false promote = drain). Only the server's UUID token shape promotes; any
    /// other 200 body sleeps and leaves the dedupe untouched so the real token still fires.
    func testCaptivePortalBodyDoesNotPromote() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(), onAC: false)
        spy.pollToken = "<html><body>Sign in to WiFi</body></html>"   // captive portal
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .slept)
        XCTAssertEqual(spy.promotes, 0)
        // dedupe untouched → the real token still promotes once the network clears
        spy.pollToken = "33333333-3333-4333-8333-333333333333"
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 90), .promoted)
        XCTAssertEqual(spy.promotes, 1)
    }

    /// A wake skipped below the floor isn't lost: the same token still pending when the
    /// battery recovers reads as new and promotes (we never advanced lastWakeToken).
    func testFloorSkippedTokenStillPromotesAfterRecovery() {
        let spy = Spy(); let core = make(spy)
        _ = core.applyConfig(cfg(floor: 50), onAC: false)
        spy.pollToken = "11111111-1111-4111-8111-111111111111"
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 30), .slept)    // below floor, skipped
        spy.tick(11)
        XCTAssertEqual(core.onWake(onAC: false, battPct: 80), .promoted) // recovered → still fires
        XCTAssertEqual(spy.promotes, 1)
    }

    // --- config validation (the on-disk trust boundary) ---

    func testSanitizeRejectsUnknownVersion() {
        var c = cfg(); c.version = 99
        XCTAssertFalse(c.sanitized().enabled)
    }

    func testSanitizeRejectsNonAllowlistedHost() {
        XCTAssertFalse(cfg(url: "https://evil.example.com/wake/abc").sanitized().enabled)
    }

    func testSanitizeRejectsNonHTTPS() {
        XCTAssertFalse(cfg(url: "http://prosper.ventsislav-georgiev.com/wake/abc").sanitized().enabled)
    }

    func testSanitizeAllowsLocalhostDev() {
        XCTAssertTrue(cfg(url: "http://127.0.0.1:8787/wake/abc").sanitized().enabled)
    }

    func testSanitizeClampsIntervalsAndFloor() {
        let s = cfg(ac: 0.1, batt: 999999, floor: 250).sanitized()
        XCTAssertEqual(s.intervalAC, 5)
        XCTAssertEqual(s.intervalBatt, 86400)   // ceiling = 1 day (the longest UI cadence)
        XCTAssertEqual(s.batteryFloor, 100)
    }

    func testSanitizeAllowsOneDayInterval() {
        // 1-day battery cadence (the "barely any drain" UI option) must survive.
        let s = cfg(batt: 86400).sanitized()
        XCTAssertEqual(s.intervalBatt, 86400)
    }

    func testFromJSONRoundTripAndGarbage() {
        let json = cfg().jsonString()
        XCTAssertTrue(RemoteWakeConfig.from(json: json).enabled)
        XCTAssertFalse(RemoteWakeConfig.from(json: "{not json").enabled)
        XCTAssertFalse(RemoteWakeConfig.from(json: "{}").enabled)
    }

    func testDisabledConfigSanitizesToDisabled() {
        XCTAssertFalse(cfg(enabled: false).sanitized().enabled)
    }

    func testSlowPollDoesNotDefeatDebounce() {
        // The injected poll can block ~22s (10s timeout + retry) inside onWake.
        // powerd's NEXT capability notification for the SAME wake then arrives with
        // the first timestamp already >debounce old — it must still be collapsed,
        // so the debounce clock is re-stamped after the poll completes.
        let spy = Spy()
        let slowSpyPoll: () -> String? = { spy.polls += 1; spy.tick(22); return spy.pollToken }
        let slow = RemoteWakeCore(
            schedule: { spy.scheduled.append($0) }, cancelAll: { spy.cancels += 1 },
            poll: slowSpyPoll, promote: { spy.promotes += 1 },
            now: { spy.clock }, debounce: 10)
        _ = slow.applyConfig(cfg(), onAC: false)

        XCTAssertEqual(slow.onWake(onAC: false, battPct: 80), .slept)  // poll took 22s
        spy.tick(1)                                                    // powerd's 2nd notify, 1s later
        XCTAssertEqual(slow.onWake(onAC: false, battPct: 80), .ignored) // collapsed, no 2nd poll
        XCTAssertEqual(spy.polls, 1)
    }

    func testSanitizeRejectionPreservesTrace() {
        // The disable / refuse-to-arm paths are exactly what the verbose log
        // debugs; sanitize must not silently drop the flag on its way to disabled.
        var off = cfg(enabled: false); off.trace = true
        XCTAssertTrue(off.sanitized().trace)
        var badHost = cfg(url: "https://evil.example.com/wake/abc"); badHost.trace = true
        XCTAssertFalse(badHost.sanitized().enabled)
        XCTAssertTrue(badHost.sanitized().trace)
        var badVersion = cfg(); badVersion.version = 99; badVersion.trace = true
        XCTAssertTrue(badVersion.sanitized().trace)
    }
}

/// Hot-path guard for `RemoteWakeCore.onWake` — runs on every dark wake, so the
/// decision (sans the injected network poll) must stay near-free. Budget per the
/// doc comment on `onWake`: **< 1 µs/call** decision-only. Generous CI ceiling.
final class RemoteWakeCorePerfTests: XCTestCase {
    override func setUpWithError() throws { try requireHeavyTests() }
    func testOnWakeDecisionIsSubMicrosecond() {
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        // debounce 0 so every iteration runs the full decide+re-arm path (not the
        // early-return); no-op effects so we measure only the core's own work.
        let core = RemoteWakeCore(
            schedule: { _ in }, cancelAll: {}, poll: { "11111111-1111-4111-8111-111111111111" }, promote: {},
            now: { fixed }, debounce: 0)
        _ = core.applyConfig(
            RemoteWakeConfig(enabled: true, pollURL: "https://prosper.ventsislav-georgiev.com/wake/abc",
                             intervalAC: 30, intervalBatt: 300, batteryFloor: 20),
            onAC: false)

        // First call promotes on "11111111-1111-4111-8111-111111111111"; every later call sees the same token and
        // returns at the dedupe guard — the realistic steady state (a request sits in
        // KV until TTL, so most polls re-see the same token).
        let n = 100_000
        for _ in 0..<1_000 { _ = core.onWake(onAC: true, battPct: 80) }   // warm
        let perCall = bestOfThreeNs {
            for _ in 0..<n { _ = core.onWake(onAC: true, battPct: 80) }
        } / Double(n)
        print("onWake decision hot path: \(String(format: "%.1f", perCall)) ns/call over \(n) iters (steady-state dedupe, no-op effects)")
        XCTAssertLessThan(perCall, 1_000, "onWake decision exceeded the 1µs hot-path budget")
    }
    private func bestOfThreeNs(_ body: () -> Void) -> Double {
        (0..<3).map { _ in
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - t0)
        }.min()!
    }
}

/// #1003 (QA 598 INFO-4): the powerd capability bits RemoteWakeObserver subscribes to and decodes.
final class WakeCapabilityTests: XCTestCase {
    /// The observer subscribes to CPU|Network and reads CPU, Network and Video
    /// (user) from what powerd hands it.
    func testWakeCapabilityInterestsAndDecode() {
        XCTAssertEqual(WakeCapability.interests, 9)
        let none = WakeCapability.decode(0)
        XCTAssertEqual([none.cpu, none.net, none.user], [false, false, false])
        let cpu = WakeCapability.decode(1)
        XCTAssertEqual([cpu.cpu, cpu.net, cpu.user], [true, false, false])
        let video = WakeCapability.decode(2)
        XCTAssertEqual([video.cpu, video.net, video.user], [false, false, true])
        let audio = WakeCapability.decode(4)
        XCTAssertEqual([audio.cpu, audio.net, audio.user], [false, false, false])
        let net = WakeCapability.decode(8)
        XCTAssertEqual([net.cpu, net.net, net.user], [false, true, false])
        let full = WakeCapability.decode(0x1F)
        XCTAssertEqual([full.cpu, full.net, full.user], [true, true, true])
    }

    /// The bit values match the SPI header the observer links against, and the observer reads
    /// them only through WakeCapability (a scan: the helper target has no test target).
    func testObserverUsesWakeCapabilityAndTheHeaderAgrees() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let header = try String(contentsOf: app.appendingPathComponent("Sources/ProsperHelper/include/RemoteWakeSPI.h"),
                                encoding: .utf8)
        for line in ["kIOPMCapabilityCPU     = (1 << 0),", "kIOPMCapabilityVideo   = (1 << 1),",
                     "kIOPMCapabilityNetwork = (1 << 3),"] {
            XCTAssertTrue(header.contains(line), line)
        }
        let observer = try String(contentsOf: app.appendingPathComponent("Sources/ProsperHelper/RemoteWakeObserver.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(observer.contains("let interests = IOPMCapabilityBits(WakeCapability.interests)"))
        XCTAssertTrue(observer.contains("let (cpu, net, user) = WakeCapability.decode(caps)"))
        XCTAssertFalse(observer.contains("kIOPMCapability"), "a capability bit read outside WakeCapability")
    }
}
