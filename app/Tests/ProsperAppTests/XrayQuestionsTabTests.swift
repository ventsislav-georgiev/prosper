import XCTest
@testable import ProsperApp

/// #1974 (operator 2026-11-26: "can we have another tab for open questions"): the X-ray drawer's Questions tab, from
/// dch 1.171.0's `dch --xray <n> --questions --json` (rows as Tasks', under "question" or bare). Shown only for exit 0,
/// schema 1 and at least one row; Open first; polled only while shown, never from the follow. A fake runner answers by
/// form (no dch, no process, no window, no wall clock).
@MainActor
final class XrayQuestionsTabTests: XCTestCase {

    nonisolated static let header = #"{"schema":1,"session":"api","source":"command","title":"example questions","partial":false}"#
    nonisolated static let rows = [
        #"{"question":{"id":"OQ-2","title":"Which port?","status":"pending","label":"OPEN","note":"","created":"2026-11-16T09:00:00Z"}}"#,
        #"{"question":{"id":"OQ-1","title":"Keep the old flag?","status":"done","label":"ANSWERED","note":"Yes, one more release","updated":"2026-11-16T10:00:00Z"}}"#,
        #"{"id":"OQ-3","title":"Rename the tab?","status":"pending","label":"OPEN"}"#,   // a bare row
        #"{"question":{"id":"OQ-4","title":"Drop the cache?","status":"dropped","label":"DROPPED"}}"#,
    ]
    nonisolated static let done = #"{"done":true,"count":4,"dropped":0}"#
    nonisolated static var out: Data { XrayPanelTasksTests.ndjson([header] + rows + [done]) }

