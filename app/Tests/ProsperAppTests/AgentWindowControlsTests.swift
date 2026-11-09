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
        /// #829 Phase 2: the History seams.
        var records: [(verb: AgentWindowVerb, record: DchHistoryRecord)] = []
        var started = true
        func wire(_ m: AgentWindowModel) {
            m.restartSession = { self.all.append((.restart, $0)); return self.started }
            m.stopSession = { self.all.append((.stop, $0)); return self.started }
            m.killSession = { self.all.append((.kill, $0)); return self.started }
            m.resume = { self.records.append((.resume, $0)) }
            m.resumeNoMessage = { self.records.append((.resumeNoMessage, $0)) }
            m.pinRecord = { self.records.append((.pin, $0)) }
            m.removeRecord = { self.records.append((.remove, $0)) }
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
        st.controlDch = bin([1, 38, 0])   // QA #665 INFO-6: the answer checks the gates again (masters at 1.30.0)
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
        st.controlDch = bin([1, 38, 0])
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
        // QA #665 INFO-8: the row went before its record: the selection holds on the ended session.
        XCTAssertEqual(m.selection, .live(a.key), "the row went and only an older record of its name is there: held")
        XCTAssertEqual(m.selectedRow?.session?.key, a.key, "the pane keeps the session's last row")
        st.history = [record("other", ago: 0), record("a", ago: 7200)]
        XCTAssertEqual(m.selection, .live(a.key), "another session's new record: not followed, still held")
        XCTAssertNotNil(m.following)
        st.history = [record("a", ago: 0), record("a", ago: 7200)]
        XCTAssertEqual(m.selection, .history(a.key), "its new record: selected")
        XCTAssertNil(m.following, "one-shot")
        XCTAssertEqual(seen, [.history(a.key)], "never through nothing")

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

        // QA #665 INFO-8: held, the bound passing with no record lets go (nothing selected), and a
        // manual pick while held drops the hold at once.
        m.now = { Self.now }
        st.sessions = [a, b]
        st.history = []
        m.ask(.kill, a)
        m.confirm(true)
        st.sessions = [b]
        XCTAssertEqual(m.selection, .live(a.key), "held")
        m.now = { Self.now + DchActionRunner.restartBound + 1 }
        m.refresh()
        XCTAssertNil(m.following)
        XCTAssertNil(m.selection, "the bound passed with no record: let go")
        XCTAssertNil(m.selectedRow)
        m.now = { Self.now }
        st.sessions = [a, b]
        m.ask(.kill, a)
        m.confirm(true)
        st.sessions = [b]
        m.select(.live(b.key))
        st.sessions = [a, b]
        st.sessions = [b]
        XCTAssertEqual(m.selection, .live(b.key))
        m.select(.live(a.key))
        XCTAssertNil(m.selectedRow, "no follow, no hold: a gone row reads as nothing")
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
                // QA #665 INFO-1: a row text (a busy refusal, then a running text) shows over the
                // conversation's top: one band changes and nothing under it moves.
                st.actions[s.key] = AgentIsland.restartBusyText
                let refused = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                try save(refused, "829p2-window-refusal-\(label)-\(scale)")
                XCTAssertEqual(overflow(refused, content: size, canvas: canvas), 0, "\(label) \(scale)")
                let band = diffRows(plain, refused)
                XCTAssertFalse(band.isEmpty, "the refusal shows (\(label) \(scale))")
                XCTAssertGreaterThan(CGFloat(band.min() ?? 0) / k, 60 * scale, "the header stays put (\(label) \(scale))")
                XCTAssertLessThan(CGFloat((band.max() ?? 0) - (band.min() ?? 0)) / k, 40 * scale,
                                  "one line's band, the transcript under it unmoved (\(label) \(scale))")
                st.actions[s.key] = "Pausing…"
                let locked = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                try save(locked, "829-window-locked-\(label)-\(scale)")
                st.actions = [:]
                // The detail pane's columns: the notice band and the locked input box change, nothing between.
                let x0 = Int((sz(290) + 2) * k), inputTop = Int((size.height - 120 * scale) * k)
                let moved = (0..<locked.pixelsHigh).filter { y in
                    (y < (band.min() ?? 0) - 1 || y > (band.max() ?? 0) + 1) && y < inputTop
                        && stride(from: x0, to: locked.pixelsWide - Int(24 * k), by: 2).contains { x in
                            plain.colorAt(x: x, y: y) != locked.colorAt(x: x, y: y)
                        }
                }
                XCTAssertEqual(moved, [], "locked: the conversation did not move (\(label) \(scale))")
            }
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

/// #829 Phase 2: a History row's Resume, Resume (no message), Pin/Unpin and Remove from History from
/// the window (the island's gates, titles and controller calls; Remove asks on the Phase 1 strip),
/// the selection after a removal, and QA #665's notes on Phase 1. Offscreen only, every seam stubbed.
extension AgentWindowD1Tests {
    func hkey(_ name: String) -> AgentSessionKey { AgentSessionKey(dir: "/tmp/dch-test", name: name) }

    func pinned(_ r: DchHistoryRecord) -> DchHistoryRecord {
        var r = r
        r.pinned = true
        return r
    }

    /// An older record of `name` a cold start moved aside (#743): same key, its own file.
    func aside(_ name: String, ago: TimeInterval, pinned: Bool = false) -> DchHistoryRecord {
        var r = record(name, ago: ago)
        r.file = "\(name).\(Int(Self.now - ago))"
        r.pinned = pinned
        return r
    }

    func bin(_ v: [Int]) -> DchCommand.Binary { DchCommand.Binary(path: "/fake/dch", version: v) }

