import Foundation
import XCTest
@testable import ProsperApp

/// #1862: window.nextNeedsYou on the window model's own seams (the AgentWindowCommandJTests setup: fake store, a layouts
/// suite in memory, no window shown, no dch). The window is never opened by the command.
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
        let m = base.windowModel(st, layouts: d)
        defer { m.close() }
        m.paneArea = AgentWindowD1Tests.wideArea
        m.runtimes.values.forEach { $0.transcript.taskStoreDirectory = { _ in nil } }
        m.setLayoutEditing(false)
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
            let c = try ControlNav.nextNeedsYou()
            XCTAssertEqual(focusedName(m), "api-qa")
            XCTAssertEqual(c.result, .string("api-qa"))
            c.undo?()
            XCTAssertEqual(m.layout.id, a.id)
            XCTAssertEqual(focusedName(m), "api", "undo puts the focused pane back")

            st.sessions = [base.session("api", .idle), base.session("api-qa", .idle), base.session("web", .blocked)]
            let d = try ControlNav.nextNeedsYou()
            XCTAssertEqual(m.layout.id, b.id, "web is only in layout B: switched")
            XCTAssertEqual(focusedName(m), "web")
            d.undo?()
            XCTAssertEqual(m.layout.id, a.id, "undo switches back")
            XCTAssertEqual(m.layout.focused, a.focused)

            st.sessions = [base.session("api", .idle), base.session("api-qa", .idle), base.session("web", .idle)]
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
            if m.newSession != nil {
                refused(try ControlNav.nextNeedsYou(), ControlSessions.formOpen)
                m.cancelNewSession()
            }
            AgentPaneLayout.splitsEnabled = false
            refused(try ControlNav.nextNeedsYou(), ControlLayouts.off)
        }
    }
}
