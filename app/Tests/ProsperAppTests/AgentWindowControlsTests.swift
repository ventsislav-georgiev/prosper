import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #829 Phase 1: Restart agent, Stop and Kill from the window (asked on an inline strip, run by
/// the island's controller), the island's row and dir texts shown in the window, the input lock
/// while a Restart or Stop types, follow-to-History, and QA #660's notes on #828. Offscreen only:
/// no real dch (the window's seams are stubbed), no menu popped, no window shown, no event posted.
extension AgentWindowD1Tests {
    static let v1240 = DchCommand.Binary(path: "/fake/dch", version: [1, 24, 0])
    static let v1241 = DchCommand.Binary(path: "/fake/dch", version: [1, 24, 1])

    func ctlKey(_ name: String) -> AgentSessionKey { AgentSessionKey(dir: "/tmp/dch-test", name: name) }

    func ctlSession(_ name: String, _ state: AgentState = .idle, version: String) -> AgentSession {
        AgentSession(key: ctlKey(name), alias: "", activity: Self.now - 60, state: state, agents: 0, version: version)
    }

    /// A model whose Restart / Stop / Kill seams record and answer `started`.
    @MainActor
    final class Calls {
        var all: [(verb: AgentWindowVerb, session: AgentSession)] = []
        var started = true
        func wire(_ m: AgentWindowModel) {
            m.restartSession = { self.all.append((.restart, $0)); return self.started }
            m.stopSession = { self.all.append((.stop, $0)); return self.started }
            m.killSession = { self.all.append((.kill, $0)); return self.started }
        }
    }

    // MARK: Menu items: the island's gates and titles

    @MainActor
    func testAgentWindowMenuUsesTheIslandsGatesAndTitles() throws {
        let a = ctlSession("a", version: "1.24.0"), old = ctlSession("old", version: "1.23.0")
        let dash = ctlSession("-x", version: "1.24.0")
        let st = store([a, old, dash])
        st.controlDch = nil
        let why = try XCTUnwrap(st.resumeGate.refusal)
        XCTAssertEqual(AgentWindowControls.menu(a, store: st), [
            .item("Restart agent", enabled: false, verb: .restart), .item("Stop", enabled: false, verb: .stop), .divider,
            .item("Kill…", enabled: false, verb: .kill), .note("Controls \(why)"),
        ], "no control dch: all off, the island's footer says why")
        st.controlDch = Self.v1240
        XCTAssertEqual(AgentWindowControls.menu(a, store: st), [
            .item("Restart agent (needs dch 1.24.1)", enabled: false, verb: .restart),
            .item("Stop (needs dch 1.24.1)", enabled: false, verb: .stop), .divider,
            .item("Kill…", enabled: true, verb: .kill),
        ], "1.24.0: Restart and Stop name the version; Kill needs only the base gate")
        st.controlDch = Self.v1241
        XCTAssertEqual(AgentWindowControls.menu(a, store: st), [
            .item("Restart agent…", enabled: true, verb: .restart), .item("Stop…", enabled: true, verb: .stop), .divider,
            .item("Kill…", enabled: true, verb: .kill),
        ], "items that ask carry an ellipsis")
        XCTAssertEqual(AgentWindowControls.menu(old, store: st)[1], .item(AgentIsland.stopOldMasterLabel, enabled: false, verb: .stop),
                       "an old master's Stop says why")
        XCTAssertEqual(AgentWindowControls.menu(dash, store: st), [], "#627: a name dch reads as a flag gets no item")
        // The header's button is there either way, one size (it never moves the title line).
        func width(_ s: AgentSession, _ store: AgentIslandStore?) -> CGFloat {
            NSHostingView(rootView: AgentSessionMenuButton(store: store, session: s, ask: { _ in })).fittingSize.width
        }
        XCTAssertGreaterThan(width(a, st), 0)
        XCTAssertEqual(width(a, st), width(dash, st))
        XCTAssertEqual(width(a, st), width(a, nil))
    }

    // MARK: Ask, then act on the asked session only

