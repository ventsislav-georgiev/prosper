import AppKit
import GhosttyTerminal
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1565 (X-T b, spec 6.2, 6.3): the hover card over the grid's marks. A fake follow (XrayFollowTests.Fake) gives the
/// marks, a fake dch runner (XrayRefRunTests.Run) answers and records each argv and cancel, a fake presenter
/// (XrayRefPopoverTests.Cards) records the cards. The dwell, settle and close items are kept and performed by hand; the
/// window is never made (the overlay's seams answer key, buttons and cards). No dch, no event posted, no card shown.
@MainActor
final class XrayHoverTests: XCTestCase {
    typealias Cards = XrayRefPopoverTests.Cards
    let local = AgentSessionKey(dir: "/Users/example/dch", name: "api")

    /// first (elapsed_ms 120), a definition of another session's and this one's, a mention of each, done.
    static let stream = [
        ##"{"schema":1,"first":{"session":"api","key":"issue:#12","shape":"issue","text":"#12","elapsed_ms":120}}"##,
        ##"{"schema":1,"definition":{"session":"api-qa","title":"Login retries","passage":"other passage","rule":"issue"}}"##,
        ##"{"schema":1,"definition":{"session":"api","title":"Login retries","passage":"own passage","rule":"issue"}}"##,
        ##"{"schema":1,"mention":{"session":"api","chapter":"c1","line":"see #12 here","offset":10}}"##,
        ##"{"schema":1,"mention":{"session":"api-qa","chapter":null,"line":"other #12 line","at":1700000000}}"##,
        ##"{"schema":1,"done":true,"partial":false,"counts":{"session":1,"project":1,"project_sessions":1}}"##,
    ].joined(separator: "\n")

