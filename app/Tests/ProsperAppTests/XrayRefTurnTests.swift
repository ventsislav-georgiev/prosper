import XCTest
@testable import ProsperApp

/// #1528 (dch 1.100.0, README "--ref"): a --ref mention's turn, who and sentence with its span; the Mentions tab grouped
/// one block per turn, newest first, then Earlier. Literal fake NDJSON only: no dch, no window, no pasteboard.
@MainActor
final class XrayRefTurnTests: XCTestCase {
    typealias T = XrayRefStreamTests

    /// One mention line in dch 1.100.0's shape, built through JSONSerialization so outside scalars are sent as they are.
    static func mention(_ session: String = "api", turn: Any = NSNull(), at: Int = 1794304801, offset: Int,
                        sentence: String = "Work on #12 please", span: Any = [8, 11], who: Any = "user", tool: Any = NSNull()) -> String {
        let m: [String: Any] = ["session": session, "chapter": "f12:\(offset)", "at": at, "who": who, "tool": tool,
                                "line": sentence, "turn": turn, "sentence": sentence, "span": span, "offset": offset, "live": false]
        let d = (try? JSONSerialization.data(withJSONObject: ["schema": 1, "mention": m])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    static func context(_ lines: [String]) -> XrayRefContext {
        XrayRefContext(T.parse([T.first] + lines + [T.done]), ref: "#12", tasks: nil, memory: nil)
    }

    /// Red with turns-oldest-first (sorted(by: <)), with other-session-turn-kept (the session check dropped) and with
    /// no-earlier-block (the trailing block dropped).
    func testTurnsNewestFirstThenOneEarlierBlock() {
        let c = Self.context([Self.mention(turn: 1, offset: 30), Self.mention(turn: 3, offset: 200), Self.mention(offset: 5),
                              Self.mention(turn: 1, offset: 10), Self.mention("api-qa", turn: 2, offset: 7),
                              Self.mention("api-qa", at: 1794304900, offset: 8)])
        let turns = c.turns ?? []
        XCTAssertEqual(turns.map(\.turn), [3, 1, nil], "newest turn first; another session's turn is not this session's")
        XCTAssertEqual(turns.first?.mentions.map(\.offset), [200])
        XCTAssertEqual(turns.dropFirst().first?.mentions.map(\.offset), [10, 30], "a turn's rows in file order")
        XCTAssertEqual(turns.last?.mentions.map(\.offset), [5, 8, 7], "Earlier: this session's, then the others newest first")
        XCTAssertEqual(turns.reduce(0) { $0 + $1.mentions.count }, 6, "no mention lost")
        XCTAssertEqual(c.groups.reduce(0) { $0 + $1.mentions.count }, 6, "the tab's count is unchanged")
        let none = Self.context([Self.mention(turn: 2, offset: 1)])
        XCTAssertEqual(none.turns?.map(\.turn), [2], "no Earlier block when every row has a turn")
    }

    /// The parse: dch's fixture row (tests/xray/fixtures/refs-defs, names made generic); a turn that is not 1... is nil.
    func testNewShapeParses() {
        let s = T.parse([##"{"schema":1,"mention":{"session":"api","chapter":"f*:0","at":1794304801,"who":"tool","tool":"Bash","line":"Work on #831 please","turn":1,"sentence":"Work on #831 please","span":[8,12],"offset":0,"live":false,"project":"-Users-example-acme"}}"##])
        let m = s.mentions.first
        XCTAssertEqual(m?.turn, 1)
        XCTAssertEqual(m?.who, "tool")
        XCTAssertEqual(m?.tool, "Bash")
        XCTAssertEqual(m?.sentence, XrayRefStream.Sentence(before: "Work on ", hit: "#831", after: " please"))
        for bad in [0, -1, "3", 1.5, NSNull()] as [Any] {
            XCTAssertTrue(T.parse([Self.mention(turn: bad, offset: 1)]).mentions.first?.turn == nil, "\(bad)")
        }
    }

    /// Red with no-scalar-check (samePosition dropped: a mid-scalar span slices), with no-order-check (a <= b dropped:
    /// a reversed span traps or slices) and with no-end-check: each bad span keeps the plain sentence, no highlight.
    func testBadSpanFallsBackToThePlainSentence() {
        let raw = "caf\u{00E9} #12"   // é is two bytes: the ref is bytes [6, 9)
        XCTAssertEqual(raw.utf8.count, 9)
        XCTAssertEqual(XrayRefStream.sentence(raw, span: [6, 9]), .init(before: "caf\u{00E9} ", hit: "#12", after: ""))
        let plain = XrayRefStream.Sentence(before: raw, hit: "", after: "")
        let bad: [Any?] = [[4, 9], [6, 4], [9, 6], [6, 10], [-1, 9], [10, 12], ["6", "9"], [6.5, 9], [6], [6, 9, 9], NSNull(), nil]
        for span in bad {
            XCTAssertEqual(XrayRefStream.sentence(raw, span: span), plain, "\(String(describing: span))")
        }
        // through the parse too, and a sentence over dch's 400 bytes is not dch's: plain, cut
        XCTAssertEqual(T.parse([Self.mention(offset: 1, sentence: raw, span: [4, 9])]).mentions.first?.sentence, plain)
        let long = String(repeating: "a", count: 401)
        XCTAssertEqual(XrayRefStream.sentence(long, span: [0, 1]).hit, "")
        XCTAssertEqual(XrayRefStream.sentence(String(repeating: "a", count: 400), span: [0, 1]).hit, "a", "400 bytes is dch's cap")
        XCTAssertEqual(XrayRefStream.sentence("#12", span: [0, 0]), .init(before: "", hit: "", after: "#12"), "an empty span is a span")
    }

    /// The binding order (review-clean-then-parse): slice the RAW sentence by span, then clean each part. Red with
    /// clean-then-slice (the span's bytes counted on the cleaned sentence) and with one part left raw.
    func testBidiAndMarkStackCleanedInAllThreeParts() {
        let before = "Fix\u{202E} ", hit = "#1\u{202D}2", after = " now\u{200F} e\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}"
        let raw = before + hit + after
        let a = before.utf8.count, b = a + hit.utf8.count
        XCTAssertEqual([a, b], [7, 13])
        let s = XrayRefStream.sentence(raw, span: [a, b])
        XCTAssertEqual(s.before, "Fix ")
        XCTAssertEqual(s.hit, "#12")
        XCTAssertEqual(s.after, " now e\u{0301}\u{0301}\u{0301}", "the bidi mark dropped, the marks capped at three")
        XCTAssertEqual(T.parse([Self.mention(offset: 1, sentence: raw, span: [a, b])]).mentions.first?.sentence, s)
        // the plain fallback is cleaned too
        XCTAssertEqual(XrayRefStream.sentence(raw, span: [b, a]).before, "Fix #12 now e\u{0301}\u{0301}\u{0301}")
    }

    /// Red with old-shape-turned (turns built without a sentence): an older dch keeps today's flat list.
    func testOldShapeKeepsTheFlatList() {
        let c = Self.context([T.mention1, T.mention0])
        XCTAssertTrue(c.turns == nil)
        XCTAssertEqual(c.groups.map(\.session), ["api"])
        XCTAssertEqual(c.groups.first?.mentions.map(\.line), ["Work on #12 please", "# #12 Login retries"])
        let m = c.groups.first?.mentions.first
        XCTAssertTrue(m?.turn == nil && m?.who == nil && m?.tool == nil && m?.sentence == nil)
        XCTAssertEqual(m.map(XrayRefPopover.spokenRow), "Mention: Work on #12 please")
    }

    /// The header (pN, the chapter's title cleaned, the newest mention's age), Earlier, and You / Reply / the tool.
    func testHeaderAndSpeaker() {
        let now = Date(timeIntervalSince1970: 1794304801 + 300)
        let ch = [TranscriptOutline.Chapter(id: 0, ordinal: 3, title: "Fix\u{202E} login", kind: .prompt, hasError: false)]
        let c = Self.context([Self.mention(turn: 3, offset: 1), Self.mention(turn: 1, at: 1794304801 - 7200, offset: 9),
                              Self.mention(offset: 0)])
        XCTAssertEqual(c.turns?.map { XrayRefPopover.turnHeader($0, chapters: ch, now: now) },
                       ["p3 \u{00B7} Fix login \u{00B7} 5m", "p1 \u{00B7} 2h", "Earlier"])
        func said(_ who: Any, _ tool: Any = NSNull()) -> String? {
            T.parse([Self.mention(offset: 1, who: who, tool: tool)]).mentions.first.flatMap(XrayRefPopover.speaker)
        }
        XCTAssertEqual([said("user"), said("assistant"), said("tool", "Bash"), said("tool"), said("other"), said(NSNull())],
                       ["You", "Reply", "Bash", "Tool", nil, nil])
        let m = T.parse([Self.mention(offset: 1, who: "assistant")]).mentions.first
        XCTAssertEqual(m.map(XrayRefPopover.spokenRow), "Reply: Work on #12 please")
    }

    /// #1905, red with the old `.accessibilityHidden(true)`: a row with no arrow shows its speaker to AX; one with an arrow hides it.
    func testSpeakerHiddenOnlyWhenArrowSpeaksIt() {
        XCTAssertTrue(XrayRefPopover.speakerHidden(opens: true))
        XCTAssertTrue(!XrayRefPopover.speakerHidden(opens: false))
    }

    /// Red with jump-no-chapter (the chapter lookup ignored: the first chapter opens): a header opens its turn's chapter
    /// card; Earlier, or a turn the chapters do not hold, opens nothing.
    func testHeaderJumpsToItsTurn() {
        let c = Self.context([Self.mention(turn: 3, offset: 1), Self.mention(turn: 1, offset: 9), Self.mention(offset: 0)])
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .search)
        p.dchChapters = [TranscriptOutline.Chapter(id: 0, ordinal: 3, title: "Fix login", kind: .prompt, hasError: false)]
        let turns = c.turns ?? []
        XCTAssertEqual(turns.count, 3)
        if let earlier = turns.last { XCTAssertFalse(p.jumpTurn(earlier, in: c)) }
        if let one = turns.dropFirst().first { XCTAssertFalse(p.jumpTurn(one, in: c), "turn 1 is not among the chapters read") }
        XCTAssertTrue(p.chapterCard == nil)
        let orphan = XrayRefContext(T.parse([Self.mention(turn: 3, offset: 1)]), ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(orphan.turns?.map(\.turn), [nil], "no first line: no session, so no turn block to jump from")
        if let three = turns.first { XCTAssertTrue(p.jumpTurn(three, in: c)) } else { XCTFail("no turn 3") }
        XCTAssertEqual(p.chapterCard?.ordinal, 3)
    }

    static func chapter(_ n: Int, _ title: String) -> TranscriptOutline.Chapter {
        TranscriptOutline.Chapter(id: n, ordinal: n, title: title, kind: .prompt, hasError: false)
    }

    /// #1900: a mention's arrow opens its chapter by its anchor, else its turn's; with neither held (or no chapters read
    /// at all, the hover card's case before the fix) jumpRef is false and opens nothing. Another session's never opens.
    /// Red with jump-true-on-nothing (and on the old jumpRef, which returned true having opened nothing) and with
    /// no-turn-fallback (a mention whose anchor is not held opens nothing).
    func testMentionOpensItsAnchorElseItsTurnsChapter() {
        let c = Self.context([Self.mention(turn: 3, offset: 1), Self.mention(turn: 2, offset: 9), Self.mention(turn: 1, offset: 20),
                              Self.mention("api-qa", turn: 2, offset: 7)])
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .search)
        let mine = c.groups.first?.mentions ?? [], theirs = c.groups.last?.mentions ?? []
        XCTAssertEqual(mine.map(\.offset), [1, 9, 20])
        XCTAssertEqual(theirs.map(\.session), ["api-qa"])
        for m in mine + theirs { XCTAssertFalse(p.jumpRef(m, in: c), "no chapters read: nothing to open") }
        XCTAssertTrue(p.chapterCard == nil)
        p.dchChapters = [Self.chapter(2, "Fix login"), Self.chapter(5, "Ship it")]
        p.chapterAnchors = ["f12:1": 5, "f12:7": 5]
        if let a = mine.first {   // its anchor's chapter, not its turn's
            XCTAssertTrue(p.jumpRef(a, in: c))
            XCTAssertEqual(p.chapterCard?.ordinal, 5)
        }
        if let b = mine.dropFirst().first {   // anchor f12:9 not held: turn 2's chapter
            XCTAssertEqual(p.mentionChapter(b, in: c)?.ordinal, 2)
            XCTAssertTrue(p.jumpRef(b, in: c))
            XCTAssertEqual(p.chapterCard?.ordinal, 2)
        }
        if let d = mine.last {   // neither its anchor nor its turn 1 is held
            XCTAssertTrue(p.mentionChapter(d, in: c) == nil)
            XCTAssertFalse(p.jumpRef(d, in: c))
        }
        for m in theirs {
            XCTAssertTrue(p.mentionChapter(m, in: c) == nil, "another session's mention, whatever its anchor or turn")
            XCTAssertFalse(p.jumpRef(m, in: c))
        }
        XCTAssertEqual(p.chapterCard?.ordinal, 2, "nothing opened after the last card")
    }
}
