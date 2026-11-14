import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

/// Entry 1234: while the helper said it answers `setFanManualRPMWithReason`, the app sends it and reads the
/// helper's own reason instead of guessing it; otherwise the Bool method and today's naming. Fakes only: the fan
/// connection and the identity throwaway are `FanHelperIdentityTests.FakeConn` (no Mach service, no helper, no
/// SMC, no SMAppService: the registration is a seam), the speed read is a seam, the ceiling and the retry are kept
/// and never fired on their own. Manual and the fast re-engage hold are off in the scratch defaults.
@MainActor
final class FanReasonReplyTests: XCTestCase {
    typealias FakeConn = FanHelperIdentityTests.FakeConn

    private var saved: (manual: Bool, hold: Bool, targets: [Int: Double], refused: Int?) = (false, false, [:], nil)
    private var savedRegistration: (@Sendable () -> LidSleepHelper.RegisterOutcome)?
    private var savedFactory: (() -> NSXPCConnection?)?
    private var savedCeiling: ((@escaping @Sendable @MainActor () -> Void) -> Void)?
    private var savedRetry: ((@escaping @Sendable @MainActor () -> Void) -> Void)?
    private let reads = LockedBox()
    /// The speed-read seam: records each read, reads 2500 rpm. No SMC.
    private var speed: @Sendable (Int) -> Double? { let r = reads; return { _ in r.set(true); return 2500 } }

    override func setUp() async throws {
        saved = (Preferences.fanManualEnabled, Preferences.fanHoldUnlock, Preferences.fanTargets, FanControlHelper.lastRefusedFan)
        Preferences.fanHoldUnlock = false
        Preferences.fanManualEnabled = false
        savedRegistration = LidSleepHelper.registration
        LidSleepHelper.registration = { .enabled }
        savedFactory = FanControlHelper.makeIdentityConnection
        savedCeiling = FanControlHelper.identityCeiling
        savedRetry = FanControlHelper.identityRetry
        FanControlHelper.makeIdentityConnection = { nil }
        FanControlHelper.identityCeiling = { _ in }
        FanControlHelper.identityRetry = { _ in }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()
    }

    override func tearDown() async throws {
        Preferences.fanManualEnabled = false
        FanControlHelper.makeIdentityConnection = { nil }
        FanControlHelper.removeSleepObservers()
        await FanControlHelper.resetAll(teardown: true)   // drops the reclaim timer setManualReply armed
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()
        FanControlHelper.presetPending = false
        FanControlHelper.deferReclaimRetry(now: .distantPast)
        if let savedRegistration { LidSleepHelper.registration = savedRegistration }
        if let savedFactory { FanControlHelper.makeIdentityConnection = savedFactory }
        if let savedCeiling { FanControlHelper.identityCeiling = savedCeiling }
        if let savedRetry { FanControlHelper.identityRetry = savedRetry }
        Preferences.fanManualEnabled = saved.manual
        Preferences.fanHoldUnlock = saved.hold
        Preferences.fanTargets = saved.targets
        FanControlHelper.lastRefusedFan = saved.refused
    }

    /// The verdict through the real ask, answered by a fake throwaway.
    private func answer(_ mode: FakeConn.Mode) async {
        let t = FakeConn()
        t.mode = mode
        FanControlHelper.makeIdentityConnection = { t }
        let closed = expectation(description: "throwaway closed")
        t.onInvalidate = { closed.fulfill() }
        XCTAssertTrue(FanControlHelper.askHelperIdentityIfIdle())
        await fulfillment(of: [closed], timeout: 5)
        t.onInvalidate = nil
        FanControlHelper.makeIdentityConnection = { nil }
    }

    private func engage(_ fan: Int = 0, rpm: Double = 3103) async -> FanManualReply {
        await FanControlHelper.setManualReply(fan, rpm: rpm, presentModal: false, macOSRPM: speed)
    }

