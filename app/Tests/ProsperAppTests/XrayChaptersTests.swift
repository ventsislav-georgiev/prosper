import AppKit
import XCTest
@testable import ProsperApp

/// #1389 (#1346 P6 step B): X-ray's Prompts and Responses tabs for a Terminal-mode pane and a remote session, read from
/// `dch --xray <n> --json`'s chapters through the XrayPanels.run seam (5 s local, 15 s remote). dch's `auto` key is an
/// automatic row and its `peer` key a marked, hideable one (step A's rules). A fake runner answers by form; the clock is
/// injected and the ticks are called by hand. No dch, no process, no window shown, no key posted.
@MainActor
final class XrayChaptersTests: XCTestCase {

    typealias Answer = (status: Int32, out: Data)
    nonisolated static let base = XrayPanelTasksTests.now
    nonisolated static let ok: Answer = (0, XrayPanelTasksTests.tasksOut)
    nonisolated static let mem: Answer = (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory))
    static let label = "host unreachable"

    /// Six chapters as dch prints them: 1 own (answered, Bash 1), 2 a task notification (auto, summary), 3 api-qa's
    /// message (peer), 4 worker-a's hand-back (auto and peer), 5 a compaction, 6 own (answered).
    nonisolated static let json = #"""
    {"schema":1,"session":"api","session_id":"0b1f6a52-4c1e-4d7a-9a51-2f6d8c3e7a10","live":true,"corpus":"claude",\#
    "reason":null,"available":true,"chapters":[\#
    {"anchor":"f3a41c:0","offset":0,"i":1,"at":1794304860,"title":"Fix the login test","kind":"prompt","partial":false,\#
    "error":false,"response":"Done: login fixed","tools":"Bash 1"},\#
    {"anchor":"f3a41c:100","i":2,"title":"<task-notification>","kind":"prompt","auto":true,"summary":"Background build finished"},\#
    {"anchor":"f3a41c:200","i":3,"title":"Please rerun the api suite","kind":"prompt","peer":"api-qa","response":"Rerunning"},\#
    {"anchor":"f3a41c:300","i":4,"title":"PASS.","kind":"prompt","auto":true,"summary":"subagent worker-a: PASS.","peer":"worker-a"},\#
    {"anchor":"f3a41c:400","i":5,"title":"Conversation compacted","kind":"compact"},\#
    {"anchor":"f3a41c:500","i":6,"title":"Continue the api work","kind":"prompt","response":"Continuing"}],\#
    "chapters_evicted":false,"refs":[],"dropped_keys":0}
    """#
    nonisolated static let chapters: Answer = (0, Data(json.utf8))

    /// The fake dch: records each argv, answers by form at once (no form flag: the chapters read).
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _chapters = XrayChaptersTests.chapters
        var calls: [[String]] { lock.withLock { _calls } }
        var chapterReads: Int { calls.filter { !$0.contains("--tasks") && !$0.contains("--memory") }.count }
        var chapters: Answer { get { lock.withLock { _chapters } } set { lock.withLock { _chapters = newValue } } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                lock.withLock { () -> Answer in
                    _calls.append(args)
                    return args.contains("--tasks") ? XrayChaptersTests.ok : args.contains("--memory") ? XrayChaptersTests.mem : _chapters
                }
            }
        }
    }

    final class Clock { var t = XrayChaptersTests.base }

    static let local = XrayTarget(name: "api", dir: "/tmp/dch-test")

    /// A panel that reads dch's chapters (a Terminal-mode pane or a remote row), shown and live, its clock at `base`.
    func panel(_ target: XrayTarget, _ clock: Clock) -> XrayPanelModel {
        let p = XrayPanelModel(target: target, tab: .prompts)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in Self.base }
        p.fromDch = { true }
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

    /// Red at TIP: no chapters read (XrayPanel.swift readBoth runs `--tasks` and `--memory` only; no chaptersArgs).
    func testArgvForALocalTerminalPaneAndARemoteOne() async throws {
        let remote = try XCTUnwrap(XrayTarget.of(XrayRemoteTabsTests.remoteRow))
        for (target, argv) in [(Self.local, ["--xray", "api", "--json"]), (remote, ["--xray", "example-host:api", "--json"])] {
            let clock = Clock(), run = Run(), p = panel(target, clock)
            await open(p, run)
            XCTAssertEqual(Set(run.calls), [target.args("tasks"), target.args("memory"), argv], "\(target.name): the open read")
            XCTAssertEqual(run.calls.count, 3)
            await tick(p, clock, at: 15)
            XCTAssertEqual(run.calls.last, argv, "\(target.name): the poll on Prompts")
            XCTAssertEqual(run.calls.count, 4)
        }
    }

    /// dch's `auto` hides a row until "Show automatic" (titled by its summary); `peer` is shown, marked with its sender,
    /// and hidden by "Hide agent messages"; a hand-back (auto and peer) is automatic. Red at TIP: no XrayChapters.parse.
    func testAutoAndPeerFromTheDchKeys() async throws {
        let clock = Clock(), run = Run(), p = panel(XrayTarget(name: "example-host:api", dir: nil), clock)
        await open(p, run)
        XCTAssertEqual(p.tabs, [.prompts, .responses, .tasks, .memory])
        XCTAssertEqual(p.chapters.map(\.from), [.own, .auto, .peer, .auto, .auto, .own])
        XCTAssertEqual(p.shownPrompts.map(\.title), ["Continue the api work", "Please rerun the api suite", "Fix the login test"],
                       "newest first, the 3 automatic rows hidden")
        XCTAssertEqual(p.count(.prompts), 3)
        XCTAssertEqual(p.shownPrompts.map { XrayPromptRow($0).mark }, [nil, "api-qa", nil], "the peer is marked")
        XCTAssertEqual(p.shownPrompts.map { XrayPromptRow($0).robot }, [false, true, false], "with the robot glyph (#1546)")
        XCTAssertEqual(p.hidden(.prompts).auto, 3)
        XCTAssertEqual(p.hidden(.prompts).peer, 1)
        XCTAssertEqual(p.shownResponses.map(\.response), ["Continuing", "Rerunning", "Done: login fixed"])
        XCTAssertEqual(p.shownResponses.last?.tools, "Bash 1")
        XCTAssertEqual(p.count(.responses), 3)

        p.hidePeer = true
        XCTAssertEqual(p.shownPrompts.map(\.title), ["Continue the api work", "Fix the login test"], "agent messages hidden")
        p.hidePeer = false
        p.showAuto = true
        XCTAssertEqual(p.shownPrompts.map(\.title), ["Continue the api work", "Conversation compacted", "PASS.",
                                                     "Please rerun the api suite", "Background build finished",
                                                     "Fix the login test"], "an auto prompt titled by its summary")
        XCTAssertEqual(p.shownPrompts.map { XrayPromptRow($0).mark },
                       [nil, nil, "\u{1F4E5} worker-a", "api-qa", "\u{1F514}", nil])
        XCTAssertTrue(p.shownPrompts.allSatisfy { XrayPromptRow($0).faint == $0.auto })
        XCTAssertEqual(p.shownPrompts.map(\.ordinal), [6, 5, 4, 3, 2, 1], "dch's i")
    }

    /// Prompts polls dch at the Tasks cadence: 5 s for a local Terminal pane, 15 s for a remote one.
    func testRemoteCadenceIsFifteenSecondsAndLocalIsFive() async throws {
        for (target, every) in [(XrayTarget(name: "example-host:api", dir: nil), 15.0), (Self.local, 5)] {
            let clock = Clock(), run = Run(), p = panel(target, clock)
            await open(p, run)
            XCTAssertEqual(run.chapterReads, 1)
            XCTAssertEqual(p.interval, every, target.name)
            for s in [1.0, 4, every - 1] { await tick(p, clock, at: s) }
            XCTAssertEqual(run.chapterReads, 1, "\(target.name): none before \(every) s")
            await tick(p, clock, at: every)
            XCTAssertEqual(run.chapterReads, 2, "\(target.name): one at \(every) s")
            await tick(p, clock, at: every * 2 - 1)
            XCTAssertEqual(run.chapterReads, 2)
            await tick(p, clock, at: every * 2)
            XCTAssertEqual(run.chapterReads, 3)
            XCTAssertEqual(run.calls.count, 5, "\(target.name): no Tasks or Memory poll while Prompts shows")
        }
    }

    /// A never-shown window on a model with "api" selected (as XrayPollTests.withOpenPanel); nothing spawns.
    func window(_ body: (AgentsNSWindow, AgentWindowModel) async throws -> Void) async throws {
        let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        store.sessions = [AgentSession(key: key, alias: "", activity: AgentWindowD1Tests.now - 60, state: .idle, agents: 0,
                                       version: "1.78.0")]
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
        try await body(win, m)
        XCTAssertEqual(spawns.count, 0, "no terminal spawned")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// Through the window: a local pane runs the chapters read on every open (#1471: no Transcript mode keeps its own).
    func testALocalPaneAlwaysRunsTheChaptersRead() async throws {
        let fake = XrayPanelTasksTests.FakeRun()
        let (dch, prun, model, read) = (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.chaptersRead)
        defer { (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.chaptersRead) = (dch, prun, model, read)
                XrayPanels.shared.open = [:] }
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 78, 0])
        XrayPanels.run = fake.run
        XrayPanels.chaptersRead = XrayPanels.fromDch
        let chaptersArgv = ["/fake/dch", "--xray", "api", "--json"]
        try await window { win, m in
            XrayPanels.model = { [weak m] _ in m }
            let pane = m.layout.focused
            XCTAssertTrue(m.paneHasTerminal)
            XCTAssertTrue(win.toggleXray())
            await XrayPanels.shared.open[pane]?.reading?.value
            XCTAssertEqual(fake.calls.filter { $0 == chaptersArgv }.count, 1, "Terminal mode: the chapters read")
            XCTAssertTrue(win.toggleXray(), "closes")

            // #1471: no Transcript mode: the local pane and a remote row both read dch.
            XCTAssertTrue(m.paneHasTerminal)
            XCTAssertTrue(XrayPanels.fromDch(pane, Self.local), "a local row reads dch")
            XCTAssertTrue(XrayPanels.fromDch(pane, XrayTarget(name: "example-host:api", dir: nil)), "a remote row reads dch")
            XCTAssertTrue(win.toggleXray(), "opens again")
            await XrayPanels.shared.open[pane]?.reading?.value
            XCTAssertEqual(fake.calls.filter { $0 == chaptersArgv }.count, 2, "reopened: read again")
        }
    }

    /// Exit 1 (the host's dch does not know the form) and 6 (refused): no Prompts or Responses tab, on the open read and
    /// on a poll, and no more chapters reads; exit 4 and 7 keep the rows with "host unreachable" (P5's labels).
    func testExitOneAndSixGiveNoPromptsTab() async throws {
        let remote = XrayTarget(name: "example-host:api", dir: nil)
        for code: Int32 in [1, 6] {
            let clock = Clock(), run = Run(), p = panel(remote, clock)
            run.chapters = (code, Data("dch: example-host: does not support --xray\n".utf8))
            await open(p, run)
            XCTAssertEqual(p.tabs, [.tasks, .memory], "exit \(code) on open")
            XCTAssertEqual(p.tab, .tasks, "exit \(code): the strip moves to the tab left")
            XCTAssertFalse(p.unreachable)

            let c2 = Clock(), r2 = Run(), q = panel(remote, c2)
            await open(q, r2)
            XCTAssertEqual(q.tabs, [.prompts, .responses, .tasks, .memory])
            r2.chapters = (code, Data())
            await tick(q, c2, at: 15)
            XCTAssertTrue(q.dchChapters == nil, "exit \(code) on a poll: the tabs go")
            XCTAssertEqual(q.tabs, [.tasks, .memory])
            XCTAssertEqual(q.tab, .tasks)
            XCTAssertFalse(q.memoryFooter.contains(Self.label))
            q.select(.prompts)
            for s in [30.0, 45] { await tick(q, c2, at: s) }
            XCTAssertEqual(r2.chapterReads, 2, "exit \(code): no more chapters reads")
        }
        for code: Int32 in [4, 7] {
            let clock = Clock(), run = Run(), p = panel(remote, clock)
            await open(p, run)
            run.chapters = (code, Data())
            await tick(p, clock, at: 15)
            XCTAssertEqual(p.chapters.count, 6, "exit \(code): the rows are kept")
            XCTAssertEqual(p.tabs, [.prompts, .responses, .tasks, .memory])
            XCTAssertTrue(p.memoryFooter.contains(Self.label), "exit \(code): \(p.memoryFooter)")
        }
    }

    /// The caps: rows past 5000 drop the oldest; titles 120 scalars, responses 2048; bad JSON or another schema: no tab.
    func testParseCapsAndRefusals() {
        let row = #"{"i":0,"title":"s","kind":"prompt"}"#
        let long = #"{"i":0,"title":"\#(String(repeating: "t", count: 300))","kind":"prompt","response":"\#(String(repeating: "r", count: 5000))"}"#
        let many = #"{"schema":1,"chapters":["# + (Array(repeating: row, count: 5002) + [long]).joined(separator: ",") + "]}"
        let cs = XrayChapters.parse(Data(many.utf8)) ?? []
        XCTAssertEqual(cs.count, XrayChapters.maxRows, "the newest 5000")
        XCTAssertEqual(cs.last?.title.unicodeScalars.count, TranscriptOutline.titleCap)
        XCTAssertEqual(cs.last?.response?.unicodeScalars.count, XrayChapters.responseCap)
        XCTAssertEqual(cs.last?.ordinal, XrayChapters.maxRows, "an i of 0 is not dch's: the place in the list")
        let huge = #"{"schema":1,"chapters":[{"title":"\#(String(repeating: "h", count: XrayChapters.maxBytes))"}]}"#
        XCTAssertTrue(XrayChapters.parse(Data(huge.utf8)) == nil, "over 16 MiB: no tab")
        XCTAssertTrue(XrayChapters.parse(Data(#"{"schema":2,"chapters":[]}"#.utf8)) == nil)
        XCTAssertTrue(XrayChapters.parse(Data("not json".utf8)) == nil)
        XCTAssertTrue(XrayChapters.parse(Data(#"{"schema":1}"#.utf8)) == nil)
        XCTAssertEqual(XrayChapters.parse(Data(#"{"schema":1,"chapters":[7,{"title":"x"}]}"#.utf8))?.map(\.title), ["x"])
    }

    // MARK: #1463 the X-ray window remembers its last tab

    static let lastTabKey = "xrayLastTab"

    /// A Terminal-mode window whose dch answers the chapters (tabs Prompts, Responses, Tasks, Memory), the remember seam on
    /// and the stored tab cleared before and after; `body` opens through `open`: a read panel, closed again afterwards.
    func lastTabWindow(_ body: (AgentsNSWindow) async throws -> Void) async throws {
        let fake = Run()
        let (dch, prun, model, read, rem) = (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.chaptersRead, XrayPanels.rememberTab)
        Preferences.defaults.removeObject(forKey: Self.lastTabKey)
        defer {
            (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.chaptersRead, XrayPanels.rememberTab) = (dch, prun, model, read, rem)
            XrayPanels.shared.open = [:]
            Preferences.defaults.removeObject(forKey: Self.lastTabKey)
        }
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 78, 0])
        XrayPanels.run = fake.run
        XrayPanels.chaptersRead = XrayPanels.fromDch
        XrayPanels.rememberTab = { true }
        try await window { win, m in
            XrayPanels.model = { [weak m] _ in m }
            try await body(win)
        }
    }

    /// Opens X-ray on `tab` (nil: the default open), waits for its read and closes it again; the panel is returned.
    func openLast(_ win: AgentsNSWindow, _ tab: XrayTab?) async throws -> XrayPanelModel {
        let pane = try XCTUnwrap(win.model).layout.focused
        XCTAssertTrue(win.toggleXray(on: tab))
        let p = try XCTUnwrap(XrayPanels.shared.open[pane])
        await p.reading?.value
        XCTAssertEqual(p.tabs, [.prompts, .responses, .tasks, .memory])
        XCTAssertTrue(win.toggleXray(), "closes")
        XCTAssertTrue(XrayPanels.shared.open[pane] == nil)
        return p
    }

    /// Red at TIP: the default open was Tasks (AgentsWindow.toggleXray `on tab: XrayTab = .tasks`).
    func testTheFirstDefaultOpenShowsPrompts() async throws {
        try await lastTabWindow { win in
            let p = try await openLast(win, nil)
            XCTAssertEqual(p.tab, .prompts)
        }
    }

    /// Red at TIP: nothing stored the choice, and the default was Tasks.
    func testTheNextDefaultOpenIsTheTabChosenLast() async throws {
        try await lastTabWindow { win in
            let first = try await openLast(win, nil)
            first.select(.responses)
            XCTAssertEqual(Preferences.defaults.string(forKey: Self.lastTabKey), "Responses")
            let second = try await openLast(win, nil)
            XCTAssertEqual(second.tab, .responses)
            second.select(.tasks)
            let third = try await openLast(win, nil)
            XCTAssertEqual(third.tab, .tasks)
        }
    }

    /// A caller that names a tab (the Todos chip: Tasks) opens on it and neither reads nor overwrites the stored one; a
    /// jump that sets `tab` directly (a ref card's Search) is not a choice either.
    func testAnExplicitTabOpensThereAndKeepsTheStoredOne() async throws {
        try await lastTabWindow { win in
            try await openLast(win, nil).select(.responses)
            let chip = try await openLast(win, .tasks)
            XCTAssertEqual(chip.tab, .tasks)
            chip.tab = .memory
            XCTAssertEqual(Preferences.defaults.string(forKey: Self.lastTabKey), "Responses", "a jump is not remembered")
            let next = try await openLast(win, nil)
            XCTAssertEqual(next.tab, .responses)
        }
    }

    /// A stored tab the session lacks (Search is off under XCTest) opens on Prompts; an unknown stored value reads as Prompts.
    func testAnUnavailableOrUnknownStoredTabOpensPrompts() async throws {
        try await lastTabWindow { win in
            Preferences.xrayLastTab = .search
            let gone = try await openLast(win, nil)
            XCTAssertEqual(gone.tab, .prompts)
            Preferences.defaults.set("Bogus", forKey: Self.lastTabKey)
            XCTAssertEqual(Preferences.xrayLastTab, .prompts)
            let unknown = try await openLast(win, nil)
            XCTAssertEqual(unknown.tab, .prompts)
        }
    }

    /// Under XCTest the seam is off: a choice in the strip stores nothing, so no row leaks into another's default open.
    func testTheRememberSeamIsOffUnderXCTest() throws {
        Preferences.defaults.removeObject(forKey: Self.lastTabKey)
        XCTAssertFalse(XrayPanels.rememberTab())
        let p = XrayPanelModel(target: Self.local, tab: .prompts)
        p.select(.responses)
        XCTAssertTrue(Preferences.defaults.object(forKey: Self.lastTabKey) == nil)
    }

    /// #1636: the chapters poll backs off too while its answer is identical (5, 10, 20, 40, 60 s) and a changed answer
    /// resets it. Red at TIP: a flat 5 s (24 reads in 120 s).
    func testChaptersPollBacksOffWhileIdenticalAndResetsOnAChange() async {
        let clock = Clock(), run = Run(), p = panel(Self.local, clock)
        await open(p, run)
        for s in 1...120 { await tick(p, clock, at: TimeInterval(s)) }
        XCTAssertEqual(run.chapterReads, 6, "the open read, then 5, 10, 20, 40, 80")
        run.chapters = (4, Data())
        await tick(p, clock, at: 139)
        XCTAssertEqual(run.chapterReads, 6)
        await tick(p, clock, at: 140)
        XCTAssertEqual(run.chapterReads, 7, "60 s after the 80")
        await tick(p, clock, at: 144)
        XCTAssertEqual(run.chapterReads, 7)
        await tick(p, clock, at: 145)
        XCTAssertEqual(run.chapterReads, 8, "the changed answer: 5 s again")
    }
}
