import XCTest
@testable import ProsperApp

/// #1475 c (dch #446, 1.91.0): X-ray's Tasks and Memory from the same `dch --xray <n> --follow --tasks --memory --json`
/// as the chapters, through the XrayPanels.follow seam (XrayFollowTests.Fake) and a probed fake dch version. Tasks and
/// Memory reads go to the fake runners of the neighbouring rows. No dch, no window, no key; the one process row runs a
/// /bin/sh fixture in tempDir.
@MainActor
final class XrayFollowTasksTests: XCTestCase {
    typealias Fake = XrayFollowTests.Fake
    typealias Clock = XrayFollowTests.Clock

    static let plain = ["--xray", "api", "--follow", "--json"]
    static let withTasks = ["--xray", "api", "--follow", "--tasks", "--memory", "--json"]
    static let tasksHeader = XrayPanelTasksTests.header
    static let memoryHeader = XrayPanelTasksTests.memory[0]
    static let done = #"{"done":true,"count":2,"dropped":0}"#

    static func task(_ id: String, _ status: String = "pending") -> String {
        #"{"task":{"id":""# + id + #"","title":"Task "# + id + #"","status":""# + status + #""}}"#
    }
    static func memory(_ id: String) -> String {
        #"{"memory":{"id":""# + id + #"","title":"Note "# + id + #"","kind":"project","scope":"user","path":"/Users/example/"# + id + #".md"}}"#
    }
    /// A tasks block, then a memory block, as dch sends them after a snapshot.
    static func blocks(tasks: [String], memories: [String]) -> [String] {
        [tasksHeader] + tasks.map { task($0) } + [done, memoryHeader] + memories.map(memory) + [done]
    }