    @MainActor
    func testAgentWindowAsksThenActsOnTheAskedSessionOnly() throws {
        let st = store([session("a", .working), session("b", .blocked)])
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        let a = try XCTUnwrap(st.sessions.first { $0.name == "a" }), b = try XCTUnwrap(st.sessions.first { $0.name == "b" })
        m.select(.live(b.key))
        m.ask(.restart, a)
        XCTAssertEqual(m.selection, .live(a.key), "R6: a context-menu ask selects its row first")
        XCTAssertEqual(m.confirming, AgentWindowConfirm(verb: .restart, key: a.key))
        XCTAssertTrue(calls.all.isEmpty, "asking runs nothing")
        m.confirm(false)
        XCTAssertNil(m.confirming)
        m.confirm(true)
        XCTAssertTrue(calls.all.isEmpty, "Cancel, then an answer with no question: nothing runs")
        m.ask(.restart, a)
        m.confirm(true)
        XCTAssertEqual(calls.all.map(\.verb), [.restart])
        XCTAssertEqual(calls.all.last?.session.key, a.key)
        // A selection change drops the question.
        m.ask(.stop, a)
        m.select(.live(b.key))
        XCTAssertNil(m.confirming, "another row picked: the strip goes")
        m.confirm(true)
        XCTAssertEqual(calls.all.count, 1)
        // The answer re-resolves the session: its current value is acted on, and a gone one is not.
        m.ask(.kill, a)
        st.sessions = [session("a", .idle), b]
        m.confirm(true)
        XCTAssertEqual(calls.all.last?.verb, .kill)
        XCTAssertEqual(calls.all.last?.session.state, .idle, "the session as it is now, not as asked")
        m.ask(.stop, a)
        m.setVisible(false)   // hidden: the sidebar does not rebuild, so only the answer can notice
        st.sessions = [b]
        m.confirm(true)
        XCTAssertEqual(calls.all.count, 2, "the asked session ended before the answer: nothing runs")
        m.setVisible(true)
        m.ask(.stop, b)
        st.sessions = []
        XCTAssertNil(m.confirming, "the asked session gone from the list drops the strip")
        // The copy.
        XCTAssertEqual(AgentWindowControls.question(.restart, a),
                       "Restart a? Claude Code is paused, then relaunched on the same conversation. This can take minutes.")
        XCTAssertEqual(AgentWindowControls.question(.stop, a),
                       "Stop a? Claude Code is paused and the session ends. Resume it later from History.")
        XCTAssertEqual(AgentWindowControls.question(.kill, a), AgentIsland.killQuestion("a"))
        XCTAssertTrue(AgentWindowControls.question(.restart, b).hasSuffix(AgentWindowControls.blockedSentence),
                      "blocked: answer the prompt first")
        XCTAssertTrue(AgentWindowControls.question(.stop, b).hasSuffix(AgentWindowControls.blockedSentence))
        XCTAssertEqual(AgentWindowControls.question(.kill, b), AgentIsland.killQuestion("b"), "Kill needs no prompt answered")
    }

    // MARK: Follow-to-History (G2)

