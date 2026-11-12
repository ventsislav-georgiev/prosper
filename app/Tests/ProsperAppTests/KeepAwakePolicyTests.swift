import Network
import ProsperHelperProtocol
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

    // MARK: - watch mode (post-release: re-hold on resumed activity)

    func testWatchReholdsWhenSessionResumesOutput() {
        // The mid-build quiet-phase case: hold released after the grace, then the
        // detached session prints again → must re-acquire, not sleep mid-work.
        XCTAssertEqual(KeepAwakePolicy.watch(clientConnected: false, sessionActive: true,
                                             sessionsExist: true), .rehold)
    }

    func testTickActivityWindowCoversLeeway() {
        // A tick up to `tickLeewaySeconds` late must still see activity from right after the previous tick.
        XCTAssertEqual(KeepAwakePolicy.tickActivityWindowSeconds,
                       KeepAwakePolicy.activeWindowSeconds + KeepAwakePolicy.tickLeewaySeconds)
    }

    func testWatchReholdsOnClientReconnect() {
        XCTAssertEqual(KeepAwakePolicy.watch(clientConnected: true, sessionActive: false,
                                             sessionsExist: true), .rehold)
    }

    func testWatchKeepsTickingWhileQuietSessionsExist() {
        XCTAssertEqual(KeepAwakePolicy.watch(clientConnected: false, sessionActive: false,
                                             sessionsExist: true), .keepWatching)
    }

    func testWatchStopsWhenNothingLeftToWatch() {
        XCTAssertEqual(KeepAwakePolicy.watch(clientConnected: false, sessionActive: false,
                                             sessionsExist: false), .stop)
    }

    // MARK: - #767 J15: a confirmed hold beats every 30 s, not every tick

    /// Sends over `ticks` holding ticks after a send, the way `tick()` drives `beat`.
    private func sends(confirmed: Bool, ticks: Int) -> Int {
        var since = 0, n = 0
        for _ in 0..<ticks {
            let b = KeepAwakePolicy.beat(confirmed: confirmed, ticksSinceBeat: since)
            since = b.ticksSinceBeat
            if b.send { n += 1 }
        }
        return n
    }

    func testConfirmedHoldBeatsEveryThirdTick() {
        XCTAssertEqual(sends(confirmed: true, ticks: 2), 0)
        XCTAssertEqual(sends(confirmed: true, ticks: 3), 1)
        XCTAssertEqual(sends(confirmed: true, ticks: 12), 4)
        XCTAssertEqual(KeepAwakePolicy.heartbeatSeconds, 30)
    }

    func testUnconfirmedHoldBeatsEveryTick() {
        // Lid open, failed XPC or a restarted daemon: re-assert within one tick.
        XCTAssertEqual(sends(confirmed: false, ticks: 4), 4)
    }

    func testTwoMissedBeatsStillLandInsideTheDaemonTTL() {
        // Real slack, not equality: the TTL is armed at a beat; with the next two
        // beats lost, the third must still land before it expires, even with every
        // tick of the way at its full leeway — and with seconds to spare for the
        // XPC hop. The TTL itself stays 120 s, so a dead Prosper still lets the Mac
        // sleep within 2 min (old apps beat at 10 s: also inside it).
        let worstBeat = KeepAwakePolicy.heartbeatSeconds
            + KeepAwakePolicy.heartbeatTicks * KeepAwakePolicy.tickLeewaySeconds
        let thirdBeat = 3 * worstBeat
        XCTAssertLessThan(thirdBeat + 10, LidHelperCore.remoteHoldTTLSeconds,
                          "third beat at \(thirdBeat) s leaves under 10 s of slack to the TTL")
        XCTAssertEqual(LidHelperCore.remoteHoldTTLSeconds, 120)
    }

    // MARK: - #767 J17: TCP keepalive idle 120 s

    func testKeepaliveIdleIs120AndDeadLinkSeenWithinThreeMinutes() {
        let tcp = NWProtocolTCP.Options()
        DchSessionServer.configureTCP(tcp)
        XCTAssertTrue(tcp.enableKeepalive)
        XCTAssertEqual(tcp.keepaliveIdle, 120)
        XCTAssertLessThanOrEqual(tcp.keepaliveIdle + tcp.keepaliveInterval * tcp.keepaliveCount, 180)
    }

    // MARK: - #888 TCP no-delay on the session server

    private func assertSessionTCP(_ tcp: NWProtocolTCP.Options?, file: StaticString = #filePath, line: UInt = #line) {
        guard let tcp else { return XCTFail("no TCP options", file: file, line: line) }
        XCTAssertTrue(tcp.noDelay, "Nagle on: every small frame waits a round trip", file: file, line: line)
        XCTAssertTrue(tcp.enableKeepalive, file: file, line: line)
        XCTAssertEqual(tcp.keepaliveIdle, 120, file: file, line: line)
        XCTAssertEqual(tcp.keepaliveInterval, 10, file: file, line: line)
        XCTAssertEqual(tcp.keepaliveCount, 4, file: file, line: line)
    }

    func testConfigureTCPSetsNoDelayAndKeepalive() {
        let tcp = NWProtocolTCP.Options()
        DchSessionServer.configureTCP(tcp)
        assertSessionTCP(tcp)
    }

    /// The parameters makeListener really uses; no listener is built, nothing binds.
    func testListenerParametersCarryNoDelayAndKeepalive() {
        let params = DchSessionServer.listenerParameters(host: "127.0.0.1")
        assertSessionTCP(params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
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