    func panel(tab: XrayTab = .tasks) -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayChaptersTests.local, tab: tab)
        p.now = { XrayPanelTasksTests.now }
        return p
    }

    /// Red at base: Row required "task" (XrayTasks.swift:104), so both forms were skipped lines and no row came.
    func testQuestionAndBareRowsParse() {
        let q = XrayTasks.parse(Self.out)
        XCTAssertEqual(q.tasks.map(\.id), ["OQ-2", "OQ-1", "OQ-3", "OQ-4"])
        XCTAssertEqual(q.skippedLines, 0)
        XCTAssertEqual(q.schema, 1)
        XCTAssertFalse(q.partial)
        XCTAssertEqual(q.tasks.first(where: { $0.id == "OQ-1" })?.note, "Yes, one more release", "the ruling is the note")
        XCTAssertEqual(q.tasks.last?.status, .dropped)
        XCTAssertEqual(q.open, 2)
    }

    /// A bare line without an id (not a header, not a done line) is still a skipped line, not a row.
    func testABareLineWithoutAnIdIsSkipped() {
        let q = XrayTasks.parse(XrayPanelTasksTests.ndjson([Self.header, #"{"title":"no id"}"#, #"{"other":1}"#, Self.done]))
        XCTAssertEqual(q.tasks.count, 0)
        XCTAssertEqual(q.skippedLines, 2)
    }

    /// Open (pending and in progress) first, then Answered, then Dropped only when any.
    func testGroupsPutOpenFirst() {
        let q = XrayTasks.parse(Self.out)
        XCTAssertEqual(q.questionGroups.map(\.title), ["Open", "Answered", "Dropped"])
        XCTAssertEqual(q.questionGroups.first?.tasks.map(\.id), ["OQ-2", "OQ-3"])
        let noDrop = XrayTasks.parse(XrayPanelTasksTests.ndjson([Self.header] + Self.rows.dropLast() + [Self.done]))
        XCTAssertEqual(noDrop.questionGroups.map(\.title), ["Open", "Answered"])
    }

    /// The tab after Tasks, "Questions 2" (open ones), spoken "Questions, 2 open". Red at base: no such tab.
    func testTheTabShowsForRowsAfterTasks() {
        let p = panel()
        p.apply(tasks: (0, XrayPanelTasksTests.tasksOut), memory: (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory)))
        p.takeQuestions((0, Self.out))
        XCTAssertEqual(p.tabs, [.tasks, .questions, .memory])
        XCTAssertEqual(p.title(.questions), "Questions 2")
        XCTAssertEqual(p.spoken(.questions), "Questions, 2 open")
    }

    /// No tab for an older dch's refusal (exit 1, no error line), dch's "none" header with no rows, another schema, an
    /// over-cap answer; exit 4 keeps the rows and says "host unreachable".
    func testNoTabWithoutRows() {
        let p = panel()
        p.takeQuestions((0, Self.out))
        XCTAssertTrue(p.questions != nil)
        p.takeQuestions((1, Data("dch: unknown option --questions\n".utf8)))
        XCTAssertTrue(p.questions == nil, "an older dch")
        XCTAssertFalse(p.tabs.contains(.questions))
        XCTAssertEqual(p.goneFooter, [], "no error line for the refusal")
        XCTAssertFalse(p.unreachable)
        let none = XrayPanelTasksTests.ndjson([#"{"schema":1,"session":"api","source":"none","partial":false}"#, Self.done])
        p.takeQuestions((0, none))
        XCTAssertTrue(p.questions == nil, "no questions command")
        p.takeQuestions((0, XrayPanelTasksTests.ndjson([#"{"schema":2}"#] + Self.rows + [Self.done])))
        XCTAssertTrue(p.questions == nil, "another schema")
        p.takeQuestions((XrayPanels.overCap, Self.out))
        XCTAssertTrue(p.questions == nil, "over the cap")
        p.takeQuestions((0, Self.out))
        p.takeQuestions((4, Data()))
        XCTAssertTrue(p.questions != nil, "an unreachable host keeps the rows")
        XCTAssertTrue(p.unreachable)
    }

    /// Stable ids: "h:" a group, "q:" a question (a repeat made unique); the filter narrows the rows and drops empty groups.
    func testLinesHaveStableIds() {
        let p = panel()
        p.takeQuestions((0, Self.out))
        XCTAssertEqual(p.questionLines.map(\.id), ["h:Open", "q:OQ-2", "q:OQ-3", "h:Answered", "q:OQ-1", "h:Dropped", "q:OQ-4"])
        XCTAssertEqual(p.questionLines.first?.header, "Open 2")
        p.filter = "port"
        XCTAssertEqual(p.questionLines.map(\.id), ["h:Open", "q:OQ-2"])
        let twice = XrayPanelTasksTests.ndjson([Self.header, Self.rows[0], Self.rows[0], Self.done])
        p.filter = ""
        p.takeQuestions((0, twice))
        XCTAssertEqual(p.questionLines.map(\.id), ["h:Open", "q:OQ-2", "q:OQ-2\u{1F}2"])
    }

    /// The widths are built once per change, not per body.
    func testColumnsAreBuiltOncePerChange() {
        let p = panel()
        p.takeQuestions((0, Self.out))
        for _ in 0..<5 { _ = p.questionCols }
        XCTAssertEqual(p.questionColsBuilt, 1)
        p.takeQuestions((0, Self.out))
        _ = p.questionCols
        XCTAssertEqual(p.questionColsBuilt, 1, "an unchanged answer keeps them")
    }

    /// A closed panel's questions come back on the next open (#1976's kept rows).
    func testKeptRowsHoldTheQuestions() {
        let p = panel()
        p.takeQuestions((0, Self.out))
        let k = p.keptRows
        XCTAssertEqual(k.questions?.tasks.count, 4)
        let p2 = panel(tab: .questions)
        p2.seed(k)
        XCTAssertEqual(p2.questions, p.questions)
        XCTAssertTrue(p2.loaded, "the kept Questions tab draws on the first frame")
    }

    // MARK: reads and polls

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _forms: [String] = []
        let questions: (status: Int32, out: Data)
        init(questions: (status: Int32, out: Data)) { self.questions = questions }
        var forms: [String] { lock.withLock { _forms } }
        func count(_ f: String) -> Int { forms.filter { $0 == f }.count }
        var run: XrayPanels.Run {
            { [self] _, a, _ in
                let f = XrayOpenFastTests.Gate.form(a)
                lock.withLock { _forms.append(f) }
                return f == "tasks" ? (0, XrayPanelTasksTests.tasksOut) : f == "memory" ? XrayChaptersTests.mem
                    : f == "questions" ? questions : XrayChaptersTests.chapters
            }
        }
    }

    func withQuestions(_ body: () async throws -> Void) async rethrows {
        let gate = XrayPanels.questionsTab
        defer { XrayPanels.questionsTab = gate }
        XrayPanels.questionsTab = { true }
        try await body()
    }

    final class Clock { var t = XrayChaptersTests.base }

    func live(_ clock: Clock, tab: XrayTab) -> XrayPanelModel {
        let p = panel(tab: tab)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in XrayChaptersTests.base }
        p.panels = XrayPanels()
        return p
    }

    /// The open reads --questions once (behind the seam); the poll reads it every 30 s only while Questions shows, and
    /// Tasks' poll never does. Red at base: no questions read at all.
    func testQuestionsArePolledOnlyWhileShown() async {
        await withQuestions {
            let clock = Clock(), rec = Recorder(questions: (0, Self.out)), p = live(clock, tab: .tasks)
            p.read(dch: "/fake/dch", run: rec.run)
            await p.reading?.value
            XCTAssertEqual(rec.count("questions"), 1, "the open reads it once")
            XCTAssertEqual(p.tabs, [.tasks, .questions, .memory])
            for s in 1...40 {   // Tasks shown: its 5 s poll, no questions read
                clock.t = XrayChaptersTests.base + Double(s)
                p.tick()
                await p.reading?.value
            }
            XCTAssertEqual(rec.count("questions"), 1, "not polled while Tasks shows")
            XCTAssertGreaterThan(rec.count("tasks"), 1)
            p.select(.questions)
            let tasksBefore = rec.count("tasks")
            for s in 41...100 {
                clock.t = XrayChaptersTests.base + Double(s)
                p.tick()
                await p.reading?.value
            }
            XCTAssertEqual(rec.count("questions"), 3, "every 30 s while Questions shows (and the answer changes nothing: 30 then 60)")
            XCTAssertEqual(rec.count("tasks"), tasksBefore, "no Tasks poll while Questions shows")
            p.stop()
        }
    }

    /// An older dch refuses --questions: no tab, no error line, the remembered Questions tab falls to the first tab, and
    /// no poll reads it again.
    func testAnOlderDchsRefusalHidesTheTab() async {
        await withQuestions {
            let clock = Clock(), rec = Recorder(questions: (1, Data())), p = live(clock, tab: .questions)
            p.read(dch: "/fake/dch", run: rec.run)
            await p.reading?.value
            XCTAssertTrue(p.questions == nil)
            XCTAssertEqual(p.tabs, [.tasks, .memory])
            XCTAssertEqual(p.tab, .tasks, "a session without questions falls back as for Tasks")
            XCTAssertEqual(p.footer.filter { $0.contains("question") }, [])
            for s in 1...100 {
                clock.t = XrayChaptersTests.base + Double(s)
                p.tick()
                await p.reading?.value
            }
            XCTAssertEqual(rec.count("questions"), 1, "never read again")
            p.stop()
        }
    }

    /// Under XCTest the seam is off: the open's reads stay Tasks, Memory (and the chapters), as every other row pins.
    func testTheSeamIsOffUnderXCTest() async {
        let rec = Recorder(questions: (0, Self.out)), p = live(Clock(), tab: .tasks)
        p.read(dch: "/fake/dch", run: rec.run)
        await p.reading?.value
        XCTAssertEqual(rec.count("questions"), 0)
        p.stop()
    }
}
