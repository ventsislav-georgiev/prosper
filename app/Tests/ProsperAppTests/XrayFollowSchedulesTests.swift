import XCTest
@testable import ProsperApp

/// #2014 (dch #686, 1.188.0): X-ray's Schedules tab from the follow's schedules block (`--follow --tasks --memory
/// --schedules --json`), through the XrayPanels.follow seam (XrayFollowTests.Fake) and a probed fake dch version. No dch,
/// no window, no key, no timer.
@MainActor
final class XrayFollowSchedulesTests: XCTestCase {
    typealias Fake = XrayFollowTests.Fake
    typealias T = XrayFollowTasksTests

    static let withSchedules = ["--xray", "api", "--follow", "--tasks", "--memory", "--schedules", "--json"]
    static let base = XrayChaptersTests.base

    static func iso(_ s: TimeInterval) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: base + s)
    }
    static func header(live: Bool = true, source: String = "claude") -> String {
        #"{"schema":1,"block":"schedules","session":"api","session_id":"s-1","source":""# + source + #"","live":"# + "\(live)" + #","title":null,"partial":false}"#
    }
    static func cron(_ id: String, status: String = "pending", next: TimeInterval = 600, prompt: String = "check CI") -> String {
        #"{"schedule":{"id":""# + id + #"","kind":"cron","status":""# + status + #"","recurring":true,"cron":"*/10 * * * *","human":"every 10 minutes","durable":false,"prompt":""# + prompt + #"","reason":null,"created":null,"next":""# + iso(next) + #"","last_fired":null,"expires":""# + iso(7 * 86400) + #"","fires":0}}"#
    }
    static func wakeup(status: String = "pending", next: TimeInterval = 90) -> String {
        #"{"schedule":{"id":"wakeup","kind":"wakeup","status":""# + status + #"","recurring":false,"cron":null,"human":"in 20m","durable":false,"prompt":"check again","next":""# + iso(next) + #"","expires":null,"fires":14}}"#
    }
    static let done = #"{"done":true,"count":2,"dropped":0}"#
    /// A tasks header in the 1.187.0 shape ("block":"tasks").
    static let tasksHeader = #"{"schema":1,"block":"tasks","session":"api","session_id":"s-1","source":"claude","title":"Example Org api","partial":false}"#
    static func schedules(_ rows: [String], live: Bool = true) -> [String] { [header(live: live)] + rows + [done] }

    func withFollow(dch version: [Int] = [1, 188, 0], _ body: (Fake, XrayPanels) async throws -> Void) async rethrows {
        let (ok, follow, probed) = (XrayPanels.followOK, XrayPanels.follow, XrayPanels.probed)
        defer { (XrayPanels.followOK, XrayPanels.follow, XrayPanels.probed) = (ok, follow, probed) }
        let fake = Fake()
        XrayPanels.followOK = { true }
        XrayPanels.follow = fake.follow
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: version)
        try await body(fake, XrayPanels())
    }

    func panel(_ panels: XrayPanels, clock: XrayFollowTests.Clock = .init()) async -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayFollowTests.target("api"), tab: .schedules)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in Self.base }
        p.fromDch = { true }
        p.panels = panels
        p.read(dch: "/fake/dch", run: XrayChaptersTests.Run().run)
        await p.reading?.value
        return p
    }

    func send(_ fake: Fake, _ lines: [String], to n: Int = 1) { for l in lines { fake.send(n, l) } }

    private func lines(_ ls: [String]) -> [Data] { ls.map { Data($0.utf8) } }

    /// Red with route-by-block removed (XrayFollow.swift:313 at base: `o["session"] != nil ? "task" : "memory"`): the
    /// schedules header carries `source` and `session`, so its block replaced the tasks block and no schedules came.
    func testSchedulesHeaderRoutesToItsBlockThoughItHasSourceAndSession() {
        let f = XrayFollow(target: XrayFollowTests.target("api"))
        f.take(lines([XrayFollowTests.snapshot(), Self.tasksHeader, T.task("1"), T.task("2"), Self.done]
                     + Self.schedules([Self.cron("c1"), Self.wakeup()])))
        XCTAssertEqual(f.state?.tasks?.tasks.map(\.id), ["1", "2"], "the tasks block is untouched")
        XCTAssertEqual(f.state?.schedules?.schedules.map(\.id), ["c1", "wakeup"])
        XCTAssertEqual(f.state?.schedules?.schedules.map(\.kind), [.cron, .wakeup])
        XCTAssertEqual(f.blockParses, 2, "one tasks parse, one schedules parse")
    }

    /// The old rule still holds for a header without "block" (a dch before 1.187.0): `session` is tasks, none memory.
    /// Red if blockKey read a header without "block" as no block at all (nil): no tasks, no memory.
    func testAnOldStyleHeaderWithoutBlockStillRoutesToTasksAndMemory() {
        let f = XrayFollow(target: XrayFollowTests.target("api"))
        f.take(lines([XrayFollowTests.snapshot()] + T.blocks(tasks: ["1"], memories: ["m1"])))
        XCTAssertEqual(f.state?.tasks?.tasks.map(\.id), ["1"])
        XCTAssertEqual(f.state?.memory?.items.map(\.id), ["m1"])
        XCTAssertTrue(f.state?.schedules == nil)
        XCTAssertEqual(XrayStateBuilder.blockKey(["source": "claude", "session": "api"]), "task")
        XCTAssertEqual(XrayStateBuilder.blockKey(["source": "claude"]), "memory")
        XCTAssertEqual(XrayStateBuilder.blockKey(["source": "claude", "session": "api", "block": "schedules"]), "schedule")
        XCTAssertTrue(XrayStateBuilder.blockKey(["source": "claude", "block": "later"]) == nil)
    }

    /// A full block, a changed row (in place, dch's order kept), a gone row; a row's own bytes again builds nothing; no
    /// new process for a delta. Red with the gone branch removed (XrayFollow takeBlockLine `if gone { b.rows.remove }`):
    /// c1 stays.
    func testFullBlockThenAChangedRowThenAGoneRow() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            XCTAssertEqual(fake.args, [Self.withSchedules])
            send(fake, [XrayFollowTests.snapshot()] + T.blocks(tasks: ["1"], memories: ["m1"])
                 + Self.schedules([Self.cron("c1"), Self.cron("c2", next: 1200), Self.wakeup()]))
            XCTAssertEqual(p.schedules?.schedules.map(\.id), ["c1", "c2", "wakeup"])
            XCTAssertEqual(p.count(.schedules), 3)
            XCTAssertTrue(p.tabs.contains(.schedules))
            let applies = p.follow?.applies ?? -1
            fake.send(1, Self.cron("c1"))
            XCTAssertEqual(p.follow?.applies, applies, "the held row's bytes again: no build")
            fake.send(1, Self.cron("c1", prompt: "check CI again"))
            XCTAssertEqual(p.schedules?.schedules.map(\.id), ["c1", "c2", "wakeup"], "the row changes in place")
            XCTAssertEqual(p.schedules?.schedules.first?.prompt, "check CI again")
            XCTAssertEqual(p.follow?.applies, applies + 1, "one delta, one build")
            fake.send(1, #"{"schedule":{"id":"c1","gone":true}}"#)
            XCTAssertEqual(p.schedules?.schedules.map(\.id), ["c2", "wakeup"], "gone removes the row")
            XCTAssertEqual(p.count(.schedules), 2)
            XCTAssertEqual(p.tasks?.tasks.map(\.id), ["1"], "tasks untouched")
            XCTAssertEqual(fake.args.count, 1, "no new process for a delta")
            p.stop()
        }
    }

    /// The agent left: the block again with live:false. dch marks the rows ended itself; Prosper does too, so a row
    /// still "pending" there reads ended, the count is 0 and the /loop marker goes. Red with the live:false mapping removed
    /// (XraySchedules.parse `if !r.live`): c1 and the wake-up stay pending, count 2.
    func testLiveFalseTurnsPendingRowsToEnded() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            send(fake, [XrayFollowTests.snapshot()] + T.blocks(tasks: ["1"], memories: ["m1"])
                 + Self.schedules([Self.cron("c1"), Self.cron("c0", status: "deleted"), Self.wakeup()]))
            XCTAssertEqual(p.count(.schedules), 2)
            send(fake, Self.schedules([Self.cron("c1"), Self.cron("c0", status: "deleted"), Self.wakeup()], live: false))
            XCTAssertEqual(p.schedules?.live, false)
            XCTAssertEqual(p.schedules?.schedules.map(\.status), ["ended", "deleted", "ended"])
            XCTAssertEqual(p.count(.schedules), 0)
            XCTAssertEqual(p.title(.schedules), "Schedules 0")
            XCTAssertTrue(p.schedules?.schedules.compactMap { XrayScheduleRow($0, now: Self.base).countdown }.isEmpty == true,
                          "an ended row has no countdown")
            p.stop()
        }
    }

    /// The countdown from `next` (90 s ahead: "in 1m 30s"; past: "due"), and for a wake-up with no `next`, from `expires`.
    /// Red if the countdown read seconds as minutes or dropped the past case.
    func testCountdownTextFor90sAndAPastNext() throws {
        XCTAssertEqual(XrayScheduleRow.countdown(Self.base + 90, now: Self.base), "in 1m 30s")
        XCTAssertEqual(XrayScheduleRow.countdown(Self.base - 5, now: Self.base), "due")
        XCTAssertEqual(XrayScheduleRow.countdown(Self.base + 45, now: Self.base), "in 45s")
        XCTAssertEqual(XrayScheduleRow.countdown(Self.base + 7500, now: Self.base), "in 2h 5m")
        XCTAssertEqual(XrayScheduleRow.countdown(Self.base + 1e15, now: Self.base), "in 11574d 1h", "a far date is bounded, never a trap")
        let s = XraySchedules.parse(lines(Self.schedules([Self.wakeup(next: 90)])))
        let w = try XCTUnwrap(s.schedules.first)
        XCTAssertEqual(XrayScheduleRow(w, now: Self.base).countdown, "in 1m 30s")
        XCTAssertEqual(XrayScheduleRow(w, now: Self.base + 100).countdown, "due")
        var e = w; e.next = nil; e.expires = Self.base + 60
        XCTAssertEqual(XrayScheduleRow(e, now: Self.base).countdown, "in 1m")
        XCTAssertEqual(XrayScheduleRow(w, now: Self.base).kind, "wake-up")
    }

    /// The countdowns move with the panel's own ticker: one redraw per second only while a row is due within the hour,
    /// none for the ticks inside the same second; per minute otherwise. Red if schedulesTick sent on every tick (3, not 1).
    func testCountdownRedrawsOnThePanelTickOnlyWhenItsClockMoves() async throws {
        await withFollow { fake, panels in
            let clock = XrayFollowTests.Clock()
            let p = await panel(panels, clock: clock)
            send(fake, [XrayFollowTests.snapshot()] + Self.schedules([Self.wakeup(next: 90)]))
            p.tab = .schedules
            let r0 = p.schedulesRedraws
            for _ in 0..<3 { p.tick() }
            XCTAssertEqual(p.schedulesRedraws, r0 + 1, "one redraw for one second")
            clock.t = Self.base + 1
            p.tick()
            XCTAssertEqual(p.schedulesRedraws, r0 + 2)
            send(fake, Self.schedules([Self.cron("c1", next: 7200)]))
            clock.t = Self.base + 2; p.tick()
            let r1 = p.schedulesRedraws
            clock.t = Self.base + 3; p.tick()
            XCTAssertEqual(p.schedulesRedraws, r1, "no row due within the hour: the minute clock, no redraw per second")
            XCTAssertEqual(fake.args.count, 1, "no process for a tick")
            p.stop()
        }
    }

    /// The /loop marker on a pending wake-up (title and VoiceOver) and none once it is gone. Red if loopActive ignored the
    /// status or the gone row stayed.
    func testLoopMarkerOnAPendingWakeupAndNoneAfterItIsGone() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            send(fake, [XrayFollowTests.snapshot()] + Self.schedules([Self.cron("c1"), Self.wakeup()]))
            XCTAssertEqual(p.title(.schedules), "Schedules 2 \u{21BB}")
            XCTAssertEqual(p.spoken(.schedules), "Schedules, 2 pending, loop active")
            fake.send(1, #"{"schedule":{"id":"wakeup","gone":true}}"#)
            XCTAssertEqual(p.title(.schedules), "Schedules 1")
            XCTAssertEqual(p.spoken(.schedules), "Schedules, 1 pending")
            p.stop()
        }
    }

    /// Red with the version gate removed (`withSchedules = !schedulesRefused`): dch 1.187.0 gets --schedules too.
    func testArgvCarriesSchedulesOnlyFrom1188() async throws {
        XCTAssertEqual(XrayFollow.schedulesDch, [1, 188, 0])
        await withFollow(dch: [1, 187, 0]) { fake, panels in
            let p = await panel(panels)
            XCTAssertEqual(fake.args, [T.withTasks])
            p.stop()
        }
        await withFollow(dch: [1, 188, 0]) { fake, panels in
            let p = await panel(panels)
            XCTAssertEqual(fake.args, [Self.withSchedules])
            p.stop()
        }
    }

    /// No schedules block (a shell's source "none", or none sent): no tab, and the chapters, tasks and memory go on.
    func testChaptersKeepWorkingWhenTheSchedulesBlockIsAbsent() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            send(fake, [XrayFollowTests.snapshot()] + T.blocks(tasks: ["1"], memories: ["m1"]))
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertFalse(p.tabs.contains(.schedules))
            XCTAssertTrue(p.tabs.contains(.prompts) && p.tabs.contains(.tasks))
            send(fake, [Self.header(source: "none"), Self.done])
            XCTAssertFalse(p.tabs.contains(.schedules), "a shell has no Schedules tab")
            fake.send(1, XrayFollowTests.chapter7)
            XCTAssertEqual(p.dchChapters?.count, 7)
            p.stop()
        }
    }

    /// A host's older dch answers `--follow --schedules` with exit 2 before any snapshot: the follow starts again without
    /// it (once), the chapters come, and the Schedules tab says "needs dch 1.188.0". Red with that restart removed: the
    /// follow fails (no second start), no note.
    func testExitTwoShowsNeedsDchOnSchedulesAndChaptersGoOn() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            fake.end(1, 2)
            XCTAssertEqual(fake.args, [Self.withSchedules, T.withTasks], "again without --schedules")
            XCTAssertTrue(p.follow != nil, "the same follow, still attached")
            send(fake, [XrayFollowTests.snapshot()] + T.blocks(tasks: ["1"], memories: ["m1"]), to: 2)
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertEqual(p.schedulesNote, "needs dch 1.188.0")
            XCTAssertTrue(p.tabs.contains(.schedules) && p.tabs.contains(.prompts))
            XCTAssertEqual(p.count(.schedules), 0)
            fake.end(2, 2)
            XCTAssertEqual(fake.args.count, 2, "once: a second exit 2 after a snapshot starts nothing")
            p.stop()
        }
    }

    /// #2035 n1: a pending cron whose `next` passed reads "due" for good: the minute clock, no redraw per second. Red with
    /// the `0 <` bound removed (XraySchedules scheduleClock): every tick of the five moves the clock (5 redraws, not 0).
    func testAnOverduePendingRowKeepsNoPerSecondClock() async throws {
        await withFollow { fake, panels in
            let clock = XrayFollowTests.Clock()
            let p = await panel(panels, clock: clock)
            send(fake, [XrayFollowTests.snapshot()] + Self.schedules([Self.cron("c1", next: -30)]))
            p.tab = .schedules
            p.tick()
            let r0 = p.schedulesRedraws
            for s in 1...5 { clock.t = Self.base + TimeInterval(s); p.tick() }
            XCTAssertEqual(p.schedulesRedraws, r0, "inside one minute: no redraw for an overdue row")
            p.stop()
        }
    }

    /// #2035 n2: an agent session whose schedules block has no rows has no tab (tasksTab's rule: an empty block is nil,
    /// also when a block empties while shown). Red with the `!s.schedules.isEmpty` test removed (schedulesTab).
    func testAnEmptyBlockForAClaudeSessionShowsNoTab() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            send(fake, [XrayFollowTests.snapshot()] + Self.schedules([]))
            XCTAssertTrue(p.schedules == nil)
            XCTAssertFalse(p.tabs.contains(.schedules))
            send(fake, Self.schedules([Self.cron("c1")]))
            XCTAssertTrue(p.tabs.contains(.schedules))
            fake.send(1, #"{"schedule":{"id":"c1","gone":true}}"#)
            XCTAssertFalse(p.tabs.contains(.schedules), "the last row gone: the tab goes")
            p.stop()
        }
    }

    static let shellSnapshot = XrayFollowTests.snapshot(
        XrayChaptersTests.json.replacingOccurrences(of: #""corpus":"claude""#, with: #""corpus":"shell""#))

    /// #2035 n3: a shell on a host before 1.188.0 gets no tab and no note. Red with the agent-only test removed
    /// (XrayPanel takeFollow `c == "claude" || c == "codex"`): the note and the tab show.
    func testAShellOnAnOlderHostGetsNoTabAndNoNote() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            fake.end(1, 2)
            send(fake, [Self.shellSnapshot] + T.blocks(tasks: ["1"], memories: ["m1"]), to: 2)
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertTrue(p.schedulesNote == nil)
            XCTAssertFalse(p.tabs.contains(.schedules))
            p.stop()
        }
    }

    /// #2035 n3: the agent's session (the snapshot's corpus codex) gets the note and the tab, as before.
    func testACodexSessionOnAnOlderHostGetsTheNoteAndTheTab() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            fake.end(1, 2)
            send(fake, [XrayFollowTests.snapshot(XrayChaptersTests.json.replacingOccurrences(of: #""corpus":"claude""#, with: #""corpus":"codex""#))]
                 + T.blocks(tasks: ["1"], memories: ["m1"]), to: 2)
            XCTAssertEqual(p.schedulesNote, "needs dch 1.188.0")
            XCTAssertTrue(p.tabs.contains(.schedules))
            p.stop()
        }
    }

    /// #2035 n4: the tasks refusal (a host before 1.91) restarts once with neither flag. Red with the
    /// `tasksRefused = true` line removed from finish (XrayFollow): a second restart, with --tasks.
    func testATasksRefusalRestartsOnceWithNeitherFlag() async throws {
        await withFollow { fake, panels in
            let p = await panel(panels)
            fake.end(1, XrayPanels.followTasksRefused)
            XCTAssertEqual(fake.args, [Self.withSchedules, T.plain], "one restart, neither --schedules nor --tasks")
            p.stop()
        }
    }
}