    // The code table: each code and outside values (compared only).
    func testReasonCodeTable() {
        let rows: [(Int, FanManualReply)] = [
            (0, .engaged), (1, .settlingReported), (2, .refused), (3, .writeFailed), (4, .writeFailed), (5, .writeFailed),
            (-1, .writeFailed), (6, .writeFailed), (Int.max, .writeFailed), (Int.min, .writeFailed),
        ]
        for (code, want) in rows { XCTAssertEqual(FanManualReply.reason(code), want, "code \(code)") }
        XCTAssertTrue(FanManualReply.settlingReported.isLatchRefusal)
        XCTAssertEqual(FanManualReply.settlingReported.errorText, FanManualReply.settling.errorText)
        XCTAssertEqual(FanManualReply.settlingReported.afterAnAccept, .settlingReported, "only the guess is renamed")
        XCTAssertEqual(FanManualReply.settling.afterAnAccept, .writeFailed)
    }

    // (iv) The method follows the verdict, read once before the call: unknown and old send the Bool method and
    // name a false by the speed read as today; current sends the reason method and uses the code, with no read.
    func testTheMethodFollowsTheVerdict() async {
        let fan = FakeConn()
        FanControlHelper.inject(connection: fan, engagesInFlight: 0)
        fan.boolReply = false
        var reply = await engage()
        XCTAssertEqual(fan.sent, ["bool"], "unknown: the Bool method")
        XCTAssertEqual(reply, .settling, "named by the speed read (3103 >= 2500)")
        XCTAssertEqual(reads.get().count, 1)

        await answer(.answers(helperProtocolVersion, helperCapabilityFanReason))
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)
        // Code 2 is still named by the speed read too: 3103 reads at or above 2500, as an older helper's false did.
        for (code, rpm, want) in [(0, 3103.0, FanManualReply.engaged), (1, 3103, .settlingReported), (2, 2000, .refused),
                                  (2, 3103, .settling), (3, 3103, .writeFailed), (4, 3103, .writeFailed),
                                  (5, 3103, .writeFailed), (-1, 3103, .writeFailed), (6, 3103, .writeFailed),
                                  (Int.max, 3103, .writeFailed)] {
            fan.sent = []
            fan.reasonCode = code
            reply = await engage(rpm: rpm)
            XCTAssertEqual(fan.sent, ["reason"], "current: the reason method, code \(code)")
            XCTAssertEqual(reply, want, "code \(code) at \(rpm)")
        }
        XCTAssertEqual(reads.get().count, 3, "a speed read for code 2 only")
        XCTAssertEqual(FanControlHelper.lastRefusedFan, 0)

