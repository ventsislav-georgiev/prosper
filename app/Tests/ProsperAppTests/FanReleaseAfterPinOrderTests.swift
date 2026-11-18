import XCTest
@testable import ProsperApp
@testable import ProsperHelperProtocol

/// Entry 1041, item 2: the release-after-pin order the app rests on (a late pin is cleared by the reset sent after it on
/// the same connection). The helper handles every fan message as ONE block on its serial `fanQ`, enqueued inline in the
/// XPC handler (ProsperHelper/main.swift engageFan and resetAllFans), and the block runs the core's entry point with the
/// SMC write inline: an engage is `FanControlCore.engageCode`, a reset `releaseAll`. These rows run those entry points the
/// same way, on a serial queue built as fanQ is, against a fake SMC that can hold a write. Fakes only: no helper, no
/// XPC, no SMC, no fan. XPC's own in-order delivery per connection is the platform's and is not run here.
/// Not main-actor isolated: every closure here runs on the row's queue or the test thread, none on main.
final class FanReleaseAfterPinOrderTests: XCTestCase {

    /// FanHardware with no SMC behind it: records each call in order (thread-safe: the queue writes, the row reads) and
    /// holds a write or a reset that `held` names until the row lets it go. `resetAll` is the core's injected reset.
    private final class HoldingFan: FanHardware, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _pinned: [Int: Double] = [:]
        private let gate = DispatchSemaphore(value: 0)
        /// "write" or "reset": that call waits on the gate after it started. Set before anything is queued.
        var held: String?
        /// Runs on the row's queue when the held call has started and is waiting.
        var onHeld: (@Sendable () -> Void)?

        var calls: [String] { lock.withLock { _calls } }
        var pinned: [Int: Double] { lock.withLock { _pinned } }
        func record(_ s: String) { lock.withLock { _calls.append(s) } }
        /// Lets a held call return. Extra signals are harmless; a row calls it in a defer so a red row never hangs.
        func letGo() { gate.signal() }

        private func hold(_ what: String) {
            guard held == what else { return }
            onHeld?()
            gate.wait()
        }

