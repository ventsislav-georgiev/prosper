import Combine
import XCTest
@testable import ProsperApp

/// #1475 (dch #445 phase 1): X-ray's chapters and refs from one `dch --xray <n> --follow --json` per target, through
/// the XrayPanels.follow seam. A fake stream records each start (argv) and each stop (the SIGTERM) and hands lines in by
/// hand; Tasks and Memory go to the fake runners of the neighbouring rows. No dch, no process, no signal, no window.
@MainActor
final class XrayFollowTests: XCTestCase {

    /// The fake follow: each start's argv and its line and end sinks; the starts (1-based) whose stop was called.
    @MainActor final class Fake {
        var args: [[String]] = []
        var stopped: [Int] = []
        private var sinks: [(lines: @Sendable ([Data]) -> Void, ended: @MainActor @Sendable (Int32) -> Void)] = []

        var follow: XrayPanels.Follow {
            { [self] _, a, _, lines, ended in
                args.append(a)
                sinks.append((lines, ended))
                let n = args.count
                return { [self] in stopped.append(n) }
            }
        }

        /// One batch to start `n`.
        func send(_ n: Int, _ lines: String...) {
            guard let s = sinks.dropFirst(n - 1).first else { return XCTFail("no follow \(n)") }
            s.lines(lines.map { Data($0.utf8) })
        }

        func end(_ n: Int, _ status: Int32) {
            guard let s = sinks.dropFirst(n - 1).first else { return XCTFail("no follow \(n)") }
            s.ended(status)
        }
    }

    final class Clock { var t = XrayChaptersTests.base }

