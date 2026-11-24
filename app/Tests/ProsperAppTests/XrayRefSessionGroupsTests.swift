import XCTest
@testable import ProsperApp

/// #1589 (dch 1.104.0 #479, README v1.104.0:1694): another session of this project gets its own block in the ref card,
/// "also discussed in <session>, <age>", its mentions grouped by turn and keyed by session_id; an older dch keeps the
/// one Earlier block. Literal fake NDJSON only: no dch, no window, no pasteboard.
@MainActor
final class XrayRefSessionGroupsTests: XCTestCase {
    typealias T = XrayRefStreamTests
    typealias R = XrayRefTurnTests

    static let base = 1794304801

    /// A mention line of another session of this project in dch 1.104.0's shape (session_id, turn, turn_title,
    /// last_active); `recall: false` drops turn_title and last_active (an older dch).
    static func other(_ session: String, id: Any = NSNull(), turn: Any = NSNull(), title: Any = NSNull(),
                      active: Any = NSNull(), at: Int = base, offset: Int, recall: Bool = true) -> String {
        var m: [String: Any] = ["session": session, "session_id": id, "chapter": NSNull(), "at": at, "who": "user",
                                "tool": NSNull(), "line": "Work on #12 please", "turn": turn, "sentence": "Work on #12 please",
                                "span": [8, 11], "offset": offset, "live": false, "project": "-Users-example-acme"]
        if recall { (m["turn_title"], m["last_active"]) = (title, active) }
        let d = (try? JSONSerialization.data(withJSONObject: ["schema": 1, "mention": m])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    /// Red with no-recall-parse (the recall flag never set: every block falls back to Earlier) and with
    /// session-id-unparsed: the README's fields land, cleaned; an older line has none of them.
    func testNewShapeParses() {
        let s = T.parse([##"{"schema":1,"mention":{"session":"api-qa","session_id":"7d2c0e4a-1b3f-4c5d-8e9f-0a1b2c3d4e5f","chapter":"f*:0","at":1794304801,"who":"user","tool":null,"line":"Work on #12 please","turn":4,"turn_title":"Fix‮ login","last_active":1794305000,"sentence":"Work on #12 please","span":[8,11],"offset":0,"live":false,"project":"-Users-example-acme"}}"##,
                         T.mention0])
        let m = s.mentions.first
        XCTAssertEqual(m?.sessionID, "7d2c0e4a-1b3f-4c5d-8e9f-0a1b2c3d4e5f")
        XCTAssertEqual(m?.turn, 4)
        XCTAssertEqual(m?.turnTitle, "Fix login", "outside text cleaned")
        XCTAssertEqual(m?.lastActive, Date(timeIntervalSince1970: 1794305000))
        XCTAssertEqual(m?.recall, true)
        let old = s.mentions.last
        XCTAssertTrue(old?.sessionID == nil && old?.turnTitle == nil && old?.lastActive == nil && old?.recall == false)
        let nulls = T.parse([Self.other("api-qa", offset: 1)]).mentions.first
        XCTAssertTrue(nulls?.recall == true && nulls?.turnTitle == nil && nulls?.lastActive == nil, "null keys still mark it")
    }

    /// Red with recall-in-earlier (the block's lines left in Earlier), with blocks-oldest-first, with
    /// group-by-name (a renamed session split in two) and with block-turns-oldest-first.
    func testOtherSessionsGetTheirOwnBlocks() {
        let now = Date(timeIntervalSince1970: TimeInterval(Self.base + 7200))
        let c = R.context([R.mention(turn: 3, offset: 1), R.mention(offset: 0),
                           Self.other("web", id: "w1", turn: 2, title: "Ship it", active: Self.base - 86400, offset: 4),
                           Self.other("api-qa", id: "q1", turn: 2, title: "Retry\u{202E} logic", active: Self.base, offset: 5),
                           Self.other("api-qa", id: "q1", turn: 5, title: "Login", active: Self.base, offset: 9),
                           Self.other("api-qa-renamed", id: "q1", active: Self.base, offset: 7)])
        let turns = c.turns ?? []
        XCTAssertEqual(turns.map(\.turn), [3, nil, 5, 2, nil, 2])
        XCTAssertEqual(turns.map(\.session), [nil, nil, "api-qa", "api-qa", "api-qa", "web"])
        XCTAssertEqual(turns.dropFirst().first?.mentions.map(\.offset), [0], "Earlier holds this session's alone")
        XCTAssertEqual(turns.map(\.opens), [false, false, true, false, false, true])
        XCTAssertEqual(turns.reduce(0) { $0 + $1.mentions.count }, 6, "no mention lost")
        XCTAssertEqual(turns.compactMap { XrayRefPopover.sessionHeader($0, now: now) },
                       ["also discussed in api-qa, 2h", "also discussed in web, 1d"])
        let ch = [TranscriptOutline.Chapter(id: 0, ordinal: 5, title: "Not this one", kind: .prompt, hasError: false)]
        XCTAssertEqual(turns.map { XrayRefPopover.turnHeader($0, chapters: ch, now: now) },
                       ["p3 \u{00B7} 2h", "Earlier", "p5 \u{00B7} Login \u{00B7} 2h", "p2 \u{00B7} Retry logic \u{00B7} 2h",
                        "Earlier", "p2 \u{00B7} Ship it \u{00B7} 2h"], "another session's title is dch's turn_title, cleaned")
    }

    /// Red with no-name-fallback (a null session_id groups every such session together): with no session_id the
    /// name keys the block; with no last_active the newest mention dates it.
    func testNameKeysTheBlockWhenNoSessionID() {
        let now = Date(timeIntervalSince1970: TimeInterval(Self.base + 600))
        let c = R.context([R.mention(turn: 1, offset: 1),
                           Self.other("web", turn: 1, at: Self.base - 3600, offset: 2),
                           Self.other("api-qa", turn: 1, offset: 3)])
        let turns = c.turns ?? []
        XCTAssertEqual(turns.map(\.session), [nil, "api-qa", "web"])
        XCTAssertEqual(turns.compactMap { XrayRefPopover.sessionHeader($0, now: now) },
                       ["also discussed in api-qa, 10m", "also discussed in web, 1h"])
    }

    /// Red with old-shape-blocked (the recall check dropped): an older dch's line of another session (no turn_title, no
    /// last_active) keeps today's view exactly: one Earlier block, no session header.
    func testOldDchKeepsTodaysView() {
        let old = [R.mention(turn: 3, offset: 1), R.mention(offset: 0),
                   Self.other("api-qa", turn: NSNull(), offset: 5, recall: false)]
        let c = R.context(old)
        XCTAssertEqual(c.turns, [XrayRefContext.Turn(turn: 3, mentions: c.turns?.first?.mentions ?? []),
                                 XrayRefContext.Turn(turn: nil, mentions: c.turns?.last?.mentions ?? [])])
        XCTAssertEqual(c.turns?.last?.mentions.map(\.offset), [0, 5])
        XCTAssertTrue((c.turns ?? []).allSatisfy { XrayRefPopover.sessionHeader($0, now: Date()) == nil })
    }

    /// Red with jump-other-turn (the session check dropped from jumpTurn): another session's turn is not in this
    /// session's chapters, so its header opens nothing even when the same pN is there.
    func testOtherSessionTurnOpensNothing() {
        let c = R.context([R.mention(turn: 3, offset: 1), Self.other("api-qa", id: "q1", turn: 3, title: "Login", offset: 2)])
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .search)
        p.dchChapters = [TranscriptOutline.Chapter(id: 0, ordinal: 3, title: "Fix login", kind: .prompt, hasError: false)]
        XCTAssertEqual(c.turns?.count, 2)
        if let theirs = c.turns?.last { XCTAssertFalse(p.jumpTurn(theirs, in: c)) }
        XCTAssertTrue(p.chapterCard == nil)
        if let mine = c.turns?.first { XCTAssertTrue(p.jumpTurn(mine, in: c)) }
        XCTAssertEqual(p.chapterCard?.ordinal, 3)
    }

    /// Another project's lines (a `--scope all` read: no turn_title, no last_active) stay in Other projects' flat
    /// groups; the card's turns are untouched by them.
    func testOtherProjectsUnchanged() {
        let c = R.context([R.mention(turn: 3, offset: 1), Self.other("api-qa", id: "q1", turn: 2, title: "Login", offset: 2)])
        let all = R.context([Self.other("web-other", id: "x9", offset: 3, recall: false)])
        let w = c.with(others: all)
        XCTAssertEqual(w.turns, c.turns)
        XCTAssertEqual(w.others?.map(\.session), ["web-other"])
        XCTAssertTrue(all.turns?.allSatisfy { $0.session == nil } == true)
    }
}