    // MARK: G6-G8 menu: the island's gates and titles

    @MainActor
    func testAgentWindowHistoryMenuUsesTheIslandsGatesAndTitles() throws {
        let h = record("h"), dash = record("-x")
        let st = store([], history: [h, dash])
        st.controlDch = nil
        let why = try XCTUnwrap(st.resumeGate.refusal)
        XCTAssertEqual(AgentWindowControls.historyMenu(h, store: st), [.note("Resume \(why)")],
                       "no control dch: nothing drawn (as the island), the reason as a note")
        st.controlDch = bin([1, 24, 1])
        XCTAssertEqual(AgentWindowControls.historyMenu(h, store: st), [.item("Resume", enabled: true, verb: .resume)],
                       "1.24: Resume only (no message needs 1.27.0, pin and remove 1.25.0)")
        st.controlDch = bin([1, 25, 0])
        XCTAssertEqual(AgentWindowControls.historyMenu(h, store: st), [
            .item("Resume", enabled: true, verb: .resume), .divider,
            .item("Pin", enabled: true, verb: .pin), .item("Remove from History…", enabled: true, verb: .remove),
        ])
        st.controlDch = bin([1, 27, 0])
        let all: [AgentWindowMenuEntry] = [
            .item("Resume", enabled: true, verb: .resume), .item("Resume (no message)", enabled: true, verb: .resumeNoMessage),
            .divider, .item("Pin", enabled: true, verb: .pin), .item("Remove from History…", enabled: true, verb: .remove),
        ]
        XCTAssertEqual(AgentWindowControls.historyMenu(h, store: st), all, "Remove asks: an ellipsis; the rest act at once")
        XCTAssertEqual(AgentWindowControls.historyMenu(dash, store: st), [], "#627: a name dch reads as a flag gets nothing")
        XCTAssertEqual(AgentWindowControls.historyMenu(pinned(h), store: st), [
            .item("Resume", enabled: true, verb: .resume), .item("Resume (no message)", enabled: true, verb: .resumeNoMessage),
            .divider, .item("Unpin", enabled: true, verb: .pin),
            .item("Remove from History (unpin it first)", enabled: false, verb: .remove),
        ], "pinned: Unpin, and Remove stays, off, saying why")
        // #743: folded older records, counted as the island counts them (Remove: the unpinned ones).
        st.history = [h, aside("h", ago: 9000), aside("h", ago: 9500, pinned: true)]
        let menu = AgentWindowControls.historyMenu(h, store: st)
        XCTAssertEqual(menu[3], .item("Pin (also 2 older records of this name)", enabled: true, verb: .pin))
        XCTAssertEqual(menu[4], .item("Remove from History (also 1 older record of this name)…", enabled: true, verb: .remove))
        // A live master newer than the control dch closes the gates, as in the island.
        st.sessions = [ctlSession("live", version: "1.30.0")]
        XCTAssertFalse(AgentWindowControls.historyMenu(h, store: st).contains { if case .item(_, _, .pin) = $0 { true } else { false } })
        // notRun: on, an off item's title, a gate's note.
        XCTAssertNil(AgentWindowControls.notRun(all, .remove))
        XCTAssertEqual(AgentWindowControls.notRun(AgentWindowControls.historyMenu(pinned(h), store: store([], history: [h]).with(bin([1, 27, 0]))), .remove),
                       "Not run: Remove from History (unpin it first)")
        XCTAssertEqual(AgentWindowControls.notRun([.note("Resume \(why)")], .remove), "Not run: Resume \(why)")
        XCTAssertEqual(AgentWindowControls.notRun([.note("Resume \(why)")], .remove, absent: "Remove from History (\(why))"),
                       "Not run: Remove from History (\(why))", "a History verb: its own reason, not Resume's")
        st.sessions = []
        st.controlDch = bin([1, 24, 1])
        XCTAssertEqual(AgentWindowControls.historyOff(.pin, h, store: st), "Pin (needs dch 1.25.0)")
        XCTAssertEqual(AgentWindowControls.historyOff(.pin, pinned(h), store: st), "Unpin (needs dch 1.25.0)")
        XCTAssertEqual(AgentWindowControls.historyOff(.resumeNoMessage, h, store: st), "Resume (no message) (needs dch 1.27.0)")
        XCTAssertEqual(AgentWindowControls.historyOff(.resume, dash, store: st), "Resume (not available for this session)")
    }

    // MARK: G6-G8: act through the island; Remove asks

