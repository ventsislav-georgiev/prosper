import XCTest
@testable import ProsperApp

/// #1416 (#1356 step 2): XrayRefStream.parse over `dch --xray <n> --ref <text> --full --json`'s NDJSON. Literal fake
/// lines in the shape of dch v1.82.0's goldens (tests/xray/fixtures/refs-defs/expected/2.ndjson, refs-full), acme names.
/// No dch, no process, no window.
final class XrayRefStreamTests: XCTestCase {
    static let first = ##"{"schema":1,"first":{"session":"api","session_id":"0b1f6a52-4c1e-4d7a-9a51-2f6d8c3e7a10","key":"issue:#12","shape":"issue","text":"#12","project":"-Users-example-acme","mode":"full","scope":"project","budget_ms":null,"elapsed_ms":0}}"##
    static let mention0 = #"{"schema":1,"mention":{"session":"api","chapter":"f12:0","at":1794304801,"line":"Work on #12 please","offset":0,"live":false,"project":"-Users-example-acme"}}"#
    static let definition = #"{"schema":1,"definition":{"session":"api","live":false,"project":"-Users-example-acme","at":1794304803,"title":"Login retries","passage":"The login retries twice.\nSecond line.","rule":"D1","offset":376,"chapter":"f12:376"}}"#
    static let mention1 = ##"{"schema":1,"mention":{"session":"api","chapter":"f12:376","at":1794304803,"line":"# #12 Login retries","offset":376,"live":false,"project":"-Users-example-acme"}}"##
    static let tally = #"{"schema":1,"tally":{"session":"api","live":false,"project":"-Users-example-acme","count":2,"definitions":1,"partial":false,"mentions_dropped":0}}"#
    static let progress = #"{"schema":1,"progress":{"files":1,"bytes":900,"partial":true,"counts":{"session":2,"project":0,"project_sessions":0,"all":null,"all_sessions":null}}}"#
    static let done = #"{"schema":1,"done":true,"partial":false,"counts":{"session":2,"project":3,"project_sessions":1,"all":null,"all_sessions":null},"why":null,"files":2,"bytes":22827,"lines_too_long":0}"#

    static func parse(_ lines: [String]) -> XrayRefStream { XrayRefStream.parse(Data(lines.joined(separator: "\n").utf8)) }
    static var golden: [String] { [first, mention0, definition, mention1, tally, done] }

    func testGoldenShapeParsesEveryKind() {
        let s = Self.parse(Self.golden)
        XCTAssertEqual(s.first, XrayRefStream.First(session: "api", key: "issue:#12", shape: "issue", text: "#12", elapsed: 0))
        XCTAssertEqual(s.definitions.count, 1)
        XCTAssertEqual(s.definitions.first?.title, "Login retries")
        XCTAssertEqual(s.definitions.first?.passage, "The login retries twice.\nSecond line.")
        XCTAssertEqual(s.definitions.first?.rule, "D1")
        XCTAssertEqual(s.definitions.first?.chapter, "f12:376")
        XCTAssertEqual(s.definitions.first?.command, false)
        XCTAssertEqual(s.mentions.map(\.line), ["Work on #12 please", "# #12 Login retries"])
        XCTAssertEqual(s.mentions.map(\.offset), [0, 376])
        XCTAssertEqual(s.tallies, [XrayRefStream.Tally(session: "api", count: 2, mentionsDropped: 0)])
        XCTAssertEqual(s.counts, XrayRefStream.Counts(session: 2, project: 3, projectSessions: 1, all: nil, allSessions: nil))
        XCTAssertTrue(s.done)
        XCTAssertFalse(s.partial)
        XCTAssertTrue(s.why == nil)
    }

