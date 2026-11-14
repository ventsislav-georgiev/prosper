import XCTest
@testable import ProsperApp

/// #1033: a slider commit ends with every fan at the slider's targets, or every fan handed back to
/// macOS with a pending preset - never one fan at the new speed while the slider went back. Fakes
/// only: no XPC connection, no helper, no SMC.
@MainActor
final class FanCommitRuleTests: XCTestCase {
    /// The literal table: engageAll's per-fan replies (engage order, stopping at the first failure)
    /// for two and three fans -> the decision. The first fan's reply is taken as it is; a later
    /// fan's .settling (the heat gate was open for the fan before it) is a write failure.
    func testDecisionTable() {
        let rows: [(fans: Int, replies: [FanManualReply], want: FanCommit)] = [
            (2, [.engaged, .engaged], .landed),
            (2, [.refused], .keepNew(.refused)),
            (2, [.settling], .keepNew(.settling)),
            (2, [.unavailable], .keepPrevious(.unavailable)),
            (2, [.needsApproval], .keepPrevious(.needsApproval)),
            (2, [.engaged, .refused], .keepNew(.refused)),
            (2, [.engaged, .settling], .keepPrevious(.writeFailed)),
            (2, [.engaged, .unavailable], .keepPrevious(.unavailable)),
            (2, [.engaged, .needsApproval], .keepPrevious(.needsApproval)),
            (2, [.engaged], .keepPrevious(.unavailable)),
            (2, [], .keepPrevious(.unavailable)),
            (3, [.engaged, .engaged, .engaged], .landed),
            (3, [.refused], .keepNew(.refused)),
            (3, [.settling], .keepNew(.settling)),
            (3, [.unavailable], .keepPrevious(.unavailable)),
            (3, [.needsApproval], .keepPrevious(.needsApproval)),
            (3, [.engaged, .refused], .keepNew(.refused)),
            (3, [.engaged, .settling], .keepPrevious(.writeFailed)),
            (3, [.engaged, .unavailable], .keepPrevious(.unavailable)),
            (3, [.engaged, .engaged, .refused], .keepNew(.refused)),
            (3, [.engaged, .engaged, .settling], .keepPrevious(.writeFailed)),
            (3, [.engaged, .engaged, .unavailable], .keepPrevious(.unavailable)),
            (3, [.engaged, .engaged, .needsApproval], .keepPrevious(.needsApproval)),
            (3, [.engaged, .engaged], .keepPrevious(.unavailable)),
            (0, [], .landed),
        ]
        for row in rows {
            XCTAssertEqual(FanCommit.decide(row.replies, fans: row.fans, manualEnabled: true), row.want,
                           "\(row.fans) fans, \(row.replies)")
        }
        // Automatic landed while the commit was in flight: every outcome is a release.
        for replies: [FanManualReply] in [[.engaged, .engaged], [.engaged, .unavailable], [.refused], [.engaged, .settling]] {
            XCTAssertEqual(FanCommit.decide(replies, fans: 2, manualEnabled: false), .release, "\(replies)")
        }
    }

    func testAfterAnAcceptRenamesOnlySettling() {
        XCTAssertEqual(FanManualReply.settling.afterAnAccept, .writeFailed)
        for reply: FanManualReply in [.engaged, .refused, .unavailable, .needsApproval, .writeFailed] {
            XCTAssertEqual(reply.afterAnAccept, reply)
        }
        XCTAssertFalse(FanManualReply.writeFailed.isLatchRefusal)
    }

    /// Part B/C: a write failure has its own plain line, not the overheat one, not the helper one.
    func testWriteFailureHasItsOwnText() throws {
        let text = try XCTUnwrap(FanManualReply.writeFailed.errorText)
        XCTAssertEqual(text, "A fan didn’t take the new speed, so macOS runs every fan again. Try again.")
        for other: FanManualReply in [.refused, .settling, .unavailable] {
            XCTAssertNotEqual(other.errorText, text)
        }
        XCTAssertFalse(text.contains("overheat") || text.contains("cut-off") || text.contains("helper"))
    }