    @MainActor
    func testAgentWindowHistoryActsThroughTheIslandAndAsksBeforeRemoving() throws {
        var h = record("h")
        h.agent = DchHistoryRecord.Agent(kind: "claude", sessionID: "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab")
        let g = record("g", ago: 7200)
        // "h" is live again too: its record's id equals the live key (#580); the question must not mix them.
        let st = store([session("h", .idle)], history: [h, g])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        m.select(.history(g.id))
        m.act(.resume, h)
        XCTAssertEqual(m.selection, .history(h.id), "R6: the row is selected first")
        m.act(.resumeNoMessage, h)
        m.act(.pin, h)
        XCTAssertEqual(calls.records.map(\.verb), [.resume, .resumeNoMessage, .pin], "no question for these (as the island)")
        XCTAssertTrue(calls.records.allSatisfy { $0.record == h })
        XCTAssertNil(m.confirming)
        XCTAssertTrue(calls.all.isEmpty)
        // Remove asks, naming the record, with its Claude id.
        m.act(.remove, h)
        XCTAssertEqual(m.confirming, AgentWindowConfirm(verb: .remove, key: h.id))
        XCTAssertNil(m.confirmingSession, "the live session of the same key is not the asked thing")
        XCTAssertEqual(m.confirmingRecord, h)
        XCTAssertEqual(AgentWindowControls.removeQuestion(h),
                       "Remove h from History? Resume won't be able to bring it back. Its Claude Code conversation stays on disk."
                           + " (claude --resume 0b7c2f3e-aaaa-bbbb-cccc-0123456789ab)")
        XCTAssertFalse(AgentWindowControls.removeQuestion(g).contains("--resume"), "no id: no command")
        XCTAssertEqual(AgentWindowControls.confirmTitle(.remove), "Remove")
        XCTAssertEqual(calls.records.count, 3, "asking runs nothing")
        m.confirm(false)
        XCTAssertNil(m.confirming)
        XCTAssertEqual(calls.records.count, 3, "Cancel runs nothing")
        m.act(.remove, h)
        m.select(.history(g.id))
        XCTAssertNil(m.confirming, "another row picked: the strip goes")
        m.act(.remove, h)
        m.confirm(true)
        XCTAssertEqual(calls.records.last?.verb, .remove)
        XCTAssertEqual(calls.records.last?.record, h)
        XCTAssertTrue(calls.all.isEmpty, "never a live verb on the live session of that name")
        // Re-resolved at the answer: gone, nothing runs.
        m.act(.remove, g)
        m.setVisible(false)
        st.history = [h]
        m.confirm(true)
        XCTAssertEqual(calls.records.count, 4, "the record went before the answer: nothing runs")
        m.setVisible(true)
        st.history = [h, g]
        m.act(.remove, g)
        st.history = [h]
        XCTAssertNil(m.confirming, "the asked record gone from the list drops the strip")
        // QA #665 INFO-6 for Remove: pinned (or the gate closed) since the question: nothing runs, the row says why.
        st.history = [h, g]
        m.act(.remove, g)
        st.history = [h, pinned(g)]
        m.confirm(true)
        XCTAssertEqual(calls.records.count, 4)
        XCTAssertEqual(m.refusalText(.history(g.id)), "Not run: Remove from History (unpin it first)")
        XCTAssertNil(m.refusalText(.history(h.id)), "on that row only")
        st.history = [h, g]
        m.act(.remove, g)
        XCTAssertNil(m.refusal, "the next question drops it")
        st.controlDch = bin([1, 24, 1])
        m.confirm(true)
        XCTAssertEqual(calls.records.count, 4)
        XCTAssertEqual(m.refusalText(.history(g.id)), "Not run: Remove from History (\(try XCTUnwrap(st.historyEditGate.refusal)))",
                       "the edit gate's reason")
        m.select(.history(h.id))
        XCTAssertNil(m.refusal, "a selection change drops it")
    }

    // MARK: QA #665 INFO-6: a live answer whose gate closed says why

    @MainActor
    func testAgentWindowAnswerSaysWhyWhenAGateClosedSinceTheQuestion() throws {
        let a = ctlSession("a", version: "1.24.0"), old = ctlSession("old", version: "1.24.0")
        let st = store([a, old])
        st.controlDch = Self.v1241
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        m.ask(.restart, a)
        st.controlDch = Self.v1240
        m.confirm(true)
        XCTAssertTrue(calls.all.isEmpty, "the gate closed: nothing runs")
        XCTAssertEqual(m.refusalText(.live(a.key)), "Not run: Restart agent (needs dch 1.24.1)")
        st.controlDch = nil
        m.ask(.kill, a)
        XCTAssertNil(m.refusal, "a new question drops it")
        m.confirm(true)
        let why = try XCTUnwrap(st.resumeGate.refusal)
        XCTAssertEqual(m.refusalText(.live(a.key)), "Not run: Controls \(why)", "the gate's own reason")
        // A master that dropped under 1.24.0 since the question (a restarted session on an old dch).
        st.controlDch = Self.v1241
        m.ask(.stop, old)
        st.sessions = [a, ctlSession("old", version: "1.23.0")]
        m.confirm(true)
        XCTAssertEqual(m.refusalText(.live(old.key)), "Not run: \(AgentIsland.stopOldMasterLabel)")
        XCTAssertTrue(calls.all.isEmpty)
        // The notice line shows it over the row's text.
        st.actions[old.key] = "Restarted"
        XCTAssertEqual(NSHostingView(rootView: AgentNoticeLine(store: st, key: old.key, refusal: m.refusalText(.live(old.key)))).fittingSize.height,
                       NSHostingView(rootView: AgentNoticeLine(store: st, key: old.key)).fittingSize.height, accuracy: 1)
        m.ask(.stop, a)
        m.confirm(true)
        XCTAssertEqual(calls.all.map(\.verb), [.stop], "gates open: it runs")
        XCTAssertNil(m.refusal)
    }

    // MARK: G8: the selection after a removal