    @MainActor
    func testAgentWindowFollowsAStoppedOrKilledSessionToItsHistoryRow() throws {
        let st = store([session("a", .idle), session("b", .idle)], history: [record("a", ago: 7200)])
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        let a = try XCTUnwrap(st.sessions.first { $0.name == "a" }), b = try XCTUnwrap(st.sessions.first { $0.name == "b" })
        var seen: [AgentSidebar.RowID?] = []
        m.ask(.stop, a)
        m.confirm(true)
        XCTAssertNotNil(m.following)
        let sub = m.$selection.dropFirst().sink { seen.append($0) }
        defer { sub.cancel() }
        st.sessions = [b]
        XCTAssertNil(m.selection, "the row went and only an older record of its name is there: nothing yet")
        st.history = [record("other", ago: 0), record("a", ago: 7200)]
        XCTAssertNil(m.selection, "another session's new record: not followed")
        XCTAssertNotNil(m.following)
        st.history = [record("a", ago: 0), record("a", ago: 7200)]
        XCTAssertEqual(m.selection, .history(a.key), "its new record: selected")
        XCTAssertNil(m.following, "one-shot")
        XCTAssertEqual(seen, [nil, .history(a.key)])

        // The record read landing before the row leaves: straight to it, no empty pane between.
        st.sessions = [a, b]
        st.history = [record("a", ago: 7200)]
        m.ask(.kill, a)
        m.confirm(true)
        st.history = [record("a", ago: 0)]
        XCTAssertEqual(m.selection, .live(a.key), "still live: stays")
        seen = []
        st.sessions = [b]
        XCTAssertEqual(seen, [.history(a.key)], "one change, never through nothing")

        // Any manual pick drops it.
        st.sessions = [a, b]
        st.history = []
        m.ask(.stop, a)
        m.confirm(true)
        m.select(.live(b.key))
        XCTAssertNil(m.following)
        st.sessions = [b]
        st.history = [record("a", ago: 0)]
        XCTAssertEqual(m.selection, .live(b.key))

        // A refused Stop (busy row) follows nothing; neither does a Restart.
        st.sessions = [a, b]
        st.history = []
        calls.started = false
        m.ask(.stop, a)
        m.confirm(true)
        XCTAssertNil(m.following)
        calls.started = true
        m.ask(.restart, a)
        m.confirm(true)
        XCTAssertNil(m.following)

        // Past the Stop's bound: dropped.
        m.ask(.stop, a)
        m.confirm(true)
        m.now = { Self.now + DchActionRunner.restartBound + 1 }
        st.sessions = [b]
        st.history = [record("a", ago: -DchActionRunner.restartBound)]
        XCTAssertNil(m.following)
        XCTAssertNil(m.selection, "too late to follow")
    }

    // MARK: G0: the island's row and dir texts

