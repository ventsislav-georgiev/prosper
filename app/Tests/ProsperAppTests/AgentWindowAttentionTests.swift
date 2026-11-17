import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

/// #901 B3 step 5 (spec section 10 :745-760): which pane and which layout needs you. Offscreen only: views are hosted in
/// never-shown windows (paneSnapshot), no event is built or posted; the split gate is saved, set and restored through
/// `gate(_:)`; every row uses a private in-memory suite (`layoutSuite`, XCTestDefaults). Sessions are fakes in a fake
/// store; no session verb runs. No timer is waited on (the edge bar has none). All on the main actor; the Combine sinks
/// run synchronously on the main actor inside the store's publish.
extension AgentWindowD1Tests {
    /// A visible model over `layouts` (the first active unless `active`) and a store of `sessions`.
    @MainActor
    private func attentionModel(_ layouts: [PaneLayout], active: UUID? = nil,
                                _ sessions: [(String, AgentState)]) throws -> (AgentWindowModel, AgentIslandStore) {
        let d = layoutSuite(), act = active ?? layouts.first?.id ?? UUID()
        d.set(try PaneLayoutStore(layouts: layouts, active: act, mru: [act]).encode(), forKey: "agentWindowLayouts")
        let st = store(sessions.map { session($0.0, $0.1) })
        let m = windowModel(st, layouts: d)
        m.setVisible(true)
        return (m, st)
    }

    private func sessionKey(_ n: String) -> AgentSessionKey { AgentSessionKey(dir: "/tmp/dch-test", name: n) }

    /// Item 2, the map as literals across three layouts. Active A: api blocked (focused), docs done, web idle. B: api
    /// blocked, ops working, q blocked: 2. C: docs done, web idle: no entry (done is not counted, spec :751). D: q and a
    /// History pane named api: 1 (History is no live session; spec :30 allows no session twice in one layout). The focused pane's need is in
    /// the map but paneNeed gives nil for it (the focused pane never shows section 10's marks).
    @MainActor
    func testAgentWindowAttentionMapLiterals() throws {
        gate(true)
        let a = paneLayout([paneTarget("api"), paneTarget("docs"), paneTarget("web")])
        let b = paneLayout([paneTarget("api"), paneTarget("ops"), paneTarget("q")])
        let c = paneLayout([paneTarget("docs"), paneTarget("web")])
        let e = paneLayout([paneTarget("q"), .history(dir: "/tmp/dch-test", id: "api", seen: nil)])
        let (m, _) = try attentionModel([a, b, c, e], [("api", .blocked), ("docs", .done), ("web", .idle), ("ops", .working),
                                                       ("q", .blocked)])
        defer { m.close() }
        XCTAssertEqual(m.needs, [sessionKey("api"): .blocked, sessionKey("docs"): .done, sessionKey("q"): .blocked])
        let map = try XCTUnwrap(m.attention)
        let ap = a.panes.map(\.id)
        XCTAssertEqual(map.panes, [ap[0]: .blocked, ap[1]: .done], "the active layout's panes that need you")
        XCTAssertEqual(map.layouts, [b.id: 2, e.id: 1], "inactive layouts: distinct BLOCKED sessions; C has none")
        XCTAssertEqual(m.layout.focused, ap.first)
        XCTAssertTrue(m.paneNeed(ap[0]) == nil, "the focused pane: no mark")
        XCTAssertEqual(m.paneNeed(ap[1]), .done)
        XCTAssertTrue(m.paneNeed(ap[2]) == nil, "idle: no mark")
        XCTAssertEqual(m.layoutRows?.map(\.blocked), [0, 2, 0, 1], "the active row counts nothing")
        XCTAssertEqual(AgentLayoutsSection.value(try XCTUnwrap(m.layoutRows?.last)), "1 session needs input")
        XCTAssertEqual(AgentLayoutsSection.value(try XCTUnwrap(m.layoutRows?.first)), "")
        XCTAssertEqual(m.layoutWrites, 0, "reading the map writes nothing")
    }

    /// Item 2: an equal refresh publishes nothing (twenty of them); a state change publishes and the map follows it.
    @MainActor
    func testAgentWindowAttentionEqualRefreshPublishesNothing() throws {
        gate(true)
        let a = paneLayout([paneTarget("api"), paneTarget("docs")]), b = paneLayout([paneTarget("docs")])
        let (m, st) = try attentionModel([a, b], [("api", .idle), ("docs", .blocked)])
        defer { m.close() }
        m.refresh()
        let before = m.attention
        var published = 0
        let sink = m.objectWillChange.sink { _ in published += 1 }   // main actor, inside refresh()
        defer { sink.cancel() }
        for _ in 0..<20 { m.refresh() }
        XCTAssertEqual(published, 0, "equal refreshes: nothing published")
        XCTAssertEqual(m.attention, before)
        st.sessions = [session("api", .idle), session("docs", .idle)]
        XCTAssertGreaterThan(published, 0, "a change publishes")
        XCTAssertEqual(m.needs, [:])
        XCTAssertEqual(m.attention?.layouts, [:], "the blocked session left: no count")
    }

