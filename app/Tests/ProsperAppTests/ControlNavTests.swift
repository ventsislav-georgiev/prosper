import Foundation
import XCTest
@testable import ProsperApp

/// #1862: window.nextNeedsYou on the window model's own seams (the AgentWindowCommandJTests setup: fake store, a layouts
/// suite in memory, no window shown, no dch). The window is never opened by the command. The model is made visible as
/// jumpModel does: the sidebar's Needs you rows (what ⌘J reads) publish only on a visible refresh.
final class ControlNavTests: XCTestCase {
    let base = AgentWindowD1Tests()

    /// A model over layout A (api focused, api-qa) and B (web), with `states` for api, api-qa, web.
    @MainActor
    func withModel(_ states: (AgentState, AgentState, AgentState), body: (AgentWindowModel, AgentIslandStore, PaneLayout, PaneLayout) throws -> Void) throws {
        let saved = (ControlSessions.model, AgentPaneLayout.splitsEnabled)
        defer { (ControlSessions.model, AgentPaneLayout.splitsEnabled) = saved }
        AgentPaneLayout.splitsEnabled = true
        let a = base.paneLayout([base.paneTarget("api"), base.paneTarget("api-qa")]), b = base.paneLayout([base.paneTarget("web")])
        let d = base.layoutSuite()
        d.set(try PaneLayoutStore(layouts: [a, b], active: a.id, mru: [a.id]).encode(), forKey: "agentWindowLayouts")
        let st = base.store([base.session("api", states.0), base.session("api-qa", states.1), base.session("web", states.2)])
        st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])   // the form's gate (never run)
        let m = base.windowModel(st, layouts: d)
        defer { m.close() }
        m.paneArea = AgentWindowD1Tests.wideArea
        m.runtimes.values.forEach { $0.transcript.taskStoreDirectory = { _ in nil } }
        m.setLayoutEditing(false)
        m.setVisible(true)   // the model flag only (no window exists): sections publish on a visible refresh
        ControlSessions.model = { m }
        try body(m, st, a, b)
    }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    @MainActor
    func focusedName(_ m: AgentWindowModel) -> String? {
        guard case let .session(_, n)? = m.layout.panes.first(where: { $0.id == m.layout.focused })?.target else { return nil }
        return n
    }

    /// The titles of the sidebar's Needs you rows, the list AgentWindowModel.nextNeedsYou walks.
    @MainActor
    func needsYou(_ m: AgentWindowModel) -> [String] {
        m.sections.first { $0.id == AgentSidebar.needsYouTitle }?.rows.map(\.title) ?? []
    }

    @MainActor
    func testRegisteredAsAChangeWithNoArgs() {
        var r = ControlRegistry()
        ControlRegistry.registerNav(&r)
        XCTAssertEqual(r.commands.keys.sorted(), ["window.nextNeedsYou"])
        XCTAssertEqual(r.commands["window.nextNeedsYou"]?.mutates, true)
        XCTAssertEqual(r.commands["window.nextNeedsYou"]?.args.count, 0)
    }

    /// In the active layout: the blocked session's pane is focused; undo puts the focus back. Another layout: switched to
    /// and undone. Nothing else needing you: refused, nothing changed.
    @MainActor
    func testJumpsWithinAndAcrossLayoutsAndUndoes() throws {
        try withModel((.idle, .blocked, .idle)) { m, st, a, b in
            XCTAssertEqual(focusedName(m), "api")
            XCTAssertEqual(needsYou(m), ["api-qa"], "the rows ⌘J reads are published")
            let c = try ControlNav.nextNeedsYou()
            XCTAssertEqual(focusedName(m), "api-qa")
            XCTAssertEqual(c.result, .string("api-qa"))
            c.undo?()
            XCTAssertEqual(m.layout.id, a.id)
            XCTAssertEqual(focusedName(m), "api", "undo puts the focused pane back")

            st.sessions = [base.session("api", .idle), base.session("api-qa", .idle), base.session("web", .blocked)]
            XCTAssertEqual(needsYou(m), ["web"])
            let d = try ControlNav.nextNeedsYou()
            XCTAssertEqual(m.layout.id, b.id, "web is only in layout B: switched")
            XCTAssertEqual(focusedName(m), "web")
            d.undo?()
            XCTAssertEqual(m.layout.id, a.id, "undo switches back")
            XCTAssertEqual(m.layout.focused, a.focused)

            st.sessions = [base.session("api", .idle), base.session("api-qa", .idle), base.session("web", .idle)]
            XCTAssertEqual(needsYou(m), [])
            let before = m.layout, writes = m.layoutWrites
            refused(try ControlNav.nextNeedsYou(), ControlNav.nobody)
            XCTAssertEqual(m.layout, before)
            XCTAssertEqual(m.layoutWrites, writes)
        }
    }

    /// No window model: nothing is opened (showWindow never runs); the split gate off and the open New session form refuse.
    @MainActor
    func testRefusesWithNoWindowGateOffAndOpenForm() throws {
        let savedShow = ControlSessions.showWindow
        var shown = 0
        ControlSessions.showWindow = { shown += 1; return nil }
        addTeardownBlock { @MainActor in ControlSessions.showWindow = savedShow }
        try withModel((.idle, .blocked, .idle)) { m, _, _, _ in
            ControlSessions.model = { nil }
            refused(try ControlNav.nextNeedsYou(), ControlNav.notOpen)
            XCTAssertEqual(shown, 0, "the window is never opened")
            ControlSessions.model = { m }
            m.openNewSession()
            XCTAssertTrue(m.newSession != nil, "the form is open")
            refused(try ControlNav.nextNeedsYou(), ControlSessions.formOpen)
            m.cancelNewSession()
            AgentPaneLayout.splitsEnabled = false
            refused(try ControlNav.nextNeedsYou(), ControlLayouts.off)
        }
    }

    /// n171: a New session form the person opened after the jump stays open: the undo does nothing meanwhile.
    @MainActor
    func testUndoDoesNothingWhileAFormIsOpen() throws {
        try withModel((.idle, .blocked, .idle)) { m, _, _, _ in
            let c = try ControlNav.nextNeedsYou()
            XCTAssertEqual(focusedName(m), "api-qa")
            m.openNewSession()
            XCTAssertTrue(m.newSession != nil, "the form is open")
            c.undo?()
            XCTAssertTrue(m.newSession != nil, "the form stays open")
            XCTAssertEqual(focusedName(m), "api-qa", "nothing moved")
            m.cancelNewSession()
            c.undo?()
            XCTAssertEqual(focusedName(m), "api", "with the form gone the undo works")
        }
    }

    /// n170: the agent's jump shows and focuses the pane but the keys stay where they are (sessions.focus's rule): from
    /// api's terminal they never land in web's (the old pane gives them up as on any focus switch); from the sidebar they
    /// stay there; the undo moves none. The person's own ⌘J (the model's nextNeedsYou) still moves them into web's
    /// terminal. Two fake-client terminals in a never-shown window (AgentWindowPaneFocusTests' setup).
    @MainActor
    func testAgentJumpLeavesTheKeysAndTheHumansKeyMovesThem() throws {
        try base.withPaneMenu(true) {
            let saved = ControlSessions.model
            defer { ControlSessions.model = saved }
            let m = base.windowModel(base.store([base.session("api", .idle), base.session("web", .blocked)]), layouts: base.layoutSuite())
            let log = base.splitTerminals(m)
            m.setVisible(true)
            defer { m.close() }
            m.adopt(base.paneLayout([base.paneTarget("api"), base.paneTarget("web")]))
            ControlSessions.model = { m }
            let api = m.layout.focused, web = try XCTUnwrap(m.layout.order.last)
            let (win, host) = base.focusWindow(m)
            defer { win.close() }
            base.endRests(log)
            let terminals = { [api, web].compactMap { m.runtimes[$0]?.terminal } }
            base.paneFocusSettle(host) { terminals().count == 2 && terminals().allSatisfy { $0.phase == .live && $0.view?.window === win } }
            let apiView = try XCTUnwrap(m.runtimes[api]?.terminal?.view), webView = try XCTUnwrap(m.runtimes[web]?.terminal?.view)
            XCTAssertEqual(needsYou(m), ["web"])

            // The person types in api's terminal.
            XCTAssertTrue(m.focusSelection())
            base.paneFocusSettle(host) { win.firstResponder === apiView }
            XCTAssertTrue(win.firstResponder === apiView, "the keys in api's terminal")
            let keys = m.keyFocus
            let c = try ControlNav.nextNeedsYou()
            base.paneFocusSettle(host) { false }
            XCTAssertEqual(m.layout.focused, web, "web shown and focused")
            XCTAssertFalse(win.firstResponder === webView, "the agent's jump never puts the keys in another session's terminal")
            XCTAssertEqual(m.keyFocus, keys, "keyFocus left as it was")
            XCTAssertFalse(m.keysStay)
            c.undo?()
            base.paneFocusSettle(host) { false }
            XCTAssertEqual(m.layout.focused, api)
            XCTAssertFalse(win.firstResponder === apiView || win.firstResponder === webView, "the undo moves no keys")

            // The keys in the sidebar: they stay there across the jump and its undo.
            base.sidebarKeys(win)
            let before = win.firstResponder
            let d = try ControlNav.nextNeedsYou()
            base.paneFocusSettle(host) { false }
            XCTAssertEqual(m.layout.focused, web)
            XCTAssertTrue(win.firstResponder === before && win.sidebarFocused, "the sidebar keeps the keys")
            d.undo?()
            base.paneFocusSettle(host) { false }
            XCTAssertTrue(win.firstResponder === before && win.sidebarFocused, "and keeps them across the undo")

            // The person's ⌘J moves the keys into web's terminal, as before.
            XCTAssertTrue(m.nextNeedsYou())
            base.paneFocusSettle(host) { win.firstResponder === webView }
            XCTAssertTrue(win.firstResponder === webView, "the human key moves the keys")
            XCTAssertFalse(win.isVisible, "never shown")
            XCTAssertFalse(win.isKeyWindow, "never key")
        }
    }
}
