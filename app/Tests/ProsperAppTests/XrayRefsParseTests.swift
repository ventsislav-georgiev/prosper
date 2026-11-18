import XCTest
@testable import ProsperApp

/// #1415 (#1356 step 1): the `refs` of `dch --xray <n> --json` (dch README "Refs"). Literal JSON, no dch, no process.
final class XrayRefsParseTests: XCTestCase {

    /// One --json object (README shape) with six refs, one of each shape; acme/api fakes.
    static func object(refs: String, schema: Int = 1, dropped: Int = 0, complete: Bool = true) -> Data {
        Data(#"""
        {"schema":\#(schema),"session":"api","session_id":"0b1f6a52-4c1e-4d7a-9a51-2f6d8c3e7a10","live":true,\#
        "corpus":"claude","complete":\#(complete),"why":\#(complete ? "null" : "\"output\""),"project":"-Users-example-api",\#
        "chapters":[{"anchor":"f3a41c:0","offset":0,"i":1,"title":"Fix the login test","kind":"prompt"}],\#
        "chapters_evicted":false,"refs":\#(refs),"dropped_keys":\#(dropped)}
        """#.utf8)
    }

    static let six = #"""
    [{"key":"issue:#831","shape":"issue","text":"#831","project":"-Users-example-api","count":2,"last_offset":376,\#
    "defined":true,"definitions":1,"title":"Agent panes","underline":true},\#
    {"key":"ticket:API-12","shape":"ticket","text":"API-12","count":3,"last_offset":376,"defined":false,"definitions":0,\#
    "underline":true},\#
    {"key":"commit:abc1234","shape":"commit","text":"abc1234","full":"abc1234def5678","count":1,"last_offset":50},\#
    {"key":"pull:acme/api#7","shape":"pull","text":"acme/api#7","count":1,"last_offset":900,"title":"Fix the login flow"},\#
    {"key":"file:/Users/example/api/src/main.c:12","shape":"file","text":"src/main.c:12","count":1,"last_offset":100},\#
    {"key":"url:https://example.org/acme/api","shape":"url","text":"https://example.org/acme/api","count":1,"last_offset":10}]
    """#

    func testEveryField() throws {
        let r = try XCTUnwrap(XrayRefs.parse(Self.object(refs: Self.six, dropped: 4)))
        XCTAssertEqual(r.entries.count, 6)
        let e = try XCTUnwrap(r.entries.first)
        XCTAssertEqual(e.key, "issue:#831")
        XCTAssertEqual(e.shape, .issue)
        XCTAssertEqual(e.text, "#831")
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.lastOffset, 376)
        XCTAssertTrue(e.defined)
        XCTAssertEqual(e.definitions, 1)
        XCTAssertEqual(e.title, "Agent panes")
        XCTAssertTrue(e.underline)
        XCTAssertEqual(r.entries.map(\.shape), [.issue, .ticket, .commit, .pull, .file, .url])
        XCTAssertEqual(r.entries.first { $0.shape == .commit }?.full, "abc1234def5678")
        XCTAssertEqual(r.droppedKeys, 4)
        XCTAssertTrue(r.complete)
        XCTAssertTrue(r.why == nil)
        XCTAssertEqual(r.sessionID, "0b1f6a52-4c1e-4d7a-9a51-2f6d8c3e7a10")
        let cut = try XCTUnwrap(XrayRefs.parse(Self.object(refs: Self.six, complete: false)))
        XCTAssertFalse(cut.complete)
        XCTAssertEqual(cut.why, "output")
    }

    func testUnknownShapeStaysARowWithAGenericKind() throws {
        let refs = #"[{"key":"epic:E-1","shape":"epic","text":"E-1","count":1},{"text":"no shape"},7,"x"]"#
        let r = try XCTUnwrap(XrayRefs.parse(Self.object(refs: refs)))
        XCTAssertEqual(r.entries.map(\.text), ["E-1", "no shape"], "not an object: skipped; no throw")
        XCTAssertTrue(r.entries.allSatisfy { $0.shape == nil })
        let e = try XCTUnwrap(r.entries.first)
        XCTAssertTrue(XrayRefs.byDefault(e), "a shape Prosper does not know is never hidden away")
        XCTAssertEqual(XrayRefRow(e, complete: true, home: "/Users/example", cwd: nil).spoken, "Ref E-1, 1 mention")
    }

    func testRefsMissingNotAnArrayOrSchemaTwoGiveNil() {
        let noRefs = Data(#"{"schema":1,"session":"api","chapters":[]}"#.utf8)
        XCTAssertTrue(XrayRefs.parse(noRefs) == nil, "refs missing")
        XCTAssertTrue(XrayRefs.parse(Self.object(refs: #"{"a":1}"#)) == nil, "refs not an array")
        XCTAssertTrue(XrayRefs.parse(Self.object(refs: "[]", schema: 2)) == nil, "schema 2")
        XCTAssertTrue(XrayRefs.parse(Data("not json".utf8)) == nil)
        XCTAssertEqual(XrayRefs.parse(Self.object(refs: "[]"))?.entries.count, 0)
    }

    func testOverlongKeyOrTextIsDropped() throws {
        let long = String(repeating: "a", count: 70_000), at = String(repeating: "b", count: 256)
        let refs = #"""
        [{"key":"issue:#\#(long)","shape":"issue","text":"#12","count":1},\#
        {"key":"ticket:X-1","shape":"ticket","text":"\#(at)x","count":1},\#
        {"key":"ticket:X-2","shape":"ticket","text":"\#(at)","count":1},\#
        {"key":"ticket:X-3","shape":"ticket","text":"X-3","count":1}]
        """#
        let r = try XCTUnwrap(XrayRefs.parse(Self.object(refs: refs)))
        XCTAssertEqual(r.entries.map(\.key), ["ticket:X-2", "ticket:X-3"], "a >64 KB key and a 257-byte text go; 256 bytes stay")
    }

    func testBidiAndControlCharactersInTitleAreStripped() throws {
        let refs = ##"[{"key":"issue:#831","shape":"issue","text":"#831","count":1,"title":"Agent\u202e pa\u0007nes\u200b"}]"##
        let r = try XCTUnwrap(XrayRefs.parse(Self.object(refs: refs)))
        XCTAssertEqual(r.entries.first?.title, "Agent panes")
    }

    func testDroppedKeysAndRowsPastTheCapCount() throws {
        let one = #"{"key":"ticket:API-1","shape":"ticket","text":"API-1","count":1}"#
        let many = "[" + Array(repeating: one, count: XrayRefs.maxRows + 3).joined(separator: ",") + "]"
        let r = try XCTUnwrap(XrayRefs.parse(Self.object(refs: many, dropped: 5)))
        XCTAssertEqual(r.entries.count, XrayRefs.maxRows)
        XCTAssertEqual(r.droppedKeys, 8, "dch's 5 and the 3 past the cap")
        let neg = try XCTUnwrap(XrayRefs.parse(Self.object(refs: "[]", dropped: -2)))
        XCTAssertEqual(neg.droppedKeys, 0)
    }

    /// dch's order: latest mention first, then count, then later in dch's list first.
    func testOrder() throws {
        let r = try XCTUnwrap(XrayRefs.parse(Self.object(refs: Self.six)))
        XCTAssertEqual(r.ordered.map(\.text),
                       ["acme/api#7", "API-12", "#831", "src/main.c:12", "abc1234", "https://example.org/acme/api"])
        let old = ##"[{"key":"issue:#11","shape":"issue","text":"#11","count":1},{"key":"issue:#12","shape":"issue","text":"#12","count":1},{"key":"issue:#13","shape":"issue","text":"#13","count":4}]"##
        let o = try XCTUnwrap(XrayRefs.parse(Self.object(refs: old)))
        XCTAssertEqual(o.ordered.map(\.text), ["#13", "#12", "#11"], "no last_offset (dch < 1.62.0): by count, then later first")
    }

    /// #1560 (dch README v1.99.0 "other_projects" :1461, :1468-1470): read as a bounded int, 0 when missing, negative or
    /// not a number (red with the field unread: 3 reads 0).
    func testOtherProjectsIsReadBounded() throws {
        func with(_ v: String?) throws -> XrayRefs {
            let base = String(decoding: Self.object(refs: "[]"), as: UTF8.self)
            let o = v.map { base.replacingOccurrences(of: #""dropped_keys":0}"#, with: #""dropped_keys":0,"other_projects":"# + $0 + "}") } ?? base
            return try XCTUnwrap(XrayRefs.parse(Data(o.utf8)))
        }
        XCTAssertEqual(try with("3").otherProjects, 3)
        XCTAssertEqual(try with(nil).otherProjects, 0, "a dch before the field")
        XCTAssertEqual(try with("0").otherProjects, 0)
        XCTAssertEqual(try with("-4").otherProjects, 0)
        XCTAssertEqual(try with(#""3""#).otherProjects, 0, "a string is no count")
    }
}
