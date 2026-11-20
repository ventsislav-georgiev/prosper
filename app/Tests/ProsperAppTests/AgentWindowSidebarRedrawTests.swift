import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1373 round 3: the operator saw the Agent Sessions sidebar stop redrawing (old title, state and age on every row)
/// while the pane header showed the session's new title and state. Both draw `model.sections` (the header through
/// selectedRow), so a model that stops refreshing freezes the header too; only the sidebar's own drawing can split
/// them. Fakes only: store publishes into a bound, visible, never rebuilt model; the view is hosted in a window that is
/// never shown and read through this process's own accessibility tree. No dch, no event.
final class AgentWindowSidebarRedrawTests: XCTestCase {

    static let dir = AgentWindowRemoteRowsTests.dir
    static let api = AgentSessionKey(dir: dir, name: "api")

    static func session(_ name: String, alias: String = "", _ state: AgentState) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: alias, activity: AgentWindowD1Tests.now - 60,
                     state: state, agents: 0, meta: nil, version: "1.80.0")
    }

    /// The model half of the evidence: hidden (no refresh), a publish leaves the header's row exactly as stale as the
    /// sidebar's, and showing again fixes both at once. So "header right, sidebar stale" is never the model's state.
    @MainActor
    func testAHiddenModelFreezesTheHeaderWithTheSidebar() {
        let (m, store, _) = AgentWindowRemoteRowsTests().model(AgentWindowRemoteRowsTests.Lister(nil),
                                                                sessions: [Self.session("api", .idle), Self.session("web", .idle)])
        defer { m.close() }
        m.select(.live(Self.api), manual: true)
        m.setVisible(false)
        store.sessions = [Self.session("api", alias: "Example task", .working), Self.session("web", .working)]
        XCTAssertEqual(m.row(.live(Self.api))?.title, "api", "hidden: the sidebar row is not rebuilt")
        XCTAssertEqual(m.selectedRow?.title, "api", "and neither is the header's row: it is the same row")
        XCTAssertEqual(m.selectedRow?.state, .idle)
        m.setVisible(true)
        XCTAssertEqual(m.row(.live(Self.api))?.title, "Example task")
        XCTAssertEqual(m.selectedRow?.title, "Example task")
        XCTAssertEqual(m.selectedRow?.state, .working)
    }

    /// The view half, the operator's sequence: a session started from History is selected before its row exists, its
    /// row comes with the dch name, then Claude names it and it works (another row starts working too). After every
    /// publish the drawn sidebar row reads what the drawn header reads, with no rebuild of the window.
    @MainActor
    func testTheDrawnSidebarFollowsEveryPublishTheHeaderShows() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let (m, store, _) = AgentWindowRemoteRowsTests().model(AgentWindowRemoteRowsTests.Lister(nil),
                                                                sessions: [Self.session("web", .idle)])
        defer { m.close() }
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        let size = CGSize(width: 1000, height: 680)
        let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), size)
        defer { win.contentView = nil; win.close() }
        func names(_ t: [AXTreeNode]) -> [String] { t.filter { !$0.ignored }.flatMap(\.names) }

        var t = AXTreeSupport.poll(host) { $0.contains { $0.named(prefix: "web, Idle") } }
        XCTAssertTrue(t.contains { $0.named(prefix: "web, Idle") }, "the first draw: \(names(t))")

        // Resumed: its row arrives under the dch name, idle; it is selected as it lands.
        store.sessions = [Self.session("api", .idle), Self.session("web", .idle)]
        m.select(.live(Self.api), manual: false)
        t = AXTreeSupport.poll(host) { $0.contains { $0.named(prefix: "api, Idle") } }
        XCTAssertTrue(t.contains { $0.named(prefix: "api, Idle") }, "the dch name row: \(names(t))")

        // Claude has loaded: named and working; web works too.
        store.sessions = [Self.session("api", alias: "Example task", .working), Self.session("web", .working)]
        XCTAssertEqual(m.selectedRow?.title, "Example task", "the model is current")
        let fresh: ([AXTreeNode]) -> Bool = { t in
            t.contains { $0.named(prefix: "Example task, Working") } && t.contains { $0.named(prefix: "web, Working") }
                && !t.contains { $0.named(prefix: "api, Idle") || $0.named(prefix: "web, Idle") }
        }
        t = AXTreeSupport.poll(host, until: fresh)
        XCTAssertTrue(t.contains { $0.named("Example task") }, "the header's title: \(names(t))")
        XCTAssertTrue(fresh(t), "the sidebar drew the publish the header drew: \(names(t))")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    // MARK: #1373 round 4: a row that moves from one section to another keeps its RowID

    static func key(_ name: String) -> AgentSessionKey { AgentSessionKey(dir: dir, name: name) }

    /// dch's list answer once Claude has named the session: alias and harness title both.
    static func titled(_ name: String, _ title: String, _ state: AgentState) -> AgentSession {
        var s = session(name, alias: title, state)
        s.harness = title
        return s
    }

    /// The first unignored node whose name starts with `prefix` (a sidebar row's label: "<title>, <detail>, ...").
    static func node(_ t: [AXTreeNode], _ prefix: String) -> AXTreeNode? { t.first { !$0.ignored && $0.named(prefix: prefix) } }

    /// The Cmd-<n> chip is drawn on the row whose label starts with `prefix`. The row's button reads the chip's own
    /// label last ("web, Needs input, 1m ago, Command-1"; ticket 1 of this round: no separate chip element is served).
    static func chip(_ n: Int, on prefix: String, _ t: [AXTreeNode]) -> Bool {
        node(t, prefix)?.names.contains { $0.hasPrefix(prefix) && $0.hasSuffix(", Command-\(n)") } == true
    }

    /// The rows that carry Cmd-<n> (n is 1...9, so no other number ends with it).
    static func chips(_ n: Int, _ t: [AXTreeNode]) -> Int {
        t.filter { !$0.ignored && $0.names.contains { $0.hasSuffix(", Command-\(n)") } }.count
    }

    /// The real root view in a never-shown window, AX on, scale 1, no folded section; everything put back after.
    @MainActor
    func withRoot(_ sessions: [AgentSession], pattern: String = "", height: CGFloat = 680,
                  _ body: (AgentWindowModel, AgentIslandStore, NSView) -> Void) {
        let pref = "agentWindowCollapsedSections"
        let savedPref = Preferences.defaults.object(forKey: pref), savedScale = ThemeRuntime.scale
        Preferences.defaults.removeObject(forKey: pref)
        ThemeRuntime.scale = 1.0
        let (m, store, _) = AgentWindowRemoteRowsTests().model(AgentWindowRemoteRowsTests.Lister(nil), sessions: sessions)
        store.sort = .name
        store.sidekickPattern = pattern
        let restoreAX = AXTreeSupport.axOn()
        let (win, host) = AXTreeSupport.hosted(AgentWindowRootView(model: m, scrolls: false), CGSize(width: 1000, height: height))
        defer {
            win.contentView = nil; win.close(); restoreAX(); m.close()
            Preferences.defaults.set(savedPref, forKey: pref); ThemeRuntime.scale = savedScale
        }
        body(m, store, host)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// Case A (operator, 2026-11-16): a blocked session is the first row of Needs you, Cmd-1, selected. One publish later it
    /// works and sorts into Sessions at a later place (Needs you is gone). The drawn row must read Working, carry Cmd-6 and
    /// stay selected, and app1 (now first) alone carries Cmd-1; folding and unfolding Sessions, and selecting another row
    /// and back, leave it right. At TIP (.id(row.id) across sections) the row kept its Needs you look.
    @MainActor
    func testARowMovedFromNeedsYouToSessionsDrawsItsNewStateAndNumber() {
        let others = (1...5).map { Self.session("app\($0)", .idle) }
        withRoot([Self.session("web", .blocked)] + others) { m, store, host in
            func names(_ t: [AXTreeNode]) -> [String] { t.filter { !$0.ignored }.flatMap(\.names) }
            m.select(.live(Self.key("web")), manual: true)
            var t = AXTreeSupport.poll(host) { Self.chip(1, on: "web, Needs input", $0) }
            XCTAssertTrue(Self.chip(1, on: "web, Needs input", t), "the first draw: web first in Needs you, Cmd-1: \(names(t))")
            XCTAssertTrue(Self.node(t, "web, Needs input")?.selected == true, "and selected: \(names(t))")
            XCTAssertEqual(Self.chips(1, t), 1, "the first draw: one Cmd-1 only: \(names(t))")

            store.sessions = [Self.session("web", .working)] + others
            XCTAssertEqual(m.sections.map(\.title), ["Sessions"], "the model moved it")
            XCTAssertEqual(m.number(.live(Self.key("web"))), 6)
            XCTAssertEqual(m.selectedRow?.state, .working, "the header's row is current")
            let fresh: ([AXTreeNode]) -> Bool = { t in
                Self.chip(6, on: "web, Working", t) && Self.chip(1, on: "app1, Idle", t) && Self.chips(1, t) == 1
                    && Self.node(t, "web, Needs input") == nil && Self.node(t, "web, Working")?.selected == true
            }
            func check(_ when: String) {
                XCTAssertTrue(Self.node(t, "web, Needs input") == nil, "\(when): no row keeps the Needs you look: \(names(t))")
                XCTAssertTrue(Self.chip(6, on: "web, Working", t), "\(when): web drawn Working with Cmd-6: \(names(t))")
                XCTAssertTrue(Self.node(t, "web, Working")?.selected == true, "\(when): and still selected: \(names(t))")
                XCTAssertTrue(Self.chip(1, on: "app1, Idle", t), "\(when): Cmd-1 on app1: \(names(t))")
                XCTAssertEqual(Self.chips(1, t), 1, "\(when): one Cmd-1 only: \(names(t))")
            }
            t = AXTreeSupport.poll(host, until: fresh)
            check("after the move")

            m.toggleCollapsed("Sessions")
            t = AXTreeSupport.poll(host) { Self.node($0, "web, ") == nil }
            XCTAssertTrue(Self.node(t, "web, ") == nil, "folded: no web row: \(names(t))")
            m.toggleCollapsed("Sessions")
            t = AXTreeSupport.poll(host, until: fresh)
            check("folded and unfolded")

            m.select(.live(Self.key("app1")), manual: true)
            m.select(.live(Self.key("web")), manual: true)
            t = AXTreeSupport.poll(host, until: fresh)
            check("another row selected and back")
        }
    }

    /// Case B (operator, 2026-11-16): a session listed in Sessions under its dch name gets a title that matches the
    /// sidekick pattern ("-qa"), so one publish moves it to Sidekicks. The drawn row must read "api-qa, Working" with
    /// Cmd-3 (app1 and web keep Sessions' Cmd-1, Cmd-2), selected or not; folding and unfolding Sidekicks leaves it right.
    @MainActor
    func testARowMovedFromSessionsToSidekicksDrawsItsNewTitle() { sidekickMove(selected: false) }

    @MainActor
    func testASelectedRowMovedFromSessionsToSidekicksDrawsItsNewTitle() { sidekickMove(selected: true) }

    @MainActor
    func sidekickMove(selected: Bool, line: UInt = #line) {
        let others = [Self.session("app1", .idle), Self.session("web", .idle)]
        withRoot([Self.session("api", .idle)] + others, pattern: "-qa") { m, store, host in
            func names(_ t: [AXTreeNode]) -> [String] { t.filter { !$0.ignored }.flatMap(\.names) }
            if selected { m.select(.live(Self.key("api")), manual: true) } else { m.select(.live(Self.key("web")), manual: true) }
            var t = AXTreeSupport.poll(host) { Self.chip(1, on: "api, Idle", $0) }
            XCTAssertTrue(Self.chip(1, on: "api, Idle", t), "the first draw: api first in Sessions, Cmd-1: \(names(t))")

            XCTAssertEqual(Self.chips(1, t), 1, "the first draw: one Cmd-1 only: \(names(t))", line: line)

            store.sessions = [Self.titled("api", "api-qa", .working)] + others
            XCTAssertEqual(m.sections.map(\.title), ["Sessions", "Sidekicks"], "the model moved it")
            XCTAssertEqual(m.number(.live(Self.key("api"))), 3)
            let fresh: ([AXTreeNode]) -> Bool = { t in
                Self.chip(3, on: "api-qa, Working", t) && Self.chip(1, on: "app1, Idle", t) && Self.chips(1, t) == 1
                    && Self.node(t, "api, ") == nil
            }
            func check(_ when: String) {
                XCTAssertTrue(Self.node(t, "api, ") == nil, "\(when): no row keeps the dch name: \(names(t))", line: line)
                XCTAssertTrue(Self.chip(3, on: "api-qa, Working", t), "\(when): api-qa drawn Working with Cmd-3: \(names(t))", line: line)
                XCTAssertTrue(Self.chip(1, on: "app1, Idle", t), "\(when): Cmd-1 on app1: \(names(t))", line: line)
                XCTAssertEqual(Self.chips(1, t), 1, "\(when): one Cmd-1 only: \(names(t))", line: line)
                XCTAssertEqual(Self.node(t, "api-qa, Working")?.selected, selected, "\(when): selected as before: \(names(t))", line: line)
            }
            t = AXTreeSupport.poll(host, until: fresh)
            check("after the move")

            m.toggleCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID))
            t = AXTreeSupport.poll(host) { Self.node($0, "api-qa, ") == nil }
            XCTAssertTrue(Self.node(t, "api-qa, ") == nil, "folded: no api-qa row: \(names(t))", line: line)
            m.toggleCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID))
            t = AXTreeSupport.poll(host, until: fresh)
            check("folded and unfolded")
        }
    }

    /// The selection still scrolls the list to its row with the section-qualified identity: an existing row far down, a
    /// row that has just arrived, and a row that has just moved to another section (Sessions to Needs you, at the top).
    /// A row "lands" when its whole frame is inside the hosting view (the list is three times the window's height).
    @MainActor
    func testTheSelectionStillScrollsToItsRowAfterARowMovesSections() {
        let list = (0..<30).map { Self.session(String(format: "s%02d", $0), .idle) }
        withRoot(list, height: 420) { m, store, host in
            func names(_ t: [AXTreeNode]) -> [String] { t.filter { !$0.ignored }.flatMap(\.names) }
            func lands(_ prefix: String, _ t: [AXTreeNode]) -> Bool {
                guard let r = Self.node(t, prefix), let h = t.first?.frame else { return false }
                return r.frame.minY >= h.minY && r.frame.maxY <= h.maxY && r.frame.height > 0
            }
            m.select(.live(Self.key("s00")), manual: true)
            var t = AXTreeSupport.poll(host) { lands("s00, ", $0) }
            XCTAssertTrue(lands("s00, ", t), "the first draw: s00 shows: \(names(t))")
            XCTAssertFalse(lands("s29, ", t), "and s29 is below the fold: \(names(t))")

            m.select(.live(Self.key("s29")), manual: true)
            t = AXTreeSupport.poll(host) { lands("s29, ", $0) }
            XCTAssertTrue(lands("s29, ", t), "an existing row far down: \(names(t))")

            store.sessions = list + [Self.session("s30", .idle)]
            m.select(.live(Self.key("s30")), manual: false)
            t = AXTreeSupport.poll(host) { lands("s30, ", $0) }
            XCTAssertTrue(lands("s30, ", t), "a row that has just arrived: \(names(t))")

            store.sessions = list.map { $0.name == "s15" ? Self.session("s15", .blocked) : $0 } + [Self.session("s30", .idle)]
            XCTAssertEqual(m.sections.first?.title, AgentSidebar.needsYouTitle)
            m.select(.live(Self.key("s15")), manual: true)
            t = AXTreeSupport.poll(host) { lands("s15, Needs input", $0) }
            XCTAssertTrue(lands("s15, Needs input", t), "a row that has just moved to Needs you: \(names(t))")
        }
    }
}
