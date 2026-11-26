import Combine
import XCTest
@testable import ProsperApp

/// #1972 round 2 (operator 2026-11-26, "Keep scroll anchored"; QA R1972 f2, n1): a drawer update that brings new rows
/// above the one the person reads keeps that row at the top (stable row ids, XrayScrollAnchor.restore); a quiet ledger's
/// ages still move each minute; the ref card's count is never below the rows it lists. Fake dch answers only: no dch, no
/// process, no window.
@MainActor
final class XrayScrollAnchorTests: XCTestCase {
    typealias T = XrayRefStreamTests
    typealias M = XrayRefTurnTests

    /// objectWillChange sends while `body` runs (an async body: a poll's read lands inside it).
    func publishes(_ p: XrayPanelModel, _ body: () async -> Void) async -> Int {
        var n = 0
        let s = p.objectWillChange.sink { _ in n += 1 }
        await body()
        s.cancel()
        return n
    }

    func tasks(_ rows: [String]) -> (Int32, Data) {
        (0, XrayPanelTasksTests.ndjson([XrayPanelTasksTests.header] + rows + [XrayPanelTasksTests.done]))
    }

    static let newTask = #"{"task":{"id":"14","title":"Retry the build","status":"pending","label":"pending","created":null,"updated":null,"blocked_by":[]}}"#

    // MARK: the pure restore

    func testRestoreKeepsTheReadersRowUnlessAtTheTop() {
        let old = ["a", "b", "c", "d"]
        XCTAssertEqual(XrayScrollAnchor.restore(old: old, new: ["n"] + old, anchor: "c"), "c", "a new first row: the reader's row comes back")
        XCTAssertTrue(XrayScrollAnchor.restore(old: old, new: ["n"] + old, anchor: "a") == nil, "at the very top: the new row shows")
        XCTAssertTrue(XrayScrollAnchor.restore(old: old, new: ["n"] + old, anchor: nil) == nil, "never scrolled: the top")
        XCTAssertTrue(XrayScrollAnchor.restore(old: old, new: old + ["n"], anchor: "c") == nil, "a row below: nothing above moved")
        XCTAssertTrue(XrayScrollAnchor.restore(old: old, new: old, anchor: "c") == nil, "the same rows: nothing")
        XCTAssertEqual(XrayScrollAnchor.restore(old: old, new: ["n", "a", "b", "d"], anchor: "c"), "d", "the row went: the next one")
        XCTAssertEqual(XrayScrollAnchor.restore(old: old, new: ["n", "a", "b"], anchor: "c"), "b", "none after it: the one before")
        XCTAssertTrue(XrayScrollAnchor.restore(old: old, new: ["a", "b", "d"], anchor: "c") == nil, "it went, nothing above moved")
        XCTAssertTrue(XrayScrollAnchor.restore(old: old, new: ["n"] + old, anchor: "x") == nil, "another tab's row: nothing")
        XCTAssertTrue(XrayScrollAnchor.restore(old: old, new: [], anchor: "c") == nil, "an emptied list: nothing")
    }

    func testUniqueIdsKeepTheFirstAndMarkRepeats() {
        let u = XrayScrollAnchor.unique(["t:1", "t:2", "t:1", "t:1"])
        XCTAssertEqual(u, ["t:1", "t:2", "t:1\u{1F}2", "t:1\u{1F}3"])
        XCTAssertEqual(Set(u).count, u.count)
    }

    // MARK: stable row ids, model level

    /// Red with the base ids (XrayPanel.swift taskLines: "g\(i).\(j)", the place in the group): the id the reader's row
    /// had names another task after a new pending task sorts above it. Here a poll's new first row keeps the anchor.
    func testANewTaskAboveKeepsTheReadersRow() {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        p.now = { XrayPanelTasksTests.now }
        p.take((0, XrayPanelTasksTests.tasksOut))
        let old = p.taskLines.map(\.id)
        XCTAssertEqual(old, ["h:In progress", "t:1", "h:Pending", "t:12", "t:13", "h:Done", "t:9"])
        p.topRow = "t:13"
        let r = XrayPanelTasksTests.rows
        p.take(tasks([r[0], Self.newTask] + r.dropFirst()))   // dch lists 14 before 12 and 13
        let new = p.taskLines.map(\.id)
        XCTAssertEqual(new, ["h:In progress", "t:1", "h:Pending", "t:14", "t:12", "t:13", "h:Done", "t:9"])
        XCTAssertEqual(p.restoreTop(old: old, new: new), "t:13")
        XCTAssertEqual(p.taskLines.first { $0.id == p.topRow }?.task?.id, "13", "the anchor still names the task read")
        p.topRow = "h:In progress"
        XCTAssertTrue(p.restoreTop(old: new, new: new) == nil, "at the top: nothing moves")
        p.topRow = "t:9"
        p.tab = .memory
        XCTAssertTrue(p.topRow == nil, "another tab starts at its top")
    }