    @MainActor
    func testAgentWindowRemovalMovesTheSelectionToTheNextHistoryRow() throws {
        let h1 = record("h1", ago: 100), h2 = record("h2", ago: 200), h3 = record("h3", ago: 300)
        let st = store([session("live", .idle)], history: [h1, h2, h3])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        var seen: [AgentSidebar.RowID?] = []
        let sub = m.$selection.dropFirst().sink { seen.append($0) }
        defer { sub.cancel() }
        m.act(.remove, h2)
        m.confirm(true)
        XCTAssertEqual(m.removing, h2.id)
        st.history = [h1, h2, h3]   // a re-read with the row still there (a failed forget): stays
        XCTAssertEqual(m.selection, .history(h2.id))
        seen = []
        st.history = [h1, h3]
        XCTAssertEqual(m.selection, .history(h3.id), "the next row")
        XCTAssertEqual(seen, [.history(h3.id)], "one change, never through nothing")
        XCTAssertNil(m.removing, "one-shot")
        m.act(.remove, h3)
        m.confirm(true)
        seen = []
        st.history = [h1]
        XCTAssertEqual(m.selection, .history(h1.id), "the last one: the previous row")
        XCTAssertEqual(seen, [.history(h1.id)])
        // The next row went too (another remove landed in the same read): the one after it, else before.
        st.history = [h1, h2, h3, record("h4", ago: 400)]
        m.act(.remove, h2)
        m.confirm(true)
        st.history = [h1, record("h4", ago: 400)]
        XCTAssertEqual(m.selection, .history(hkey("h4")), "the next row still there")
        // The only History row: nothing selected (the live rows are not History).
        st.history = [h1]
        m.act(.remove, h1)
        m.confirm(true)
        st.history = []
        XCTAssertNil(m.selection, "no History row left: nothing")
        // A manual pick drops the hand-on.
        st.history = [h1, h2]
        m.act(.remove, h1)
        m.confirm(true)
        m.select(.history(h1.id))
        XCTAssertNil(m.removing)
        st.history = [h2]
        XCTAssertNil(m.selection, "the record left without a window removal: today's rule")
        // A record removed elsewhere (the island) while selected: today's rule too.
        st.history = [h1, h2]
        m.select(.history(h1.id))
        st.history = [h2]
        XCTAssertNil(m.selection)
        XCTAssertEqual(calls.records.filter { $0.verb == .remove }.map(\.record.name), ["h2", "h3", "h2", "h1", "h1"])
        // neighbour() on its own: after, else before, else the first left.
        let sec = { (ids: [String]) in [AgentSidebar.Section(title: "History", rows: ids.map { self.record($0) }.map { AgentSidebar.row($0, now: Self.now) })] }
        XCTAssertEqual(AgentWindowModel.neighbour(of: hkey("b"), old: sec(["a", "b", "c"]), new: sec(["a", "c"])), .history(hkey("c")))
        XCTAssertEqual(AgentWindowModel.neighbour(of: hkey("b"), old: sec(["a", "b", "c"]), new: sec(["a"])), .history(hkey("a")))
        XCTAssertEqual(AgentWindowModel.neighbour(of: hkey("b"), old: sec(["a", "b", "c"]), new: sec(["z"])), .history(hkey("z")))
        XCTAssertNil(AgentWindowModel.neighbour(of: hkey("b"), old: sec(["b"]), new: []))
        // The previous row is not always the first one left.
        XCTAssertEqual(AgentWindowModel.neighbour(of: hkey("d"), old: sec(["a", "b", "c", "d"]), new: sec(["a", "b", "c"])),
                       .history(hkey("c")))
    }

    @MainActor
    func testAgentWindowRemovingTheLastOfManyHistoryRowsSelectsTheOneBeforeIt() throws {
        let h1 = record("h1", ago: 100), h2 = record("h2", ago: 200), h3 = record("h3", ago: 300)
        let st = store([], history: [h1, h2, h3])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        Calls().wire(m)
        m.setVisible(true)
        defer { m.close() }
        m.act(.remove, h3)
        m.confirm(true)
        st.history = [h1, h2]
        XCTAssertEqual(m.selection, .history(h2.id), "the row just before it, not the first")
    }

    // MARK: A question whose session or record left is dropped for good

    @MainActor
    func testAgentWindowQuestionWhoseSessionOrRecordLeftDoesNotComeBack() throws {
        let a = session("a", .idle), b = session("b", .idle), g = record("g", ago: 7200)
        let st = store([a, b], history: [g])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        m.ask(.stop, a)
        st.sessions = [b]
        m.refresh()
        st.sessions = [a, b]   // an island Restart keeps the key
        XCTAssertNil(m.confirming, "the question went with its session; the same key back does not bring it")
        m.confirm(true)
        XCTAssertTrue(calls.all.isEmpty, "nothing runs")
        m.act(.remove, g)
        st.history = []
        m.refresh()
        st.history = [g]
        XCTAssertNil(m.confirming, "the question went with its record")
        m.confirm(true)
        XCTAssertTrue(calls.records.isEmpty, "nothing runs")
    }

    // MARK: QA #665 INFO-8: the held row is the last one seen

    @MainActor
    func testAgentWindowHeldRowIsTheLastLiveRowSeenBeforeItLeft() throws {
        let a = session("a", .idle), b = session("b", .idle)
        let st = store([a, b])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        Calls().wire(m)
        m.setVisible(true)
        defer { m.close() }
        m.ask(.stop, a)
        m.confirm(true)
        XCTAssertNotNil(m.following)
        st.actions[a.key] = AgentIsland.stoppingText
        st.sessions = [b]
        XCTAssertEqual(m.selection, .live(a.key), "held")
        XCTAssertEqual(m.selectedRow?.detail, AgentIsland.stoppingText, "the row as last seen, not as at the Stop")
        st.history = [record("a", ago: 0)]
        XCTAssertEqual(m.selection, .history(a.key))
    }
}

extension AgentWindowD1Tests {
    // MARK: QA #665 INFO-4/5: the dir strip never covers a row the keys select

