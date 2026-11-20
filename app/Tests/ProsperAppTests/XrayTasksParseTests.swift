import XCTest
@testable import ProsperApp

final class XrayTasksParseTests: XCTestCase {
    private let header = #"{"schema":1,"session":"api","session_id":"s-1","source":"claude","title":"Example Org api","partial":false}"#
    private let done = #"{"done":true,"count":2,"dropped":0}"#

    private func parse(_ lines: [String]) -> XrayTasks { XrayTasks.parse(Data(lines.joined(separator: "\n").utf8)) }
    private func row(_ id: String, _ status: String, title: String = "t", label: String = "l", extra: String = "") -> String {
        #"{"task":{"id":"\#(id)","title":"\#(title)","status":"\#(status)","label":"\#(label)"\#(extra)}}"#
    }

    func testEveryField() {
        let r = parse([header, #"{"task":{"id":"7","title":"Fix acme/api retry","status":"active","label":"in_progress","active":"Fixing","note":"see acme/api#7","created":"2026-11-01T10:00:00Z","updated":"2026-11-02T11:30:00.500Z","chapter":"c3","created_chapter":"c1","blocked_by":["5","6"],"url":"https://example.org/acme/api/issues/7","group":"Backend"}}"#, done])
        XCTAssertEqual(r.source, "claude")
        XCTAssertEqual(r.sessionTitle, "Example Org api")
        XCTAssertFalse(r.partial)
        let t = r.tasks.first
        XCTAssertEqual(t?.id, "7"); XCTAssertEqual(t?.title, "Fix acme/api retry"); XCTAssertEqual(t?.status, .active)
        XCTAssertEqual(t?.label, "in_progress"); XCTAssertEqual(t?.active, "Fixing"); XCTAssertEqual(t?.note, "see acme/api#7")
        XCTAssertEqual(t?.created, Date(timeIntervalSince1970: 1_793_527_200))
        XCTAssertEqual(t?.updated, Date(timeIntervalSince1970: 1_793_619_000.5))
        XCTAssertEqual(t?.chapter, "c3"); XCTAssertEqual(t?.createdChapter, "c1")
        XCTAssertEqual(t?.blockedBy, ["5", "6"]); XCTAssertEqual(t?.url, "https://example.org/acme/api/issues/7")
        XCTAssertEqual(t?.group, "Backend")
        XCTAssertEqual(r.tasks.count, 1)
    }

    /// #1787 (lag1778a R6: 258 of 716 follow-queue samples in NSISO8601DateFormatter): with a cache, a parse decodes and
    /// dates only the rows whose bytes it has not seen, gives the same result as the whole parse, and keeps only the rows
    /// of its last parse. Red at base: no reusing parse (XrayTasks.swift:139 read every row of the block each time).
    func testACachedParseDecodesOnlyChangedRows() {
        let date = #","created":"2026-11-01T10:00:00Z","updated":"2026-11-02T11:30:00.500Z""#
        let one = [header, row("1", "pending", extra: date), row("2", "active", extra: date), row("3", "done", extra: date), done]
        var cache = XrayTasks.Cache()
        let lines = { (ls: [String]) in ls.map { Data($0.utf8) } }
        XCTAssertEqual(XrayTasks.parse(lines(one), reusing: &cache), parse(one))
        XCTAssertEqual(cache.parses, 3, "first parse: every row")
        XCTAssertEqual(cache.rows.count, 3)
        var two = one
        two[2] = row("2", "done", extra: date)
        XCTAssertEqual(XrayTasks.parse(lines(two), reusing: &cache), parse(two))
        XCTAssertEqual(cache.parses, 4, "one changed row: one row decoded and dated")
        XCTAssertEqual(cache.rows.count, 3, "the old bytes of row 2 are dropped")
        XCTAssertEqual(XrayTasks.parse(lines(two + [row("1", "pending", extra: date)]), reusing: &cache).tasks.map(\.id),
                       ["1", "2", "3", "1"], "a repeated row is kept twice and decoded none")
        XCTAssertEqual(cache.parses, 4)
        XCTAssertTrue(XrayTasks.date("2026-11-01T10:00:00+02:00") == Date(timeIntervalSince1970: 1_793_520_000))
        XCTAssertTrue(XrayTasks.date("v1.2") == nil, "a '.' that is no ISO date reads as null")
    }

    func testNulls() {
        let r = parse([#"{"schema":1,"session":"api","session_id":"s-1","source":"none","title":null,"partial":false}"#,
                       row("1", "pending", extra: #","active":null,"note":null,"created":null,"updated":"yesterday","chapter":null,"created_chapter":null,"blocked_by":[],"url":null,"group":null"#), done])
        XCTAssertTrue(r.sessionTitle == nil)
        let t = r.tasks.first
        XCTAssertTrue(t?.active == nil); XCTAssertTrue(t?.note == nil); XCTAssertTrue(t?.created == nil)
        XCTAssertTrue(t?.updated == nil)   // a non-ISO value reads as null
        XCTAssertTrue(t?.chapter == nil); XCTAssertTrue(t?.createdChapter == nil)
        XCTAssertEqual(t?.blockedBy, []); XCTAssertTrue(t?.url == nil); XCTAssertTrue(t?.group == nil)
    }

    func testQuestionMarkIdIsPending() {
        let r = parse([header, row("?3", "pending"), done])
        XCTAssertEqual(r.tasks.first?.id, "?3"); XCTAssertEqual(r.tasks.first?.status, .pending)
        XCTAssertEqual(r.open, 1)
    }

    func testUnknownStatusBecomesPendingWithLabelKept() {
        let r = parse([header, row("1", "parked", label: "PARKED"), done])
        XCTAssertEqual(r.tasks.first?.status, .pending); XCTAssertEqual(r.tasks.first?.label, "PARKED")
        XCTAssertEqual(r.open, 1)
    }

    func testNoDoneLineIsPartial() {
        XCTAssertTrue(parse([header, row("1", "active")]).partial)
        XCTAssertFalse(parse([header, row("1", "active"), done]).partial)
        XCTAssertTrue(parse([header.replacingOccurrences(of: #""partial":false"#, with: #""partial":true"#), done]).partial)
    }

    func testWarnOnHeaderAndOnDone() {
        let h = header.dropLast() + #","warn":"cut at 5 s"}"#
        let r = parse([String(h), #"{"done":true,"count":0,"dropped":2,"warn":"2 rows unreadable"}"#])
        XCTAssertEqual(r.headerWarn, "cut at 5 s"); XCTAssertEqual(r.doneWarn, "2 rows unreadable"); XCTAssertEqual(r.droppedCount, 2)
        XCTAssertTrue(parse([header, done]).headerWarn == nil)
    }

    func testLineOver64KBIsDropped() {
        let big = row("9", "active", title: String(repeating: "a", count: 70_000))
        let r = parse([header, big, row("1", "active"), done])
        XCTAssertEqual(r.tasks.map(\.id), ["1"]); XCTAssertEqual(r.skippedLines, 1)
        XCTAssertEqual(parse([header, "{not json", done]).skippedLines, 1)
    }

    func testBidiAndControlStrippedFromTitle() {
        let r = parse([header, row("1", "active", title: #"a\u202eb\u0007c\u200bd\u0000e"#), done])
        XCTAssertEqual(r.tasks.first?.title, "abcde")
    }

    func testCountIsActivePlusPending() {
        let r = parse([header, row("1", "active"), row("2", "pending"), row("3", "done"), row("4", "dropped"), done])
        XCTAssertEqual(r.open, 2)
    }

    func testGroupsAndOrder() {
        let u = { (d: String) in #","updated":"\#(d)""# }
        let r = parse([header, row("1", "done", extra: u("2026-11-01T00:00:00Z")), row("2", "pending"), row("3", "done", extra: u("2026-11-03T00:00:00Z")),
                       row("4", "active"), row("5", "done"), done])
        XCTAssertEqual(r.groups.map(\.title), ["In progress", "Pending", "Done"])
        XCTAssertEqual(r.groups.map { $0.tasks.map(\.id) }, [["4"], ["2"], ["3", "1", "5"]])
        let d = parse([header, row("6", "dropped"), done])
        XCTAssertEqual(d.groups.map(\.title), ["In progress", "Pending", "Done", "Dropped"])
        XCTAssertEqual(d.groups.last?.tasks.map(\.id), ["6"])
    }

    /// #1351 (QA R1349-i2, R1349-i1): the header's schema is kept for the panel's check; the url is kept raw beside its
    /// display form.
    func testSchemaKeptAndRawURLBesideTheDisplayForm() {
        let long = "https://example.org/" + String(repeating: "a", count: 2100)
        let r = parse([header, row("1", "pending", extra: #","url":"\#(long)""#), done])
        XCTAssertEqual(r.schema, 1)
        XCTAssertEqual(r.tasks.first?.rawURL, long, "raw: whole")
        XCTAssertNotEqual(r.tasks.first?.url, long, "display: capped")
        XCTAssertEqual(parse([#"{"schema":2,"source":"claude","partial":false}"#, done]).schema, 2)
        XCTAssertTrue(parse([row("1", "pending"), done]).schema == nil, "no header: nil")
    }
}
