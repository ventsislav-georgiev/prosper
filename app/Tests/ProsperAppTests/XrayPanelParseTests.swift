import XCTest
@testable import ProsperApp

/// #2091: the open read's and the polls' answers are parsed off the main thread (XrayPanelModel.parsed); the main actor
/// takes the parsed values only. The parse equals the main-actor apply's, a parse on the main thread is counted
/// (XrayParsed.parses), and a stale read that answers last is still dropped. Fake runners only (no dch, no window).
@MainActor
final class XrayPanelParseTests: XCTestCase {

    /// A fake dch: the first Tasks read parks until `release` and answers `old`; every later one answers `new` at once.
    final class Stale: @unchecked Sendable {
        private let lock = NSLock()
        private var parked: CheckedContinuation<Void, Never>?
        private var tasksCalls = 0
        let old: Data, new: Data
        init(old: Data, new: Data) { (self.old, self.new) = (old, new) }
        var isParked: Bool { lock.withLock { parked != nil } }
        var run: XrayPanels.Run {
            { [self] _, a, _ in
                let f = XrayOpenFastTests.Gate.form(a)
                guard f == "tasks" else { return f == "memory" ? XrayChaptersTests.mem : f == "questions" ? (1, Data()) : XrayChaptersTests.chapters }
                let first = lock.withLock { tasksCalls += 1; return tasksCalls == 1 }
                guard first else { return (0, new) }
                await withCheckedContinuation { c in lock.withLock { parked = c } }
                return (0, old)
            }
        }
        func release() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { parked = nil }; return parked }?.resume() }
    }

    func panel() -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayChaptersTests.local, tab: .tasks)
        p.now = { XrayChaptersTests.base }
        p.paneState = { (true, true) }
        p.mtime = { _ in XrayChaptersTests.base }
        p.fromDch = { true }
        p.panels = XrayPanels()
        return p
    }

    func until(_ done: @escaping () -> Bool) async {
        var n = 0
        while n < 10_000, !done() { n += 1; await Task.yield() }
    }

    /// The off-main parse of the perf fixtures (60 tasks, 20 memory, 300 chapters) equals each parser's own result and
    /// the main-actor apply(tasks:memory:chapters:). Red if one parser is skipped (a field stays nil or empty).
    func testOffMainParseEqualsTheMainApply() async {
        let (t, m, c) = (AgentPanePerfTests.tasks, AgentPanePerfTests.memory, AgentPanePerfTests.chapters)
        let pt = await XrayPanelModel.parsed(.tasks, t), pm = await XrayPanelModel.parsed(.memory, m)
        let pc = await XrayPanelModel.parsed(.chapters, c, refs: true), pr = await XrayPanelModel.parsed(.refs, c)
        XCTAssertTrue(pt.tasks == XrayPanelModel.tasksTab(XrayTasks.parse(t.1)))
        XCTAssertEqual(pt.tasks?.tasks.count, 60)
        XCTAssertTrue(pm.memory == XrayMemory.parse(m.1))
        XCTAssertEqual(pm.memory?.count, 20)
        XCTAssertTrue(pc.chapters == XrayChapters.parse(c.1))
        XCTAssertEqual(pc.chapters?.count, 300)
        XCTAssertEqual(pc.anchors, XrayPanelModel.anchors(c.1))
        XCTAssertEqual(pc.anchors.count, 300)
        XCTAssertTrue(pc.corpus == XrayChapters.corpus(c.1) && pc.corpus != nil)
        XCTAssertTrue(pc.refs == XrayRefs.parse(c.1) && pc.refs != nil, "the refs from the same decode when the gate is on")
        XCTAssertTrue(pr.refs == XrayRefs.parse(c.1) && pr.refs != nil)
        let off = await XrayPanelModel.parsed(.chapters, c)
        XCTAssertTrue(off.refs == nil && off.chapters == pc.chapters, "gate off: no refs parse")

        let a = panel(), b = panel()
        a.apply(tasks: t, memory: m, chapters: c)
        b.apply([pt, pm, off])
        XCTAssertTrue(a.tasks == b.tasks && a.memory == b.memory && a.dchChapters == b.dchChapters)
        XCTAssertEqual(a.chapterAnchors, b.chapterAnchors)
        XCTAssertTrue(a.corpus == b.corpus && a.refs == b.refs)
        XCTAssertEqual(a.tabs, b.tabs)
        XCTAssertEqual(b.tabs, [.prompts, .tasks, .memory])
        XCTAssertTrue(a.loaded && b.loaded)
    }

    /// The open's reads and a poll parse on no main thread: XrayParsed.parses counts each parse and the main-thread ones.
    /// Red if the parse runs on main again (the main count moves).
    func testTheReadsParseOffTheMainThread() async {
        let p = panel(), gate = XrayOpenFastTests.Gate(hold: [])
        let before = XrayParsed.parses.withLock { $0 }
        p.read(dch: "/fake/dch", run: gate.run)
        await p.reading?.value
        XCTAssertEqual(p.tasks?.tasks.count, 4)
        XCTAssertEqual(p.dchChapters?.count, 6)
        XCTAssertTrue(p.memory != nil && p.loaded && p.answered)
        var now = XrayParsed.parses.withLock { $0 }
        XCTAssertGreaterThanOrEqual(now.all - before.all, 3, "Tasks, Memory and the chapters parsed")
        XCTAssertEqual(now.main, before.main, "no answer parsed on the main thread")
        p.now = { XrayChaptersTests.base + 60 }
        p.tick()   // the 30 s Tasks poll
        XCTAssertTrue(p.reading != nil, "a poll read started")
        await p.reading?.value
        now = XrayParsed.parses.withLock { $0 }
        XCTAssertGreaterThanOrEqual(now.all - before.all, 4, "the poll's answer parsed too")
        XCTAssertEqual(now.main, before.main, "the poll parsed off main")
        XCTAssertEqual(gate.count("tasks"), 2)
        p.stop()
    }

    /// The main-actor entry still parses on main (the seam rows and the perf harness use it), and counts it.
    func testTheMainActorApplyCountsItsParses() {
        let p = panel(), before = XrayParsed.parses.withLock { $0 }
        p.apply(tasks: (0, XrayPanelTasksTests.tasksOut), memory: XrayChaptersTests.mem, chapters: XrayChaptersTests.chapters)
        let now = XrayParsed.parses.withLock { $0 }
        XCTAssertEqual(now.main - before.main, 3)
        XCTAssertEqual(p.tasks?.tasks.count, 4)
    }

    /// An open read cancelled (followFailed's cancel + readBoth) whose Tasks answer comes after the newer read's: the newer
    /// rows stay. Red if a cancelled read's parsed answer is taken.
    func testAStaleReadAnsweringLastDoesNotOverwriteTheNewerOne() async {
        let fake = Stale(old: XrayPanelTasksTests.tasksOut, new: AgentPanePerfTests.tasks.1)
        let p = panel()
        p.read(dch: "/fake/dch", run: fake.run)
        await until { fake.isParked && p.memory != nil }
        XCTAssertTrue(fake.isParked)
        let old = p.reading
        p.cancel()
        p.readBoth()
        await p.reading?.value
        XCTAssertEqual(p.tasks?.tasks.count, 60, "the newer read's rows")
        fake.release()
        await old?.value
        XCTAssertEqual(p.tasks?.tasks.count, 60, "the stale answer, parsed after the newer one landed, is dropped")
        p.stop()
    }
}
