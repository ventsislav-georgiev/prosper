import AppKit
import GhosttyTerminal
import XCTest
@testable import ProsperApp

/// #1559 (X-T a): ref marks on the Terminal grid. A fake follow (XrayFollowTests.Fake through the XrayPanels.follow seam)
/// hands in dch's lines, the viewport text is the rows' own, the settle item is kept and performed by hand, and the window
/// is never ordered in (its visibility is the overlay's windowShown seam). No dch, no pty, no event posted, no card shown.
@MainActor
final class XrayGridMarksTests: XCTestCase {
    typealias F = XrayRefLinkFixture
    let local = AgentSessionKey(dir: "/Users/example/dch", name: "api")
    let shell = AgentSessionKey(dir: "/Users/example/dch", name: "shell")
    let grid = TerminalGridMetrics(columns: 80, rows: 24, widthPixels: 1280, heightPixels: 816, cellWidthPixels: 16, cellHeightPixels: 34)
    static let viewport = "$ git log\nfix #12 now, API-7 too\nsee #1\n"

    static func snapshot(_ refs: String = F.refs) -> String {
        XrayFollowTests.snapshot(String(decoding: XrayRefsParseTests.object(refs: refs), as: UTF8.self))
    }

    static func refDelta(_ key: String, text: String, underline: Bool, count: Int = 2) -> String {
        #"{"schema":1,"ref":{"key":"\#(key)","shape":"issue","text":"\#(text)","count":\#(count),"underline":\#(underline)}}"#
    }