    @MainActor
    func testAgentWindowShowsTheIslandsRowAndDirTexts() throws {
        let st = store([session("a", .working, agents: 2)])
        let k = ctlKey("a")
        XCTAssertNil(AgentWindowControls.notice(st, k))
        st.actions[k] = "Stopping…"
        XCTAssertEqual(AgentWindowControls.notice(st, k), "Stopping…", "an action alone shows")
        st.notices[k] = "Attach command copied"
        XCTAssertEqual(AgentWindowControls.notice(st, k), "Attach command copied", "the island's rule: the notice wins")
        st.notices = [:]
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.rows.first?.detail, "Stopping… · 2 agents", "a running text replaces the state word")
        st.actions[k] = "Pausing…"
        XCTAssertEqual(m.rows.first?.detail, "Pausing… · 2 agents", "each phase as it comes")
        st.actions[k] = "Stopped"
        XCTAssertEqual(m.rows.first?.detail, "Working · 2 agents", "a result is not a running text: the state again")
        st.actions[k] = AgentIsland.restartBusyText
        XCTAssertEqual(m.rows.first?.detail, "Working · 2 agents")
        // The dir strip: hidden while empty, one line when not.
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            let saved = ThemeRuntime.scale
            defer { ThemeRuntime.scale = saved }
            ThemeRuntime.scale = scale
            st.actions = [:]
            let size = CGSize(width: sz(290), height: AgentWindowControls.stripHeight)
            XCTAssertEqual(ink(try render(AgentDirStatusStrip(store: st), size: size, dark: true)), 0, "nothing to say: nothing drawn")
            st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "")] = "Stop all: 2 stopped, 1 failed"
            st.actions[AgentSessionKey(dir: "/tmp/other", name: "")] = "Kill all: 1 killed"
            XCTAssertEqual(st.dirStatus, "Stop all: 2 stopped, 1 failed · Kill all: 1 killed")
            let rep = try render(AgentDirStatusStrip(store: st), size: size, dark: true)
            try save(rep, "829-dir-strip-\(scale)")
            XCTAssertGreaterThan(ink(rep), 10)
            XCTAssertEqual(overflow(rep, content: size, canvas: CGSize(width: size.width + 24, height: size.height + 24)), 0)
            XCTAssertEqual(NSHostingView(rootView: AgentDirStatusStrip(store: st).frame(width: size.width)).fittingSize.height,
                           AgentWindowControls.stripHeight, accuracy: 1, "one fixed height (fittingSize rounds to whole points) at \(scale)")
        }
    }

    // MARK: 3.5: the input lock

    @MainActor
    func testAgentWindowInputLocksWhileARestartOrStopTypes() {
        let i = AgentWindowInteraction()
        let idle = AgentSession(key: ctlKey("a"), alias: "", activity: 1, state: .idle, agents: 0)
        let working = AgentSession(key: ctlKey("a"), alias: "", activity: 1, state: .working, agents: 0)
        i.follow(idle)
        i.draft = "hello"
        XCTAssertTrue(AgentInteractionPane(model: i, session: idle, open: {}).canSend)
        XCTAssertTrue(AgentInteractionPane(model: i, session: working, open: {}).canInterrupt)
        for t in AgentIsland.runningTexts {
            let lock = AgentWindowControls.lock(t)
            XCTAssertEqual(lock, t)
            let p = AgentInteractionPane(model: i, session: idle, open: {}, lock: lock)
            XCTAssertFalse(p.canSend, t)
            XCTAssertFalse(AgentInteractionPane(model: i, session: working, open: {}, lock: lock).canInterrupt, t)
            XCTAssertEqual(p.placeholder, "\(t.dropLast()): wait for it to finish")
        }
        XCTAssertEqual(AgentInteractionPane(model: i, session: idle, open: {}, lock: "Restarting…").placeholder,
                       "Restarting: wait for it to finish")
        for t in [nil, "Restarted", "Stopped", AgentIsland.killingText, "Killed", AgentIsland.restartBusyText,
                  "NOT stopped — claude did not go idle; resume message typed"] {
            XCTAssertNil(AgentWindowControls.lock(t), "\(t ?? "nil") locks nothing")
        }
        XCTAssertEqual(i.draft, "hello", "the draft is kept")
    }

    // MARK: QA #660 notes on #828

    @MainActor
    func testAgentWindowKeysReachAFullyFoldedSidebarAndPassATextView() throws {
        let pref = "agentWindowCollapsedSections"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        Preferences.defaults.set(["Sessions", "Sidekicks", "History"], forKey: pref)
        var opened: [String] = []
        let m = windowModel(foldStore(), opened: { opened.append($0.name) })
        m.setVisible(true)
        defer { m.close() }
        XCTAssertNil(m.selection)
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        // Note 1: right with nothing selected and every section folded unfolds the first and picks its first row.
        XCTAssertTrue(AgentsNSWindow.handle(key(124), m))
        XCTAssertFalse(m.isCollapsed("Sessions"))
        XCTAssertTrue(m.isCollapsed("Sidekicks") && m.isCollapsed("History"), "only the first")
        XCTAssertEqual(m.selection, live("a"))
        m.setCollapsed("Sessions", true)
        m.select(nil)
        _ = AgentsNSWindow.handle(key(125), m)
        XCTAssertNil(m.selection, "down never unfolds: #828's rule (the smallest rule: right only)")
        XCTAssertTrue(m.isCollapsed("Sessions"))
        XCTAssertTrue(AgentsNSWindow.handle(key(124), m))
        XCTAssertEqual(m.selection, live("a"))
        XCTAssertFalse(m.isCollapsed("Sessions"))
        m.setCollapsed("Sidekicks", false)
        m.select(nil)
        XCTAssertTrue(AgentsNSWindow.handle(key(124), m))
        XCTAssertEqual(m.selection, live("a"), "rows shown: right picks the first, unfolds nothing")
        XCTAssertTrue(m.isCollapsed("History"))
        m.setCollapsed("Sidekicks", true)
        XCTAssertTrue(AgentsNSWindow.handle(key(123), m))
        XCTAssertTrue(m.isCollapsed("Sessions"), "left still folds the selection's section")
        m.select(nil)
        XCTAssertTrue(AgentsNSWindow.handle(key(123), m))
        XCTAssertNil(m.selection, "left with nothing selected does nothing")
        XCTAssertTrue(m.isCollapsed("Sessions"))
        // Note 2 (decided: acting is fine, the detail pane shows the folded selection): Return opens it.
        m.select(live("a"))
        XCTAssertTrue(m.isCollapsed("Sessions"))
        XCTAssertTrue(AgentsNSWindow.handle(key(36), m))
        XCTAssertEqual(opened, ["a"], "Return acts on a selection inside a folded section")
        // Note 5: with a text view first responder, left and right go to it, not to the sidebar.
        let tv = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 20))
        tv.string = "draft"
        win.contentView?.addSubview(tv)
        XCTAssertTrue(win.makeFirstResponder(tv))
        XCTAssertTrue(win.sidebarFocused)
        win.sendEvent(key(124))
        XCTAssertTrue(m.isCollapsed("Sessions"), "right reached the text view, not the fold")
        m.setCollapsed("Sessions", false)
        win.sendEvent(key(123))
        XCTAssertFalse(m.isCollapsed("Sessions"), "left too")
        XCTAssertEqual(tv.string, "draft")
        XCTAssertTrue(win.makeFirstResponder(nil))
        win.sendEvent(key(123))
        XCTAssertTrue(m.isCollapsed("Sessions"), "no text view: the sidebar's left folds again")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// Note 4: the slot fits every age the formatter returns.
    @MainActor
    func testAgentWindowAgeSlotFitsTheWidestAge() {
        let year: TimeInterval = 365 * 86400
        let cases: [(TimeInterval, String)] = [(119 * 86400, "119d"), (120 * 86400, "120d"), (year - 1, "364d"), (year, "1y"),
                                               (2 * year + 5, "2y"), (99 * year, "99y"), (1e12, "99y"),
                                               (.greatestFiniteMagnitude, "99y")]
        for (s, want) in cases { XCTAssertEqual(AgentIsland.age(s), want, "\(s)") }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            func w(_ t: String) -> CGFloat {
                NSHostingView(rootView: Text(t).font(Neon.font(10).monospacedDigit()).fixedSize()).fittingSize.width
            }
            let slot = w(AgentIsland.ageWidest)
            for t in ["9s", "59s", "59m", "23h", "120d", "364d", "1y", "99y"] {
                XCTAssertLessThanOrEqual(w(t), slot + 0.01, "\(t) fits the slot at \(scale)")
            }
        }
    }

    // MARK: Offscreen evidence: nothing moves when a strip or the "⋯" shows

    @MainActor
    func testAgentWindowRendersTheControlsWithoutMovingNeighbours() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        let convo = Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl")
        let (m, st) = demoModel(convo)
        defer { m.close() }
        let calls = Calls()
        calls.wire(m)
        st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 38, 0])
        let s = try XCTUnwrap(m.selectedRow?.session)
        /// Rows (pixels) where two renders differ.
        func diffRows(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [Int] {
            (0..<a.pixelsHigh).filter { y in
                stride(from: 0, to: a.pixelsWide, by: 2).contains { x in
                    a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y)
                }
            }
        }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            for (label, size) in [("min", CGSize(width: 640 * scale, height: 420 * scale)),
                                  ("default", CGSize(width: 1000 * scale, height: 680 * scale))] {
                let canvas = CGSize(width: size.width + 24, height: size.height + 24)
                let plain = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                try save(plain, "829-window-\(label)-\(scale)")
                XCTAssertEqual(overflow(plain, content: size, canvas: canvas), 0, "\(label) \(scale)")
                // The confirm strip: drawn over the conversation's top only.
                m.ask(.restart, s)
                let asked = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                try save(asked, "829-window-confirm-\(label)-\(scale)")
                m.confirm(false)
                XCTAssertEqual(overflow(asked, content: size, canvas: canvas), 0, "\(label) \(scale)")
                let k = CGFloat(asked.pixelsWide) / canvas.width
                let rows = diffRows(plain, asked)
                XCTAssertFalse(rows.isEmpty, "the strip shows (\(label) \(scale))")
                XCTAssertLessThan(CGFloat((rows.max() ?? 0) - (rows.min() ?? 0)) / k, size.height * 0.6,
                                  "only a band changed (\(label) \(scale))")
                XCTAssertGreaterThan(CGFloat(rows.min() ?? 0) / k, 60 * scale, "the header stays put (\(label) \(scale))")
                XCTAssertLessThan(CGFloat(rows.max() ?? 0) / k, size.height - 120 * scale,
                                  "the input box stays put (\(label) \(scale))")
                // The dir strip: over the sidebar's reserved bottom, so no row moves.
                st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "")] = "Restart all: 2 restarted"
                let dir = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                try save(dir, "829-window-dirstrip-\(label)-\(scale)")
                st.actions = [:]
                let drows = diffRows(plain, dir)
                XCTAssertFalse(drows.isEmpty)
                XCTAssertGreaterThan(CGFloat(drows.min() ?? 0) / k, size.height - AgentWindowControls.stripHeight - 2,
                                     "only the sidebar's bottom line changed (\(label) \(scale))")
            }
            // The running text in the notice line, the sidebar and the locked input box.
            st.actions[s.key] = "Pausing…"
            let locked = try render(AgentWindowRootView(model: m, scrolls: false), size: CGSize(width: 1000 * scale, height: 680 * scale),
                                    dark: true)
            try save(locked, "829-window-locked-\(scale)")
            st.actions = [:]
            // The header at the narrowest pane: the "⋯" fits every variant without overflow.
            let room = 640 * scale - sz(290) - 1
            let header = AgentSessionHeader(row: try XCTUnwrap(m.selectedRow), session: s, cwd: "/Users/example/projects/prosper",
                                            open: {}, store: st)
            let hsize = CGSize(width: room, height: 90 * scale)
            let hrep = try render(header, size: hsize, dark: true)
            try save(hrep, "829-header-min-\(scale)")
            XCTAssertEqual(overflow(hrep, content: hsize, canvas: CGSize(width: hsize.width + 24, height: hsize.height + 24)), 0)
        }
        XCTAssertTrue(calls.all.isEmpty, "rendering and Cancel ran nothing")
    }
}

