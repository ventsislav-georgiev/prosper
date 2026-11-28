import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2066 (operator 2026-11-27: "drop the popups"): the pane header's agents, shells and open PRs count groups open the
/// window's one drawer for that pane's session, at their bottom tab, unfolded; buttons for VoiceOver with the count words
/// as the value; plain counts with the X-ray gate closed. Fakes only: a fake dch gate and runner, never-shown windows, no
/// event posted (the click is the action the button runs).
extension AgentWindowD1Tests {
    /// The bottom pane's keys cleared in the scratch defaults and its shared state put back after.
    @MainActor
    func withBottomPane(_ body: () throws -> Void) rethrows {
        XCTAssertFalse(Preferences.defaults === UserDefaults.standard, "a private defaults store")
        let keys = XrayBottomPaneTests.keys, saved = keys.map { Preferences.defaults.object(forKey: $0) }
        let b = XrayBottomPane.shared, tab = b.tab
        defer {
            b.tab = tab
            b.reset()
            for (k, v) in zip(keys, saved) { Preferences.defaults.set(v, forKey: k) }
        }
        try body()
    }

    /// Red at TIP (no xrayCountClicked). Mutant count-click-no-tab (the show call dropped) fails the tab and unfold lines.
    /// A click on web's shells group focuses web, opens the drawer for web's session, on Shells; a second click (agents,
    /// the bottom pane folded meanwhile) keeps it open (no toggle), on Agents, unfolded; PRs likewise.
    @MainActor
    func testXrayCountGroupClickOpensTheDrawerAtItsTab() throws {
        try withBottomPane {
            try xrayButtonSeams([1, 78, 0]) { _ in
                try xrayButtonSplit { m, win, api, web in
                    let panels = XrayPanels.shared, b = XrayBottomPane.shared
                    b.tab = .agents
                    XCTAssertEqual(m.layout.focused, api, "control: api focused")
                    AgentsNSWindow.xrayCountClicked(.shells, pane: web, in: win)
                    XCTAssertEqual(m.layout.focused, web, "the click focuses its own pane")
                    XCTAssertEqual(panels.open[web]?.target.name, "web", "the drawer opens for web's session")
                    XCTAssertTrue(panels.open[api] == nil, "one drawer per window")
                    XCTAssertEqual(b.tab, .shells, "at the Shells tab")
                    b.dragged(by: 10_000, in: 600)
                    b.ended()
                    XCTAssertTrue(b.collapsed, "control: folded")
                    AgentsNSWindow.xrayCountClicked(.agents, pane: web, in: win)
                    XCTAssertEqual(panels.open[web]?.target.name, "web", "an open drawer stays open (no toggle)")
                    XCTAssertEqual(b.tab, .agents)
                    XCTAssertFalse(b.collapsed, "unfolded")
                    AgentsNSWindow.xrayCountClicked(.prs, pane: web, in: win)
                    XCTAssertEqual(panels.open[web]?.target.name, "web")
                    XCTAssertEqual(b.tab, .prs)
                    AgentsNSWindow.xrayCountClicked(.shells, pane: api, in: nil)
                    XCTAssertEqual(b.tab, .prs, "no window: nothing")
                }
            }
            try xrayButtonSeams(nil) { _ in
                try xrayButtonSplit { _, win, _, web in
                    XrayBottomPane.shared.tab = .agents
                    AgentsNSWindow.xrayCountClicked(.shells, pane: web, in: win)
                    XCTAssertTrue(XrayPanels.shared.open.isEmpty, "gate closed: no drawer")
                    XCTAssertEqual(XrayBottomPane.shared.tab, .agents, "and no tab change")
                }
            }
        }
    }

