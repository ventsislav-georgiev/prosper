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
                     floor: Int = 20, url: String = "https://prosper.illegible.eu/wake/abc") -> RemoteWakeConfig {
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
        _ = core.applyConfig(cfg(), onAC: true)
        XCTAssertEqual(spy.scheduled, [30])
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
        XCTAssertFalse(cfg(url: "http://prosper.illegible.eu/wake/abc").sanitized().enabled)
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
}

/// Hot-path guard for `RemoteWakeCore.onWake` — runs on every dark wake, so the
/// decision (sans the injected network poll) must stay near-free. Budget per the
/// doc comment on `onWake`: **< 1 µs/call** decision-only. Generous CI ceiling.
final class RemoteWakeCorePerfTests: XCTestCase {
    func testOnWakeDecisionIsSubMicrosecond() {
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        // debounce 0 so every iteration runs the full decide+re-arm path (not the
        // early-return); no-op effects so we measure only the core's own work.
        let core = RemoteWakeCore(
            schedule: { _ in }, cancelAll: {}, poll: { "11111111-1111-4111-8111-111111111111" }, promote: {},
            now: { fixed }, debounce: 0)
        _ = core.applyConfig(
            RemoteWakeConfig(enabled: true, pollURL: "https://prosper.illegible.eu/wake/abc",
                             intervalAC: 30, intervalBatt: 300, batteryFloor: 20),
            onAC: false)

        // First call promotes on "11111111-1111-4111-8111-111111111111"; every later call sees the same token and
        // returns at the dedupe guard — the realistic steady state (a request sits in
        // KV until TTL, so most polls re-see the same token).
        let n = 100_000
        for _ in 0..<1_000 { _ = core.onWake(onAC: true, battPct: 80) }   // warm
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { _ = core.onWake(onAC: true, battPct: 80) }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n)
        print("onWake decision hot path: \(String(format: "%.1f", perCall)) ns/call over \(n) iters (steady-state dedupe, no-op effects)")
        XCTAssertLessThan(perCall, 1_000, "onWake decision exceeded the 1µs hot-path budget")
    }
}