    /// Red with the base Refs list (`id: \.offset`): the reader's ref is keyed by its text, so a new ref sorting first
    /// keeps it.
    func testANewRefFirstKeepsTheReadersRef() {
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
        p.showAllRefs = true
        p.takeRefs((0, XrayRefsParseTests.object(refs: XrayRefsTabTests.three)))
        let old = p.refLines.map(\.id)
        XCTAssertEqual(old, ["r:acme/api#7", "r:#831", "r:src/main.c:12"])
        p.topRow = "r:#831"
        let more = ##"[{"key":"issue:#900","shape":"issue","text":"#900","count":9,"last_offset":1200},"## + XrayRefsTabTests.three.dropFirst()
        p.takeRefs((0, XrayRefsParseTests.object(refs: more)))
        let new = p.refLines.map(\.id)
        XCTAssertEqual(new.first, "r:#900")
        XCTAssertEqual(p.restoreTop(old: old, new: new), "r:#831")
        XCTAssertEqual(p.refLines.first { $0.id == "r:#831" }?.e.text, "#831")
    }

    /// Red with prompts keyed by Chapter.id (dch's place in its list): a front drop (#1633) shifts every place; the
    /// anchor ids hold, and a new prompt on top keeps the reader's prompt.
    func testANewPromptKeepsTheReadersPromptAcrossAFrontDrop() {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .prompts)
        p.showAuto = true   // automatic rows shown; agent messages stay hidden (the default)
        p.takeChapters(XrayChaptersTests.chapters)
        let old = p.promptLines(p.shownPrompts).map(\.id)
        XCTAssertEqual(old, ["a:f3a41c:500", "a:f3a41c:400", "a:f3a41c:300", "a:f3a41c:100", "a:f3a41c:0"])
        p.topRow = "a:f3a41c:400"
        // dch's ring dropped the first chapter (the others renumbered) and a new prompt came
        let first = #"{"anchor":"f3a41c:0","offset":0,"i":1,"at":1794304860,"title":"Fix the login test","kind":"prompt","partial":false,"error":false,"response":"Done: login fixed","tools":"Bash 1"},"#
        var json = XrayChaptersTests.json.replacingOccurrences(of: first, with: "")
        XCTAssertNotEqual(json, XrayChaptersTests.json)
        for i in 2...6 { json = json.replacingOccurrences(of: "\"i\":\(i),", with: "\"i\":\(i - 1),") }
        json = json.replacingOccurrences(of: #"Continuing"}]"#, with: #"Continuing"},{"anchor":"f3a41c:600","i":6,"title":"Next step","kind":"prompt"}]"#)
        p.takeChapters((0, Data(json.utf8)))
        let new = p.promptLines(p.shownPrompts).map(\.id)
        XCTAssertEqual(new, ["a:f3a41c:600", "a:f3a41c:500", "a:f3a41c:400", "a:f3a41c:300", "a:f3a41c:100"])
        XCTAssertEqual(p.restoreTop(old: old, new: new), "a:f3a41c:400")
        XCTAssertEqual(p.promptLines(p.shownPrompts).first { $0.id == "a:f3a41c:400" }?.c.title, "Conversation compacted")
    }

