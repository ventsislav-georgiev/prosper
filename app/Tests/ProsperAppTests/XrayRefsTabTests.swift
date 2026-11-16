import XCTest
@testable import ProsperApp

/// #1415 (#1356 step 1): the Refs tab behind gate A (XrayPanels.refsTab, restored by every row). A fake runner answers
/// by form with literal JSON, the clock is injected and the ticks are called by hand. No dch, no window, no key posted.
@MainActor
final class XrayRefsTabTests: XCTestCase {

    typealias Answer = (status: Int32, out: Data)
    nonisolated static let base = XrayPanelTasksTests.now
    nonisolated static let three = #"""
    [{"key":"issue:#831","shape":"issue","text":"#831","count":2,"last_offset":376,"defined":true,"definitions":1,\#
    "title":"Agent panes","underline":true},\#
    {"key":"pull:acme/api#7","shape":"pull","text":"acme/api#7","count":1,"last_offset":900,"title":"Fix the login flow"},\#
    {"key":"file:/Users/example/api/src/main.c:12","shape":"file","text":"src/main.c:12","count":1,"last_offset":100}]
    """#

    /// The fake dch: records each argv; Tasks and Memory answer as XrayPanelTasksTests', the --json read with `json`.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        let json: Answer
        init(json: Answer = (0, XrayRefsParseTests.object(refs: XrayRefsTabTests.three))) { self.json = json }
        var calls: [[String]] { lock.withLock { _calls } }
        var jsonReads: Int { calls.filter { $0.last == "--json" && $0.count == 3 }.count }
        var tasksReads: Int { calls.filter { $0.contains("--tasks") }.count }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                lock.withLock { _calls.append(args) }
                if args.contains("--tasks") { return (0, XrayPanelTasksTests.tasksOut) }
                if args.contains("--memory") { return (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory)) }
                return json
            }
        }
    }

    final class Clock { var t = XrayRefsTabTests.base }

    /// A local panel on "api", Tasks shown, shown and live; `dchPane`: a Terminal-mode pane (dch's chapters).
    func panel(_ clock: Clock, dchPane: Bool = false) -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in Self.base }
        p.fromDch = { dchPane }
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

    /// A panel that took `refs` from a Terminal-mode pane's chapters read.
    func applied(_ refs: String = XrayRefsTabTests.three, complete: Bool = true, dropped: Int = 0) -> XrayPanelModel {
        let p = panel(Clock(), dchPane: true)
        p.apply(tasks: (0, XrayPanelTasksTests.tasksOut), memory: (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory)),
                chapters: (0, XrayRefsParseTests.object(refs: refs, dropped: dropped, complete: complete)))
        return p
    }

    func testTabOnlyWithTheGateOnAndRefs() {
        let gate = XrayPanels.refsTab
        defer { XrayPanels.refsTab = gate }
        XCTAssertFalse(XrayPanels.refsTab(), "gate A is off under XCTest")
        XCTAssertEqual(applied().tabs, [.prompts, .responses, .tasks, .memory], "gate off: the tab set is unchanged")
        XCTAssertTrue(applied().refs == nil, "gate off: no refs kept")
        XrayPanels.refsTab = { true }
        XCTAssertEqual(applied().tabs, [.prompts, .responses, .refs, .tasks, .memory], "between Responses and Search")
        XCTAssertEqual(applied("[]").tabs, [.prompts, .responses, .tasks, .memory], "an empty list: no tab")
    }

    func testCountIsEveryRefHiddenKindsIncluded() {
        let gate = XrayPanels.refsTab
        defer { XrayPanels.refsTab = gate }
        XrayPanels.refsTab = { true }
        let p = applied()
        XCTAssertEqual(p.shownRefs.count, 2, "the file is hidden by default")
        XCTAssertEqual(p.title(.refs), "Refs 3")
        XCTAssertEqual(p.spoken(.refs), "Refs, 3")
        XCTAssertEqual(applied(complete: false).title(.refs), "Refs \u{2265}3", "dch's list not complete: a lower bound")
    }

    func testDefaultKindsAndTheShowAllToggle() throws {
        let gate = XrayPanels.refsTab
        defer { XrayPanels.refsTab = gate }
        XrayPanels.refsTab = { true }
        let p = applied(XrayRefsParseTests.six, dropped: 5)
        XCTAssertEqual(p.shownRefs.map(\.text), ["acme/api#7", "API-12", "#831"], "issues, pulls and tickets, dch's order")
        let t = try XCTUnwrap(p.refsToggle)
        XCTAssertEqual(t.text, "3 files, commits and links hidden")
        XCTAssertEqual(t.button, "Show all kinds")
        XCTAssertEqual(p.refsFooter, ["5 more refs not indexed"])
        p.showAllRefs = true
        XCTAssertEqual(p.shownRefs.map(\.text),
                       ["acme/api#7", "API-12", "#831", "src/main.c:12", "abc1234", "https://example.org/acme/api"])
        XCTAssertTrue(p.refsToggle?.text == nil)
        XCTAssertEqual(p.refsToggle?.button, "Hide files, commits and links")
        XCTAssertEqual(applied().refsFooter, [], "no dropped keys: no line")
    }

    func testFilterIsOverTextAndTitleCaseInsensitive() {
        let gate = XrayPanels.refsTab
        defer { XrayPanels.refsTab = gate }
        XrayPanels.refsTab = { true }
        let p = applied(XrayRefsParseTests.six)
        p.filter = "LOGIN"
        XCTAssertEqual(p.shownRefs.map(\.text), ["acme/api#7"], "by its title only")
        p.filter = "api-12"
        XCTAssertEqual(p.shownRefs.map(\.text), ["API-12"], "by its text")
        p.filter = "main.c"
        XCTAssertEqual(p.shownRefs.map(\.text), [], "a hidden kind stays hidden")
        XCTAssertEqual(p.refsToggle?.text, "1 files, commits and links hidden")
    }

    func testBoldWhenDefinedOrTwoMentions() throws {
        let r = try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs: XrayRefsParseTests.six)))
        func bold(_ text: String) -> Bool? {
            r.entries.first { $0.text == text }.map { XrayRefRow($0, complete: true, home: "/Users/example", cwd: nil).bold }
        }
        XCTAssertEqual(bold("#831"), true, "defined")
        XCTAssertEqual(bold("API-12"), true, "3 mentions, no definition")
        XCTAssertEqual(bold("acme/api#7"), false, "one mention, no definition")
    }

    func testFilesRelativeToTheCwdElseHome() throws {
        let r = try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs: XrayRefsParseTests.six)))
        let f = try XCTUnwrap(r.entries.first { $0.shape == .file })
        XCTAssertEqual(XrayRefRow(f, complete: true, home: "/Users/example", cwd: "/Users/example/api").text, "src/main.c:12")
        XCTAssertEqual(XrayRefRow(f, complete: true, home: "/Users/example", cwd: "/Users/example/web").text, "~/api/src/main.c:12")
        XCTAssertEqual(XrayRefRow(f, complete: true, home: "/Users/other", cwd: nil).text, "/Users/example/api/src/main.c:12")
    }

    func testRowIsAButtonWithASpokenLabel() throws {
        let r = try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs: XrayRefsParseTests.six)))
        let e = try XCTUnwrap(r.entries.first)
        XCTAssertEqual(XrayRefRow(e, complete: true, home: "/Users/example", cwd: nil).spoken, "Issue #831, Agent panes, 2 mentions")
        let low = XrayRefRow(e, complete: false, home: "/Users/example", cwd: nil)
        XCTAssertEqual(low.spoken, "Issue #831, Agent panes, at least 2 mentions")
        XCTAssertEqual(low.count, "\u{2265}2")
    }

    /// A Transcript pane runs `--xray <n> --json` on open, on a switch to Refs and every 30 s while Refs is shown and the
    /// session live; never while hidden, ended, or on another tab; its chapters are ignored.
    func testTranscriptPaneReadsJsonOnOpenSwitchAndEvery30sWhileShown() async {
        let gate = XrayPanels.refsTab
        defer { XrayPanels.refsTab = gate }
        XrayPanels.refsTab = { true }
        let clock = Clock(), run = Run(), p = panel(clock)
        var (visible, live) = (true, true)
        p.paneState = { (visible, live) }
        await open(p, run)
        XCTAssertEqual(run.jsonReads, 1, "the read on open")
        XCTAssertEqual(run.calls.filter { $0.count == 3 }.last, ["--xray", "api", "--json"])
        XCTAssertTrue(p.dchChapters == nil, "the pane keeps its own chapters")
        XCTAssertEqual(p.tabs, [.refs, .tasks, .memory])
        for s in [5.0, 10, 30, 60] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.jsonReads, 1, "Tasks shown: no --json poll")
        XCTAssertEqual(run.tasksReads, 5, "Tasks polls every 5 s")
        clock.t = Self.base + 100
        p.select(.refs)
        await p.reading?.value
        XCTAssertEqual(run.jsonReads, 2, "a switch to Refs reads")
        await tick(p, clock, at: 129)
        XCTAssertEqual(run.jsonReads, 2, "not before 30 s")
        await tick(p, clock, at: 130)
        XCTAssertEqual(run.jsonReads, 3, "every 30 s")
        visible = false
        for s in [160.0, 200, 400] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.jsonReads, 3, "hidden: no read")
        (visible, live) = (true, false)
        for s in [500.0, 600] { await tick(p, clock, at: s) }
        XCTAssertEqual(run.jsonReads, 3, "ended: no read")
        XCTAssertEqual(run.tasksReads, 5)
    }

    func testGateOffTranscriptPaneRunsNoJsonRead() async {
        let clock = Clock(), run = Run(), p = panel(clock)
        await open(p, run)
        XCTAssertEqual(run.calls.count, 2, "Tasks and Memory only, as before")
        XCTAssertEqual(run.jsonReads, 0)
        XCTAssertEqual(p.tabs, [.tasks, .memory])
    }
}