        func maxTemperature(complete: Bool) -> Double? { 60 }   // below the cut-off: the gate is open, nothing latched
        func currentRPM(_ i: Int) -> Double? { nil }            // read only while latched: never here
        func targetRPM(_ i: Int) -> Double? { nil }
        func setManual(_ i: Int, rpm: Double) throws {
            record("write \(i) start")
            hold("write")
            lock.withLock { _pinned[i] = rpm; _calls.append("write \(i) end") }
        }
        func isManualEngaged(_ i: Int) -> Bool { pinned[i] != nil }
        func setAuto(_ i: Int, holdUnlock: Bool) throws { lock.withLock { _pinned[i] = nil; _calls.append("auto \(i)") } }
        func hasFtst() -> Bool { false }
        func maxRPM(_ i: Int) -> Double? { nil }               // read only while latched at the cut-off: never here
        func resetAll() -> Bool {
            record("reset start")
            hold("reset")
            lock.withLock { _pinned = [:]; _calls.append("reset end") }
            return true
        }
    }

    /// The helper's two fan messages as its handlers enqueue them: one block each on `q`, the core's entry point inside.
    /// `arm` is a no-op (the helper's 30 s supervision timer is not built here).
    private static func pin(_ core: FanControlCore, _ fan: HoldingFan, on q: DispatchQueue, done: XCTestExpectation) {
        nonisolated(unsafe) let core = core   // touched only on q, as the helper touches fanCore only on fanQ
        q.async {
            let code = core.engageCode(fan, index: 0, rpm: 3000, holder: ObjectIdentifier(fan), arm: {},
                                       refused: { _ in }, failed: { _ in })
            fan.record("pin replied \(code == .engaged)")
            done.fulfill()
        }
    }

    private static func release(_ core: FanControlCore, _ fan: HoldingFan, on q: DispatchQueue, done: XCTestExpectation) {
        nonisolated(unsafe) let core = core
        q.async {
            fan.record("reset replied \(core.releaseAll())")
            done.fulfill()
        }
    }

    /// A pin, then a reset queued while the pin's SMC write is still under way (the fake holds it until the reset is
    /// queued): the reset waits for the pin, the recorder shows the pin's write ending before the reset starts, and every
    /// fan ends on automatic with nothing held. This is the late pin cleared by the release sent after it.
    func testAResetQueuedWhileThePinIsWritingRunsAfterItAndEveryFanEndsAutomatic() {
        let fan = HoldingFan()
        let core = FanControlCore(reset: { fan.resetAll() }, maxCelsius: { 60 })
        let q = DispatchQueue(label: "test.fan1041.fanQ")   // as the helper's fanQ: a plain label, so serial
        defer { fan.letGo(); q.sync {} }   // a red row leaves nothing held or queued, and fulfils nothing after it ends
        fan.held = "write"
        let writing = expectation(description: "the pin's write started and is held")
        fan.onHeld = { writing.fulfill() }
        let pinned = expectation(description: "the pin replied")
        let reset = expectation(description: "the reset replied")

        Self.pin(core, fan, on: q, done: pinned)
        wait(for: [writing], timeout: 5)
        Self.release(core, fan, on: q, done: reset)
        XCTAssertEqual(fan.calls, ["write 0 start"], "the reset ran while the pin was still writing")
        fan.letGo()
        wait(for: [pinned, reset], timeout: 5, enforceOrder: true)

        XCTAssertEqual(fan.calls, ["write 0 start", "write 0 end", "pin replied true",
                                   "reset start", "reset end", "reset replied true"])
        XCTAssertEqual(fan.pinned, [:], "a fan stayed at the pin's speed")
        let held = q.sync { (core.manualHeld, core.heldTargets, core.holder == nil) }
        XCTAssertFalse(held.0, "the reset left the crash reset armed")
        XCTAssertEqual(held.1, [:], "the reset left a target to re-assert")
        XCTAssertTrue(held.2, "the reset left the pin's holder")
    }

    /// The mirror: a reset, then a pin queued while the reset is still under way. The pin runs after it and the fan stays
    /// pinned, so the row above sees the order, not a fan that always ends automatic.
    func testAPinQueuedWhileTheResetIsRunningRunsAfterItAndStaysPinned() {
        let fan = HoldingFan()
        let core = FanControlCore(reset: { fan.resetAll() }, maxCelsius: { 60 })
        let q = DispatchQueue(label: "test.fan1041.fanQ")
        defer { fan.letGo(); q.sync {} }   // a red row leaves nothing held or queued, and fulfils nothing after it ends
        fan.held = "reset"
        let resetting = expectation(description: "the reset started and is held")
        fan.onHeld = { resetting.fulfill() }
        let reset = expectation(description: "the reset replied")
        let pinned = expectation(description: "the pin replied")

        Self.release(core, fan, on: q, done: reset)
        wait(for: [resetting], timeout: 5)
        Self.pin(core, fan, on: q, done: pinned)
        XCTAssertEqual(fan.calls, ["reset start"], "the pin ran while the reset was still under way")
        fan.letGo()
        wait(for: [reset, pinned], timeout: 5, enforceOrder: true)

        XCTAssertEqual(fan.calls, ["reset start", "reset end", "reset replied true",
                                   "write 0 start", "write 0 end", "pin replied true"])
        XCTAssertEqual(fan.pinned, [0: 3000])
        let held = q.sync { (core.manualHeld, core.heldTargets) }
        XCTAssertTrue(held.0, "a landed pin must arm the crash reset")
        XCTAssertEqual(held.1, [0: 3000])
    }
}