    /// Red with M2a (`partial` read from done's flag alone): no done line is a cancel, never complete.
    func testNoDoneLineIsCancelledNeverComplete() {
        let s = Self.parse([Self.first, Self.mention0, Self.definition, Self.progress])
        XCTAssertFalse(s.done)
        XCTAssertTrue(s.partial)
        XCTAssertEqual(s.counts?.session, 2, "progress gives the counts so far")
        let c = XrayRefContext(s, ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(c.heading, "Definition found so far")
        XCTAssertEqual(c.counts.first, "This session \u{2265}2")
    }

    func testPartialDoneSaysAtLeastAndKeepsWhy() {
        let done = #"{"schema":1,"done":true,"partial":true,"counts":{"session":2,"project":5,"project_sessions":2,"all":7,"all_sessions":3},"why":"time","files":64,"bytes":1,"lines_too_long":0}"#
        let s = Self.parse([Self.first, Self.mention0, done])
        XCTAssertTrue(s.done)
        XCTAssertTrue(s.partial)
        XCTAssertEqual(s.why, "time")
        let c = XrayRefContext(s, ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(c.counts, ["This session \u{2265}2", "This project \u{2265}5 in 2 other sessions",
                                  "All projects \u{2265}7 in 3 other sessions"])
        let whole = XrayRefContext(Self.parse(Self.golden), ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(whole.counts, ["This session 2", "This project 3 in 1 other sessions"])
    }

    func testResolvedCommitAndFileCapped() {
        let long = String(repeating: "x", count: 300)
        let lines = (0..<20).map { "\"\($0)\(long)\"" }.joined(separator: ",")
        let commit = #"{"schema":1,"resolved":{"kind":"commit","state":"ok","title":"Fix login","subtitle":"acme/api","lines":["#
            + lines + "]}}"
        let s = Self.parse([Self.first, commit, Self.done])
        XCTAssertEqual(s.resolved?.kind, "commit")
        XCTAssertEqual(s.resolved?.title, "Fix login")
        XCTAssertEqual(s.resolved?.lines.count, 14)
        XCTAssertTrue(s.resolved?.lines.allSatisfy { $0.count <= 200 } == true)
        let file = #"{"schema":1,"resolved":{"kind":"file","state":"missing","title":"login.swift","subtitle":"/Users/example/acme/api","lines":[]}}"#
        XCTAssertEqual(Self.parse([file]).resolved, XrayRefStream.Resolved(kind: "file", state: "missing", title: "login.swift",
                                                                         subtitle: "/Users/example/acme/api", lines: []))
    }

    /// Red with M2e (the command source not kept): dch's card marks these "your define_command".
    func testDefineCommandLineIsMarkedAndKeepsUrlAndStatus() {
        let cmd = #"{"schema":1,"definition":{"session":"api","live":false,"project":"-Users-example-acme","at":null,"title":"Login retries","passage":"From the tracker.","rule":"command","offset":null,"chapter":null,"source":"command","url":"https://example.com/acme/api/issues/12","status":"open"}}"#
        let s = Self.parse([Self.first, cmd, Self.done])
        XCTAssertEqual(s.definitions.first?.mark, "your define_command")
        XCTAssertEqual(s.definitions.first?.url, "https://example.com/acme/api/issues/12")
        XCTAssertEqual(s.definitions.first?.status, "open")
        XCTAssertTrue(Self.parse(Self.golden).definitions.first?.mark == nil)
    }

    func testUnknownKindsAndWordsNeverThrow() {
        let odd = [#"{"schema":1,"frobnicate":{"x":1}}"#, #"{"schema":2,"mention":{"session":"api","line":"later schema"}}"#,
                   "not json", #"{"schema":1,"definition":{"session":"api","title":"T","passage":"p","rule":"Z9"}}"#,
                   #"{"schema":1,"resolved":{"kind":"tree","state":"weird","title":"t","subtitle":"s","lines":[1,"a"]}}"#,
                   #"{"schema":1,"done":true,"partial":true,"why":"cosmic","counts":{}}"#]
        let s = Self.parse(odd)
        XCTAssertTrue(s.mentions.isEmpty)
        XCTAssertEqual(s.definitions.first?.rule, "Z9")
        XCTAssertEqual(s.resolved?.state, "weird")
        XCTAssertEqual(s.resolved?.lines, ["a"])
        XCTAssertEqual(s.why, "cosmic")
        XCTAssertEqual(s.counts?.session, 0)
    }

    func testInputPastFourMiBIsNotReadAndCountsAsCancelled() {
        let pad = Self.mention0
        let n = XrayRefStream.maxBytes / pad.utf8.count + 10
        let s = Self.parse([Self.first] + Array(repeating: pad, count: n) + [Self.done])
        XCTAssertFalse(s.done)
        XCTAssertTrue(s.partial)
        XCTAssertLessThan(s.mentions.count, n)
    }

    func testBidiAndControlsInALineAreStripped() {
        let m = "{\"schema\":1,\"mention\":{\"session\":\"api\",\"chapter\":null,\"at\":1,\"line\":\"see \\u202e#12\\u200f now\\u0007\",\"offset\":5}}"
        let s = Self.parse([m])
        XCTAssertEqual(s.mentions.first?.line, "see #12 now")
        XCTAssertFalse(s.mentions.first?.line.unicodeScalars.contains { $0.value == 0x202e } ?? true)
    }

    /// dch 1.94 (#455): a mention line gains `who` and `tool`; it decodes as before.
    func testMentionWithWhoAndToolKeysDecodes() {
        let line = #"{"schema":1,"mention":{"session":"api","chapter":"f12:0","at":1794304801,"line":"Work on #12 please","offset":0,"live":false,"project":"-Users-example-acme","who":"tool","tool":"Bash"}}"#
        let none = #"{"schema":1,"mention":{"session":"api","chapter":"f12:1","at":1794304802,"line":"again","offset":1,"live":false,"project":"-Users-example-acme","who":"user","tool":null}}"#
        let s = Self.parse([Self.first, line, none, Self.done])
        XCTAssertEqual(s.mentions.map(\.line), ["Work on #12 please", "again"])
        XCTAssertEqual(s.mentions.map(\.offset), [0, 1])
    }

    /// #1560 (dch README v1.99.0 :1762-1893): a `resolved` line for `state` (a commit's title, subtitle and stat lines
    /// as git would give them; dch sends none past `ok`, the fixture does to prove they are never drawn).
    static func resolved(_ kind: String, _ state: String) -> XrayRefStream.Resolved? {
        parse([first, #"{"schema":1,"resolved":{"kind":"\#(kind)","state":"\#(state)","title":"Fix the login retry","subtitle":"Example Dev \#u{00B7} 3h ago \#u{00B7} abc1234","lines":[" src/login.c | 4 ++--"]}}"#, done]).resolved
    }

    /// #1560: each state its one line (red with any line changed or a state falling to its word); `ok` and a missing
    /// state keep today's title, subtitle and lines.
    @MainActor func testEachResolvedStateGivesItsLine() throws {
        let lines: [(String, String, String)] = [
            ("commit", "ended", "Session ended: git not run"), ("commit", "no_git", "No git found: not looked up"),
            ("commit", "not_repo", "Not in a git repository"), ("commit", "ambiguous", "Short SHA matches more than one object"),
            ("commit", "not_commit", "Not a commit in this repository"), ("commit", "timeout", "git took too long"),
            ("file", "outside_project", "Outside the project: not read"), ("file", "secret_name", "Looks like a secret: not read"),
            ("file", "too_large", "Over 2 MB: not read"), ("commit", "shallow_clone", "shallow_clone"),
        ]
        for (kind, state, line) in lines {
            let r = try XCTUnwrap(Self.resolved(kind, state), state)
            XCTAssertEqual(r.kind, kind)
            XCTAssertEqual(XrayRefPopover.resolvedText(r), line, state)
        }
        let whole = "Fix the login retry\nExample Dev \u{00B7} 3h ago \u{00B7} abc1234\n src/login.c | 4 ++--"
        XCTAssertEqual(XrayRefPopover.resolvedText(try XCTUnwrap(Self.resolved("commit", "ok"))), whole)
        XCTAssertEqual(XrayRefPopover.resolvedText(try XCTUnwrap(Self.resolved("commit", ""))), whole, "no state word: as before")
    }

    /// #1560: an ended session ran no git: none of the title, subtitle or lines is drawn (red with ended drawn as ok).
    @MainActor func testEndedDrawsNoGitOutput() throws {
        let t = XrayRefPopover.resolvedText(try XCTUnwrap(Self.resolved("commit", "ended")))
        for git in ["Fix the login retry", "abc1234", "src/login.c"] { XCTAssertFalse(t.contains(git), git) }
    }

    /// #1560: an unknown state word with bidi and control scalars is shown cleaned (red with the raw word kept).
    @MainActor func testABidiOrControlStateWordIsCleaned() throws {
        let r = try XCTUnwrap(Self.resolved("commit", #"we\u202eird\u0007\u200f"#))
        XCTAssertEqual(r.state, "weird")
        XCTAssertEqual(XrayRefPopover.resolvedText(r), "weird")
    }
}
