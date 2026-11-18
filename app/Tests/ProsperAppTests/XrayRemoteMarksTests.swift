import AppKit
import GhosttyTerminal
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1568 (X-R a, plan 905 phase G): grid marks, hover and Cmd-click on a remote row, keyed "host:name". A fake follow
/// (XrayFollowTests.Fake) gives the marks, a fake dch runner (XrayRefRunTests.Run) records each argv, a fake `--requests`
/// child (XrayRequestsTests.Spawns) stands in for the warm connection, a fake presenter (XrayRefPopoverTests.Cards)
/// records the cards. The windows are never ordered in or made key; the Esc is a built NSEvent handed to the view's own
/// keyDown, never posted. No dch, no ssh, no card shown.
@MainActor
final class XrayRemoteMarksTests: XCTestCase {
    typealias Cards = XrayRefPopoverTests.Cards
    let remote = AgentSessionKey(dir: "@example-host", name: "api")
    let target = XrayTarget(name: "example-host:api", dir: nil)
    let grid = TerminalGridMetrics(columns: 80, rows: 24, widthPixels: 1280, heightPixels: 816, cellWidthPixels: 16, cellHeightPixels: 34)

    override func setUp() {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 99, 0])
        XrayPanels.spawnCosts = []
    }

    override func tearDown() {
        XrayPanels.probed = nil
        XrayPanels.spawnCosts = []
    }

    /// The seams set for the body and put back after it (follow, its gate, the dch path, gate B); the shared LRU keeps
    /// no follow of these rows'.
    func withSeams(_ body: (XrayFollowTests.Fake) async throws -> Void) async rethrows {
        let (ok, follow, dch, decorate) = (XrayPanels.followOK, XrayPanels.follow, XrayPanels.dch, XrayRefLink.decorate)
        defer {
            (XrayPanels.followOK, XrayPanels.follow, XrayPanels.dch, XrayRefLink.decorate) = (ok, follow, dch, decorate)
            for f in XrayPanels.shared.follows.follows where f.target.name.hasPrefix("example-host:") { XrayPanels.shared.follows.drop(f) }
        }
        let fake = XrayFollowTests.Fake()
        XrayPanels.followOK = { true }
        XrayPanels.follow = fake.follow
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 99, 0])
        XrayRefLink.decorate = { true }
        try await body(fake)
    }

    final class Rig {
        let t: AgentTerminalController
        let v: AgentTerminalHostView
        let run = XrayRefRunTests.Run()
        let cards: Cards
        let panels: XrayPanels   // the panel's is weak
        var panel: XrayPanelModel?
        var items: [(delay: TimeInterval, item: DispatchWorkItem)] = []
        var passed: [NSEvent] = []
        init(t: AgentTerminalController, v: AgentTerminalHostView, cards: Cards, panels: XrayPanels) {
            (self.t, self.v, self.cards, self.panels) = (t, v, cards, panels)
        }
        func item(_ delay: TimeInterval) -> DispatchWorkItem? { items.last { $0.delay == delay }?.item }
    }

    /// A live remote terminal (never in a window unless the row puts it in one), the items kept, the overlay's seams on
    /// (shown, key window, no button; a card is up while the fake presenter shows one).
    func rig() -> Rig {
        let t = AgentTerminalController()
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        let r = Rig(t: t, v: v, cards: Cards(), panels: XrayPanels())
        t.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        t.makeScreen = { AgentTerminalTests.FakeScreen($0) }
        v.owner = t
        t.view = v
        v.gridMetrics = grid
        let text = XrayGridMarksTests.viewport
        v.viewportText = { text }
        v.passedKey = { [weak r] in r?.passed.append($0) }
        v.marks.windowShown = { _ in true }
        v.marks.windowKey = { _ in true }
        v.marks.buttons = { 0 }
        v.marks.cardShown = { [weak r] _ in r?.cards.shown != nil }
        v.marks.after = { [weak r] d, item in r?.items.append((d, item)) }
        t.attach(remote)
        t.gridChanged(cols: 80, rows: 24)
        t.gridChanged(cols: 80, rows: 24, generation: t.generation)
        XCTAssertEqual(t.phase, .live)
        return r
    }

    /// `rig` with the remote follow's snapshot in and a hover panel on "example-host:api" wired to the fake presenter:
    /// `linked`, the panel a grid click makes (XrayRefLink.panel: its run is the warm connection's); else one on the
    /// cold fake runner.
    func hoverRig(_ fake: XrayFollowTests.Fake, linked: Bool = false) throws -> Rig {
        let r = rig()
        let f = try XCTUnwrap(XrayFollows().attach(target, dch: "/fake/dch"))
        fake.send(fake.args.count, XrayGridMarksTests.snapshot())
        r.v.marks.follow = f
        XCTAssertEqual(r.v.marks.marks.map(\.key), ["issue:#12", "issue:#1"])
        let refs = try XCTUnwrap(f.state?.refs)
        let p = linked ? XrayRefLink.panel(UUID(), target, refs) : XrayPanelModel(target: target, tab: .refs)
        if !linked { (p.dch, p.run, p.panels) = ("/fake/dch", r.run.run, r.panels) }
        p.home = "/Users/example"
        p.presentRef = { [weak r] in r?.cards.present($0, $1, $2) }
        p.dismiss = { [weak r] in r?.cards.close() }
        r.panel = p
        r.v.marks.hover.panel = { [weak r] in
            guard let r, let p = r.panel, let refs = r.v.marks.refs else { return nil }
            return (p, refs)
        }
        return r
    }

    /// The remote terminal in a window that is never ordered in, with a window model (viewDidMoveToWindow: the focused
    /// pane takes its follow).
    func windowed(_ r: Rig) -> (AgentsNSWindow, AgentWindowModel) {
        let w = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        w.model = m
        w.contentView?.addSubview(r.v)
        return (w, m)
    }

    func until(_ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// Red with the `remoteHost == nil` guards back (followFocus attaches no follow; shown() draws none), or a follow
    /// keyed by the bare name (the host's session would be read as a local one).
    func testRemoteMarksFromAFakeFollow() async throws {
        try await withSeams { fake in
            let r = rig()
            let (w, m) = windowed(r)
            try withExtendedLifetime(m) {
                XCTAssertEqual(fake.args.last.map { Array($0.prefix(3)) }, ["--xray", "example-host:api", "--follow"])
                fake.send(fake.args.count, XrayGridMarksTests.snapshot())
                XCTAssertEqual(r.v.marks.marks.map(\.key), ["issue:#12", "issue:#1"])
                let refs = try XCTUnwrap(XrayRefLink.terminalRefs(w, remote))
                XCTAssertEqual(refs.target, target)
                XCTAssertTrue(XrayRefLink.terminalRefs(w, AgentSessionKey(dir: "/Users/example/dch", name: "api")) == nil,
                              "a local session of the same name is another session")
                r.t.attach(nil)
                XCTAssertTrue(r.v.marks.marks.isEmpty)
            }
        }
    }

    /// Red if a host or name dch would read as a flag gets a target, or a remote one is not "host:name" with no dir.
    func testTargetIsHostColonName() {
        XCTAssertEqual(XrayRefLink.target(remote), target)
        XCTAssertEqual(XrayRefLink.target(AgentSessionKey(dir: "/Users/example/dch", name: "api")),
                       XrayTarget(name: "api", dir: "/Users/example/dch"))
        for k in [AgentSessionKey(dir: "@-oProxyCommand", name: "api"), AgentSessionKey(dir: "@", name: "api"),
                  AgentSessionKey(dir: "@example-host", name: "-x"), AgentSessionKey(dir: "@example-host", name: "")] {
            XCTAssertTrue(XrayRefLink.target(k) == nil, "\(k)")
        }
    }

    /// Red if a remote hover spawns (the light read: K4.1 says none), or its card lacks the window's cached answer or the
    /// "Pin for passages" note; a ref with nothing cached shows the note alone, still with no spawn.
    func testRemoteHoverSpawnsNothingAndShowsTheCachedCard() async throws {
        try await withSeams { fake in
            let r = try hoverRig(fake)
            let p = try XCTUnwrap(r.panel)
            let cache = XrayRefResults()
            cache.put(.init(target: target, ref: "#12", light: false, scope: "project"), Data(XrayHoverTests.stream.utf8))
            p.refResults = { cache }
            r.v.marks.hover.point("issue:#12")
            r.item(0.5)?.perform()
            XCTAssertTrue(r.cards.shown != nil, "the card")
            XCTAssertEqual(r.v.marks.hover.card?.key, "issue:#12")
            XCTAssertEqual(p.refContext?.definitions.isEmpty, false, "the cached answer")
            XCTAssertEqual(p.refNote, XrayPanelModel.pinForPassages)
            r.v.marks.hover.point("issue:#1")   // a switch: nothing cached for #1
            r.item(0.15)?.perform()
            XCTAssertEqual(r.v.marks.hover.card?.key, "issue:#1")
            XCTAssertTrue(p.refContext == nil)
            XCTAssertEqual(p.refNote, XrayPanelModel.pinForPassages)
            XCTAssertTrue(r.v.marks.hover.read == nil)
            XCTAssertEqual(r.run.calls.count, 0, "a remote hover runs nothing")
        }
    }

    /// Red if Pin on a remote hover card runs anything but one full --ref read, or that read goes cold while the warm
    /// host:name connection answers (XrayRefLink.panel's run).
    func testPinGivesOneFullReadOverTheWarmConnection() async throws {
        let panels = XrayPanels.shared
        let spawns = XrayRequestsTests.Spawns { XrayRequestsTests.Child(reply: XrayRequestsTests.echo) }
        let (old, oldRun, cold) = (panels.requests.spawn, XrayPanels.run, XrayRefRunTests.Run())
        defer { (panels.requests.spawn, XrayPanels.run) = (old, oldRun); panels.requests.windowClosed() }
        (panels.requests.spawn, XrayPanels.run) = (spawns.spawn, cold.run)   // the cold path is a recorder too
        try await withSeams { fake in
            let r = try hoverRig(fake, linked: true)
            r.v.marks.hover.point("issue:#12")
            r.item(0.5)?.perform()
            XCTAssertTrue(r.cards.shown != nil)
            XCTAssertEqual(spawns.calls.count, 0, "the hover ran nothing")
            r.v.marks.hover.pin()
            await until { spawns.children.last?.writes.isEmpty == false }
            await panels.refReading?.value
            XCTAssertEqual(spawns.calls, [["--xray", "example-host:api", "--requests", "--json"]])
            XCTAssertEqual(spawns.children.last?.writes.count, 1, "one read")
            XCTAssertEqual(spawns.children.last?.writes.last?["argv"] as? [String],
                           ["--ref", "#12", "--scope", "project", "--full", "--json"])
            XCTAssertTrue(r.cards.shown != nil, "the pinned card")
            XCTAssertEqual(cold.calls.count, 0, "never cold while the connection answers")
        }
    }

    /// Red with refClick's or terminalRefs' remote refusal back: a Cmd-click on a remote row's underlined ref opens no card.
    func testRemoteCmdClickOpensTheCard() async throws {
        try await withSeams { fake in
            let r = rig()
            let (w, m) = windowed(r)
            withExtendedLifetime((w, m)) {
                fake.send(fake.args.count, XrayGridMarksTests.snapshot())
                let pane = m.layout.focused
                let panel = XrayPanelModel(target: target, tab: .refs)
                XrayPanels.shared.open[pane] = panel
                defer { XrayPanels.shared.open[pane] = nil; r.t.attach(nil) }
                let s = w.backingScaleFactor, cw = 16 / s, ch = 34 / s
                XCTAssertTrue(r.v.refClick(at: CGPoint(x: 4 + cw * 4 + 1, y: 2 + ch + 1)))   // row 1, column 4: "#12"
                XCTAssertEqual(panel.refCard?.key, "issue:#12")
            }
        }
    }

    /// Red if a remote card's other-session group lacks its host, the card's own session or a local card's gains one,
    /// or the host skips OutsideText.shown.
    func testHostLabelOnGroups() throws {
        let c = XrayRefContext(XrayRefStream.parse(Data(XrayHoverTests.stream.utf8)), ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(c.groups.map(\.session), ["api", "api-qa"])
        XCTAssertEqual(c.groups.map { XrayRefPopover.groupTitle($0.session, own: c.session, target: target) },
                       ["api", "example-host:api-qa"])
        let local = XrayTarget(name: "api", dir: "/Users/example/dch")
        XCTAssertEqual(XrayRefPopover.groupTitle("api-qa", own: "api", target: local), "api-qa")
        let odd = XrayTarget(name: "example\u{202E}-host:api", dir: nil)
        XCTAssertEqual(XrayRefPopover.groupTitle("api-qa", own: "api", target: odd), "example-host:api-qa")
    }

    /// Red if a remote exit 6 (the host's dch has no X-ray, README v1.99.0:1267-1269) reads "The ref read failed", or a
    /// local exit 6 or a remote 4 / 7 changes its note.
    func testExit6Label() async {
        let cases: [(XrayTarget, Int32, String)] = [
            (target, 6, XrayPanelModel.refNoXray), (XrayTarget(name: "api", dir: "/Users/example/dch"), 6, XrayPanelModel.refFailed),
            (target, 4, "host unreachable"), (target, 7, "host unreachable"),
        ]
        for (t, status, note) in cases {
            let run = XrayRefRunTests.Run(), panels = XrayPanels(), p = XrayPanelModel(target: t, tab: .search)
            (p.dch, p.run) = ("/fake/dch", run.run)
            run.answer = (status, Data())
            panels.runRef("#12", for: p)
            await panels.refReading?.value
            XCTAssertEqual(p.refNote, note, "\(t.name) exit \(status)")
        }
    }

    static func esc(_ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                       isARepeat: false, keyCode: 53))
    }

    /// Red if Esc in the terminal leaves a card up (the keyDown wiring gone), or goes on to the pty while it closed one,
    /// or an Esc with no card up (or a modified one) no longer reaches the pty.
    func testEscClosesACardElseReachesThePty() async throws {
        try await withSeams { fake in
            let r = try hoverRig(fake)
            r.v.keyDown(with: try Self.esc())
            XCTAssertEqual(r.passed.count, 1, "no card: the pty's")
            r.v.marks.hover.point("issue:#12")
            r.item(0.5)?.perform()
            XCTAssertTrue(r.cards.shown != nil)
            r.v.keyDown(with: try Self.esc(.shift))
            XCTAssertTrue(r.cards.shown != nil, "Shift-Esc is the program's")
            XCTAssertEqual(r.passed.count, 2)
            r.v.keyDown(with: try Self.esc())
            XCTAssertTrue(r.cards.shown == nil, "Esc closed the card")
            XCTAssertTrue(r.v.marks.hover.card == nil)
            XCTAssertEqual(r.passed.count, 2, "the closing Esc never reaches the pty")
            r.v.marks.hover.point(nil)
            r.v.marks.hover.point("issue:#12")
            r.item(0.5)?.perform()
            r.v.marks.hover.pin()
            XCTAssertTrue(r.cards.shown != nil, "pinned")
            r.v.keyDown(with: try Self.esc())
            XCTAssertTrue(r.cards.shown == nil, "Esc closes a pinned card too")
            XCTAssertEqual(r.passed.count, 2)
            r.v.keyDown(with: try Self.esc())
            XCTAssertEqual(r.passed.count, 3, "no card again: the pty's")
            await r.panels.refReading?.value
        }
    }
}