/// Entry 1041, item 3: one wording per reply on the popup and the phone. A first-fan Manual click at 60% on two fans
/// (fan 0: 1200...6000 rpm, fan 1: 1000...5000), by the helper's reply, written out. Fakes only: the phone path runs with
/// the FanOps seams and `FanCommitSaveTests.HeldConn` (no Mach service, no helper, no SMC), the registration is a seam
/// (no SMAppService), the identity throwaway factory returns nil, the popup is never built. The prefs are the scratch
/// XCTest defaults, saved and restored.
@MainActor
final class FanReplyWordingTests: XCTestCase {
    typealias HeldConn = FanCommitSaveTests.HeldConn

    nonisolated private static let fans = [
        FanReading(id: 1, min: 1000, max: 5000, current: 1500, manual: false),
        FanReading(id: 0, min: 1200, max: 6000, current: 1800, manual: false),
    ]
    private static let pending = "Waiting for macOS to hand back the fans. Prosper sets 60% as soon as it can."
    private static let tooHot = "Too hot: only maximum speed until it cools. Prosper sets 60% as soon as it can."
    private static let unavailable = "Couldn’t enable manual control — the Prosper helper isn’t running or wasn’t "
        + "approved. Turn on “Prosper” under System Settings ▸ General ▸ Login Items ▸ Allow in the Background, then try again."
    private static let writeFailed = "A fan didn’t take the new speed, so macOS runs every fan again. Try again."
    private static let approval = "Prosper's fan helper needs approval on the Mac: System Settings › General › Login Items"

    /// reply | the click saves a pending preset | the popup's line (nil: none) | the phone's text | its detail (nil: an error)
    private static let table: [(reply: FanManualReply, saved: Bool, popup: String?, phone: String, detail: String?)] = [
        (.engaged, false, nil, "Manual · 4080 / 3400 rpm", "target at 60%"),
        (.refused, true, pending, "Manual pending · 4080 / 3400 rpm", pending),
        (.settling, true, pending, "Manual pending · 4080 / 3400 rpm", pending),
        (.settlingReported, true, pending, "Manual pending · 4080 / 3400 rpm", pending),
        (.tooHot, true, tooHot, "Manual pending · 4080 / 3400 rpm", tooHot),
        (.unavailable, false, unavailable, unavailable, nil),
        (.needsApproval, false, unavailable, approval, nil),
        (.writeFailed, false, writeFailed, writeFailed, nil),
    ]

    /// Every case. The switch has no default: a new reply does not build until it is listed here and in the table.
    private static func listed(_ r: FanManualReply) -> Bool {
        switch r {
        case .engaged, .refused, .settling, .unavailable, .needsApproval, .writeFailed, .settlingReported, .tooHot: return true
        }
    }
    private static let every: [FanManualReply] = [.engaged, .refused, .settling, .unavailable, .needsApproval,
                                                   .writeFailed, .settlingReported, .tooHot]

    private var saved: (manual: Bool, hold: Bool, targets: [Int: Double], pending: Bool, refused: Int?) =
        (false, false, [:], false, nil)
    private var savedRegistration: (@Sendable () -> LidSleepHelper.RegisterOutcome)?
    private var savedFactory: (() -> NSXPCConnection?)?

    override func setUp() async throws {
        saved = (Preferences.fanManualEnabled, Preferences.fanHoldUnlock, Preferences.fanTargets,
                 FanControlHelper.presetPending, FanControlHelper.lastRefusedFan)
        Preferences.fanHoldUnlock = false   // a release leaves the connection nil
        Preferences.fanManualEnabled = false
        Preferences.fanTargets = [:]
        savedRegistration = LidSleepHelper.registration
        LidSleepHelper.registration = { .enabled }
        savedFactory = FanControlHelper.makeIdentityConnection
        FanControlHelper.makeIdentityConnection = { nil }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.inject(sleeping: false)
        FanControlHelper.helperMayHaveChanged()   // no verdict: no "older helper" sentence on a refusal
        FanControlHelper.presetPending = false
        FanControlHelper.lastRefusedFan = nil     // fan 0 is the first fan
    }

