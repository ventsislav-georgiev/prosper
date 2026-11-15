import XCTest
@testable import ProsperHelperProtocol
@testable import SMCKit

/// #1207: the parts of the privileged fan daemon no test reached — the 30 s tick's step-to-action
/// map and setFanAuto's order (now `FanControlCore.tick` / `setFanAuto`), and SMCFanController's
/// writes (setAuto, resetAll, the RPM clamps). Fakes only: no SMC is opened, no fan, no helper.
final class FanDaemonSeamTests: XCTestCase {

    // MARK: - Fakes

    /// FanHardware for the core: every call recorded in order. No SMC.
    private final class Fan: FanHardware {
        struct Failed: Error {}
        var calls: [String] = []
        var temperature: Double? = 60
        var disengaged: Set<Int> = []
        var failWrites: Set<Int> = []
        var autoFails = false
        var ftst = true
        func maxTemperature(complete: Bool) -> Double? { calls.append("temp complete=\(complete)"); return temperature }
        func currentRPM(_ i: Int) -> Double? { calls.append("Ac \(i)"); return nil }
        func targetRPM(_ i: Int) -> Double? { calls.append("Tg \(i)"); return nil }
        func setManual(_ i: Int, rpm: Double) throws {
            calls.append("write \(i) \(rpm.isFinite ? "\(Int(rpm))" : "\(rpm)")")
            if failWrites.contains(i) { throw Failed() }
        }
        func isManualEngaged(_ i: Int) -> Bool { calls.append("engaged \(i)"); return !disengaged.contains(i) }
        func setAuto(_ i: Int, holdUnlock: Bool) throws {
            calls.append("auto \(i) hold=\(holdUnlock)")
            if autoFails { throw Failed() }
        }
        func hasFtst() -> Bool { calls.append("ftst"); return ftst }
        /// The calls without the reclaim probes (supervise probes the held fans in dictionary order).
        var ordered: [String] { calls.filter { !$0.hasPrefix("engaged") } }
    }

    /// SMCAccess with no SMC behind it: values by key, every attempted write recorded in order.
    /// N1230-b: a write to a key it was not given throws, as the real write does (it asks for the key's info first).
    private final class FakeSMC: SMCAccess {
        struct Rejected: Error {}
        var values: [String: SMCValue] = [:]
        var failing: Set<String> = []
        var writes: [String] = []
        func read(_ key: String) -> SMCValue? { values[key] }
        func exists(_ key: String) -> Bool { values[key] != nil }
        func allKeys() -> [String] { values.keys.sorted() }
        func writeRawUnchecked(_ key: String, _ bytes: [UInt8]) throws {
            writes.append("\(key) \(bytes)")
            if failing.contains(key) || values[key] == nil { throw Rejected() }
        }
        func set(_ key: String, _ type: String, _ value: Double) {
            values[key] = SMCValue(key: key, type: type, bytes: [], double: value)
        }
    }

    private final class Conn {}
    private let conn = Conn()
    private var holder: ObjectIdentifier { ObjectIdentifier(conn) }

    private final class Resets { var count = 0; var works = true }