    /// The seams set for the body (the follow gate, the fake stream, the probed dch) and put back after it.
    func withFollow(dch version: [Int] = [1, 91, 0], _ body: (Fake, XrayPanels) async throws -> Void) async rethrows {
        let (ok, follow, probed) = (XrayPanels.followOK, XrayPanels.follow, XrayPanels.probed)
        defer { (XrayPanels.followOK, XrayPanels.follow, XrayPanels.probed) = (ok, follow, probed) }
        let fake = Fake()
        XrayPanels.followOK = { true }
        XrayPanels.follow = fake.follow
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: version)
        try await body(fake, XrayPanels())
    }

    /// A Terminal-mode (dch-chapters) panel, shown and live, its clock at `base`.
    func panel(_ panels: XrayPanels, clock: Clock = Clock(), tab: XrayTab = .tasks) -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayFollowTests.target("api"), tab: tab)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in XrayChaptersTests.base }
        p.fromDch = { true }
        p.panels = panels
        return p
    }

    func open(_ p: XrayPanelModel, _ run: @escaping XrayPanels.Run) async {
        p.read(dch: "/fake/dch", run: run)
        await p.reading?.value
    }

    func send(_ fake: Fake, _ lines: [String]) { for l in lines { fake.send(1, l) } }

    func tick(_ p: XrayPanelModel, _ clock: Clock, at s: TimeInterval) async {
        clock.t = XrayChaptersTests.base + s
        p.tick()
        await p.reading?.value
    }

    /// Red at base: XrayFollow.swift:167 `["--xray", name, "--follow", "--json"]` (no --tasks) and take() skips the
    /// block lines (`o["schema"] as? Int == 1 else { continue }`): the tabs keep the open read's 4 tasks and 1 memory.
    func testSnapshotAndBlocksFillTasksAndMemory() async throws {
        try await withFollow { fake, panels in
            let p = panel(panels)
            await open(p, XrayChaptersTests.Run().run)
            XCTAssertEqual(fake.args, [Self.withTasks])
            send(fake, [XrayFollowTests.snapshot()] + Self.blocks(tasks: ["1", "2"], memories: ["m1", "m2"]))
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["1", "2"])
            XCTAssertEqual(p.tasks?.partial, false, "the done line closed the block")
            XCTAssertEqual(p.memory?.items.map(\.id), ["m1", "m2"])
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertTrue(p.tabs.contains(.tasks) && p.tabs.contains(.memory))
            p.stop()
        }
    }

    /// Red with gone-ignored: m1 and task 1 stay after their `gone` deltas.
    func testTaskMemoryAndGoneDeltas() async throws {
        try await withFollow { fake, panels in
            let p = panel(panels)
            await open(p, XrayChaptersTests.Run().run)
            send(fake, [XrayFollowTests.snapshot()] + Self.blocks(tasks: ["1", "2"], memories: ["m1", "m2"]))
            fake.send(1, #"{"schema":1,"task":{"id":"2","title":"Task 2","status":"done"}}"#)
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["1", "2"], "a known id replaces its row")
            XCTAssertEqual(p.tasks?.tasks.last?.status, .done)
            fake.send(1, Self.task("3"))
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["1", "2", "3"], "a new id is added")
            fake.send(1, Self.memory("m3"))
            XCTAssertEqual(p.memory?.items.map(\.id), ["m1", "m2", "m3"])
            fake.send(1, #"{"schema":1,"memory":{"id":"m1","gone":true}}"#)
            XCTAssertEqual(p.memory?.items.map(\.id), ["m2", "m3"], "gone removes the memory")
            fake.send(1, #"{"task":{"id":"1","gone":true}}"#)
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["2", "3"], "gone removes the task")
            XCTAssertEqual(p.dchChapters?.count, 6, "the chapters are untouched")
            XCTAssertEqual(fake.args.count, 1, "no new process for a delta")
            p.stop()
        }
    }

    /// Red with block-appends: the second blocks add to the first (1, 2, 3 and m1, m2, m9).
    func testARepeatedBlockReplacesTheKeptOne() async throws {
        try await withFollow { fake, panels in
            let p = panel(panels)
            await open(p, XrayChaptersTests.Run().run)
            send(fake, [XrayFollowTests.snapshot()] + Self.blocks(tasks: ["1", "2"], memories: ["m1", "m2"]))
            send(fake, Self.blocks(tasks: ["3"], memories: ["m9"]))
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["3"])
            XCTAssertEqual(p.memory?.items.map(\.id), ["m9"])
            p.stop()
        }
    }

    /// #1631 (dch's sample of a live follow: 6522 of 8160 task lines in 90 s byte-equal to a held row; the ~1.3 MB
    /// tasks block sent whole again up to 4 times): a whole block equal to the held one and a row's own bytes again
    /// parse nothing and build no state; a changed row is one block parse; a changed whole block replaces the kept
    /// one; `gone` still removes. Red at base: XrayFollow.swift:209 marked each done line dirty and :219 each delta
    /// (blockParses 4 and applies 3 after the repeats, not 2 and 1).
    func testARepeatedBlockOrRowParsesNothing() {
        let f = XrayFollow(target: XrayFollowTests.target("api"))
        let lines = { (ls: [String]) in ls.map { Data($0.utf8) } }
        f.take(lines([XrayFollowTests.snapshot()] + Self.blocks(tasks: ["1", "2"], memories: ["m1"])))
        XCTAssertEqual(f.applies, 1)
        XCTAssertEqual(f.blockParses, 2)
        f.take(lines(Self.blocks(tasks: ["1", "2"], memories: ["m1"])))
        XCTAssertEqual(f.blockParses, 2, "the same blocks again: no parse")
        f.take(lines([Self.task("2"), Self.memory("m1")]))
        XCTAssertEqual(f.applies, 1, "the held rows' bytes again: no build")
        f.take(lines([Self.task("2", "done")]))
        XCTAssertEqual(f.applies, 2)
        XCTAssertEqual(f.blockParses, 3, "one changed row: one tasks parse, memory kept")
        XCTAssertEqual(f.state?.tasks?.tasks.last?.status, .done)
        f.take(lines(Self.blocks(tasks: ["1", "3"], memories: ["m1"])))
        XCTAssertEqual(f.blockParses, 4, "a changed tasks block replaces the kept one; the equal memory block is skipped")
        XCTAssertEqual(f.state?.tasks?.tasks.map(\.id), ["1", "3"])
        XCTAssertEqual(f.state?.memory?.items.map(\.id), ["m1"])
        f.take(lines([#"{"task":{"id":"1","gone":true}}"#]))
        XCTAssertEqual(f.state?.tasks?.tasks.map(\.id), ["3"], "gone removes")
        f.take(lines([XrayFollowTests.reset, XrayFollowTests.snapshot()] + Self.blocks(tasks: ["3"], memories: ["m1"])))
        XCTAssertEqual(f.state?.tasks?.tasks.map(\.id), ["3"], "after a reset the blocks come again and are shown")
        XCTAssertEqual(f.state?.memory?.items.map(\.id), ["m1"])
    }

    /// #1643 (QA r1 on #1642): Block.same compares the header too. The same task rows and done line resent under a header
    /// whose source changed (none -> command; the title is padded so both headers have the same byte length, which the
    /// `bytes` check cannot tell apart) are one more parse and the new source is shown. Red with head-ignored (the
    /// `head == o.head` term dropped from Block.same, XrayFollow.swift:47): blockParses stays 1 and the source stays nil.
    func testTheSameRowsUnderAHeaderWithAnotherSourceParseAgain() {
        let f = XrayFollow(target: XrayFollowTests.target("api"))
        let lines = { (ls: [String]) in ls.map { Data($0.utf8) } }
        let head = { (source: String, title: String) in
            #"{"schema":1,"session":"api","session_id":"s-1","source":"# + source + #","title":""# + title + #"","partial":false}"#
        }
        let (none, command) = (head("null", "Example Org api"), head(#""command""#, "Example Or"))
        XCTAssertEqual(none.utf8.count, command.utf8.count, "equal byte length: only the head comparison can tell them apart")
        let rows = ["1", "2"].map { Self.task($0) } + [Self.done]
        f.take(lines([XrayFollowTests.snapshot(), none] + rows))
        XCTAssertEqual(f.blockParses, 1)
        XCTAssertTrue(f.state?.tasks?.source == nil)
        f.take(lines([none] + rows))
        XCTAssertEqual(f.blockParses, 1, "the same header and rows again: no parse")
        f.take(lines([command] + rows))
        XCTAssertEqual(f.blockParses, 2, "a changed header is a changed block")
        XCTAssertEqual(f.state?.tasks?.source, "command")
        XCTAssertEqual(f.state?.tasks?.tasks.map(\.id), ["1", "2"])
    }

    /// dch 1.92.0: a reset why "range" with a tail snapshot and its blocks, then a reset why "full" with the whole
    /// snapshot and its blocks. Each reset drops the follow's state; the panel shows each snapshot's rows.
    /// Red with reset-keeps-old (the six chapters and the first blocks stay through the second reset).
    func testRangeThenFullResetReplacesTheStateEachTime() async throws {
        try await withFollow { fake, panels in
            let p = panel(panels)
            await open(p, XrayChaptersTests.Run().run)
            let tail = XrayFollowTests.snapshot(#"{"schema":1,"chapters":[{"anchor":"f3a41c:500","i":6,"title":"Continue the api work","kind":"prompt"}],"refs":[]}"#)
            send(fake, [#"{"schema":1,"reset":{"why":"range"}}"#, tail] + Self.blocks(tasks: ["2"], memories: ["m2"]))
            XCTAssertEqual(p.dchChapters?.count, 1)
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["2"])
            XCTAssertEqual(p.memory?.items.map(\.id), ["m2"])
            fake.send(1, #"{"schema":1,"reset":{"why":"full"}}"#)
            XCTAssertEqual(p.dchChapters?.count, 0, "reset drops the chapters")
            XCTAssertTrue(p.follow?.state?.tasks == nil && p.follow?.state?.memory == nil, "and the blocks")
            send(fake, [XrayFollowTests.snapshot()] + Self.blocks(tasks: ["1", "2"], memories: ["m1", "m2"]))
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["1", "2"])
            XCTAssertEqual(p.memory?.items.map(\.id), ["m1", "m2"])
            p.stop()
        }
    }

    /// Red with tasks-polled-while-following (XrayPoller.swift:34 at base polls Tasks every 5 s and Memory every 30 s
    /// beside the follow): tasksReads 2 at 5 s.
    func testNoTasksOrMemoryReadWhileTheFollowRunsOneAfterItEnds() async throws {
        try await withFollow { fake, panels in
            let run = XrayPollTests.PollRun(), clock = Clock()
            let p = panel(panels, clock: clock)
            await open(p, run.run)
            XCTAssertEqual(run.tasksReads, 1, "the open's read")
            send(fake, [XrayFollowTests.snapshot()] + Self.blocks(tasks: ["1", "2"], memories: ["m1", "m2"]))
            await tick(p, clock, at: 5)
            await tick(p, clock, at: 20)
            XCTAssertEqual(run.tasksReads, 1, "no Tasks poll beside the follow")
            p.select(.memory)
            await p.reading?.value
            await tick(p, clock, at: 40)
            XCTAssertEqual(run.memoryReads, 1, "no Memory read on the switch nor its poll")
            fake.end(1, 0)
            await tick(p, clock, at: 41)
            XCTAssertEqual(run.memoryReads, 2, "the follow ended: the Memory poll resumes")
            p.tab = .tasks
            await tick(p, clock, at: 46)
            XCTAssertEqual(run.tasksReads, 2, "and the Tasks poll")
            XCTAssertTrue(fake.stopped.isEmpty)
            p.stop()
        }
    }

    /// Red with no-old-dch-fallback: the refusal ends the follow (failed), so no second start and the open reads run again.
    func testAnOlderHostsRefusalFollowsAgainWithoutTasksOnce() async throws {
        try await withFollow { fake, panels in
            let run = XrayPollTests.PollRun(), clock = Clock()
            let p = panel(panels, clock: clock)
            await open(p, run.run)
            fake.end(1, XrayPanels.followTasksRefused)
            XCTAssertEqual(fake.args, [Self.withTasks, Self.plain], "started again without --tasks --memory")
            XCTAssertTrue(p.follow != nil, "the same follow, still attached")
            XCTAssertEqual(p.follow?.carriesTasks, false)
            XCTAssertEqual(run.tasksReads, 1, "no second open read")
            fake.send(2, XrayFollowTests.snapshot())
            XCTAssertEqual(p.dchChapters?.count, 6)
            await tick(p, clock, at: 5)
            XCTAssertEqual(run.tasksReads, 2, "Tasks stay on today's poll for that target")
            p.stop()
            let p2 = panel(panels, clock: clock)
            await open(p2, run.run)
            XCTAssertEqual(fake.args.count, 2, "the stored follow runs on: no third start")
            p2.stop()
        }
    }

    /// Red at base: no tasks gate, the argv has --tasks for every dch. dch 1.90.0 follows the chapters alone and the Tasks
    /// poll runs beside it.
    func testAnOlderDchBuildsNoTasksArgv() async throws {
        try await withFollow(dch: [1, 90, 0]) { fake, panels in
            let run = XrayPollTests.PollRun(), clock = Clock()
            let p = panel(panels, clock: clock)
            await open(p, run.run)
            XCTAssertEqual(fake.args, [Self.plain])
            fake.send(1, XrayFollowTests.snapshot())
            await tick(p, clock, at: 5)
            XCTAssertEqual(run.tasksReads, 2, "the Tasks poll runs")
            p.stop()
        }
    }

    /// The product's streamLines on /bin/sh fixtures in tempDir (never dch): exit 2 with the refusal on stderr is
    /// followTasksRefused; exit 2 with any other line stays 2. Red at base: stderr went to /dev/null, both are 2.
    func testStreamLinesTellsTheRefusalFromAnotherExit2() async throws {
        let dir = tempDir("xray-follow-refused")
        let refused = dir.appendingPathComponent("refused.sh"), other = dir.appendingPathComponent("other.sh")
        try "printf '%s\\n' 'dch: bad usage: --tasks and --follow' >&2\nexit 2\n".write(to: refused, atomically: true, encoding: .utf8)
        try "printf '%s\\n' 'dch: bad usage: --nope' >&2\nexit 2\n".write(to: other, atomically: true, encoding: .utf8)
        let a = await Task.detached { XrayPanels.streamLines(XrayChild(), "/bin/sh", [refused.path], [:]) { _ in } }.value
        let b = await Task.detached { XrayPanels.streamLines(XrayChild(), "/bin/sh", [other.path], [:]) { _ in } }.value
        XCTAssertEqual(a, XrayPanels.followTasksRefused)
        XCTAssertEqual(b, 2)
    }

    /// QA r1451 r1: the blocks' bytes count toward maxKept. A test-sized cap holds the snapshot and two task rows; a
    /// third row (a delta) passes it: the follow gets its SIGTERM and today's Tasks read runs.
    /// Red with blocks-not-counted (block bytes left out of pastCap): the snapshot alone is under the cap, nothing stops.
    func testBlocksPastTheByteCapFallBackToTheReads() async throws {
        let cap = XrayFollow.maxKept
        defer { XrayFollow.maxKept = cap }
        try await withFollow { fake, panels in
            let run = XrayPollTests.PollRun()
            let p = panel(panels)
            await open(p, run.run)
            let snap = XrayFollowTests.snapshot()
            let used = [snap, Self.tasksHeader, Self.task("1"), Self.task("2"), Self.done].reduce(0) { $0 + $1.utf8.count }
            XrayFollow.maxKept = used
            send(fake, [snap, Self.tasksHeader, Self.task("1"), Self.task("2"), Self.done])
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["1", "2"])
            XCTAssertTrue(p.follow != nil && fake.stopped.isEmpty, "at the cap: kept")
            XCTAssertEqual(run.tasksReads, 1)
            fake.send(1, Self.task("3"))
            XCTAssertEqual(fake.stopped, [1], "past the cap: SIGTERM")
            XCTAssertTrue(p.follow == nil)
            await p.reading?.value
            XCTAssertEqual(run.tasksReads, 2, "today's Tasks read runs")
            p.stop()
        }
    }

    /// QA r1451 s1: a block's row COUNT is capped (maxBlockRows, a test-sized 3 here; XrayTasks.maxRows in production).
    /// A new id past it ends the follow and today's reads run; a replaced id and a gone do not count.
    /// Red with block-rows-uncapped: the fourth task is kept and the follow runs on.
    func testBlockRowsPastTheRowCapFallBackToTheReads() async throws {
        let cap = XrayFollow.maxBlockRows
        defer { XrayFollow.maxBlockRows = cap }
        try await withFollow { fake, panels in
            let run = XrayPollTests.PollRun()
            let p = panel(panels)
            await open(p, run.run)
            XrayFollow.maxBlockRows = 3
            send(fake, [XrayFollowTests.snapshot()] + Self.blocks(tasks: ["1", "2", "3"], memories: ["m1"]))
            fake.send(1, Self.task("2", "done"))
            fake.send(1, #"{"task":{"id":"1","gone":true}}"#)
            fake.send(1, Self.task("4"))
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["2", "3", "4"], "at the cap: kept")
            XCTAssertTrue(p.follow != nil && fake.stopped.isEmpty)
            fake.send(1, Self.task("5"))
            XCTAssertEqual(fake.stopped, [1], "past the cap: SIGTERM")
            XCTAssertTrue(p.follow == nil)
            await p.reading?.value
            XCTAssertEqual(run.tasksReads, 2, "today's Tasks read runs")
            p.stop()
        }
    }

    /// The same cap on a memory block's own rows (the snapshot's blocks, before any delta).
    /// Red with block-rows-uncapped: four memory rows are kept.
    func testMemoryBlockPastTheRowCapFallsBack() async throws {
        let cap = XrayFollow.maxBlockRows
        defer { XrayFollow.maxBlockRows = cap }
        try await withFollow { fake, panels in
            let run = XrayPollTests.PollRun()
            let p = panel(panels)
            await open(p, run.run)
            XrayFollow.maxBlockRows = 3
            send(fake, [XrayFollowTests.snapshot()] + Self.blocks(tasks: ["1"], memories: ["m1", "m2", "m3", "m4"]))
            XCTAssertEqual(fake.stopped, [1])
            XCTAssertTrue(p.follow == nil)
            await p.reading?.value
            XCTAssertEqual(run.tasksReads, 2)
            p.stop()
        }
    }
}
