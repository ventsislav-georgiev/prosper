import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1924: a pane History card's Resume and Resume (no message) follow the session they start: once it lists, that pane
/// shows it and the keys go into its terminal, once. The sidebar's context menu (act alone) moves nothing; a person who
/// moved on before it listed keeps where they are. Offscreen only: the island's verbs are recording seams (no dch), the
/// terminal runs on a fake client, the window is never shown, ordered in or made key, and key events are built values.
extension AgentWindowD1Tests {
    @MainActor
    func cardResumeModel(_ history: [DchHistoryRecord]) -> (AgentWindowModel, AgentIslandStore, () -> [AgentWindowVerb]) {
        let st = store([], history: history)
        st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 38, 0])
        let m = windowModel(st)
        var ran: [AgentWindowVerb] = []
        m.resume = { _ in ran.append(.resume) }
        m.resumeNoMessage = { _ in ran.append(.resumeNoMessage) }
        return (m, st, { ran })
    }

    /// Both card verbs: the pane that showed api's record shows the live api, its terminal the first responder (the sidebar
    /// had the keys), one-shot. Red at base: no landing for a resume, the pane kept the record's target (its row hidden
    /// once api lists: an empty pane) and the keys stayed in the sidebar.
    @MainActor
    func testAgentWindowCardResumeLandsTheSessionInThePaneWithTheKeys() throws {
        try withModePref {
            for verb: AgentWindowVerb in [.resume, .resumeNoMessage] {
                let h = record("api")
                let (m, st, ran) = cardResumeModel([h])
                _ = fakeTerminal(m)
                m.setVisible(true)
                defer { m.close() }
                let (win, host) = focusWindow(m)
                defer { win.close() }
                m.select(.history(h.id))
                let pane = m.layout.focused
                sidebarKeys(win)
                m.actInPane(verb, h)
                XCTAssertEqual(ran(), [verb], "\(verb): the island's verb, once")
                XCTAssertEqual(m.pendingResume?.key, h.key)
                m.refresh()
                XCTAssertEqual(m.selection, .history(h.id), "\(verb): not listed yet, nothing moves")
                st.sessions = [mapped("api")]
                settle(host)
                XCTAssertEqual(m.layout.focused, pane, "\(verb): the same pane")
                XCTAssertEqual(m.focusedTarget, paneTarget("api"), "\(verb): it shows the resumed session")
                XCTAssertEqual(m.selection, .live(h.key))
                XCTAssertTrue(m.terminal.view != nil && win.firstResponder === m.terminal.view, "\(verb): the keys in its terminal")
                XCTAssertFalse(win.sidebarFocused, "\(verb): #845: the sidebar stands down")
                XCTAssertTrue(m.pendingResume?.key == nil, "\(verb): one-shot")
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }

    /// The sidebar row's context menu runs act() alone (today's behaviour, and the card's before #1924): nothing armed, and
    /// when api lists the selection and the keys stay where they were.
    @MainActor
    func testAgentWindowCardResumeSidebarMenuResumeMovesNothing() throws {
        for verb: AgentWindowVerb in [.resume, .resumeNoMessage] {
            let h = record("api")
            let (m, st, ran) = cardResumeModel([h])
            m.setVisible(true)
            defer { m.close() }
            m.act(verb, h)
            XCTAssertEqual(ran(), [verb])
            XCTAssertTrue(m.pendingResume?.key == nil, "\(verb): the menu arms no follow")
            st.sessions = [mapped("api")]
            XCTAssertNotEqual(m.selection, .live(h.key), "\(verb): the pane does not take the session")
            XCTAssertFalse(m.terminal.focusPending, "\(verb): no focus asked")
        }
    }

    /// The person moved on before api listed: a pick (even back to the same record), a sidebar mouse-down, a key typed, the
    /// window no longer key, another target in the pane (a pick the model made), a hidden window. Nothing is taken.
    @MainActor
    func testAgentWindowCardResumeMovedOnBeforeItListsTakesNothing() throws {
        for how in ["pick", "sidebar", "key", "resign", "target", "hidden"] {
            let h = record("api"), g = record("other", ago: 7200)
            let (m, st, _) = cardResumeModel([h, g])
            m.setVisible(true)
            defer { m.close() }
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                     backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.model = m
            win.raise = { _ in }   // QA 1092's belt: the real makeKeyAndOrderFront never runs (a key down asks none anyway)
            defer { win.close() }
            m.select(.history(h.id))
            m.actInPane(.resume, h)
            XCTAssertEqual(m.pendingResume?.key, h.key, how)
            switch how {
            case "pick": m.select(.history(g.id)); m.select(.history(h.id))
            case "sidebar": m.dropPendingFocus()
            case "key":
                win.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: win.windowNumber, context: nil, characters: "x",
                                               charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!)
            case "resign": AgentsNSWindow.resignedKey(m)
            case "target": m.select(.history(g.id), manual: false)
            default: m.setVisible(false); m.setVisible(true)
            }
            st.sessions = [mapped("api")]
            XCTAssertNotEqual(m.selection, .live(h.key), "\(how): the pane stays as the person left it")
            XCTAssertFalse(m.terminal.focusPending, "\(how): no focus asked")
            XCTAssertTrue(m.pendingResume?.key == nil, "\(how): dropped")
        }
    }

    /// Two panes (gate on): Resume on the first pane's card, then the second pane focused before api lists: nothing lands,
    /// the second pane keeps the focus and api goes into no pane.
    @MainActor
    func testAgentWindowCardResumeAnotherPaneFocusedTakesNothing() throws {
        try withPaneMenu(true) {
            let h = record("api")
            let st = store([session("web", .idle)], history: [h])
            st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 38, 0])
            let m = windowModel(st, layouts: layoutSuite())
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([nil, paneTarget("web")]))
            let second = try XCTUnwrap(m.layout.order.last)
            m.select(.history(h.id))
            XCTAssertNotEqual(m.layout.focused, second)
            m.actInPane(.resume, h)
            XCTAssertEqual(m.pendingResume?.key, h.key)
            XCTAssertTrue(m.perform(.cycle(1)))
            XCTAssertEqual(m.layout.focused, second)
            st.sessions = [session("web", .idle), session("api", .idle)]
            XCTAssertEqual(m.layout.focused, second, "the focus stays where the person put it")
            XCTAssertFalse(m.layout.panes.contains { $0.target == paneTarget("api") }, "api goes into no pane")
            XCTAssertTrue(m.pendingResume?.key == nil, "dropped")
        }
    }

    /// Nothing runs, nothing is armed: a closed gate (no control dch), another machine's record (#1324: never attached).
    @MainActor
    func testAgentWindowCardResumeArmsNothingWhenNothingRunsHere() throws {
        let h = record("api")
        let (m, st, _) = cardResumeModel([h])
        m.setVisible(true)
        defer { m.close() }
        st.controlDch = nil
        m.actInPane(.resume, h)
        XCTAssertTrue(m.pendingResume?.key == nil, "gate closed")
        st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 38, 0])
        var far = DchHistoryRecord(key: AgentSessionKey(dir: "@host-a", name: "api"))
        far.ended = Self.now - 3600
        m.actInPane(.resumeNoMessage, far)
        XCTAssertTrue(m.pendingResume?.key == nil, "another machine's record")
    }

    /// #1935: a resume that did not start (the island's false: a busy row or a closed gate) arms nothing; a start that fails
    /// later drops what it armed (only its own record's); and a sidebar-menu resume of the record afterwards moves no focus
    /// when it lists. Old lines that make it red: no `resumeStarted` in actInPane's guard (busy armed), no `resumeFailed`
    /// (the failure kept it), `pendingResume?.record == r.id` dropped (a stranger's failure took it).
    @MainActor
    func testAgentWindowCardResumeBusyOrFailedResumeLeavesNothingArmed() throws {
        let h = record("api"), g = record("other", ago: 7200)
        let (m, st, _) = cardResumeModel([h, g])
        m.setVisible(true)
        defer { m.close() }
        // Busy: the island started nothing.
        m.resume = { [unowned m] _ in m.resumeStarted = false }
        m.actInPane(.resume, h)
        XCTAssertTrue(m.pendingResume?.key == nil, "busy: nothing armed")
        // Started, then another record's failure: kept; its own failure: dropped.
        m.resume = { _ in }
        m.actInPane(.resume, h)
        XCTAssertEqual(m.pendingResume?.key, h.key)
        m.resumeFailed(g)
        XCTAssertEqual(m.pendingResume?.key, h.key, "another record's failure leaves it")
        m.resumeFailed(h)
        XCTAssertTrue(m.pendingResume?.key == nil, "its own failure: dropped")
        // A later sidebar-menu resume of the same record, and api listing: no focus moves.
        m.act(.resume, h)
        st.sessions = [mapped("api")]
        XCTAssertNotEqual(m.selection, .live(h.key), "the menu never follows")
        XCTAssertFalse(m.terminal.focusPending, "no focus asked")
    }

    /// #1935: a refusal the window left for the record's row (nothing ran) arms nothing. Old line: no
    /// `refusalText(.history(r.id)) == nil` in actInPane's guard.
    @MainActor
    func testAgentWindowCardResumeARefusedResumeArmsNothing() throws {
        let h = record("api")
        let (m, _, _) = cardResumeModel([h])
        m.setVisible(true)
        defer { m.close() }
        m.resume = { [unowned m] _ in m.refusal = AgentWindowRefusal(id: .history(h.id), text: "refused") }
        m.actInPane(.resume, h)
        XCTAssertEqual(m.refusalText(.history(h.id)), "refused")
        XCTAssertTrue(m.pendingResume?.key == nil, "refused: nothing armed")
    }

    /// #1935 (t1): the History card's own Resume and Resume (no message) pills go through actInPane: the island's verb ran
    /// once and the follow is armed. Offscreen: the pills are read from the built view values and their actions called.
    /// Old line: `act: { model.actInPane($0, r) }` as `model.act($0, r)` (the verb ran, nothing armed).
    @MainActor
    func testAgentWindowCardResumePillsArmTheFollow() throws {
        for (title, verb) in [(AgentIsland.resumeLabel, AgentWindowVerb.resume),
                              (AgentIsland.resumeNoMessageLabel, .resumeNoMessage)] {
            let h = record("api")
            let (m, _, ran) = cardResumeModel([h])
            m.setVisible(true)
            defer { m.close() }
            m.select(.history(h.id))
            let view = AgentPaneArea(model: m, scrolls: false).pane(m.layout.focused, compact: false)
            let root: Any = try XCTUnwrap(paneRiderFind(view, AgentDetailView.self), "a detail view").body
            let card = try XCTUnwrap(paneRiderFind(root, AgentHistoryDetail.self), "a History card")
            let buttons = try XCTUnwrap(paneRiderFind(card.body, AgentHistoryButtons.self), "its buttons")
            let pill = try XCTUnwrap(emptyPanePills(buttons.body).first { $0.title == title }, title)
            XCTAssertTrue(pill.enabled)
            pill.action()
            XCTAssertEqual(ran(), [verb], "\(verb): the island's verb, once")
            XCTAssertEqual(m.pendingResume?.key, h.key, "\(verb): the card's pill armed the follow")
        }
    }
}
