import AppKit
import XCTest
@testable import ProsperApp

/// #1784 (operator 2026-11-20, "Hide for 10 min"; supersedes #797's teardown on close for this window): a close hides the
/// Agent Sessions window for AgentsWindow.hideGrace; a show inside the grace presents the same window and model with no
/// rebuild; past the grace (the timer fired by the row) today's teardown runs. While hidden: one timer, no age clock, no
/// sidebar rebuild on a store publish. Never on screen: a fresh AgentsWindow whose present and dismissed are recorders.
extension AgentWindowD1Tests {
    @MainActor
    final class HideRig {
        let w = AgentsWindow()
        let c = AgentIslandController()
        var built = 0, presented = 0, dismissed = 0
        init(_ st: AgentIslandStore, real: Bool = false) {
            c.io = AgentWindowInteractionTests.FormSim(.plain("")).io
            c.showsPanel = false
            c.store = st
            c.autoAllowOn = { false }
            c.after = { _, _ in }
            c.onSessions = { _ in }
            let c = c
            w.island = { c }
            // Weak: the row's teardown block closes a window left open after the rig is gone.
            w.present = { [weak self] _ in self?.presented += 1 }
            w.dismissed = { [weak self] _ in self?.dismissed += 1 }
            w.build = { [weak self] m in
                self?.built += 1
                if real { return AgentsWindow.makeWindow(m, autosave: nil) }
                let win = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                                         backing: .buffered, defer: true)
                win.isReleasedWhenClosed = false
                win.model = m
                return win
            }
        }
        /// The model show() built, its outside effects off (the terminal is the recorder, set by the row).
        func model() throws -> AgentWindowModel {
            let m = try XCTUnwrap(w.model)
            m.onVisible = { _ in }
            m.ageInterval = 3600
            return m
        }
    }

    @MainActor
    func testAgentsWindowCloseHidesAndAShowInTheGraceBringsTheSameWindowBack() throws {
        let a = session("api", .working, ago: 30), b = session("api-qa", .idle, ago: 90)
        let st = store([a, b])
        let r = HideRig(st)
        let w = r.w
        addTeardownBlock { @MainActor in w.window?.close(); w.grace?.fire() }
        w.show()
        let win = try XCTUnwrap(w.window)
        let m = try r.model()
        let t = fakeTerminal(m)
        m.setVisible(true)   // the occlusion observer's call for a window on screen (this one never is)
        let (refreshes, builds) = (m.refreshes, m.sectionBuilds)
        XCTAssertGreaterThan(builds, 0, "the first visible refresh builds the sidebar")
        XCTAssertTrue(m.clock != nil)

        win.close()
        let g = try XCTUnwrap(w.grace, "one grace timer while hidden")
        XCTAssertTrue(g.isValid)
        XCTAssertEqual(AgentsWindow.hideGrace, 600, "the operator's 10 minutes")
        XCTAssertEqual(g.fireDate.timeIntervalSinceNow, AgentsWindow.hideGrace, accuracy: 5)
        XCTAssertFalse(w.isOpen, "closed for the person")
        XCTAssertTrue(w.window === win && w.model === m, "kept")
        XCTAssertFalse(m.visible, "stopped as an occluded window")
        XCTAssertTrue(m.clock == nil, "no age clock while hidden")
        XCTAssertEqual(r.dismissed, 1, "the Dock lets go at the hide")
        XCTAssertNotNil(r.c.onStoreChanged, "the island link stays (its refresh is skipped while hidden)")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: win)
        XCTAssertTrue(w.grace === g, "a second willClose keeps the one timer")
        XCTAssertEqual(r.dismissed, 1)

        // Hidden: the store's publishes rebuild nothing and start no terminal.
        let spawns = t.spawned().count
        XCTAssertTrue(m.terminal.key == nil, "no terminal client while hidden")
        st.sessions = [a]
        st.sessions = [a, b]
        XCTAssertEqual(m.refreshes, refreshes, "no sidebar refresh while hidden")
        XCTAssertEqual(m.sectionBuilds, builds)
        XCTAssertEqual(t.spawned().count, spawns, "no terminal while hidden")
        XCTAssertTrue(m.clock == nil)

        w.show()
        XCTAssertEqual(r.built, 1, "no second window")
        XCTAssertEqual(r.presented, 2, "the kept window presented")
        XCTAssertTrue(w.window === win && w.model === m, "the same window and model")
        XCTAssertTrue(w.grace == nil)
        XCTAssertFalse(g.isValid, "the show ended the grace timer")
        XCTAssertTrue(w.isOpen)
        m.setVisible(true)   // the occlusion observer's call once on screen
        XCTAssertEqual(m.sectionBuilds, builds, "an unchanged store: the sections recompute 0 times")
        XCTAssertGreaterThan(m.refreshes, refreshes, "the store is read again")
    }

    @MainActor
    func testAgentsWindowGraceEndTearsDownAndLeavesNoTimer() throws {
        let st = store([session("api", .working, ago: 30)])
        let r = HideRig(st)
        let w = r.w
        addTeardownBlock { @MainActor in w.window?.close(); w.grace?.fire() }
        w.show()
        let win = try XCTUnwrap(w.window)
        let m = try r.model()
        _ = fakeTerminal(m)
        m.setVisible(true)
        let builds = m.sectionBuilds
        win.close()
        let g = try XCTUnwrap(w.grace)
        g.fire()   // the grace's end
        XCTAssertTrue(w.grace == nil, "no timer after the teardown")
        XCTAssertFalse(g.isValid)
        XCTAssertTrue(w.model == nil && w.window == nil, "today's teardown")
        XCTAssertNil(r.c.onStoreChanged)
        XCTAssertNil(r.c.onHoldChanged)
        XCTAssertEqual(r.dismissed, 1, "the Dock was told once, at the hide")
        st.sessions = [session("api-qa", .idle)]
        XCTAssertEqual(m.sectionBuilds, builds, "a closed model rebuilds nothing")
        w.show()
        XCTAssertEqual(r.built, 2, "past the grace a show builds again")
        XCTAssertTrue(w.model !== m)
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    /// The operator's "light on memory": phys_footprint of a real window (AgentsWindow.makeWindow, never shown) with 60
    /// sidebar rows, laid out: before show, hidden after the close, and after the grace's teardown. One warm-up cycle first
    /// so the process's one-time costs (SwiftUI metadata, fonts) are not counted. Printed as HIDE1784 for the report.
    @MainActor
    func testAgentsWindowHiddenWindowMemoryIsMeasured() throws {
        _ = NSApplication.shared
        var list: [AgentSession] = []
        for i in 0..<60 {
            let state: AgentState = i % 3 == 0 ? .working : .idle
            list.append(session("api-\(i)", state, ago: TimeInterval(60 + i * 7)))
        }
        let st = store(list)
        let r = HideRig(st, real: true)
        let w = r.w
        addTeardownBlock { @MainActor in w.window?.close(); w.grace?.fire() }
        func cycle() throws -> (base: Int, hidden: Int, gone: Int, rows: Int) {
            let base = AgentTerminalKeepTests.footprint()
            var rows = 0
            try autoreleasepool { () throws -> Void in
                w.show()
                let m = try r.model()
                _ = fakeTerminal(m)
                m.setVisible(true)
                let host = try XCTUnwrap(w.window?.contentView)
                for _ in 0..<3 { settle(host) }
                rows = m.sections.map(\.rows.count).reduce(0, +)
                w.window?.close()
                settle(host)
            }
            let hidden = AgentTerminalKeepTests.footprint()
            let g = try XCTUnwrap(w.grace)
            autoreleasepool { g.fire() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))   // the teardown's async contentViewController = nil
            return (base, hidden, AgentTerminalKeepTests.footprint(), rows)
        }
        _ = try cycle()
        let m = try cycle()
        let kept = max(0, m.hidden - m.base), freed = max(0, m.hidden - m.gone)
        print("HIDE1784 footprint before show \(m.base) hidden \(m.hidden) after teardown \(m.gone);"
              + " kept by the hidden window \(kept) bytes (\(kept >> 10) KiB), freed by the teardown \(freed) bytes"
              + " (\(freed >> 10) KiB), rows \(m.rows), scale \(ThemeRuntime.scale)")
        XCTAssertGreaterThanOrEqual(m.rows, 60, "every session has its row")
        XCTAssertEqual(r.built, 2)
        XCTAssertTrue(w.grace == nil && w.window == nil)
        XCTAssertLessThan(kept, 256 << 20, "a hidden window is bounded")
    }
}
