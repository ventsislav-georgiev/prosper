import Combine
import XCTest
@testable import ProsperApp

/// #1976: the X-ray drawer draws on the press. Each open read (Tasks, Memory, the chapters) is taken as it answers, so the
/// shown tab draws before the slow chapters read; a second open of the same target draws the last panel's rows on its
/// first frame and the fresh, unchanged answers publish nothing. A fake runner answers by form and parks the forms a
/// row holds (no wall clock, no dch, no process, no window).
@MainActor
final class XrayOpenFastTests: XCTestCase {

    /// The fake dch: records each form; a held form parks until `release`.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var parked: [CheckedContinuation<Void, Never>] = []
        private var _calls: [String] = []
        private var _hold: Set<String>
        let tasks: Data
        /// #1974: the Tasks answer's exit; the Questions answer (an older dch's refusal unless a row says).
        var tasksStatus: Int32 = 0
        var questions: (status: Int32, out: Data) = (1, Data())
        init(hold: Set<String>, tasks: Data = XrayPanelTasksTests.tasksOut) { (_hold, self.tasks) = (hold, tasks) }
        static func form(_ a: [String]) -> String {
            a.contains("--tasks") ? "tasks" : a.contains("--memory") ? "memory" : a.contains("--questions") ? "questions" : "chapters"
        }
        var calls: [String] { lock.withLock { _calls } }
        var parkedCount: Int { lock.withLock { parked.count } }
        var hold: Set<String> { get { lock.withLock { _hold } } set { lock.withLock { _hold = newValue } } }
        func count(_ f: String) -> Int { calls.filter { $0 == f }.count }
        var run: XrayPanels.Run {
            { [self] _, a, _ in
                let f = Self.form(a)
                if lock.withLock({ _calls.append(f); return _hold.contains(f) }) {
                    await withCheckedContinuation { c in lock.withLock { parked.append(c) } }
                }
                return f == "tasks" ? (tasksStatus, tasks) : f == "memory" ? XrayChaptersTests.mem : f == "questions" ? questions : XrayChaptersTests.chapters
            }
        }
        func release() { lock.withLock { () -> [CheckedContinuation<Void, Never>] in let h = parked; parked = []; return h }.forEach { $0.resume() } }
    }

    final class Clock { var t = XrayChaptersTests.base }

    /// A dch-chapters panel (Tasks, Memory and the chapters read), shown and live, on its own XrayPanels.
    func panel(_ panels: XrayPanels, _ clock: Clock = Clock(), tab: XrayTab = .tasks) -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayChaptersTests.local, tab: tab)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in XrayChaptersTests.base }
        p.fromDch = { true }
        p.panels = panels
        return p
    }

    /// Yields (no wall clock) until `done` or a bound.
    func until(_ done: @escaping () -> Bool) async {
        var n = 0
        while n < 10_000, !done() { n += 1; await Task.yield() }
    }

    func withKeep(_ body: () async throws -> Void) async rethrows {
        let keep = XrayPanels.keepRows
        defer { XrayPanels.keepRows = keep }
        XrayPanels.keepRows = { true }
        try await body()
    }

    /// Press to first content: Tasks answers at once, the chapters read never (held). Red at base: readBoth awaited all
    /// three before apply, so the panel stayed "Reading" until the chapters answered.
    func testTheShownTabDrawsBeforeTheChaptersAnswer() async {
        let ps = XrayPanels()
        let gate = Gate(hold: ["chapters"]), p = panel(ps)
        p.read(dch: "/fake/dch", run: gate.run)
        await until { p.loaded && p.memory != nil && gate.parkedCount == 1 }
        XCTAssertTrue(p.loaded, "Tasks answered: the drawer draws its rows")
        XCTAssertEqual(p.tasks?.tasks.count, 4)
        XCTAssertTrue(p.dchChapters == nil, "the chapters read is still out")
        XCTAssertEqual(p.tabs, [.tasks, .memory])
        XCTAssertTrue(p.reading != nil, "the open read is still in flight: no poll beside it")
        gate.release()
        await p.reading?.value
        XCTAssertEqual(p.dchChapters?.count, 6, "the chapters fill in when they answer")
        XCTAssertEqual(p.tabs, [.prompts, .tasks, .memory])
        XCTAssertEqual(p.tab, .tasks, "the shown tab does not move")
        XCTAssertTrue(p.answered)
        p.stop()
    }

    /// A tab whose read is still out does not draw early: the chosen Prompts waits for the chapters (no empty list).
    func testATabStillReadingKeepsTheReadingLine() async {
        let ps = XrayPanels()
        let gate = Gate(hold: ["chapters"]), p = panel(ps, tab: .prompts)
        p.read(dch: "/fake/dch", run: gate.run)
        await until { p.memory != nil && p.tasks != nil && gate.parkedCount == 1 }
        XCTAssertFalse(p.loaded, "Prompts is the shown tab and its read is out")
        gate.release()
        await p.reading?.value
        XCTAssertTrue(p.loaded)
        XCTAssertEqual(p.tab, .prompts)
        p.stop()
    }

    /// Re-open: the second panel for the same target is loaded on creation with the first one's rows, and the fresh
    /// answers (the same bytes) publish nothing. Red at base: no kept rows, "Reading" until the reads answer.
    func testASecondOpenDrawsTheKeptRowsOnItsFirstFrame() async {
        await withKeep {
            let panels = XrayPanels()
            let p1 = panel(panels)
            p1.read(dch: "/fake/dch", run: Gate(hold: []).run)
            await p1.reading?.value
            XCTAssertTrue(p1.loaded)
            p1.stop()
            let gate = Gate(hold: ["tasks", "memory", "chapters"]), p2 = panel(panels)
            var sent = 0
            let sink = p2.objectWillChange.sink { sent += 1 }
            p2.read(dch: "/fake/dch", run: gate.run)
            XCTAssertTrue(p2.loaded, "the kept rows on the first frame, before any read answers")
            XCTAssertEqual(p2.tasks?.tasks.count, 4)
            XCTAssertEqual(p2.memory?.count, 1)
            XCTAssertEqual(p2.dchChapters?.count, 6)
            XCTAssertEqual(p2.tab, .tasks)
            await until { gate.parkedCount == 3 }
            XCTAssertEqual(gate.parkedCount, 3, "the fresh reads still run")
            let before = sent
            gate.release()
            await p2.reading?.value
            XCTAssertTrue(p2.answered)
            XCTAssertEqual(sent, before, "unchanged answers publish nothing")
            sink.cancel()
            p2.stop()
        }
    }

    /// The kept rows are a few targets' only: the oldest goes past XrayFollows.limit.
    func testKeptRowsAreBoundedToTheNewestTargets() {
        let panels = XrayPanels(), k = XrayPanels.Kept(anchors: [:])
        for i in 0...XrayFollows.limit { panels.keep(XrayTarget(name: "api-\(i)", dir: "/tmp/dch-test"), k) }
        XCTAssertEqual(panels.kept.count, XrayFollows.limit)
        XCTAssertTrue(panels.kept[XrayTarget(name: "api-0", dir: "/tmp/dch-test")] == nil, "the oldest went")
    }

    /// Under XCTest nothing is kept unless a row turns it on (no row's rows leak into another row's open).
    func testNothingIsKeptByDefaultUnderXCTest() async {
        let panels = XrayPanels(), p = panel(panels)
        p.read(dch: "/fake/dch", run: Gate(hold: []).run)
        await p.reading?.value
        p.stop()
        XCTAssertTrue(panels.kept.isEmpty)
    }

    /// The Todos chip: no Tasks tab -> the fallback runs once, right after the Tasks answer (the chapters still out),
    /// never before it (Memory answered first), and not again when the open ends. Red with fallback-twice.
    func testTheChipFallbackRunsOnceAtTheTasksAnswer() async {
        let none = XrayPanelTasksTests.ndjson([XrayPanelTasksTests.header, #"{"done":true,"count":0,"dropped":0}"#])
        let ps = XrayPanels()
        let gate = Gate(hold: ["tasks", "chapters"], tasks: none), p = panel(ps)
        var fell = 0, closed = 0
        p.fallback = { fell += 1 }
        p.close = { closed += 1 }
        p.read(dch: "/fake/dch", run: gate.run)
        await until { p.memory != nil && gate.parkedCount == 2 }
        XCTAssertEqual(fell, 0, "Memory answered, Tasks not yet: no decision")
        XCTAssertFalse(p.loaded)
        gate.release()   // Tasks and the chapters answer
        await p.reading?.value
        XCTAssertEqual(fell, 1, "the fallback ran once")
        XCTAssertEqual(closed, 1)
        p.stop()
    }

    /// The same, with the chapters still held when Tasks answers: the fallback does not wait for them.
    func testTheChipFallbackDoesNotWaitForTheChapters() async {
        let none = XrayPanelTasksTests.ndjson([XrayPanelTasksTests.header, #"{"done":true,"count":0,"dropped":0}"#])
        let ps = XrayPanels()
        let gate = Gate(hold: ["chapters"], tasks: none), p = panel(ps)
        var fell = 0
        p.fallback = { fell += 1 }
        p.read(dch: "/fake/dch", run: gate.run)
        await until { fell == 1 && gate.parkedCount == 1 }
        XCTAssertEqual(fell, 1, "Tasks answered with no tasks: the list opens now")
        XCTAssertTrue(p.dchChapters == nil, "the chapters read is still out")
        gate.release()
        await p.reading?.value
        XCTAssertEqual(fell, 1, "not again when the open ends")
    }

    /// An open drawn early whose reads a selection change cancelled reads all three again on return (not Tasks alone),
    /// an ended session too (its one open read had not answered); the cancelled read's late answer is not taken (#1368).
    func testACancelledEarlyOpenReadsAllThreeAgain() async {
        let ps = XrayPanels()
        let clock = Clock(), gate = Gate(hold: ["chapters"]), p = panel(ps, clock)
        p.read(dch: "/fake/dch", run: gate.run)
        await until { p.loaded && gate.parkedCount == 1 }
        XCTAssertTrue(p.loaded)
        let old = p.reading
        p.isCurrent = { false }
        p.tick()   // hidden by a selection change: the read is cancelled
        XCTAssertTrue(p.reading == nil)
        gate.release()
        await old?.value
        XCTAssertTrue(p.dchChapters == nil, "the cancelled chapters answer is not news")
        XCTAssertFalse(p.answered)
        p.isCurrent = { true }
        p.paneState = { (true, false) }   // the session ended meanwhile
        gate.hold = []
        clock.t = XrayChaptersTests.base + 60
        p.tick()
        await p.reading?.value
        XCTAssertEqual(gate.count("chapters"), 2, "the open's chapters read again")
        XCTAssertEqual(gate.count("memory"), 2, "and its Memory read")
        XCTAssertTrue(p.answered)
        XCTAssertEqual(p.dchChapters?.count, 6)
        p.stop()
    }

    /// #1974 n1: an open drawn early from kept rows, with a follow attached that has no snapshot yet: when the Tasks answer
    /// removes the shown tab, the strip moves to the first tab left. Red at base: answeredAll() skipped finishOpen (no
    /// snapshot) and takeFollow returns at `guard !loaded`, so the drawer sat on the missing Tasks tab.
    func testAnEarlyOpenWithAFollowLeavesATabItsAnswerRemoved() async {
        await withKeep {
            let panels = XrayPanels()
            panels.keep(XrayChaptersTests.local, XrayPanels.Kept(tasks: XrayPanelModel.tasksTab((0, XrayPanelTasksTests.tasksOut)), anchors: [:]))
            let none = XrayPanelTasksTests.ndjson([XrayPanelTasksTests.header, #"{"done":true,"count":0,"dropped":0}"#])
            let p = panel(panels)
            p.follow = XrayFollow(target: XrayChaptersTests.local)   // attached, never started: no snapshot comes
            p.read(dch: "/fake/dch", run: Gate(hold: [], tasks: none).run)
            XCTAssertTrue(p.loaded, "drawn early from the kept Tasks")
            await p.reading?.value
            XCTAssertTrue(p.answered)
            XCTAssertTrue(p.tasks == nil, "the answer has no tasks")
            XCTAssertEqual(p.tabs, [.memory])
            XCTAssertEqual(p.tab, .memory, "the strip left the missing Tasks tab")
            p.follow = nil
            p.stop()
        }
    }

    /// #1974 n2: the Todos chip on a host that does not answer: no kept rows are drawn for it, so its unreachable Tasks
    /// answer leaves no tasks and the fallback (the list) runs. Red at base: the kept tasks were seeded, exit 4 kept them,
    /// and the chip showed stale rows instead of its list.
    func testTheChipDoesNotDrawKeptRows() async {
        await withKeep {
            let panels = XrayPanels()
            panels.keep(XrayChaptersTests.local, XrayPanels.Kept(tasks: XrayPanelModel.tasksTab((0, XrayPanelTasksTests.tasksOut)), anchors: [:]))
            let gate = Gate(hold: []), p = panel(panels)
            gate.tasksStatus = 4
            var fell = 0
            p.fallback = { fell += 1 }
            p.read(dch: "/fake/dch", run: gate.run)
            XCTAssertFalse(p.loaded, "no kept rows on the chip's first frame")
            await p.reading?.value
            XCTAssertEqual(fell, 1, "the list opens")
            XCTAssertTrue(p.tasks == nil)
            p.stop()
        }
    }
}
