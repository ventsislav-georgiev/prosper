import AppKit
import GhosttyTerminal
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1565 (X-T b), #1701: the card over the grid's marks, opened by a Command-click (#1926/#1931: no hover card). A fake
/// follow (XrayFollowTests.Fake) gives the marks, a fake dch runner (XrayRefRunTests.Run) answers and records each argv
/// and cancel, a fake presenter (XrayRefPopoverTests.Cards) records the cards. The settle items are kept; the window is
/// never made (the overlay's seams answer shown and cards). No dch, no event posted, no card shown.
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
    /// row 2 col 4), the items kept, the overlay's seams on (shown, a card up while the fake shows one) and a fake panel.
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
    /// #1926: Command held unless `flags` says otherwise (a hold opens nothing).
    func move(_ r: Rig, col: Int, row: Int, _ flags: NSEvent.ModifierFlags = .command) throws {
        let p = CGPoint(x: 4 + 8 * CGFloat(col) + 1, y: 2 + 17 * CGFloat(row) + 1)   // no window: scale 2, cells 8 x 17 pt
        let e = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: r.v.marks.convert(p, to: nil), modifierFlags: flags,
                                                 timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        r.v.marks.mouseMoved(with: e)
    }

    /// #1931: mark `key`'s card, as a Command-click on it opens it (AgentTerminalHostView.mouseDown -> hover.click).
    func open(_ r: Rig, _ key: String) {
        XCTAssertTrue(r.v.marks.hover.click(key), key)
    }

    func waitCancelled(_ run: XrayRefRunTests.Run, _ n: Int) async {
        let end = Date().addingTimeInterval(5)
        while run.cancelled < n, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func waitCalls(_ run: XrayRefRunTests.Run, _ n: Int) async {
        let end = Date().addingTimeInterval(5)
        while run.calls.count < n, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// #1931 (was the dwell's light-read row): red if a Command-click shows no card at once, runs anything but one
    /// full --ref read on stdin, or the card drops another session's lines (the unpinned guard went with the hover). The
    /// light budget (#1565 6.3, still the staged open's, XrayRefStagedOpenTests) stays max(50, 300 - p75), 250 with none.
    func testCommandClickOpensTheCardAtOnceWithOneFullRead() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            open(r, "issue:#12")
            XCTAssertEqual(r.cards.views.count, 1, "the card at once, with the cached row")
            XCTAssertEqual(r.panel.refCard?.key, "issue:#12")
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls, [["--xray", "api", "--ref", "-", "--scope", "project", "--full", "--json"]])
            XCTAssertEqual(r.run.stdins.last, "#12\n")
            XCTAssertEqual(XrayPanels.spawnCosts, [], "a full read keeps no light cost")
            XCTAssertEqual(r.panel.refContext?.ref, "#12")
            XCTAssertEqual(r.panel.refContext?.groups.map(\.session), ["api", "api-qa"])
            let e = try XCTUnwrap(XrayRefLinkFixture.parsed().entries.first)
            XCTAssertEqual(XrayRefPopover(panel: r.panel, entry: e, complete: true).context?.groups.count, 2, "all of it")
            XCTAssertEqual(XrayPanels.budget(), 250)
            XrayPanels.spawnCosts = [70, 10, 400, 20, 30, 40, 50, 60]
            XCTAssertEqual(XrayPanels.budget(), 240, "p75 (nearest rank) of 8 is the 6th: 60")
            XrayPanels.spent(5)
            XCTAssertEqual(XrayPanels.spawnCosts.count, 8, "the last 8 only")
            XrayPanels.spawnCosts = [400]
            XCTAssertEqual(XrayPanels.budget(), 50, "never under dch's 50")
            XCTAssertEqual(XrayTarget(name: "api", dir: "/d").lightArgs("x", budget: 999).dropLast().last, "300")
        }
    }

    /// #1931 (was the hover switch row): red if a Command-click on another mark leaves the old card or its read running,
    /// or waits to open the new one.
    func testAClickOnAnotherMarkReplacesTheCardAndKillsItsRead() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            open(r, "issue:#1")   // the fake's "#1" read runs until cancelled
            await waitCalls(r.run, 1)
            open(r, "issue:#12")
            XCTAssertEqual(r.cards.views.count, 2, "switched at once")
            XCTAssertEqual(r.panel.refCard?.key, "issue:#12")
            await waitCancelled(r.run, 1)
            XCTAssertEqual(r.run.cancelled, 1, "the old read killed")
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.count, 2)
            XCTAssertEqual(r.run.stdins.last, "#12\n")
            XCTAssertTrue(r.cards.shown != nil)
        }
    }

    /// Red if output closes the card (#1931: every grid card is a pinned one).
    func testOutputKeepsTheCard() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            open(r, "issue:#12")
            XCTAssertTrue(r.cards.shown != nil)
            r.v.marks.output()
            XCTAssertTrue(r.cards.shown != nil, "kept")
            XCTAssertEqual(r.panel.refCard?.key, "issue:#12")
            await r.panels.refReading?.value
        }
    }

    /// #1824 (was the dwell prefetch row): red with the cached light answer not served (M2-noHit): a light answer in the
    /// window cache makes a Command-click open the card with its rows at once; only the full read runs.
    func testACachedLightAnswerMakesTheClickACacheHit() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            let cache = XrayRefResults()
            r.panel.refResults = { cache }
            cache.put(.init(target: r.panel.target, ref: "#12", light: true, scope: "project"), Data(Self.stream.utf8))
            open(r, "issue:#12")
            XCTAssertEqual(r.panel.refCard?.key, "issue:#12")
            let c = try XCTUnwrap(r.panel.refContext, "the rows before any await")
            XCTAssertTrue(c.light && c.more)
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.count, 1, "the full read only")
            XCTAssertEqual(r.run.calls.last?.contains("--full"), true)
            XCTAssertEqual(r.panel.refContext?.light, false)
        }
    }

    /// #1931 (was the dwell gate row): red if a Command-click on an unfocused pane opens a card or reads (the pane draws
    /// no marks, its down never reaches the card), or a focused pane's does not.
    func testUnfocusedPaneOpensNothing() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            var refs = 0
            r.v.openRef = { _, _, _, _ in refs += 1; return true }
            r.v.passedClick = { _ in }
            func click(_ type: NSEvent.EventType) throws -> NSEvent {   // row 1, column 4 ("#12"), the view's unflipped space
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 4 + 8 * 4 + 2, y: 410 - (2 + 17 + 3)),
                                                 modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1))
            }
            r.t.paneFocused = { false }
            r.v.marks.place()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "no marks on an unfocused pane")
            r.v.mouseDown(with: try click(.leftMouseDown))
            r.v.mouseUp(with: try click(.leftMouseUp))
            XCTAssertEqual(r.run.calls.count, 0)
            XCTAssertTrue(r.cards.views.isEmpty)
            XCTAssertEqual(refs, 0)
            r.t.paneFocused = { true }
            r.v.marks.place()
            r.v.mouseDown(with: try click(.leftMouseDown))
            r.v.mouseUp(with: try click(.leftMouseUp))
            XCTAssertEqual(r.cards.views.count, 1, "back")
            await r.panels.refReading?.value
        }
    }

    /// Red if Esc, pane hide or blur leaves the card up, or its read running.
    func testEscHideAndBlurCloseAnyCard() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            open(r, "issue:#12")
            r.v.marks.escape()
            XCTAssertTrue(r.cards.shown == nil, "Esc")
            await r.panels.refReading?.value
            open(r, "issue:#1")
            await waitCalls(r.run, 2)
            r.v.marks.viewDidHide()
            XCTAssertTrue(r.cards.shown == nil, "pane hide")
            await waitCancelled(r.run, 1)
            XCTAssertEqual(r.run.cancelled, 1, "its read killed")
            open(r, "issue:#12")
            XCTAssertTrue(r.cards.shown != nil)
            r.v.marks.follow = nil
            XCTAssertTrue(r.cards.shown == nil, "blur")
            await r.panels.refReading?.value
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

    /// Red if a PR ref (or any kind) opens no pinned card on a Command-click, a list number gets no mark or no card (its read
    /// sends "OQ-1978"), or "2558" in prose is marked.
    func testEveryRefKindOpensItsCardOnCommandClick() async throws {
        try await withSeams { fake in
            let r = try shotRig(fake)
            XCTAssertEqual(r.v.marks.marks.map(\.key), ["pull:#24065", "ticket:wt-2554", "ticket:OQ-1977", "ticket:OQ-1978",
                                                       "ticket:OQ-1980", "ticket:OQ-1981", "ticket:OQ-1991", "ticket:OQ-1994"])
            XCTAssertFalse(r.v.marks.marks.contains { $0.row == 3 }, "2558 in prose")
            r.v.passedClick = { _ in }
            for (col, row, key) in [(10, 1, "pull:#24065"), (24, 1, "ticket:wt-2554"), (0, 2, "ticket:OQ-1977"), (9, 2, "ticket:OQ-1978"),
                                    (36, 2, "ticket:OQ-1994")] {
                func click(_ type: NSEvent.EventType) throws -> NSEvent {   // no window: the view's own unflipped space
                    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 4 + 8 * CGFloat(col) + 2, y: 410 - (2 + 17 * CGFloat(row) + 3)),
                                                     modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
                }
                r.v.mouseDown(with: try click(.leftMouseDown))
                r.v.mouseUp(with: try click(.leftMouseUp))
                XCTAssertEqual(r.panel.refCard?.key, key, "the same pinned card for every kind")
                await r.panels.refReading?.value
                r.v.marks.hover.close()
            }
            XCTAssertEqual(r.run.stdins.last, "OQ-1994\n", "a list number's read is its prefixed text")
            XCTAssertTrue(r.run.stdins.contains("OQ-1978\n"))
        }
    }

    func flags(_ f: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    }

    /// #1926 (operator 2026-11-24): red at the parent (a Command move or a Command press over a mark armed the 500 ms dwell:
    /// hover.over was the mark, a card opened). Holding Command, with the pointer over any mark or moving between them,
    /// arms nothing, opens no card and reads nothing; Command-click (below) is the only way a card opens. #1931: the
    /// dwell is gone; the row keeps the hold and the moves.
    func testCommandHoldOverAMarkOpensNothing() async throws {
        try await withSeams { fake in
            let r = try shotRig(fake)
            let armed = r.items.count
            r.v.flagsChanged(with: try flags(.command))   // the host is the first responder; a built event, never posted
            for (col, row) in [(10, 1), (24, 1), (0, 2), (30, 5), (36, 2)] { try move(r, col: col, row: row) }
            r.v.flagsChanged(with: try flags([]))
            for i in r.items { i.item.perform() }
            await r.panels.refReading?.value
            XCTAssertEqual(r.items.count, armed, "no dwell, settle or linger armed")
            XCTAssertTrue(r.v.marks.hover.model == nil, "no card opened")
            XCTAssertTrue(r.cards.shown == nil && r.cards.views.isEmpty)
            XCTAssertEqual(r.run.calls.count, 0)
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
            await r.panels.refReading?.value
            XCTAssertEqual(r.run.calls.last?.contains("--full"), true)
            try move(r, col: 30, row: 5, [])
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
                XCTAssertTrue(r.cards.shown == nil && r.v.marks.hover.model == nil, "captured \(captured): no card")
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