    @MainActor
    func testAgentWindowKeysKeepTheSelectedRowAboveTheDirStrip() throws {
        let pref = "agentWindowCollapsedSections"
        let saved = Preferences.defaults.object(forKey: pref)
        let savedScale = ThemeRuntime.scale
        defer { Preferences.defaults.set(saved, forKey: pref); ThemeRuntime.scale = savedScale }
        Preferences.defaults.removeObject(forKey: pref)
        let st = store([session("a", .idle), session("b", .working)],
                       history: (0..<24).map { record("h\($0)", ago: TimeInterval(100 + $0)) })
        st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "")] = "Restart all: 2 restarted"
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            // The sidebar at the window's minimum height: the list scrolls.
            let size = CGSize(width: sz(290), height: 420 * scale)
            m.select(m.rows.first?.id)
            let host = NSHostingView(rootView: AgentSidebarView(model: m).frame(width: size.width, height: size.height)
                .background(Neon.sidebar).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            // In a window that is never shown (never ordered front, never key), so the list's scrollTo can act.
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            // The list's scroll view ends above the strip's slot: whatever it scrolls to is above it.
            func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
            let sv = try XCTUnwrap(scrollViews(host).first, "the list scrolls")
            let r = sv.convert(sv.bounds, to: host)
            let bottom = host.isFlipped ? r.maxY : host.bounds.height - r.minY
            XCTAssertLessThanOrEqual(bottom, size.height - AgentWindowControls.stripHeight + 0.5, "the list ends above the strip at \(scale)")
            for _ in m.rows { m.move(1) }   // the keys' path: down to the last row, scrolled to by the list
            XCTAssertEqual(m.selection, m.rows.last?.id)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let k = CGFloat(rep.pixelsHigh) / size.height
            // The selected row's 2 pt blue bar, inset sz(7) from the row's top and bottom.
            // Neon.blue (0.13, 0.80, 1.0): bright cyan; the card, text and glyphs are dark or grey.
            let x = Int((sz(8) + 1) * k)
            func bar(_ c: NSColor?) -> Bool {
                guard let c = c?.usingColorSpace(.sRGB) else { return false }
                return c.blueComponent > 0.75 && c.redComponent < 0.45 && c.blueComponent - c.redComponent > 0.4
            }
            let ys = (0..<rep.pixelsHigh).filter { bar(rep.colorAt(x: x, y: $0)) }
            try save(rep, "829p2-sidebar-keys-last-\(scale)")
            XCTAssertFalse(ys.isEmpty, "the selected last row is on screen at \(scale)")
            let stripTop = (size.height - AgentWindowControls.stripHeight) * k
            XCTAssertLessThanOrEqual(CGFloat(ys.max() ?? .max) + sz(7) * k, stripTop + 1,
                                     "the last row ends above the dir strip at \(scale)")
            win.contentView = nil
            XCTAssertGreaterThan(ink(try render(AgentDirStatusStrip(store: st),
                                                size: CGSize(width: size.width, height: AgentWindowControls.stripHeight),
                                                dark: true)), 10, "the strip shows")
        }
    }

    // MARK: G6-G8: the History detail's buttons hold fixed slots

    @MainActor
    func testAgentWindowHistoryDetailHoldsItsButtonsInFixedSlots() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        var h = record("old-spike", ago: 7200)
        h.agent = DchHistoryRecord.Agent(kind: "claude", sessionID: "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab", name: "spike: agent window")
        let g = record("cdv2", ago: 86_400 * 2)
        let st = store([session("prosper", .working, ago: 40)], history: [h, g])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        m.select(.history(h.id))
        func diffRows(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, from x0: Int) -> [Int] {
            (0..<a.pixelsHigh).filter { y in
                stride(from: x0, to: a.pixelsWide, by: 2).contains { a.colorAt(x: $0, y: y) != b.colorAt(x: $0, y: y) }
            }
        }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            // One size whatever the record's state or the gates: no state moves a neighbour.
            func fit(_ r: DchHistoryRecord, _ status: String? = nil) -> CGSize {
                NSHostingView(rootView: AgentHistoryButtons(store: st, record: r, refusal: status, act: { _ in })).fittingSize
            }
            let base = fit(h)
            XCTAssertEqual(fit(pinned(h)), base, "Pin and Unpin share a slot at \(scale)")
            // Row 1 sets the width, so equal sizes alone miss a re-centred row 2: the Remove pill
            // (dimmed on a pinned record) must keep its right edge when Pin turns into Unpin.
            let un = try render(AgentHistoryButtons(store: st, record: h, act: { _ in }), size: base, dark: true, margin: 0)
            let pi = try render(AgentHistoryButtons(store: st, record: pinned(h), act: { _ in }), size: base, dark: true, margin: 0)
            func rightEdges(_ rep: NSBitmapImageRep) -> [Int] {
                let bg = rep.colorAt(x: 0, y: rep.pixelsHigh - 1)
                return (0..<rep.pixelsHigh).map { y in
                    (0..<rep.pixelsWide).last { rep.colorAt(x: $0, y: y) != bg } ?? -1
                }
            }
            // Rows whose ink reaches past the centre are the Remove pill's (the pin glyphs stay left of it).
            let half = un.pixelsWide / 2
            let (eu, ep) = (rightEdges(un), rightEdges(pi))
            let far = eu.indices.filter { eu[$0] > half || ep[$0] > half }
            XCTAssertFalse(far.isEmpty)
            // 1 px: the dimmed (pinned) capsule's anti-aliased curve; a re-centred row moves it ~10 px.
            XCTAssertLessThanOrEqual(far.map { abs(ep[$0] - eu[$0]) }.max() ?? 0, 1,
                                     "Remove holds its place when Pin turns into Unpin at \(scale)")
            XCTAssertEqual(fit(h, "Not run: Remove from History (unpin it first)"), base, "a status keeps the line's room at \(scale)")
            // At the pane's width a long status wraps: blank, one line and two lines take one height.
            func tall(_ status: String?) -> CGFloat {
                NSHostingView(rootView: AgentHistoryButtons(store: st, record: h, refusal: status, act: { _ in })
                    .frame(width: base.width)).fittingSize.height
            }
            XCTAssertEqual(tall(String(repeating: "Not run: Remove from History (needs dch 1.25.0). ", count: 4)), tall(nil),
                           "the status line reserves its two lines at \(scale)")
            st.controlDch = nil
            XCTAssertEqual(fit(h), base, "every button drawn while the gates refuse at \(scale)")
            st.controlDch = bin([1, 38, 0])
            for (label, size) in [("min", CGSize(width: 640 * scale, height: 420 * scale)),
                                  ("default", CGSize(width: 1000 * scale, height: 680 * scale))] {
                let canvas = CGSize(width: size.width + 24, height: size.height + 24)
                let tag = "\(label)-\(scale)"
                let plain = try render(AgentWindowRootView(model: m), size: size, dark: true)
                try save(plain, "829p2-history-\(tag)")
                XCTAssertEqual(overflow(plain, content: size, canvas: canvas), 0, tag)
                let k = CGFloat(plain.pixelsWide) / canvas.width, x0 = Int((sz(290) + 2) * k)
                st.history = [pinned(h), g]
                let pin = try render(AgentWindowRootView(model: m), size: size, dark: true)
                try save(pin, "829p2-history-pinned-\(tag)")
                XCTAssertEqual(overflow(pin, content: size, canvas: canvas), 0, tag)
                let prow = diffRows(plain, pin, from: x0)
                XCTAssertFalse(prow.isEmpty, "Unpin shows (\(tag))")
                XCTAssertLessThan(CGFloat((prow.max() ?? 0) - (prow.min() ?? 0)) / k, 30 * scale,
                                  "only the Pin/Remove row changed (\(tag))")
                st.history = [h, g]
                st.controlDch = nil
                let off = try render(AgentWindowRootView(model: m), size: size, dark: true)
                try save(off, "829p2-history-gated-\(tag)")
                st.controlDch = bin([1, 38, 0])
                let orow = diffRows(plain, off, from: x0)
                XCTAssertLessThan(CGFloat((orow.max() ?? 0) - (orow.min() ?? 0)) / k, 60 * scale,
                                  "gates off: the two button rows dim in place (\(tag))")
                m.act(.remove, h)
                let ask = try render(AgentWindowRootView(model: m), size: size, dark: true)
                try save(ask, "829p2-history-remove-confirm-\(tag)")
                m.confirm(false)
                XCTAssertEqual(overflow(ask, content: size, canvas: canvas), 0, tag)
                let arow = diffRows(plain, ask, from: x0)
                XCTAssertFalse(arow.isEmpty)
                XCTAssertLessThan(CGFloat(arow.max() ?? 0) / k, size.height * 0.5, "the strip is over the pane's top only (\(tag))")
            }
        }
        XCTAssertTrue(calls.records.isEmpty, "rendering and Cancel ran nothing")
    }
}

