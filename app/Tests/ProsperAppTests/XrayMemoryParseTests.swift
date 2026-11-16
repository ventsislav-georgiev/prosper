import XCTest
@testable import ProsperApp

final class XrayMemoryParseTests: XCTestCase {
    private let header = #"{"schema":1,"source":"claude","title":"Example Org api","partial":false}"#
    private let done = #"{"done":true,"count":0,"dropped":0}"#

    private func parse(_ lines: [String]) -> XrayMemory { XrayMemory.parse(Data(lines.joined(separator: "\n").utf8)) }
    /// A memory row; `fields` are the extra JSON members, already encoded.
    private func row(_ id: String, kind: String = "null", session: String = "null", updated: String = "null",
                     body: String = "null", extra: String = "") -> String {
        #"{"memory":{"id":"\#(id)","title":"t\#(id)","note":null,"kind":\#(kind),"scope":null,"updated":\#(updated),"path":"/Users/example/\#(id).md","session":\#(session),"chapter":null,"body":\#(body)\#(extra)}}"#
    }
    private func ids(_ g: XrayMemory.Group?) -> [String] { g?.items.map(\.id) ?? [] }

    func testGroupsAndOrder() {
        let r = parse([header,
                       row("a", kind: #""user""#, session: #""loaded""#, updated: #""2026-11-01T10:00:00Z""#),
                       row("b", kind: #""project""#),
                       row("c", kind: #""instructions""#),
                       row("d", kind: #""feedback""#, session: #""wrote""#, updated: #""2026-11-03T10:00:00Z""#),
                       row("e", kind: #""instructions""#),
                       row("f", kind: #""reference""#),
                       row("g", kind: #""instructions""#, session: #""loaded""#),
                       done])
        XCTAssertEqual(r.groups.map(\.title), ["This session", "Memories", "Instructions"])
        XCTAssertEqual(ids(r.groups.first), ["d", "a", "g"])   // newest first, undated last
        XCTAssertEqual(ids(r.groups.dropFirst().first), ["b", "f"])
        XCTAssertEqual(ids(r.groups.last), ["c", "e"])   // load order = dch's order
        XCTAssertEqual(parse([header, row("b"), done]).groups.map(\.title), ["Memories"])
    }

    func testCutFlag() {
        let r = parse([header, row("a", body: #""x""#, extra: #","cut":true"#), row("b", body: #""y""#), done])
        XCTAssertEqual(r.items.map(\.cut), [true, false])
    }

    func testBodyNullStaysNull() {
        let r = parse([header, row("a"), row("b", body: #""""#), done])
        XCTAssertTrue(r.items.first?.body == nil)
        XCTAssertEqual(r.items.last?.body, "")
    }

    func testEveryKindAndAnUnknownOne() {
        let kinds = ["user", "feedback", "project", "reference", "instructions"]
        let r = parse([header] + kinds.map { row($0, kind: "\"\($0)\"") } + [row("x", kind: #""skill""#), row("n"), done])
        XCTAssertEqual(r.items.prefix(5).map(\.kind), [.user, .feedback, .project, .reference, .instructions])
        XCTAssertEqual(r.items.prefix(5).map(\.kindWord), kinds)
        let unknown = r.items.dropFirst(5).first, null = r.items.last
        XCTAssertTrue(unknown?.kind == nil); XCTAssertEqual(unknown?.kindWord, "skill")
        XCTAssertTrue(null?.kind == nil); XCTAssertTrue(null?.kindWord == nil)
        let scopes = parse([header,
                            #"{"memory":{"id":"1","title":"t","scope":"managed","path":"p"}}"#,
                            #"{"memory":{"id":"2","title":"t","scope":"user","path":"p"}}"#,
                            #"{"memory":{"id":"3","title":"t","scope":"project","path":"p"}}"#,
                            #"{"memory":{"id":"4","title":"t","scope":"team","path":"p"}}"#,
                            #"{"memory":{"id":"5","title":"t","scope":null,"path":"p"}}"#, done])
        XCTAssertEqual(scopes.items.map(\.scope), [.managed, .user, .project, nil, nil])
        XCTAssertEqual(scopes.items.map(\.scopeWord), ["managed", "user", "project", "team", nil])
    }

    func testInstructionsPathKeptRaw() {
        let m = #"{"memory":{"id":"i1","title":"AGENTS.md","note":"load order 1","kind":"instructions","scope":"user","updated":"2026-11-02T11:30:00.500Z","path":"/Users/example/a\u0007b/AGENTS.md","session":null,"chapter":"c3","body":"rules","cut":false}}"#
        let it = parse([header, m, done]).items.first
        XCTAssertEqual(it?.path, "/Users/example/a\u{07}b/AGENTS.md")
        XCTAssertEqual(it?.kind, .instructions); XCTAssertEqual(it?.scope, .user)
        XCTAssertEqual(it?.updated, Date(timeIntervalSince1970: 1_793_619_000.5))
        XCTAssertEqual(it?.chapter, "c3"); XCTAssertEqual(it?.note, "load order 1")
    }

    func testCommandSource() {
        let r = parse([#"{"schema":1,"source":"command","title":null,"partial":false,"warn":"from a command"}"#,
                       row("c1"), #"{"done":true,"count":1,"dropped":3,"warn":"3 rows over the limit"}"#])
        XCTAssertEqual(r.source, "command"); XCTAssertTrue(r.title == nil)
        XCTAssertEqual(r.headerWarn, "from a command"); XCTAssertEqual(r.doneWarn, "3 rows over the limit")
        XCTAssertEqual(r.droppedCount, 3); XCTAssertFalse(r.partial)
        XCTAssertEqual(r.items.count, 1)
    }

    func testBodyCapIsReappliedAfterCleaning() {
        let big = String(repeating: "a", count: 20_000)
        let r = parse([header, row("a", body: "\"\(big)\""),
                       // 16384 letters plus bidi marks: the marks go first, so nothing is left to cut
                       row("b", body: "\"" + String(repeating: "a", count: 16_384) + String(repeating: #"\u202e"#, count: 100) + "\""),
                       done])
        XCTAssertEqual(r.items.first?.body?.utf8.count, 16_384); XCTAssertEqual(r.items.first?.cut, true)
        XCTAssertEqual(r.items.last?.body?.utf8.count, 16_384); XCTAssertEqual(r.items.last?.cut, false)
    }

    func testControlAndBidiRemovedFromBodyNewlinesStay() {
        let r = parse([header, row("a", body: #""l1\r\n\u202el2\u0007\n\n\tl3\u200b\u0000""#), done])
        XCTAssertEqual(r.items.first?.body, "l1\nl2\n\nl3")
        let title = parse([header, #"{"memory":{"id":"1","title":"a\u202eb\u0007c","path":"p"}}"#, done])
        XCTAssertEqual(title.items.first?.title, "abc")
    }

    func testNoDoneLineMeansPartial() {
        XCTAssertTrue(parse([header, row("a")]).partial)
        XCTAssertFalse(parse([header, row("a"), done]).partial)
        XCTAssertTrue(parse([#"{"schema":1,"source":"claude","title":null,"partial":true}"#, row("a"), done]).partial)
    }

    func testLineOver64KBIsSkipped() {
        let r = parse([header, row("big", body: "\"" + String(repeating: "a", count: 70_000) + "\""), row("ok"), done])
        XCTAssertEqual(r.items.map(\.id), ["ok"]); XCTAssertEqual(r.skippedLines, 1)
        XCTAssertEqual(parse([header, "{not json", done]).skippedLines, 1)
    }

    func testCountIsEveryRow() {
        let r = parse([header, row("a", kind: #""user""#), row("b", session: #""wrote""#), row("c", kind: #""instructions""#),
                       row("d", kind: #""skill""#), row("e", session: #""read""#), done])
        XCTAssertEqual(r.count, 5)
        XCTAssertEqual(r.groups.map(\.items.count).reduce(0, +), 5)
    }
}