extension AgentWindowInteractionTests {
    /// QA #660 note 6: Interrupt is on while Claude works and no answer is in flight, only.
    @MainActor
    func testAgentWindowCanInterruptOnlyWhileWorkingAndNotBusy() {
        let i = interaction(nil)
        for state in AgentState.allCases {
            let s = session(state)
            i.follow(s)
            XCTAssertEqual(AgentInteractionPane(model: i, session: s, open: {}).canInterrupt, state == .working, "\(state)")
        }
        let f = MessageFake(statuses: ["working", "idle"])
        let gate = DispatchSemaphore(value: 0)
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var first = true
            func take() -> Bool { lock.withLock { defer { first = false }; return first } }
        }
        let once = Once()
        let io = AgentPromptIO(read: { k in if once.take() { gate.wait() }; return f.io.read(k) }, status: f.io.status,
                               send: f.io.send, keys: f.io.keys, say: f.io.say)
        let j = interaction(controller(io, autoAllow: false))
        j.follow(session(.working))
        j.interrupt()
        XCTAssertTrue(j.busy)
        XCTAssertFalse(AgentInteractionPane(model: j, session: session(.working), open: {}).canInterrupt, "busy: off")
        gate.signal()
        until("interrupted") { !j.busy }
        XCTAssertTrue(AgentInteractionPane(model: j, session: session(.working), open: {}).canInterrupt, "free again: on")
    }
}

