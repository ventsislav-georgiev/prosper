import XCTest
@testable import ProsperApp

/// #1625 (dch #516, 1.113.0 `--since`): the "since you were last here" recap: the parse pinned to dch's shape (fixture
/// Tests/Fixtures/dch-xray-since, from dch README v1.113.0:2135, fakes only), the 30 min gap, the version gate, the
/// --requests form, OutsideText on every drawn string, dismiss and the chapter jump. Fake runs; no dch, no process, no
/// window shown, no event posted.
@MainActor
final class XrayRecapTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/dch-xray-since", isDirectory: true)
    static func fixture() throws -> Data { try Data(contentsOf: dir.appendingPathComponent("since-1.113.0.json")) }
    static let t0 = Date(timeIntervalSince1970: 1_795_046_400)
    let api = XrayTarget(name: "api", dir: "/Users/example/.dch")
    let qa = XrayTarget(name: "api-qa", dir: "/Users/example/.dch")

    static func json(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }

    // MARK: parse

    /// dch's shape: both chapters (a null title kept nil), in dch's order; #1764: the file ref dropped, the pull kept.
    func testParseFullFixture() throws {
        let r = try XCTUnwrap(XrayRecap.parse(Self.fixture()))
        XCTAssertEqual(r.chapters.map(\.anchor), ["f1a2:9120", "f1a2:4096"])
        XCTAssertEqual(r.chapters.first?.title, "Fix the login test")
        XCTAssertTrue(r.chapters.last?.title == nil)
        XCTAssertEqual(r.chapters.first?.at, Date(timeIntervalSince1970: 1_795_047_000))
        XCTAssertEqual(r.refs.map(\.key), ["pull:o/r#41"], "#1764: no file path")
        XCTAssertEqual(r.refs.first?.count, 2)
        XCTAssertEqual(r.since, Self.t0)
        XCTAssertFalse(r.more)
        XCTAssertFalse(r.partial)
        XCTAssertEqual(r.headline(now: Self.t0 + 2 * 3600), "Away 2h \u{00B7} 2 new prompts")
        XCTAssertEqual(r.refChips, ["o/r#41 \u{00D7}2"])
        XCTAssertEqual(r.moreRefs, 0)
    }

    /// Empty lists: a recap that is empty (no strip); a bad schema or a missing list: nil.
    func testParseEmptyAndRefused() {
        let empty = XrayRecap.parse(Self.json(["schema": 1, "chapters": [], "refs": [], "more": false, "partial": false]))
        XCTAssertEqual(empty?.isEmpty, true)
        XCTAssertTrue(XrayRecap.parse(Self.json(["schema": 2, "chapters": [], "refs": []])) == nil)
        XCTAssertTrue(XrayRecap.parse(Self.json(["schema": 1, "chapters": []])) == nil)
        XCTAssertTrue(XrayRecap.parse(Data("not json".utf8)) == nil)
    }

    /// `partial` true says only the newest; a count that is not a JSON integer in range is 1; a row with no anchor or
    /// key is skipped; `more` must be the boolean true.
    func testParsePartialAndBadRows() throws {
        let r = try XCTUnwrap(XrayRecap.parse(Self.json([
            "schema": 1, "partial": true, "more": 1,
            "chapters": [["turn_title": "no anchor"], ["chapter": "a:1", "turn_title": "kept"], "not an object"],
            "refs": [["key": "k1", "shape": "issue", "text": "one", "count": true], ["key": "k2", "shape": "issue", "text": "two", "count": -4],
                     ["shape": "issue", "text": "no key"]],
        ])))
        XCTAssertTrue(r.partial)
        XCTAssertFalse(r.more, "1 is not the boolean true")
        XCTAssertEqual(r.chapters.map(\.anchor), ["a:1"])
        XCTAssertEqual(r.refs.map(\.count), [1, 1])
        XCTAssertEqual(r.headline(now: Self.t0), "1 new prompt \u{00B7} newest only", "no since: no Away part")
    }

    /// Over dch's caps: 20 chapters and 30 refs kept, `more` set although dch said false.
    func testParseOverCap() throws {
        let cs = (0..<25).map { ["chapter": "c:\($0)", "turn_title": "t\($0)"] as [String: Any] }
        let rs = (0..<35).map { ["key": "k\($0)", "shape": "ticket", "text": "r\($0)", "count": 1] as [String: Any] }
        let r = try XCTUnwrap(XrayRecap.parse(Self.json(["schema": 1, "chapters": cs, "refs": rs, "more": false])))
        XCTAssertEqual(r.chapters.count, XrayRecap.maxChapters)
        XCTAssertEqual(r.refs.count, XrayRecap.maxRefs)
        XCTAssertEqual(r.chapters.last?.anchor, "c:19")
        XCTAssertTrue(r.more)
        XCTAssertEqual(r.headline(now: Self.t0), "20+ new prompts")
        XCTAssertEqual(r.moreRefs, XrayRecap.maxRefs - XrayRecap.shownRefs)
    }

    /// #1630: a valid recap one byte over XrayChapters.maxBytes is refused; the same at the cap parses. Red without the
    /// `data.count <= XrayChapters.maxBytes` gate in parse.
    func testParseRefusesOverMaxBytes() {
        func padded(_ n: Int) -> Data {
            let head = Data(#"{"schema":1,"chapters":[],"refs":[],"pad":""#.utf8), tail = Data(#""}"#.utf8)
            return head + Data(repeating: 0x61, count: n - head.count - tail.count) + tail
        }
        XCTAssertTrue(XrayRecap.parse(padded(XrayChapters.maxBytes)) != nil, "at the cap")
        XCTAssertTrue(XrayRecap.parse(padded(XrayChapters.maxBytes + 1)) == nil, "one over")
    }

    // MARK: gap

    /// First focus: none; back under 30 min: none; back at 30 min or more: since = when it left; the same target
    /// again: none; a clock that went back: none.
    func testGapRule() {
        var c = XrayRecapClock()
        XCTAssertTrue(c.focus(api, now: Self.t0) == nil, "first focus")
        XCTAssertTrue(c.focus(qa, now: Self.t0) == nil, "first focus of api-qa; api left at t0")
        XCTAssertTrue(c.focus(api, now: Self.t0 + 29 * 60) == nil, "under 30 min")
        XCTAssertTrue(c.focus(api, now: Self.t0 + 99 * 60) == nil, "the same target")
        XCTAssertEqual(c.focus(qa, now: Self.t0 + 59 * 60), Self.t0 + 29 * 60, "30 min since api-qa left")
        _ = c.focus(nil, now: Self.t0 + 60 * 60)   // the app went away; api-qa left
        XCTAssertTrue(c.focus(qa, now: Self.t0 + 20 * 60) == nil, "a clock that went back 40 min")
        XCTAssertEqual(c.current, qa)
    }

    /// The memory is bounded: past maxKept the oldest stamp goes.
    func testClockIsBounded() {
        var c = XrayRecapClock()
        for i in 0...(XrayRecapClock.maxKept + 1) { _ = c.focus(XrayTarget(name: "s\(i)", dir: "/d"), now: Self.t0 + Double(i)) }
        XCTAssertTrue(c.left.count <= XrayRecapClock.maxKept)
        XCTAssertTrue(c.left[XrayTarget(name: "s0", dir: "/d")] == nil)
    }

    // MARK: version gate, argv and the --requests form

    func testVersionGate() {
        XCTAssertFalse(XrayRecap.supported(nil))
        XCTAssertFalse(XrayRecap.supported([1, 112, 9]))
        XCTAssertTrue(XrayRecap.supported([1, 113, 0]))
        XCTAssertTrue(XrayRecap.supported([1, 114, 0]))
    }

    func testSinceArgsAndRequestForm() {
        XCTAssertEqual(api.sinceArgs(Self.t0 + 0.9), ["--xray", "api", "--since", "1795046400", "--json"])
        let remote = XrayTarget(name: "box:api", dir: nil)
        let a = remote.sinceArgs(Self.t0)
        XCTAssertEqual(XrayRequests.form(a, name: "box:api", since: true), ["--since", "1795046400", "--json"])
        XCTAssertTrue(XrayRequests.form(a, name: "box:api", since: false) == nil, "an older local dch: cold")
        XCTAssertTrue(XrayRequests.form(["--xray", "box:api", "--since", "1h"], name: "box:api", since: true) == nil, "no --json")
        XCTAssertTrue(XrayRequests.form(["--xray", "box:api", "--since", "1h", "--tasks", "--json"], name: "box:api", since: true) == nil)
    }

    // MARK: the read, OutsideText and dismiss

    /// A recaps object with fake seams; `answer` is what the fake dch says.
    func recaps(version: [Int] = [1, 113, 0], answer: Data, status: Int32 = 0, seen: Box? = nil) -> XrayRecaps {
        let r = XrayRecaps()
        var t = Self.t0
        r.now = { t }
        r.dch = { "/fake/dch" }
        r.version = { version }
        r.run = { _ in { _, args, _ in seen?.args.append(args); return (status, answer) } }
        advance = { t += $0 }
        return r
    }
    var advance: (TimeInterval) -> Void = { _ in }
    final class Box: @unchecked Sendable { var args: [[String]] = [] }

    func settle(_ r: XrayRecaps) async {
        for _ in 0..<200 where r.shown == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Back after the gap on 1.113.0: one read from the leave time and the strip; back early: no read.
    func testFocusAfterGapReadsOnce() async throws {
        let seen = Box()
        let r = recaps(answer: try Self.fixture(), seen: seen)
        r.focus(api)
        r.focus(qa)            // api left at t0
        advance(10 * 60)
        r.focus(api)           // 10 min: no read
        XCTAssertEqual(r.reads, 0)
        r.focus(qa)            // api left at t0 + 10 min
        advance(30 * 60)
        r.focus(api)
        XCTAssertEqual(r.reads, 1)
        await settle(r)
        XCTAssertEqual(r.shown?.target, api)
        XCTAssertEqual(seen.args.last, ["--xray", "api", "--since", "1795047000", "--json"])
    }

    /// Below 1.113.0: no read, no strip, whatever the gap.
    func testOlderDchReadsNothing() async throws {
        let r = recaps(version: [1, 112, 0], answer: try Self.fixture())
        r.focus(api)
        r.focus(qa)
        advance(60 * 60)
        r.focus(api)
        XCTAssertEqual(r.reads, 0)
        XCTAssertTrue(r.shown == nil)
    }

    /// A failed read, an empty answer or a focus that moved on: no strip.
    func testTakeRefusesFailuresAndStaleTargets() throws {
        let r = recaps(answer: Data())
        r.focus(api)
        r.take((1, try Self.fixture()), for: api)
        XCTAssertTrue(r.shown == nil, "exit 1")
        r.take((0, Self.json(["schema": 1, "chapters": [], "refs": []])), for: api)
        XCTAssertTrue(r.shown == nil, "empty")
        r.take((0, try Self.fixture()), for: qa)
        XCTAssertTrue(r.shown == nil, "not the focused target")
        r.take((0, try Self.fixture()), for: api)
        XCTAssertEqual(r.shown?.target, api)
    }

    /// The x (dismiss), a leave and a focus move each end the strip; a leave of another target keeps it.
    func testDismiss() throws {
        let r = recaps(answer: Data())
        r.focus(api)
        r.take((0, try Self.fixture()), for: api)
        r.dismiss()
        XCTAssertTrue(r.shown == nil, "x / keystroke")
        r.take((0, try Self.fixture()), for: api)
        r.focus(api)
        XCTAssertEqual(r.shown?.target, api, "the same target again keeps it")
        r.leave(qa)
        XCTAssertEqual(r.shown?.target, api, "another target's leave")
        r.leave(api)
        XCTAssertTrue(r.shown == nil, "leave")
        r.focus(api)
        r.take((0, try Self.fixture()), for: api)
        r.focus(qa)
        XCTAssertTrue(r.shown == nil, "focus moved")
    }

    /// Every drawn string goes through OutsideText: controls, bidi overrides and zero-width scalars dropped, cut.
    func testOutsideTextCleaning() throws {
        let r = try XCTUnwrap(XrayRecap.parse(Self.json([
            "schema": 1,
            "chapters": [["chapter": "a:1", "turn_title": "Fix\u{202E}\u{7} the\u{200B} test"], ["chapter": "a:2", "turn_title": "\u{200B}\u{2800}"],
                         ["chapter": "a:3", "turn_title": String(repeating: "x", count: 200)]],
            "refs": [["key": "k", "shape": "pull", "text": "o/r\u{1B}[31m#41\u{2066}", "count": 3]],
        ])))
        XCTAssertEqual(r.chapters.first.map(XrayRecap.title), "Fix the test")
        XCTAssertEqual(r.chapters.dropFirst().first.map(XrayRecap.title), "Untitled turn")
        XCTAssertEqual(r.chapters.last.map(XrayRecap.title)?.count, XrayRecap.shortTitle, "#1764: one long word cut at the cap")
        XCTAssertEqual(r.chapters.last.map(XrayRecap.fullTitle)?.count, TranscriptOutline.titleCap, "the tooltip: the whole title")
        XCTAssertEqual(r.refChips, ["o/r[31m#41 \u{00D7}3"])
    }

    // MARK: the chapter jump

    /// A title the panel's chapters hold opens that chapter; another opens one titled from the recap under the
    /// recap ordinal, whose anchor replaces the last recap anchor.
    func testChapterJump() {
        let p = XrayPanelModel(target: api, tab: .prompts)
        p.dchChapters = [TranscriptOutline.Chapter(id: 0, ordinal: 5, title: "Known", kind: .prompt, hasError: false)]
        p.chapterAnchors = ["f1a2:9120": 5]
        p.openRecapChapter(XrayRecap.Chapter(anchor: "f1a2:9120", title: "Fix the login test", at: nil))
        XCTAssertEqual(p.chapterCard?.title, "Known")
        p.openRecapChapter(XrayRecap.Chapter(anchor: "f1a2:1", title: "Older", at: nil))
        XCTAssertEqual(p.chapterCard?.ordinal, XrayPanelModel.recapOrdinal)
        XCTAssertEqual(p.chapterCard?.title, "Older")
        p.openRecapChapter(XrayRecap.Chapter(anchor: "f1a2:2", title: nil, at: nil))
        XCTAssertEqual(p.chapterAnchors.filter { $0.value == XrayPanelModel.recapOrdinal }.map(\.key), ["f1a2:2"])
        XCTAssertEqual(p.chapterAnchors["f1a2:9120"], 5)
    }

    // MARK: #1764 friendly and short

    static func chapter(_ i: Int, _ title: String) -> [String: Any] { ["chapter": "a:\(i)", "turn_title": title] }

    /// Harness turns are dropped at parse and never counted: a title opening with a tag, or "[Request interrupted".
    /// A tag later in the title, or a "<" that is no tag, is the person's. Red at TIP: 9 chapters, "<task-notification>" shown.
    func testHarnessTurnsDroppedAtParse() throws {
        let titles = ["<task-notification>\n<task-id>b1</task-id>", "  <system-reminder>keep going", "<command-name>/clear</command-name>",
                      "<local-command-stdout></local-command-stdout>", "[Request interrupted by user]", "Fix the login test",
                      "Wrap <b> in a span", "<3 thanks, ship it", "<task-notification id=\"1\">"]
        let r = try XCTUnwrap(XrayRecap.parse(Self.json([
            "schema": 1, "since": Self.t0.timeIntervalSince1970, "refs": [],
            "chapters": titles.enumerated().map { Self.chapter($0.offset, $0.element) },
        ])))
        XCTAssertEqual(r.chapters.map(\.title), ["Fix the login test", "Wrap <b> in a span", "<3 thanks, ship it"])
        XCTAssertEqual(r.headline(now: Self.t0 + 45 * 60), "Away 45m \u{00B7} 3 new prompts")
    }

    /// Nothing the person wrote and no refs: no strip. Refs alone still make one. Red at TIP: a <task-notification> strip.
    func testAllHarnessGivesNoStrip() throws {
        let harness = [Self.chapter(1, "<task-notification>"), Self.chapter(2, "[Request interrupted by user for tool use]")]
        let none = try XCTUnwrap(XrayRecap.parse(Self.json(["schema": 1, "chapters": harness, "refs": [
            ["key": "file:/Users/example/api/main.swift", "shape": "file", "text": "main.swift", "count": 7]]])))
        XCTAssertTrue(none.isEmpty, "harness turns and a file ref: nothing to show")
        let r = recaps(answer: Data())
        r.focus(api)
        r.take((0, Self.json(["schema": 1, "chapters": harness, "refs": []])), for: api)
        XCTAssertTrue(r.shown == nil, "no strip")
        let refsOnly = try XCTUnwrap(XrayRecap.parse(Self.json(["schema": 1, "since": Self.t0.timeIntervalSince1970, "chapters": harness,
                                                                 "refs": [["key": "ticket:FT-1", "shape": "ticket", "text": "FT-1", "count": 1]]])))
        XCTAssertFalse(refsOnly.isEmpty)
        XCTAssertEqual(refsOnly.headline(now: Self.t0 + 3 * 3600), "Away 3h \u{00B7} no new prompts")
    }

    /// The headline's forms: the span from since (m, h, d, floored), singular, the cap, partial, a clock that went back.
    /// Red at TIP: no headline(now:) ("Since you were last here: ... chapters").
    func testHeadlineForms() {
        func h(_ n: Int, more: Bool = false, partial: Bool = false, away: TimeInterval) -> String {
            XrayRecap(since: Self.t0, chapters: (0..<n).map { .init(anchor: "a:\($0)", title: "t", at: nil) }, refs: [],
                      more: more, partial: partial).headline(now: Self.t0 + away)
        }
        XCTAssertEqual(h(13, away: 5 * 60), "Away 5m \u{00B7} 13 new prompts")
        XCTAssertEqual(h(1, away: 2 * 3600 + 59 * 60), "Away 2h \u{00B7} 1 new prompt")
        XCTAssertEqual(h(13, more: true, away: 3 * 86400 + 5), "Away 3d \u{00B7} 13+ new prompts")
        XCTAssertEqual(h(1, more: true, away: 59 * 60), "Away 59m \u{00B7} 1+ new prompts")
        XCTAssertEqual(h(4, partial: true, away: 3600), "Away 1h \u{00B7} 4 new prompts \u{00B7} newest only")
        XCTAssertEqual(h(2, away: -600), "Away 0m \u{00B7} 2 new prompts", "a clock that went back")
        for (headline, word) in [(h(2, away: 60), "chapter"), (h(1, away: 60), "Since you were")] {
            XCTAssertFalse(headline.contains(word), headline)
        }
    }

    /// Titles: at most 32 characters, cut at the last word boundary (trailing punctuation dropped) with an ellipsis; a
    /// short one whole; the full title for the tooltip. Red at TIP: a 60-character cut mid-word, no ellipsis rule.
    func testTitleCutAtWordBoundary() {
        func c(_ t: String) -> XrayRecap.Chapter { .init(anchor: "a:1", title: t, at: nil) }
        let long = "perf-qa #212: confirmed for 20 Nov as a timer artefact of the run"
        XCTAssertEqual(XrayRecap.title(c(long)), "perf-qa #212: confirmed for 20\u{2026}")
        XCTAssertEqual(XrayRecap.title(c("Fix the flaky login test: retry on timeout")), "Fix the flaky login test\u{2026}")
        XCTAssertEqual(XrayRecap.title(c("Fix the login test")), "Fix the login test")
        XCTAssertEqual(XrayRecap.title(c(String(repeating: "a", count: 32))).count, 32, "at the cap: whole")
        XCTAssertEqual(XrayRecap.fullTitle(c(long)), long)
        XCTAssertEqual(XrayRecap.shownChapters, 2)
    }

    /// Refs: only tickets (OQ ids among them), PRs and issues, by shape; most mentioned first, dch's order on a tie; the
    /// top 3 as chips, "\u{00D7}N" only above 1; the rest counted for "+N more". Red at TIP: the file path shown x7.
    func testRefsKeepOnlyTicketsPullsAndIssues() throws {
        let rs: [[String: Any]] = [
            ["key": "file:/Users/example/api/main.swift", "shape": "file", "text": "/Users/example/api/main.swift", "count": 7],
            ["key": "url:https://example.com", "shape": "url", "text": "example.com", "count": 6],
            ["key": "commit:abc1234", "shape": "commit", "text": "abc1234", "count": 6],
            ["key": "term:MAX_SIZE", "shape": "term", "text": "MAX_SIZE", "count": 6],
            ["key": "odd:1", "shape": "odd", "text": "odd", "count": 6],
            ["key": "noshape", "text": "no shape", "count": 6],
            ["key": "issue:#212", "shape": "issue", "text": "#212", "count": 3],
            ["key": "ticket:FT-1", "shape": "ticket", "text": "FT-1", "count": 1],
            ["key": "ticket:OQ-12", "shape": "ticket", "text": "OQ-12", "count": 5],
            ["key": "pull:o/r#41", "shape": "pull", "text": "o/r#41", "count": 1],
        ]
        let r = try XCTUnwrap(XrayRecap.parse(Self.json(["schema": 1, "chapters": [], "refs": rs])))
        XCTAssertEqual(r.refs.map(\.key), ["ticket:OQ-12", "issue:#212", "ticket:FT-1", "pull:o/r#41"])
        XCTAssertEqual(r.refChips, ["OQ-12 \u{00D7}5", "#212 \u{00D7}3", "FT-1"])
        XCTAssertEqual(r.moreRefs, 1)
    }

    /// The recap card's heading is "Earlier prompt", never "Prompt -1"; a panel prompt keeps "Prompt 3". Red at TIP.
    func testRecapCardHeading() {
        let o = XrayPanelModel.recapOrdinal
        let recap = TranscriptOutline.Chapter(id: o, ordinal: o, title: "Older", kind: .prompt, hasError: false)
        XCTAssertEqual(XrayChapterCard.heading(recap), "Earlier prompt")
        let known = TranscriptOutline.Chapter(id: 0, ordinal: 3, title: "Known", kind: .prompt, hasError: false)
        XCTAssertEqual(XrayChapterCard.heading(known), "Prompt 3")
    }
}
