import Foundation
import XCTest
@testable import ProsperApp

/// #896 (#822 P4): the "Sized for another window · Fit here" chip (dch ask 1) and the automatic reconnect of a remote
/// attach on a lost link only (dch ask 4). Fakes only: AgentTerminalTests' recorded spawn, fake screen and fake clock;
/// no dch, no socket, no real sleep.
final class AgentTerminalFitReconnectTests: XCTestCase {
    typealias Rig = AgentTerminalTests.Rig

    static let local = AgentSessionKey(dir: "/Users/example/.dch-test", name: "api")
    static let remote = AgentTerminalSpawn.remoteKey(host: "host-a", name: "api")

    @MainActor
    func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// A live attach to `key` at 100x30.
    @MainActor
    func live(_ key: AgentSessionKey) -> Rig {
        let rig = Rig()
        rig.c.request = { AgentTerminalSpawn.attach($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: ["HOME": "/Users/example"]) }
        rig.c.attach(key)
        rig.grid(100, 30)
        XCTAssertEqual(rig.c.phase, .live)
        return rig
    }

    // MARK: ask 1, the parse helper

    @MainActor
    func testPtySizesReadsColsRowsAndClientsAndDropsWhatIsNotAPlainSize() {
        let json = Data(#"""
        [{"name":"api","cols":120,"rows":40,"clients":2},
         {"name":"old"},
         {"name":"half","cols":120,"rows":40},
         {"name":"bool","cols":120,"rows":40,"clients":true},
         {"name":"frac","cols":120.5,"rows":40,"clients":1},
         {"name":"zero","cols":0,"rows":40,"clients":1},
         {"name":"wide","cols":65536,"rows":40,"clients":1},
         {"name":"neg","cols":80,"rows":24,"clients":-1},
         {"name":"huge","cols":80,"rows":24,"clients":1e30},
         {"name":"edge","cols":65535,"rows":1,"clients":0}]
        """#.utf8)
        let p = AgentTranscriptMapping.ptySizes(json)
        XCTAssertEqual(p["api"], AgentSessionPty(cols: 120, rows: 40, clients: 2))
        XCTAssertEqual(p["edge"], AgentSessionPty(cols: 65535, rows: 1, clients: 0))
        XCTAssertEqual(Set(p.keys), ["api", "edge"], "left out, partial, a bool, a fraction, out of range: no entry")
        XCTAssertTrue(AgentTranscriptMapping.ptySizes(Data()).isEmpty)
        XCTAssertTrue(AgentTranscriptMapping.ptySizes(Data("dch: something".utf8)).isEmpty)
    }

    @MainActor
    func testTheListCarriesThePtySizeOnTheSession() {
        let row = Data(#"[{"name":"api","alias":"","activity_epoch":1,"state":"idle","agents":0,"cols":80,"rows":24,"clients":2},{"name":"api-qa","alias":"","activity_epoch":1,"state":"idle","agents":0}]"#.utf8)
        let s = AgentIsland.list(dirs: ["/Users/example/.dch-test"], run: { _, _ in row })
        XCTAssertEqual(s.first { $0.name == "api" }?.pty, AgentSessionPty(cols: 80, rows: 24, clients: 2))
        XCTAssertTrue(s.first { $0.name == "api-qa" }?.pty == nil, "an older master says nothing: no chip")
    }

    // MARK: ask 1, the chip

    @MainActor
    func testChipHiddenWhenTheSessionIsAtThisPanesSize() {
        let rig = live(Self.local)
        rig.c.sessionPty = AgentSessionPty(cols: 100, rows: 30, clients: 2)
        XCTAssertFalse(rig.c.sizedElsewhere)
    }

    @MainActor
    func testChipHiddenWithOneClient() {
        let rig = live(Self.local)
        rig.c.sessionPty = AgentSessionPty(cols: 80, rows: 24, clients: 1)
        XCTAssertFalse(rig.c.sizedElsewhere, "only this pane is attached: it will take its size itself")
        rig.c.sessionPty = nil
        XCTAssertFalse(rig.c.sizedElsewhere, "dch left the size out")
    }

    @MainActor
    func testChipShownWhenTheSizeDiffersWithTwoClients() {
        let rig = live(Self.local)
        rig.c.sessionPty = AgentSessionPty(cols: 80, rows: 24, clients: 2)
        XCTAssertTrue(rig.c.sizedElsewhere)
        rig.c.sessionPty = AgentSessionPty(cols: 100, rows: 24, clients: 2)
        XCTAssertTrue(rig.c.sizedElsewhere, "rows alone differ")
        rig.c.sessionPty = AgentSessionPty(cols: 80, rows: 30, clients: 3)
        XCTAssertTrue(rig.c.sizedElsewhere, "cols alone differ")
    }

    @MainActor
    func testChipHiddenOnARemotePaneAndWithNothingAttached() {
        let rig = live(Self.remote)
        rig.c.sessionPty = AgentSessionPty(cols: 80, rows: 24, clients: 2)
        XCTAssertFalse(rig.c.sizedElsewhere, "a remote row's size is another machine's")
        let l = live(Self.local)
        l.c.sessionPty = AgentSessionPty(cols: 80, rows: 24, clients: 2)
        l.c.attach(nil)
        XCTAssertFalse(l.c.sizedElsewhere)
        XCTAssertTrue(l.c.sessionPty == nil, "a new attach drops the last session's size")
    }

    @MainActor
    func testFitHereSendsThePanesSizeOnceByTheFocusPath() throws {
        let rig = live(Self.local)
        let child = try XCTUnwrap(rig.child)
        rig.c.sessionPty = AgentSessionPty(cols: 80, rows: 24, clients: 2)
        rig.c.fitHere()
        rig.c.fitHere()
        XCTAssertEqual(child.redraws, 1, "one jiggle: the dch client re-sends this pane's winsize")
        XCTAssertEqual(child.resizes, [], "no new path: a same-size TIOCSWINSZ would send nothing")
        XCTAssertFalse(rig.c.sizedElsewhere, "hidden until the next list")
    }

    @MainActor
    func testFitHereDoesNothingWithoutTheChip() throws {
        let rig = live(Self.local)
        let child = try XCTUnwrap(rig.child)
        rig.c.sessionPty = AgentSessionPty(cols: 100, rows: 30, clients: 2)
        rig.c.fitHere()
        XCTAssertEqual(child.redraws, 0)
    }

    // MARK: ask 4, reconnect on "lost" only

    @MainActor
    func testRemoteLostLinkReconnectsAfterItsBackoff() {
        let rig = live(Self.remote)
        rig.ios.last?.exit(1)
        spin()
        XCTAssertEqual(rig.c.phase, .failed("Lost the connection to host-a"))
        XCTAssertTrue(rig.c.reconnecting)
        rig.clock.advance(0.99)
        XCTAssertEqual(rig.requests.count, 1, "not before the first delay")
        rig.clock.advance(0.01)
        XCTAssertEqual(rig.requests.count, 2, "exit 1 is lost: a retry may work")
        XCTAssertEqual(rig.c.phase, .live)
        XCTAssertFalse(rig.c.reconnecting)
    }

    @MainActor
    func testRemoteEndRefusedTakenAndOtherCodesNeverRetry() {
        for (code, phase) in [(0, AgentTerminalController.Phase.ended),
                              (4, .failed("host-a refused the attach")),
                              (5, .detached("Opened on another device")),
                              (2, .failed("Lost the connection to host-a"))] as [(Int32, AgentTerminalController.Phase)] {
            let rig = live(Self.remote)
            rig.ios.last?.exit(code)
            spin()
            XCTAssertEqual(rig.c.phase, phase, "exit \(code)")
            XCTAssertFalse(rig.c.reconnecting, "exit \(code)")
            rig.clock.advance(1000)
            XCTAssertEqual(rig.requests.count, 1, "exit \(code): no retry")
        }
    }

    @MainActor
    func testALocalExit1NeverReconnectsByItself() {
        let rig = live(Self.local)
        rig.ios.last?.exit(1)
        spin()
        XCTAssertEqual(rig.c.phase, .failed("Couldn't attach (dch exited 1)"))
        rig.clock.advance(1000)
        XCTAssertEqual(rig.requests.count, 1)
    }

    @MainActor
    func testReconnectBackoffDoublesAndStopsAtTheCap() {
        let rig = live(Self.remote)
        var at = rig.clock.now
        for delay in AgentTerminalController.reconnectBackoff {
            let n = rig.requests.count
            rig.ios.last?.exit(1)
            spin()
            rig.clock.advance(delay - 0.01)
            XCTAssertEqual(rig.requests.count, n, "still waiting \(delay) s")
            rig.clock.advance(0.01)
            XCTAssertEqual(rig.requests.count, n + 1, "retried after \(delay) s")
            XCTAssertEqual(rig.clock.now - at, delay, accuracy: 0.001)
            at = rig.clock.now
        }
        XCTAssertEqual(AgentTerminalController.reconnectBackoff, [1, 2, 4, 8, 16])
        XCTAssertEqual(rig.requests.count, 6)
        rig.ios.last?.exit(1)
        spin()
        XCTAssertFalse(rig.c.reconnecting, "the cap is spent")
        rig.clock.advance(10_000)
        XCTAssertEqual(rig.requests.count, 6)
        XCTAssertEqual(rig.c.phase, .failed("Lost the connection to host-a"))
        rig.c.retry()   // the card's Reconnect starts the backoff over
        rig.ios.last?.exit(1)
        spin()
        rig.clock.advance(1)
        XCTAssertEqual(rig.requests.count, 8)
    }

    @MainActor
    func testASettledAttachStartsTheBackoffOver() {
        let rig = live(Self.remote)
        rig.ios.last?.exit(1)
        spin()
        rig.clock.advance(1)   // first retry
        rig.ios.last?.exit(1)
        spin()
        rig.clock.advance(2)   // second, after 2 s
        XCTAssertEqual(rig.requests.count, 3)
        rig.clock.advance(AgentTerminalController.reconnectSettled)
        rig.ios.last?.exit(1)
        spin()
        rig.clock.advance(1)
        XCTAssertEqual(rig.requests.count, 4, "up 30 s: the next delay is the first again")
    }

    @MainActor
    func testReconnectOrADetachDuringTheWaitDropsTheScheduledRetry() {
        let rig = live(Self.remote)
        rig.ios.last?.exit(1)
        spin()
        rig.c.retry()
        XCTAssertEqual(rig.requests.count, 2, "Reconnect: now")
        rig.ios.last?.exit(4)   // that attach refused: the retry scheduled before it must not run over the refusal
        spin()
        rig.clock.advance(1000)
        XCTAssertEqual(rig.requests.count, 2, "the scheduled one is dropped")
        XCTAssertEqual(rig.c.phase, .failed("host-a refused the attach"))
        rig.c.retry()
        XCTAssertEqual(rig.requests.count, 3)
        rig.ios.last?.exit(1)
        spin()
        rig.c.attach(nil)
        XCTAssertFalse(rig.c.reconnecting)
        rig.clock.advance(1000)
        XCTAssertEqual(rig.requests.count, 3, "detached: nothing reconnects")
    }
}
