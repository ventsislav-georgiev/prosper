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
    private static let twoFans = [
        FanReading(id: 1, min: 1000, max: 5000, current: 1500, manual: false),
        FanReading(id: 0, min: 1200, max: 6000, current: 1800, manual: false),
        FanReading(id: 2, min: 2000, max: 2000, current: 2000, manual: false),
    ]

    private func ops(fans: [FanReading] = DchFanCommandsTests.twoFans, enabled: Bool = true, log: Log,
                     first: FanManualReply = .engaged) -> DchCommandOps {
        DchCommandOps(enabled: { enabled }, registry: { log.add("registry"); return nil },
                      fans: .init(read: { log.add("read"); return fans },
                                  firstReply: { i, rpm in log.add("first \(i) \(Int(rpm))"); return first },
                                  engage: { i, rpm in log.add("engage \(i) \(Int(rpm))"); return true }))
    }

    /// Saves and restores the fan prefs and helper state around `body`. Drops any reclaim timer a
    /// sibling test left first (its tick could reapply saved targets for real), then starts
    /// with manual off, `[9: 1]` saved, awake, no connection.
    private func withFanState(_ body: () async throws -> Void) async rethrows {
        let manual = Preferences.fanManualEnabled, targets = Preferences.fanTargets, hold = Preferences.fanHoldUnlock
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        await FanControlHelper.resetAll(teardown: true)   // no connection: no call, timer dropped
        defer {
            Preferences.fanManualEnabled = manual; Preferences.fanTargets = targets; Preferences.fanHoldUnlock = hold
            FanControlHelper.inject(connection: nil, engagesInFlight: 0); FanControlHelper.inject(sleeping: false)
            FanControlHelper.userAdjusting = false
        }
        Preferences.fanManualEnabled = false
        Preferences.fanTargets = [9: 1]
        Preferences.fanHoldUnlock = false
        FanControlHelper.inject(sleeping: false)
        try await body()
    }

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
        for (s, want) in [("60", 60.0), ("60%", 60), (" 60 % ", 60), ("0", 0), ("100%", 100), ("12.5", 12.5)] {
            XCTAssertEqual(DchCommandOps.percent(s), want, s)
        }
        for s in ["", "%", "abc", "-1", "101", "100.5", "60%%", "nan", "inf", "6 0"] {
            XCTAssertNil(DchCommandOps.percent(s), s)
        }
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
            let f = await run(ops(log: Log()), "fans.manual", "60")
            XCTAssertEqual(Self.message(f), "fans stayed automatic")
            XCTAssertFalse(Preferences.fanManualEnabled)
            XCTAssertEqual(Preferences.fanTargets, [9: 1])
        }
    }

    /// A refusal is the command's error in the popup's words; nothing is saved and an existing
    /// manual intent is kept as it was (the popup's commit revert).
    func testRefusalComesBackAsThePopupErrorText() async throws {
        try await withFanState {
            for (manual, reply) in [(false, FanManualReply.refused), (false, .settling), (false, .unavailable), (true, .refused)] {
                Preferences.fanManualEnabled = manual
                let log = Log()
                let f = await run(ops(log: log, first: reply), "fans.manual", "60%")
                XCTAssertEqual(Self.message(f), try XCTUnwrap(reply.errorText), "\(reply)")
                XCTAssertEqual(Preferences.fanManualEnabled, manual)
                XCTAssertEqual(Preferences.fanTargets, [9: 1])
                XCTAssertFalse(log.calls.contains { $0.hasPrefix("engage") }, "the rest engaged after a refusal")
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
