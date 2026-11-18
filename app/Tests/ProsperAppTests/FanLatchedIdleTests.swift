import XCTest
@testable import ProsperHelperProtocol

/// #981 (QA #26): the trip latch lives only in the helper's memory, so the helper's idle exit asks
/// `FanControlCore.idleMayExit` first and stays while latched, until a complete cool reading or the bound.
/// A fake fan, an injected clock and explicit durations only: no SMC, no helper, no real fan, no timer.
final class FanLatchedIdleTests: XCTestCase {
    /// FanControlCoreTests' FakeFan is private to that file; this is the smallest copy, with the
    /// complete and the incomplete hottest read kept apart.
    private final class FakeFan: FanHardware {
        var calls: [String] = []
        var complete: Double? = 90, partial: Double? = 90
        var macOS: Double? = 2500
        func maxTemperature(complete c: Bool) -> Double? { calls.append("temp complete=\(c)"); return c ? complete : partial }
        func currentRPM(_ i: Int) -> Double? { calls.append("Ac \(i)"); return macOS }
        func targetRPM(_ i: Int) -> Double? { calls.append("Tg \(i)"); return macOS }
        func setManual(_ i: Int, rpm: Double) throws { calls.append("write \(i) \(rpm)") }
        func isManualEngaged(_ i: Int) -> Bool { calls.append("engaged \(i)"); return true }
        func setAuto(_ i: Int, holdUnlock: Bool) throws { calls.append("auto \(i)") }
        func hasFtst() -> Bool { calls.append("ftst"); return true }
        func maxRPM(_ i: Int) -> Double? { calls.append("Mx \(i)"); return nil }
    }
    private final class Clock {
        var t = ContinuousClock.now
        func advance(_ s: Double) { t = t.advanced(by: .seconds(s)) }
    }
    private final class Conn {}
    private let a = Conn()

    private func core(_ clock: Clock) -> FanControlCore {
        FanControlCore(reset: { true }, maxCelsius: { nil }, now: { clock.t })
    }

    private func engage(_ core: FanControlCore, _ fan: FakeFan, rpm: Double, refused: (FanControlCore.Refusal) -> Void = { _ in }) -> FanEngageCode {
        core.engageCode(fan, index: 0, rpm: rpm, holder: ObjectIdentifier(a), arm: {}, refused: refused, failed: { _ in })
    }

    /// A core that tripped as the daemon's tick does it: a pin below macOS's speed, then the cut-off.
    private func tripped(_ fan: FakeFan, _ clock: Clock) -> FanControlCore {
        let c = core(clock)
        XCTAssertEqual(engage(c, fan, rpm: 1200), .engaged)
        XCTAssertTrue(c.temperatureTick(maxCelsius: 96))
        XCTAssertTrue(c.tripLatched)
        c.connectionClosed(ObjectIdentifier(a))
        fan.calls = []
        return c
    }

    /// Latched at 90 C: stay, inside the settle window and after it; one complete read per fire.
    func testLatchedAt90Stays() {
        let fan = FakeFan(), clock = Clock()
        let c = tripped(fan, clock)
        XCTAssertFalse(c.idleMayExit(fan, stayed: .zero))
        XCTAssertEqual(fan.calls, ["temp complete=true"])
        clock.advance(FanControlCore.reTakeSettleSeconds + 1)
        XCTAssertFalse(c.idleMayExit(fan, stayed: .seconds(20)))
        XCTAssertEqual(fan.calls, ["temp complete=true", "temp complete=true"], "no speed read, no write")
        XCTAssertTrue(c.tripLatched)
    }

    /// Latched, no reading at all: stay (fail closed).
    func testLatchedUnreadableStays() {
        let fan = FakeFan(), clock = Clock()
        let c = tripped(fan, clock)
        fan.complete = nil; fan.partial = nil
        XCTAssertFalse(c.idleMayExit(fan, stayed: .seconds(10)))
        XCTAssertTrue(c.tripLatched)
    }

