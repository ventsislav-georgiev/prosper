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
    func move(_ r: Rig, col: Int, row: Int) throws {
        let p = CGPoint(x: 4 + 8 * CGFloat(col) + 1, y: 2 + 17 * CGFloat(row) + 1)   // no window: scale 2, cells 8 x 17 pt
        let e = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: r.v.marks.convert(p, to: nil), modifierFlags: [],
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
}
