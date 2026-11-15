import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

/// #901 B3 step 4a (spec 8.1 :625-631): the sidebar's Layouts section, built from `AgentWindowModel.layoutRows` (the
/// split gate AND the show rule). Offscreen only: views are hosted in never-shown windows (AXTreeSupport: the AX flags of
/// this process only, put back as found); key events are BUILT values handed to the pure functions; a click and the
/// "+" are the section's own static functions (what its Buttons call), never an event. Every row uses a private
/// in-memory suite (`layoutSuite`, XCTestDefaults); the gate is saved, set and restored through `gate(_:)`. Sessions
/// are fakes, the session verbs recording fakes (`Calls`, the `opened` counter), never run. All on the main actor.
extension AgentWindowD1Tests {
    @MainActor
    private func sectionModel(_ layouts: [PaneLayout], active: UUID? = nil, sessions: [String] = ["api", "docs"],
                              opened: @escaping (AgentSession) -> Void = { _ in }) throws -> (AgentWindowModel, UserDefaults) {
        let d = layoutSuite(), act = active ?? layouts.first?.id ?? UUID()
        d.set(try PaneLayoutStore(layouts: layouts, active: act, mru: [act]).encode(), forKey: "agentWindowLayouts")
        let m = windowModel(store(sessions.map { session($0, .idle) }), opened: opened, layouts: d)
        m.setVisible(true)
        return (m, d)
    }

    @MainActor
    private func named(_ l: PaneLayout, _ name: String?) -> PaneLayout {
        PaneLayout(id: l.id, name: name, tree: l.tree, focused: l.focused, zoomed: l.zoomed)
    }

    /// The show rule as a table: gate on, one layout of one pane: not built; two panes: built; two layouts: built. Gate
    /// off with two layouts, the active one of two panes: not built (nil before anything is read).
    @MainActor
    func testAgentWindowLayoutSectionShowRuleTable() throws {
        typealias Row = (on: Bool, layouts: [[String?]], built: Bool, why: String)
        let table: [Row] = [
            (true, [["api"]], false, "one layout of one pane"),
            (true, [["api", "docs"]], true, "two panes"),
            (true, [["api"], ["docs"]], true, "two layouts"),
            (false, [["api", "docs"], ["docs"]], false, "gate off: two panes and two layouts"),
        ]
        for r in table {
            gate(r.on)
            let (m, _) = try sectionModel(r.layouts.map { paneLayout($0.map { $0.map(paneTarget) }) })
            defer { m.close() }
            XCTAssertEqual(m.layoutRows != nil, r.built, r.why)
            XCTAssertEqual(m.layoutWrites, 0, "reading the rule writes nothing (\(r.why))")
        }
    }

