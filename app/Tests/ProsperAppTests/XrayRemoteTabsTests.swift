import XCTest
@testable import ProsperApp

/// #1353 (#1346 P5, design 3.5): X-ray's Tasks and Memory tabs for a session on another machine. The local dch reads
/// it as "host:name"; each read dials, so Tasks polls every 15 s (Memory 30 s); exit 4/7 (and a remote -1) keep the
/// rows with "host unreachable", exit 1 ("does not know"), 6 or any other failure means no tab. A fake runner answers
/// by form; the clock is injected and the ticks are called by hand. No dch, no process, no window.
@MainActor
final class XrayRemoteTabsTests: XCTestCase {

    typealias Answer = (status: Int32, out: Data)
    nonisolated static let base = XrayPanelTasksTests.now
    nonisolated static let ok: Answer = (0, XrayPanelTasksTests.tasksOut)
    nonisolated static let mem: Answer = (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory))
    static let label = "host unreachable"

    /// The fake dch: records each argv and answers by form at once.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _tasks = XrayRemoteTabsTests.ok, _memory = XrayRemoteTabsTests.mem
        var calls: [[String]] { lock.withLock { _calls } }
        var tasksReads: Int { calls.filter { $0.contains("--tasks") }.count }
        var memoryReads: Int { calls.filter { $0.contains("--memory") }.count }
        var tasks: Answer { get { lock.withLock { _tasks } } set { lock.withLock { _tasks = newValue } } }
        var memory: Answer { get { lock.withLock { _memory } } set { lock.withLock { _memory = newValue } } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                lock.withLock { () -> Answer in _calls.append(args); return args.contains("--tasks") ? _tasks : _memory }
            }
        }
    }

    final class Clock { var t = XrayRemoteTabsTests.base }

    /// The sidebar's remote row for "api" on "example-host".
    static var remoteRow: AgentSidebar.Row {
        var r = AgentSidebar.Row(id: .remote(host: "example-host", name: "api"), title: "api", state: .idle, detail: "",
                                 age: "", prs: [])
        r.remote = AgentSidebar.Remote(host: "example-host", name: "api", alias: "", stale: false, cwd: nil)
        return r
    }

    /// A panel on the remote row's target, shown and live, its clock at `base`.
    func panel(_ clock: Clock) throws -> XrayPanelModel {
        let target = try XCTUnwrap(XrayTarget.of(Self.remoteRow))
        let p = XrayPanelModel(target: target, tab: .tasks)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in Self.base }
        return p
    }

    func open(_ p: XrayPanelModel, _ run: Run) async {
        p.read(dch: "/fake/dch", run: run.run)
        await p.reading?.value
    }

    func tick(_ p: XrayPanelModel, _ clock: Clock, at s: TimeInterval) async {
        clock.t = Self.base + s
        p.tick()
        await p.reading?.value
    }

    func testRemoteArgvIsHostColonNameForBothForms() async throws {
        XCTAssertEqual(XrayTarget.of(Self.remoteRow), XrayTarget(name: "example-host:api", dir: nil))
        let clock = Clock(), run = Run(), p = try panel(clock)
        await open(p, run)
        XCTAssertEqual(Set(run.calls), [["--xray", "example-host:api", "--tasks", "--json"],
                                        ["--xray", "example-host:api", "--memory", "--json"]], "the open read, both forms")
        await tick(p, clock, at: 15)
        XCTAssertEqual(run.calls.last, ["--xray", "example-host:api", "--tasks", "--json"], "the Tasks poll")
        p.select(.memory)
        await p.reading?.value
        XCTAssertEqual(run.calls.last, ["--xray", "example-host:api", "--memory", "--json"], "the Memory read")
        XCTAssertEqual(run.calls.count, 4)
    }

    func testRemoteCadenceIsFifteenSecondsForTasksAndThirtyForMemory() async throws {
        let clock = Clock(), run = Run(), p = try panel(clock)
        await open(p, run)
        XCTAssertEqual(p.interval, 15)
        for s in [5.0, 10, 14] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.tasksReads, 1, "no Tasks poll before 15 s (a local session's 5 s would read at +5 and +10)")
        await tick(p, clock, at: 15)
        XCTAssertEqual(run.tasksReads, 2, "at 15 s")
        for s in [20.0, 25, 29] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.tasksReads, 2)
        await tick(p, clock, at: 30)
        XCTAssertEqual(run.tasksReads, 3, "at 30 s")
        p.select(.memory)
        await p.reading?.value
        XCTAssertEqual(run.memoryReads, 2, "the open read and the switch at +30")
        XCTAssertEqual(p.interval, 30)
        await tick(p, clock, at: 59)
        XCTAssertEqual(run.memoryReads, 2, "Memory: not before 30 s")
        await tick(p, clock, at: 60)
        XCTAssertEqual(run.memoryReads, 3, "Memory: at 30 s")
        XCTAssertEqual(run.tasksReads, 3, "Memory shown: no Tasks poll")
    }

    /// Exit 4, 7 and a remote -1: the rows are kept and the footer says "host unreachable"; exit 1 and 6: no Tasks tab.
    func testExitLabelsOnATasksPoll() async throws {
        for (code, kept) in [(Int32(4), true), (7, true), (-1, true), (1, false), (6, false)] {
            let clock = Clock(), run = Run(), p = try panel(clock)
            await open(p, run)
            XCTAssertFalse(p.footer.contains(Self.label))
            run.tasks = (code, Data())
            await tick(p, clock, at: 15)
            XCTAssertEqual(p.tasks?.tasks.count, kept ? 4 : nil, "exit \(code)")
            XCTAssertEqual(p.tabs, kept ? [.tasks, .memory] : [.memory], "exit \(code)")
            XCTAssertEqual(p.unreachable, kept, "exit \(code)")
            XCTAssertEqual(p.footer.contains(Self.label), kept, "exit \(code): \(p.footer)")
            if !kept { XCTAssertEqual(p.tab, .memory, "exit \(code): the strip moves to the tab left") }
        }
    }

    /// "the host's dch does not know --tasks/--memory" (exit 1): no tab, on the open read and on a poll.
    func testNoTabWhenTheHostsDchDoesNotKnowTheFlag() async throws {
        let clock = Clock(), run = Run(), p = try panel(clock)
        run.tasks = (1, Data("dch: the host's dch does not know --tasks\n".utf8))
        run.memory = (1, Data("dch: the host's dch does not know --memory\n".utf8))
        await open(p, run)
        XCTAssertTrue(p.loaded)
        XCTAssertEqual(p.tabs, [], "no tab")
        XCTAssertFalse(p.unreachable, "the host answered")
        for s in [15.0, 30, 600] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.calls.count, 2, "no retry until the dch path's mtime moves (design 3.9)")

        let c2 = Clock(), r2 = Run(), q = try panel(c2)
        await open(q, r2)
        r2.tasks = (1, Data("dch: the host's dch does not know --tasks\n".utf8))
        await tick(q, c2, at: 15)
        XCTAssertTrue(q.tasks == nil, "a poll that does not know: the tab goes")
        XCTAssertEqual(q.tabs, [.memory])
        for s in [30.0, 45] { await tick(q, c2, at: s) }
        XCTAssertEqual(r2.tasksReads, 2, "no Tasks tab shown: no poll")
    }

    /// Exit 6 on a poll removes the Tasks tab for good (no further Tasks read); the Memory tab stays.
    func testExitSixRemovesTheTab() async throws {
        let clock = Clock(), run = Run(), p = try panel(clock)
        await open(p, run)
        run.tasks = (6, Data())
        await tick(p, clock, at: 15)
        XCTAssertTrue(p.tasks == nil, "exit 6: no Tasks tab")
        XCTAssertEqual(p.tabs, [.memory])
        XCTAssertEqual(p.memory?.count, 1)
    }

    /// R1381-i1: a remote session, Memory shown: exit 7 keeps the rows and says "host unreachable"; exit 0 clears it, also
    /// when Tasks set it.
    func testMemoryReadSetsAndClearsHostUnreachable() async throws {
        let clock = Clock(), run = Run(), p = try panel(clock)
        await open(p, run)
        p.select(.memory)
        await p.reading?.value
        XCTAssertEqual(p.memoryFooter, [])
        run.memory = (7, Data())
        await tick(p, clock, at: 30)
        XCTAssertEqual(run.memoryReads, 3)
        XCTAssertEqual(p.memory?.count, 1, "exit 7: the rows are kept")
        XCTAssertEqual(p.tabs, [.tasks, .memory])
        XCTAssertTrue(p.memoryFooter.contains(Self.label), "exit 7: \(p.memoryFooter)")
        run.memory = Self.mem
        await tick(p, clock, at: 60)
        XCTAssertEqual(run.memoryReads, 4)
        XCTAssertFalse(p.unreachable, "exit 0: the host answered")
        XCTAssertEqual(p.memoryFooter, [])

        // a Tasks poll set it; a good Memory answer clears it
        let c2 = Clock(), r2 = Run(), q = try panel(c2)
        await open(q, r2)
        r2.tasks = (7, Data())
        await tick(q, c2, at: 15)
        XCTAssertTrue(q.unreachable)
        q.select(.memory)
        await q.reading?.value
        XCTAssertEqual(r2.memoryReads, 2)
        XCTAssertFalse(q.unreachable, "the Memory read reached the host")
        XCTAssertEqual(q.memoryFooter, [])
    }
}
