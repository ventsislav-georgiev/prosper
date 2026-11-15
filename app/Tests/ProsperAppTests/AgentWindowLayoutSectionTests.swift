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
        XCTAssertEqual(drawn, "e\u{301}\u{301}\u{301}", "at most \(OutsideText.maxMarks) marks on the base")
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
            t.contains { $0.label.hasPrefix("docs,") && !$0.label.contains(", Control ") } && done(t)   // 4b: a session row
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
        let rows = unique(tree) { ["Review, Control 1", "api + docs, Control 2"].contains($0.label) }
        XCTAssertEqual(rows.map(\.label), ["Review, Control 1", "api + docs, Control 2"], "drawn order, the key read too")
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
            titles.compactMap { n in unique(t) { $0.label.hasPrefix("\(n),") && !$0.label.contains(", Control ") }.first?.frame }
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
            let tree = sidebarTree(shown) { t in t.contains { $0.label == "Empty, Control 3" } }
            let moved = sessionRows(tree)
            let layoutRows = unique(tree) { ["api, Control 1", "docs, Control 2", "Empty, Control 3"].contains($0.label)
                && $0.role == "AXButton" }
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

    // MARK: #901 B3 step 4b: the context menu, the inline rename, folding, the band's name slot

    /// The menu entry `verb` of the row `id`'s list (a value: no menu is popped).
    @MainActor
    private func entry(_ m: AgentWindowModel, _ id: UUID, _ verb: AgentLayoutVerb) throws -> AgentLayoutMenuEntry {
        try XCTUnwrap(AgentWindowControls.layoutMenu(m, id).first { $0.verb == verb })
    }

    /// Item 2: each row's entry list as literals: Rename / Duplicate / Delete, all on with two layouts. Delete through its
    /// entry: one write; then the last layout's Delete reads "Delete (last layout)", off, and running it writes nothing.
    /// At 9 Duplicate reads "Duplicate (9 layouts max)", off. Gate off: no entries at all. GUARD delete-allowed-on-the-last.
    @MainActor
    func testAgentWindowLayoutSectionMenuEntriesAreValuesAndDeleteStopsAtTheLast() throws {
        gate(true)
        let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("docs")])
        let (m, d) = try sectionModel([a, b])
        defer { m.close() }
        let calls = Calls()
        calls.wire(m)
        let two = AgentWindowControls.layoutMenu(m, a.id)
        XCTAssertEqual(two.map(\.title), ["Rename", "Duplicate", "Delete"])
        XCTAssertEqual(two.map(\.enabled), [true, true, true])
        XCTAssertEqual(AgentWindowControls.layoutMenu(m, b.id), two, "the same list on every row")
        AgentWindowControls.runLayout(try entry(m, b.id, .delete), m, b.id)
        XCTAssertEqual(m.layoutWrites, 1, "one write")
        XCTAssertEqual(savedLayouts(d).layouts.map(\.id), [a.id])
        let last = AgentWindowControls.layoutMenu(m, a.id)
        XCTAssertEqual(last.map(\.title), ["Rename", "Duplicate", "Delete (last layout)"])
        XCTAssertEqual(last.map(\.enabled), [true, true, false])
        AgentWindowControls.runLayout(try entry(m, a.id, .delete), m, a.id)
        XCTAssertEqual(m.layoutWrites, 1, "a disabled entry runs nothing")
        XCTAssertEqual(m.layouts?.layouts.count, 1)
        for _ in 0..<8 { AgentLayoutsSection.plus(m) }
        XCTAssertEqual(m.layoutRows?.count, 9)
        let full = AgentWindowControls.layoutMenu(m, a.id)
        XCTAssertEqual(full.map(\.title), ["Rename", "Duplicate (9 layouts max)", "Delete"])
        XCTAssertEqual(full.map(\.enabled), [true, false, true])
        XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no session verb")
        gate(false)
        XCTAssertEqual(AgentWindowControls.layoutMenu(m, a.id), [], "gate off: no entry")
    }

    /// Item 2: Duplicate makes ONE layout, active (D2), named by D3, with one write; no session verb runs.
    @MainActor
    func testAgentWindowLayoutSectionDuplicateMakesOneActiveLayout() throws {
        gate(true)
        var opened = 0
        let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("docs")])
        let (m, d) = try sectionModel([a, b], opened: { _ in opened += 1 })
        defer { m.close() }
        let calls = Calls()
        calls.wire(m)
        AgentWindowControls.runLayout(try entry(m, a.id, .duplicate), m, a.id)
        XCTAssertEqual(m.layoutWrites, 1, "one write")
        let rows = try XCTUnwrap(m.layoutRows)
        XCTAssertEqual(rows.map(\.name), ["Review", "docs", "Review 2"])
        XCTAssertEqual(rows.map(\.active), [false, false, true], "the copy is active")
        XCTAssertEqual(m.layout.id, rows.last?.id)
        XCTAssertFalse([a.id, b.id].contains(m.layout.id), "fresh ids")
        let saved = savedLayouts(d)
        XCTAssertEqual(saved.layouts.count, 3)
        XCTAssertEqual(saved.active, rows.last?.id)
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no session verb")
    }

    /// Item 2: Delete of the ACTIVE layout leaves the MRU's next one active and adopted (the model op's rule), one write.
    @MainActor
    func testAgentWindowLayoutSectionDeleteOfTheActiveHandsOverToTheMRUNext() throws {
        gate(true)
        let a = paneLayout([paneTarget("api")]), b = paneLayout([paneTarget("docs")]), c = paneLayout([nil])
        let (m, d) = try sectionModel([a, b, c])
        defer { m.close() }
        let rows = try XCTUnwrap(m.layoutRows)
        AgentLayoutsSection.click(m, try XCTUnwrap(rows.last))    // c
        AgentLayoutsSection.click(m, try XCTUnwrap(rows.dropFirst().first))   // b
        AgentLayoutsSection.click(m, try XCTUnwrap(rows.last))    // c again: MRU c, b, a
        XCTAssertEqual(m.layoutWrites, 3)
        AgentWindowControls.runLayout(try entry(m, c.id, .delete), m, c.id)
        XCTAssertEqual(m.layoutWrites, 4, "one write")
        XCTAssertEqual(m.layout.id, b.id, "the MRU's next")
        XCTAssertEqual(m.layoutRows?.map(\.name), ["api", "docs"])
        XCTAssertEqual(m.layoutRows?.map(\.active), [false, true])
        XCTAssertEqual(savedLayouts(d).active, b.id)
    }

    /// Item 2: Rename opens the inline field's state (no write); Escape (nil) closes it and writes nothing; Return writes
    /// ONCE with the name cleaned by the model (D1); a late end of the closed field changes nothing. Gate off: Rename
    /// opens nothing. GUARD rename-commits-on-cancel.
    @MainActor
    func testAgentWindowLayoutSectionInlineRenameCommitsOnceAndCancelWritesNothing() throws {
        gate(true)
        let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("docs")])
        let (m, d) = try sectionModel([a, b])
        defer { m.close() }
        let calls = Calls()
        calls.wire(m)
        AgentWindowControls.runLayout(try entry(m, a.id, .rename), m, a.id)
        XCTAssertEqual(m.layoutRenaming, a.id, "the field is open")
        XCTAssertEqual(m.layoutWrites, 0)
        m.endLayoutRename(a.id, nil)
        XCTAssertTrue(m.layoutRenaming == nil)
        XCTAssertEqual(m.layoutWrites, 0, "Escape: nothing written")
        XCTAssertEqual(m.layoutRows?.first?.name, "Review")
        AgentWindowControls.runLayout(try entry(m, a.id, .rename), m, a.id)
        m.endLayoutRename(a.id, "  Docs\u{7}   pass\t ")
        XCTAssertTrue(m.layoutRenaming == nil)
        XCTAssertEqual(m.layoutWrites, 1, "Return: one write")
        XCTAssertEqual(m.layoutRows?.first?.name, "Docs pass", "cleaned by the model")
        XCTAssertEqual(savedLayouts(d).layouts.first?.name, "Docs pass")
        m.endLayoutRename(a.id, "Other")
        XCTAssertEqual(m.layoutWrites, 1, "a late end changes nothing")
        XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no session verb (no dch -m)")
        gate(false)
        m.beginLayoutRename(a.id)
        XCTAssertTrue(m.layoutRenaming == nil, "gate off: no field")
    }

    /// Item 4: the header folds through agentWindowCollapsedSections ("Layouts"): folded, the rows are out of the drawn
    /// tree and the active layout is unchanged; 50 refreshes keep it folded and publish nothing; a new model reads it back;
    /// unfolding brings the rows back. GUARD section-folds-without-persisting.
    @MainActor
    func testAgentWindowLayoutSectionFoldsAndUnfoldsThroughTheCollapsedSet() throws {
        let pref = "agentWindowCollapsedSections"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        Preferences.defaults.removeObject(forKey: pref)
        gate(true)
        let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("api"), paneTarget("docs")])
        let (m, _) = try sectionModel([a, b], active: b.id)
        defer { m.close() }
        let open = sidebarTree(m) { t in t.contains { $0.label == "Review, Control 1" } }
        XCTAssertTrue(open.contains { $0.label == "Review, Control 1" })
        m.toggleCollapsed(AgentLayoutsSection.title)
        XCTAssertTrue(m.isCollapsed(AgentLayoutsSection.title))
        XCTAssertEqual(Preferences.defaults.stringArray(forKey: pref), ["Layouts"], "its own entry in the set")
        XCTAssertEqual(m.layout.id, b.id, "the active layout unchanged")
        XCTAssertEqual(m.layoutWrites, 0)
        m.refresh()
        var published = 0
        let sink = m.objectWillChange.sink { _ in published += 1 }   // main actor, inside refresh()
        defer { sink.cancel() }
        for _ in 0..<50 { m.refresh() }
        XCTAssertEqual(published, 0, "nothing published")
        XCTAssertTrue(m.isCollapsed(AgentLayoutsSection.title), "still folded")
        sink.cancel()
        let folded = sidebarTree(m)
        XCTAssertFalse(folded.contains { $0.label.hasSuffix(", Control 1") || $0.label.hasSuffix(", Control 2") }, "rows out")
        XCTAssertTrue(folded.contains { $0.label == "Layouts, 2" }, "the header stays, with its count")
        let (next, _) = try sectionModel([a, b], active: b.id)
        defer { next.close() }
        XCTAssertTrue(next.isCollapsed(AgentLayoutsSection.title), "read back")
        m.toggleCollapsed(AgentLayoutsSection.title)
        XCTAssertEqual(Preferences.defaults.stringArray(forKey: pref), [])
        let back = sidebarTree(m) { t in t.contains { $0.label == "Review, Control 1" } }
        XCTAssertTrue(back.contains { $0.label == "api + docs, Control 2" }, "unfolded: the rows again")
    }

    /// Item 5 (9.1 :708) at 1.0, 0.85 and 0.7: with two layouts the band's slot draws the active row's "⌃N name" inside the
    /// layout slot, and every band frame equals the one-layout-of-one-pane band's (no slot built there). Gate off: no slot
    /// row and no band at all. GUARD band-slot-built-with-the-gate-off.
    @MainActor
    func testAgentWindowLayoutBandNameSlotAtThreeScales() throws {
        _ = ThemeStore.shared   // seeds ThemeRuntime.scale first, before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let size = CGSize(width: 1400, height: 800)
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            gate(true)
            let (one, _) = try sectionModel([paneLayout([paneTarget("api")])])
            XCTAssertTrue(AgentWindowBand.layoutSlot(one) == nil, "\(scale)")
            let base = bandSnapshot(one, size)
            one.close()
            let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("docs")])
            let (two, _) = try sectionModel([a, b])
            let slot = try XCTUnwrap(AgentWindowBand.layoutSlot(two))
            XCTAssertEqual(slot.name, two.layoutRows?.first { $0.active }?.name)
            XCTAssertEqual(slot.name, "Review")
            XCTAssertEqual(slot.number, 1)
            let shown = bandSnapshot(two, size)
            two.close()
            XCTAssertTrue(base["layoutName"] == nil, "one layout of one pane: not built (\(scale))")
            XCTAssertTrue(base["layout"] != nil, "\(scale)")
            for k in base.keys.sorted() { XCTAssertEqual(shown[k], base[k], "\(k) unchanged (\(scale))") }
            let name = try XCTUnwrap(shown["layoutName"], "\(scale)"), room = try XCTUnwrap(shown["layout"])
            XCTAssertTrue(name.minX >= room.minX - 0.5 && name.maxX <= room.maxX + 0.5, "in the slot (\(scale)): \(name) \(room)")
            XCTAssertTrue(name.width > 0)
            gate(false)
            let (off, _) = try sectionModel([a, b])
            XCTAssertTrue(AgentWindowBand.layoutSlot(off) == nil, "gate off (\(scale))")
            XCTAssertTrue(bandSnapshot(off, size).isEmpty, "gate off: no band, no slot (\(scale))")
            off.close()
        }
    }

    /// R901-s4a-q1: automaticName joins cleaned titles with " + " (and "…" when long); a title that starts with `cap`
    /// combining marks would hang them on the separator's space or the "…". Every Character of the drawn name keeps at
    /// most `cap` scalars, both for the plain join and for one cut to "…" right before that title.
    @MainActor
    func testAgentWindowLayoutSectionNameCharactersStayUnderTheScalarCap() throws {
        gate(true)
        let cap = ThemeVariant.labelCharScalarMax, marks = String(repeating: "\u{301}", count: cap)
        let plain = paneLayout([paneTarget("api"), paneTarget(marks + "x")])
        let cut = paneLayout([paneTarget(String(repeating: "a", count: 40)), paneTarget(marks + String(repeating: "x", count: 31))])
        let (m, _) = try sectionModel([plain, cut], sessions: ["api"])
        defer { m.close() }
        let rows = try XCTUnwrap(m.layoutRows)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.last?.name.contains("…") == true, "the second one is cut")
        for r in rows {
            XCTAssertTrue(r.name.allSatisfy { $0.unicodeScalars.count <= cap }, "\(r.number): \(r.name.unicodeScalars.count)")
            XCTAssertEqual(r.name, OutsideText.shown(r.name), "drawn through the shared cap")
        }
    }

    // MARK: #901 B3 step 5: the attention slot, rider R901-s4b-q2

    /// Item 3 (a): an inactive layout holding two blocked sessions reads "<name>, Control 2" valued "2 sessions need
    /// input"; the active row and a row with none have no value. At 1.0, 0.85 and 0.7 every Layouts row's frame is the
    /// same with the dot and count as without (every session idle). The store's sessions are set on the fake store.
    @MainActor
    func testAgentWindowLayoutSectionAttentionSlotReadsTheCountAndKeepsFrames() throws {
        gate(true)
        _ = ThemeStore.shared   // seeds ThemeRuntime.scale from the prefs before it is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let labels = ["api, Control 1", "docs + web, Control 2", "web, Control 3"]
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let a = paneLayout([paneTarget("api")]), b = paneLayout([paneTarget("docs"), paneTarget("web")])
            let c = paneLayout([paneTarget("web")])
            let (m, _) = try sectionModel([a, b, c], sessions: ["api", "docs", "web"])
            defer { m.close() }
            let plainTree = sidebarTree(m) { t in t.contains { $0.label == "web, Control 3" } }
            let plain = unique(plainTree) { labels.contains($0.label) && $0.role == "AXButton" }
            try XCTUnwrap(m.store).sessions = [session("api", .blocked), session("docs", .blocked), session("web", .blocked)]
            XCTAssertEqual(m.layoutRows?.map(\.blocked), [0, 2, 1], "\(scale)")
            let tree = sidebarTree(m) { t in t.contains { $0.label == "docs + web, Control 2" && !$0.value.isEmpty } }
            let marked = unique(tree) { labels.contains($0.label) && $0.role == "AXButton" }
            XCTAssertEqual(marked.map(\.label), labels, "\(scale)")
            XCTAssertEqual(marked.map(\.value), ["", "2 sessions need input", "1 session needs input"], "\(scale)")
            XCTAssertEqual(plain.map(\.value), ["", "", ""], "\(scale)")
            XCTAssertEqual(marked.map(\.frame), plain.map(\.frame), "no frame moves (\(scale))")
            XCTAssertEqual(m.layoutWrites, 0, "\(scale)")
        }
    }

    /// R901-s4b-q2: the inline field's state ends in the model when its layout is deleted (no write beyond the delete's
    /// one) or when the active layout changes (the switch's one write only). GUARD renaming-survives-a-delete.
    @MainActor
    func testAgentWindowLayoutSectionRenameStateEndsWithItsLayoutOrASwitch() throws {
        gate(true)
        let a = paneLayout([paneTarget("api")]), b = paneLayout([paneTarget("docs")]), c = paneLayout([paneTarget("web")])
        let (m, d) = try sectionModel([a, b, c], sessions: ["api", "docs", "web"])
        defer { m.close() }
        m.beginLayoutRename(b.id)
        XCTAssertEqual(m.layoutRenaming, b.id)
        XCTAssertNil(m.deleteLayout(b.id))
        XCTAssertTrue(m.layoutRenaming == nil, "its layout deleted: no field left")
        XCTAssertEqual(m.layoutWrites, 1, "the delete's one write only")
        XCTAssertEqual(m.layout.id, a.id, "an inactive delete keeps the active layout")
        m.beginLayoutRename(a.id)
        XCTAssertEqual(m.layoutRenaming, a.id)
        XCTAssertNil(m.switchLayout(c.id))
        XCTAssertTrue(m.layoutRenaming == nil, "another active layout: no field left")
        XCTAssertEqual(m.layoutWrites, 2, "the switch's one write only")
        XCTAssertEqual(savedLayouts(d).layouts.map(\.name), [nil, nil], "no name written")
    }
}
