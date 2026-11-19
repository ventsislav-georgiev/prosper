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

    /// dch's shape: both chapters (a null title kept nil), both refs, in dch's order. Red at TIP: no XrayRecap.
    func testParseFullFixture() throws {
        let r = try XCTUnwrap(XrayRecap.parse(Self.fixture()))
        XCTAssertEqual(r.chapters.map(\.anchor), ["f1a2:9120", "f1a2:4096"])
        XCTAssertEqual(r.chapters.first?.title, "Fix the login test")
        XCTAssertTrue(r.chapters.last?.title == nil)
        XCTAssertEqual(r.chapters.first?.at, Date(timeIntervalSince1970: 1_795_047_000))
        XCTAssertEqual(r.refs.map(\.key), ["pull:o/r#41", "file:/Users/example/api/main.swift"])
        XCTAssertEqual(r.refs.first?.count, 2)
        XCTAssertEqual(r.since, Self.t0)
        XCTAssertFalse(r.more)
        XCTAssertFalse(r.partial)
        XCTAssertEqual(r.headline, "Since you were last here: 2 chapters")
        XCTAssertEqual(r.refsLine, "o/r#41 \u{00D7}2, main.swift")
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
            "refs": [["key": "k1", "text": "one", "count": true], ["key": "k2", "text": "two", "count": -4], ["text": "no key"]],
        ])))
        XCTAssertTrue(r.partial)
        XCTAssertFalse(r.more, "1 is not the boolean true")
        XCTAssertEqual(r.chapters.map(\.anchor), ["a:1"])
        XCTAssertEqual(r.refs.map(\.count), [1, 1])
        XCTAssertEqual(r.headline, "Since you were last here: 1 chapter (only the newest)")
    }

    /// Over dch's caps: 20 chapters and 30 refs kept, `more` set although dch said false.
    func testParseOverCap() throws {
        let cs = (0..<25).map { ["chapter": "c:\($0)", "turn_title": "t\($0)"] as [String: Any] }
        let rs = (0..<35).map { ["key": "k\($0)", "text": "r\($0)", "count": 1] as [String: Any] }
        let r = try XCTUnwrap(XrayRecap.parse(Self.json(["schema": 1, "chapters": cs, "refs": rs, "more": false])))
        XCTAssertEqual(r.chapters.count, XrayRecap.maxChapters)
        XCTAssertEqual(r.refs.count, XrayRecap.maxRefs)
        XCTAssertEqual(r.chapters.last?.anchor, "c:19")
        XCTAssertTrue(r.more)
        XCTAssertEqual(r.headline, "Since you were last here: 20+ chapters")
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
            "refs": [["key": "k", "text": "o/r\u{1B}[31m#41\u{2066}", "count": 3]],
        ])))
        XCTAssertEqual(r.chapters.first.map(XrayRecap.title), "Fix the test")
        XCTAssertEqual(r.chapters.dropFirst().first.map(XrayRecap.title), "Untitled turn")
        XCTAssertEqual(r.chapters.last.map(XrayRecap.title)?.count, 60)
        XCTAssertEqual(r.refsLine, "o/r[31m#41 \u{00D7}3")
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
}
