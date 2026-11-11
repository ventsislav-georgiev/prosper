import AppKit
import Combine
import CoreImage
import GhosttyTerminal
import IOSurface
import SwiftUI
import XCTest
@testable import ProsperApp

/// #822 P1: the Agent Sessions window's terminal. The controller runs on fakes (a recorded spawn,
/// a fake screen, an injected clock); the view is a real libghostty surface in a window that is
/// never ordered in. No dch runs: a pty test runs /bin/cat. Keys are built NSEvents handed to the
/// never-shown window (no CGEventPost), and every clipboard is a private named pasteboard.
final class AgentTerminalTests: XCTestCase {

    static let key = AgentSessionKey(dir: "/Users/example/.dch-test", name: "alpha")

    // MARK: Fakes

    final class FakeChild: AgentTerminalChild, @unchecked Sendable {
        private let lock = NSLock()
        private var _written: [UInt8] = []
        private var _resizes: [[Int]] = []
        private var _redraws = 0, _terminated = 0, _ran = 0, inside = 0, _overlapped = false
        /// Two writes were inside write() at once (the pty write path must be serial).
        var overlapped: Bool { lock.withLock { _overlapped } }
        var written: [UInt8] { lock.withLock { _written } }
        var resizes: [[Int]] { lock.withLock { _resizes } }
        var redraws: Int { lock.withLock { _redraws } }
        var terminated: Int { lock.withLock { _terminated } }
        var ran: Int { lock.withLock { _ran } }
        func run() { lock.withLock { _ran += 1 } }
        func write(_ bytes: [UInt8]) {
            lock.withLock { inside += 1; if inside > 1 { _overlapped = true } }
            usleep(20)
            lock.withLock { _written += bytes; inside -= 1 }
        }
        func resize(cols: Int, rows: Int) { lock.withLock { _resizes.append([cols, rows]) } }
        func redraw() { lock.withLock { _redraws += 1 } }
        func terminate() { lock.withLock { _terminated += 1 } }
        func clear() { lock.withLock { _written = [] } }
    }

    @MainActor
    final class FakeScreen: AgentTerminalScreen {
        let events: AgentTerminalScreenEvents
        var fed: [UInt8] = []
        init(_ events: AgentTerminalScreenEvents) { self.events = events }
        func feed(_ bytes: [UInt8]) { fed += bytes }
    }

    /// Delays run only when the test advances time.
    @MainActor
    final class Clock {
        var now: TimeInterval = 0
        private var seq = 0
        private var pending: [(at: TimeInterval, seq: Int, work: @MainActor () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            pending.append((now + delay, seq, work))
            seq += 1
        }
        func advance(_ by: TimeInterval) {
            let end = now + by
            while let next = pending.filter({ $0.at <= end }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
                pending.removeAll { $0.seq == next.seq }
                now = next.at
                next.work()
            }
            now = end
        }
    }

    @MainActor
    final class Rig {
        let c = AgentTerminalController()
        let clock = Clock()
        var requests: [AgentTerminalSpawn] = []
        var children: [FakeChild] = []
        var ios: [AgentTerminalIO] = []
        var screens: [FakeScreen] = []
        var live = true
        var opened: [URL] = []
        var refuse: Error?
        /// A new screen reports the view's grid as its own at once, as libghostty's surface does from
        /// its IO thread once it runs at that grid. Off for the tests of that hand-off.
        var screenReports = true
        /// INFO-4: the session's socket on disk.
        var socket = true
        /// OQ-66: what an OSC 52 write sees. Nothing is viewed until a test says so.
        var selected = false
        var window: AgentTerminalWindowState?
        var writes = true

        /// Selected, in an ordered-in, unminimized, visible window: a write may land.
        func view() {
            selected = true
            window = AgentTerminalWindowState(onScreen: true, miniaturized: false, occlusionVisible: true)
        }

        init(version: [Int]? = [1, 40, 0]) {
            c.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: ["HOME": "/Users/example"]) }
            c.spawn = { [unowned self] req, io in
                if let refuse { throw refuse }
                requests.append(req)
                ios.append(io)
                let child = FakeChild()
                children.append(child)
                return child
            }
            c.makeScreen = { [unowned self] in
                let s = FakeScreen($0)
                screens.append(s)
                if screenReports, let g = c.grid { c.gridChanged(cols: g.cols, rows: g.rows, generation: c.generation) }
                return s
            }
            c.after = { [clock] in clock.schedule($0, $1) }
            c.isLive = { [unowned self] _ in live }
            c.openURL = { [unowned self] in opened.append($0) }
            c.clientVersion = { _ in version }
            c.socketExists = { [unowned self] _ in socket }
            c.isSelected = { [unowned self] _ in selected }
            c.windowState = { [unowned self] _ in window }
            c.clipboardWrites = { [unowned self] in writes }
        }

        var child: FakeChild? { children.last }
        var screen: FakeScreen? { screens.last }

