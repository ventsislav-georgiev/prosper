import XCTest
@testable import ProsperApp

/// Covers the pure keep-awake decision: hold while a client is attached or a
/// detached session is still producing output, and release only after a full grace
/// of consecutive idle ticks. This is the logic that decides whether a
/// remotely-woken Mac stays awake, so its edges (grace boundary, reset on activity)
/// are worth pinning.
final class KeepAwakePolicyTests: XCTestCase {

    private func step(_ client: Bool, _ active: Bool, _ idle: Int) -> KeepAwakePolicy.Step {
        KeepAwakePolicy.step(clientConnected: client, sessionActive: active, idleTicks: idle)
    }

    func testClientConnectedHoldsAndResetsIdle() {
        // Even mid-grace, a connected client resets the count and holds.
        XCTAssertEqual(step(true, false, 5),
                       KeepAwakePolicy.Step(hold: true, release: false, idleTicks: 0))
    }

    func testActiveSessionHoldsWithoutClient() {
        XCTAssertEqual(step(false, true, 4),
                       KeepAwakePolicy.Step(hold: true, release: false, idleTicks: 0))
    }

    func testIdleAccumulatesButHoldsThroughGrace() {
        // Ticks 1..graceTicks-1 keep holding (still in grace), incrementing the count.
        var idle = 0
        for expected in 1..<KeepAwakePolicy.graceTicks {
            let s = step(false, false, idle)
            XCTAssertTrue(s.hold, "tick \(expected) should still hold")
            XCTAssertFalse(s.release)
            XCTAssertEqual(s.idleTicks, expected)
            idle = s.idleTicks
        }
    }

    func testReleasesExactlyAtGraceBoundary() {
        // The graceTicks-th consecutive idle tick releases — not before, not after.
        let last = step(false, false, KeepAwakePolicy.graceTicks - 1)
        XCTAssertTrue(last.release)
        XCTAssertFalse(last.hold)
        XCTAssertEqual(last.idleTicks, KeepAwakePolicy.graceTicks)
    }

    func testActivityDuringGraceResetsCountNoRelease() {
        // A late burst of output one tick before release pulls us back from the edge.
        let s = step(false, true, KeepAwakePolicy.graceTicks - 1)
        XCTAssertFalse(s.release)
        XCTAssertTrue(s.hold)
        XCTAssertEqual(s.idleTicks, 0)
    }

    func testFullCycleConnectWorkDisconnectIdleRelease() {
        // Connect → hold. Disconnect but session active → hold. Session goes quiet →
        // count up over the grace → release once.
        var idle = step(true, false, 0).idleTicks                 // connected
        idle = step(false, true, idle).idleTicks                  // detached, working
        XCTAssertEqual(idle, 0)
        var releases = 0
        for _ in 0..<KeepAwakePolicy.graceTicks {
            let s = step(false, false, idle)
            idle = s.idleTicks
            if s.release { releases += 1 }
        }
        XCTAssertEqual(releases, 1, "should release exactly once at the grace boundary")
    }

    /// Hot-ish path budget: `step` runs every tick for the life of every remote
    /// session and must be branch-only — no allocation, no clock, no I/O. 2M calls
    /// under 600ms on a DEBUG build (~300ns ceiling, in line with LidHelperCore's
    /// own transition budget) is a regression guard — an accidental heap escape
    /// would land 10-100× over. Release is several times faster, and the call only
    /// fires once per tick anyway.
    func testStepThroughputUnderBudget() {
        let iterations = 2_000_000
        var sink = 0
        let start = DispatchTime.now()
        for i in 0..<iterations {
            let s = step(i & 1 == 0, i & 2 == 0, i & 7)
            sink &+= s.idleTicks
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(ms, 600, "KeepAwakePolicy.step too slow: \(ms)ms for \(iterations) (sink \(sink))")
    }
}