    /// QA 799 rider 2 through the burst and the commit's outcome: fan 0 took the new speed, a later fan
    /// did not (no reply, or a write failure). Every fan is handed back once, the slider and the saved
    /// targets show the previous speed as the pending preset, and the status line names the reply.
    func testALaterFansFailureHandsEveryFanBack() async {
        let manual = Preferences.fanManualEnabled, saved = Preferences.fanTargets
        let refused = FanControlHelper.lastRefusedFan
        defer {
            Preferences.fanManualEnabled = manual; Preferences.fanTargets = saved
            FanControlHelper.lastRefusedFan = refused
        }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        let previous: [Int: Double] = [0: 1500, 1: 1500, 2: 1500]
        let dragged: [Int: Double] = [0: 3000, 1: 3000, 2: 3000]
        for (failing, reply, text) in [(1, FanManualReply.unavailable, FanManualReply.unavailable.errorText),
                                       (2, .settling, FanManualReply.writeFailed.errorText),
                                       (2, .needsApproval, FanManualReply.needsApproval.errorText)] {
            FanControlHelper.lastRefusedFan = nil
            Preferences.fanManualEnabled = true
            Preferences.fanTargets = dragged   // the commit's own persist, before the burst
            FanControlHelper.presetPending = false
            var asked: [Int] = []
            let replies = await FanControlHelper.engageAll(dragged) { i, _ in
                asked.append(i); return i == failing ? reply : .engaged }
            XCTAssertEqual(asked, Array(0...failing), "\(reply)")
            let handedBack = expectation(description: "\(reply) on fan \(failing): every fan handed to macOS")
            let out = StatsPopupView.settleCommit(replies, dragged, previous: previous, reset: { handedBack.fulfill() })
            await fulfillment(of: [handedBack], timeout: 1)
            XCTAssertTrue(out.shown == previous, "\(reply): the slider kept the speed only some fans run")
            XCTAssertEqual(out.error, text, "\(reply)")
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, previous, "\(reply)")
            XCTAssertTrue(FanControlHelper.presetPending, "\(reply): the previous targets read as landed")
            XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: Date()), "\(reply): the re-apply was not deferred")
            Preferences.fanManualEnabled = false
            FanControlHelper.removeSleepObservers()
            await FanControlHelper.resetAll(teardown: true)   // no connection injected: only drops the timer
            FanControlHelper.deferReclaimRetry(now: .distantPast)
            FanControlHelper.presetPending = false
        }
    }

    // MARK: - R1218-1: non-finite and out-of-range speeds

    /// The literal inputs every guard below is fed. Nothing here converts a value with Int().
    private static let unusable: [Double] = [.nan, .infinity, -.infinity, -1, 0, 20_000, 1e300]

    func testUsableRPMTable() {
        for (rpm, want) in [(Double.nan, false), (.infinity, false), (-.infinity, false), (-1, false), (0, false),
                            (1e300, false), (20_000, false), (19_999, true), (1, true), (1500, true)] {
            XCTAssertEqual(FanRPM.usable(rpm), want, "\(rpm)")
        }
    }

    /// The saved-targets getter drops every unusable value it reads (written raw into the scratch
    /// suite's defaults, as a damaged or hand-edited plist would hold them); usable ones stay.
    func testSavedTargetsGetterDropsUnusableSpeeds() {
        let previous = Preferences.defaults.object(forKey: "fanTargets")
        defer { Preferences.defaults.set(previous, forKey: "fanTargets") }
        var raw: [String: Double] = ["7": 1500]
        for (i, v) in Self.unusable.enumerated() { raw[String(i)] = v }
        Preferences.defaults.set(raw, forKey: "fanTargets")
        XCTAssertEqual(Preferences.fanTargets, [7: 1500])
    }

    /// savePreset never saves an unusable target: the raw saved value (not the filtering getter) holds
    /// only the usable fan, and every fan is still handed back once.
    func testSavePresetNeverSavesAnUnusableTarget() async {
        let manual = Preferences.fanManualEnabled, previous = Preferences.defaults.object(forKey: "fanTargets")
        defer {
            Preferences.fanManualEnabled = manual; Preferences.defaults.set(previous, forKey: "fanTargets")
            FanControlHelper.removeSleepObservers(); FanControlHelper.deferReclaimRetry(now: .distantPast)
            FanControlHelper.presetPending = false
        }
        var targets: [Int: Double] = [7: 1500]
        for (i, v) in Self.unusable.enumerated() { targets[i] = v }
        let handedBack = expectation(description: "every fan handed to macOS")
        FanControlHelper.savePreset(targets, reset: { handedBack.fulfill() })
        await fulfillment(of: [handedBack], timeout: 2)
        let saved = Preferences.defaults.dictionary(forKey: "fanTargets") as? [String: Double]
        XCTAssertEqual(saved, ["7": 1500])
        XCTAssertTrue(Preferences.fanManualEnabled)
        XCTAssertTrue(FanControlHelper.presetPending)
        Preferences.fanManualEnabled = false
        await FanControlHelper.resetAll(teardown: true)   // no connection injected: drops the timer savePreset armed
    }

    /// No unusable speed reaches the helper call: the reply is a write failure (not the latch, so no
    /// caller saves it as a preset) and registration is never asked. The fake registration answers
    /// .failed, so even a call past the guard opens no connection.
    func testSetManualReplyNeverSendsAnUnusableSpeed() async {
        let registration = LidSleepHelper.registration, present = HelperApproval.present
        defer { LidSleepHelper.registration = registration; HelperApproval.present = present; HelperApproval.lastShown = .distantPast; FanControlHelper.inject(connection: nil, engagesInFlight: 0) }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        let asked = LockedBox()
        LidSleepHelper.registration = { asked.set(true); return .failed }
        HelperApproval.present = { _ in asked.set(false) }   // never a real modal
        for rpm in Self.unusable {
            let reply = await FanControlHelper.setManualReply(0, rpm: rpm, presentModal: false, macOSRPM: { _ in nil })
            XCTAssertEqual(reply, .writeFailed, "\(rpm)")
            XCTAssertFalse(reply.isLatchRefusal)
        }
        XCTAssertEqual(asked.get(), [], "an unusable speed went on to the helper's registration")
        XCTAssertEqual(FanControlHelper.engagesInFlight, 0)
    }

    /// The popup Manual click's seed: a non-finite current speed drops the fan (it stays with macOS);
    /// a finite one is clamped into the fan's range as before.
    func testManualSeedDropsANonFiniteCurrentSpeed() {
        let fan = FanReading(id: 0, min: 1000, max: 5000, current: 0, manual: false)
        for v in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(StatsPopupView.clampRPM(v, fan) == nil, "\(v)")
        }
        for (v, want) in [(-1.0, 1000.0), (0, 1000), (1500, 1500), (1e300, 5000)] {
            XCTAssertEqual(StatsPopupView.clampRPM(v, fan), want, "\(v)")
        }
    }
}
