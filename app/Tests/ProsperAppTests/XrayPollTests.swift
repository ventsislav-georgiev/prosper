import XCTest
@testable import ProsperApp

/// #1368 (#1346 P3b, design 3.4, 3.5, 3.9): the X-ray Tasks poller. The clock is injected (`now`), the ticks are called
/// by hand (no ticker runs under XCTest), the reads go to a fake runner that can hold an answer until the test releases
/// it and records each cancel. No dch, no process, no signal (the child's SIGTERM goes to a recorder), no window.
@MainActor
final class XrayPollTests: XCTestCase {

    typealias Answer = (status: Int32, out: Data)
    nonisolated static let base = XrayPanelTasksTests.now
    nonisolated static let ok: Answer = (0, XrayPanelTasksTests.tasksOut)
    nonisolated static let mem: Answer = (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory))

    /// The fake dch: answers by form at once, or (hold) parks the call until `answer` (with the answer its form had at
    /// the call); a cancel answers -1 and counts.
    final class PollRun: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _cancels = 0
        private var parked: [Int: (c: CheckedContinuation<Answer, Never>, reply: Answer)] = [:]
        private var cancelled: Set<Int> = []
        private var _tasks = XrayPollTests.ok, _memory = XrayPollTests.mem
        private var _hold = false
        var calls: [[String]] { lock.withLock { _calls } }
        var tasksReads: Int { calls.filter { $0.contains("--tasks") }.count }
        var memoryReads: Int { calls.filter { $0.contains("--memory") }.count }
        var cancels: Int { lock.withLock { _cancels } }
        var held: Int { lock.withLock { parked.count } }
        var tasks: Answer { get { lock.withLock { _tasks } } set { lock.withLock { _tasks = newValue } } }
        var memory: Answer { get { lock.withLock { _memory } } set { lock.withLock { _memory = newValue } } }
        var hold: Bool { get { lock.withLock { _hold } } set { lock.withLock { _hold = newValue } } }

        var run: XrayPanels.Run {
            { [self] _, args, _ in
                let (id, hold, reply) = lock.withLock { () -> (Int, Bool, Answer) in
                    _calls.append(args)
                    return (_calls.count, _hold, args.contains("--tasks") ? _tasks : _memory)
                }
                guard hold else { return reply }
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { c in
                        let gone = lock.withLock { () -> Bool in
                            if cancelled.contains(id) { return true }
                            parked[id] = (c, reply)
                            return false
                        }
                        if gone { c.resume(returning: (-1, Data())) }
                    }
                } onCancel: { [self] in
                    lock.withLock { () -> CheckedContinuation<Answer, Never>? in
                        _cancels += 1
                        cancelled.insert(id)
                        return parked.removeValue(forKey: id)?.c
                    }?.resume(returning: (-1, Data()))
                }
            }
        }

        /// Releases every parked call.
        func answer() {
            let ps = lock.withLock { () -> [(c: CheckedContinuation<Answer, Never>, reply: Answer)] in
                defer { parked = [:] }
                return Array(parked.values)
            }
            ps.forEach { $0.c.resume(returning: $0.reply) }
        }
    }

    final class Clock { var t = XrayPollTests.base }

    /// A panel on "api" (local) or "example-host:api" (remote), its clock at `base`, shown and live unless said.
    func panel(remote: Bool = false, _ clock: Clock) -> XrayPanelModel {
        let p = XrayPanelModel(target: remote ? XrayTarget(name: "example-host:api", dir: nil)
                                              : XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in Self.base }
        return p
    }

    func open(_ p: XrayPanelModel, _ run: PollRun) async {
        p.read(dch: "/fake/dch", run: run.run)
        await p.reading?.value
    }

    /// One tick at `base + s`, awaited when it started a read that answers at once.
    func tick(_ p: XrayPanelModel, _ clock: Clock, at s: TimeInterval) async {
        clock.t = Self.base + s
        p.tick()
        await p.reading?.value
    }

    func testCadenceIsFiveSecondsLocalAndFifteenRemote() async {
        for (remote, period) in [(false, 5.0), (true, 15.0)] {
            let clock = Clock(), run = PollRun(), p = panel(remote: remote, clock)
            await open(p, run)
            XCTAssertEqual(run.tasksReads, 1, "the read on open")
            await tick(p, clock, at: period - 1)
            XCTAssertEqual(run.tasksReads, 1, "remote \(remote): not before \(period) s")
            await tick(p, clock, at: period)
            XCTAssertEqual(run.tasksReads, 2, "remote \(remote): at \(period) s")
            await tick(p, clock, at: 2 * period - 1)
            XCTAssertEqual(run.tasksReads, 2)
            await tick(p, clock, at: 2 * period)
            XCTAssertEqual(run.tasksReads, 3)
            XCTAssertEqual(run.memoryReads, 1, "the poller reads Tasks only")
            XCTAssertEqual(run.calls.last, ["--xray", remote ? "example-host:api" : "api", "--tasks", "--json"])
            XCTAssertEqual(p.tasks?.tasks.count, 4)
        }
    }

    func testNoReadWhileHidden() async {
        let clock = Clock(), run = PollRun(), p = panel(clock)
        var (visible, current) = (false, true)
        p.paneState = { (visible, true) }
        p.isCurrent = { current }
        await open(p, run)
        for s in [5.0, 15, 60, 600] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.tasksReads, 1, "window not visible: no read")
        (visible, current) = (true, false)
        for s in [605.0, 700] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.tasksReads, 1, "drawer hidden by a selection change: no read")
        current = true
        await tick(p, clock, at: 701)
        XCTAssertEqual(run.tasksReads, 2, "shown again: it reads")
    }

    func testNoSecondProcessWhileOneRuns() async {
        let clock = Clock(), run = PollRun(), p = panel(clock)
        run.hold = true
        p.read(dch: "/fake/dch", run: run.run)
        for _ in 0..<10_000 where run.held < 2 { await Task.yield() }   // both open reads parked, no wall clock
        XCTAssertEqual(run.held, 2)
        clock.t = Self.base + 5
        p.tick()
        XCTAssertEqual(run.calls.count, 2, "the open read still runs: the tick is skipped")
        var r = p.reading
        run.answer()
        await r?.value
        p.tick()
        for _ in 0..<10_000 where run.held < 1 { await Task.yield() }
        XCTAssertEqual(run.tasksReads, 2, "the open read done: the tick reads")
        XCTAssertEqual(run.held, 1)
        for s in [10.0, 15, 20, 60] { clock.t = Self.base + s; p.tick() }
        XCTAssertEqual(run.tasksReads, 2, "a tick while a read runs is skipped, never queued")
        r = p.reading
        run.answer()
        await r?.value
        XCTAssertEqual(run.tasksReads, 2, "nothing queued behind it")
        run.hold = false
        await tick(p, clock, at: 61)
        XCTAssertEqual(run.tasksReads, 3)
        XCTAssertEqual(run.cancels, 0)
    }

    func testCloseOrSelectionChangeCancelsTheReadOnce() async {
        for close in [true, false] {
            let clock = Clock(), run = PollRun(), p = panel(clock), pane = UUID()
            defer { XrayPanels.shared.open = [:] }
            var current = true
            if close { XrayPanels.shared.open[pane] = p } else { p.isCurrent = { current } }
            p.paneState = { (true, true) }   // after the insert, which wires the product's
            await open(p, run)
            run.hold = true
            clock.t = Self.base + 5
            p.tick()
            for _ in 0..<10_000 where run.held < 1 { await Task.yield() }
            XCTAssertEqual(run.held, 1, "the poll read runs")
            let r = p.reading
            if close { XrayPanels.shared.close(pane) } else { current = false; p.tick() }
            for _ in 0..<10_000 where run.cancels < 1 { await Task.yield() }   // bounded: a missing cancel fails, never hangs
            XCTAssertEqual(run.cancels, 1, close ? "close cancels the read" : "a selection change cancels it")
            run.answer()   // releases a read no cancel reached, so the await below always ends
            await r?.value
            XCTAssertTrue(p.reading == nil)
            XCTAssertEqual(p.tasks?.tasks.count, 4, "the cancelled answer is not applied")
            for s in [6.0, 20, 60] { await tick(p, clock, at: s) }
            XCTAssertEqual(run.cancels, 1, "exactly once")
            XCTAssertEqual(run.tasksReads, 2, "no read after it")
            if !close {
                run.hold = false
                current = true
                await tick(p, clock, at: 61)
                XCTAssertEqual(run.tasksReads, 3, "the session shown again: polled again")
            }
        }
    }

    func testEndedSessionGetsOneRead() async {
        let clock = Clock(), run = PollRun(), p = panel(clock)
        var live = false
        p.paneState = { (true, live) }
        await open(p, run)
        for s in [5.0, 15, 60, 600] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.calls.count, 2, "ended: the open read (both forms), then no poll")
        live = true
        await tick(p, clock, at: 605)
        XCTAssertEqual(run.tasksReads, 2, "live: polled")
        live = false
        for s in [610.0, 700] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.tasksReads, 2, "it ended: no poll")
    }

    func testExitSixOrDoesNotKnowRemovesTheTab() async {
        for bad in [(Int32(6), ""), (Int32(2), "dch: does not know --tasks")] {
            let clock = Clock(), run = PollRun(), p = panel(clock)
            await open(p, run)
            XCTAssertEqual(p.tabs, [.tasks, .memory])
            run.tasks = (bad.0, Data(bad.1.utf8))
            await tick(p, clock, at: 5)
            XCTAssertTrue(p.tasks == nil, "exit \(bad.0): no Tasks tab")
            XCTAssertEqual(p.tabs, [.memory])
            XCTAssertEqual(p.tab, .memory, "the strip moves to the tab left")
            for s in [10.0, 60] { await tick(p, clock, at: s) }
            XCTAssertEqual(run.tasksReads, 2, "no Tasks tab shown: no poll")
        }
    }

    func testUnreachableKeepsTheRowsAndSaysSo() async {
        for code in [Int32(4), 7] {
            let clock = Clock(), run = PollRun(), p = panel(remote: true, clock)
            await open(p, run)
            XCTAssertFalse(p.footer.contains("host unreachable"))
            run.tasks = (code, Data())
            await tick(p, clock, at: 15)
            XCTAssertEqual(p.tasks?.tasks.count, 4, "exit \(code): the rows are kept")
            XCTAssertEqual(p.tabs, [.tasks, .memory])
            XCTAssertTrue(p.footer.contains("host unreachable"), "exit \(code): \(p.footer)")
            await tick(p, clock, at: 30)
            XCTAssertEqual(run.tasksReads, 3, "unreachable is not a failure: the poll goes on")
            run.tasks = Self.ok
            await tick(p, clock, at: 45)
            XCTAssertFalse(p.footer.contains("host unreachable"), "the host answered")
        }
    }

    func testRemoteTimeoutIsUnreachableAndKeepsPolling() async {
        let clock = Clock(), run = PollRun(), p = panel(remote: true, clock)
        await open(p, run)
        run.tasks = (-1, Data())
        await tick(p, clock, at: 15)
        XCTAssertEqual(p.tasks?.tasks.count, 4, "remote -1 (timed out dialling): the rows are kept")
        XCTAssertTrue(p.footer.contains("host unreachable"), "\(p.footer)")
        for s in [30.0, 45] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.tasksReads, 4, "the poll goes on at 15 s")
    }

    func testLocalTimeoutStopsUntilTheMtimeMoves() async {
        let clock = Clock(), run = PollRun(), p = panel(clock)
        var mtime = Self.base
        p.mtime = { _ in mtime }
        run.memory = (2, Data())   // no Memory tab, so the strip stays on Tasks and only the 3.9 rule can stop the poll
        await open(p, run)
        run.tasks = (-1, Data())
        await tick(p, clock, at: 5)
        XCTAssertTrue(p.tasks == nil, "local -1: a failure, no tab")
        XCTAssertFalse(p.footer.contains("host unreachable"))
        for s in [10.0, 60, 600] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.tasksReads, 2, "no retry while the mtime stands")
        mtime = Self.base + 3600
        run.tasks = Self.ok
        await tick(p, clock, at: 601)
        XCTAssertEqual(run.tasksReads, 3, "the dch path changed: one retry")
    }

    // MARK: the product's pane state and isCurrent, through a never-shown window and toggleXray

    /// A never-shown window on a model with "api" and "api-qa", "api" selected; X-ray opened by toggleXray on `run`
    /// (gate 1.78.0); XrayPanels.model points at this model. Nothing spawns, nothing is shown.
    func withOpenPanel(_ run: PollRun, _ body: (AgentWindowModel, XrayPanelModel, Clock) async throws -> Void) async throws {
        let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        store.sessions = [AgentSession(key: key, alias: "", activity: AgentWindowD1Tests.now - 60, state: .idle, agents: 0,
                                       version: "1.78.0"),
                          AgentSession(key: XrayPanelTasksTests.otherKey, alias: "", activity: AgentWindowD1Tests.now - 120,
                                       state: .idle, agents: 0, version: "1.78.0")]
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        final class Spawns { var count = 0 }
        let spawns = Spawns()
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in spawns.count += 1; return AgentTerminalTests.FakeChild() }
        m.bind(store)
        m.setVisible(true)
        m.select(.live(key))
        defer { m.close() }
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        win.cards = FakeCardPresenter()
        let (dch, prun, model) = (XrayPanels.dch, XrayPanels.run, XrayPanels.model)
        defer { (XrayPanels.dch, XrayPanels.run, XrayPanels.model) = (dch, prun, model); XrayPanels.shared.open = [:] }
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 78, 0])
        XrayPanels.run = run.run
        XrayPanels.model = { [weak m] _ in m }
        XCTAssertTrue(win.toggleXray())
        let p = try XCTUnwrap(XrayPanels.shared.open[m.layout.focused])
        await p.reading?.value
        let clock = Clock()
        clock.t = p.lastRead
        p.now = { clock.t }
        p.mtime = { _ in Self.base }
        try await body(m, p, clock)
        XCTAssertEqual(spawns.count, 0, "no terminal spawned")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    func testHiddenWindowGivesNoReadThroughThePaneState() async throws {
        let run = PollRun()
        try await withOpenPanel(run) { m, p, clock in
            XCTAssertEqual(run.tasksReads, 1, "the open read")
            XCTAssertTrue(XrayPanels.paneState(m.layout.focused) == (true, true), "shown and live")
            XCTAssertTrue(XrayPanels.paneState(UUID()) == (false, false), "a pane the window does not focus: hidden")
            let t0 = clock.t
            m.setVisible(false)
            XCTAssertTrue(XrayPanels.paneState(m.layout.focused).visible == false)
            for s in [5.0, 10, 60, 600] { clock.t = t0 + s; p.tick(); await p.reading?.value }
            XCTAssertEqual(run.tasksReads, 1, "the window hidden: no read")
            m.setVisible(true)
            clock.t = t0 + 601
            p.tick()
            await p.reading?.value
            XCTAssertEqual(run.tasksReads, 2, "visible again: the next tick reads")
        }
    }

    func testSelectionChangeCancelsByTheNextTick() async throws {
        let run = PollRun()
        try await withOpenPanel(run) { m, p, clock in
            let t0 = clock.t
            run.hold = true
            clock.t = t0 + 5
            p.tick()
            for _ in 0..<10_000 where run.held < 1 { await Task.yield() }
            XCTAssertEqual(run.held, 1, "the poll read runs")
            let r = p.reading
            m.select(.live(XrayPanelTasksTests.otherKey))
            XCTAssertEqual(run.cancels, 0, "the selection alone sends nothing: the tick does (1 s latency)")
            clock.t = t0 + 6
            p.tick()
            for _ in 0..<10_000 where run.cancels < 1 { await Task.yield() }
            XCTAssertEqual(run.cancels, 1, "the next tick cancels it")
            run.answer()
            await r?.value
            XCTAssertTrue(p.reading == nil)
            for s in [7.0, 20, 60] { clock.t = t0 + s; p.tick() }
            XCTAssertEqual(run.cancels, 1, "once")
            XCTAssertEqual(run.tasksReads, 2, "no read for a hidden drawer")
        }
    }

    func testNoRetryUntilTheDchMtimeMoves() async {
        let clock = Clock(), run = PollRun(), p = panel(clock)
        var mtime = Self.base, asked: [String] = []
        p.mtime = { asked.append($0); return mtime }
        run.tasks = (2, Data("dch: does not know --tasks".utf8))
        run.memory = (2, Data())
        await open(p, run)
        XCTAssertEqual(p.tabs, [], "older dch: no tab")
        for s in [5.0, 10, 60, 600] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.tasksReads, 1, "no retry while the mtime stands")
        XCTAssertEqual(asked.last, "/fake/dch")
        mtime = Self.base + 3600
        run.tasks = Self.ok
        await tick(p, clock, at: 601)
        XCTAssertEqual(run.tasksReads, 2, "the dch path changed: one retry")
        XCTAssertEqual(p.tasks?.tasks.count, 4, "and the tab is back")
    }

    func testChildIsSignalledOnceAndNeverAfterItIsReaped() {
        final class Sent: @unchecked Sendable { let lock = NSLock(); var pids: [pid_t] = [] }
        func child(_ s: Sent) -> XrayChild { XrayChild { p in s.lock.withLock { s.pids.append(p) } } }
        let early = Sent(), c1 = child(early)
        c1.cancel()
        XCTAssertEqual(early.pids, [], "nothing launched yet")
        c1.started(41)
        XCTAssertEqual(early.pids, [41], "cancelled before the launch: signalled at it")
        let mid = Sent(), c2 = child(mid)
        c2.started(42)
        c2.cancel()
        c2.cancel()
        XCTAssertEqual(mid.pids, [42], "once")
        let late = Sent(), c3 = child(late)
        c3.started(43)
        c3.reaped()
        c3.cancel()
        XCTAssertEqual(late.pids, [], "reaped: its pid may be reused")
    }
}