// MARK: 3.5 in the model (review round 1): the lock holds without the UI too

extension AgentWindowInteractionTests {
    /// Under every running text, every write path of the interaction model (send, interrupt, a
    /// single choice, a preview option, multi Submit, Other, Chat about this, plan approve)
    /// refuses: the notice is the lock's line and nothing reaches the pty. Cleared, each one goes.
    /// Through the fakes only; the lock is read through the rowText seam.
    @MainActor
    func testAgentWindowInteractionRefusesEveryWriteWhileARunningTextShows() throws {
        var row: String?
        struct NoPanel: Error { let why: String }   // thrown: the test fails, never skips
        struct Case {
            let name: String
            let make: () throws -> (AgentWindowInteraction, () -> Int)
            let go: (AgentWindowInteraction) throws -> Void
        }
        func form(_ kind: FormSim.Kind, ask: AgentAskInput? = nil, plan: AgentPlanInput? = nil) -> () throws -> (AgentWindowInteraction, () -> Int) {
            {
                let f = FormSim(kind)
                let i = self.interaction(self.controller(f.io, autoAllow: false))
                i.rowText = { _ in row }
                i.ask = ask
                i.plan = plan
                i.follow(self.session(.blocked))
                guard case .prompt = i.panel else { throw NoPanel(why: "no prompt panel for \(kind): \(i.panel)") }
                return (i, { f.lock.withLock { f.log.count } })
            }
        }
        func message(_ statuses: [String], _ state: AgentState) -> () throws -> (AgentWindowInteraction, () -> Int) {
            {
                let f = MessageFake(statuses: statuses)
                let i = self.interaction(self.controller(f.io, autoAllow: false))
                i.rowText = { _ in row }
                i.follow(self.session(state))
                i.draft = "hello"
                return (i, { f.lock.withLock { f.says.count + f.keys.count } })
            }
        }
        func prompt(_ i: AgentWindowInteraction) throws -> AgentWindowPrompt {
            guard case .prompt(let w) = i.panel else { throw NoPanel(why: "\(i.panel)") }
            return w
        }
        let cases = [
            Case(name: "send", make: message(["idle", "working"], .idle)) { $0.send() },
            Case(name: "interrupt", make: message(["working", "idle"], .working)) { $0.interrupt() },
            Case(name: "single choice", make: form(.single, ask: Self.singleAsk)) { $0.answer(try prompt($0).buttons[0]) },
            Case(name: "preview", make: form(.preview, ask: Self.previewAsk)) { $0.choosePreview(try prompt($0).buttons[0]) },
            Case(name: "multi submit", make: form(.multi, ask: Self.multiAsk)) { $0.picks = [1]; $0.submitPicks() },
            Case(name: "other", make: form(.single, ask: Self.singleAsk)) { $0.otherText = "Teal"; $0.sendOther() },
            Case(name: "chat", make: form(.single, ask: Self.singleAsk)) { $0.chat() },
            Case(name: "plan approve", make: form(.plan, plan: Self.planInput)) { i in
                let w = try prompt(i)
                i.answer(try XCTUnwrap(w.buttons.first { w.approve.contains($0.digit) }, "an approve row"))
            },
        ]
        XCTAssertFalse(AgentIsland.runningTexts.isEmpty)
        for c in cases {
            for t in AgentIsland.runningTexts.sorted() {
                row = t
                let (i, writes) = try c.make()
                try c.go(i)
                XCTAssertFalse(i.busy, "\(c.name) under \(t): nothing in flight")
                XCTAssertEqual(i.notice, AgentWindowControls.lockPlaceholder(t), "\(c.name) under \(t): the notice says why")
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                XCTAssertEqual(writes(), 0, "\(c.name) under \(t): nothing reaches the pty")
            }
            // Text that is no running text (none, an outcome, a refusal): no lock, it goes.
            for t in [nil, "Restarted", AgentIsland.restartBusyText] {
                row = t
                let (i, writes) = try c.make()
                try c.go(i)
                until("\(c.name) goes with row \(t ?? "nil")") { writes() > 0 }
                XCTAssertGreaterThan(writes(), 0, "\(c.name) with row \(t ?? "nil"): it goes")
                until("\(c.name) done") { !i.busy }
            }
        }
    }

    /// The default lock read (no seam): the controller's own store, the one the island writes.
    @MainActor
    func testAgentWindowInteractionReadsTheLockFromTheControllersStore() {
        let f = MessageFake(statuses: ["idle", "working"])
        let c = controller(f.io, autoAllow: false)
        let i = interaction(c)
        i.follow(session(.idle))
        i.draft = "hello"
        c.store?.actions[Self.key] = AgentIsland.restartingText
        i.send()
        XCTAssertFalse(i.busy)
        XCTAssertEqual(i.notice, AgentWindowControls.lockPlaceholder(AgentIsland.restartingText))
        XCTAssertEqual(i.draft, "hello", "the text stays in the box")
        c.store?.actions[Self.key] = nil
        i.send()
        until("sent") { !i.busy }
        XCTAssertEqual(f.says, ["hello"])
    }
}