    /// A core whose `holder` pins `targets`; its reset counts and returns `resets.works`.
    private func core(holding targets: [Int: Double], _ resets: Resets = Resets()) -> FanControlCore {
        let core = FanControlCore(reset: { resets.count += 1; return resets.works }, maxCelsius: { nil })
        for (i, rpm) in targets.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(core.manualRequest(index: i, rpm: rpm, holder: holder, maxCelsius: nil, macOSRPM: nil))
        }
        return core
    }

    /// One tick: whether the daemon cancels its timer, and its log events as text.
    private func tick(_ core: FanControlCore, _ fan: Fan?) -> (cancel: Bool, logs: [String]) {
        var logs: [String] = []
        let cancel = core.tick(fan) { event in
            switch event {
            case .step(let step, let mx): logs.append("\(step) at \(mx.map { "\($0)" } ?? "nil")")
            case .reassertFailed(let i, _): logs.append("reassert \(i) failed")
            case .releaseFailed: logs.append("release failed")
            }
        }
        return (cancel, logs)
    }

    // MARK: - The 30 s tick (main.swift fanKillTick_fanQ)

    /// Every step to its action, literally: what the fan saw, the log, the timer, what stays held.
    func testTickMapsEveryStepToItsAction() {
        // .stop: nothing held. No read, timer cancelled, no reset.
        do {
            let resets = Resets(), c = core(holding: [:], resets), fan = Fan()
            let r = tick(c, fan)
            XCTAssertEqual(r.cancel, true)
            XCTAssertEqual(r.logs, ["stop at nil"])
            XCTAssertEqual(fan.calls, [])
            XCTAssertEqual(resets.count, 0)
        }
        // .keep: held, 94.9 °C (under the 95 °C cut-off), engaged. Timer kept, nothing written.
        do {
            let resets = Resets(), c = core(holding: [0: 3000], resets), fan = Fan()
            fan.temperature = 94.9
            let r = tick(c, fan)
            XCTAssertEqual(r.cancel, false)
            XCTAssertEqual(r.logs, ["keep at 94.9"])
            XCTAssertEqual(fan.calls, ["temp complete=false", "engaged 0"])
            XCTAssertEqual(resets.count, 0)
            XCTAssertEqual(c.heldTargets, [0: 3000])
        }
        // .fired: held, exactly 95 °C. One reset, timer cancelled, nothing held, latched.
        do {
            let resets = Resets(), c = core(holding: [0: 3000], resets), fan = Fan()
            fan.temperature = 95
            let r = tick(c, fan)
            XCTAssertEqual(r.cancel, true)
            XCTAssertEqual(r.logs, ["fired at 95.0"])
            XCTAssertEqual(fan.calls, ["temp complete=false"])
            XCTAssertEqual(resets.count, 1)
            XCTAssertTrue(c.heldTargets.isEmpty)
            XCTAssertTrue(c.tripLatched)
        }
        // .reassert: fan 1 reclaimed. Its held target is written back, fan 0 is not; timer kept.
        do {
            let resets = Resets(), c = core(holding: [0: 3000, 1: 3100], resets), fan = Fan()
            fan.disengaged = [1]
            let r = tick(c, fan)
            XCTAssertEqual(r.cancel, false)
            XCTAssertEqual(r.logs, ["reassert([1]) at 60.0"])
            XCTAssertEqual(fan.ordered, ["temp complete=false", "write 1 3100"])
            XCTAssertEqual(Set(fan.calls.filter { $0.hasPrefix("engaged") }), ["engaged 0", "engaged 1"])
            XCTAssertEqual(resets.count, 0)
            XCTAssertEqual(c.heldTargets, [0: 3000, 1: 3100])
        }
        // .release: still reclaimed after the one re-assert, reset works. Timer cancelled, nothing held.
        do {
            let resets = Resets(), c = core(holding: [0: 3000], resets), fan = Fan()
            fan.disengaged = [0]
            XCTAssertEqual(tick(c, fan).logs, ["reassert([0]) at 60.0"])
            fan.calls = []
            let r = tick(c, fan)
            XCTAssertEqual(r.cancel, true)
            XCTAssertEqual(r.logs, ["release([0]) at 60.0"])
            XCTAssertEqual(fan.calls, ["temp complete=false", "engaged 0"])
            XCTAssertEqual(resets.count, 1)
            XCTAssertFalse(c.manualHeld)
            XCTAssertTrue(c.heldTargets.isEmpty)
            XCTAssertTrue(c.holder == nil)
        }
    }

    /// A re-assert write that throws is logged and the loop goes on to the next fan, ascending.
    func testTickReassertGoesOnPastAThrowingWrite() {
        let c = core(holding: [0: 3000, 1: 3100, 2: 3200]), fan = Fan()
        fan.disengaged = [0, 1, 2]
        fan.failWrites = [0]
        let r = tick(c, fan)
        XCTAssertEqual(r.cancel, false)
        XCTAssertEqual(r.logs, ["reassert([0, 1, 2]) at 60.0", "reassert 0 failed"])
        XCTAssertEqual(fan.ordered, ["temp complete=false", "write 0 3000", "write 1 3100", "write 2 3200"])
        XCTAssertEqual(c.heldTargets, [0: 3000, 1: 3100, 2: 3200])
        XCTAssertTrue(c.manualHeld)
    }

    /// A release whose reset fails keeps the timer and everything held; the next tick releases
    /// again, and the first reset that works cancels.
    func testTickFailedReleaseKeepsTheTimerAndRetries() {
        let resets = Resets(), c = core(holding: [0: 3000], resets), fan = Fan()
        resets.works = false
        fan.disengaged = [0]
        XCTAssertEqual(tick(c, fan).cancel, false)          // the one re-assert
        for n in 1...2 {
            let r = tick(c, fan)
            XCTAssertEqual(r.cancel, false, "try \(n)")
            XCTAssertEqual(r.logs, ["release([0]) at 60.0", "release failed"], "try \(n)")
            XCTAssertEqual(resets.count, n)
            XCTAssertTrue(c.manualHeld)
            XCTAssertEqual(c.heldTargets, [0: 3000])
            XCTAssertEqual(c.holder, holder)
        }
        resets.works = true
        let r = tick(c, fan)
        XCTAssertEqual(r.cancel, true)
        XCTAssertEqual(r.logs, ["release([0]) at 60.0"])
        XCTAssertFalse(c.manualHeld)
    }

    /// No SMC controller (the SMC failed to open): the hottest sensor reads nil and every fan reads
    /// engaged, so a held pin only keeps the timer: no reset, no write, never a release.
    func testTickWithoutAnSMCControllerKeepsAndWritesNothing() {
        let resets = Resets(), c = core(holding: [0: 3000], resets)
        for n in 1...3 {
            let r = tick(c, nil)
            XCTAssertEqual(r.cancel, false, "tick \(n)")
            XCTAssertEqual(r.logs, ["keep at nil"], "tick \(n)")
        }
        XCTAssertEqual(resets.count, 0)
        XCTAssertEqual(c.heldTargets, [0: 3000])
    }

    // MARK: - setFanAuto (main.swift)

    func testSetFanAutoWithoutAnSMCControllerRecordsNothing() throws {
        let c = core(holding: [0: 3000])
        var armed = 0
        XCTAssertFalse(try c.setFanAuto(nil, index: 0, holdUnlock: true, arm: { armed += 1 }))
        XCTAssertEqual(armed, 0)
        XCTAssertEqual(c.heldTargets, [0: 3000])
        XCTAssertTrue(c.manualHeld)
    }

    /// The write, then the target dropped, then (last fan, unlock kept, Ftst present) the arm.
    func testSetFanAutoWritesThenRecordsThenArms() throws {
        let c = core(holding: [0: 3000, 1: 3100]), fan = Fan()
        let arm = { fan.calls.append("arm") }
        XCTAssertTrue(try c.setFanAuto(fan, index: 0, holdUnlock: true, arm: arm))
        XCTAssertEqual(fan.calls, ["auto 0 hold=true"], "a sibling is still pinned: no Ftst read, no arm")
        XCTAssertEqual(c.heldTargets, [1: 3100])
        XCTAssertTrue(try c.setFanAuto(fan, index: 1, holdUnlock: true, arm: arm))
        XCTAssertEqual(fan.calls, ["auto 0 hold=true", "auto 1 hold=true", "ftst", "arm"])
        XCTAssertTrue(c.unlockHeld)
        XCTAssertFalse(c.manualHeld)
    }

    /// Unlock not kept: no Ftst read, no arm, and the crash reset stays armed. Kept but no Ftst: no arm.
    func testSetFanAutoWithoutHoldOrFtstArmsNothing() throws {
        var c = core(holding: [0: 3000])
        let fan = Fan()
        XCTAssertTrue(try c.setFanAuto(fan, index: 0, holdUnlock: false, arm: { fan.calls.append("arm") }))
        XCTAssertEqual(fan.calls, ["auto 0 hold=false"])
        XCTAssertTrue(c.manualHeld)
        XCTAssertTrue(c.heldTargets.isEmpty)
        c = core(holding: [0: 3000])
        fan.calls = []
        fan.ftst = false
        XCTAssertTrue(try c.setFanAuto(fan, index: 0, holdUnlock: true, arm: { fan.calls.append("arm") }))
        XCTAssertEqual(fan.calls, ["auto 0 hold=true", "ftst"])
        XCTAssertFalse(c.unlockHeld)
    }

    /// A throwing write rethrows before anything is recorded: the target, the holder and the crash
    /// reset stay, the next tick still supervises the pin, and the holder's drop still resets.
    func testSetFanAutoFailedWriteKeepsThePinHeld() {
        let resets = Resets(), c = core(holding: [0: 3000], resets), fan = Fan()
        fan.autoFails = true
        XCTAssertThrowsError(try c.setFanAuto(fan, index: 0, holdUnlock: true, arm: { fan.calls.append("arm") }))
        XCTAssertEqual(fan.calls, ["auto 0 hold=true"])
        XCTAssertEqual(c.heldTargets, [0: 3000])
        XCTAssertTrue(c.manualHeld)
        XCTAssertEqual(c.holder, holder)
        XCTAssertEqual(tick(c, Fan()).logs, ["keep at 60.0"])
        c.connectionClosed(holder)
        XCTAssertEqual(resets.count, 1)
    }

    // MARK: - SMCFanController writes, through a fake SMC

    /// A board with `fans` fans, uppercase mode keys, Ftst present (M1–M4) or not (M5+).
    private func board(fans: Int, ftst: Bool = true) -> (SMCFanController, FakeSMC) {
        let smc = FakeSMC()
        smc.set("FNum", "ui8 ", Double(fans))
        if ftst { smc.set("Ftst", "ui8 ", 0) }
        for i in 0..<fans { smc.set("F\(i)Md", "ui8 ", 0) }
        return (SMCFanController(access: smc), smc)
    }

    func testSetAutoWritesInThisOrder() throws {
        var (fc, smc) = board(fans: 2)
        try fc.setAuto(1, holdUnlock: false)
        XCTAssertEqual(smc.writes, ["F1Md [0]", "Ftst [0]"], "M1–M4: this fan's mode, then the master clear")
        (fc, smc) = board(fans: 2)
        try fc.setAuto(1, holdUnlock: true)
        XCTAssertEqual(smc.writes, ["F1Md [0]"], "unlock kept: the mode only")
        for hold in [false, true] {
            (fc, smc) = board(fans: 2, ftst: false)
            try fc.setAuto(1, holdUnlock: hold)
            XCTAssertEqual(smc.writes, ["F1Md [0]"], "M5+, hold \(hold)")
        }
        let lower = FakeSMC()
        lower.set("FNum", "ui8 ", 1)
        lower.set("F0md", "ui8 ", 0)
        try SMCFanController(access: lower).setAuto(0, holdUnlock: false)
        XCTAssertEqual(lower.writes, ["F0md [0]"], "lowercase mode-key board, no Ftst")
    }

    func testSetAutoWhenAWriteThrows() {
        var (fc, smc) = board(fans: 1)
        smc.failing = ["F0Md"]
        XCTAssertNoThrow(try fc.setAuto(0, holdUnlock: false), "M1–M4: a failed mode write is swallowed")
        XCTAssertEqual(smc.writes, ["F0Md [0]", "Ftst [0]"], "and Ftst is still cleared")
        (fc, smc) = board(fans: 1)
        smc.failing = ["Ftst"]
        XCTAssertThrowsError(try fc.setAuto(0, holdUnlock: false), "a failed master clear throws")
        XCTAssertEqual(smc.writes, ["F0Md [0]", "Ftst [0]"])
        (fc, smc) = board(fans: 1)
        smc.failing = ["F0Md"]
        XCTAssertThrowsError(try fc.setAuto(0, holdUnlock: true), "unlock kept: the mode write throws through")
        XCTAssertEqual(smc.writes, ["F0Md [0]"])
        (fc, smc) = board(fans: 1, ftst: false)
        smc.failing = ["F0Md"]
        XCTAssertThrowsError(try fc.setAuto(0, holdUnlock: false), "M5+: throws through")
        XCTAssertEqual(smc.writes, ["F0Md [0]"])
    }

    /// resetAll: every mode key, then Ftst, then FS! (best effort). Literal rows of what is written
    /// and what the result is when one write throws.
    func testResetAllWritesInThisOrderAndWhatGatesItsResult() {
        let all2 = ["F0Md [0]", "F1Md [0]", "Ftst [0]", "FS!  [0, 0]"]
        let rows: [(fans: Int, ftst: Bool, failing: String?, writes: [String], ok: Bool)] = [
            (2, true, nil, all2, true),
            (2, true, "F0Md", all2, false),
            (2, true, "Ftst", all2, false),
            (2, true, "FS! ", all2, true),
            (2, false, nil, ["F0Md [0]", "F1Md [0]", "FS!  [0, 0]"], true),
            (2, false, "F1Md", ["F0Md [0]", "F1Md [0]", "FS!  [0, 0]"], false),
            (0, false, nil, ["FS!  [0, 0]"], false),
            (0, true, nil, ["Ftst [0]", "FS!  [0, 0]"], true),
        ]
        for r in rows {
            let (fc, smc) = board(fans: r.fans, ftst: r.ftst)
            if let k = r.failing { smc.failing = [k] }
            XCTAssertEqual(fc.resetAll(), r.ok, "\(r)")
            XCTAssertEqual(smc.writes, r.writes, "\(r)")
        }
    }

    /// resetAllFans is the core's releaseAll over resetAll: a failed Ftst clear keeps everything held.
    func testResetAllFansDisarmsOnlyWhenTheClearsLanded() {
        let (fc, smc) = board(fans: 1)
        let c = FanControlCore(reset: { fc.resetAll() }, maxCelsius: { nil })
        XCTAssertTrue(c.manualRequest(index: 0, rpm: 3000, holder: holder, maxCelsius: nil, macOSRPM: nil))
        smc.failing = ["Ftst"]
        XCTAssertFalse(c.releaseAll())
        XCTAssertTrue(c.manualHeld)
        XCTAssertEqual(c.heldTargets, [0: 3000])
        XCTAssertEqual(c.holder, holder)
        smc.failing = []
        XCTAssertTrue(c.releaseAll())
        XCTAssertFalse(c.manualHeld)
        XCTAssertTrue(c.heldTargets.isEmpty)
        XCTAssertTrue(c.holder == nil)
    }

    // MARK: - The RPM clamps (literal numbers of today: floor 200, ceiling 20000)

    func testSetManualClampRows() {
        let rows: [(FanBounds, Double, Double)] = [
            (FanBounds(min: 1000, max: 6000), 999, 1000),
            (FanBounds(min: 1000, max: 6000), 1000, 1000),
            (FanBounds(min: 1000, max: 6000), 1001, 1001),
            (FanBounds(min: 1000, max: 6000), 5999, 5999),
            (FanBounds(min: 1000, max: 6000), 6000, 6000),
            (FanBounds(min: 1000, max: 6000), 6001, 6000),
            (FanBounds(min: 1000, max: 6000), -.infinity, 1000),
            (FanBounds(min: 1000, max: 6000), .infinity, 6000),
            // an SMC min under the floor: the floor wins
            (FanBounds(min: 100, max: 6000), 0, 200),
            (FanBounds(min: 100, max: 6000), 199, 200),
            (FanBounds(min: 100, max: 6000), 200, 200),
            (FanBounds(min: 100, max: 6000), 201, 201),
            // an SMC max over the ceiling (bounds() never returns one today): the ceiling wins
            (FanBounds(min: 1000, max: 25_000), 19_999, 19_999),
            (FanBounds(min: 1000, max: 25_000), 20_000, 20_000),
            (FanBounds(min: 1000, max: 25_000), 20_001, 20_000),
        ]
        for (b, rpm, want) in rows {
            XCTAssertEqual(SMCFanController.clampRPM(rpm, b), want, "\(b) \(rpm)")
        }
        XCTAssertTrue(SMCFanController.clampRPM(.nan, FanBounds(min: 1000, max: 6000)).isNaN,
                      "the clamp still lets a NaN through (Swift.max/min keep it); #1218: writeTarget throws on it, see testSetManualNaNThrowsAndHandsBack")
    }

    /// R1218-a: FNum is capped before Int(): a float of 2^63 or more trapped the root helper. N1225-a: the cap is 10,
    /// the one-digit indexes the write guard accepts. Nothing here converts a value the cap has not seen first
    /// (the fake SMC only; no real SMC).
    func testFanCountIsCappedBeforeTheConversion() {
        let rows: [(Double, Int)] = [(.nan, 0), (.infinity, 0), (-.infinity, 0), (-1, 0), (0, 0), (2, 2),
                                     (9, 9), (10, 10), (11, 10), (64, 10), (65, 10), (9.3e18, 10)]
        for (fnum, want) in rows {
            let smc = FakeSMC()
            smc.set("FNum", "flt ", fnum)
            XCTAssertEqual(SMCFanController(access: smc).fanCount(), want, "FNum \(fnum)")
        }
        // A garbage count still clears every real fan's mode key: capped, not zeroed.
        let (fc, smc) = board(fans: 2)
        smc.set("FNum", "flt ", 9.3e18)
        fc.resetAll()
        XCTAssertTrue(smc.writes.contains("F0Md [0]") && smc.writes.contains("F1Md [0]"), "\(smc.writes.prefix(4))")
    }

    /// N1225-a, restated by N1230-b: a garbage count over the cap tries the ten one-digit mode keys and no index of
    /// 10 or more. With two fans present the absent keys throw (as on a Mac): FALSE, the safe side (crash safety
    /// stays armed), after the two real fans and Ftst are cleared. With every fan up to the cap present: TRUE.
    /// Fake SMC only.
    func testResetAllIsFalseForAGarbageCountWithAbsentFansTrueWhenAllExist() {
        for (fnum, ftst) in [(11.0, true), (64, true), (9.3e18, true), (11, false), (64, false)] {
            for fans in [2, 10] {
                let (fc, smc) = board(fans: fans, ftst: ftst)
                smc.set("FNum", "ui8 ", fnum)
                XCTAssertEqual(fc.resetAll(), fans == 10, "FNum \(fnum) Ftst \(ftst) fans \(fans): \(smc.writes.suffix(3))")
                XCTAssertEqual(Array(smc.writes.prefix(2)), ["F0Md [0]", "F1Md [0]"], "FNum \(fnum) fans \(fans)")
                XCTAssertEqual(smc.writes.filter { $0.hasSuffix("Md [0]") }.count, 10, "FNum \(fnum) fans \(fans)")
                XCTAssertTrue(smc.writes.contains("F9Md [0]") && !smc.writes.contains { $0.hasPrefix("F10") }, "FNum \(fnum)")
                XCTAssertEqual(smc.writes.contains("Ftst [0]"), ftst, "FNum \(fnum) fans \(fans)")
            }
        }
    }

    func testTargetWriteClampRows() {
        let flt = FakeSMC()
        flt.set("F0Tg", "flt ", 0)
        let f = SMCFanController(access: flt)
        let fltRows: [(Float, Float)] = [(199, 200), (200, 200), (201, 201), (19_999, 19_999), (20_000, 20_000),
                                         (20_001, 20_000), (.nan, 200), (.infinity, 200), (-.infinity, 200)]
        for (rpm, want) in fltRows {
            XCTAssertEqual(SMCDecode.decodeFloatLE(f.clampTargetBytes("F0Tg", SMCDecode.encodeFloatLE(rpm))), want, "flt \(rpm)")
        }
        XCTAssertEqual(f.clampTargetBytes("F0Tg", [1, 2]), SMCDecode.encodeFloatLE(200), "short bytes: NaN, the floor")

        let fpe = FakeSMC()
        fpe.set("F0Tg", "fpe2", 0)
        let g = SMCFanController(access: fpe)
        for (rpm, want) in [(0, 200), (199, 200), (200, 200), (201, 201), (16_383, 16_383)] {
            XCTAssertEqual(SMCDecode.decodeFPE2(g.clampTargetBytes("F0Tg", SMCDecode.encodeFPE2(rpm))), want, "fpe2 \(rpm)")
        }
        XCTAssertEqual(g.clampTargetBytes("F0Tg", [1]), SMCDecode.encodeFPE2(200), "short bytes decode to 0: the floor")

        // F0Tg unreadable: the encoding follows Ftst (present: flt, absent: fpe2).
        let withFtst = FakeSMC()
        withFtst.set("Ftst", "ui8 ", 0)
        XCTAssertEqual(SMCFanController(access: withFtst).clampTargetBytes("F0Tg", SMCDecode.encodeFloatLE(150)),
                       SMCDecode.encodeFloatLE(200))
        XCTAssertEqual(SMCFanController(access: FakeSMC()).clampTargetBytes("F0Tg", SMCDecode.encodeFPE2(150)),
                       SMCDecode.encodeFPE2(200))
    }

    /// setManual end to end on an already-manual fan (no unlock, so no wait): the clamped target is the
    /// only write; a bad index writes nothing; unreadable bounds hand the fan back and throw.
    func testSetManualThroughTheFakeSMC() throws {
        func manualBoard() -> (SMCFanController, FakeSMC) {
            let smc = FakeSMC()
            smc.set("FNum", "ui8 ", 1)
            smc.set("Ftst", "ui8 ", 1)
            smc.set("F0Md", "ui8 ", 1)
            smc.set("F0Mn", "flt ", 1000)
            smc.set("F0Mx", "flt ", 6000)
            smc.set("F0Tg", "flt ", 2000)
            return (SMCFanController(access: smc), smc)
        }
        let rows: [(Double, Float)] = [(999, 1000), (6001, 6000), (.infinity, 6000), (-.infinity, 1000)]
        for (rpm, want) in rows {
            let (fc, smc) = manualBoard()
            try fc.setManual(0, rpm: rpm)
            XCTAssertEqual(smc.writes, ["F0Tg \(SMCDecode.encodeFloatLE(want))"], "\(rpm)")
        }
        var (fc, smc) = manualBoard()
        XCTAssertThrowsError(try fc.setManual(1, rpm: 3000)) { XCTAssertEqual($0 as? SMCError, SMCError.keyNotFound("F1")) }
        XCTAssertEqual(smc.writes, [])
        (fc, smc) = manualBoard()
        smc.values["F0Mn"] = nil
        XCTAssertThrowsError(try fc.setManual(0, rpm: 3000)) { XCTAssertEqual($0 as? SMCError, SMCError.clampUnsafe("F0")) }
        XCTAssertEqual(smc.writes, ["F0Md [0]", "Ftst [0]"])
    }

    /// #1218: a NaN speed throws clampUnsafe before any conversion (Int(NaN) would trap on an fpe2 board),
    /// and the only writes are setManual's hand-back to automatic. Float board and fpe2 board; the fpe2
    /// row relies on the check in writeTarget (without it the test process traps), so its mutant is described only.
    func testSetManualNaNThrowsAndHandsBack() {
        func manualBoard(type: String, ftst: Bool) -> (SMCFanController, FakeSMC) {
            let smc = FakeSMC()
            smc.set("FNum", "ui8 ", 1)
            if ftst { smc.set("Ftst", "ui8 ", 1) }
            smc.set("F0Md", "ui8 ", 1)
            smc.set("F0Mn", type, 1000)
            smc.set("F0Mx", type, 6000)
            smc.set("F0Tg", type, 2000)
            return (SMCFanController(access: smc), smc)
        }
        var (fc, smc) = manualBoard(type: "flt ", ftst: true)
        XCTAssertThrowsError(try fc.setManual(0, rpm: .nan)) { XCTAssertEqual($0 as? SMCError, SMCError.clampUnsafe("F0")) }
        XCTAssertEqual(smc.writes, ["F0Md [0]", "Ftst [0]"], "float board: only the hand-back, no F0Tg write")
        (fc, smc) = manualBoard(type: "fpe2", ftst: false)
        XCTAssertThrowsError(try fc.setManual(0, rpm: .nan)) { XCTAssertEqual($0 as? SMCError, SMCError.clampUnsafe("F0")) }
        XCTAssertEqual(smc.writes, ["F0Md [0]"], "fpe2 board: only the hand-back, no F0Tg write")
        for (rpm, want) in [(Double.infinity, 6000), (-Double.infinity, 1000)] {
            (fc, smc) = manualBoard(type: "fpe2", ftst: false)
            XCTAssertNoThrow(try fc.setManual(0, rpm: rpm))
            XCTAssertEqual(smc.writes, ["F0Tg \(SMCDecode.encodeFPE2(want))"], "fpe2 \(rpm)")
        }
    }

    // MARK: - The helper's queue (R1041-c), a source scan: text against text, nothing is run

    /// main.swift (the helper's source, read as text; the helper itself is never run): one serial `fanQ`, and the
    /// engage handler and the resetAllFans handler each hold exactly one `fanQ.async {` with the call the fan
    /// state change goes through (`engageCode`, `releaseAll`) inside it. A second queue, a concurrent `fanQ`, or a
    /// handler that calls the core outside the block reads red.
    func testTheHelperRunsEveryFanChangeInOneFanQBlockOnASerialQueue() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperHelper/main.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let queueLines = source.components(separatedBy: "\n").filter { $0.contains("fanQ = Dispatch" + "Queue(") }
        XCTAssertEqual(queueLines.count, 1, "exactly one fanQ declaration")
        XCTAssertFalse(queueLines.contains { $0.contains("attributes:") }, "fanQ is serial: no attributes")

        // A handler's text: from its func line to the first line that closes it (a lone four-space brace).
        func body(of header: String) -> String? {
            guard let start = source.range(of: header)?.lowerBound else { return nil }
            let rest = source[start...]
            guard let end = rest.range(of: "\n    }\n")?.lowerBound else { return nil }
            return String(rest[..<end])
        }
        let block = "fanQ.as" + "ync {"
        for (header, call) in [("private func engageFan(", "engage" + "Code("), ("func resetAllFans(", "release" + "All(")] {
            guard let text = body(of: header) else { XCTFail("\(header) not found"); continue }
            XCTAssertEqual(text.components(separatedBy: block).count - 1, 1, "\(header): exactly one fanQ block")
            let parts = text.components(separatedBy: block)
            XCTAssertFalse(parts[0].contains(call), "\(header): \(call) before the block")
            XCTAssertEqual(parts.dropFirst().joined().components(separatedBy: call).count - 1, 1, "\(header): \(call) once, inside the block")
        }
    }
}