    override func tearDown() async throws {
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()
        FanControlHelper.presetPending = saved.pending
        FanControlHelper.lastRefusedFan = saved.refused
        if let savedRegistration { LidSleepHelper.registration = savedRegistration }
        if let savedFactory { FanControlHelper.makeIdentityConnection = savedFactory }
        Preferences.fanManualEnabled = saved.manual
        Preferences.fanHoldUnlock = saved.hold
        Preferences.fanTargets = saved.targets
    }

    func testTheTableHasEveryReplyOnce() {
        XCTAssertTrue(Self.every.allSatisfy(Self.listed))
        XCTAssertEqual(Set(Self.table.map(\.reply)), Set(Self.every))
        XCTAssertEqual(Self.table.count, Self.every.count, "a reply is in the table twice")
    }

    /// The popup: a saved click shows the pending line (StatsPopupView: the line once every fan is with macOS), an
    /// unsaved one `errorText`; the saved column is the click's own rule (`isLatchRefusal`, FanControlHelper.popupEngage).
    func testThePopupShowsTheTableText() {
        let targets: [Int: Double] = [0: 4080, 1: 3400]
        for row in Self.table {
            XCTAssertEqual(row.reply.isLatchRefusal, row.saved, "\(row.reply)")
            if row.saved {
                // Entry 1077: the popup passes FanControlHelper.pendingTooHot, set by that reply (FanReasonReplyTests).
                XCTAssertEqual(FanReclaimRecovery.pendingText(manualIntent: true, readings: Self.fans, targets: targets,
                                                              tooHot: row.reply == .tooHot),
                               row.popup, "\(row.reply)")
            } else {
                XCTAssertEqual(row.reply.errorText, row.popup, "\(row.reply)")
            }
        }
    }

    /// The phone's "Fans: Manual 60%" for every reply that saves nothing, through the real path (DchCommandOps.runFans
    /// -> StatsPopupView.engageManual -> popupEngage), and the release a failed click sends (a reset on the fake, waited
    /// for before the next reply). The three saved replies are not run here: savePreset arms the real reclaim timer; the
    /// phone builds their detail from the one sentence pinned below, and DchFanCommandsTests runs refused and settling.
    func testThePhoneAnswersTheTableText() async {
        XCTAssertEqual(FanReclaimRecovery.pendingSentence("60%"), Self.pending)
        XCTAssertEqual(FanReclaimRecovery.tooHotSentence("60%"), Self.tooHot)
        for row in Self.table where !row.saved {
            Preferences.fanManualEnabled = false
            Preferences.fanTargets = [:]
            let conn = HeldConn()
            FanControlHelper.inject(connection: conn, engagesInFlight: 0)
            let released = expectation(description: "\(row.reply): the failed click handed the fans back")
            if row.reply != .engaged { conn.onReset = { released.fulfill() } } else { released.fulfill() }
            let reply = row.reply, fans = Self.fans   // values captured, not Self
            let ops = DchCommandOps(enabled: { true }, registry: { nil },
                                    fans: .init(read: { fans }, firstReply: { _, _ in reply },
                                                engage: { _, _ in .engaged }))
            let f = await ops.runFans(DchCommandOps.fanManual, "60%")
            await fulfillment(of: [released], timeout: 5)
            conn.onReset = nil
            await Task { @MainActor in }.value   // the release's resetAll ended: no reset in flight
            let json = f.count > 5 ? f.subdata(in: (f.startIndex + 5)..<f.endIndex) : Data()   // the frame's 5-byte header
            let body = try? JSONSerialization.jsonObject(with: json) as? [String: String]
            if let detail = row.detail {
                XCTAssertEqual(body, ["text": row.phone, "detail": detail], "\(row.reply)")
            } else {
                XCTAssertEqual(body?["message"], row.phone, "\(row.reply)")
                XCTAssertEqual(conn.resets, 1, "\(row.reply): the failed click did not hand the fans back")
            }
        }
        Preferences.fanManualEnabled = false
    }
}