    override func setUp() {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 84, 0])   // #1443: stdin needs 1.84.0
        XrayPanels.spawnCosts = []
    }

    override func tearDown() {
        XrayPanels.probed = nil
        XrayPanels.spawnCosts = []
    }

    final class Rig {
        let t: AgentTerminalController
        let v: AgentTerminalHostView
        let run = XrayRefRunTests.Run()
        let panels: XrayPanels
        let cards: Cards
        let panel: XrayPanelModel
        var items: [(delay: TimeInterval, item: DispatchWorkItem)] = []
        init(t: AgentTerminalController, v: AgentTerminalHostView, panels: XrayPanels, cards: Cards, panel: XrayPanelModel) {
            (self.t, self.v, self.panels, self.cards, self.panel) = (t, v, panels, cards, panel)
        }
        /// The last kept item armed with `delay`.
        func item(_ delay: TimeInterval) -> DispatchWorkItem? { items.last { $0.delay == delay }?.item }
    }

    /// The seams set for the body and put back after it (follow, its gate, the dch path, gate B).
    func withSeams(_ body: (XrayFollowTests.Fake) async throws -> Void) async rethrows {
        let (ok, follow, dch, decorate) = (XrayPanels.followOK, XrayPanels.follow, XrayPanels.dch, XrayRefLink.decorate)
        defer { (XrayPanels.followOK, XrayPanels.follow, XrayPanels.dch, XrayRefLink.decorate) = (ok, follow, dch, decorate) }
        let fake = XrayFollowTests.Fake()
        XrayPanels.followOK = { true }
        XrayPanels.follow = fake.follow
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 99, 0])
        XrayRefLink.decorate = { true }
        try await body(fake)
    }

    /// A live local terminal (never in a window) with the marks of XrayGridMarksTests.viewport ("#12" row 1 col 4, "#1"
    /// row 2 col 4), the items kept, the overlay's seams on (key window, no button, no other card) and a fake panel.
    func rig(_ fake: XrayFollowTests.Fake) throws -> Rig {
        let t = AgentTerminalController()
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        let target = XrayTarget(name: local.name, dir: local.dir)
        let r = Rig(t: t, v: v, panels: XrayPanels(), cards: Cards(), panel: XrayPanelModel(target: target, tab: .refs))
        t.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        t.makeScreen = { AgentTerminalTests.FakeScreen($0) }
        v.owner = t
        t.view = v
        v.gridMetrics = TerminalGridMetrics(columns: 80, rows: 24, widthPixels: 1280, heightPixels: 816, cellWidthPixels: 16, cellHeightPixels: 34)
        let text = XrayGridMarksTests.viewport
        v.viewportText = { text }
        v.marks.windowShown = { _ in true }
        v.marks.windowKey = { _ in true }
        v.marks.buttons = { 0 }
        v.marks.cardShown = { [weak r] _ in r?.cards.shown != nil }
        v.marks.after = { [weak r] d, item in r?.items.append((d, item)) }
        v.marks.hop = XrayGridMarksTests.inline   // #1655: the compute and its apply at once, on main
        t.attach(local)
        t.gridChanged(cols: 80, rows: 24)
        t.gridChanged(cols: 80, rows: 24, generation: t.generation)
        XCTAssertEqual(t.phase, .live)
        let f = try XCTUnwrap(XrayFollows().attach(target, dch: "/fake/dch"))
        fake.send(1, XrayGridMarksTests.snapshot())
        v.marks.follow = f
        XCTAssertEqual(v.marks.marks.map(\.key), ["issue:#12", "issue:#1"])
        (r.panel.dch, r.panel.run) = ("/fake/dch", r.run.run)
        r.panel.panels = r.panels
        r.panel.home = "/Users/example"
        r.panel.presentRef = { [weak r] in r?.cards.present($0, $1, $2) }
        r.panel.dismiss = { [weak r] in r?.cards.close() }
        r.run.answer = (0, Data(Self.stream.utf8))
        v.marks.hover.panel = { [weak r] in
            guard let r, let refs = r.v.marks.refs else { return nil }
            return (r.panel, refs)
        }
        return r
    }

    /// The pointer over a mark's cell through the overlay's own mouseMoved (a built event, never posted).
    /// #1701: with Command held unless `flags` says otherwise (the hover opens only then).
    func move(_ r: Rig, col: Int, row: Int, _ flags: NSEvent.ModifierFlags = .command) throws {
        let p = CGPoint(x: 4 + 8 * CGFloat(col) + 1, y: 2 + 17 * CGFloat(row) + 1)   // no window: scale 2, cells 8 x 17 pt
        let e = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: r.v.marks.convert(p, to: nil), modifierFlags: flags,
                                                 timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        r.v.marks.mouseMoved(with: e)
    }

    /// Dwell on `key`: the 500 ms item performed.
    func dwell(_ r: Rig, _ key: String) {
        r.v.marks.hover.point(key)
        r.item(0.5)?.perform()
    }

    func waitCancelled(_ run: XrayRefRunTests.Run, _ n: Int) async {
        let end = Date().addingTimeInterval(5)
        while run.cancelled < n, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func waitCalls(_ run: XrayRefRunTests.Run, _ n: Int) async {
        let end = Date().addingTimeInterval(5)
        while run.calls.count < n, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// Red if the pointer's cell does not find the mark under it (mouseMoved, mark(at:)), or a pass that leaves before
    /// 500 ms spawns a read or shows a card (the dwell item not guarded on the pointer still being there).
    func testAPassUnder500msSpawnsNothing() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            try move(r, col: 4, row: 1)   // the mark's first cell
            XCTAssertEqual(r.v.marks.hover.over, "issue:#12")
            XCTAssertEqual(r.items.last?.delay, 0.5)
            try move(r, col: 30, row: 5)   // off every mark before the dwell ran
            XCTAssertTrue(r.v.marks.hover.over == nil)
            XCTAssertTrue(r.items.last?.item.isCancelled == true)
            for i in r.items { i.item.perform() }
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.count, 0)
            XCTAssertTrue(r.cards.views.isEmpty)
        }
    }

    /// Red if the dwell shows no card at once, spawns more than one read, sends --full, or a budget other than 250 with
    /// no cost kept and then max(50, 300 - p75) of the kept costs (first.elapsed_ms).
    func testOneLightSpawnAfter500msWithTheBudget() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            dwell(r, "issue:#12")
            XCTAssertEqual(r.cards.views.count, 1, "the card at once, with the cached row")
            XCTAssertEqual(r.v.marks.hover.card?.key, "issue:#12")
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls, [["--xray", "api", "--ref", "-", "--scope", "project", "--budget-ms", "250", "--json"]])
            XCTAssertEqual(r.run.stdins.last, "#12\n")
            XCTAssertEqual(XrayPanels.spawnCosts, [120], "first.elapsed_ms kept")
            XCTAssertEqual(r.panel.refContext?.ref, "#12")
            r.v.marks.hover.close(all: false)
            r.v.marks.hover.point(nil)
            dwell(r, "issue:#12")
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.count, 2)
            XCTAssertEqual(r.run.calls.last?.contains("--full"), false)
            XCTAssertEqual(r.run.calls.last?.split(separator: "--budget-ms").last?.first, "180", "300 - 120")
            XrayPanels.spawnCosts = [70, 10, 400, 20, 30, 40, 50, 60]
            XCTAssertEqual(XrayPanels.budget(), 240, "p75 (nearest rank) of 8 is the 6th: 60")
            XrayPanels.spent(5)
            XCTAssertEqual(XrayPanels.spawnCosts.count, 8, "the last 8 only")
            XrayPanels.spawnCosts = [400]
            XCTAssertEqual(XrayPanels.budget(), 50, "never under dch's 50")
            XCTAssertEqual(XrayTarget(name: "api", dir: "/d").lightArgs("x", budget: 999).dropLast().last, "300")
        }
    }

    /// Red if a move to another mark waits for a dwell, leaves the old read running, starts the new one before the
    /// 150 ms settle, or the card stays past 250 ms once the pointer left the mark and the card (or goes while on it).
    func testSwitchKillsAndSettlesAndLeaveClosesAt250ms() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            dwell(r, "issue:#1")   // the fake's "#1" read runs until cancelled
            await waitCalls(r.run, 1)
            r.v.marks.hover.point("issue:#12")
            XCTAssertEqual(r.cards.views.count, 2, "switched at once")
            XCTAssertEqual(r.v.marks.hover.card?.key, "issue:#12", "the old card's close is not news")
            await waitCancelled(r.run, 1)
            XCTAssertEqual(r.run.cancelled, 1, "the old read killed")
            XCTAssertEqual(r.run.calls.count, 1, "no read before the settle")
            let settle = try XCTUnwrap(r.item(0.15))
            settle.perform()
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.count, 2)
            XCTAssertEqual(r.run.stdins.last, "#12\n")
            // leave: the mark, then onto the card (kept), then off the card (closed after 250 ms)
            r.v.marks.hover.point(nil)
            XCTAssertEqual(r.items.last?.delay, 0.25)
            r.v.marks.hover.onCard(true)
            XCTAssertTrue(r.items.last?.item.isCancelled == true)
            XCTAssertTrue(r.cards.shown != nil)
            r.v.marks.hover.onCard(false)
            let linger = try XCTUnwrap(r.items.last { $0.delay == 0.25 && !$0.item.isCancelled }?.item)
            XCTAssertTrue(r.cards.shown != nil, "not before 250 ms")
            linger.perform()
            XCTAssertTrue(r.cards.shown == nil)
            XCTAssertTrue(r.v.marks.hover.card == nil)
        }
    }

    /// #1772 (QA R1760 n88): red at base (no promote: the linger closes a card the user clicked and types in). A promoted
    /// card: the linger is cancelled and not re-armed on leaving the mark or the card, output leaves it, another mark does
    /// not replace it, Esc still closes it. An unpromoted hover card still closes on its linger.
    func testAPromotedHoverCardIsPinnedInPlace() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            let h = r.v.marks.hover
            dwell(r, "issue:#12")
            h.point(nil)
            let armed = try XCTUnwrap(r.items.last { $0.delay == 0.25 && !$0.item.isCancelled }?.item)
            h.promote()
            XCTAssertTrue(armed.isCancelled, "the armed linger is cancelled")
            XCTAssertTrue(h.promoted)
            let n = r.items.count
            h.onCard(true)
            h.onCard(false)
            h.point("issue:#1")
            h.point(nil)
            XCTAssertEqual(r.items.count, n, "no linger or settle is armed for a promoted card")
            XCTAssertEqual(h.card?.key, "issue:#12", "another mark does not replace it")
            r.v.marks.output()
            XCTAssertTrue(r.cards.shown != nil, "output leaves it")
            r.v.marks.escape()
            XCTAssertTrue(r.cards.shown == nil, "Esc closes it")
            XCTAssertFalse(h.promoted)
            await r.panels.refReading?.value
            // an unpromoted one still closes on its linger
            dwell(r, "issue:#12")
            h.point(nil)
            let linger = try XCTUnwrap(r.items.last { $0.delay == 0.25 && !$0.item.isCancelled }?.item)
            linger.perform()
            XCTAssertTrue(r.cards.shown == nil, "a hover card closes on linger")
            await r.panels.refReading?.value
        }
    }

    /// Red if output leaves an unpinned card up, or closes a pinned one.
    func testOutputClosesUnpinnedKeepsPinned() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            dwell(r, "issue:#12")
            XCTAssertTrue(r.cards.shown != nil)
            r.v.marks.output()
            XCTAssertTrue(r.cards.shown == nil, "unpinned: closed")
            XCTAssertTrue(r.v.marks.hover.card == nil)
            r.v.marks.place()
            r.v.marks.hover.point(nil)
            dwell(r, "issue:#12")
            r.v.marks.hover.pin()
            XCTAssertTrue(r.cards.shown != nil)
            r.v.marks.output()
            XCTAssertTrue(r.cards.shown != nil, "pinned: kept")
            XCTAssertEqual(r.panel.refCard?.key, "issue:#12")
            await r.panels.refReading?.value
        }
    }

    /// Red if Pin leaves the light read running, opens no card, or the card it opens is not today's (--full).
    func testPinKillsTheLightReadThenAFullSpawn() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            dwell(r, "issue:#1")
            await waitCalls(r.run, 1)
            XCTAssertEqual(r.run.calls.first?.contains("--budget-ms"), true)
            r.v.marks.hover.pin()
            await waitCancelled(r.run, 1)
            XCTAssertEqual(r.run.cancelled, 1, "SIGTERM on the light read")
            await waitCalls(r.run, 2)
            XCTAssertEqual(r.run.calls.last, ["--xray", "api", "--ref", "-", "--scope", "project", "--full", "--json"])
            XCTAssertEqual(r.panel.refCard?.key, "issue:#1", "openRef: today's card")
            XCTAssertTrue(r.v.marks.hover.card == nil)
            r.panels.closeRef()
            await waitCancelled(r.run, 2)
        }
    }

    /// #1824: red with the cached light answer not served (M2-noHit): the dwell's light read (the hover-intent prefetch)
    /// lands in the window cache, so a Command-click on the mark opens the pinned card with its rows at once.
    func testDwellPrefetchMakesTheClickACacheHit() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            let cache = XrayRefResults()
            r.panel.refResults = { cache }
            dwell(r, "issue:#12")
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.count, 1)
            XCTAssertEqual(r.run.calls.first?.contains("--budget-ms"), true)
            XCTAssertTrue(r.v.marks.hover.click("issue:#12"))
            XCTAssertEqual(r.panel.refCard?.key, "issue:#12")
            let c = try XCTUnwrap(r.panel.refContext, "the rows before any await")
            XCTAssertTrue(c.light && c.more)
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.count, 2, "the full read only")
            XCTAssertEqual(r.run.calls.last?.contains("--full"), true)
            XCTAssertEqual(r.panel.refContext?.light, false)
        }
    }

    /// #1824: red if a move off the mark before the dwell still reads (M6-dwellKept: the dwell item not cancelled), or a
    /// move to another mark leaves the old prefetch running (M7-switchKeeps: show's closeRef dropped).
    func testPointerMoveCancelsThePrefetch() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            r.v.marks.hover.point("issue:#1")
            let pending = try XCTUnwrap(r.item(0.5))
            r.v.marks.hover.point(nil)
            XCTAssertTrue(pending.isCancelled, "a move off the mark: no prefetch")
            XCTAssertEqual(r.run.calls.count, 0)
            dwell(r, "issue:#1")
            await waitCalls(r.run, 1)
            r.v.marks.hover.point("issue:#12")
            await waitCancelled(r.run, 1)
            XCTAssertEqual(r.run.cancelled, 1, "the move to #12 killed #1's light read")
            r.v.marks.hover.close(all: true)
            await r.panels.refReading?.value
        }
    }

    /// Red if an unpinned card shows another session's mention or passage, or a pinned one loses them.
    func testUnpinnedCardDropsOtherSessionLines() throws {
        let c = XrayRefContext(XrayRefStream.parse(Data(Self.stream.utf8)), ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(c.groups.map(\.session), ["api", "api-qa"])
        let g = c.guarded(pinned: false, shell: false)
        XCTAssertEqual(g.groups.map(\.session), ["api"])
        XCTAssertEqual(g.groups.flatMap(\.mentions).map(\.line), ["see #12 here"])
        XCTAssertEqual(g.definitions.map(\.passage).sorted(), ["", "own passage"])
        XCTAssertEqual(g.definitions.count, 2, "titles stay")
        XCTAssertEqual(g.counts, c.counts, "counts stay")
        XCTAssertTrue(c.guarded(pinned: true, shell: true) == c, "pinned: all of it")
        // the card itself: unpinned (a hover) guarded, today's card not
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: local.dir), tab: .refs)
        p.refContext = c
        let e = try XCTUnwrap(XrayRefLinkFixture.parsed().entries.first)
        XCTAssertEqual(XrayRefPopover(panel: p, entry: e, complete: true, hover: XrayHover()).context?.groups.count, 1)
        XCTAssertEqual(XrayRefPopover(panel: p, entry: e, complete: true).context?.groups.count, 2)
    }

    /// Red if an unpinned shell card shows a mention line, a passage or a first mention (titles and counts only), or
    /// the shell id test takes another id.
    func testShellCardHasNoLineOrPassage() {
        let c = XrayRefContext(XrayRefStream.parse(Data(Self.stream.utf8)), ref: "#12", tasks: nil, memory: nil)
        let s = c.guarded(pinned: false, shell: true)
        XCTAssertTrue(s.groups.isEmpty)
        XCTAssertTrue(s.turns == nil || s.turns?.isEmpty == true)
        XCTAssertTrue(s.firstMention == nil)
        XCTAssertEqual(s.definitions.map(\.passage), ["", ""])
        XCTAssertEqual(s.definitions.map(\.title), ["Login retries", "Login retries"])
        XCTAssertEqual(s.counts, c.counts)
        XCTAssertTrue(XrayRefContext.shell("m0123456789abcdef"))
        XCTAssertFalse(XrayRefContext.shell(XrayRefLinkFixture.sessionID))
        XCTAssertFalse(XrayRefContext.shell("m0123456789abcdeg"))
        XCTAssertFalse(XrayRefContext.shell(nil))
    }

    /// Red if a dwell opens a card on an unfocused pane, a window that is not key, with a button down, or over another
    /// card.
    func testUnfocusedPaneOpensNothing() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            r.t.paneFocused = { false }
            r.v.marks.place()
            try move(r, col: 5, row: 1)
            XCTAssertTrue(r.v.marks.hover.over == nil, "no marks on an unfocused pane")
            dwell(r, "issue:#12")
            r.t.paneFocused = { true }
            r.v.marks.hover.point(nil)
            r.v.marks.windowKey = { _ in false }
            dwell(r, "issue:#12")
            r.v.marks.windowKey = { _ in true }
            r.v.marks.hover.point(nil)
            r.v.marks.buttons = { 1 }
            dwell(r, "issue:#12")
            XCTAssertEqual(r.run.calls.count, 0)
            XCTAssertTrue(r.cards.views.isEmpty)
            r.v.marks.buttons = { 0 }
            r.v.marks.hover.point(nil)
            dwell(r, "issue:#12")
            XCTAssertEqual(r.cards.views.count, 1, "back")
            await r.panels.refReading?.value
        }
    }

    /// Red if Esc, pane hide or blur leaves a card (pinned or not) up, or its read running.
    func testEscHideAndBlurCloseAnyCard() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            dwell(r, "issue:#12")
            r.v.marks.hover.pin()
            r.v.marks.escape()
            XCTAssertTrue(r.cards.shown == nil, "Esc: the pinned card too")
            await r.panels.refReading?.value
            r.v.marks.hover.point(nil)
            dwell(r, "issue:#1")
            await waitCalls(r.run, 3)
            r.v.marks.viewDidHide()
            XCTAssertTrue(r.cards.shown == nil, "pane hide")
            await waitCancelled(r.run, 1)
            XCTAssertEqual(r.run.cancelled, 1, "its read killed")
            r.v.marks.hover.point(nil)
            dwell(r, "issue:#12")
            XCTAssertTrue(r.cards.shown != nil)
            r.v.marks.follow = nil
            XCTAssertTrue(r.cards.shown == nil, "blur")
        }
    }

    // MARK: #1701 (operator 2026-11-20): one hover rule for every ref kind, Command only, list numbers, Cmd-click pins

    /// The screenshot's shapes: a PR ref, a wt- ref, an OQ- ref with a list after it, and a plain number in prose.
    static let shot = "$ git log\nafter the #24065 build, wt-2554 parked\nOQ-1977, 1978, 1980, 1981, 1991 and 1994.\nby 2558.\n"

    static func ref(_ key: String, _ shape: String, _ text: String) -> String {
        #"{"schema":1,"ref":{"key":"\#(key)","shape":"\#(shape)","text":"\#(text)","count":1,"underline":true}}"#
    }

    /// The rig on `shot` with its three refs sent as deltas.
    func shotRig(_ fake: XrayFollowTests.Fake) throws -> Rig {
        let r = try rig(fake)
        r.v.viewportText = { Self.shot }
        fake.send(1, Self.ref("pull:#24065", "pull", "#24065"))
        fake.send(1, Self.ref("ticket:wt-2554", "ticket", "wt-2554"))
        fake.send(1, Self.ref("ticket:OQ-1977", "ticket", "OQ-1977"))
        r.v.marks.place()
        return r
    }

    /// Red if the list numbers are not refs keyed as their seed (OQ-1978 ...), a plain "2558" in prose or "entry 2554"
    /// is, or the list walks past a word, a date, a decimal, a code span or another separator.
    func testListNumbersContinueTheirPrefixAndProseNumbersDoNot() throws {
        func keys(_ line: String, _ seeds: [(String, String)]) -> [String] {
            let refs = seeds.enumerated().map { i, s in
                XrayRefs.Entry(key: s.0, shape: .ticket, text: s.1, full: nil, count: 1, lastOffset: nil, defined: false,
                               definitions: 0, title: "", underline: true, index: i)
            }
            let found = XrayRefSpans.find(line, refs)
            return XrayRefSpans.continued(line, after: found).map(\.key)
        }
        let oq = [("ticket:OQ-1977", "OQ-1977")]
        XCTAssertEqual(keys("from cdv2: OQ-1977, 1978, 1980, 1981, 1991 and 1994.", oq),
                       ["ticket:OQ-1978", "ticket:OQ-1980", "ticket:OQ-1981", "ticket:OQ-1991", "ticket:OQ-1994"])
        XCTAssertEqual(keys("OQ-1977, 1978, and 1980 or 1981", oq), ["ticket:OQ-1978", "ticket:OQ-1980", "ticket:OQ-1981"])
        XCTAssertEqual(keys("by 2558. OQ-1977 is open; entry 2554 is parked", oq), [], "prose numbers are not refs")
        XCTAssertEqual(keys("OQ-1977, due 1978", oq), [], "a word between ends the list")
        XCTAssertEqual(keys("OQ-1977, 2026-11-21", oq), [], "a date is no list number")
        XCTAssertEqual(keys("OQ-1977, 1.5 points", oq), [], "a decimal is none")
        XCTAssertEqual(keys("OQ-1977, 12ms", oq), [], "nor a number with a unit")
        XCTAssertEqual(keys("OQ-1977, `1978`", oq), [], "nor one in code")
        XCTAssertEqual(keys("OQ-1977; 1978", oq), [], "only , and or")
        XCTAssertEqual(keys("OQ-1977, 1978, 1980", oq + [("issue:1978", "1978")]), [], "a number that is a ref of its own ends the list")
        XCTAssertEqual(keys("#24065 and 24066", [("pull:#24065", "#24065")]), ["pull:#24066"])
        XCTAssertEqual(keys("#1700 and 2 more", [("pull:#1700", "#1700")]), [], "#1721: too few digits")
        XCTAssertEqual(keys("OQ-190, 3 tests", [("ticket:OQ-190", "OQ-190")]), [], "#1721: one digit")
        XCTAssertEqual(keys("wt-12 or 4 days", [("ticket:wt-12", "wt-12")]), [], "#1721: one digit")
        XCTAssertEqual(keys("OQ-1977, 197", oq), ["ticket:OQ-197"], "#1721: seed digits minus 1 still continues")
        XCTAssertEqual(keys("OQ-1977, 19", oq), [], "#1721: fewer than seed digits minus 1")
        XCTAssertEqual(keys("abc123, 456", [("commit:abc123", "abc123")]), [], "a hex has no list prefix")
        XCTAssertTrue(XrayRefSpans.listPrefix("OQ-") == nil && XrayRefSpans.listPrefix("-12") == nil && XrayRefSpans.listPrefix("#") == nil)
        let e = try XCTUnwrap(XrayRefSpans.listed("ticket:OQ-1978", in: [XrayRefs.Entry(
            key: "ticket:OQ-1977", shape: .ticket, text: "OQ-1977", full: nil, count: 3, lastOffset: nil, defined: false,
            definitions: 0, title: "t", underline: true, index: 0)]))
        XCTAssertEqual([e.text, e.title], ["OQ-1978", ""])
        XCTAssertEqual(e.shape, .ticket)
        XCTAssertTrue(XrayRefSpans.listed("ticket:OQ-19x8", in: [e]) == nil)
    }

    /// Red if a PR ref (or any kind) hovers without Command, misses the hover with it, a list number gets no mark or
    /// no card (its read sends "OQ-1978"), or "2558" in prose is marked.
    func testEveryRefKindHoversWithCommandOnly() async throws {
        try await withSeams { fake in
            let r = try shotRig(fake)
            XCTAssertEqual(r.v.marks.marks.map(\.key), ["pull:#24065", "ticket:wt-2554", "ticket:OQ-1977", "ticket:OQ-1978",
                                                       "ticket:OQ-1980", "ticket:OQ-1981", "ticket:OQ-1991", "ticket:OQ-1994"])
            XCTAssertFalse(r.v.marks.marks.contains { $0.row == 3 }, "2558 in prose")
            for (col, row, key) in [(10, 1, "pull:#24065"), (24, 1, "ticket:wt-2554"), (0, 2, "ticket:OQ-1977"), (9, 2, "ticket:OQ-1978"),
                                    (36, 2, "ticket:OQ-1994")] {
                let armed = r.items.count
                try move(r, col: col, row: row, [])
                XCTAssertTrue(r.v.marks.hover.over == nil, "\(key): no hover without Command")
                XCTAssertEqual(r.items.count, armed, "\(key): no dwell armed")
                try move(r, col: col, row: row)
                XCTAssertEqual(r.v.marks.hover.over, key)
                r.item(0.5)?.perform()
                XCTAssertEqual(r.v.marks.hover.card?.key, key, "the same card for every kind")
                await r.panels.refReading?.value
                r.v.marks.hover.close(all: true)
                try move(r, col: 30, row: 5)
            }
            XCTAssertEqual(r.run.stdins.last, "OQ-1994\n", "a list number's read is its prefixed text")
            XCTAssertTrue(r.run.stdins.contains("OQ-1978\n"))
        }
    }

    func flags(_ f: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    }

    /// Red if pressing Command over a mark does not hover it, or releasing it is not a hover-out (the 250 ms close).
    func testCommandDownHoversAndCommandUpClosesAsHoverOut() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            try move(r, col: 5, row: 1, [])
            XCTAssertTrue(r.v.marks.hover.over == nil)
            r.v.flagsChanged(with: try flags(.command))   // the host is the first responder; a built event, never posted
            XCTAssertEqual(r.v.marks.hover.over, "issue:#12")
            r.item(0.5)?.perform()
            XCTAssertTrue(r.cards.shown != nil)
            await r.panels.refReading?.value
            r.v.flagsChanged(with: try flags([]))
            XCTAssertTrue(r.v.marks.hover.over == nil)
            XCTAssertTrue(r.cards.shown != nil, "not before 250 ms")
            try XCTUnwrap(r.items.last { $0.delay == 0.25 && !$0.item.isCancelled }?.item).perform()
            XCTAssertTrue(r.cards.shown == nil, "released: closed as a hover-out")
        }
    }

    /// Red if a Command-click on a mark opens no pinned card, hands the down or its up to libghostty (which opens an
    /// OSC 8 link on the up), or a plain click is no longer the program's.
    func testCommandClickPinsTheCardAndOpensNoLink() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            var passed: [NSEvent.EventType] = []
            r.v.passedClick = { passed.append($0.type) }
            func click(_ type: NSEvent.EventType, _ f: NSEvent.ModifierFlags) throws -> NSEvent {
                // no window: the view's own unflipped space; row 1, column 4 ("#12") from the top
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 4 + 8 * 4 + 2, y: 410 - (2 + 17 + 3)),
                                                 modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1))
            }
            r.v.mouseDown(with: try click(.leftMouseDown, []))
            r.v.mouseUp(with: try click(.leftMouseUp, []))
            XCTAssertEqual(passed, [.leftMouseDown, .leftMouseUp], "a plain click is the program's, as before")
            XCTAssertTrue(r.cards.shown == nil)
            r.v.mouseDown(with: try click(.leftMouseDown, .command))
            r.v.mouseUp(with: try click(.leftMouseUp, .command))
            XCTAssertEqual(passed.count, 2, "the Command-click stops here: no link opens")
            XCTAssertTrue(r.cards.shown != nil)
            XCTAssertEqual(r.panel.refCard?.key, "issue:#12", "pinned: today's full card")
            XCTAssertTrue(r.v.marks.hover.card == nil, "no unpinned card left")
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.last?.contains("--full"), true)
            try move(r, col: 30, row: 5, [])
            for i in r.items where !i.item.isCancelled { i.item.perform() }
            XCTAssertTrue(r.cards.shown != nil, "Command up and the pointer gone: the pinned card stays")
            r.v.mouseUp(with: try click(.leftMouseUp, []))
            XCTAssertEqual(passed.count, 3, "the next up goes on")
        }
    }

    // MARK: #1901 (operator 2026-11-23): Cmd+Shift hands the click to libghostty (it opens a link on the up)

    /// Red at the parent: Cmd+Shift on a mark pinned its card and stopped the down and up (old line
    /// `if let k = marks.mark(at: q)?.key, marks.hover.click(k)` ran with Shift too), so libghostty never opened the link.
    /// Red too if Cmd alone stops pinning or passes the click on (#1701).
    func testCommandShiftOnAMarkPassesBothClicksOnAndPinsNothing() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            var passed: [NSEvent.EventType] = []
            r.v.passedClick = { passed.append($0.type) }
            var refs = 0
            r.v.openRef = { _, _, _, _ in refs += 1; return true }
            func click(_ type: NSEvent.EventType, _ f: NSEvent.ModifierFlags) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 4 + 8 * 4 + 2, y: 410 - (2 + 17 + 3)),
                                                 modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1))
            }
            for captured in [true, false] {
                r.v.mouseCaptured = { captured }
                passed = []
                r.v.mouseDown(with: try click(.leftMouseDown, [.command, .shift]))
                r.v.mouseUp(with: try click(.leftMouseUp, [.command, .shift]))
                XCTAssertEqual(passed, [.leftMouseDown, .leftMouseUp], "captured \(captured)")
                XCTAssertTrue(r.cards.shown == nil && r.v.marks.hover.card == nil, "captured \(captured): no card")
                XCTAssertEqual(refs, 0)
                XCTAssertFalse(r.v.pinnedDown)
            }
            passed = []
            r.v.mouseDown(with: try click(.leftMouseDown, .command))
            r.v.mouseUp(with: try click(.leftMouseUp, .command))
            XCTAssertTrue(r.cards.shown != nil && passed.isEmpty, "Cmd alone: the card, nothing passed on")
        }
    }
}
