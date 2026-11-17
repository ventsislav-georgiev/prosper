import XCTest
@testable import ProsperApp

/// #1489 (dch 1.93.0, dch #458): "term" refs. Literal JSON and a fake runner; no dch, no window, no popover, no pasteboard.
@MainActor
final class XrayRefTermTests: XCTestCase {
    override func setUp() { XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 93, 0]) }
    override func tearDown() { XrayPanels.probed = nil }

    /// Terms as dch writes them (no backticks in text; CONST_CASE, snake_case, a backtick-only identifier, a dashed one), newer than the issue and the ticket; one unknown shape.
    nonisolated static let refs = #"""
    [{"key":"issue:#831","shape":"issue","text":"#831","count":1,"last_offset":100,"title":"Agent panes"},\#
    {"key":"term:ERR_LEDGER_SKEW","shape":"term","text":"ERR_LEDGER_SKEW","count":3,"last_offset":900,"defined":false,"definitions":0},\#
    {"key":"term:test_retry_timeout","shape":"term","text":"test_retry_timeout","count":2,"last_offset":800,"defined":false},\#
    {"key":"term:dryRun","shape":"term","text":"dryRun","count":1,"last_offset":700,"defined":false},\#
    {"key":"term:--ref","shape":"term","text":"--ref","count":1,"last_offset":600,"defined":false},\#
    {"key":"ticket:API-12","shape":"ticket","text":"API-12","count":1,"last_offset":50},\#
    {"key":"epic:E-1","shape":"epic","text":"E-1","count":1,"last_offset":10}]
    """#

    func parsed() throws -> XrayRefs { try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs: Self.refs))) }

    /// Red on the old line `enum Shape ... case issue, pull, ticket, commit, file, url }` (a term parses to shape nil).
    func testTermsParseToTheTermShapeAndAnUnknownShapeStaysGeneric() throws {
        let r = try parsed()
        XCTAssertEqual(r.entries.map(\.shape), [.issue, .term, .term, .term, .term, .ticket, nil])
        XCTAssertTrue(r.entries.filter { $0.shape == .term }.allSatisfy { !$0.defined })
        let epic = try XCTUnwrap(r.entries.last)
        XCTAssertEqual(XrayRefRow(epic, complete: true, home: "/Users/example", cwd: nil).spoken, "Ref E-1, 1 mention")
    }

    /// Red on the old byDefault/ordered: terms are shown by default (ruling) and sort after issues and tickets, though newer.
    func testTermsAreShownByDefaultAfterIssuesAndTickets() throws {
        let r = try parsed()
        XCTAssertTrue(r.entries.filter { $0.shape == .term }.allSatisfy { XrayRefs.byDefault($0) }, "term: shown without \"a\"")
        XCTAssertEqual(r.ordered.map(\.text), ["#831", "API-12", "E-1", "ERR_LEDGER_SKEW", "test_retry_timeout", "dryRun", "--ref"],
                       "newer terms still after the older issue, ticket and generic row")
    }

    /// Red on the old kind(): no "Term" word, so the row spoke "Ref ERR_LEDGER_SKEW".
    func testTermRowSpeaksItsKind() throws {
        let t = try XCTUnwrap(try parsed().entries.first { $0.text == "ERR_LEDGER_SKEW" })
        XCTAssertEqual(XrayRefRow(t, complete: true, home: "/Users/example", cwd: nil).spoken, "Term ERR_LEDGER_SKEW, 3 mentions")
        XCTAssertEqual(XrayRefRow.kind(.term), "Term")
        XCTAssertEqual(XrayRefPopover.header(t, complete: true, home: "/Users/example", cwd: nil), ["Term ERR_LEDGER_SKEW", "3 mentions"])
    }

    func openTerm(_ text: String, version: [Int]) async throws -> (XrayRefRunTests.Run, XrayPanelModel) {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: version)
        let e = try XCTUnwrap(try parsed().entries.first { $0.text == text })
        let run = XrayRefRunTests.Run(), panels = XrayPanels()
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
        (p.dch, p.run) = ("/fake/dch", run.run)
        p.panels = panels
        p.presentRef = { _, _, _ in }
        p.openRef(e)
        await panels.refReading?.value
        return (run, p)
    }

    /// dch's --ref wants a term in its backticks (the key "term:x" is no ref text): sent wrapped on stdin from 1.84.0 and in
    /// argv before it, while the card and the row keep the bare text. Red on the old openRef(e.text): bare send, and "--ref" refused.
    func testTermIsSentInBackticksButShownBare() async throws {
        for text in ["dryRun", "ERR_LEDGER_SKEW", "--ref"] {
            let wrapped = "`" + text + "`"
            for (version, onStdin) in [([1, 93, 0], true), ([1, 83, 0], false)] {
                let (run, p) = try await openTerm(text, version: version)
                XCTAssertEqual(run.calls.count, 1, text)
                XCTAssertEqual(run.calls.last?[3], onStdin ? "-" : wrapped, text)
                XCTAssertEqual(run.stdins.last ?? nil, onStdin ? wrapped + "\n" : nil, text)
                XCTAssertEqual(p.refContext?.ref, text, "the card names the bare text")
                XCTAssertEqual(p.refCard?.text, text)
                XCTAssertTrue(p.refNote == nil, text)
            }
        }
    }

    /// A term text holding a backtick is no term dch writes: never sent, the card says it is not a ref.
    func testTermHoldingABacktickIsNotRun() async throws {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 93, 0])
        let e = try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs:
            #"[{"key":"term:a`b","shape":"term","text":"a`b","count":1,"last_offset":1}]"#))?.entries.first)
        let run = XrayRefRunTests.Run(), panels = XrayPanels()
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
        (p.dch, p.run) = ("/fake/dch", run.run)
        p.panels = panels
        p.presentRef = { _, _, _ in }
        p.openRef(e)
        XCTAssertTrue(run.calls.isEmpty)
        XCTAssertEqual(p.refNote, XrayPanelModel.refNotARef)
    }

    /// A non-term row is sent as written (no wrap): red if the wrap leaks to every shape.
    func testNonTermRefIsSentUnwrapped() async throws {
        let (run, _) = try await openTerm("#831", version: [1, 93, 0])
        XCTAssertEqual(run.stdins.last ?? nil, "#831\n")
    }

    static let first = ##"{"schema":1,"first":{"session":"api","key":"term:ERR_LEDGER_SKEW","shape":"term","text":"ERR_LEDGER_SKEW"}}"##
    static let termDef = #"{"schema":1,"definition":{"session":"api","at":1794304803,"title":"","passage":"Retry on ERR_LEDGER_SKEW\u202e only once.","rule":"term","source":"first mention"}}"#

    /// Red on the old popover: the term's definition was labelled by its (empty) title. The sentence goes through OutsideText.
    func testPopoverShowsTheFirstMentionSentence() throws {
        let c = XrayRefContext(XrayRefStreamTests.parse([Self.first, Self.termDef, XrayRefStreamTests.done]),
                               ref: "ERR_LEDGER_SKEW", tasks: nil, memory: nil)
        XCTAssertEqual(c.shape, .term)
        let d = try XCTUnwrap(c.definitions.first)
        XCTAssertEqual(XrayRefPopover.label(d), "First mention")
        XCTAssertEqual(d.passage, "Retry on ERR_LEDGER_SKEW only once.", "the direction override is cleaned, not shown raw")
        XCTAssertEqual(XrayRefPopover.label(try XCTUnwrap(XrayRefStreamTests.parse([XrayRefStreamTests.definition]).definitions.first)),
                       "Login retries", "any other rule keeps its title")
    }
}