    /// Item 2: nothing computed while hidden: a model never shown has no map; a shown-then-hidden one keeps the last
    /// visible value while the store says a session is blocked, and reads it afresh when shown again.
    @MainActor
    func testAgentWindowAttentionNothingComputedWhileHidden() throws {
        gate(true)
        let d = layoutSuite(), a = paneLayout([paneTarget("api"), paneTarget("docs")])
        d.set(try PaneLayoutStore(layouts: [a], active: a.id, mru: [a.id]).encode(), forKey: "agentWindowLayouts")
        let st = store([session("api", .idle), session("docs", .idle)])
        let never = windowModel(st, layouts: d)
        defer { never.close() }
        XCTAssertTrue(never.needs == nil, "never visible: nothing computed")
        let (m, st2) = try attentionModel([a], [("api", .idle), ("docs", .idle)])
        defer { m.close() }
        XCTAssertEqual(m.needs, [:])
        m.setVisible(false)
        st2.sessions = [session("api", .idle), session("docs", .blocked)]
        m.refresh()
        XCTAssertEqual(m.needs, [:], "hidden: the publish and the clock's refresh compute nothing")
        XCTAssertTrue(never.needs == nil)
        m.setVisible(true)
        XCTAssertEqual(m.needs, [sessionKey("docs"): .blocked], "shown again: read afresh")
    }

    /// Item 4, gate off: two panes, a second layout and blocked sessions: no map, no rows, no mark, nothing in `needs`,
    /// and the pane area builds no attention view (one pane: never compact).
    @MainActor
    func testAgentWindowAttentionGateOffBuildsNothing() throws {
        gate(false)
        let restoreModes = transcriptMode(["api", "docs"])
        defer { restoreModes() }
        let a = paneLayout([paneTarget("api"), paneTarget("docs")]), b = paneLayout([paneTarget("docs")])
        let (m, st) = try attentionModel([a, b], [("api", .idle), ("docs", .blocked)])
        defer { m.close() }
        st.sessions = [session("api", .blocked), session("docs", .blocked)]
        m.refresh()
        XCTAssertTrue(m.needs == nil, "gate off: nothing computed")
        XCTAssertTrue(m.attention == nil)
        XCTAssertTrue(m.layoutRows == nil)
        XCTAssertTrue(a.panes.allSatisfy { m.paneNeed($0.id) == nil })
        let parts = paneSnapshot(m, CGSize(width: 1600, height: 700))
        XCTAssertFalse(parts.keys.contains { $0.hasPrefix("attention") }, "no bar built: \(parts.keys.sorted())")
        XCTAssertEqual(m.layoutWrites, 0)
    }

    /// Item 3 (b)(c): three panes, api focused and blocked, docs blocked, web done. The bar is on docs only (never the
    /// focused pane, never a done one); docs turning done ends it (no timer). At 1.0, 0.85 and 0.7 each pane's frame, header
    /// and composer slot are the same with the marks (blocked/done) as without (all idle). The chips' words are literal.
    @MainActor
    func testAgentWindowAttentionEdgeBarOnAnUnfocusedBlockedPaneAndFixedFrames() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        gate(true)
        _ = ThemeStore.shared   // seeds ThemeRuntime.scale from the prefs before it is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let restoreModes = transcriptMode(["api", "docs", "web"])
        defer { restoreModes() }
        XCTAssertEqual(AgentStateChip(state: .blocked).label, "Needs input")
        XCTAssertEqual(AgentStateChip(state: .done).label, "Done")
        let size = CGSize(width: 1600, height: 700)
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let l = paneLayout([paneTarget("api"), paneTarget("docs"), paneTarget("web")])
            let (m, st) = try attentionModel([l], [("api", .blocked), ("docs", .blocked), ("web", .done)])
            let marked = paneSnapshot(m, size)
            XCTAssertNotNil(marked["attention 1"], "docs: unfocused and blocked (\(scale)): \(marked.keys.sorted())")
            XCTAssertTrue(marked["attention 0"] == nil, "the focused pane never (\(scale))")
            XCTAssertTrue(marked["attention 2"] == nil, "done: the header chip only (\(scale))")
            if let bar = marked["attention 1"], let pane = marked["pane 1"] {
                XCTAssertEqual(bar.height, sz(3), accuracy: pixel, "3·s high (\(scale))")
                XCTAssertEqual(bar.minY, pane.minY, accuracy: pixel, "on the top edge (\(scale))")
                XCTAssertEqual(bar.width, pane.width, accuracy: pixel, "the pane's width (\(scale))")
            }
            st.sessions = [session("api", .blocked), session("docs", .done), session("web", .done)]
            let ended = paneSnapshot(m, size)
            XCTAssertTrue(ended["attention 1"] == nil, "blocked -> done: the bar ends (\(scale))")
            st.sessions = [session("api", .idle), session("docs", .idle), session("web", .idle)]
            let plain = paneSnapshot(m, size)
            m.close()
            XCTAssertFalse(plain.keys.contains { $0.hasPrefix("attention") }, "\(scale)")
            for part in ["pane", "header"] {   // #1471: no composer slot under a terminal pane
                for i in 1...2 { assertSame(marked["\(part) \(i)"], plain["\(part) \(i)"], "\(part) \(i) at \(scale)") }
            }
            assertSame(marked["pane 0"], plain["pane 0"], "the focused pane at \(scale)")
        }
    }
}