    static func snapshot(_ json: String = XrayChaptersTests.json) -> String { #"{"schema":1,"snapshot":"# + json + "}" }
    /// A prompt newer than the snapshot: the one m2 of XrayChapterCardTests.memory names.
    static let chapter7 = #"{"schema":1,"chapter":{"anchor":"f3a41c:900","offset":900,"i":7,"title":"Ship the api fix","kind":"prompt","response":"Shipped"}}"#
    static let reset = #"{"schema":1,"reset":{"why":"rotated"}}"#

    static func target(_ name: String) -> XrayTarget {
        name.contains(":") ? XrayTarget(name: name, dir: nil) : XrayTarget(name: name, dir: "/tmp/dch-test")
    }

    /// The seams set for the body and put back after it.
    func withFollow(_ body: (Fake, XrayPanels) async throws -> Void) async rethrows {
        let (ok, follow) = (XrayPanels.followOK, XrayPanels.follow)
        defer { (XrayPanels.followOK, XrayPanels.follow) = (ok, follow) }
        let fake = Fake()
        XrayPanels.followOK = { true }
        XrayPanels.follow = fake.follow
        try await body(fake, XrayPanels())
    }

    /// A Terminal-mode (dch-chapters) panel, shown and live, its clock at `base`.
    func panel(_ panels: XrayPanels, _ name: String = "api", clock: Clock = Clock(), tab: XrayTab = .prompts) -> XrayPanelModel {
        let p = XrayPanelModel(target: Self.target(name), tab: tab)
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

    func tick(_ p: XrayPanelModel, _ clock: Clock, at s: TimeInterval) async {
        clock.t = XrayChaptersTests.base + s
        p.tick()
        await p.reading?.value
    }

    /// Red at base: readBoth's third read (XrayPanel.swift:291, `target.chaptersArgs`) and no follow at all.
    func testSnapshotFillsTheTabsAndADeltaNeedsNoNewProcess() async throws {
        try await withFollow { fake, panels in
            let run = XrayChaptersTests.Run()
            let p = panel(panels)
            await open(p, run.run)
            XCTAssertEqual(fake.args, [["--xray", "api", "--follow", "--json"]])
            XCTAssertEqual(run.chapterReads, 0, "the follow carries the chapters: no chapters read on open")
            XCTAssertFalse(p.loaded, "a cold open reads until the first snapshot")
            fake.send(1, Self.snapshot())
            XCTAssertTrue(p.loaded)
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertEqual(p.tab, .prompts)
            fake.send(1, Self.chapter7)
            XCTAssertEqual(p.dchChapters?.count, 7)
            XCTAssertEqual(p.dchChapters?.last?.title, "Ship the api fix")
            fake.send(1, #"{"schema":1,"chapter":{"anchor":"f3a41c:500","i":6,"title":"Continue the api work","kind":"prompt","error":true}}"#)
            XCTAssertEqual(p.dchChapters?.count, 7, "a known anchor replaces its chapter")
            XCTAssertEqual(p.dchChapters?.first { $0.ordinal == 6 }?.hasError, true)
            XCTAssertEqual(fake.args.count, 1, "no new process for a delta")
            XCTAssertEqual(run.chapterReads, 0)
            p.stop()
        }
    }

    /// Red with reset-keeps-old: the six chapters stay through the reset.
    func testResetClearsThenTheSnapshotRefills() async throws {
        try await withFollow { fake, panels in
            let p = panel(panels)
            await open(p, XrayChaptersTests.Run().run)
            fake.send(1, Self.snapshot())
            XCTAssertEqual(p.dchChapters?.count, 6)
            fake.send(1, Self.reset)
            XCTAssertEqual(p.dchChapters?.count, 0, "reset drops everything")
            XCTAssertTrue(p.chapterAnchors.isEmpty)
            fake.send(1, Self.snapshot(#"{"schema":1,"chapters":[{"anchor":"f9:0","i":1,"title":"After the clear","kind":"prompt"}],"refs":[]}"#))
            XCTAssertEqual(p.dchChapters?.map(\.title), ["After the clear"])
            XCTAssertEqual(p.chapterAnchors, ["f9:0": 1])
            p.stop()
        }
    }

    /// Red at base: no store, a new panel is "Reading" until its own read answers. Red with cache-dropped-on-close.
    func testReopenShowsTheStoredRowsBeforeTheSlowReadAnswers() async throws {
        try await withFollow { fake, panels in
            let run = XrayPollTests.PollRun()
            let p1 = panel(panels)
            await open(p1, run.run)
            fake.send(1, Self.snapshot())
            p1.stop()
            run.hold = true
            let p2 = panel(panels)
            p2.read(dch: "/fake/dch", run: run.run)
            XCTAssertTrue(p2.loaded, "rows on the first frame, before the fake answers Tasks or Memory")
            XCTAssertEqual(p2.dchChapters?.count, 6)
            XCTAssertEqual(fake.args.count, 1, "the stored follow: no new process")
            XCTAssertTrue(fake.stopped.isEmpty, "closing the panel did not end the follow")
            XCTAssertTrue(run.calls.allSatisfy { $0.contains("--tasks") || $0.contains("--memory") }, "no chapters read")
            let reading = p2.reading
            p2.stop()
            await reading?.value
        }
    }

    /// Red at base: XrayPollTests' hidden rule cancelled the only read; there was nothing to keep.
    func testHiddenKeepsTheFollowLive() async throws {
        try await withFollow { fake, panels in
            let clock = Clock()
            let p = panel(panels, clock: clock)
            await open(p, XrayChaptersTests.Run().run)
            fake.send(1, Self.snapshot())
            p.paneState = { (false, true) }
            await tick(p, clock, at: 10)
            p.isCurrent = { false }
            await tick(p, clock, at: 20)
            XCTAssertTrue(fake.stopped.isEmpty, "hidden: the follow keeps running")
            XCTAssertEqual(panels.follows.follows.first?.running, true)
            fake.send(1, Self.chapter7)
            XCTAssertEqual(p.dchChapters?.count, 7, "still live while hidden")
            p.stop()
        }
    }

    /// Red with no-evict: four follows, none stopped.
    func testFourthTargetEvictsTheOldestUnshown() async throws {
        try await withFollow { fake, panels in
            let run = XrayChaptersTests.Run()
            for name in ["api", "web", "docs", "ops"] {
                let p = panel(panels, name)
                await open(p, run.run)
                p.stop()
            }
            XCTAssertEqual(fake.stopped, [1], "the oldest got its SIGTERM")
            XCTAssertEqual(panels.follows.follows.map(\.target.name), ["web", "docs", "ops"])
            // three shown at once: a fourth gets no follow, and reads as today
            let shown = XrayPanels()
            var kept: [XrayPanelModel] = []
            for name in ["api", "web", "docs"] {
                let p = panel(shown, name)
                await open(p, run.run)
                kept.append(p)
            }
            let before = run.chapterReads
            let p4 = panel(shown, "ops")
            await open(p4, run.run)
            XCTAssertTrue(p4.follow == nil)
            XCTAssertEqual(shown.follows.follows.count, 3)
            XCTAssertEqual(run.chapterReads, before + 1, "the fourth panel's own chapters read")
            XCTAssertEqual(fake.stopped, [1], "a shown follow is never evicted")
            (kept + [p4]).forEach { $0.stop() }
        }
    }

    /// Red with no-evict: a third remote follow starts.
    func testAThirdRemoteFollowIsNeverOpened() async throws {
        try await withFollow { fake, panels in
            let run = XrayChaptersTests.Run()
            let p1 = panel(panels, "example-host:api"), p2 = panel(panels, "example-host:web")
            await open(p1, run.run)
            await open(p2, run.run)
            let p3 = panel(panels, "example-host:docs")
            await open(p3, run.run)
            XCTAssertTrue(p3.follow == nil, "both remote follows shown: the third reads as today")
            XCTAssertEqual(fake.args.count, 2)
            p3.stop()
            p1.stop()
            let p4 = panel(panels, "example-host:docs")
            await open(p4, run.run)
            XCTAssertEqual(fake.stopped, [1], "the oldest unshown remote follow ends first")
            XCTAssertEqual(panels.follows.follows.filter { $0.target.dir == nil }.count, 2)
            XCTAssertEqual(fake.args.last, ["--xray", "example-host:docs", "--follow", "--json"])
            [p2, p4].forEach { $0.stop() }
        }
    }

    /// Below the follow gate the open read and the 5 s chapters poll run as before.
    func testBelowTheGateThePollsStay() async throws {
        try await withFollow { fake, panels in
            XrayPanels.followOK = { false }
            let run = XrayChaptersTests.Run(), clock = Clock()
            let p = panel(panels, clock: clock)
            await open(p, run.run)
            XCTAssertTrue(fake.args.isEmpty)
            XCTAssertEqual(run.chapterReads, 1)
            XCTAssertEqual(p.dchChapters?.count, 6)
            await tick(p, clock, at: 5)
            XCTAssertEqual(run.chapterReads, 2, "today's 5 s poll")
            p.stop()
        }
    }

    /// An older host's dch exits 2 before any snapshot: the panel falls back to today's read.
    func testExitBeforeASnapshotFallsBack() async throws {
        try await withFollow { fake, panels in
            let run = XrayChaptersTests.Run()
            let p = panel(panels)
            await open(p, run.run)
            fake.end(1, 2)
            await p.reading?.value
            XCTAssertTrue(p.follow == nil)
            XCTAssertTrue(panels.follows.follows.isEmpty)
            XCTAssertEqual(run.chapterReads, 1)
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertTrue(p.loaded)
            p.stop()
        }
    }

    /// A follow that never sends its snapshot (a hung ssh, a stalled dch) is bounded as today's read is: past
    /// DchCommand.remoteTimeout from the attach it ends and the chapters read runs. Red with no-snapshot-bound (Reading forever).
    func testNoSnapshotWithinTheBoundFallsBack() async throws {
        try await withFollow { fake, panels in
            let run = XrayChaptersTests.Run(), clock = Clock()
            let p = panel(panels, clock: clock)
            await open(p, run.run)
            await tick(p, clock, at: DchCommand.remoteTimeout - 1)
            XCTAssertEqual(run.chapterReads, 0, "before the bound: no chapters read")
            XCTAssertFalse(p.loaded)
            XCTAssertTrue(fake.stopped.isEmpty)
            await tick(p, clock, at: DchCommand.remoteTimeout + 1)
            XCTAssertEqual(run.chapterReads, 1, "past the bound: today's chapters read")
            XCTAssertTrue(p.loaded)
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertTrue(p.follow == nil)
            XCTAssertEqual(fake.stopped, [1], "the stalled follow got its SIGTERM")
            XCTAssertTrue(panels.follows.follows.isEmpty, "and left the LRU")
            p.stop()
        }
    }

    /// dch ends the follow when the session ends: the rows stay, nothing is signalled; a reopen follows again.
    func testSessionEndKeepsTheRows() async throws {
        try await withFollow { fake, panels in
            let p = panel(panels)
            await open(p, XrayChaptersTests.Run().run)
            fake.send(1, Self.snapshot())
            fake.end(1, 0)
            XCTAssertTrue(fake.stopped.isEmpty)
            XCTAssertEqual(panels.follows.follows.first?.running, false)
            XCTAssertEqual(p.dchChapters?.count, 6)
            p.stop()
            let p2 = panel(panels)
            p2.read(dch: "/fake/dch", run: XrayChaptersTests.Run().run)
            XCTAssertTrue(p2.loaded, "the ended session's rows at once")
            XCTAssertEqual(fake.args.count, 2, "read again for the reopen")
            await p2.reading?.value
            p2.stop()
        }
    }

    /// Red with poll-still-runs: the 5 s chapters poll runs beside the follow.
    func testNoChaptersPollWhileAFollowRuns() async throws {
        try await withFollow { fake, panels in
            let run = XrayChaptersTests.Run(), clock = Clock()
            let p = panel(panels, clock: clock)
            await open(p, run.run)
            fake.send(1, Self.snapshot())
            await tick(p, clock, at: 5)
            await tick(p, clock, at: 10)
            await tick(p, clock, at: 40)
            XCTAssertEqual(run.chapterReads, 0)
            p.tab = .tasks
            await tick(p, clock, at: 50)
            XCTAssertEqual(run.calls.filter { $0.contains("--tasks") }.count, 2, "Tasks keeps its poll")
            XCTAssertEqual(run.chapterReads, 0)
            p.stop()
        }
    }

    /// Red at base: chapterAnchors came from the open read alone (the #1472 shortcut at XrayPanel.swift:224).
    func testReadThePromptFindsAChapterThatCameAfterTheOpen() async throws {
        try await withFollow { fake, panels in
            let run = XrayPollTests.PollRun()
            run.memory = (0, XrayChapterCardTests.memory)
            let p = panel(panels)
            p.present = { _, _ in }
            await open(p, run.run)
            fake.send(1, Self.snapshot())
            let m2 = try XCTUnwrap(p.memory?.items.first { $0.id == "m2" })
            p.readPrompt(m2)
            XCTAssertEqual(p.memoryCard, m2, "not read yet: the memory card")
            fake.send(1, Self.chapter7)
            p.readPrompt(m2)
            XCTAssertEqual(p.chapterCard?.ordinal, 7, "the chapter that came after the open")
            p.stop()
        }
        // the poll's read keeps anchors too
        let q = XrayPanelModel(target: Self.target("api"), tab: .prompts)
        q.takeChapters((0, Data(#"{"schema":1,"chapters":[{"anchor":"f3a41c:900","i":7,"title":"Ship","kind":"prompt"}]}"#.utf8)))
        XCTAssertEqual(q.chapterAnchors, ["f3a41c:900": 7])
    }

    /// The state's deltas: ref by key (count 0 removes), evict by offset, a delta before any snapshot or of another
    /// schema dropped.
    func testRefAndEvictDeltas() {
        let f = XrayFollow(target: Self.target("api"))
        f.take([Data(Self.chapter7.utf8)])
        XCTAssertTrue(f.state == nil, "no snapshot yet: nothing to apply to")
        f.take([Data(Self.snapshot(#"""
        {"schema":1,"chapters":[{"anchor":"s:10","offset":10,"i":1,"title":"one","kind":"prompt"},\#
        {"anchor":"s:20","offset":20,"i":2,"title":"two","kind":"prompt"}],\#
        "refs":[{"key":"issue:#12","shape":"issue","text":"#12","count":2}],"dropped_keys":0}
        """#).utf8)])
        XCTAssertEqual(f.state?.refs?.entries.map(\.count), [2])
        f.take(["{\"schema\":1,\"ref\":{\"key\":\"issue:#12\",\"shape\":\"issue\",\"text\":\"#12\",\"count\":3}}",
                "{\"schema\":1,\"ref\":{\"key\":\"pull:#7\",\"shape\":\"pull\",\"text\":\"#7\",\"count\":1}}"].map { Data($0.utf8) })
        XCTAssertEqual(f.state?.refs?.entries.map(\.key), ["issue:#12", "pull:#7"])
        XCTAssertEqual(f.state?.refs?.entries.first?.count, 3)
        f.take([Data("{\"schema\":1,\"ref\":{\"key\":\"issue:#12\",\"text\":\"#12\",\"count\":0}}".utf8)])
        XCTAssertEqual(f.state?.refs?.entries.map(\.key), ["pull:#7"])
        f.take([Data("{\"schema\":1,\"evict\":{\"seq\":15}}".utf8), Data("{\"schema\":2,\"reset\":{}}".utf8)])
        XCTAssertEqual(f.state?.chapters?.map(\.title), ["two"])
        XCTAssertEqual(f.state?.anchors, ["s:20": 2])
    }

    /// QA r1436 s1: the follow's object is bounded as one read is. Replaced lines and a new snapshot do not add up;
    /// a new chapter past XrayFollow.maxKept (a test-sized cap here) ends the follow and today's chapters read runs.
    /// Red with follow-bytes-unbounded: the follow keeps the seventh chapter and nothing is stopped or read.
    func testObjectPastTheCapFallsBackToTheReads() async throws {
        let cap = XrayFollow.maxKept
        defer { XrayFollow.maxKept = cap }
        try await withFollow { fake, panels in
            let run = XrayChaptersTests.Run()
            let p = panel(panels)
            await open(p, run.run)
            let snap = Self.snapshot()
            XrayFollow.maxKept = snap.utf8.count + 2 * Self.chapter7.utf8.count
            fake.send(1, snap)
            for _ in 0..<5 { fake.send(1, Self.chapter7) }   // one anchor: each line replaces the last
            XCTAssertEqual(p.dchChapters?.count, 7)
            XCTAssertTrue(p.follow != nil, "a replaced chapter's bytes are subtracted")
            fake.send(1, snap)   // the count starts again at a snapshot
            fake.send(1, Self.chapter7, Self.chapter7)
            XCTAssertTrue(p.follow != nil, "a snapshot resets the count")
            XCTAssertTrue(fake.stopped.isEmpty)
            let big = String(repeating: "x", count: 2 * Self.chapter7.utf8.count)
            fake.send(1, #"{"schema":1,"chapter":{"anchor":"f3a41c:950","offset":950,"i":8,"title":""# + big + #"","kind":"prompt"}}"#)
            XCTAssertEqual(fake.stopped, [1], "past the cap: the follow got its SIGTERM")
            XCTAssertTrue(p.follow == nil)
            XCTAssertTrue(panels.follows.follows.isEmpty, "and left the LRU")
            await p.reading?.value
            XCTAssertEqual(run.chapterReads, 1, "today's chapters read instead")
            XCTAssertEqual(p.dchChapters?.count, 6)
            XCTAssertTrue(p.loaded)
            p.stop()
        }
    }

    /// QA r1436 s2: a follow that ends after its snapshot while the panel is shown and live (a dropped link, a serve
    /// restart, serve evicting it) keeps its rows and the 5 s chapters poll resumes, so Prompts and Responses update
    /// again; #1475 c (QA r1446 i2): and the 30 s Refs poll (the same `follow == nil` gate, XrayPoller.swift:33).
    /// Red with ended-follow-frozen: `follow` stays set and no chapters read ever runs.
    func testAFollowEndedAfterItsSnapshotLetsThePollsResume() async throws {
        let gate = XrayPanels.refsTab
        defer { XrayPanels.refsTab = gate }
        XrayPanels.refsTab = { true }
        try await withFollow { fake, panels in
            let run = XrayChaptersTests.Run(), clock = Clock()
            let p = panel(panels, clock: clock)
            await open(p, run.run)
            fake.send(1, Self.snapshot(#"{"schema":1,"chapters":[{"anchor":"f9:0","i":1,"title":"Before the drop","kind":"prompt"}],"refs":[]}"#))
            fake.end(1, 1)
            await tick(p, clock, at: 1)
            XCTAssertEqual(p.dchChapters?.map(\.title), ["Before the drop"], "the rows stay")
            XCTAssertEqual(run.chapterReads, 0, "not before the interval")
            await tick(p, clock, at: 5)
            XCTAssertEqual(run.chapterReads, 1, "the 5 s poll resumes")
            XCTAssertEqual(p.dchChapters?.count, 6, "Prompts update again")
            await tick(p, clock, at: 10)
            XCTAssertEqual(run.chapterReads, 2, "and the next")
            p.tab = .refs
            await tick(p, clock, at: 39)
            XCTAssertEqual(run.chapterReads, 2, "Refs: not before its 30 s")
            await tick(p, clock, at: 40)
            XCTAssertEqual(run.chapterReads, 3, "and the Refs poll resumes")
            XCTAssertTrue(p.refs != nil)
            XCTAssertTrue(fake.stopped.isEmpty)
            XCTAssertEqual(fake.args.count, 1, "the polls, no restart")
            p.stop()
        }
    }

    /// QA r1436 s3: the product's streamLines on a /bin/sh fixture in tempDir (never dch). A snapshot and one delta
    /// written in two parts (the second only after the first batch landed) come out as two batches of whole lines,
    /// then exit 0. Red if the splitter emitted the partial line or dropped the tail.
    func testStreamLinesJoinsADeltaSplitAcrossTwoWrites() async throws {
        let dir = tempDir("xray-follow-stream")
        let script = dir.appendingPathComponent("fake-follow.sh"), go = dir.appendingPathComponent("go")
        let snap = Self.snapshot(#"{"schema":1,"chapters":[],"refs":[]}"#), delta = Self.chapter7
        let half = delta.index(delta.startIndex, offsetBy: 40)
        try """
        printf '%s\\n%s' '\(snap)' '\(delta[..<half])'
        i=0; while [ ! -e "$D/go" ] && [ $i -lt 100 ]; do /bin/sleep 0.1; i=$((i+1)); done
        printf '%s\\n' '\(delta[half...])'
        exit 0

        """.write(to: script, atomically: true, encoding: .utf8)
        let got = XrayBatches()
        let status = await Task.detached {
            XrayPanels.streamLines(XrayChild(), "/bin/sh", [script.path], ["D": dir.path]) { b in
                got.add(b)
                FileManager.default.createFile(atPath: go.path, contents: nil)
            }
        }.value
        XCTAssertEqual(status, 0)
        XCTAssertEqual(got.all, [[Data(snap.utf8)], [Data(delta.utf8)]])
    }

    /// QA r1436 s3: a line past the (test-sized) cap ends the stream: the child gets its SIGTERM long before its sleep
    /// ends, and no batch is sent. Red with line-cap-dropped: status 0 after the 20 s sleep.
    func testStreamLinesEndsALinePastTheCap() async throws {
        let dir = tempDir("xray-follow-cap")
        let script = dir.appendingPathComponent("fake-follow.sh")
        try "printf '%s' 0123456789abcdef\nexec /bin/sleep 20\n".write(to: script, atomically: true, encoding: .utf8)
        let got = XrayBatches(), t0 = Date()
        let status = await Task.detached {
            XrayPanels.streamLines(XrayChild(), "/bin/sh", [script.path], [:], cap: 8) { got.add($0) }
        }.value
        XCTAssertEqual(status, SIGTERM, "the child got its SIGTERM")
        XCTAssertTrue(got.all.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15, "ended by the signal, not by the sleep")
    }

    func testLineSplit() {
        var s = XrayLineSplit()
        XCTAssertEqual(s.take(Data("a\nb".utf8)), [Data("a".utf8)])
        XCTAssertEqual(s.take(Data("c\n\n".utf8)), [Data("bc".utf8)])
        var t = XrayLineSplit()
        t.cap = 4
        XCTAssertEqual(t.take(Data("1234".utf8)), [])
        XCTAssertTrue(t.take(Data("5".utf8)) == nil, "a line past the cap ends the stream")
    }

    /// #1629 (sample2: 90% of main in take's whole-state rebuild, 48% in XrayRefs.parse): a big snapshot (2000 refs),
    /// then a burst of 100 ref lines read as 100 batches. The reader's hand-off schedules one main hop for the burst,
    /// so the follow builds its state once for it; a ref line parses refs only; the same lines again build nothing.
    /// Red at base: every batch was its own main hop and take (XrayFollow.swift:323) and every take parsed every part
    /// (XrayFollow.swift:172).
    func testABurstOfRefLinesIsOneBuildAndARepeatIsNone() {
        let refs = (0..<XrayRefs.maxRows).map { ##"{"key":"issue:#\##($0)","shape":"issue","text":"#\##($0)","count":1}"## }
        let f = XrayFollow(target: Self.target("api"))
        f.take([Data(Self.snapshot(#"{"schema":1,"chapters":[{"anchor":"s:10","offset":10,"i":1,"title":"one","kind":"prompt"}],"refs":["#
                                   + refs.joined(separator: ",") + "]}").utf8)])
        XCTAssertEqual(f.applies, 1)
        XCTAssertEqual(f.state?.refs?.entries.count, XrayRefs.maxRows)
        let burst = (0..<100).map { Data(##"{"schema":1,"ref":{"key":"issue:#\##($0)","shape":"issue","text":"#\##($0)","count":2}}"##.utf8) }
        let pending = XrayPendingLines()
        let hops = burst.filter { pending.add([$0]) }.count
        XCTAssertEqual(hops, 1, "one main hop for the burst")
        let drained = pending.drain()
        XCTAssertEqual(drained, burst, "every line, in order")
        f.take(drained)
        XCTAssertEqual(f.applies, 2, "one build for 100 lines")
        XCTAssertEqual(f.parsed.refs, 2)
        XCTAssertEqual(f.parsed.chapters, 1, "a ref line parses no chapters")
        XCTAssertEqual(f.state?.refs?.entries.filter { $0.count == 2 }.count, 100)
        XCTAssertEqual(f.state?.chapters?.map(\.title), ["one"], "the parts not parsed are kept")
        XCTAssertEqual(f.state?.anchors, ["s:10": 1])
        f.take(burst)
        XCTAssertEqual(f.applies, 2, "the same refs again: no build, no $state")
        f.take([Data(Self.chapter7.utf8)])
        XCTAssertEqual(f.applies, 3)
        XCTAssertEqual(f.parsed.refs, 2, "a chapter line parses no refs")
        XCTAssertEqual(f.state?.chapters?.count, 2)
        XCTAssertEqual(f.state?.refs?.entries.count, XrayRefs.maxRows)
        f.take([Data(Self.snapshot(#"{"schema":1,"chapters":[],"refs":[],"dropped_keys":3}"#).utf8)])
        XCTAssertEqual(f.state?.refs?.entries.count, 0, "a later snapshot replaces every part")
        XCTAssertEqual(f.state?.refs?.droppedKeys, 3)
        XCTAssertEqual(f.state?.chapters?.count, 0)
        XCTAssertEqual(f.state?.anchors, [:])
        XCTAssertTrue(pending.add([Data("x".utf8)]), "after a drain the next lines get their own hop")
        XCTAssertFalse(pending.add([]), "no hop for nothing")
    }

    static func ref(_ n: Int, count: Int = 1, text: String? = nil) -> String {
        ##"{"key":"issue:#\##(n)","shape":"issue","text":"\##(text ?? "#\(n)")","count":\##(count)}"##
    }

    /// A snapshot with refs 0..<n and one chapter.
    static func refsSnapshot(_ n: Int, text1: String? = nil) -> Data {
        Data(snapshot(#"{"schema":1,"chapters":[{"anchor":"s:10","offset":10,"i":1,"title":"one","kind":"prompt"}],"refs":["#
                      + (0..<n).map { ref($0, text: $0 == 1 ? text1 : nil) }.joined(separator: ",") + "]}").utf8)
    }

    /// #1631 (sample2: XrayRefs.parse 1193 samples under take, OutsideText.shown 410 of them): one changed ref in a list
    /// of 50 parses that ref alone; a removal and a repeat parse none; a new key parses one; a snapshot parses every
    /// row again (a same-key ref with new text shows it). Red at base: XrayFollow.swift:181 `XrayRefs.parse(object)`
    /// parsed all 50 rows for each ref line (refRows 100 after the first delta, not 51).
    func testOneChangedRefParsesThatRefAlone() {
        let f = XrayFollow(target: Self.target("api"))
        f.take([Self.refsSnapshot(50)])
        XCTAssertEqual(f.refRows, 50)
        f.take([Data(#"{"schema":1,"ref":"#.utf8) + Data(Self.ref(7, count: 5).utf8) + Data("}".utf8)])
        XCTAssertEqual(f.refRows, 51, "one changed ref: one row parsed")
        XCTAssertEqual(f.state?.refs?.entries.first { $0.key == "issue:#7" }?.count, 5)
        XCTAssertEqual(f.state?.refs?.entries.filter { $0.count == 1 }.count, 49, "the rest keep their parsed value")
        XCTAssertEqual(f.state?.refs?.entries.map(\.index), Array(0..<50))
        f.take([Data(##"{"schema":1,"ref":{"key":"issue:#0","text":"#0","count":0}}"##.utf8)])
        XCTAssertEqual(f.refRows, 51, "a removal parses no row")
        XCTAssertEqual(f.state?.refs?.entries.first?.key, "issue:#1")
        XCTAssertEqual(f.state?.refs?.entries.map(\.index), Array(0..<49), "each kept row at its new place")
        f.take([Data(#"{"schema":1,"ref":"#.utf8) + Data(Self.ref(99).utf8) + Data("}".utf8)])
        XCTAssertEqual(f.refRows, 52, "a new key: one row")
        XCTAssertEqual(f.state?.refs?.entries.last?.key, "issue:#99")
        XCTAssertEqual(f.parsed.chapters, 1, "no chapters parsed for ref lines")
        f.take([Self.refsSnapshot(50, text1: "#1 again")])
        XCTAssertEqual(f.refRows, 102, "a snapshot parses every row")
        XCTAssertEqual(f.state?.refs?.entries.first { $0.key == "issue:#1" }?.text, "#1 again", "not the kept #1")
    }

    /// #1631: a key twice in a snapshot is parsed each time (never kept by key): each row keeps its own text.
    func testAKeyTwiceInASnapshotIsNeverReused() {
        let f = XrayFollow(target: Self.target("api"))
        f.take([Data(Self.snapshot(#"{"schema":1,"chapters":[],"refs":["# + Self.ref(1) + "," + Self.ref(1, text: "#1b") + "," + Self.ref(2) + "]}").utf8)])
        f.take([Data(#"{"schema":1,"ref":"#.utf8) + Data(Self.ref(2, count: 4).utf8) + Data("}".utf8)])
        XCTAssertEqual(f.refRows, 6, "3 rows, then the twice-held key's 2 rows and the changed #2")
        XCTAssertEqual(f.state?.refs?.entries.map(\.text), ["#1", "#1b", "#2"])
    }

    /// #1631: with the hop on (the product's), the build runs on the follow's queue and main swaps in the result; two
    /// builds asked before main turns land as one state, the newer one (the older is dropped by its generation), and
    /// the newer one's parse reused the older one's rows. Red with the build on main (builtOnMain 2) or without the
    /// generation check (the first state that lands is the older one, #7 at count 1).
    func testTheBuildRunsOffMainAndOnlyTheNewestLands() async {
        let offMain = XrayFollow.buildOffMain
        defer { XrayFollow.buildOffMain = offMain }
        XrayFollow.buildOffMain = { true }
        let f = XrayFollow(target: Self.target("api"))
        let landed = expectation(description: "a state landed")
        landed.assertForOverFulfill = false   // a mutant without the generation check lands twice: its asserts say so
        let sink = f.$state.dropFirst().sink { _ in landed.fulfill() }
        defer { sink.cancel() }
        f.take([Self.refsSnapshot(50)] + XrayFollowTasksTests.blocks(tasks: ["1", "2"], memories: ["m1"]).map { Data($0.utf8) })
        f.take([Data(#"{"schema":1,"ref":"#.utf8) + Data(Self.ref(7, count: 5).utf8) + Data("}".utf8)])
        XCTAssertTrue(f.state == nil, "main does not wait for the build")
        await fulfillment(of: [landed], timeout: 10)
        XCTAssertEqual(f.builtOnMain, 0, "both builds ran off main")
        XCTAssertEqual(f.swapped, 1, "the older build was overtaken: one state swapped in")
        XCTAssertEqual(f.state?.refs?.entries.first { $0.key == "issue:#7" }?.count, 5, "the newer build's")
        XCTAssertEqual(f.refRows, 51, "the newer build parsed #7 alone")
        XCTAssertEqual(f.blockParses, 2, "tasks and memory parsed once, off main")
        XCTAssertEqual(f.state?.tasks?.tasks.map(\.id), ["1", "2"])
    }

    /// #1629 (sample2: XrayLineSplit.take 1895 samples in Data.firstIndex): a 1 MiB line in 1 KiB reads, then 2000
    /// short lines in one read. Each byte is searched or copied about once. Red at base: the kept tail was searched
    /// again from its start on every read (XrayFollow.swift:376) and copied again after every line (XrayFollow.swift:379).
    func testLineSplitTouchesEachByteAboutOnce() {
        var s = XrayLineSplit()
        let kib = Data(repeating: 0x61, count: 1024)
        for _ in 0..<1023 { XCTAssertEqual(s.take(kib), []) }
        XCTAssertEqual(s.take(kib + Data("\nb".utf8))?.map(\.count), [1 << 20])
        let short = Data((0..<2000).map { "line \($0)\n" }.joined().utf8)
        let out = s.take(short)
        XCTAssertEqual(out?.count, 2000)
        XCTAssertEqual(out?.first, Data("bline 0".utf8))
        XCTAssertEqual(out?.last, Data("line 1999".utf8))
        let total = (1 << 20) + 2 + short.count
        XCTAssertLessThanOrEqual(s.touched, 2 * total, "touched \(s.touched) for \(total) bytes")
    }

    /// #1638 (sample2: 37 samples of JSONSerialization under take on main): with the hop on, the follow's lines (two
    /// batches from the reader) wait in its pending list and are decoded, applied and built on its queue in one take;
    /// main only swaps the finished state in. Red at base: take decoded every line on main (XrayFollow.swift:127,
    /// decodedOnMain 3) and each batch was its own wait on main (XrayFollow.swift:437). The hop-off follow at the end
    /// shows the counter counts.
    func testLinesAreDecodedOffMainInOneTakePerWait() async {
        let offMain = XrayFollow.buildOffMain
        defer { XrayFollow.buildOffMain = offMain }
        XrayFollow.buildOffMain = { true }
        let lines = [Self.snapshot(), Self.chapter7, #"{"schema":1,"ref":"# + Self.ref(7) + "}"]
        await withFollow { fake, _ in
            let f = XrayFollow(target: Self.target("api"))
            let landed = expectation(description: "a state landed")
            let sink = f.$state.dropFirst().sink { _ in landed.fulfill() }
            defer { sink.cancel() }
            f.start("/fake/dch")
            fake.send(1, lines[0], lines[1])
            fake.send(1, lines[2])
            XCTAssertTrue(f.state == nil, "main does not decode or build")
            await fulfillment(of: [landed], timeout: 10)
            XCTAssertEqual(f.decoded, 3)
            XCTAssertEqual(f.decodedOnMain, 0, "no line decoded on main")
            XCTAssertEqual(f.builtOnMain, 0)
            XCTAssertEqual(f.applies, 1, "two batches in one wait: one take, one build")
            XCTAssertEqual(f.state?.chapters?.count, 7)
            XCTAssertEqual(f.state?.refs?.entries.contains { $0.key == "issue:#7" }, true)
            f.stop()
        }
        XrayFollow.buildOffMain = { false }
        let g = XrayFollow(target: Self.target("api"))
        g.take(lines.map { Data($0.utf8) })
        XCTAssertEqual(g.decodedOnMain, 3, "the counter counts: on main with the hop off")
    }

    /// #1638: the end comes after the lines before it. A snapshot still waiting (inside the 100 ms wait) is taken and
    /// landed before the end is read, so a follow that had its snapshot is not failed, keeps its state and stays in the
    /// LRU; a follow whose lines held no snapshot fails after them. Red with ended-skips-drain (the end is read before
    /// the snapshot lands: failed, onEnd) and with ended-no-hop (the end is read at once: not running before settled).
    func testEndedLandsAfterTheLinesBeforeIt() async {
        let offMain = XrayFollow.buildOffMain
        defer { XrayFollow.buildOffMain = offMain }
        XrayFollow.buildOffMain = { true }
        await withFollow { fake, _ in
            let f = XrayFollow(target: Self.target("api")), g = XrayFollow(target: Self.target("api-qa"))
            var ends: [String] = []
            f.onEnd = { ends.append($0.target.name) }
            g.onEnd = { ends.append($0.target.name) }
            f.start("/fake/dch")
            fake.send(1, Self.snapshot())
            fake.end(1, 0)
            XCTAssertTrue(f.running, "the end waits for the lines before it")
            await f.settled()
            XCTAssertFalse(f.running)
            XCTAssertFalse(f.failed, "it had its snapshot")
            XCTAssertEqual(f.state?.chapters?.count, 6)
            g.start("/fake/dch")
            fake.send(2, Self.chapter7)   // a delta before any snapshot
            fake.end(2, 0)
            await g.settled()
            XCTAssertTrue(g.failed, "no snapshot: the panels go back to the reads")
            XCTAssertEqual(ends, ["api-qa"])
            XCTAssertEqual(f.decodedOnMain + g.decodedOnMain, 0)
        }
    }

    /// #1631 QA rider (supervisor add-on to #1638): with the hop on, a snapshot with refs, a ref delta, a reset, a new
    /// snapshot and another ref delta (five takes) go through the real queue. The state that lands equals the one the
    /// same lines build with the hop off, and holds the new snapshot's refs and chapters plus the last delta only:
    /// nothing from before the reset. Red with swap-every-landing (swapped 5: every older build lands first).
    func testResetThroughTheQueueEqualsTheHopOff() async {
        let lines = [
            Data(Self.snapshot(#"{"schema":1,"chapters":[{"anchor":"s:10","offset":10,"i":1,"title":"old","kind":"prompt"}],"refs":["#
                               + Self.ref(1) + "," + Self.ref(2) + "]}").utf8),
            Data((#"{"schema":1,"ref":"# + Self.ref(2, count: 9) + "}").utf8),
            Data(Self.reset.utf8),
            Data(Self.snapshot(#"{"schema":1,"chapters":[{"anchor":"s:30","offset":30,"i":1,"title":"new","kind":"prompt"}],"refs":["#
                               + Self.ref(3) + "]}").utf8),
            Data((#"{"schema":1,"ref":"# + Self.ref(4, count: 2) + "}").utf8),
        ]
        let offMain = XrayFollow.buildOffMain
        defer { XrayFollow.buildOffMain = offMain }
        XrayFollow.buildOffMain = { false }
        let plain = XrayFollow(target: Self.target("api"))
        for l in lines { plain.take([l]) }
        XrayFollow.buildOffMain = { true }
        let f = XrayFollow(target: Self.target("api"))
        for l in lines { f.take([l]) }
        XCTAssertTrue(f.state == nil, "main does not wait")
        await f.settled()
        XCTAssertEqual(f.decodedOnMain, 0)
        XCTAssertEqual(f.builtOnMain, 0)
        XCTAssertEqual(f.applies, 5)
        XCTAssertEqual(f.swapped, 1, "only the newest of the five builds lands")
        XCTAssertTrue(f.state?.refs != nil && f.state?.refs == plain.state?.refs, "the same refs as the hop off")
        XCTAssertEqual(f.state?.chapters?.map(\.title), plain.state?.chapters?.map(\.title))
        XCTAssertEqual(f.state?.anchors, plain.state?.anchors)
        XCTAssertEqual(f.state?.refs?.entries.map(\.key), ["issue:#3", "issue:#4"], "the new snapshot's refs and the last delta only")
        XCTAssertEqual(f.state?.refs?.entries.last?.count, 2)
        XCTAssertEqual(f.state?.chapters?.map(\.title), ["new"], "nothing from before the reset")
        XCTAssertEqual(f.state?.anchors, ["s:30": 1])
    }

    /// #1638: the cap counts each delta's own line bytes (never re-serialised): an evicted chapter and a removed ref free
    /// what their lines added. A test-sized cap holds an empty snapshot, the evict and removal lines and three chapter
    /// lines; after three chapters are evicted and a ref is added then removed, three new chapters still fit, one more
    /// does not. Red with evict-frees-nothing and with ref-removal-frees-nothing (failed after the second three).
    func testEvictedChaptersAndRemovedRefsFreeTheirLineBytes() {
        let cap = XrayFollow.maxKept
        defer { XrayFollow.maxKept = cap }
        func chapter(_ n: Int) -> Data {
            Data(#"{"schema":1,"chapter":{"anchor":"s:\#(n)","offset":\#(n),"i":\#(n),"title":"chapter \#(n)","kind":"prompt"}}"#.utf8)
        }
        let snap = Data(Self.snapshot(#"{"schema":1,"chapters":[],"refs":[]}"#).utf8)
        let evict = Data(#"{"schema":1,"evict":{"seq":1000}}"#.utf8)
        let add = Data((#"{"schema":1,"ref":"# + Self.ref(5) + "}").utf8)
        let remove = Data(##"{"schema":1,"ref":{"key":"issue:#5","text":"#5","count":0}}"##.utf8)
        XrayFollow.maxKept = snap.count + evict.count + remove.count + 3 * chapter(100).count
        let f = XrayFollow(target: Self.target("api"))
        f.take([snap, chapter(100), chapter(200), chapter(300)])
        f.take([evict, add, remove])
        f.take([chapter(400), chapter(500), chapter(600)])
        XCTAssertFalse(f.failed, "the evicted chapters and the removed ref freed their bytes")
        XCTAssertEqual(f.state?.chapters?.map(\.title), ["chapter 400", "chapter 500", "chapter 600"])
        f.take([chapter(700)])
        XCTAssertTrue(f.failed, "one line more passes the cap")
        let swapped = f.swapped
        f.take([snap])
        XCTAssertEqual(f.swapped, swapped, "past the cap nothing more is read or built")
        XCTAssertEqual(f.decoded, 11, "the snapshot after the cap is not even decoded")
    }
}

/// streamLines' batches, from its reading thread.
private final class XrayBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var got: [[Data]] = []
    var all: [[Data]] { lock.withLock { got } }
    func add(_ b: [Data]) { lock.withLock { got.append(b) } }
}
