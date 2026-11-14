import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

/// #831 B1 step 4 (spec 4.2, 5.1, 9.2, 14.2 R1.1 / R6.8, R1193-4): the pane area drawn from the model's frames. Offscreen
/// only: every view is hosted in a window never ordered in, no event is posted; the split gate is saved, set and restored
/// by the rows that need two panes (15.0); the Transcript-mode list is saved and restored around each row.
extension AgentWindowD1Tests {
    /// Every pane part's frame by "<part> <pane index in tree order>", from a fresh never-shown window at `size`.
    final class PaneProbeBox { var seen: [String: CGRect] = [:] }

    @MainActor
    func paneSnapshot(_ m: AgentWindowModel, _ size: CGSize) -> [String: CGRect] {
        let box = PaneProbeBox()
        let order = m.layout.order
        AgentPaneArea.probe = { kind, pane, r in box.seen["\(kind) \(order.firstIndex(of: pane) ?? -1)"] = r }
        defer { AgentPaneArea.probe = nil }
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        settle(host)
        XCTAssertFalse(win.isVisible, "never on screen")
        win.contentView = nil
        win.close()
        return box.seen
    }

    func assertSame(_ a: CGRect?, _ b: CGRect?, _ why: String, line: UInt = #line) {
        guard let a, let b else { return XCTFail("missing frame (\(why))", line: line) }
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 0.5, "\(why): \(a) vs \(b)", line: line)
        }
    }

    /// Transcript mode for these names (a live session opens in Terminal, #822); returns what puts the list back.
    func transcriptMode(_ names: [String]) -> () -> Void {
        let saved = Preferences.agentWindowTranscriptSessions
        Preferences.agentWindowTranscriptSessions = names.map { "/tmp/dch-test\t\($0)" }
        return { Preferences.agentWindowTranscriptSessions = saved }
    }

    /// R1193-4: the pane area's size reaches `paneArea` (the detail column: the window less the sidebar and its line);
    /// a new size reaches it once; the same size again changes nothing and publishes nothing.
    @MainActor
    func testAgentWindowPaneAreaSizeReachesTheModelOncePerSize() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let st = store([session("api", .idle)])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.paneArea, .zero, "nothing drawn yet")
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.borderless],
                           backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 680)
        win.contentView = host
        settle(host)
        XCTAssertEqual(m.paneArea.width, 1000 - sz(290) - 1, accuracy: 0.5)
        XCTAssertEqual(m.paneArea.height, 680, accuracy: 0.5)
        let changes = m.paneAreaChanges
        XCTAssertGreaterThanOrEqual(changes, 1)
        var sends = 0
        let sink = m.objectWillChange.sink { _ in sends += 1 }
        defer { sink.cancel() }
        let same = m.paneArea
        m.paneArea = same
        settle(host)
        XCTAssertEqual(m.paneAreaChanges, changes, "the same size: no change, no follow")
        XCTAssertEqual(sends, 0, "the same size publishes nothing")
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 700)
        settle(host)
        XCTAssertEqual(m.paneArea.width, 1200 - sz(290) - 1, accuracy: 0.5, "a new size reaches the model")
        XCTAssertEqual(m.paneArea.height, 700, accuracy: 0.5)
        XCTAssertEqual(m.paneAreaChanges, changes + 1, "once")
        XCTAssertFalse(win.isVisible)
    }

    /// R1.1 (14.2) for what step 4 draws, at 0.7, 0.85 and 1.0. One pane (gate off): the pane is the model's frame at the
    /// whole area, the full header, a 60·s composer row. Two panes in columns (gate set by the row): every pane at its
    /// model frame; each header starts at its pane's edge and spans it (the shared edge line is an overlay, not padding),
    /// 26·s; both panes have a composer row of 60·s, focused or not; every frame equal across a focus change and the
    /// states idle -> working -> blocked. Four panes in two rows: 44·s rows.
    @MainActor
    func testAgentWindowPaneAreaKeepsEverySlotAcrossFocusAndState() throws {
        let saved = ThemeRuntime.scale, gate = AgentPaneLayout.splitsEnabled
        let restoreModes = transcriptMode(["api", "web", "db", "ops"])
        defer { ThemeRuntime.scale = saved; AgentPaneLayout.splitsEnabled = gate; restoreModes() }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            AgentPaneLayout.splitsEnabled = false
            let names = ["api", "web", "db", "ops"]
            let st = store(names.map { session($0, .idle) })
            let m = windowModel(st)
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(paneKey("api")))
            let size = CGSize(width: 1600, height: 900)
            let area = CGRect(x: 0, y: 0, width: 1600 - sz(290) - 1, height: 900)

            // One pane.
            let one = paneSnapshot(m, size)
            assertSame(one["pane 0"], area, "one pane: the whole area (\(scale))")
            let fullHeader = try XCTUnwrap(one["header 0"], "the header (\(scale))")
            XCTAssertGreaterThan(fullHeader.height, AgentCompactHeader.height + 1, "one pane: the full header (\(scale))")
            XCTAssertEqual(one["composer 0"]?.height ?? -1, sz(60), accuracy: 0.5, "60·s (\(scale))")
            // R1.3 (7.6): one pane: no focus border, no dim; the slots above are step 4's, unchanged.
            XCTAssertTrue(one["mark 0"] == nil, "one pane: neither the border nor the dim (\(scale))")

            // Two panes, columns.
            AgentPaneLayout.splitsEnabled = true
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            // #1224: with the gate on the band shows, so the pane area is the column less it.
            let frames = m.paneFrames(in: CGRect(x: 0, y: 0, width: area.width, height: area.height - AgentWindowBand.height))
            let base = paneSnapshot(m, size)
            for i in 0..<2 {
                let id = m.layout.order[i]
                assertSame(base["pane \(i)"], frames[id], "pane \(i) at the model's frame (\(scale))")
                // 7.6: the border (focused) or the dim (the other) is an overlay at the pane's own frame.
                assertSame(base["mark \(i)"], frames[id], "the focus mark of pane \(i) covers its frame exactly (\(scale))")
                let h = base["header \(i)"], p = base["pane \(i)"]
                XCTAssertEqual(h?.minX ?? -1, p?.minX ?? -2, accuracy: 0.5, "header \(i) starts at the pane's edge (\(scale))")
                XCTAssertEqual(h?.width ?? -1, p?.width ?? -2, accuracy: 0.5, "header \(i) spans the pane (\(scale))")
                XCTAssertEqual(h?.height ?? -1, AgentCompactHeader.height, accuracy: 0.5, "compact 26·s (\(scale))")
                XCTAssertEqual(base["composer \(i)"]?.height ?? -1, sz(60), accuracy: 0.5, "composer \(i), 60·s (\(scale))")
            }
            func same(_ why: String) {
                let s = paneSnapshot(m, size)
                XCTAssertEqual(Set(s.keys), Set(base.keys), "the same slots (\(why), \(scale))")
                for k in base.keys { assertSame(s[k], base[k], "\(k) (\(why), \(scale))") }
            }
            let second = try XCTUnwrap(m.layout.order.last)
            m.adopt(try m.layout.focus(second).get())
            same("focus to pane 1")
            m.adopt(try m.layout.focus(try XCTUnwrap(m.layout.order.first)).get())
            for state in [AgentState.working, .blocked] {
                st.sessions = names.map { session($0, state) }
                same("both \(state)")
            }
            st.sessions = names.map { session($0, .idle) }

            // Four panes, two rows: 44·s.
            m.adopt(paneLayout(names.map { paneTarget($0) }))
            let rows = paneSnapshot(m, size)
            for i in 0..<4 {
                XCTAssertEqual(rows["composer \(i)"]?.height ?? -1, sz(44), accuracy: 0.5, "two rows: 44·s, pane \(i) (\(scale))")
            }
            AgentPaneLayout.splitsEnabled = false
        }
    }

    /// R6.8 (14.2): the composer is first responder with a draft; 50 store publishes, an autosave and an attention change
    /// in the other pane leave the first responder, the draft and the selection as they were.
    @MainActor
    func testAgentWindowPaneAreaNeverStealsTheComposersFocus() throws {
        let gate = AgentPaneLayout.splitsEnabled
        let restoreModes = transcriptMode(["api", "web"])
        defer { AgentPaneLayout.splitsEnabled = gate; restoreModes() }
        AgentPaneLayout.splitsEnabled = true
        let st = store([session("api", .idle), session("web", .idle)])
        let m = windowModel(st, layouts: paneDefaults())
        m.setVisible(true)
        defer { m.close() }
        m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
        let selection = m.selection
        XCTAssertEqual(selection, .live(paneKey("api")))
        let size = CGSize(width: 1600, height: 900)
        let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        settle(host)
        let fields = focusViews(host, AgentComposerTextView.self)
        XCTAssertEqual(fields.count, 1, "one composer takes input: the focused pane's")
        let field = try XCTUnwrap(fields.first)
        XCTAssertTrue(win.makeFirstResponder(field))
        m.interaction.draft = "half a thought"
        settle(host)
        let writes = m.layoutWrites
        // R6.9 (7.2): the panes hold the keys; nothing below may change that or ask for a first responder.
        m.keyFocus = .pane
        let asks = win.responderAsks
        for i in 0..<50 { st.sessions = [session("api", .idle, ago: Double(60 + i)), session("web", .idle)] }
        st.sessions = [session("api", .idle), session("web", .blocked)]   // attention in the other pane
        var renamed = m.layout
        renamed.name = "Work"
        m.adopt(renamed)   // an autosave
        settle(host)
        XCTAssertGreaterThan(m.layoutWrites, writes, "the autosave ran")
        XCTAssertTrue(win.firstResponder === field, "the same field keeps the keys")
        XCTAssertEqual(m.interaction.draft, "half a thought")
        XCTAssertEqual(m.selection, selection)
        XCTAssertEqual(m.keyFocus, .pane, "R6.9: no publish, autosave or attention change moves the key focus")
        XCTAssertEqual(win.responderAsks, asks, "R6.9: and none asks for a first responder")
        XCTAssertFalse(win.isVisible)
    }

    /// 5.1: an unfocused pane's slot text: the draft's first line, else "Message <title>…"; Ended: the ended text.
    func testAgentWindowInertComposerShowsTheDraftsFirstLine() {
        XCTAssertEqual(AgentInertComposer.text(draft: "fix the build\nthen ship", title: "api", ended: false), "fix the build")
        XCTAssertEqual(AgentInertComposer.text(draft: "", title: "api", ended: false), "Message api…")
        XCTAssertEqual(AgentInertComposer.text(draft: "  \nsecond", title: "api", ended: false), "Message api…")
        XCTAssertEqual(AgentInertComposer.text(draft: "x", title: "api", ended: true), AgentInteractionPane.endedPlaceholder)
    }

    /// 4.2 Pick Another focuses the pane and gives the sidebar the keys, starting nothing; Close Pane closes a pane of
    /// several and is refused for the last one.
    @MainActor
    func testAgentWindowPickAnotherFocusesThePaneAndClosePaneKeepsTheLast() throws {
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let st = store([session("api", .idle), session("web", .idle)])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        var asked = 0
        m.focusSidebar = { asked += 1 }
        m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
        let second = try XCTUnwrap(m.layout.order.last)
        m.keyFocus = .pane
        m.pickAnother(second)
        XCTAssertEqual(m.layout.focused, second)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(m.keyFocus, .sidebar, "7.2: Pick Another gives the sidebar the keys")
        m.closePane(second)
        XCTAssertEqual(m.layout.panes.count, 1)
        XCTAssertEqual(m.keyFocus, .pane, "7.2: a close gives the panes the keys")
        let last = m.layout.focused
        m.closePane(last)
        XCTAssertEqual(m.layout.panes.count, 1, "the last pane stays (7.3)")
        m.pickAnother(last)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(AgentPanePlaceholder.title(.notRunning(paneKey("api"))), "api isn't running")
        XCTAssertEqual(AgentPanePlaceholder.title(.removed(.history(dir: "/tmp/dch-test", id: "old", seen: nil))),
                       "old was removed from History")
        XCTAssertTrue(AgentPanePlaceholder.title(nil) == nil, "no target: the empty pane's own state")
    }
}