        FanControlHelper.helperMayHaveChanged()
        await answer(.answers(0, 0))
        XCTAssertTrue(FanControlHelper.helperIdentity == .old)
        fan.sent = []
        reply = await engage(1, rpm: 2000)
        XCTAssertEqual(fan.sent, ["bool"], "old: the Bool method")
        XCTAssertEqual(reply, .refused, "named by the speed read (2000 < 2500)")
        XCTAssertEqual(reads.get().count, 4)
    }

    // (v) A burst's second fan answers code 1: the slider commit keeps the NEW targets pending (it read as a write
    // failure with the previous ones before); both hand every fan back once and defer the re-apply alike. The
    // Manual click's later fan keeps the inference: a pending preset there would be re-applied, today's write
    // failure saves nothing.
    func testABurstsSecondFanSaysSettling() async {
        XCTAssertEqual(FanCommit.decide([.engaged, .settlingReported], fans: 2, manualEnabled: true), .keepNew(.settlingReported))
        XCTAssertEqual(FanCommit.decide([.engaged, .settling], fans: 2, manualEnabled: true), .keepPrevious(.writeFailed))
        XCTAssertEqual(FanCommit.decide([.writeFailed], fans: 2, manualEnabled: true), .keepPrevious(.writeFailed))
        XCTAssertEqual(FanCommit.decide([.engaged, .settlingReported], fans: 2, manualEnabled: false), .release)
        let previous: [Int: Double] = [0: 1500, 1: 1500], dragged: [Int: Double] = [0: 3000, 1: 3000]
        for (second, shown) in [(FanManualReply.settlingReported, dragged), (.settling, previous)] {
            Preferences.fanManualEnabled = true
            Preferences.fanTargets = dragged
            FanControlHelper.presetPending = false
            let handedBack = expectation(description: "\(second): every fan handed to macOS")
            let out = StatsPopupView.settleCommit([.engaged, second], dragged, previous: previous, reset: { handedBack.fulfill() })
            await fulfillment(of: [handedBack], timeout: 1)
            XCTAssertTrue(out.shown == shown, "\(second)")
            XCTAssertEqual(Preferences.fanTargets, shown, "\(second)")
            XCTAssertTrue(Preferences.fanManualEnabled && FanControlHelper.presetPending, "\(second)")
            XCTAssertFalse(FanControlHelper.reclaimTickAllowed(now: Date()), "\(second): the re-apply deferred")
            Preferences.fanManualEnabled = false
            FanControlHelper.removeSleepObservers()
            await FanControlHelper.resetAll(teardown: true)
            FanControlHelper.deferReclaimRetry(now: .distantPast)
        }
        for (second, want) in [(FanManualReply.settlingReported, FanManualReply.writeFailed), (.settling, .writeFailed),
                               (.refused, .refused), (.writeFailed, .writeFailed)] {
            let rest = await FanControlHelper.engageRest([0: 3000, 1: 3000], skipping: 0, since: 0,
                                                         engage: { i, _ in i == 1 ? second : .engaged }, landed: { _ in true })
            XCTAssertEqual(rest, want, "Manual click, later fan \(second)")
        }
    }

    // (v) A first fan with code 4: released, nothing saved, manual stays off (an older helper's false at this
    // speed read as settling and saved the targets as a pending preset).
    func testAFirstFanWriteFailureIsReleasedAndSavesNothing() async {
        let fan = FakeConn()
        FanControlHelper.inject(connection: fan, engagesInFlight: 0)
        await answer(.answers(helperProtocolVersion, helperCapabilityFanReason))
        fan.reasonCode = FanEngageCode.writeFailed.rawValue
        let before = Preferences.fanTargets
        let released = expectation(description: "released")
        let (saved, reply) = await FanControlHelper.popupEngage(
            [0: 3103, 1: 3103], first: 0, engageFirst: { await self.engage() },
            firstLanded: { FanControlHelper.firstEngageLanded($0, since: $1, sleeping: $2, release: { released.fulfill() }) },
            engage: { _, _ in XCTFail("no later fan after a failed first"); return .engaged })
        await fulfillment(of: [released], timeout: 1)
        XCTAssertFalse(saved)
        XCTAssertEqual(reply, .writeFailed)
        XCTAssertEqual(fan.sent, ["reason"])
        XCTAssertFalse(Preferences.fanManualEnabled, "nothing saved")
        XCTAssertEqual(Preferences.fanTargets, before)
        XCTAssertFalse(FanControlHelper.presetPending)
        XCTAssertEqual(reads.get(), [], "no speed read")
    }

    // R1208-3: an interruption on the reason call (an older helper put in place since the ask) reads as a dropped
    // connection (.unavailable); the fan connection's clear handler forgets the connection and the verdict, so the
    // next engage, on a new connection, sends the Bool method.
    func testAnInterruptionOnTheReasonCallReadsUnavailableAndUnknown() async {
        let fan = FakeConn()
        FanControlHelper.inject(connection: fan, engagesInFlight: 0)
        await answer(.answers(helperProtocolVersion, helperCapabilityFanReason))
        fan.reasonCode = nil
        let reply = await engage()
        XCTAssertEqual(reply, .unavailable)
        XCTAssertEqual(fan.sent, ["reason"])
        FanControlHelper.fanConnectionDropped(FakeConn())
        XCTAssertTrue(FanControlHelper.connection === fan && FanControlHelper.helperIdentity == .current, "another connection")
        FanControlHelper.fanConnectionDropped(fan)   // what makeConnection's interruption handler runs, on main
        XCTAssertTrue(FanControlHelper.connection == nil)
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "the verdict back to unknown")
        let next = FakeConn()
        next.boolReply = true
        FanControlHelper.inject(connection: next, engagesInFlight: 0)   // the new connection ensureConnection makes
        let again = await engage()
        XCTAssertEqual(again, .engaged)
        XCTAssertEqual(next.sent, ["bool"])
    }
}