    /// Red with the base Memory list (XrayRefPopover.keyed: the place in the group): a newer memory above keeps the
    /// reader's row by its memory id.
    func testANewMemoryAboveKeepsTheReadersRow() {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .memory)
        p.takeMemory((0, XrayPanelMemoryTests.memoryOut))
        let old = p.memoryLines.map(\.id)
        XCTAssertEqual(Set(old).count, old.count)
        p.topRow = "m:m1"
        let m0 = #"{"memory":{"id":"m0","title":"Uses tabs","kind":"feedback","scope":"user","updated":"2026-11-16T11:30:00Z","path":"/Users/example/mem/m0.md","session":"wrote","chapter":null,"body":null}}"#
        let r = XrayPanelMemoryTests.rows
        p.takeMemory((0, XrayPanelTasksTests.ndjson([XrayPanelMemoryTests.header, r[0], m0] + r.dropFirst()
                                                     + [#"{"done":true,"count":6,"dropped":0}"#])))
        let new = p.memoryLines.map(\.id)
        XCTAssertLessThan(new.firstIndex(of: "m:m0") ?? .max, new.firstIndex(of: "m:m1") ?? -1, "m0 is above m1")
        XCTAssertEqual(p.restoreTop(old: old, new: new), "m:m1")
        XCTAssertEqual(p.memoryLines.first { $0.id == "m:m1" }?.item?.id, "m1")
    }

    // MARK: QA f2: ages on a quiet ledger

    /// Red without the tick's agesTick (XrayPoller.swift): an unchanged poll publishes nothing (#1972 round 1's put),
    /// so after the minute turns no redraw comes and the drawn "5m" stays. One send when the minute turns, none inside
    /// it, none while another tab shows.
    func testAQuietPollAfterTheMinuteTurnsPublishesOnceAndTheAgeMoves() async {
        let clock = XrayPollTests.Clock(), run = XrayPollTests.PollRun()
        var r = XrayPanelTasksTests.rows
        r[0] = r[0].replacingOccurrences(of: "2026-11-16T11:00:00Z", with: "2026-11-16T11:55:00Z")
        run.tasks = tasks(r)
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in XrayPollTests.base }
        p.read(dch: "/fake/dch", run: run.run)
        await p.reading?.value
        func age() -> String? { p.tasks?.tasks.first { $0.id == "1" }.flatMap { XrayTaskRow($0, now: p.now()).age } }
        func tick(at s: TimeInterval) async {
            clock.t = XrayPollTests.base + s
            p.tick()
            await p.reading?.value
        }
        await tick(at: 1)   // the minute is noted
        XCTAssertEqual(age(), "5m")
        let reads = run.tasksReads
        let quiet = await publishes(p) { await tick(at: 30) }
        XCTAssertEqual(quiet, 0, "the same minute, the same answer: nothing")
        XCTAssertGreaterThan(run.tasksReads, reads, "a poll ran and answered the same")
        let turned = await publishes(p) { await tick(at: 61) }
        XCTAssertEqual(turned, 1, "the minute turned: one send")
        XCTAssertEqual(age(), "6m")
        let after = await publishes(p) { await tick(at: 62) }
        XCTAssertEqual(after, 0)
        p.tab = .refs   // no Refs rows: no read either
        let other = await publishes(p) { await tick(at: 125) }
        XCTAssertEqual(other, 0, "another tab: the ages are not drawn")
        p.tab = .tasks
        p.paneState = { (false, true) }
        let hidden = await publishes(p) { await tick(at: 190) }
        XCTAssertEqual(hidden, 0, "hidden: nothing")
    }

    // MARK: QA n1: the ref card's count

    /// Red without merged's raise (XrayRefCard.swift): the light answer's row the full answer lacks stays on the card,
    /// and the footer said "This session 1" under two rows (and no "others" over a kept api-qa row).
    func testTheCountIsAtLeastTheRowsTheCardKeeps() {
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
        p.takeRef(XrayRefMergeTests.out([T.mention1, M.mention("api-qa", offset: 50)]), text: "#12", light: true, more: true)
        let done = T.done.replacingOccurrences(of: #""session":2,"project":3,"project_sessions":1"#,
                                               with: #""session":1,"project":0,"project_sessions":0"#)
        XCTAssertNotEqual(done, T.done)
        p.takeRef((0, Data(([T.first, T.mention0, done]).joined(separator: "\n").utf8)), text: "#12")
        let c = p.refContext
        XCTAssertEqual(XrayRefMergeTests.lines(p).count, 3, "both light rows kept, the full one added")
        XCTAssertEqual(c.map(XrayRefPopover.footer)?.prefix(2).map { $0 }, ["This session 2", "1 in 1 others"])
    }
}