    /// The seams set for the body and put back after it (follow, its gate, the dch path, gate B).
    func withSeams(_ body: (XrayFollowTests.Fake) throws -> Void) rethrows {
        let (ok, follow, dch, decorate) = (XrayPanels.followOK, XrayPanels.follow, XrayPanels.dch, XrayRefLink.decorate)
        defer {
            (XrayPanels.followOK, XrayPanels.follow, XrayPanels.dch, XrayRefLink.decorate) = (ok, follow, dch, decorate)
            // the shared LRU keeps no follow of these rows' (a later row's attach would find it running on this fake)
            for f in XrayPanels.shared.follows.follows where f.target.dir == local.dir { XrayPanels.shared.follows.drop(f) }
        }
        let fake = XrayFollowTests.Fake()
        XrayPanels.followOK = { true }
        XrayPanels.follow = fake.follow
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 99, 0])
        XrayRefLink.decorate = { true }
        try body(fake)
    }

    final class Rig {
        let t: AgentTerminalController
        let v: AgentTerminalHostView
        var child: AgentTerminalTests.FakeChild?
        var io: AgentTerminalIO?
        var items: [DispatchWorkItem] = []
        init(t: AgentTerminalController, v: AgentTerminalHostView) { (self.t, self.v) = (t, v) }
    }

    /// A live local terminal with its host view (not in a window unless the row puts it in one), the settle kept.
    func rig(_ key: AgentSessionKey, viewport: String = XrayGridMarksTests.viewport) -> Rig {
        let t = AgentTerminalController()
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        let r = Rig(t: t, v: v)
        t.spawn = { [weak r] _, io in let c = AgentTerminalTests.FakeChild(); r?.child = c; r?.io = io; return c }
        t.makeScreen = { AgentTerminalTests.FakeScreen($0) }
        v.owner = t
        t.view = v
        v.gridMetrics = grid
        v.viewportText = { viewport }
        v.marks.windowShown = { _ in true }
        v.marks.after = { [weak r] _, item in r?.items.append(item) }
        v.marks.hop = XrayGridMarksTests.inline   // #1655: the compute and its apply at once, on main
        t.attach(key)
        t.gridChanged(cols: 80, rows: 24)
        t.gridChanged(cols: 80, rows: 24, generation: t.generation)
        XCTAssertEqual(t.phase, .live)
        return r
    }

    /// A follow of `target` with the snapshot in (a fresh XrayFollows; the fake's start n).
    func follow(_ fake: XrayFollowTests.Fake, _ n: Int, _ target: XrayTarget, refs: String = F.refs) throws -> XrayFollow {
        let f = try XCTUnwrap(XrayFollows().attach(target, dch: "/fake/dch"))
        fake.send(n, Self.snapshot(refs))
        return f
    }

    static func keys(_ v: AgentTerminalHostView) -> [String] { v.marks.marks.map(\.key) }

    /// Red if a ref dch did not underline, or a url or file ref (libghostty's own link), gets a mark, or a mark's row,
    /// column or width is off.
    func testMarksOnlyForUnderlinedKeys() throws {
        var refs = try F.parsed().entries
        let lines = Self.viewport.components(separatedBy: "\n")
        XCTAssertEqual(XrayGridMarksView.marks(lines, refs, rows: 24),
                       [.init(row: 1, col: 4, cells: 3, key: "issue:#12"), .init(row: 2, col: 4, cells: 2, key: "issue:#1")])
        XCTAssertFalse(XrayGridMarksView.marks(lines, refs, rows: 24).contains { $0.key == "ticket:API-7" }, "underline:false")
        refs[0].shape = .url
        refs[2].shape = .file
        XCTAssertTrue(XrayGridMarksView.marks(lines, refs, rows: 24).isEmpty, "url and file refs are libghostty's links")
        XCTAssertTrue(XrayGridMarksView.marks(lines, try F.parsed().entries, rows: 2).map(\.row) == [1], "rows past the grid")
        XCTAssertTrue(XrayGridMarksView.marks(lines, try F.parsed().entries, rows: 0).isEmpty)
    }

    /// Red if a `ref` delta that turns underline off, or a count 0 that removes the ref, leaves its mark drawn, or one
    /// that turns it on draws none until output.
    func testADeltaTurningUnderlineOffRemovesTheMark() throws {
        try withSeams { fake in
            let r = rig(local)
            let f = try follow(fake, 1, XrayTarget(name: "api", dir: local.dir))
            r.v.marks.follow = f
            XCTAssertEqual(Self.keys(r.v), ["issue:#12", "issue:#1"])
            fake.send(1, Self.refDelta("issue:#12", text: "#12", underline: false))
            XCTAssertEqual(Self.keys(r.v), ["issue:#1"])
            fake.send(1, Self.refDelta("issue:#12", text: "#12", underline: true))
            XCTAssertEqual(Self.keys(r.v), ["issue:#12", "issue:#1"])
            fake.send(1, Self.refDelta("issue:#1", text: "#1", underline: true, count: 0))
            XCTAssertEqual(Self.keys(r.v), ["issue:#12"])
        }
    }

    /// Red if output that moved the text (a scroll) leaves the marks drawn, uses a timer (more than one live item, or the
    /// old one not cancelled), or the settle places them more than once or not at all. Output comes through the
    /// controller's real drain path.
    func testOutputClearsAndTheSettlePlacesOnce() throws {
        try withSeams { fake in
            let r = rig(local)
            r.v.marks.follow = try follow(fake, 1, XrayTarget(name: "api", dir: local.dir))
            XCTAssertEqual(Self.keys(r.v).count, 2)
            r.v.viewportText = { "fix #12 now, API-7 too\nsee #1\n" }   // #1628: scrolled up one line
            let io = try XCTUnwrap(r.io)
            io.output(Array("x".utf8))
            let drained = expectation(description: "drain")
            DispatchQueue.main.async { drained.fulfill() }   // after the drain: main is FIFO
            wait(for: [drained], timeout: 2)
            XCTAssertTrue(r.v.marks.marks.isEmpty, "output clears at once")
            XCTAssertEqual(r.items.count, 1)
            r.v.marks.output()
            XCTAssertEqual(r.items.count, 2)
            XCTAssertTrue(r.items.first?.isCancelled == true, "re-armed: the older item is cancelled")
            XCTAssertTrue(r.items.last?.isCancelled == false)
            // a delta while settling places nothing yet
            fake.send(1, Self.refDelta("issue:#12", text: "#12", underline: true))
            XCTAssertTrue(r.v.marks.marks.isEmpty)
            r.items.last?.perform()
            XCTAssertEqual(Self.keys(r.v), ["issue:#12", "issue:#1"])
            XCTAssertEqual(r.v.marks.marks.map(\.row), [0, 1], "placed on the scrolled rows")
            XCTAssertTrue(r.v.marks.settle == nil)
            XCTAssertEqual(r.items.count, 2, "the settle arms nothing after it")
        }
    }

    /// Red if an unfocused pane, a hidden window, a hidden pane, a remote row or gate B off draws marks.
    func testUnfocusedOrHiddenPaneDrawsNone() throws {
        try withSeams { fake in
            let r = rig(local)
            r.v.marks.follow = try follow(fake, 1, XrayTarget(name: "api", dir: local.dir))
            XCTAssertEqual(Self.keys(r.v).count, 2)
            r.t.paneFocused = { false }
            r.v.marks.place()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "unfocused")
            r.t.paneFocused = { true }
            r.v.marks.windowShown = { _ in false }
            r.v.marks.place()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "window hidden")
            r.v.marks.windowShown = { _ in true }
            r.v.isHidden = true
            r.v.marks.place()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "pane hidden")
            r.v.isHidden = false
            XrayRefLink.decorate = { false }
            r.v.marks.place()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "gate B off")
            XrayRefLink.decorate = { true }
            r.v.marks.place()
            XCTAssertEqual(Self.keys(r.v).count, 2, "back")
            let far = rig(AgentSessionKey(dir: "@example-host", name: "api"))
            far.v.marks.follow = r.v.marks.follow
            far.v.marks.place()
            XCTAssertEqual(Self.keys(far.v).count, 2, "#1568: a remote row marks too")
        }
    }

    /// Red if placing, clearing or a follow's lines write anything to the pty.
    func testNoBytesReachThePty() throws {
        try withSeams { fake in
            let r = rig(local)
            r.v.marks.follow = try follow(fake, 1, XrayTarget(name: "api", dir: local.dir))
            r.v.marks.output()
            r.items.last?.perform()
            fake.send(1, Self.refDelta("issue:#12", text: "#12", underline: false))
            r.t.writer.flush()
            XCTAssertEqual(r.child?.written.count, 0)
            XCTAssertEqual(r.child?.resizes.count, 0)
        }
    }

    /// Red if the overlay sizes the terminal: its frame, its grid, the pty's size, or the overlay not covering the view.
    func testFrameAndGridUnchangedWithTheOverlayOn() throws {
        try withSeams { fake in
            let r = rig(local)
            let (frame, metrics, sent) = (r.v.frame, r.v.gridMetrics, r.t.sentSize.map { [$0.cols, $0.rows] })
            r.v.marks.follow = try follow(fake, 1, XrayTarget(name: "api", dir: local.dir))
            XCTAssertEqual(Self.keys(r.v).count, 2)
            XCTAssertEqual(r.v.frame, frame)
            XCTAssertEqual(r.v.gridMetrics, metrics)
            XCTAssertTrue(r.t.sentSize.map { [$0.cols, $0.rows] } == sent)
            XCTAssertTrue(r.v.marks.superview === r.v)
            XCTAssertEqual(r.v.marks.frame, r.v.bounds)
            XCTAssertEqual(r.v.marks.autoresizingMask, [.width, .height], "it follows the view, never the reverse")
        }
    }

    /// Red if the overlay takes a click: its hitTest is nil and the terminal's own is the terminal.
    func testTheOverlaysHitTestIsNil() {
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        XCTAssertTrue(v.marks.hitTest(NSPoint(x: 10, y: 10)) == nil)
        XCTAssertTrue(v.hitTest(NSPoint(x: 10, y: 10)) === v)
        XCTAssertFalse(v.marks.isAccessibilityElement())
    }

    /// Red if pane focus does not attach the target's follow once, or blur (nil, another target) does not detach it.
    func testPaneFocusAttachesAndBlurDetaches() throws {
        try withSeams { fake in
            let follows = XrayFollows(), w = ObjectIdentifier(self)
            let a = try XCTUnwrap(follows.focus(XrayTarget(name: "api", dir: local.dir), window: w, dch: "/fake/dch"))
            XCTAssertEqual(a.users, 1)
            XCTAssertTrue(follows.focus(XrayTarget(name: "api", dir: local.dir), window: w, dch: "/fake/dch") === a)
            XCTAssertTrue(a.users == 1 && fake.args.count == 1, "the same focus again: no second attach")
            let b = try XCTUnwrap(follows.focus(XrayTarget(name: "shell", dir: shell.dir), window: w, dch: "/fake/dch"))
            XCTAssertTrue(a.users == 0 && b.users == 1)
            XCTAssertTrue(follows.focused(in: w) === b)
            XCTAssertTrue(follows.focus(nil, window: w, dch: nil) == nil)
            XCTAssertEqual(b.users, 0)
            XCTAssertTrue(follows.focused(in: w) == nil)
            // a held follow that ended and left the LRU is not handed out again: the focus starts a new one
            let c = try XCTUnwrap(follows.focus(XrayTarget(name: "api", dir: local.dir), window: w, dch: "/fake/dch"))
            follows.drop(c)
            let d = try XCTUnwrap(follows.focus(XrayTarget(name: "api", dir: local.dir), window: w, dch: "/fake/dch"))
            XCTAssertFalse(c === d)
            XCTAssertTrue(follows.follows.contains { $0 === d })
        }
    }

    /// The shell pane in a window that is never ordered in, with a window model (its focused pane is the click's).
    func windowed(_ r: Rig) -> (AgentsNSWindow, AgentWindowModel) {
        let w = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        w.model = m
        w.contentView?.addSubview(r.v)   // viewDidMoveToWindow: the focused pane takes its follow
        return (w, m)
    }

    /// Red if a shell pane (no transcript) gets no follow, no marks or no refs for a Cmd-click: the #1357 path read them
    /// only for a session whose transcript the pane had.
    func testAShellTargetGetsMarks() throws {
        try withSeams { fake in
            let r = rig(shell)
            let (w, m) = windowed(r)
            try withExtendedLifetime(m) {
                XCTAssertEqual(fake.args.last.map { Array($0.prefix(3)) }, ["--xray", "shell", "--follow"])
                fake.send(fake.args.count, Self.snapshot())
                XCTAssertEqual(Self.keys(r.v), ["issue:#12", "issue:#1"])
                let refs = try XCTUnwrap(XrayRefLink.terminalRefs(w, shell))
                XCTAssertEqual(refs.target, XrayTarget(name: "shell", dir: shell.dir))
                XCTAssertTrue(XrayRefLink.terminalRefs(w, local) == nil, "another session")
                r.t.attach(nil)   // the window hides: the focused pane's attach(nil) lets the follow go
                XCTAssertTrue(XrayPanels.shared.follows.focused(in: ObjectIdentifier(w)) == nil)
                XCTAssertTrue(r.v.marks.marks.isEmpty)
            }
        }
    }

    /// Red if a Cmd-click on a shell pane's underlined ref does not open its card (the pane's open panel shows it).
    func testCmdClickOnAShellPaneOpensTheCard() throws {
        try withSeams { fake in
            let r = rig(shell)
            let (w, m) = windowed(r)
            withExtendedLifetime((w, m)) {
                fake.send(fake.args.count, Self.snapshot())
                let pane = m.layout.focused
                let panel = XrayPanelModel(target: XrayTarget(name: "shell", dir: shell.dir), tab: .refs)
                XrayPanels.shared.open[pane] = panel
                defer { XrayPanels.shared.open[pane] = nil; r.t.attach(nil) }
                // a cell in points at the window's own backing scale (it is never on a screen: 1x or 2x)
                let s = w.backingScaleFactor, cw = 16 / s, ch = 34 / s
                // row 1, column 4: "#12" (the default openRef: XrayRefLink.openOnGrid)
                XCTAssertTrue(r.v.refClick(at: CGPoint(x: 4 + cw * 4 + 1, y: 2 + ch + 1)))
                XCTAssertEqual(panel.refCard?.key, "issue:#12")
                XCTAssertFalse(r.v.refClick(at: CGPoint(x: 4 + cw * 14 + 1, y: 2 + ch + 1)), "API-7 is underline:false")
            }
        }
    }

    /// #1917 (operator 2026-11-24 on v2.176.0: "cmd + click seems to have stopped working"): the path end to end, through
    /// the window model, the product's mount (AgentTerminalRepresentable.mount), the real follow wiring and a built
    /// Command-down handed to the view (never posted). The focused pane's terminal switches to a session it had not kept,
    /// so #1782's keepShown makes a fresh host view. Red at the parent: updateNSView ran `slot.hold(v)` before
    /// `v.owner = controller`, so the fresh view's viewDidMoveToWindow asked no controller for the follow: no `--xray api
    /// --follow`, no marks, the window's follow still the old session's, and the Command-click opened no card. Single
    /// pane and a layout (another live pane, unfocused, in the same window: it never takes the follow).
    func testCmdClickOpensTheCardAfterTheFocusedPaneSwitchesSession() throws {
        for layout in [false, true] {
            try withSeams { fake in
                let w = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled],
                                       backing: .buffered, defer: true)
                w.isReleasedWhenClosed = false
                let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
                w.model = m
                let slot = AgentTerminalHostSlot(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
                let t = AgentTerminalController()
                t.spawn = { _, _ in AgentTerminalTests.FakeChild() }
                t.makeScreen = { AgentTerminalTests.FakeScreen($0) }
                t.paneFocused = { true }
                var items: [DispatchWorkItem] = []
                let other = layout ? rig(AgentSessionKey(dir: local.dir, name: "api-qa")) : nil
                other?.t.paneFocused = { false }
                if let o = other { w.contentView?.addSubview(o.v) }   // unfocused: takes nothing
                let pane = m.layout.focused
                defer {
                    XrayPanels.shared.open[pane] = nil
                    t.attach(nil)
                    other?.t.attach(nil)
                    slot.removeFromSuperview()
                    other?.v.removeFromSuperview()
                }
                /// What the pane draws for `key`: the seams on the controller's view, then the product's mount, live.
                @MainActor func show(_ key: AgentSessionKey) -> AgentTerminalHostView {
                    t.attach(key)
                    let v = t.hostView()
                    v.gridMetrics = grid
                    let text = Self.viewport
                    v.viewportText = { text }
                    v.marks.windowShown = { _ in true }
                    v.marks.after = { _, item in items.append(item) }
                    v.marks.hop = XrayGridMarksTests.inline
                    v.passedClick = { _ in }
                    XCTAssertTrue(AgentTerminalRepresentable.mount(t, in: slot) === v)
                    t.gridChanged(cols: 80, rows: 24)
                    t.gridChanged(cols: 80, rows: 24, generation: t.generation)
                    XCTAssertEqual(t.phase, .live)
                    return v
                }
                /// A Command-down and up on row 1, column 4 ("#12"): true when it pinned the card in the pane's panel.
                @MainActor func cmdClick(_ v: AgentTerminalHostView, _ key: AgentSessionKey) throws -> Bool {
                    let panel = XrayPanelModel(target: XrayTarget(name: key.name, dir: key.dir), tab: .refs)
                    XrayPanels.shared.open[pane] = panel
                    let s = w.backingScaleFactor, at = NSPoint(x: 4 + 16 / s * 4 + 1, y: 410 - (2 + 34 / s + 1))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: at, modifierFlags: .command, timestamp: 0,
                                                                 windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                        if type == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
                    }
                    return panel.refCard?.key == "issue:#12"
                }
                let va = show(shell)
                w.contentView?.addSubview(slot)   // as makeNSView's slot: mounted first, then in the window (worked at the parent)
                fake.send(fake.args.count, Self.snapshot())
                XCTAssertEqual(Self.keys(va), ["issue:#12", "issue:#1"], "layout \(layout)")
                XCTAssertTrue(try cmdClick(va, shell), "layout \(layout): the first session's card")
                let vb = show(local)
                XCTAssertFalse(va === vb, "a fresh view (#1782): the shell session is kept")
                XCTAssertTrue(va.window == nil && va.marks.follow == nil)
                XCTAssertEqual(fake.args.last.map { Array($0.prefix(3)) }, ["--xray", "api", "--follow"],
                               "layout \(layout): the new session's follow started on its view's mount")
                fake.send(fake.args.count, Self.snapshot())
                for i in items where !i.isCancelled { i.perform() }
                XCTAssertTrue(vb.marks.follow != nil, "layout \(layout)")
                XCTAssertEqual(Self.keys(vb), ["issue:#12", "issue:#1"], "layout \(layout): underlined")
                XCTAssertTrue(XrayRefLink.terminalRefs(w, local) != nil, "layout \(layout): the window's follow is api's")
                XCTAssertTrue(try cmdClick(vb, local), "layout \(layout): Command-click opens the card")
                XCTAssertFalse(vb.pinnedDown, "its up ended the pin")
                if let o = other {
                    XCTAssertTrue(o.v.marks.follow == nil && o.v.marks.marks.isEmpty, "the unfocused pane takes no follow")
                }
            }
        }
    }

    /// #1900 (the cause): the hover card's panel on a pane with no X-ray panel open is a new one; it had the follow's refs
    /// but no chapters or anchors, so this session's mention (anchor f3a41c:0, the snapshot's chapter 1) opened nothing
    /// and its arrow did nothing. Red on the old XrayRefLink.panel (it set dch, run and refs only).
    func testHoverPanelTakesTheFollowsChaptersSoAMentionOpensIt() throws {
        try withSeams { fake in
            let r = rig(shell)
            let (w, m) = windowed(r)
            try withExtendedLifetime((w, m)) {
                defer { r.t.attach(nil) }
                fake.send(fake.args.count, Self.snapshot())
                XCTAssertTrue(XrayPanels.shared.open[m.layout.focused] == nil, "no X-ray panel open on the pane")
                let p = try XCTUnwrap(XrayRefLink.hoverPanel(w, key: shell)).panel
                XCTAssertEqual(p.chapterAnchors, ["f3a41c:0": 1])
                XCTAssertEqual(p.chapters.map(\.ordinal), [1])
                var shown = 0
                // no --chapter read, no real card window; #1944: the arrow opens it from the ref card: a push
                (p.run, p.presentRef, p.pushRef) = (nil, { _, _, _ in XCTFail("a push, not a replace") }, { _, _, _ in shown += 1 })
                let first = XrayRefStreamTests.first.replacingOccurrences(of: #""session":"api""#, with: #""session":"shell""#)
                let lines = [first, XrayRefContextTests.mention("shell", at: 40, offset: 0, chapter: "f3a41c:0"), XrayRefStreamTests.done]
                let c = XrayRefContext(XrayRefStreamTests.parse(lines), ref: "#12", tasks: nil, memory: nil)
                let mine = try XCTUnwrap(c.groups.first?.mentions.first)
                XCTAssertEqual(c.session, "shell")
                XCTAssertTrue(p.jumpRef(mine, in: c))
                XCTAssertEqual(p.chapterCard?.ordinal, 1)
                XCTAssertEqual(shown, 1, "the chapter card is presented")
            }
        }
    }

    /// Red if another pane's focus in the same window leaves the old pane's marks drawn (blur), or an unfocused pane's
    /// attach takes the window's follow.
    func testAnotherPaneFocusClearsTheOldPanesMarks() throws {
        try withSeams { fake in
            let a = rig(local), b = rig(shell)
            var focused = "a"
            a.t.paneFocused = { focused == "a" }
            b.t.paneFocused = { focused == "b" }
            let (w, m) = windowed(a)
            withExtendedLifetime((w, m)) {
                w.contentView?.addSubview(b.v)   // unfocused: takes nothing
                XCTAssertEqual(fake.args.count, 1)
                fake.send(1, Self.snapshot())
                XCTAssertEqual(Self.keys(a.v).count, 2)
                focused = "b"
                b.t.attach(shell)   // follow() asks the newly focused pane's terminal
                XCTAssertTrue(a.v.marks.follow == nil)
                XCTAssertTrue(a.v.marks.marks.isEmpty, "blurred")
                XCTAssertEqual(fake.args.last.map { Array($0.prefix(3)) }, ["--xray", "shell", "--follow"])
                b.t.attach(nil)
            }
        }
    }

    /// #1628: red if output that leaves the marked text as it was (a spinner or status line redrawn on another row, or a
    /// chunk that rewrites the same text) takes any mark off, even for a moment. Through the real drain path each time.
    func testUnchangedMarkedTextKeepsTheMarksThroughOutput() throws {
        try withSeams { fake in
            let r = rig(local)
            r.v.marks.follow = try follow(fake, 1, XrayTarget(name: "api", dir: local.dir))
            let placed = r.v.marks.marks
            XCTAssertEqual(placed.count, 2)
            var spinner = ""
            let base = Self.viewport
            r.v.viewportText = { base + spinner }   // the last row only
            let io = try XCTUnwrap(r.io)
            for frame in ["\u{280B} Working", "\u{2819} Working", "\u{2839} Working", "", "\u{2838} Working (esc to interrupt)"] {
                spinner = frame
                io.output(Array("x".utf8))
                let drained = expectation(description: "drain")
                DispatchQueue.main.async { drained.fulfill() }   // after the drain: main is FIFO
                wait(for: [drained], timeout: 2)
                XCTAssertEqual(r.v.marks.marks, placed, "frame \(frame): the marks never go")
            }
            r.v.marks.output()   // the same text rewritten
            XCTAssertEqual(r.v.marks.marks, placed)
            XCTAssertTrue(r.items.last?.isCancelled == false, "the settle is still armed")
            r.items.last?.perform()
            XCTAssertEqual(r.v.marks.marks, placed, "and stays after the settle")
        }
    }

    /// #1628: red if output that changes one mark's text leaves that mark drawn, or takes the untouched one off with it.
    func testChangedMarkedTextTakesThatMarkOff() throws {
        try withSeams { fake in
            let r = rig(local)
            r.v.marks.follow = try follow(fake, 1, XrayTarget(name: "api", dir: local.dir))
            XCTAssertEqual(Self.keys(r.v), ["issue:#12", "issue:#1"])
            r.v.viewportText = { "$ git log\nfix #19 now, API-7 too\nsee #1\n" }
            r.v.marks.output()
            XCTAssertEqual(Self.keys(r.v), ["issue:#1"], "#12 rewritten: its mark goes now")
            r.v.viewportText = { "$ git log\nfix #19 now, API-7 too\nsee  #1\n" }
            r.v.marks.output()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "#1 moved a cell: its mark goes too")
            r.items.last?.perform()
            XCTAssertEqual(r.v.marks.marks, [.init(row: 2, col: 5, cells: 2, key: "issue:#1")], "the settle places it again")
        }
    }

    /// #1628: red if a resize keeps the marks (new cells, the same text), if output on a pane that stopped showing keeps
    /// them, or if either is not placed again by the settle.
    func testResizeOrHiddenPaneStillClearsAndResettles() throws {
        try withSeams { fake in
            let r = rig(local)
            r.t.after = { _, _ in }   // the pty resize debounce is not this row's
            r.v.marks.follow = try follow(fake, 1, XrayTarget(name: "api", dir: local.dir))
            XCTAssertEqual(Self.keys(r.v).count, 2)
            r.v.terminalDidResize(grid)
            XCTAssertTrue(r.v.marks.marks.isEmpty, "a resize: all off")
            r.items.last?.perform()
            XCTAssertEqual(Self.keys(r.v).count, 2)
            r.v.marks.windowShown = { _ in false }
            r.v.marks.output()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "not shown: all off")
            r.v.marks.windowShown = { _ in true }
            r.items.last?.perform()
            XCTAssertEqual(Self.keys(r.v).count, 2)
        }
    }

    /// #1628: red if span() returns text across a wide character's edge, past the line, or not the cells asked for.
    func testSpanReadsCellsNotCharacters() {
        typealias M = XrayGridMarksView.Mark
        XCTAssertEqual(XrayGridMarksView.span("fix #12 now", M(row: 0, col: 4, cells: 3, key: "k")), "#12")
        XCTAssertEqual(XrayGridMarksView.span("\u{4E2D} #12", M(row: 0, col: 3, cells: 3, key: "k")), "#12", "a wide character is two cells")
        XCTAssertTrue(XrayGridMarksView.span("\u{4E2D} #12", M(row: 0, col: 1, cells: 2, key: "k")) == nil, "starts inside a wide character")
        XCTAssertTrue(XrayGridMarksView.span("see #1", M(row: 0, col: 4, cells: 3, key: "k")) == nil, "past the line")
        XCTAssertEqual(XrayGridMarksView.span("see #1", M(row: 0, col: 4, cells: 2, key: "k")), "#1", "to the line's end")
    }
}