    /// The rows as literals: number, name (a set name, an automatic name of two titles, a gone session's word, an empty
    /// pane's word, a name with 20 combining marks drawn with the shared cap), the active one.
    @MainActor
    func testAgentWindowLayoutSectionRowsAreNumberedNamedAndMarkTheActiveOne() throws {
        gate(true)
        let marked = "e" + String(repeating: "\u{301}", count: 20)
        let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("api"), paneTarget("docs")])
        let c = paneLayout([paneTarget("gone")]), e = paneLayout([nil]), f = named(paneLayout([paneTarget("docs")]), marked)
        let (m, _) = try sectionModel([a, b, c, e, f], active: b.id)
        defer { m.close() }
        let rows = try XCTUnwrap(m.layoutRows)
        XCTAssertEqual(rows.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.id), [a, b, c, e, f].map(\.id), "the stored order")
        XCTAssertEqual(Array(rows.map(\.name).prefix(4)), ["Review", "api + docs", "gone", "Empty"])
        XCTAssertEqual(rows.map(\.active), [false, true, false, false, false])
        let drawn = rows.last?.name ?? ""
        XCTAssertEqual(drawn, OutsideText.shown(drawn), "through the shared cap")
        XCTAssertEqual(drawn, "e\u{301}\u{301}", "at most \(2) marks on the base")
    }

    /// A click switches through switchLayout(number:) (one write); the active row's click writes nothing; no click opens,
    /// starts or asks anything (recording fakes stay empty).
    @MainActor
    func testAgentWindowLayoutSectionClickSwitchesOnceAndStartsNothing() throws {
        gate(true)
        var opened = 0
        let a = paneLayout([paneTarget("api")]), b = paneLayout([paneTarget("docs")])
        let (m, d) = try sectionModel([a, b], opened: { _ in opened += 1 })
        defer { m.close() }
        let calls = Calls()
        calls.wire(m)
        let before = try XCTUnwrap(m.layoutRows)
        let first = try XCTUnwrap(before.first), last = try XCTUnwrap(before.last)
        AgentLayoutsSection.click(m, first)
        XCTAssertEqual(m.layoutWrites, 0, "the active row's click: nothing written")
        AgentLayoutsSection.click(m, last)
        XCTAssertEqual(m.layout.id, b.id)
        XCTAssertEqual(m.layoutWrites, 1, "one write per switch")
        XCTAssertEqual(savedLayouts(d).active, b.id)
        XCTAssertEqual(m.layoutRows?.map(\.active), [false, true])
        XCTAssertEqual(opened, 0, "no open")
        XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no session verb")
        XCTAssertTrue(m.newSession == nil, "no New session form")
    }

    /// "+" makes a layout (one write each, the new one active); at 9 the section is full and "+" makes nothing; the 9
    /// made through the "+" path persist in order (the saved blob decoded).
    @MainActor
    func testAgentWindowLayoutSectionPlusMakesLayoutsUpToNineThatPersist() throws {
        gate(true)
        let a = paneLayout([paneTarget("api"), paneTarget("docs")])
        let (m, d) = try sectionModel([a])
        defer { m.close() }
        let one = try XCTUnwrap(m.layoutRows)
        XCTAssertFalse(AgentLayoutsSection.full(one))
        AgentLayoutsSection.plus(m)
        XCTAssertEqual(m.layoutWrites, 1, "one write")
        XCTAssertEqual(m.layoutRows?.count, 2)
        XCTAssertEqual(m.layoutRows?.last?.active, true, "the new layout is active (D2)")
        for _ in 0..<7 { AgentLayoutsSection.plus(m) }
        let rows = try XCTUnwrap(m.layoutRows)
        XCTAssertEqual(rows.count, 9)
        XCTAssertTrue(AgentLayoutsSection.full(rows))
        XCTAssertEqual(m.layoutWrites, 8)
        AgentLayoutsSection.plus(m)
        XCTAssertEqual(m.layoutWrites, 8, "at the cap: nothing made or written")
        XCTAssertEqual(m.layoutRows?.count, 9)
        let saved = savedLayouts(d)
        XCTAssertEqual(saved.layouts.count, 9)
        XCTAssertEqual(saved.layouts.map(\.id), rows.map(\.id), "in order")
        XCTAssertEqual(saved.layouts.first?.id, a.id)
    }

    /// The Layouts rows are out of the up/down walk and the ⌘1…9 jump: with the section shown both enumerate exactly the
    /// session rows they enumerate with it not built, and up/down through the window's handler move the selection only.
    @MainActor
    func testAgentWindowLayoutSectionStaysOutOfTheWalkAndTheJump() throws {
        gate(true)
        let one = paneLayout([paneTarget("api")])
        let (plain, _) = try sectionModel([one])
        defer { plain.close() }
        XCTAssertTrue(plain.layoutRows == nil)
        let a = paneLayout([paneTarget("api")]), b = paneLayout([paneTarget("docs")])
        let (m, _) = try sectionModel([a, b])
        defer { m.close() }
        XCTAssertEqual(m.layoutRows?.count, 2)
        XCTAssertEqual(m.navigableIDs, plain.navigableIDs)
        XCTAssertEqual(m.numberedIDs, plain.numberedIDs)
        @MainActor func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        for code: UInt16 in [125, 126, 125, 125, 126, 126, 126] {
            XCTAssertTrue(AgentsNSWindow.handle(key(code), m))
            XCTAssertTrue(AgentsNSWindow.handle(key(code), plain))
            XCTAssertEqual(m.selection, plain.selection, "the walk lands on session rows only (\(code))")
        }
        XCTAssertEqual(m.layout.id, a.id, "a key never lands on a layout row")
        XCTAssertEqual(m.layoutWrites, plain.layoutWrites)
    }

    /// No flicker: 50 refreshes of the store with unchanged layouts publish nothing and leave the rows identical.
    @MainActor
    func testAgentWindowLayoutSectionFiftyRefreshesPublishNothing() throws {
        gate(true)
        let (m, _) = try sectionModel([paneLayout([paneTarget("api"), paneTarget("docs")])])
        defer { m.close() }
        m.refresh()
        let rows = try XCTUnwrap(m.layoutRows)
        var published = 0
        let sink = m.objectWillChange.sink { _ in published += 1 }   // runs on the main actor, inside refresh()
        defer { sink.cancel() }
        for _ in 0..<50 { m.refresh() }
        XCTAssertEqual(published, 0, "nothing new published")
        XCTAssertEqual(m.layoutRows, rows, "the same rows")
        XCTAssertEqual(m.layoutWrites, 0)
    }

    // MARK: Drawn: the accessibility tree and the frames

    @MainActor
    private func sidebarTree(_ m: AgentWindowModel, until done: @escaping ([AXTreeNode]) -> Bool = { _ in true }) -> [AXTreeNode] {
        AXTreeSupport.tree(AgentSidebarView(model: m), CGSize(width: sz(274), height: 900)) { t in
            t.contains { $0.label.hasPrefix("docs,") } && done(t)
        }
    }

    /// One node per drawn element: the first unignored node with a name and a frame (a wrapper repeating it is dropped).
    private func unique(_ tree: [AXTreeNode], _ keep: (AXTreeNode) -> Bool) -> [AXTreeNode] {
        var out: [AXTreeNode] = []
        for e in tree where !e.ignored && e.frame.height > 0 && keep(e)
            && !out.contains(where: { $0.label == e.label && $0.frame == e.frame }) { out.append(e) }
        return out
    }

    /// VoiceOver: each row a button named as drawn, in drawn order, the active one selected; "+" a button "New layout",
    /// enabled below the cap and disabled at 9 with the fixed words "(9 layouts max)". Gate off with two layouts and two
    /// panes: no Layouts element, and the tree's names and frames equal the gate-off one-layout window's.
    @MainActor
    func testAgentWindowLayoutSectionAccessibilityTree() throws {
        gate(true)
        let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("api"), paneTarget("docs")])
        let (m, _) = try sectionModel([a, b], active: b.id)
        defer { m.close() }
        let tree = sidebarTree(m) { t in t.contains { $0.label == "New layout" } }
        let rows = unique(tree) { ["Review", "api + docs"].contains($0.label) }
        XCTAssertEqual(rows.map(\.label), ["Review", "api + docs"], "drawn order")
        XCTAssertTrue(rows.allSatisfy { $0.role == "AXButton" }, rows.map(\.role).description)
        XCTAssertEqual(rows.map(\.selected), [false, true], "the active row reads selected")
        XCTAssertGreaterThan(rows.first?.frame.minY ?? 0, rows.last?.frame.minY ?? 0, "top to bottom (AX y grows upward)")
        let plus = unique(tree) { $0.label == "New layout" }
        XCTAssertEqual(plus.count, 1)
        XCTAssertEqual(plus.first?.role, "AXButton")
        XCTAssertEqual(plus.first?.enabled, true)
        XCTAssertFalse(tree.contains { $0.reads("(9 layouts max)") })

        for _ in 0..<7 { AgentLayoutsSection.plus(m) }
        XCTAssertEqual(m.layoutRows?.count, 9)
        let full = sidebarTree(m) { t in t.contains { $0.label == "New layout" } && t.contains { $0.reads("(9 layouts max)") } }
        XCTAssertEqual(unique(full) { $0.label == "New layout" }.first?.enabled, false, "disabled at the cap")
        XCTAssertTrue(full.contains { $0.reads("(9 layouts max)") }, "the fixed words")

        gate(false)
        let (off2, _) = try sectionModel([paneLayout([paneTarget("api"), paneTarget("docs")]), paneLayout([paneTarget("docs")])])
        defer { off2.close() }
        let (off1, _) = try sectionModel([paneLayout([paneTarget("api")])])
        defer { off1.close() }
        let t2 = sidebarTree(off2), t1 = sidebarTree(off1)
        XCTAssertFalse(t2.contains { $0.label == "New layout" || $0.reads(AgentLayoutsSection.title) })
        XCTAssertEqual(t2.map { "\($0.role)|\($0.names)|\($0.frame)" }, t1.map { "\($0.role)|\($0.names)|\($0.frame)" },
                       "gate off: the tree of a two-layout window is the one-layout window's")
    }

    /// Item 4, at 1.0, 0.85 and 0.7: with the section not built (gate on, one layout of one pane) the session rows' frames
    /// are the gate-off window's; shown, every session row moves down by the same amount (the section's height once) and
    /// keeps its size; every Layouts row has one height.
    @MainActor
    func testAgentWindowLayoutSectionFramesAtThreeScales() throws {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let titles = ["api", "docs"]
        func sessionRows(_ t: [AXTreeNode]) -> [CGRect] {
            titles.compactMap { n in unique(t) { $0.label.hasPrefix("\(n),") }.first?.frame }
        }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            gate(false)
            let (off, _) = try sectionModel([paneLayout([paneTarget("api")])])
            let base = sessionRows(sidebarTree(off))
            off.close()
            gate(true)
            let (hidden, _) = try sectionModel([paneLayout([paneTarget("api")])])
            let same = sessionRows(sidebarTree(hidden))
            hidden.close()
            let a = paneLayout([paneTarget("api")]), b = paneLayout([paneTarget("docs")]), c = paneLayout([nil])
            let (shown, _) = try sectionModel([a, b, c])
            let tree = sidebarTree(shown) { t in t.contains { $0.label == "Empty" } }
            let moved = sessionRows(tree)
            let layoutRows = unique(tree) { ["api", "docs", "Empty"].contains($0.label) && $0.role == "AXButton" }
            shown.close()
            XCTAssertEqual(base.count, 2, "\(scale)")
            XCTAssertEqual(same, base, "not built: byte for byte the gate-off frames (\(scale))")
            XCTAssertEqual(moved.count, 2, "\(scale)")
            let shifts = zip(base, moved).map { $0.minY - $1.minY }   // AX y grows upward: a row moved down has a lower y
            XCTAssertTrue((shifts.first ?? 0) > 0, "moved down (\(scale)): \(shifts)")
            // one amount, to the pixel: at 0.85 and 0.7 the section's height is fractional and each row's origin is
            // rounded to the pixel on its own (measured: 94.5 / 95.0 at 0.85), so one rounding step apart at most
            XCTAssertTrue(shifts.allSatisfy { abs($0 - (shifts.first ?? 0)) <= 0.5 }, "by one amount (\(scale)): \(shifts)")
            XCTAssertEqual(zip(base, moved).filter { $0.size != $1.size }.count, 0, "sizes kept (\(scale))")
            XCTAssertEqual(layoutRows.count, 3, "\(scale)")
            XCTAssertTrue(layoutRows.allSatisfy { abs($0.frame.height - (layoutRows.first?.frame.height ?? 0)) < 0.5 },
                          "one row height (\(scale))")
        }
    }
}