extension AgentIslandStore {
    /// Test sugar: the store with a control dch.
    @MainActor
    func with(_ dch: DchCommand.Binary) -> AgentIslandStore {
        controlDch = dch
        return self
    }
}

/// QA #668 F1: a Stop/Kill's held row is display-only and lasts the record slack at most; INFO-5.
extension AgentWindowD1Tests {
    /// The window model of `st` after a window Stop of "a" whose live row then left with no record.
    @MainActor
    private func heldModel(_ st: AgentIslandStore, opened: @escaping (AgentSession) -> Void) throws -> (AgentWindowModel, AgentSession) {
        let m = windowModel(st, opened: opened)
        Calls().wire(m)
        m.setVisible(true)
        let a = try XCTUnwrap(st.sessions.first { $0.name == "a" })
        m.ask(.stop, a)
        m.confirm(true)
        st.sessions = st.sessions.filter { $0.name != "a" }
        return (m, a)
    }

    @MainActor
    func testAgentWindowHeldRowOfAnEndedSessionIsDisplayOnly() throws {
        let st = store([session("a", .idle), session("b", .idle)])
        st.controlDch = bin([1, 38, 0])
        var opened: [AgentSessionKey] = []
        // The interaction goes through a controller over a fake pty: a send that starts would be busy.
        let f = AgentWindowInteractionTests.MessageFake(statuses: ["idle", "working"])
        let c = AgentIslandController()
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: Self.geometry)
        c.autoAllowOn = { false }
        c.after = { _, _ in }
        c.onSessions = { _ in }
        let m = windowModel(st, opened: { opened.append($0.key) })
        m.interaction.controller = c
        m.interaction.pause = { _ in }
        m.interaction.readQueue = { $0() }
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        let a = try XCTUnwrap(st.sessions.first { $0.name == "a" })
        m.select(.live(a.key))
        XCTAssertFalse(m.selectionIsHeld)
        XCTAssertTrue(m.openSelected(), "live: Return opens it")
        XCTAssertEqual(opened, [a.key])
        XCTAssertEqual(m.interaction.session?.key, a.key, "live: the input box is its")
        let detail = AgentDetailView(model: m, transcript: m.transcript, scrolls: false)
        XCTAssertTrue(detail.inputStore === st, "live: the locked input (Restart/Stop text)")
        m.ask(.stop, a)
        m.confirm(true)
        st.sessions = [session("b", .idle)]   // its row left, no record (history off, a failed record write)
        XCTAssertEqual(m.selection, .live(a.key), "held: the pane keeps showing it")
        XCTAssertEqual(m.selectedRow?.session?.key, a.key)
        XCTAssertTrue(m.selectionIsHeld)
        // Return / Open in terminal: nothing runs (`dch -n a` would start a new session named a).
        XCTAssertFalse(m.openSelected(), "Return passes on")
        XCTAssertEqual(opened, [a.key], "the openSession seam ran nothing")
        // Send, Interrupt and the prompt answers: no session to write to.
        XCTAssertNil(m.interaction.session, "the input box follows nothing")
        m.interaction.draft = "hello"
        m.interaction.send()
        m.interaction.interrupt()
        XCTAssertFalse(m.interaction.busy, "nothing started")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(f.lock.withLock { f.says.count + f.keys.count }, 0, "nothing reaches the pty")
        for s in [a, AgentSession(key: a.key, alias: "", activity: 1, state: .working, agents: 0)] {
            m.interaction.follow(nil)
            let pane = AgentInteractionPane(model: m.interaction, session: s, open: {}, ended: true)
            XCTAssertFalse(pane.canSend, "\(s.state)")
            XCTAssertFalse(pane.canInterrupt, "\(s.state)")
            XCTAssertEqual(pane.placeholder, AgentInteractionPane.endedPlaceholder)
        }
        // A typed draft on the idle session (drafts are per followed session): only `ended` keeps Send off.
        let typed = AgentWindowInteraction()
        typed.follow(a)
        typed.draft = "hello"
        XCTAssertFalse(AgentInteractionPane(model: typed, session: a, open: {}, ended: true).canSend)
        XCTAssertTrue(AgentInteractionPane(model: typed, session: a, open: {}, ended: false).canSend, "control")
        // The detail pane builds the plain, ended input (no lock store), never the live locked one.
        XCTAssertNil(detail.inputStore, "held: the plain pane with ended")
        // The "⋯" (and any ask for it): no question, nothing to confirm, the follow stays.
        for verb: AgentWindowVerb in [.restart, .stop, .kill] {
            m.ask(verb, a)
            XCTAssertNil(m.confirming, "\(verb): nothing asked on an ended session")
            m.confirm(true)
        }
        XCTAssertEqual(calls.all.map(\.verb), [.stop], "only the first Stop ran")
        XCTAssertNotNil(m.following, "an ask refused is no manual pick")
        XCTAssertEqual(m.selection, .live(a.key))
        // The header's controls keep their slots (off, never removed).
        let row = try XCTUnwrap(m.selectedRow)
        func height(_ ended: Bool) -> CGFloat {
            NSHostingView(rootView: AgentSessionHeader(row: row, session: a, cwd: "/tmp/p", open: {}, store: st, ended: ended)
                .frame(width: 900)).fittingSize.height
        }
        XCTAssertEqual(height(true), height(false), accuracy: 0.5)
        // The "⋯": no store for the ended row (no items, disabled); the live row's has items.
        func header(_ ended: Bool) -> AgentSessionHeader {
            AgentSessionHeader(row: row, session: a, cwd: "/tmp/p", open: {}, store: st, ended: ended)
        }
        XCTAssertNil(header(true).menuStore, "held: the menu offers nothing")
        XCTAssertTrue(header(false).menuStore === st)
        XCTAssertFalse(AgentWindowControls.menu(a, store: st).isEmpty, "live: Restart/Stop/Kill")
        // Its record lands: the History row, as before.
        st.history = [record("a", ago: 0)]
        XCTAssertEqual(m.selection, .history(a.key))
        XCTAssertFalse(m.selectionIsHeld)
        XCTAssertFalse(m.openSelected())
        XCTAssertEqual(opened, [a.key])
        // A held session whose live row is back (an island restart of that name): live again, opens.
        st.sessions = [a, session("b", .idle)]
        m.select(.live(a.key))
        XCTAssertTrue(m.openSelected())
    }

    @MainActor
    func testAgentWindowHoldLetsGoWhenNoRecordLandsWithinTheSlack() throws {
        XCTAssertEqual(AgentWindowModel.recordSlack, 65)
        var t = Self.now
        let st = store([session("a", .idle), session("b", .idle)])
        st.controlDch = bin([1, 38, 0])
        let (m, a) = try heldModel(st, opened: { _ in })
        defer { m.close() }
        m.now = { t }
        XCTAssertTrue(m.selectionIsHeld)
        t = Self.now + 60
        m.refresh()
        XCTAssertEqual(m.selection, .live(a.key), "inside the slack: held")
        t = Self.now + 66
        m.refresh()
        XCTAssertNil(m.selection, "no record 65 s on: nothing selected, as before Phase 2")
        XCTAssertNil(m.following)
        XCTAssertNil(m.selectedRow)
        XCTAssertFalse(m.selectionIsHeld)
        st.history = [record("a", ago: -66)]
        XCTAssertNil(m.selection, "a record after the hold let go is not followed")

        // A record at 30 s: followed (unchanged).
        t = Self.now
        st.history = []
        st.sessions = [a, session("b", .idle)]
        m.ask(.kill, a)
        m.confirm(true)
        st.sessions = [session("b", .idle)]
        t = Self.now + 30
        st.history = [record("a", ago: -30)]
        XCTAssertEqual(m.selection, .history(a.key))

        // A slow Stop: the slack runs from the row leaving, not from the click.
        t = Self.now
        st.history = []
        st.sessions = [a, session("b", .idle)]
        m.ask(.stop, a)
        m.confirm(true)
        t = Self.now + 100
        st.sessions = [session("b", .idle)]
        XCTAssertEqual(m.selection, .live(a.key), "the row just left: held")
        t = Self.now + 160
        m.refresh()
        XCTAssertEqual(m.selection, .live(a.key), "60 s since it left: held")
        t = Self.now + 166
        m.refresh()
        XCTAssertNil(m.selection, "66 s since it left: let go")
    }

    @MainActor
    func testAgentWindowRemoveQuestionCountsTheOlderUnpinnedRecords() {
        let h = record("h"), other = record("other")
        XCTAssertEqual(AgentWindowControls.removeQuestion(h, in: [h, other, aside("h", ago: 9500, pinned: true)]),
                       "Remove h from History? Resume won't be able to bring it back. Its Claude Code conversation stays on disk.",
                       "no older unpinned record: one record named")
        XCTAssertEqual(AgentWindowControls.removeQuestion(h, in: [h, aside("h", ago: 9000), aside("h", ago: 9500, pinned: true)]),
                       "Remove h and its 1 older record from History? Resume won't be able to bring them back."
                           + " Their Claude Code conversations stay on disk.")
        var g = record("h")
        g.agent = DchHistoryRecord.Agent(kind: "claude", sessionID: "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab")
        XCTAssertEqual(AgentWindowControls.removeQuestion(g, in: [g, aside("h", ago: 9000), aside("h", ago: 9200)]),
                       "Remove h and its 2 older records from History? Resume won't be able to bring them back."
                           + " Their Claude Code conversations stay on disk. (claude --resume 0b7c2f3e-aaaa-bbbb-cccc-0123456789ab)")
    }
}

