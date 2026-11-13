import Foundation
import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

/// #724: "Fans: Auto" and "Fans: Manual" from the phone. Every fan call goes through the
/// DchCommandOps.FanOps seams or a fake helper connection: no real helper, no SMC read or write,
/// no XPC. Preferences is the in-memory XCTest store; each test saves and restores what it sets.
@MainActor
final class DchFanCommandsTests: XCTestCase {

    /// Records what the commands asked of the fans.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        func add(_ s: String) { lock.withLock { _calls.append(s) } }
    }

    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
        func append(_ f: Data) { lock.withLock { all.append(f) } }
        var snapshot: [Data] { lock.withLock { all } }
    }

    /// Stands in for the ProsperHelper connection: counts resets and per-fan autos, never XPC.
    private final class FakeConnection: NSXPCConnection, @unchecked Sendable {
        final class Proxy: NSObject, ProsperHelperProtocol, @unchecked Sendable {
            var resets = 0
            var autos: [Int] = []
            func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setRemoteWake(_ json: String, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setRemoteSessionActive(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func clearRemoteSession(withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func sleepNow(withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setFanManualRPM(_ index: Int, rpm: Double, withReply reply: @escaping (Bool) -> Void) { reply(false) }
            func setFanAuto(_ index: Int, holdUnlock: Bool, withReply reply: @escaping (Bool) -> Void) { autos.append(index); reply(true) }
            /// Replies late, like a real helper, so a reply sent before the reset landed shows.
            func resetAllFans(withReply reply: @escaping (Bool) -> Void) {
                resets += 1
                nonisolated(unsafe) let reply = reply
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { reply(true) }
            }
        }
        let proxy = Proxy()
        override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any { proxy }
        override func invalidate() {}
    }

    /// Two adjustable fans and one with no range (never a target).
    nonisolated private static let twoFans = [
        FanReading(id: 1, min: 1000, max: 5000, current: 1500, manual: false),
        FanReading(id: 0, min: 1200, max: 6000, current: 1800, manual: false),
        FanReading(id: 2, min: 2000, max: 2000, current: 2000, manual: false),
    ]

    private func ops(fans: [FanReading] = DchFanCommandsTests.twoFans, enabled: Bool = true, log: Log,
                     first: FanManualReply = .engaged, later: FanManualReply = .engaged) -> DchCommandOps {
        DchCommandOps(enabled: { enabled }, registry: { log.add("registry"); return nil },
                      fans: .init(read: { log.add("read"); return fans },
                                  firstReply: { i, rpm in log.add("first \(i) \(Int(rpm))"); return first },
                                  engage: { i, rpm in log.add("engage \(i) \(Int(rpm))"); return later }))
    }

    /// Saves and restores the fan prefs and helper state around `body`. Drops any reclaim timer a
    /// sibling test left first (its tick could reapply saved targets for real), then starts
    /// with manual off, `[9: 1]` saved, awake, no connection.
    private func withFanState(_ body: () async throws -> Void) async rethrows {
        let manual = Preferences.fanManualEnabled, targets = Preferences.fanTargets, hold = Preferences.fanHoldUnlock
        let refused = FanControlHelper.lastRefusedFan
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        await FanControlHelper.resetAll(teardown: true)   // no connection: no call, timer dropped
        defer {
            Preferences.fanManualEnabled = manual; Preferences.fanTargets = targets; Preferences.fanHoldUnlock = hold
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
            FanControlHelper.userAdjusting = false; FanControlHelper.lastRefusedFan = refused
        }
        FanControlHelper.lastRefusedFan = nil   // engageOrder: fan 0 first, fan 1 later
        Preferences.fanManualEnabled = false
        Preferences.fanTargets = [9: 1]
        Preferences.fanHoldUnlock = false
        FanControlHelper.inject(sleeping: false)
        FanControlHelper.presetPending = false
        do { try await body() } catch { await disarm(); throw error }
        await disarm()
    }

    /// #737: a pending preset arms the real reclaim timer and sleep observers with manual on;
    /// drop them, the cooldown and the flag before the next test.
    private func disarm() async {
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        await FanControlHelper.resetAll(teardown: true)
        FanControlHelper.removeSleepObservers()
        FanControlHelper.deferReclaimRetry(now: .distantPast)
        FanControlHelper.presetPending = false
    }

    /// #728: a first engage that fails, or lands while asleep, releases on a Task of its own
    /// (firstEngageLanded). The test hands that release this fake and waits until it reset and
    /// tore down, so nothing the test started can outlive it and reset a sibling's fake.
    private func releaseSink() -> FakeConnection {
        let fake = FakeConnection()
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        return fake
    }

    private func awaitRelease(_ fake: FakeConnection, line: UInt = #line) async {
        for _ in 0..<300 where FanControlHelper.connection != nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fake.proxy.resets, 1, "the release reset the fans", line: line)
        XCTAssertTrue(FanControlHelper.connection == nil, "the release tore down", line: line)
    }

    /// #728: fakes the helper registration's outcome and records the approval modal instead of
    /// showing it. `log` gets "register" per registration and "modal <feature>" per modal.
    private func withRegistration(_ outcome: LidSleepHelper.RegisterOutcome, _ body: (Log) async throws -> Void) async rethrows {
        let registration = LidSleepHelper.registration, present = HelperApproval.present
        defer { LidSleepHelper.registration = registration; HelperApproval.present = present; HelperApproval.lastShown = .distantPast }
        let log = Log()
        LidSleepHelper.registration = { log.add("register"); return outcome }
        HelperApproval.present = { log.add("modal \($0)") }
        HelperApproval.lastShown = .distantPast
        try await body(log)
    }

    /// The phone's ops with the real FanOps engages (only the SMC read faked).
    private static let realEngages = DchCommandOps(enabled: { true }, registry: { nil }, fans: .init(read: { twoFans }))

    // MARK: Frames

    private static func type(_ f: Data) -> UInt8 { f[f.startIndex] }
    private static func json(_ f: Data) -> Any? { try? JSONSerialization.jsonObject(with: f.subdata(in: (f.startIndex + 5)..<f.endIndex)) }
    private static func message(_ f: Data?) -> String? {
        guard let f, type(f) == DchFrame.error else { return nil }
        return (json(f) as? [String: Any])?["message"] as? String
    }
    private static func result(_ f: Data?) -> [String: String]? {
        guard let f, type(f) == DchFrame.commandResult else { return nil }
        return json(f) as? [String: String]
    }

    private func request(_ ops: DchCommandOps, _ type: UInt8, _ body: Any?, line: UInt = #line) async -> Data? {
        let frames = Frames()
        let payload = body.map { (try? JSONSerialization.data(withJSONObject: $0)) ?? Data() } ?? Data()
        await ops.handle(type, payload, reply: { frames.append($0) })
        XCTAssertEqual(frames.snapshot.count, 1, "replies", line: line)
        return frames.snapshot.first
    }

    private func run(_ ops: DchCommandOps, _ id: String, _ argument: String? = nil, line: UInt = #line) async -> Data? {
        var body: [String: Any] = ["id": id]
        body["argument"] = argument
        return await request(ops, DchFrame.runCommand, body, line: line)
    }

    private func listed(_ ops: DchCommandOps) async -> [[String: String]] {
        let f = await request(ops, DchFrame.commands, nil)
        return f.flatMap(Self.json) as? [[String: String]] ?? []
    }

    // MARK: Listing

    func testListingHasBothFanRowsOnlyWithAnAdjustableFan() async {
        let log = Log()
        let rows = await listed(ops(log: log))
        XCTAssertEqual(rows, [
            ["id": "fans.auto", "title": "Fans: Auto", "subtitle": "Hand every fan back to macOS",
             "ext": "System Stats", "icon": "fan"],
            ["id": "fans.manual", "title": "Fans: Manual", "subtitle": "Every fan at a percent of its min-max speed",
             "ext": "System Stats", "argument": "60%", "icon": "fan"],
        ])
        for none in [[], [FanReading(id: 0, min: 2000, max: 2000, current: 2000, manual: false)]] {
            let rows = await listed(ops(fans: none, log: log))
            XCTAssertEqual(rows, [], "no adjustable fan: \(none)")
        }
        XCTAssertFalse(log.calls.contains { $0.hasPrefix("first") || $0.hasPrefix("engage") })
    }

    // MARK: Argument

    func testPercentParsing() {
        for (s, want) in [("60", 60.0), ("60%", 60), (" 60 % ", 60), ("0", 0), ("100%", 100), ("12.5", 12.5),
                          ("60.5", 60.5), ("0.0", 0), ("007", 7), ("100.0%", 100)] {
            XCTAssertEqual(DchCommandOps.percent(s), want, s)
        }
        // #728: plain decimal digits only. Double("…") took every one of the signed, hex and exponent forms.
        for s in ["", "%", "abc", "-1", "101", "100.5", "60%%", "nan", "inf", "6 0",
                  "-0", "-0%", "-0.0", "+60", "+0", "0x40", "0x1p4", "1e1", "6e1%", "60.", ".5", "60,5", "\u{0666}\u{0660}"] {
            XCTAssertNil(DchCommandOps.percent(s), s)
        }
        XCTAssertEqual(DchCommandOps.percent("0")?.sign, .plus, "zero is never negative")
    }

    func testBadSpeedIsAPlainErrorAndEngagesNothing() async {
        await withFanState {
            let log = Log()
            for bad in [nil, "", "abc", "-1", "101"] as [String?] {
                let f = await run(ops(log: log), "fans.manual", bad)
                XCTAssertEqual(Self.message(f), "speed must be 0-100%", bad ?? "nil")
            }
            XCTAssertEqual(log.calls.filter { $0 != "read" }, [])
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [9: 1])
        }
    }

    // MARK: Manual

    /// The shared popup engage: one first engage, the rest through engageRest, then the popup's
    /// own save of manual intent and the targets. Reply is the target rpm per fan.
    func testManualRunsThePopupEngageAndSavesIntent() async {
        await withFanState {
            let log = Log()
            let f = await run(ops(log: log), "fans.manual", "60%")
            XCTAssertEqual(Self.result(f), ["text": "Manual · 4080 / 3400 rpm", "detail": "target at 60%"])
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [0: 4080, 1: 3400])
            let engages = log.calls.filter { $0 != "read" }
            XCTAssertEqual(engages.count, 2)
            XCTAssertEqual(engages.filter { $0.hasPrefix("first") }.count, 1, "\(engages)")
            XCTAssertEqual(Set(engages.map { $0.split(separator: " ").dropFirst().joined(separator: " ") }),
                           ["0 4080", "1 3400"])
            XCTAssertFalse(log.calls.contains("registry"), "a fan id reached the Lua lookup")

            // One rpm for every fan reads once; 0 and 100 are the ends of each range.
            let same = [FanReading(id: 0, min: 1000, max: 5000, current: 0, manual: false),
                        FanReading(id: 1, min: 1000, max: 5000, current: 0, manual: false)]
            let one = await run(ops(fans: same, log: log), "fans.manual", "100")
            XCTAssertEqual(Self.result(one), ["text": "Manual · 5000 rpm", "detail": "target at 100%"])
            XCTAssertEqual(Preferences.fanTargets, [0: 5000, 1: 5000])
            let zero = await run(ops(fans: same, log: log), "fans.manual", "0")
            XCTAssertEqual(Self.result(zero)?["text"], "Manual · 1000 rpm")
        }
    }

    /// popupEngage's own guard runs on the phone's path too: a run taken while asleep saves nothing.
    func testManualWhileAsleepSavesNothing() async {
        await withFanState {
            FanControlHelper.inject(sleeping: true)
            let sink = releaseSink()
            let f = await run(ops(log: Log()), "fans.manual", "60")
            XCTAssertEqual(Self.message(f), "fans stayed automatic")
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [9: 1])
            await awaitRelease(sink)   // the engage landed asleep: released, and done before the test ends
        }
    }

    /// #737: the helper's latch refusing is a pending preset, as in the popup: intent and the
    /// targets saved (over any earlier ones), recovery armed, and the reply says it applies when
    /// the Mac cools down. No other fan engaged.
    func testLatchRefusalRepliesPendingAndSavesThePreset() async {
        await withFanState {
            for (manual, reply) in [(false, FanManualReply.refused), (false, .settling), (true, .refused)] {
                Preferences.fanManualEnabled = manual
                Preferences.fanTargets = [9: 1]
                let log = Log()
                let f = await run(ops(log: log, first: reply), "fans.manual", "60%")
                XCTAssertEqual(Self.result(f), ["text": "Manual pending · 4080 / 3400 rpm",
                                                "detail": "target at 60%, applies when the Mac cools down"], "\(reply)")
                XCTAssertTrue(Preferences.fanManualEnabled, "\(reply)")
                XCTAssertEqual(Preferences.fanTargets, [0: 4080, 1: 3400], "\(reply)")
                XCTAssertTrue(FanControlHelper.presetPending)
                XCTAssertTrue(FanControlHelper.recoveryLifecycleArmed)
                XCTAssertFalse(log.calls.contains { $0.hasPrefix("engage") }, "the rest engaged after a refusal")
                await disarm()
            }
        }
    }

    /// No reply from the helper is still the popup's error; nothing is saved, the engage is released.
    func testUnavailableComesBackAsThePopupErrorText() async throws {
        try await withFanState {
            let log = Log()
            let sink = releaseSink()
            let f = await run(ops(log: log, first: .unavailable), "fans.manual", "60%")
            XCTAssertEqual(Self.message(f), try XCTUnwrap(FanManualReply.unavailable.errorText))
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [9: 1])
            XCTAssertFalse(FanControlHelper.presetPending)
            XCTAssertFalse(log.calls.contains { $0.hasPrefix("engage") }, "the rest engaged after a failure")
            await awaitRelease(sink)
        }
    }

    // MARK: A later fan's reply (#926)

    /// The first fan (0) engaged and the later one (1) refused: the same pending reply and preset as
    /// a refused first fan, and fan 0 handed back to macOS by savePreset.
    func testALaterFansRefusalRepliesPendingAndSavesThePreset() async {
        await withFanState {
            let log = Log(), fake = FakeConnection()
            FanControlHelper.inject(connection: fake, engagesInFlight: 0)
            let f = await run(ops(log: log, later: .refused), "fans.manual", "60%")
            XCTAssertEqual(Self.result(f), ["text": "Manual pending · 4080 / 3400 rpm",
                                            "detail": "target at 60%, applies when the Mac cools down"])
            XCTAssertEqual(log.calls.filter { $0 != "read" }, ["first 0 4080", "engage 1 3400"])
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [0: 4080, 1: 3400])
            XCTAssertTrue(FanControlHelper.presetPending)
            for _ in 0..<200 where fake.proxy.resets == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(fake.proxy.resets, 1, "fan 0's pin was not handed back")
        }
    }

    /// A later .settling is a live refusal too: the same pending reply and preset as .refused.
    func testALaterFansSettlingRepliesPendingAndSavesThePreset() async {
        await withFanState {
            let log = Log(), fake = FakeConnection()
            FanControlHelper.inject(connection: fake, engagesInFlight: 0)
            let f = await run(ops(log: log, later: .settling), "fans.manual", "60%")
            XCTAssertEqual(Self.result(f), ["text": "Manual pending · 4080 / 3400 rpm",
                                            "detail": "target at 60%, applies when the Mac cools down"])
            XCTAssertEqual(log.calls.filter { $0 != "read" }, ["first 0 4080", "engage 1 3400"])
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [0: 4080, 1: 3400])
            XCTAssertTrue(FanControlHelper.presetPending)
            for _ in 0..<200 where fake.proxy.resets == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(fake.proxy.resets, 1, "fan 0's pin was not handed back")
        }
    }

    /// The later fan through FanOps' REAL engage (only the registration faked, no XPC): an unapproved
    /// helper is the approval text, never the modal, nothing saved, fan 0 released.
    func testALaterFansMissingApprovalRepliesTheApprovalText() async {
        await withRegistration(.needsApproval) { log in
            await withFanState {
                let sink = releaseSink()
                let firstLanded = DchCommandOps(enabled: { true }, registry: { nil }, fans: .init(read: { Self.twoFans },
                    firstReply: { i, rpm in log.add("first \(i) \(Int(rpm))"); return .engaged }))
                let f = await run(firstLanded, "fans.manual", "60%")
                XCTAssertEqual(Self.message(f), "Prosper's fan helper needs approval on the Mac: System Settings › General › Login Items")
                XCTAssertEqual(log.calls, ["first 0 4080", "register"], "the modal came up, or fan 1 never asked")
                XCTAssertFalse(Preferences.fanManualEnabled)
                XCTAssertEqual(Preferences.fanTargets, [9: 1])
                XCTAssertFalse(FanControlHelper.presetPending)
                await awaitRelease(sink)
            }
        }
    }

    /// The later fan through FanOps' REAL engage with registration failing (no XPC): no reply is the
    /// popup's unavailable text, nothing saved, fan 0 released.
    func testALaterFansNoReplyRepliesTheUnavailableText() async throws {
        try await withRegistration(.failed) { log in
            try await withFanState {
                let sink = releaseSink()
                let firstLanded = DchCommandOps(enabled: { true }, registry: { nil }, fans: .init(read: { Self.twoFans },
                    firstReply: { i, rpm in log.add("first \(i) \(Int(rpm))"); return .engaged }))
                let f = await run(firstLanded, "fans.manual", "60%")
                XCTAssertEqual(Self.message(f), "Couldn’t enable manual control — the Prosper helper isn’t "
                    + "running or wasn’t approved. Turn on “Prosper” under System Settings ▸ "
                    + "General ▸ Login Items ▸ Allow in the Background, then try again.")
                XCTAssertEqual(Self.message(f), try XCTUnwrap(FanManualReply.unavailable.errorText))
                XCTAssertEqual(log.calls, ["first 0 4080", "register"])
                XCTAssertFalse(Preferences.fanManualEnabled)
                XCTAssertEqual(Preferences.fanTargets, [9: 1])
                XCTAssertFalse(FanControlHelper.presetPending)
                await awaitRelease(sink)
            }
        }
    }

    // MARK: Helper approval (#728)

    /// The phone's Manual on an unapproved helper: a plain error naming the fix, never the modal.
    func testManualNeedsApprovalNamesTheFixWithoutTheModal() async {
        await withRegistration(.needsApproval) { log in
            await withFanState {
                let sink = releaseSink()
                let f = await run(Self.realEngages, "fans.manual", "60")
                XCTAssertEqual(Self.message(f), "Prosper's fan helper needs approval on the Mac: System Settings › General › Login Items")
                XCTAssertEqual(log.calls, ["register"], "the modal came up, or the engage never asked")
                XCTAssertFalse(Preferences.fanManualEnabled)
                XCTAssertEqual(Preferences.fanTargets, [9: 1])
                await awaitRelease(sink)

                // The other fans' engage registers again on its own: no modal there either.
                let firstLanded = DchCommandOps(enabled: { true }, registry: { nil },
                                                fans: .init(read: { Self.twoFans }, firstReply: { _, _ in .engaged }))
                _ = await run(firstLanded, "fans.manual", "60")
                XCTAssertEqual(log.calls, ["register", "register"])
            }
        }
    }

    /// Any other unavailability keeps the popup's "unavailable" text; still no modal.
    func testManualRegistrationFailureKeepsTheUnavailableText() async throws {
        try await withRegistration(.failed) { log in
            try await withFanState {
                let sink = releaseSink()
                let f = await run(Self.realEngages, "fans.manual", "60")
                XCTAssertEqual(Self.message(f), try XCTUnwrap(FanManualReply.unavailable.errorText))
                XCTAssertEqual(log.calls, ["register"])
                await awaitRelease(sink)
            }
        }
    }

    /// The popup's own engage keeps its modal and its words: the default stays presentModal true.
    func testPopupEngageStillPresentsTheModal() async {
        await withRegistration(.needsApproval) { log in
            await withFanState {
                let sink = releaseSink()
                let (saved, reply) = await StatsPopupView.engageManual([0: 3000])
                XCTAssertFalse(saved)
                XCTAssertEqual(reply, .needsApproval)
                XCTAssertEqual(reply.errorText, FanManualReply.unavailable.errorText, "the popup's text changed")
                XCTAssertEqual(log.calls, ["register", "modal Manual fan control"])
                await awaitRelease(sink)
            }
        }
    }

    /// Auto with hold-unlock and no connection registers through setAuto: the phone's run shows no
    /// modal and still replies Auto (no connection holds no pin); the popup's selectAuto shows it.
    func testAutoWithHoldUnlockNeedsApprovalShowsNoModal() async {
        await withRegistration(.needsApproval) { log in
            await withFanState {
                Preferences.fanHoldUnlock = true
                let f = await run(Self.realEngages, "fans.auto")
                XCTAssertEqual(Self.result(f), ["text": "Auto"])
                XCTAssertEqual(log.calls, ["register", "register"], "one setAuto per adjustable fan")
                await StatsPopupView.selectAuto(fanIDs: [0]).value
                XCTAssertEqual(log.calls, ["register", "register", "register", "modal Manual fan control"])
            }
        }
    }

    // MARK: Auto

    /// The popup's Automatic: intent off, targets cleared, resetAll(teardown: true) on the helper.
    func testAutoHandsEveryFanBackLikeThePopup() async {
        await withFanState {
            Preferences.fanManualEnabled = true
            Preferences.fanTargets = [0: 4000, 1: 3000]
            FanControlHelper.userAdjusting = true
            let fake = FakeConnection()
            FanControlHelper.inject(connection: fake, engagesInFlight: 0)
            let log = Log()
            let f = await run(ops(log: log), "fans.auto", "ignored")
            XCTAssertEqual(Self.result(f), ["text": "Auto"])
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [:])
            XCTAssertFalse(FanControlHelper.userAdjusting)
            XCTAssertEqual(fake.proxy.resets, 1)
            XCTAssertTrue(FanControlHelper.connection == nil, "replied before the reset landed and tore down")
            XCTAssertEqual(log.calls, ["read"])

            // Fast re-engage on: per-fan auto over the open connection, which stays.
            Preferences.fanManualEnabled = true
            Preferences.fanHoldUnlock = true
            let held = FakeConnection()
            FanControlHelper.inject(connection: held, engagesInFlight: 0)
            let g = await run(ops(log: log), "fans.auto")
            XCTAssertEqual(Self.result(g), ["text": "Auto"])
            XCTAssertEqual(held.proxy.autos, [0, 1])
            XCTAssertEqual(held.proxy.resets, 0)
            XCTAssertTrue(FanControlHelper.connection === held)
        }
    }

    // MARK: Gates

    func testOffRefusesFanCommandsAndTouchesNothing() async {
        await withFanState {
            Preferences.fanManualEnabled = true
            let log = Log()
            let off = ops(enabled: false, log: log)
            let list = await request(off, DchFrame.commands, nil)
            XCTAssertEqual(Self.message(list), "commands are off")
            for (id, arg) in [("fans.auto", nil), ("fans.manual", "60%")] as [(String, String?)] {
                let f = await run(off, id, arg)
                XCTAssertEqual(Self.message(f), "commands are off", id)
            }
            XCTAssertEqual(log.calls, [])
            XCTAssertTrue(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [9: 1])
        }
    }

    func testNoAdjustableFanRefusesBoth() async {
        await withFanState {
            Preferences.fanManualEnabled = true
            let log = Log()
            for (id, arg) in [("fans.auto", nil), ("fans.manual", "60%")] as [(String, String?)] {
                let f = await run(ops(fans: [], log: log), id, arg)
                XCTAssertEqual(Self.message(f), "no adjustable fans", id)
            }
            XCTAssertEqual(log.calls, ["read", "read"])
            XCTAssertTrue(Preferences.fanManualEnabled, "Auto with no fans changed the intent")
        }
    }
}