    /// Latched, the sensors that read are at 50 C but one failed: the gate's re-arm wants a complete reading, so stay.
    func testLatchedIncompleteCoolReadingStays() {
        let fan = FakeFan(), clock = Clock()
        let c = tripped(fan, clock)
        fan.complete = nil; fan.partial = 50
        XCTAssertFalse(c.idleMayExit(fan, stayed: .seconds(10)))
        XCTAssertTrue(c.tripLatched)
    }

    /// Latched, a complete 70 C: the latch clears and the helper exits as today. 80.0 itself is not below re-arm.
    func testLatchedCompleteCoolReadingClearsAndExits() {
        let fan = FakeFan(), clock = Clock()
        let c = tripped(fan, clock)
        fan.complete = 80
        XCTAssertFalse(c.idleMayExit(fan, stayed: .seconds(10)))
        XCTAssertTrue(c.tripLatched)
        fan.complete = 70
        XCTAssertTrue(c.idleMayExit(fan, stayed: .seconds(20)))
        XCTAssertFalse(c.tripLatched)
        XCTAssertTrue(c.lastRefusal == nil)
    }

    /// Never tripped: exit at once, nothing read, whatever the time (the gate-off row: nothing changes).
    func testUnlatchedExitsAtOnceWithNoRead() {
        let fan = FakeFan(), clock = Clock()
        let c = core(clock)
        XCTAssertTrue(c.idleMayExit(fan, stayed: .zero))
        XCTAssertTrue(c.idleMayExit(nil, stayed: .zero))
        XCTAssertEqual(fan.calls, [])
        XCTAssertFalse(c.tripLatched)
    }

    /// The bound: a sensor that never clears the latch keeps the helper until `latchedStaySeconds`, then it
    /// exits with the latch still set (the process ends with it; the next start is unlatched, as shipped).
    func testBoundEndsTheStayWithTheLatchKept() {
        let fan = FakeFan(), clock = Clock()
        let c = tripped(fan, clock)
        fan.complete = nil
        let bound = FanControlCore.latchedStaySeconds
        XCTAssertEqual(bound, 30 * 60)
        XCTAssertFalse(c.idleMayExit(fan, stayed: .seconds(bound - 1)))
        XCTAssertTrue(c.idleMayExit(fan, stayed: .seconds(bound)))
        XCTAssertTrue(c.idleMayExit(fan, stayed: .seconds(bound + 60)))
        XCTAssertTrue(c.tripLatched, "the bound ends the process, it does not clear the latch")
        fan.complete = 90
        XCTAssertTrue(c.idleMayExit(fan, stayed: .seconds(bound)))
        XCTAssertTrue(c.tripLatched)
    }

    /// The point of the form: after a stay the SAME core answers the relaunched app's re-apply, and a speed below
    /// macOS's is still refused; the fire left the once-per-reason refusal log as a trip leaves it.
    func testAfterAStayTheSameCoreStillRefusesBelowMacOS() {
        let fan = FakeFan(), clock = Clock()
        let c = tripped(fan, clock)
        XCTAssertFalse(c.idleMayExit(fan, stayed: .zero))
        XCTAssertTrue(c.lastRefusal == nil, "the idle fire is not a refused engage")
        var logged: [FanControlCore.Refusal] = []
        XCTAssertEqual(engage(c, fan, rpm: 1200, refused: { logged.append($0) }), .settling)
        XCTAssertEqual(logged, [.settling])
        clock.advance(FanControlCore.reTakeSettleSeconds)
        XCTAssertFalse(c.idleMayExit(fan, stayed: .seconds(10)))
        XCTAssertEqual(engage(c, fan, rpm: 1200, refused: { logged.append($0) }), .belowMacOS)
        XCTAssertEqual(logged, [.settling, .belowMacOS])
        XCTAssertFalse(fan.calls.contains { $0.hasPrefix("write") })
        XCTAssertTrue(c.tripLatched)
    }
}