extension AgentWindowD1Tests {
    /// Hosts `view` in a window that is never shown (never ordered front, never key) and lays it out.
    @MainActor
    private func hosted<V: View>(_ view: V, _ size: CGSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (win, host)
    }

    @MainActor
    private func views<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, t) } }

    /// QA #668 INFO-2/3/4: an ended session's held row reads ended everywhere: the transcript's Open in
    /// terminal is off, the input field neither edits nor reads as editable, the chip says "Ended". No slot moves.
    @MainActor
    func testAgentWindowEndedHeldRowReadsEndedEverywhere() throws {
        let st = store([session("a", .working), session("b", .idle)])
        st.controlDch = bin([1, 38, 0])
        let (m, a) = try heldModel(st, opened: { _ in })
        defer { m.close() }
        XCTAssertTrue(m.selectionIsHeld)
        let row = try XCTUnwrap(m.selectedRow)
        // INFO-4: the header's chip says Ended, not the last live state; its width never moves.
        func header(_ ended: Bool) -> AgentSessionHeader {
            AgentSessionHeader(row: row, session: a, cwd: "/tmp/p", open: {}, store: st, ended: ended)
        }
        XCTAssertEqual(header(true).stateChip.label, AgentStateChip.endedLabel)
        XCTAssertEqual(AgentStateChip.endedLabel, "Ended")
        XCTAssertEqual(header(false).stateChip.label, "Working", "live: the state")
        func width(_ c: AgentStateChip) -> CGFloat { NSHostingView(rootView: c).fittingSize.width }
        let slot = width(AgentStateChip(state: .working))
        for s in AgentState.allCases {
            XCTAssertEqual(AgentStateChip(state: s).label, s.label)
            XCTAssertEqual(AgentStateChip(state: s, ended: true).label, "Ended", "\(s)")
            XCTAssertEqual(width(AgentStateChip(state: s, ended: true)), slot, accuracy: 0.5, "\(s): the slot stays")
        }
        // INFO-2: the terminal-first state's Open in terminal: off for an ended session, on for a live one.
        XCTAssertFalse(TerminalFirstView(reason: "r", openTerminal: {}, ended: true).openEnabled, "ended: off")
        XCTAssertTrue(TerminalFirstView(reason: "r", openTerminal: {}).openEnabled, "live: on")
        // Through the transcript view (a fresh model is terminal-first, "No session selected"): only the
        // button dims, so the ended render differs from the live one, and two live renders match.
        func render(_ ended: Bool) throws -> Data {
            let r = ImageRenderer(content: AgentTranscriptView(model: AgentTranscriptModel(), scrolls: false, openTerminal: {},
                                                               ownsLifecycle: false, ended: ended)
                .frame(width: 520).background(Neon.bgBottom).environment(\.colorScheme, .dark))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage)
            return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        }
        XCTAssertEqual(try render(false), try render(false), "control: a render is stable")
        XCTAssertNotEqual(try render(true), try render(false), "ended: the button draws dimmed")
        // INFO-3: the input field: not editable (nor selectable) when ended, in the same slot.
        func field(_ ended: Bool) throws -> (AgentComposerTextView, CGFloat) {
            let i = AgentWindowInteraction()
            let (win, host) = hosted(AgentInteractionPane(model: i, session: a, open: {}, ended: ended).frame(width: 600),
                                     CGSize(width: 600, height: 200))
            defer { win.close() }
            let tv = try XCTUnwrap(views(host, AgentComposerTextView.self).first)
            return (tv, host.fittingSize.height)
        }
        let (dead, deadHeight) = try field(true)
        let (live, liveHeight) = try field(false)
        XCTAssertFalse(dead.isEditable, "ended: typing is dropped, so the field takes none")
        XCTAssertFalse(dead.isSelectable)
        XCTAssertTrue(live.isEditable, "live: it edits")
        XCTAssertEqual(deadHeight, liveHeight, accuracy: 0.5, "the pane keeps its size")
    }
}
