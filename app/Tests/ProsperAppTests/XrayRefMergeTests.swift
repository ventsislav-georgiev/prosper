import Combine
import XCTest
@testable import ProsperApp

/// #1972: a later answer for the ref card already drawn (a light answer, then the pin's full one) never moves the rows
/// on screen: shown rows keep their order and place, new rows go below; an unchanged answer (the card's, or a drawer
/// poll's) publishes nothing. Literal fake dch lines through the model's own take paths; no dch, no process, no window.
@MainActor
final class XrayRefMergeTests: XCTestCase {
    typealias T = XrayRefStreamTests
    typealias M = XrayRefTurnTests

    static func out(_ lines: [String]) -> (status: Int32, out: Data) {
        (0, Data(([T.first] + lines + [T.done]).joined(separator: "\n").utf8))
    }

    static func lines(_ p: XrayPanelModel) -> [String] { (p.refContext?.groups ?? []).flatMap(\.mentions).map(\.line) }

    func panel() -> XrayPanelModel { XrayPanelModel(target: XrayRefRunTests.local, tab: .refs) }

    /// objectWillChange sends while `body` runs.
    func publishes(_ p: XrayPanelModel, _ body: () -> Void) -> Int {
        var n = 0
        let s = p.objectWillChange.sink { _ in n += 1 }
        body()
        s.cancel()
        return n
    }

    /// Red with the wholesale replace (base XrayRefCard.swift takeRef: `refContext = scope == "project" ? c : ...`):
    /// the full answer's earlier mention (offset 0) sorts above the shown one (offset 376); it goes below it instead.
    func testNewRowsSortingAboveTheShownOnesGoBelow() {
        let p = panel()
        p.takeRef(Self.out([T.mention1]), text: "#12", light: true, more: true)
        XCTAssertEqual(Self.lines(p), ["# #12 Login retries"])
        p.takeRef(Self.out([T.mention0, T.mention1]), text: "#12")
        XCTAssertEqual(Self.lines(p), ["# #12 Login retries", "Work on #12 please"], "the shown row stays first")
        XCTAssertEqual(p.refContext?.more, false, "the full answer's facts: no longer searching")
        XCTAssertEqual(p.refContext?.done, true)
    }

    /// Red with the wholesale replace: a newer turn of the full answer (p5) sorts above the shown p3 block.
    func testANewerTurnGoesBelowTheShownTurn() {
        let p = panel()
        p.takeRef(Self.out([M.mention(turn: 3, offset: 200)]), text: "#12", light: true, more: true)
        p.takeRef(Self.out([M.mention(turn: 5, offset: 300), M.mention(turn: 3, offset: 200), M.mention(turn: 3, offset: 250)]),
                  text: "#12")
        let turns = p.refContext?.turns ?? []
        XCTAssertEqual(turns.map(\.turn), [3, 5])
        XCTAssertEqual(turns.first?.mentions.map(\.offset), [200, 250], "the shown row first, the block's new row under it")
    }

    /// Red with a merge that drops unmatched shown rows: a row the full answer lacks stays where it was.
    func testAShownRowMissingFromTheFullAnswerStays() {
        let p = panel()
        p.takeRef(Self.out([M.mention(offset: 900, sentence: "Gone #12 line")]), text: "#12", light: true, more: true)
        p.takeRef(Self.out([M.mention(offset: 0)]), text: "#12")
        XCTAssertEqual(Self.lines(p), ["Gone #12 line", "Work on #12 please"])
    }

    /// Red with a mention keyed by its line: the light row and the full row at the same place are one row, its text
    /// updated in place (#1824's light fixture, chapter f12:0 offset 0), not two.
    func testTheSameRowIsUpdatedInPlaceNotAdded() {
        let p = panel()
        p.takeRef(Self.out([XrayRefStagedOpenTests.light[1]]), text: "#12", light: true, more: true)
        XCTAssertEqual(Self.lines(p), [XrayRefStagedOpenTests.lightLine])
        p.takeRef(Self.out([T.mention0, T.definition, T.mention1]), text: "#12")
        XCTAssertEqual(Self.lines(p), ["Work on #12 please", "# #12 Login retries"])
        XCTAssertEqual(p.refContext?.definitions.count, 1)
    }

    /// Red with no ref check: another ref's answer replaces the card's context, it never merges into it.
    func testAnotherRefsAnswerIsNotMerged() {
        let p = panel()
        p.takeRef(Self.out([T.mention1]), text: "#13", light: true, more: true)
        p.takeRef(Self.out([T.mention0, T.mention1]), text: "#12")
        XCTAssertEqual(Self.lines(p), ["Work on #12 please", "# #12 Login retries"])
        XCTAssertEqual(p.refContext?.ref, "#12")
    }

    /// Red with the unconditional set (base: `refContext = ...`, one send per answer): the same answer again sends nothing.
    func testAnIdenticalAnswerPublishesNothing() {
        let p = panel()
        let full = Self.out([T.mention0, T.definition, T.mention1])
        XCTAssertEqual(publishes(p) { p.takeRef(full, text: "#12") }, 1)
        XCTAssertEqual(publishes(p) { p.takeRef(full, text: "#12") }, 0)
        XCTAssertEqual(Self.lines(p), ["Work on #12 please", "# #12 Login retries"])
    }

    /// The pure merge: shown order kept, new rows in the answer's order below, duplicates matched one to one, an
    /// unmatched shown row kept, an equal answer unchanged.
    func testMergeKeepsShownOrder() {
        func m(_ a: [String], _ b: [String]) -> [String] { XrayRefContext.merge(a, b, key: { $0 }) }
        XCTAssertEqual(m(["a", "b"], ["c", "b", "a", "d"]), ["a", "b", "c", "d"])
        XCTAssertEqual(m(["x", "b"], ["b"]), ["x", "b"])
        XCTAssertEqual(m(["a", "a"], ["a", "b", "a"]), ["a", "a", "b"])
        XCTAssertEqual(m(["a", "b"], ["a", "b"]), ["a", "b"])
        XCTAssertEqual(m([], ["b", "a"]), ["b", "a"])
        XCTAssertEqual(XrayRefContext.merge([1, 2], [2, 1, 3], key: { $0 % 10 }, with: { $1 + 10 * $0 }), [11, 22, 3])
    }

    /// Red with the base Tasks take (`tasks = ...; unreachable = false`: two sends per poll): an unchanged Tasks poll
    /// sends nothing, so the drawer does not redraw under the reader.
    func testAnUnchangedTasksPollPublishesNothing() {
        let p = panel()
        p.take((0, XrayPanelTasksTests.tasksOut))
        XCTAssertEqual(p.tasks?.tasks.count, 4)
        XCTAssertEqual(publishes(p) { p.take((0, XrayPanelTasksTests.tasksOut)) }, 0)
    }

    /// Red with the base takeMemory (`memory = parse; if count == 0 { memory = nil }`: two sends for an empty list, one
    /// for an unchanged one).
    func testAnUnchangedOrEmptyMemoryReadPublishesNothing() {
        let p = panel()
        let empty = XrayPanelTasksTests.ndjson([XrayPanelMemoryTests.header, #"{"done":true,"count":0,"dropped":0}"#])
        XCTAssertEqual(publishes(p) { p.takeMemory((0, empty)) }, 0)
        XCTAssertTrue(p.memory == nil)
        XCTAssertEqual(publishes(p) { p.takeMemory((0, XrayPanelMemoryTests.memoryOut)) }, 1)
        XCTAssertEqual(publishes(p) { p.takeMemory((0, XrayPanelMemoryTests.memoryOut)) }, 0)
    }
}
