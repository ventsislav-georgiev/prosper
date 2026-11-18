import XCTest
@testable import ProsperApp

/// Entry 982: a dropped Manual click says why (QA #91), and a later fan's engage has a wall-clock ceiling on its
/// registration wait (QA #211). Fakes only: no connection is injected, the registration is the seam, no helper,
/// no SMC, no modal.
@MainActor
final class FanEngageLeftoversTests: XCTestCase {
    private func withFanState(_ body: () async throws -> Void) async rethrows {
        let manual = Preferences.fanManualEnabled, targets = Preferences.fanTargets
        let refused = FanControlHelper.lastRefusedFan, ceiling = FanControlHelper.laterEngageCeiling
        let registration = LidSleepHelper.registration, present = HelperApproval.present
        defer {
            Preferences.fanManualEnabled = manual; Preferences.fanTargets = targets
            FanControlHelper.lastRefusedFan = refused; FanControlHelper.laterEngageCeiling = ceiling
            LidSleepHelper.registration = registration; HelperApproval.present = present
            HelperApproval.lastShown = .distantPast
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
        }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.inject(sleeping: false)
        FanControlHelper.lastRefusedFan = nil   // engageOrder: fan 0 first, fan 1 later
        Preferences.fanManualEnabled = false
        Preferences.fanTargets = [9: 1]
        HelperApproval.present = { _ in XCTFail("a modal was presented") }
        try await body()
        await FanControlHelper.resetAll(teardown: true)   // no connection: no call, timer dropped
    }

    /// QA #91: the status line of a click that saved nothing. A failed reply keeps its own text; a click dropped with
    /// its fans engaged names the sleep or the Automatic, never an empty line.
    func testAnUnsavedClickAlwaysSaysWhy() {
        XCTAssertEqual(StatsPopupView.unsavedClickText(.engaged, automaticChosen: false), StatsPopupView.droppedForSleepText)
        XCTAssertEqual(StatsPopupView.unsavedClickText(.engaged, automaticChosen: true), StatsPopupView.droppedForAutomaticText)
        XCTAssertNotEqual(StatsPopupView.droppedForSleepText, StatsPopupView.droppedForAutomaticText)
        for reply: FanManualReply in [.refused, .settling, .unavailable, .needsApproval, .writeFailed, .tooHot] {
            for automatic in [false, true] {
                XCTAssertEqual(StatsPopupView.unsavedClickText(reply, automaticChosen: automatic), reply.errorText,
                               "\(reply), \(automatic)")
            }
        }
        XCTAssertTrue(StatsPopupView.droppedForSleepText.contains("sleep"))
        XCTAssertTrue(StatsPopupView.droppedForAutomaticText.contains("Automatic"))
    }

    /// QA #91 through the click: a sleep while the first fan engages drops the click (nothing saved, reply
    /// .engaged), and the line the popup shows for it is the sleep sentence.
    func testAClickDroppedBySleepShowsTheSleepLine() async {
        await withFanState {
            let r = await StatsPopupView.engageManual([0: 3000, 1: 2500], firstReply: { @MainActor _, _ in
                FanControlHelper.willSleep()   // no connection: bumps the generation, no reset
                return .engaged
            }, engage: { _, _ in XCTFail("a later fan was engaged after the sleep"); return .writeFailed })
            XCTAssertFalse(r.saved)
            XCTAssertEqual(r.reply, .engaged)
            XCTAssertEqual(Preferences.fanTargets, [9: 1], "the dropped click saved its targets")
            XCTAssertEqual(StatsPopupView.unsavedClickText(r.reply, automaticChosen: false), StatsPopupView.droppedForSleepText)
        }
    }

    /// QA #211: the later fan's registration hangs. The click's default later engage ends at the ceiling as
    /// .unavailable (fanBusy clears), saves nothing and opens no connection. Without the ceiling the click
    /// waits for the registration: the expectation times out (the gate opens after, so nothing hangs).
    func testALaterEngageEndsAtTheRegistrationCeiling() async {
        await withFanState {
            FanControlHelper.laterEngageCeiling = 0.2
            let parked = expectation(description: "the later fan's engage waits in registration")
            let finished = expectation(description: "the parked registration returned")
            let gate = DispatchSemaphore(value: 0)
            LidSleepHelper.registration = { parked.fulfill(); gate.wait(); gate.signal(); finished.fulfill(); return .failed }
            let resolved = expectation(description: "the click resolved at the ceiling")
            let click = Task { @MainActor in
                let r = await StatsPopupView.engageManual([0: 3000, 1: 2500], firstReply: { _, _ in .engaged })
                resolved.fulfill()
                return r
            }
            await fulfillment(of: [parked, resolved], timeout: 5)
            gate.signal()
            let r = await click.value
            XCTAssertFalse(r.saved)
            XCTAssertEqual(r.reply, .unavailable)
            XCTAssertEqual(Preferences.fanTargets, [9: 1], "the click saved its targets")
            await fulfillment(of: [finished], timeout: 5)
            await Task { @MainActor in }.value   // the orphaned registration's main-actor tail ran
            XCTAssertTrue(FanControlHelper.connection == nil, "a connection was opened for the timed-out engage")
        }
    }

    /// QA #211, the phone's "Fans: Manual": its later-fan engage (FanOps' default) ends at the same ceiling.
    func testThePhonesLaterEngageEndsAtTheRegistrationCeiling() async {
        await withFanState {
            FanControlHelper.laterEngageCeiling = 0.2
            let finished = expectation(description: "the parked registration returned")
            let gate = DispatchSemaphore(value: 0)
            LidSleepHelper.registration = { gate.wait(); gate.signal(); finished.fulfill(); return .failed }
            let resolved = expectation(description: "the phone's later engage resolved at the ceiling")
            let engage = Task { @MainActor in
                let reply = await DchCommandOps.FanOps().engage(1, 2500)
                resolved.fulfill()
                return reply
            }
            await fulfillment(of: [resolved], timeout: 5)
            gate.signal()
            let reply = await engage.value
            XCTAssertEqual(reply, .unavailable)
            await fulfillment(of: [finished], timeout: 5)
            await Task { @MainActor in }.value
            XCTAssertTrue(FanControlHelper.connection == nil, "a connection was opened for the timed-out engage")
        }
    }
}
