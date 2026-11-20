import AppKit
import XCTest
@testable import ProsperApp

/// #1567 (X-ray C1, spec 5.8, 5.6): the window's --ref result cache (XrayRefResults) and the card's footer slots. The
/// fake runner (XrayRefRunTests.Run) counts spawns; the cache's 30 s and its LRU run on an injected clock, never a real
/// wait. Windows are made and never shown; notifications go through a private center. No dch, no process.
@MainActor
final class XrayRefResultsTests: XCTestCase {
    static let api = XrayTarget(name: "api", dir: "/tmp/dch-test")
    static let other = XrayTarget(name: "api-qa", dir: "/tmp/dch-test")

    final class Clock { var t = Date(timeIntervalSince1970: 1_800_000_000) }

    override func setUp() {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 84, 0])
        XrayPanels.spawnCosts = []
    }

    override func tearDown() {
        XrayPanels.probed = nil
        XrayPanels.spawnCosts = []
        MainActor.assumeIsolated { XrayRefResults.set(nil, for: nil) }   // tearDown runs on main
    }

    func cache(_ clock: Clock) -> XrayRefResults {
        let c = XrayRefResults()
        c.now = { clock.t }
        return c
    }

    func panel(_ run: XrayRefRunTests.Run, _ c: XrayRefResults) -> XrayPanelModel {
        let p = XrayPanelModel(target: Self.api, tab: .search)
        (p.dch, p.run) = ("/fake/dch", run.run)
        p.refResults = { c }
        return p
    }

    /// #1772 (QA R1760 n89): red at base (bytes sums out only; put never expired). The parsed stream counts in bytes (and
    /// evicts), and a put drops an entry past 30 s without a get.
    func testBytesCountTheParsedStreamAndPutExpires() {
        let clock = Clock(), c = cache(clock)
        var s = XrayRefStream()
        s.mentions = [XrayRefStream.Mention(session: "api", chapter: nil, at: nil, line: String(repeating: "a", count: 1000),
                                            offset: nil, index: 0)]
        let est = XrayRefResults.estimate(s)
        XCTAssertGreaterThanOrEqual(est, 1000 + XrayRefResults.perItem)
        c.put(key("#1"), Data(count: 10), parsed: s)
        XCTAssertEqual(c.bytes, 10 + est)
        c.put(key("#2"), Data(count: 10))
        XCTAssertEqual(c.bytes, 20 + est, "no parsed: out only")
        c.put(key("#big"), Data(count: 10), parsed: {
            var b = XrayRefStream()
            b.mentions = [XrayRefStream.Mention(session: "api", chapter: nil, at: nil,
                                                line: String(repeating: "b", count: XrayRefResults.maxBytes), offset: nil, index: 0)]
            return b
        }())
        XCTAssertEqual(c.entries.map { $0.key.ref }, ["#1", "#2"], "parsed alone over the cap: refused")
        clock.t += 30
        c.put(key("#3"), Data(count: 5))
        XCTAssertEqual(c.entries.map { $0.key.ref }, ["#3"], "put drops the stale entries")
    }

    func key(_ ref: String, light: Bool = false, target: XrayTarget = api, scope: String = "project") -> XrayRefResults.Key {
        XrayRefResults.Key(target: target, ref: ref, light: light, scope: scope)
    }

    static func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    /// Red at base (no cache: runRef spawns every time): the second ask within 30 s spawned again. Red with the 30 s
    /// check gone (M-ttl): the ask at 30 s is served.
    func testAHitWithin30sSpawnsNothingAMissAfter30sReads() async {
        let clock = Clock(), c = cache(clock), run = XrayRefRunTests.Run(), panels = XrayPanels(), p = panel(run, c)
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls.count, 1)
        p.refContext = nil
        clock.t += 29.9
        XCTAssertTrue(panels.runRef("#12", for: p))
        XCTAssertTrue(panels.refReading == nil, "a hit leaves no read in flight")
        XCTAssertEqual(run.calls.count, 1, "hit: 0 spawns")
        XCTAssertEqual(p.refContext?.heading, "Definition", "the hit lands at once")
        clock.t += 0.1   // 30 s after the answer was kept
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls.count, 2, "miss after 30 s")
        XCTAssertTrue(panels.runRef("#13", for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls.count, 3, "another ref is another key")
    }

    /// Red with M-status (any exit kept): a failed read's answer served the next ask, which then spawned nothing.
    func testOnlyAnExit0AnswerIsKept() async {
        let clock = Clock(), c = cache(clock), run = XrayRefRunTests.Run(), panels = XrayPanels(), p = panel(run, c)
        run.answer = (1, Data())
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(p.refNote, XrayPanelModel.refNoCorpus)
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls.count, 2, "exit 1 was not kept")
        XCTAssertEqual(c.entries.count, 0)
    }

    /// Red with M-lru (a hit not made the newest use): key 0, asked again, went at the 65th put instead of key 1.
    /// Red with M-keys (no key cap): 65 kept.
    func testTheLRUEvictsAt65Keys() {
        let clock = Clock(), c = cache(clock)
        for i in 0..<64 { c.put(key("#\(i)"), Data("x".utf8)) }
        XCTAssertEqual(c.entries.count, 64)
        XCTAssertTrue(c.get(key("#0")) != nil)
        c.put(key("#64"), Data("x".utf8))
        XCTAssertEqual(c.entries.count, 64, "the 65th key evicts one")
        XCTAssertTrue(c.get(key("#1")) == nil, "the oldest use went")
        XCTAssertTrue(c.get(key("#0")) != nil, "a hit is a use")
        XCTAssertTrue(c.get(key("#64")) != nil)
    }

    /// Red with M-bytes (no byte cap): 36 MB kept. One answer over 32 MB is never kept.
    func testTheByteCapHolds() {
        let clock = Clock(), c = cache(clock), twelve = Data(count: 12 * 1024 * 1024)
        for i in 0..<3 { c.put(key("#\(i)"), twelve) }
        XCTAssertLessThanOrEqual(c.bytes, XrayRefResults.maxBytes)
        XCTAssertEqual(c.entries.map { $0.key.ref }, ["#1", "#2"], "the oldest went for the bytes")
        c.put(key("#big"), Data(count: XrayRefResults.maxBytes + 1))
        XCTAssertTrue(c.get(key("#big")) == nil, "over the cap: not kept")
        XCTAssertEqual(c.entries.map { $0.key.ref }, ["#1", "#2"], "and it pushed nothing out (M-big)")
        XCTAssertLessThanOrEqual(c.bytes, XrayRefResults.maxBytes)
    }

    /// Red at base (the follow tells nobody): the cached answers outlived the deltas. Red with M-refdelta, M-evict,
    /// M-reset (each drop gone) and M-resetall (a `full` reset drops too).
    func testDeltasAndResetsInvalidateThroughTheFollow() {
        let clock = Clock(), c = cache(clock), w = Self.window()
        XrayRefResults.set(c, for: w)
        let f = XrayFollow(target: Self.api)
        func line(_ s: String) -> Data { Data(s.utf8) }
        func fill() {
            c.clear()
            for k in [key("#12"), key("#12", light: true), key("#13"), key("#12", target: Self.other)] { c.put(k, Data("x".utf8)) }
        }
        fill()
        f.take([line(#"{"schema":1,"snapshot":{"schema":1,"chapters":[],"refs":[]}}"#),
                line(##"{"schema":1,"ref":{"key":"issue:#12","text":"#12","shape":"issue","count":3}}"##)])
        XCTAssertEqual(c.entries.map { $0.key.ref }, ["#13", "#12"], "a ref delta drops its ref, both modes, this session only")
        XCTAssertEqual(c.entries.last?.key.target, Self.other)
        fill()
        f.take([line(#"{"schema":1,"reset":{"why":"full"}}"#)])
        XCTAssertEqual(c.entries.count, 4, "a full reset keeps them")
        for why in ["rotated", "shrunk", "cleared"] {
            fill()
            f.take([line(#"{"schema":1,"reset":{"why":"\#(why)"}}"#)])
            XCTAssertEqual(c.entries.map { $0.key.target }, [Self.other], why)
        }
        fill()
        f.take([line(#"{"schema":1,"snapshot":{"schema":1,"chapters":[],"refs":[]}}"#), line(#"{"schema":1,"evict":{"seq":40}}"#)])
        XCTAssertEqual(c.entries.map { $0.key.target }, [Self.other], "evict (no key) drops the session's")
    }

    /// Red with M-lightpin (a full ask takes a light answer): the pin was served the hover's light read. A full answer
    /// serves a later hover (red with M-fullhover) and is not light there; a hit records no spawn cost (M-spent).
    func testALightAnswerNeverServesAPinAFullOneServesAHover() async {
        let clock = Clock(), c = cache(clock), run = XrayRefRunTests.Run(), panels = XrayPanels(), p = panel(run, c)
        XCTAssertTrue(panels.runRef("#12", budget: 120, for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls.count, 1)
        XCTAssertEqual(p.refContext?.light, true)
        XCTAssertEqual(XrayPanels.spawnCosts, [0], "the light read's elapsed_ms")
        XCTAssertTrue(panels.runRef("#12", budget: 120, for: p))
        XCTAssertEqual(run.calls.count, 1, "a light answer serves a light ask")
        XCTAssertEqual(XrayPanels.spawnCosts, [0], "a hit spawned nothing: no cost")
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls.count, 2, "a pin reads in full")
        XCTAssertTrue(run.calls.last?.contains("--full") == true)
        XCTAssertTrue(panels.runRef("#12", budget: 120, for: p))
        XCTAssertEqual(run.calls.count, 2, "the full answer serves the hover")
        XCTAssertEqual(p.refContext?.light, false)
        XCTAssertTrue(c.get(key("#12", light: false)).map { !$0.light } == true)
    }

    /// Red at base (nothing listens): the hidden window kept its answers. Red with M-hide (occlusion not heard) and
    /// M-close (a close keeps the window's cache).
    func testHideEmptiesAndCloseForgets() {
        let clock = Clock(), c = cache(clock), w = Self.window(), center = NotificationCenter()
        let observers = XrayRefResults.observe(center)
        defer { for o in observers { center.removeObserver(o) } }
        XrayRefResults.set(c, for: w)
        c.put(key("#12"), Data("x".utf8))
        XCTAssertFalse(w.occlusionState.contains(.visible), "never shown")
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        XCTAssertEqual(c.entries.count, 0, "hide empties")
        c.put(key("#12"), Data("x".utf8))
        center.post(name: NSWindow.willCloseNotification, object: w)
        XCTAssertEqual(c.entries.count, 0)
        XCTAssertTrue(XrayRefResults.windows[ObjectIdentifier(w)] == nil, "close forgets the window's cache")
    }

    /// Red at base (no hook in wire): the panel had no cache. Off under XCTest unless a row turns it on.
    func testWireGivesThePanelItsWindowsCache() {
        let (window, on) = (XrayPanels.window, XrayRefResults.on)
        defer { (XrayPanels.window, XrayRefResults.on) = (window, on) }
        let win = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        XrayPanels.window = { [weak win] _ in win }
        let p = XrayPanelModel(target: Self.api, tab: .refs)
        XrayRefResults.on = { false }
        XrayPanels().wire(p, UUID())
        XCTAssertTrue(p.refResults() == nil, "off: no cache")
        XrayRefResults.on = { true }
        let a = p.refResults(), b = p.refResults()
        XCTAssertTrue(a != nil && a === b, "one cache per window")
        XCTAssertTrue(a === XrayRefResults.windows[ObjectIdentifier(win)])
    }

    // MARK: footer slots

    static func stream(session: Int, project: Int, sessions: Int, done: Bool, partial: Bool = false) -> XrayRefStream {
        let counts = #""counts":{"session":\#(session),"project":\#(project),"project_sessions":\#(sessions),"all":null,"all_sessions":null}"#
        let last = done ? #"{"schema":1,"done":true,"partial":\#(partial),\#(counts)}"# : #"{"schema":1,"progress":{"partial":true,\#(counts)}}"#
        return XrayRefStreamTests.parse([XrayRefStreamTests.first, last])
    }

    static func footer(_ s: XrayRefStream, light: Bool = false, onScreen: Int = 0) -> [String] {
        var c = XrayRefContext(s, ref: "#12", tasks: nil, memory: nil)
        c.light = light
        return XrayRefPopover.footer(c, onScreen: onScreen)
    }

    /// Red at base (no footer). Each slot at partial and at done: "N on screen", "This session ≥12" (#1641), "9 in 3 others",
    /// "searching more…" until done (M-searching), a light read that ended partial "≥21 · click for all" (M-click: a
    /// full one too); no others slot at 0 sessions (M-zero).
    func testEachFooterSlotAtPartialAndDone() {
        let ge = "\u{2265}"
        XCTAssertEqual(Self.footer(Self.stream(session: 12, project: 9, sessions: 3, done: false), onScreen: 2),
                       ["2 on screen", "This session \(ge)12", "\(ge)9 in 3 others", "searching more\u{2026}"], "partial: no done yet")
        XCTAssertEqual(Self.footer(Self.stream(session: 12, project: 9, sessions: 3, done: true), onScreen: 2),
                       ["2 on screen", "This session 12", "9 in 3 others"], "done, complete")
        XCTAssertEqual(Self.footer(Self.stream(session: 12, project: 9, sessions: 3, done: true, partial: true), light: true),
                       ["This session \(ge)12", "\(ge)9 in 3 others", "\(ge)21 \u{00B7} click for all"], "a light read ended partial")
        XCTAssertEqual(Self.footer(Self.stream(session: 12, project: 9, sessions: 3, done: true, partial: true)),
                       ["This session \(ge)12", "\(ge)9 in 3 others"], "a full read partial: no click for all")
        XCTAssertEqual(Self.footer(Self.stream(session: 12, project: 9, sessions: 3, done: true), light: true),
                       ["This session 12", "9 in 3 others"], "a light read that read all: nothing more to click for")
        XCTAssertEqual(Self.footer(Self.stream(session: 4, project: 0, sessions: 0, done: false), light: true),
                       ["This session \(ge)4", "searching more\u{2026}"], "never 0 in 0 others")
    }

    /// #1641: the operator's card: footer "≥9 session" read as a broken label. Red at TIP: "\u{2265}9 session".
    func testFooterSessionSlotIsALabelledPhrase() {
        let slots = Self.footer(Self.stream(session: 9, project: 0, sessions: 0, done: false))
        XCTAssertEqual(slots.first, "This session \u{2265}9")
        XCTAssertFalse(slots.contains { $0.hasSuffix(" session") }, "no count-then-session fragment")
    }

    static func mention(line: String, sentence: String?) -> XrayRefStream {
        let sent = sentence.map { #","sentence":"\#($0)","span":null"# } ?? ""
        let m = #"{"schema":1,"mention":{"session":"api","chapter":"f12:0","at":1794304801,"line":"\#(line)","offset":0,"live":false,"project":"-Users-example-acme","turn":1,"who":"assistant","tool":null\#(sent)}}"#
        return XrayRefStreamTests.parse([XrayRefStreamTests.first, m, XrayRefStreamTests.done])
    }

    /// #1641 (1): the First mention field shows dch's sentence when it holds more than the line (the line is cut at
    /// lineCap 200). Red at TIP: the field drew m.line, the cut 200 characters.
    func testFirstMentionShowsTheSentenceWhenLongerThanTheLine() {
        let long = "Decision for you (#12): " + String(repeating: "pick a or b ", count: 25) + "now"   // 327 characters, under 400 bytes
        let c = XrayRefContext(Self.mention(line: long, sentence: long), ref: "#12", tasks: nil, memory: nil)
        let m = c.firstMention
        XCTAssertEqual(m?.line.count, XrayRefStream.lineCap, "the parse cut the line")
        XCTAssertEqual(m.map(XrayRefPopover.firstMentionText), long)
    }

    /// #1641 (1), (3): a heading line ("Label (KEY):") and dch's sentence of it are the same text: dch bounds the sentence
    /// at the line's ends, so the card shows the line and nothing more (never made-up text); and no definition is
    /// made of it on Prosper's side (a ticket's definitions are dch's define rule). Pins today's behaviour.
    func testHeadingMentionShowsItsLineAndMakesNoDefinition() {
        let head = "Decision for you (#12):"
        for s in [head, nil] {
            let c = XrayRefContext(Self.mention(line: head, sentence: s), ref: "#12", tasks: nil, memory: nil)
            XCTAssertTrue(c.definitions.isEmpty, "no Prosper-side definition from a heading mention")
            XCTAssertEqual(c.heading, "First mention")
            XCTAssertEqual(c.firstMention.map(XrayRefPopover.firstMentionText), head)
        }
        let short = XrayRefContext(Self.mention(line: "Work on #12 please", sentence: "#12 please"), ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(short.firstMention.map(XrayRefPopover.firstMentionText), "Work on #12 please", "a shorter sentence keeps the line")
    }

    /// Red at base (no hook): the card had no on-screen count. Red with M-onscreen (every mark counted): "issue:#12"
    /// gave 2. Through XrayGridMarksTests' rig: a live local pane, its follow's snapshot, the marks placed.
    func testOnScreenCountsTheGridsMarksOfTheKey() throws {
        let g = XrayGridMarksTests()
        try g.withSeams { fake in
            let r = g.rig(g.local)
            r.v.marks.follow = try g.follow(fake, 1, XrayTarget(name: "api", dir: g.local.dir))
            XCTAssertEqual(r.v.marks.marks.count, 2, "two marks on the grid")
            XCTAssertEqual(r.v.marks.hover.onScreen("issue:#12"), 1)
            XCTAssertEqual(r.v.marks.hover.onScreen("ticket:API-7"), 0, "a key with no mark")
        }
    }
}