    /// QA R2066a F1 (ruling b): the header's count groups stay plain counts, gate open or closed, until #2051-#2053 fill
    /// the tabs. Red at fd8165c5 (AgentHeaderCounts drew "Show subagents"/"Show shells" buttons with the gate open);
    /// mutant header-wired fails it.
    @MainActor
    func testHeaderCountGroupsArePlainWithTheGateOpen() throws {
        _ = ThemeStore.shared   // #1510
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        let s = session("api", .idle)
        let m = windowModel(store([s]))
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(s.key))
        var row = try XCTUnwrap(m.selectedRow)
        row.agents = 2
        row.shells = [DchShell(id: "1", pid: 1, started: 0, command: "make")]
        row.merged = 3
        row.prCount = 1
        let pane = m.layout.focused
        func tree() -> [AXTreeNode] {
            let header = AgentSessionHeader(row: row, session: s, cwd: nil, open: {}, xrayPane: pane)
            let (win, host) = AXTreeSupport.hosted(header.frame(width: 900, height: 60, alignment: .top), CGSize(width: 900, height: 60))
            defer { win.contentView = nil; win.close() }
            host.layoutSubtreeIfNeeded()
            let t = AXTreeSupport.poll(host) { $0.contains { $0.reads("3 merged pull requests") } }
            XCTAssertFalse(win.isVisible, "never shown")
            return t
        }
        let groups = [("Show subagents", "2 agents"), ("Show shells", "1 running shell")]
        try xrayButtonSeams([1, 78, 0]) { _ in
            let t = tree()
            for (label, words) in groups {
                XCTAssertFalse(t.contains { $0.label == label && !$0.ignored }, "gate open: no \(label) button in \(t.map(\.names))")
                XCTAssertTrue(t.contains { $0.reads(words) && $0.role != "AXButton" }, "gate open: \(words) as a plain count")
            }
            XCTAssertTrue(t.contains { $0.reads("3 merged pull requests") && $0.role != "AXButton" }, "merged: a plain count")
            XCTAssertFalse(t.contains { $0.label == "Show pull requests" }, "the header draws no open PRs group (AgentRowSymbolsTests)")
        }
        try xrayButtonSeams(nil) { _ in
            let t = tree()
            for (label, words) in groups {
                XCTAssertFalse(t.contains { $0.label == label && !$0.ignored }, "gate closed: no \(label) button")
                XCTAssertTrue(t.contains { $0.reads(words) && $0.role != "AXButton" }, "gate closed: \(words) as a plain count")
            }
        }
    }

    /// Red at TIP (AgentCountGroups has no `show`). With `show` an open PRs group is a "Show pull requests" button that
    /// runs show(.prs), its words the value; without `show` (the sidebar rows) every group stays a plain count.
    @MainActor
    func testXrayCountGroupOpenPRsIsAButtonOnlyWithShow() {
        _ = ThemeStore.shared   // #1510
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        func tree(_ show: (@MainActor (XrayBottomTab) -> Void)?) -> [AXTreeNode] {
            let v = AgentCountGroups(counts: [(.open, 1), (.merged, 2)], size: 11, show: show)
            let (win, host) = AXTreeSupport.hosted(v.frame(width: 300, height: 30), CGSize(width: 300, height: 30))
            defer { win.contentView = nil; win.close() }
            let t = AXTreeSupport.poll(host) { $0.contains { $0.reads("2 merged pull requests") } }
            XCTAssertFalse(win.isVisible, "never shown")
            return t
        }
        let with = tree { _ in }
        let b = with.filter { $0.label == "Show pull requests" && !$0.ignored }
        XCTAssertEqual(b.count, 1, "\(with.map(\.names))")
        XCTAssertEqual(b.first?.role, "AXButton")
        XCTAssertEqual(b.first?.value, "1 open pull request")
        XCTAssertEqual(XrayBottomTab(.open), .prs, "the group's tab")
        XCTAssertTrue(XrayBottomTab(.merged) == nil, "merged opens nothing")
        let without = tree(nil)
        XCTAssertFalse(without.contains { $0.role == "AXButton" }, "the sidebar's groups: no button")
        XCTAssertTrue(without.contains { $0.reads("1 open pull request") })
    }
}