        /// The view lays out at cols x rows and the screen's parser runs at it: the client starts.
        func grid(_ cols: Int, _ rows: Int) {
            c.gridChanged(cols: cols, rows: rows)
            c.gridChanged(cols: cols, rows: rows, generation: c.generation)
        }
    }

    @MainActor
    func spin(_ t: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    @MainActor
    func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
              _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > end { return XCTFail("timed out: \(what)", file: file, line: line) }
            spin(0.01)
        }
    }

    // MARK: Spawn

    func testLocalAttachRunsDchAttachOnlyInTheSessionsSocketDir() throws {
        let r = AgentTerminalSpawn.local(Self.key, cols: 100, rows: 30, dch: "/opt/example/bin/dch",
                                         env: ["DCH_SOCKET_DIR": "/Users/example/.other", "HOME": "/Users/example"])
        XCTAssertEqual(r.exe, "/opt/example/bin/dch")
        XCTAssertEqual(r.args, ["-E", "-a", "alpha"], "attach only, no detach key: never creates or resurrects")
        XCTAssertEqual(r.env["DCH_SOCKET_DIR"], "/Users/example/.dch-test", "the session's own dir wins")
        XCTAssertEqual([r.cols, r.rows], [100, 30])
        let real = AgentTerminalSpawn.local(Self.key, cols: 80, rows: 24, dch: "/opt/example/bin/dch")
        XCTAssertNil(real.env["DCH_SESSION"], "a Prosper started inside dch still attaches")
        XCTAssertEqual(real.env["TERM"], "xterm-256color")
        XCTAssertEqual(real.env["DCH_SOCKET_DIR"], Self.key.dir)
        // Tests never run a real dch: the app's spawn refuses under XCTest.
        let io = AgentTerminalIO(output: { _ in }, exit: { _ in })
        XCTAssertThrowsError(try AgentTerminalController.realSpawn(real, io))
    }

    @MainActor
    func testAttachWaitsForTheGridThenRunsOneClient() {
        let rig = Rig()
        let c = rig.c
        c.attach(Self.key)
        XCTAssertEqual(c.phase, .attaching)
        XCTAssertNotNil(c.screen)
        XCTAssertTrue(rig.requests.isEmpty, "no client before the grid is known")
        c.gridChanged(cols: 0, rows: 24)
        XCTAssertTrue(rig.requests.isEmpty, "an empty grid is no grid")
        rig.grid(100, 30)
        XCTAssertEqual(rig.requests.count, 1)
        XCTAssertEqual(rig.requests.first.map { [$0.cols, $0.rows] }, [100, 30], "spawned at the view's grid")
        XCTAssertEqual(rig.child?.ran, 1)
        XCTAssertEqual(c.phase, .live)
        c.attach(Self.key)
        XCTAssertEqual(rig.requests.count, 1, "the same session again changes nothing")
        XCTAssertEqual(rig.child?.terminated, 0)
        c.attach(nil)
        XCTAssertEqual(rig.child?.terminated, 1, "detach ends the client")
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNil(c.screen)
        // The grid is the view's: a later attach starts at once, on a fresh screen.
        c.attach(AgentSessionKey(dir: Self.key.dir, name: "beta"))
        XCTAssertEqual(rig.requests.count, 2)
        XCTAssertEqual(rig.requests.last?.args, ["-E", "-a", "beta"])
        XCTAssertEqual(rig.screens.count, 2, "one screen per attach")
        // A resize from the old screen is stale.
        rig.screens[0].events.resize(40, 10)
        spin()
        XCTAssertEqual(c.grid.map { [$0.cols, $0.rows] }, [100, 30])
        c.detach()
    }

    @MainActor
    func testOutputReachesTheScreenOnMainAndRevealsIt() {
        let rig = Rig()
        let c = rig.c
        c.attach(Self.key)
        rig.grid(80, 24)
        XCTAssertFalse(c.revealed, "background only until bytes arrive")
        let io = rig.ios[0]
        let done = expectation(description: "pumped")
        DispatchQueue.global().async {
            for i in 0..<100 { io.output(Array("line \(i)\r\n".utf8)) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        wait("fed") { rig.screen?.fed.count == (0..<100).map { "line \($0)\r\n".utf8.count }.reduce(0, +) }
        XCTAssertEqual(String(decoding: rig.screen?.fed ?? [], as: UTF8.self),
                       (0..<100).map { "line \($0)\r\n" }.joined(), "in order, nothing lost or doubled")
        XCTAssertTrue(c.revealed)
        // Nothing fed: revealed anyway after 300 ms (no blank-forever pane).
        let rig2 = Rig()
        rig2.c.attach(Self.key)
        XCTAssertFalse(rig2.c.revealed)
        rig2.clock.advance(0.29)
        XCTAssertFalse(rig2.c.revealed)
        rig2.clock.advance(0.02)
        XCTAssertTrue(rig2.c.revealed)
        c.detach()
        rig2.c.detach()
    }

    func testInboxBlocksThePumpAtItsCapUntilMainDrains() {
        let box = AgentTerminalInbox()
        XCTAssertTrue(box.put([1]), "the first put schedules a drain")
        XCTAssertFalse(box.put([2]), "one drain in flight")
        XCTAssertEqual(box.take(), [1, 2])
        XCTAssertTrue(box.put(Array(repeating: 0, count: AgentTerminalInbox.cap)), "taken: the next put schedules again")
        let returned = NSLock()
        nonisolated(unsafe) var back = false
        let started = expectation(description: "started")
        DispatchQueue.global().async {
            started.fulfill()
            _ = box.put([9])
            returned.withLock { back = true }
        }
        wait(for: [started], timeout: 5)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(returned.withLock { back }, "a full inbox stops the pump (the pty is not read)")
        XCTAssertEqual(box.take().count, AgentTerminalInbox.cap)
        let end = Date().addingTimeInterval(5)
        while !returned.withLock({ back }), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(returned.withLock { back }, "a drain lets it go on")
        XCTAssertEqual(box.take(), [9])
        // close wakes a waiting pump for good.
        _ = box.put(Array(repeating: 0, count: AgentTerminalInbox.cap))
        let closed = expectation(description: "closed")
        DispatchQueue.global().async {
            XCTAssertFalse(box.put([1]), "a closed inbox takes nothing")
            closed.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        box.close()
        wait(for: [closed], timeout: 5)
        XCTAssertEqual(box.count, 0)
    }

    @MainActor
    func testABackloggedRendererHoldsTheFeedUntilItCatchesUp() {
        let rig = Rig()
        let c = rig.c
        c.attach(Self.key)
        rig.grid(80, 24)
        let screen = try! XCTUnwrap(rig.screen)
        screen.events.backlog(true)
        spin()
        rig.ios[0].output(Array("held".utf8))
        spin()
        XCTAssertEqual(screen.fed, [], "past the high water mark nothing is fed")
        rig.ios[0].output(Array(" more".utf8))
        spin()
        XCTAssertEqual(screen.fed, [])
        screen.events.backlog(false)
        spin()
        XCTAssertEqual(String(decoding: screen.fed, as: UTF8.self), "held more", "the low water mark drains what waited")
        c.detach()
    }

    @MainActor
    func testResizeIsDebouncedAndALiveResizeSendsOnceAtItsEnd() {
        let rig = Rig()
        let c = rig.c
        c.attach(Self.key)
        rig.grid(80, 24)
        let child = try! XCTUnwrap(rig.child)
        c.gridChanged(cols: 81, rows: 24)
        c.gridChanged(cols: 82, rows: 25)
        rig.clock.advance(0.1)
        c.gridChanged(cols: 90, rows: 30)
        rig.clock.advance(0.14)
        XCTAssertEqual(child.resizes, [], "150 ms trailing debounce")
        rig.clock.advance(0.02)
        XCTAssertEqual(child.resizes, [[90, 30]], "one WINCH, the last size")
        c.gridChanged(cols: 90, rows: 30)
        rig.clock.advance(1)
        XCTAssertEqual(child.resizes, [[90, 30]], "the same size again sends nothing")
        // A live resize: nothing until it ends, then exactly one.
        c.liveResizeStarted()
        for w in 91...120 { c.gridChanged(cols: w, rows: 30) }
        rig.clock.advance(1)
        XCTAssertEqual(child.resizes, [[90, 30]])
        c.liveResizeEnded()
        XCTAssertEqual(child.resizes, [[90, 30], [120, 30]])
        rig.clock.advance(1)
        XCTAssertEqual(child.resizes.count, 2, "no trailing resize after the end")
        // Back to the size the pty has: nothing.
        c.gridChanged(cols: 121, rows: 30)
        c.gridChanged(cols: 120, rows: 30)
        rig.clock.advance(1)
        XCTAssertEqual(child.resizes.count, 2)
        c.detach()
    }

    /// #844: dch adopts the attaching client's size and replays its screen drawn for it (attach.c:719-729,
    /// master.c:3358-3367). So the client starts only once the screen parses at the view's grid, a late
    /// report of the surface's creation grid never sizes the pty, and nothing more is sent: the attach is
    /// the one WINCH, on the first attach, on a switch and on the way back.
    @MainActor
    func testTheClientStartsOnceTheScreenRunsAtTheViewsGridAndSendsNothingMore() throws {
        let rig = Rig()
        rig.screenReports = false
        let c = rig.c
        c.attach(Self.key)
        let first = try XCTUnwrap(rig.screen)
        c.gridChanged(cols: 101, rows: 26)
        XCTAssertTrue(rig.requests.isEmpty, "the view's grid alone: the surface still parses at its creation grid")
        first.events.resize(46, 16)
        spin()
        XCTAssertTrue(rig.requests.isEmpty, "the creation grid is not the view's")
        first.events.resize(101, 26)
        spin()
        XCTAssertEqual(rig.requests.map { [$0.cols, $0.rows] }, [[101, 26]], "one client, at the pane's grid")
        first.events.resize(46, 16)   // a late report of the creation grid (the operator's 46x16 pane)
        spin()
        rig.ios[0].output(Array("\u{1b}[H\u{1b}[Jalpha replay".utf8))
        spin()
        XCTAssertEqual(String(decoding: first.fed, as: UTF8.self), "\u{1b}[H\u{1b}[Jalpha replay", "the replay reaches the screen")
        rig.clock.advance(1)
        XCTAssertEqual(rig.child?.resizes, [], "the screen's report never sizes the pty")
        XCTAssertEqual(rig.child?.redraws, 0, "no jiggle: the attach was the one WINCH")
        XCTAssertEqual(c.grid.map { [$0.cols, $0.rows] }, [101, 26])
        // A switch: the grid holds, and the new client waits for the new screen.
        c.attach(AgentSessionKey(dir: Self.key.dir, name: "beta"))
        XCTAssertEqual(rig.children[0].terminated, 1)
        let second = try XCTUnwrap(rig.screen)
        XCTAssertEqual(rig.requests.count, 1, "the new surface has not reported yet")
        c.gridChanged(cols: 101, rows: 26)   // the new surface lays out first, at the same grid
        XCTAssertEqual(rig.requests.count, 1, "the old screen's grid is no word on the new one")
        first.events.resize(101, 26)
        spin()
        XCTAssertEqual(rig.requests.count, 1, "the old screen's report is stale")
        second.events.resize(46, 16)
        spin()
        XCTAssertEqual(rig.requests.count, 1)
        second.events.resize(101, 26)
        spin()
        XCTAssertEqual(rig.requests.map { [$0.cols, $0.rows] }, [[101, 26], [101, 26]])
        XCTAssertEqual(rig.requests.last?.args, ["-E", "-a", "beta"])
        rig.ios[1].output(Array("beta replay".utf8))
        spin()
        XCTAssertEqual(String(decoding: second.fed, as: UTF8.self), "beta replay")
        // And back: alpha's replay again, on a fresh screen.
        c.attach(Self.key)
        c.gridChanged(cols: 101, rows: 26)
        XCTAssertEqual(rig.requests.count, 2)
        try XCTUnwrap(rig.screen).events.resize(101, 26)
        spin()
        XCTAssertEqual(rig.requests.map(\.args), [["-E", "-a", "alpha"], ["-E", "-a", "beta"], ["-E", "-a", "alpha"]])
        rig.ios[2].output(Array("alpha again".utf8))
        spin()
        XCTAssertEqual(String(decoding: rig.screen?.fed ?? [], as: UTF8.self), "alpha again")
        rig.clock.advance(1)
        XCTAssertEqual(rig.children.map(\.resizes), [[], [], []], "no duplicate sends")
        XCTAssertEqual(rig.children.map(\.redraws), [0, 0, 0])
        // A live resize still sends once, at its end.
        c.liveResizeStarted()
        for w in 102...130 { c.gridChanged(cols: w, rows: 30) }
        rig.clock.advance(1)
        XCTAssertEqual(rig.child?.resizes, [])
        c.liveResizeEnded()
        rig.clock.advance(1)
        XCTAssertEqual(rig.child?.resizes, [[130, 30]])
        c.detach()
    }

    /// The screen's report is a wait, not a gate: one that never comes or never matches the view's grid
    /// starts the client at the view's grid 500 ms after that screen began, never sooner, and a stale
    /// screen's timer starts nothing.
    @MainActor
    func testTheClientStartsAnywayWhenTheScreenNeverReportsTheViewsGrid() throws {
        let rig = Rig()
        rig.screenReports = false
        let c = rig.c
        c.attach(Self.key)
        c.gridChanged(cols: 101, rows: 26)
        try XCTUnwrap(rig.screen).events.resize(100, 26)   // rounded differently
        spin()
        rig.clock.advance(0.49)
        XCTAssertTrue(rig.requests.isEmpty, "still waiting for the screen")
        rig.clock.advance(0.02)
        XCTAssertEqual(rig.requests.map { [$0.cols, $0.rows] }, [[101, 26]], "started anyway, at the view's grid")
        rig.clock.advance(1)
        XCTAssertEqual(rig.requests.count, 1)
        // A switch 300 ms into the wait: alpha's timer runs out on beta's screen and starts nothing.
        c.attach(AgentSessionKey(dir: Self.key.dir, name: "beta"))
        rig.clock.advance(0.3)
        c.attach(AgentSessionKey(dir: Self.key.dir, name: "gamma"))
        rig.clock.advance(0.25)
        XCTAssertEqual(rig.requests.count, 1, "beta's timer is not gamma's")
        rig.clock.advance(0.3)
        XCTAssertEqual(rig.requests.last?.args, ["-E", "-a", "gamma"])
        XCTAssertEqual(rig.requests.count, 2)
        // No grid yet when the wait runs out: the client starts with the first one.
        let late = Rig()
        late.screenReports = false
        late.c.attach(Self.key)
        late.clock.advance(1)
        XCTAssertTrue(late.requests.isEmpty, "no client before the grid is known")
        late.c.gridChanged(cols: 90, rows: 20)
        XCTAssertEqual(late.requests.map { [$0.cols, $0.rows] }, [[90, 20]])
        c.detach()
        late.c.detach()
    }

    @MainActor
    func testFocusInJigglesOnlyForAClientOlderThan139() {
        for (version, redraws) in [([1, 38, 9], 1), ([1, 39, 0], 0), ([1, 40, 0], 0), (nil, 0)] as [([Int]?, Int)] {
            let rig = Rig(version: version)
            rig.c.attach(Self.key)
            rig.c.focusIn()
            rig.grid(80, 24)
            wait("version probed") { rig.c.focusJiggle == (redraws == 1) }
            spin()
            rig.c.focusIn()
            XCTAssertEqual(rig.child?.redraws, redraws, "client \(String(describing: version))")
            rig.c.detach()
            rig.c.focusIn()
            XCTAssertEqual(rig.child?.redraws, redraws, "nothing attached: nothing to jiggle")
        }
    }

    @MainActor
    func testExitCodesDecideReattachDetachedEndedOrFailed() {
        let rig = Rig()
        let c = rig.c
        c.attach(Self.key)
        rig.grid(80, 24)
        rig.ios[0].output(Array("before".utf8))
        spin()
        XCTAssertTrue(c.revealed)
        // 0 with the session live: one reattach, said once.
        rig.ios[0].exit(0)
        spin()
        XCTAssertEqual(rig.requests.count, 2, "one automatic reattach")
        XCTAssertEqual(c.phase, .live)
        XCTAssertEqual(c.notice, "Reattached")
        XCTAssertFalse(c.revealed, "the reattached screen waits for its first bytes")
        XCTAssertEqual(rig.screens.count, 2, "on a fresh screen")
        rig.clock.advance(2.1)
        XCTAssertNil(c.notice)
        rig.ios[1].exit(0)
        spin()
        XCTAssertEqual(rig.requests.count, 2, "never a second automatic one")
        XCTAssertEqual(c.phase, .detached("Detached elsewhere"))
        XCTAssertTrue(c.revealed, "the card shows over the background")
        c.retry()
        XCTAssertEqual(rig.requests.count, 3, "Reattach")
        XCTAssertEqual(c.phase, .live)
        c.retry()
        XCTAssertEqual(rig.requests.count, 3, "retry only when nothing runs")
        // 4 refused, 5 taken.
        rig.ios[2].exit(4)
        spin()
        XCTAssertEqual(c.phase, .failed("dch refused the attach"))
        c.retry()
        rig.ios[3].exit(5)
        spin()
        XCTAssertEqual(c.phase, .detached("Opened on another device"))
        // 1 with the session live: failed with the code; gone: ended.
        c.retry()
        rig.ios[4].exit(1)
        spin()
        XCTAssertEqual(c.phase, .failed("Couldn't attach (dch exited 1)"))
        rig.live = false
        c.retry()
        rig.ios[5].exit(1)
        spin()
        XCTAssertEqual(c.phase, .ended)
        c.retry()
        rig.ios[6].exit(0)
        spin()
        XCTAssertEqual(c.phase, .ended, "0 with the session gone: it ended")
        XCTAssertEqual(rig.requests.count, 7)
        // A stale exit (an earlier client) changes nothing.
        rig.live = true
        c.retry()
        XCTAssertEqual(c.phase, .live)
        rig.ios[3].exit(4)
        spin()
        XCTAssertEqual(c.phase, .live)
        c.detach()
        rig.ios[7].exit(0)
        spin()
        XCTAssertEqual(c.phase, .idle, "an exit after detach is ignored")
        XCTAssertEqual(rig.requests.count, 8)
    }

    /// QA #681 INFO-4: the session ended, the client exits 0, and the store (polled) still lists it. dch
    /// unlinked the socket before that EOF, so the pane says "Session ended" at once: no reattach, and no
    /// "Couldn't attach" from that reattach failing until the store catches up.
    @MainActor
    func testAnExitZeroWithAStaleIsLiveShowsTheEndAtOnce() {
        let rig = Rig()
        let c = rig.c
        final class Log { var phases: [AgentTerminalController.Phase] = [] }
        let log = Log()
        let watch = c.$phase.sink { log.phases.append($0) }
        defer { watch.cancel() }
        c.attach(Self.key)
        rig.grid(80, 24)
        XCTAssertEqual(c.phase, .live)
        rig.live = true   // stale: the store has not polled since the master went
        rig.socket = false
        rig.ios[0].exit(0)
        spin()
        XCTAssertEqual(c.phase, .ended, "the end shows at once")
        XCTAssertEqual(rig.requests.count, 1, "no reattach to a session that is gone")
        XCTAssertNil(c.notice, "no Reattached")
        XCTAssertTrue(c.revealed)
        XCTAssertFalse(log.phases.contains { if case .failed = $0 { return true } else { return false } },
                       "never Couldn't attach: \(log.phases)")
        // A nonzero exit with the socket gone and the store stale: ended too, not a failure.
        c.attach(nil)
        c.attach(Self.key)
        rig.grid(80, 24)
        rig.socket = false
        rig.ios[1].exit(1)
        spin()
        XCTAssertEqual(c.phase, .ended)
        // The socket still there: an exit 0 is a detach elsewhere, reattached once (as before).
        c.attach(nil)
        c.attach(Self.key)
        rig.grid(80, 24)
        rig.socket = true
        rig.ios[2].exit(0)
        spin()
        XCTAssertEqual(rig.requests.count, 4, "reattached")
        XCTAssertEqual(c.notice, "Reattached")
        c.detach()
    }

    /// QA #709 F1: the real socketExists looks for "<name>.sock" (dch.c "%s/%s.sock"), as the scanner does.
    @MainActor
    func testTheDefaultSocketCheckLooksForTheSockFile() throws {
        let dir = tempDir()
        let key = AgentSessionKey(dir: dir.path, name: "s1")
        let check = AgentTerminalController().socketExists
        XCTAssertFalse(check(key), "nothing on disk")
        try Data().write(to: dir.appendingPathComponent("s1"))
        XCTAssertFalse(check(key), "a bare <name> is not the socket")
        try Data().write(to: dir.appendingPathComponent("s1.sock"))
        XCTAssertTrue(check(key))
    }

    /// QA #709 INFO-4: the real window reader on a window never shown (never ordered or made key).
    @MainActor
    func testTheWindowStateOfAWindowNeverShownIsOffScreenAndNotVisible() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let s = AgentTerminalWindowState(w)
        XCTAssertFalse(s.onScreen)
        XCTAssertFalse(s.miniaturized)
        XCTAssertFalse(s.occlusionVisible)
    }

    @MainActor
    func testASpawnThatFailsSaysWhy() {
        struct Boom: Error, CustomStringConvertible { var description: String { "no such file" } }
        let rig = Rig()
        rig.refuse = Boom()
        rig.c.attach(Self.key)
        rig.grid(80, 24)
        // QA #681 INFO-7: a sentence, never the error's own text.
        XCTAssertEqual(rig.c.phase, .failed("Couldn't open the terminal."))
        rig.refuse = PtyChild.PtyError.forkFailed
        rig.c.retry()
        XCTAssertEqual(rig.c.phase, .failed("Couldn't open the terminal: the Mac couldn't start a new process. Close some apps and retry."))
        rig.refuse = nil
        rig.c.retry()
        XCTAssertEqual(rig.c.phase, .live)
        rig.c.detach()
    }

    func testTheWritePathIsSerialFromAnyThread() {
        let w = AgentTerminalWriter()
        w.send([1])
        w.flush()
        let child = FakeChild()
        w.child = child
        let group = DispatchGroup()
        for t in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<500 { w.send([UInt8(t), UInt8(i % 256), UInt8(t)]) }
            }
        }
        group.wait()
        w.flush()
        let out = child.written
        XCTAssertEqual(out.count, 8 * 500 * 3, "nothing lost, nothing before the child")
        XCTAssertFalse(child.overlapped, "one write at a time")
        for i in stride(from: 0, to: out.count, by: 3) where out[i] != out[i + 2] {
            return XCTFail("writes interleaved at \(i)")
        }
        w.child = nil
        w.send([7])
        w.flush()
        XCTAssertEqual(child.written.count, 8 * 500 * 3, "detached: dropped")
    }

    /// The phone's pasteBytes rules (TerminalMath.swift), as text.
    func testPasteKeepsTextTabsAndLineEndsOnly() {
        let p = AgentTerminalController.pasteText
        XCTAssertEqual(p("plain"), "plain")
        XCTAssertEqual(p("a\u{1b}[201~b"), "a[201~b", "no ESC: a copied end marker cannot close the paste early")
        XCTAssertEqual(p("x\u{9b}201~y"), "x201~y", "C1 CSI dropped")
        XCTAssertEqual(p("\u{85}\u{80}\u{9f}"), "", "every C1 dropped")
        XCTAssertEqual(p("a\tb\nc\r\nd"), "a\tb\nc\r\nd", "TAB, LF, CR kept")
        XCTAssertEqual(p("a\u{0}b\u{7}c\u{8}d\u{3}"), "abcd", "other C0 dropped (no ^C from a paste)")
        XCTAssertEqual(p("del\u{7f}x"), "delx", "DEL dropped (the program reads it as Backspace)")
        XCTAssertEqual(p("Здравей 😀 é"), "Здравей 😀 é")
    }

    @MainActor
    func testLinksOpenOnlyWebAndMail() {
        let rig = Rig()
        for ok in ["https://example.com/a?b=1", "http://example.com", "mailto:someone@example.com", "HTTPS://EXAMPLE.COM"] {
            rig.c.open(ok)
        }
        for no in ["file:///Users/example/.ssh/id_ed25519", "ssh://example.com", "javascript:alert(1)", "x-apple.systempreferences:",
                   "/Users/example", "not a url"] {
            rig.c.open(no)
        }
        XCTAssertEqual(rig.opened.map(\.absoluteString),
                       ["https://example.com/a?b=1", "http://example.com", "mailto:someone@example.com", "HTTPS://EXAMPLE.COM"])
    }

    // MARK: The real view (libghostty), offscreen

    @MainActor
    final class ViewRig {
        let rig: Rig
        let host = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        let window: NSWindow
        let app = AgentTerminalLook.make()
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.term.\(UUID().uuidString)"))

        init(_ rig: Rig = Rig()) {
            _ = NSApplication.shared
            self.rig = rig
            rig.c.makeScreen = { AgentGhosttyScreen($0) }
            host.look = { [app] in app }
            host.pasteboard = { [pb] in pb }
            host.owner = rig.c
            rig.c.view = host
            window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
        }

        var session: InMemoryTerminalSession? { (rig.c.screen as? AgentGhosttyScreen)?.session }

        func start() {
            rig.c.attach(AgentTerminalTests.key)
            host.show(rig.c.screen as? AgentGhosttyScreen)
            window.contentView = host
            window.makeFirstResponder(host)
        }

        func tearDown() {
            rig.c.detach()
            window.contentView = nil
            pb.releaseGlobally()
        }

        /// Program output through the pump path, parsed before this returns.
        func output(_ s: String, _ t: AgentTerminalTests) {
            let io = rig.ios.last!
            io.output(Array(s.utf8))
            t.wait("drained") { !(rig.screen == nil && session == nil) && rig.c.revealed }
            t.spin(0.02)
            session?.waitForPendingOutput()
        }

        func press(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
            NSApp.setValue(e, forKey: "currentEvent")
            defer { NSApp.setValue(nil, forKey: "currentEvent") }
            if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
        }

        /// Bytes the program got since the last take (each write lands through the serial writer).
        func take(_ t: AgentTerminalTests, until want: (([UInt8]) -> Bool)? = nil) -> [UInt8] {
            if let want { t.wait("bytes") { rig.c.writer.flush(); return want(rig.child?.written ?? []) } }
            t.spin(0.1)
            rig.c.writer.flush()
            let out = rig.child?.written ?? []
            rig.child?.clear()
            return out
        }
    }

    @MainActor
    func startedView() -> ViewRig {
        let v = ViewRig()
        v.start()
        wait("the surface reports its grid and the client starts") { v.rig.child != nil }
        return v
    }

    @MainActor
    func testTheViewStartsTheClientAtItsGridAndShowsItsOutput() throws {
        let before = Self.childPids()
        let v = startedView()
        defer { v.tearDown() }
        spin(0.3)
        XCTAssertEqual(Self.childPids().subtracting(before), [], "libghostty ran no shell of its own (in-memory backend only)")
        let req = try XCTUnwrap(v.rig.requests.first)
        XCTAssertGreaterThan(req.cols, 20)
        XCTAssertGreaterThan(req.rows, 5)
        XCTAssertEqual(v.rig.c.grid.map { [$0.cols, $0.rows] }, [req.cols, req.rows])
        v.output("hello from the session\r\n", self)
        XCTAssertTrue(v.session?.readViewportText()?.contains("hello from the session") == true)
        // VoiceOver (row 26): a text area named Terminal whose value is the visible screen.
        XCTAssertEqual(v.host.accessibilityRole(), .textArea)
        XCTAssertEqual(v.host.accessibilityLabel(), "Terminal")
        XCTAssertTrue((v.host.accessibilityValue() as? String)?.contains("hello from the session") == true)
        XCTAssertFalse(v.window.isVisible, "never shown")
        XCTAssertFalse(v.window.isKeyWindow)
    }

    @MainActor
    func testKeysReachTheProgramAndShiftReturnFollowsItsKeyboardMode() {
        let v = startedView()
        defer { v.tearDown() }
        _ = v.take(self)
        v.press(0, "a")
        XCTAssertEqual(v.take(self, until: { !$0.isEmpty }), Array("a".utf8))
        v.press(36, "\r")
        XCTAssertEqual(v.take(self, until: { !$0.isEmpty }), [0x0d], "Return is CR")
        // Shift-Return (Claude Code's new line): legacy modifyOtherKeys form, then CSI u once the
        // program pushes kitty flags (Claude Code 2.1.318 parses both).
        v.press(36, "\r", .shift)
        XCTAssertEqual(String(decoding: v.take(self, until: { !$0.isEmpty }), as: UTF8.self), "\u{1b}[27;2;13~")
        v.output("\u{1b}[>1u", self)
        v.press(36, "\r", .shift)
        XCTAssertEqual(String(decoding: v.take(self, until: { !$0.isEmpty }), as: UTF8.self), "\u{1b}[13;2u")
        v.output("\u{1b}[<u", self)
        // Esc, Tab, ⌃C and the arrows are the program's.
        v.press(53, "\u{1b}")
        XCTAssertEqual(v.take(self, until: { !$0.isEmpty }), [0x1b])
        v.press(48, "\t")
        XCTAssertEqual(v.take(self, until: { !$0.isEmpty }), [0x09])
        v.press(8, "c", .control)
        XCTAssertEqual(v.take(self, until: { !$0.isEmpty }), [0x03])
        v.press(126, "\u{F700}", [.numericPad, .function])
        XCTAssertEqual(String(decoding: v.take(self, until: { !$0.isEmpty }), as: UTF8.self), "\u{1b}[A")
        // Option composes (macos-option-as-alt = false): ⌥e then e is é, not ESC e.
        v.press(14, "é", .option)
        let composed = v.take(self, until: { !$0.isEmpty })
        XCTAssertFalse(composed.first == 0x1b, "Option is not Meta: \(composed)")
    }

    @MainActor
    func testIMECommitsOnlyTheFinalText() throws {
        let v = startedView()
        defer { v.tearDown() }
        _ = v.take(self)
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                 windowNumber: v.window.windowNumber, context: nil, characters: "k",
                                 charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        NSApp.setValue(e, forKey: "currentEvent")
        defer { NSApp.setValue(nil, forKey: "currentEvent") }
        let none = NSRange(location: NSNotFound, length: 0)
        v.host.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        v.host.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        XCTAssertTrue(v.host.hasMarkedText())
        XCTAssertEqual(v.take(self), [], "nothing reaches the program while composing")
        let rect = v.host.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertGreaterThan(rect.height, 0, "the candidate window has a caret rect")
        v.host.insertText("家", replacementRange: none)
        XCTAssertEqual(v.take(self, until: { !$0.isEmpty }), Array("家".utf8))
        XCTAssertFalse(v.host.hasMarkedText())
    }

    @MainActor
    func testPasteIsSanitizedBracketedOnRequestAndAnImageSendsCtrlV() {
        let v = startedView()
        defer { v.tearDown() }
        _ = v.take(self)
        v.pb.clearContents()
        v.pb.setString("ls\u{1b}[201~; echo\u{9b}x", forType: .string)
        v.host.paste(nil)
        XCTAssertEqual(String(decoding: v.take(self, until: { $0.count >= 14 }), as: UTF8.self), "ls[201~; echox")
        v.output("\u{1b}[?2004h", self)
        v.host.paste(nil)
        XCTAssertEqual(String(decoding: v.take(self, until: { $0.count >= 26 }), as: UTF8.self),
                       "\u{1b}[200~ls[201~; echox\u{1b}[201~", "bracketed once the program asked")
        // An image with no text: ^V, so Claude Code reads the Mac clipboard itself.
        v.pb.clearContents()
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        v.pb.setData(png.representation(using: .png, properties: [:]), forType: .png)
        v.host.paste(nil)
        XCTAssertEqual(v.take(self, until: { !$0.isEmpty }), [0x16])
        // Only control characters: nothing at all.
        v.pb.clearContents()
        v.pb.setString("\u{1b}\u{7}", forType: .string)
        v.host.paste(nil)
        XCTAssertEqual(v.take(self), [])
    }

    /// QA #681 INFO-3: while it runs, NSPasteboard.general and a by-name lookup of the general board
    /// answer a private board, so a libghostty or GhosttyTerminal that wrote or read the system pasteboard
    /// itself (its setPasteboardString and its paste reader both name NSPasteboard.general) reaches only
    /// that board. `install` checks the swap took before it returns one; nil means do not run.
    @MainActor
    final class GeneralPasteboardRedirect {
        static let prefix = "eu.illegible.prosper.xctest."
        let board = NSPasteboard(name: NSPasteboard.Name("\(GeneralPasteboardRedirect.prefix)general.\(UUID().uuidString)"))
        private var restore: [(Method, IMP)] = []

        static func install() -> GeneralPasteboardRedirect? {
            let r = GeneralPasteboardRedirect()
            let general = NSSelectorFromString("generalPasteboard"), named = NSSelectorFromString("pasteboardWithName:")
            guard let mGeneral = class_getClassMethod(NSPasteboard.self, general),
                  let mNamed = class_getClassMethod(NSPasteboard.self, named) else { return nil }
            let board = r.board
            typealias Named = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<NSPasteboard>
            let original = unsafeBitCast(method_getImplementation(mNamed), to: Named.self)
            let byName: @convention(block) (AnyObject, NSString) -> Unmanaged<NSPasteboard> = { cls, name in
                name as String == NSPasteboard.Name.general.rawValue ? Unmanaged.passUnretained(board) : original(cls, named, name)
            }
            let generalImp = imp_implementationWithBlock({ (_: AnyObject) in board } as @convention(block) (AnyObject) -> NSPasteboard)
            let namedImp = imp_implementationWithBlock(byName)
            r.restore = [(mGeneral, method_setImplementation(mGeneral, generalImp)),
                         (mNamed, method_setImplementation(mNamed, namedImp))]
            // The swap is in before anything asks for the board; only then is the general board looked up.
            guard method_getImplementation(mGeneral) == generalImp, method_getImplementation(mNamed) == namedImp,
                  NSPasteboard.general.name == board.name, NSPasteboard(name: .general).name == board.name else {
                r.uninstall()
                return nil
            }
            return r
        }

        func uninstall() {
            for (m, imp) in restore { method_setImplementation(m, imp) }
            restore = []
            board.releaseGlobally()
        }
    }

    /// QA #681 INFO-3: real libghostty end to end. An OSC 52 write from the program lands on the seam's
    /// board through the host's confirmation, and a read is denied. It cannot reach the real pasteboard: the
    /// seam's board is a private named one and the general board is redirected (both checked before the
    /// program writes a byte; XCTFail and no run otherwise). The redirect board staying empty proves the
    /// library never wrote it itself.
    @MainActor
    func testCopyAndOSC52GoToThePasteboardSeamAndReadsAreDenied() {
        let v = startedView()
        defer { v.tearDown() }
        let seam = v.host.pasteboard().name.rawValue
        guard seam.hasPrefix(GeneralPasteboardRedirect.prefix), seam != NSPasteboard.Name.general.rawValue else {
            return XCTFail("the host's board must be a private named one, not \(seam)")
        }
        guard let redirect = GeneralPasteboardRedirect.install() else {
            return XCTFail("NSPasteboard.general is not redirected: no OSC 52 runs")
        }
        defer { redirect.uninstall() }
        v.rig.view()   // OQ-66: selected, in a visible window
        v.output("copy me please\r\n", self)
        XCTAssertTrue(v.host.surface?.performBindingAction("select_all") == true)
        v.pb.clearContents()
        v.host.copy(nil)
        XCTAssertTrue(v.pb.string(forType: .string)?.contains("copy me please") == true, "⌘C lands on the seam's board")
        // OSC 52 write: the program's copy lands on the seam's board.
        v.pb.clearContents()
        v.output("\u{1b}]52;c;\(Data("from the program".utf8).base64EncodedString())\u{7}", self)
        wait("osc 52 write") { v.pb.string(forType: .string) == "from the program" }
        XCTAssertNil(redirect.board.string(forType: .string), "libghostty wrote no pasteboard of its own")
        // OSC 52 read: denied, no reply carries either board.
        v.pb.clearContents()
        v.pb.setString("secret", forType: .string)
        redirect.board.clearContents()
        redirect.board.setString("general secret", forType: .string)
        _ = v.take(self)
        v.output("\u{1b}]52;c;?\u{7}", self)
        let reply = String(decoding: v.take(self), as: UTF8.self)
        XCTAssertFalse(reply.contains("52;"), "no clipboard reply: \(reply.debugDescription)")
        XCTAssertFalse(reply.contains(Data("secret".utf8).base64EncodedString()))
        XCTAssertFalse(reply.contains(Data("general secret".utf8).base64EncodedString()))
        // OQ-66 end to end: the same write while the session is not selected lands nowhere.
        v.rig.selected = false
        v.pb.clearContents()
        redirect.board.clearContents()
        v.output("\u{1b}]52;c;\(Data("unseen".utf8).base64EncodedString())\u{7}", self)
        spin(0.3)
        XCTAssertNil(v.pb.string(forType: .string), "not viewed: denied")
        XCTAssertNil(redirect.board.string(forType: .string))
    }

    /// A clipboard request as libghostty hands it over, recording the answers.
    @MainActor
    final class ClipRequest: AgentClipboardRequest {
        let kind: TerminalClipboardRequestKind
        let contents: String
        var answers: [Bool] = []
        init(_ kind: TerminalClipboardRequestKind, _ contents: String) { self.kind = kind; self.contents = contents }
        func respond(allow: Bool) { answers.append(allow) }
    }

    /// Every clipboard request libghostty asks about is answered no: an OSC 52 write lands on the
    /// Pasteboard seam's board only, a read or a paste request gets nothing. The request is a recorder,
    /// so nothing reaches libghostty, whose own write (on a yes) would go to NSPasteboard.general.
    @MainActor
    func testClipboardRequestsAreDeniedAndAWriteLandsOnlyOnTheSeam() {
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.term.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let rig = Rig()
        rig.c.attach(Self.key)
        rig.grid(80, 24)
        rig.view()
        defer { rig.c.detach() }
        let host = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.pasteboard = { [pb] in pb }
        host.owner = rig.c
        let write = ClipRequest(.osc52Write, "from the program")
        host.confirmClipboard(write)
        XCTAssertEqual(write.answers, [false], "the library is told no, so it never writes the system pasteboard")
        XCTAssertEqual(pb.string(forType: .string), "from the program", "the write landed on the seam's board")
        pb.clearContents()
        pb.setString("secret", forType: .string)
        // INFO-6: a paste-protection request (.paste) is denied too; Prosper's own paste never raises one.
        for kind: TerminalClipboardRequestKind in [.osc52Read, .paste] {
            let r = ClipRequest(kind, "secret")
            host.confirmClipboard(r)
            XCTAssertEqual(r.answers, [false], "\(kind) denied")
        }
        let empty = ClipRequest(.osc52Write, "")
        host.confirmClipboard(empty)
        XCTAssertEqual(empty.answers, [false])
        XCTAssertEqual(pb.string(forType: .string), "secret", "a read, a paste request or an empty write leave the board alone")
    }

    /// OQ-66 (operator, 2026-11-10): an OSC 52 write lands only while the session is viewed: attached,
    /// selected, its window ordered in, not minimized, not fully covered, and the setting on. Every other
    /// case is answered no and writes nothing.
    @MainActor
    func testAnOSC52WriteLandsOnlyWhileTheSessionIsViewed() {
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.term.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let rig = Rig()
        let host = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.pasteboard = { [pb] in pb }
        host.owner = rig.c
        rig.c.attach(Self.key)
        rig.grid(80, 24)
        defer { rig.c.detach() }
        let shown = AgentTerminalWindowState(onScreen: true, miniaturized: false, occlusionVisible: true)
        func write(_ why: String, lands: Bool, owned: Bool = true, line: UInt = #line) {
            pb.clearContents()
            let r = ClipRequest(.osc52Write, why)
            host.confirmClipboard(r)
            XCTAssertEqual(r.answers, [false], "the library is always told no: \(why)", line: line)
            XCTAssertEqual(pb.string(forType: .string), lands ? why : nil, why, line: line)
            if owned { XCTAssertEqual(rig.c.clipboardWriteAllowed(), lands, why, line: line) }
        }
        func reset() { rig.view(); rig.writes = true }
        reset()
        write("visible and selected", lands: true)
        rig.selected = false
        write("not selected", lands: false)
        reset()
        rig.window?.occlusionVisible = false
        write("covered, on another Space or the app hidden", lands: false)
        reset()
        rig.window?.miniaturized = true
        write("minimized", lands: false)
        reset()
        rig.window?.onScreen = false
        write("ordered out", lands: false)
        reset()
        rig.window = nil
        write("window closed", lands: false)
        reset()
        rig.writes = false
        write("setting off", lands: false)
        reset()
        write("viewed again", lands: true)
        XCTAssertEqual(rig.window, shown)
        // Detached: the client left (taken by another device), then the pane let go of it.
        rig.ios[0].exit(5)
        spin()
        XCTAssertEqual(rig.c.phase, .detached("Opened on another device"))
        write("detached", lands: false)
        rig.c.attach(nil)
        write("nothing attached", lands: false)
        // No owner: the view out of its pane.
        host.owner = nil
        rig.c.attach(Self.key)
        rig.grid(80, 24)
        XCTAssertTrue(rig.c.clipboardWriteAllowed(), "its controller would say yes")
        write("no controller", lands: false, owned: false)
    }

    /// OQ-66: the setting is a Prosper default (the in-memory test store), on when unset; the controller reads
    /// it on every write, so a change in Settings applies to the next one.
    @MainActor
    func testTheClipboardSettingIsOnByDefaultAndReadOnEveryWrite() {
        let key = "agentWindowClipboardWrites"
        let saved = Preferences.defaults.object(forKey: key)
        defer { Preferences.defaults.set(saved, forKey: key) }
        XCTAssertFalse(Preferences.defaults === UserDefaults.standard, "a private defaults store")
        Preferences.defaults.removeObject(forKey: key)
        let c = AgentTerminalController()
        XCTAssertTrue(Preferences.agentWindowClipboardWrites, "on when unset")
        XCTAssertTrue(c.clipboardWrites())
        Preferences.agentWindowClipboardWrites = false
        XCTAssertFalse(c.clipboardWrites(), "read at the write, not cached")
        XCTAssertEqual(Preferences.defaults.object(forKey: key) as? Bool, false)
        Preferences.agentWindowClipboardWrites = true
        XCTAssertTrue(c.clipboardWrites())
        XCTAssertEqual(AgentSessionsSection.clipboardLabel, "Let sessions set the clipboard while you're viewing them")
    }

    /// QA #681 INFO-2 and INFO-10: libghostty takes Prosper's config as is (no diagnostics), a middle click
    /// does nothing (its primary-paste read the system pasteboard past the seam), and the config file it was
    /// loaded from is gone at once, after a theme switch too.
    @MainActor
    func testTheGhosttyConfigIgnoresMiddleClickAndLeavesNoFile() throws {
        XCTAssertTrue(AgentTerminalLook.configuration.rendered.contains("middle-click-action = ignore"))
        let c = AgentTerminalLook.make()
        XCTAssertNil(c.lastConfigurationIssue, "libghostty accepted every line")
        XCTAssertTrue(c.renderedConfig.contains("middle-click-action = ignore"))
        XCTAssertTrue(c.renderedConfig.contains("clipboard-read = deny"))
        XCTAssertTrue(c.renderedConfig.contains("clipboard-write = ask"))
        // The wrapper's own record of its file, read without touching it (dropConfigFile would remove it).
        func file() throws -> URL {
            try XCTUnwrap(Mirror(reflecting: c).children.first { $0.label == "managedConfigURL" }?.value as? URL,
                          "GhosttyTerminal's managedConfigURL is found")
        }
        let first = try file()
        defer { try? FileManager.default.removeItem(at: first) }   // only left over when the drop is broken
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, TerminalController.managedConfigDirectory.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "dropped right after the load")
        // A theme switch writes a new file (the wrapper leaves it, so the check above can see one); refresh drops its own.
        c.setTheme(TerminalTheme(light: TerminalConfiguration { $0.withBackground("#123456") },
                                 dark: TerminalConfiguration { $0.withBackground("#123456") }))
        let switched = try file()
        XCTAssertNotEqual(switched, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: switched.path), "a load the app does not drop leaves a file")
        AgentTerminalLook.refresh(c)
        let second = try file()
        XCTAssertNotEqual(second, switched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path), "and the refresh's own")
        XCTAssertEqual(AgentTerminalLook.dropConfigFile(c), second, "the drop names the file it removed")
        try? FileManager.default.removeItem(at: switched)
    }

    /// QA #681 INFO-7: the find bar's buttons say what they do to VoiceOver, not the symbols' names.
    /// (SwiftUI builds no accessibility tree for a never-shown window, so the view's modifiers are read from
    /// its dump, as AgentWindowRenameTests does.)
    @MainActor
    func testTheFindBarButtonsHaveLabels() {
        var out = ""
        dump(AgentTerminalFindBar(controller: AgentTerminalController()).body, to: &out)
        for want in ["Previous match", "Next match", "Close find", "Previous (⇧⌘G)", "Next (⌘G)", "Close (Esc)"] {
            XCTAssertTrue(out.contains("\"\(want)\""), want)
        }
    }

    @MainActor
    func testLinksFromTheSurfaceGoThroughTheOpenURLSeam() {
        let v = startedView()
        defer { v.tearDown() }
        v.host.terminalDidRequestOpenURL("https://example.com/pr/1", kind: .osc8)
        v.host.terminalDidRequestOpenURL("file:///etc/hosts", kind: .text)
        XCTAssertEqual(v.rig.opened.map(\.absoluteString), ["https://example.com/pr/1"])
    }

    @MainActor
    func testFindSearchesTheScreenAndCountsMatches() {
        let v = startedView()
        defer { v.tearDown() }
        v.output("needle one\r\nhay\r\nneedle two\r\n", self)
        v.rig.c.openFind()
        XCTAssertTrue(v.rig.c.findOpen)
        v.rig.c.findText = "needle"
        v.rig.c.search("needle")
        wait("match count") { v.rig.c.findTotal == 2 }
        v.rig.c.findNext()
        wait("a selected match") { v.rig.c.findSelected != nil }
        v.rig.c.closeFind()
        XCTAssertFalse(v.rig.c.findOpen)
        XCTAssertNil(v.rig.c.findTotal)
        XCTAssertTrue(v.window.firstResponder === v.host, "closing find gives the keys back to the terminal")
    }

    /// dch's attach replay for a cols x rows pane (vt_restore_blob, master.c:1801+): home, erase, one line
    /// per row filling all but the last column, the cursor parked. Parsed at any other grid it wraps.
    static func replay(_ tag: String, _ cols: Int, _ rows: Int) -> String {
        let lines = (0..<rows - 1).map { r in
            let head = "\(tag) row \(r) "
            return head + String(repeating: "x", count: max(0, cols - 2 - head.count)) + "|"
        }
        return "\u{1b}[H\u{1b}[J" + lines.joined(separator: "\r\n") + "\u{1b}[0m\u{1b}[\(rows);1H"
    }

    /// #844, the operator's "switching on and off sessions does not redraw their latest state": the
    /// replay a fake dch sends right after the spawn shows whole on a real libghostty surface (never
    /// shown) at the first attach, on a switch and on the way back, and the pty gets no other size.
    @MainActor
    func testTheAttachReplayShowsWholeOnARealSurfaceAndAfterASwitch() throws {
        let rig = Rig()
        let fake = rig.c.spawn
        rig.c.spawn = { req, io in
            let child = try fake(req, io)
            let bytes = Array(Self.replay(req.args.last ?? "", req.cols, req.rows).utf8)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.002) { io.output(bytes) }
            return child
        }
        let v = ViewRig(rig)
        v.start()
        defer { v.tearDown() }
        func shows(_ tag: String, clients: Int) {
            wait("\(tag) attached") { rig.requests.count == clients }
            let req = rig.requests[clients - 1]
            XCTAssertEqual(req.args.last, tag)
            var lines: [String] = []
            wait("\(tag)'s replay whole") {
                v.session?.waitForPendingOutput()
                lines = (v.session?.readViewportText() ?? "").components(separatedBy: "\n")
                return (0..<req.rows - 1).allSatisfy { r in r < lines.count && lines[r].hasPrefix("\(tag) row \(r) ") && lines[r].hasSuffix("|") }
            }
            XCTAssertEqual(lines.count, req.rows, "parsed at the grid it was drawn for")
            XCTAssertEqual(rig.c.grid.map { [$0.cols, $0.rows] }, [req.cols, req.rows])
        }
        shows("alpha", clients: 1)
        rig.c.attach(AgentSessionKey(dir: Self.key.dir, name: "beta"))
        v.host.show(rig.c.screen as? AgentGhosttyScreen)   // what the pane's updateNSView does
        shows("beta", clients: 2)
        rig.c.attach(Self.key)
        v.host.show(rig.c.screen as? AgentGhosttyScreen)
        shows("alpha", clients: 3)
        spin(0.3)
        XCTAssertEqual(rig.children.map(\.resizes), [[], [], []], "the attach is the only size dch gets")
        XCTAssertEqual(rig.children.map(\.redraws), [0, 0, 0])
    }

    /// A real pty, the program /bin/cat (never dch): keys in, the tty's echo and cat's copy out.
    @MainActor
    func testEchoThroughARealPty() throws {
        let rig = Rig()
        nonisolated(unsafe) var pty: PtyChild?
        rig.c.spawn = { req, io in
            let p = try PtyChild(exe: "/bin/cat", args: [], env: ["TERM": "xterm-256color", "HOME": NSHomeDirectory()],
                                 cols: req.cols, rows: req.rows, cwd: NSTemporaryDirectory(),
                                 onOutput: io.output, onExit: io.exit)
            pty = p
            return p
        }
        let v = ViewRig(rig)
        v.start()
        defer { v.tearDown() }
        wait("cat started") { pty != nil }
        for (code, ch) in [(4, "h"), (34, "i")] as [(UInt16, String)] { v.press(code, ch) }
        v.press(36, "\r")
        wait("echo and copy") {
            v.session?.waitForPendingOutput()
            return (v.session?.readViewportText() ?? "").components(separatedBy: "hi").count - 1 >= 2
        }
        rig.c.detach()
        XCTAssertNil(rig.c.screen)
    }

    /// Offscreen evidence: the surface's own frame (its IOSurface), at the three UI scales.
    @MainActor
    func testTheSurfaceDrawsOffscreenAtEveryScale() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let v = startedView()
            v.output("\u{1b}[1;36mProsper\u{1b}[0m terminal at \(scale)\r\n\u{1b}[42m green \u{1b}[0m\r\n", self)
            var rep: NSBitmapImageRep?
            wait("a frame") {
                rep = Self.surfaceImage(v.host)
                return rep.map { Self.ink($0) > 50 } ?? false
            }
            if let rep, let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: tempDir("822-surface").appendingPathComponent("surface-\(scale).png"))
                if let dir = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"] {
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("822-surface-\(scale).png"))
                }
            }
            v.tearDown()
        }
    }

    static func childPids() -> Set<pid_t> {
        var buf = [pid_t](repeating: 0, count: 512)
        let n = proc_listchildpids(getpid(), &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return Set(buf.prefix(Int(max(n, 0))).filter { $0 > 0 })
    }

    /// The layer libghostty presents into (an IOSurface), as a bitmap.
    @MainActor
    static func surfaceImage(_ view: NSView) -> NSBitmapImageRep? {
        var layers = [view.layer].compactMap { $0 }
        while let l = layers.popLast() {
            if let c = l.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() {
                let image = CIImage(ioSurface: unsafeBitCast(c as AnyObject, to: IOSurfaceRef.self))
                guard let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
                return NSBitmapImageRep(cgImage: cg)
            }
            layers += l.sublayers ?? []
        }
        return nil
    }

    static func ink(_ rep: NSBitmapImageRep) -> Int {
        guard let bg = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent) > 0.15 { n += 1 }
            }
        }
        return n
    }
}
