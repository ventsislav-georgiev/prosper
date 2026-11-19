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
        AXTreeSupport.tree(AgentSidebarView(model: m), CGSize(width: (AgentWindowModel.fullSidebarWidth - sz(16)), height: 900)) { t in
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
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
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
            XCTAssertTrue(shifts.allSatisfy { abs($0 - (shifts.first ?? 0)) <= pixel }, "by one amount (\(scale)): \(shifts)")
            XCTAssertEqual(zip(base, moved).filter { $0.size != $1.size }.count, 0, "sizes kept (\(scale))")
            XCTAssertEqual(layoutRows.count, 3, "\(scale)")
            XCTAssertTrue(layoutRows.allSatisfy { abs($0.frame.height - (layoutRows.first?.frame.height ?? 0)) <= pixel },
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

    /// Item 5 (9.1 :708) at 1.0, 0.85 and 0.7; #1646 (operator 2026-11-19): the band draws no layout name and no Edit
    /// layout (they moved to the Layouts section's active row): with two layouts every band frame equals the
    /// one-layout-of-one-pane band's and no name or Edit is built. Gate off: no band at all. GUARD band-has-no-layout-parts.
    @MainActor
    func testAgentWindowLayoutBandNameSlotAtThreeScales() throws {
        _ = ThemeStore.shared   // seeds ThemeRuntime.scale first, before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        // #1538: the band shows only with something in it; the sidebar hidden (both models) gives it the show glyph.
        let d = Preferences.defaults, hidden = d.object(forKey: Self.sidebarKey)
        defer { if let hidden { d.set(hidden, forKey: Self.sidebarKey) } else { d.removeObject(forKey: Self.sidebarKey) } }
        Preferences.agentWindowSidebarHidden = true
        let size = CGSize(width: 1400, height: 800)
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            gate(true)
            let (one, _) = try sectionModel([paneLayout([paneTarget("api")])])
            let base = bandSnapshot(one, size)
            one.close()
            let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("docs")])
            let (two, _) = try sectionModel([a, b])
            XCTAssertTrue(two.layoutShown, "\(scale)")
            let shown = bandSnapshot(two, size)
            two.close()
            XCTAssertTrue(base["layout"] != nil, "\(scale)")
            XCTAssertTrue(shown["layoutName"] == nil && shown["edit"] == nil, "no name, no Edit (\(scale)): \(shown.keys.sorted())")
            XCTAssertEqual(shown, base, "the band of two layouts is the one-layout band (\(scale))")
            gate(false)
            let (off, _) = try sectionModel([a, b])
            XCTAssertTrue(bandSnapshot(off, size).isEmpty, "gate off: no band, no slot (\(scale))")
            off.close()
        }
    }

    /// #1646 (operator 2026-11-19: "the edit (without the layout suffix) and done buttons directly on the sidebar, right
    /// aligned"): the active Layouts row ends in a button "Edit" (VoiceOver "Edit layout"), "Done" while editing, its own
    /// element after the row's name; the other rows have none. #1654: on the row's line, its right edge one sz(8) gap
    /// before the ⌃N chip's column (the column's width measured, the row's sz(10) padding after it), so both rows keep one
    /// width. The single-pane view (no active row) shows it nowhere. GUARD edit-only-on-the-active-row.
    @MainActor
    func testAgentWindowLayoutSectionEditButtonOnTheActiveRowOnly() throws {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let pixel = AXTreeSupport.devicePixel
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let column = NSHostingView(rootView: AgentSidebarRowView.digitColumn).fittingSize.width   // at this scale
            XCTAssertGreaterThan(column, 0, "\(scale)")
            gate(true)
            let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("api"), paneTarget("docs")])
            let (m, _) = try sectionModel([a, b], active: b.id, sessions: ["api", "docs", "ops"])
            defer { m.close() }
            m.setLayoutEditing(false)
            let tree = sidebarTree(m) { t in t.contains { $0.label == "Edit layout" } }
            let edit = unique(tree) { $0.label == "Edit layout" }
            XCTAssertEqual(edit.count, 1, "one Edit, on the active row only (\(scale))")
            XCTAssertEqual(edit.first?.role, "AXButton", "\(scale)")
            let rows = unique(tree) { ["Review, Control 1", "api + docs, Control 2"].contains($0.label) }
            XCTAssertEqual(rows.map(\.label), ["Review, Control 1", "api + docs, Control 2"], "the rows keep their labels (\(scale))")
            let other = try XCTUnwrap(rows.first), active = try XCTUnwrap(rows.last), button = try XCTUnwrap(edit.first)
            XCTAssertEqual(button.frame.midY, active.frame.midY, accuracy: 2 * pixel, "on the active row's line (\(scale))")
            XCTAssertTrue(button.frame.minX >= active.frame.minX + sz(10) - pixel, "inside the row (\(scale)): \(active.frame) \(button.frame)")
            XCTAssertEqual(button.frame.maxX, active.frame.maxX - sz(10) - column - sz(8), accuracy: 2 * pixel,
                           "right-aligned before the chip column (\(scale)): \(active.frame) \(button.frame) column \(column)")
            // the button lies over the row's own room for it: the active row keeps the other row's width (the name's
            // room is guarded in testAgentWindowLayoutChipSharesTheSessionChipColumnAtThreeScales)
            XCTAssertEqual(active.frame.width, other.frame.width, accuracy: pixel, "one row width (\(scale)): \(other.frame) \(active.frame)")
            XCTAssertEqual(active.frame.minX, other.frame.minX, accuracy: pixel, "\(scale)")
            let order = tree.filter { !$0.ignored }.map(\.label)
            let rowAt = try XCTUnwrap(order.firstIndex(of: "api + docs, Control 2")), editAt = try XCTUnwrap(order.firstIndex(of: "Edit layout"))
            XCTAssertLessThan(rowAt, editAt, "VoiceOver: the row, then its Edit (\(scale))")
            m.setLayoutEditing(true)
            let editing = sidebarTree(m) { t in t.contains { $0.label == "Done editing layout" } }
            XCTAssertEqual(unique(editing) { $0.label == "Done editing layout" }.count, 1, "Done while editing (\(scale))")
            XCTAssertFalse(editing.contains { $0.label == "Edit layout" }, "\(scale)")
            m.setLayoutEditing(false)
            m.click(.live(paneKey("ops")))
            XCTAssertTrue(m.parked != nil && m.layoutRows != nil, "the single-pane view, the section still built (\(scale))")
            let single = sidebarTree(m) { t in t.contains { $0.label == "Review, Control 1" } }
            XCTAssertFalse(single.contains { $0.label == "Edit layout" || $0.label == "Done editing layout" }, "no Edit in the view (\(scale))")
        }
    }

    /// #1654: every probed part's frame in the never-shown sidebar window, by "<kind> <title>" (layout parts by the
    /// layout's number), laid out until each of `want` reports (5 s ceiling), then twice more so the last frames stand.
    @MainActor
    private func sidebarProbes(_ m: AgentWindowModel, _ want: [String]) -> [String: CGRect] {
        let box = PaneProbeBox()
        AgentSidebarRowView.probe = { kind, title, r in box.seen["\(kind) \(title)"] = r }
        defer { AgentSidebarRowView.probe = nil }
        let (win, host) = AXTreeSupport.hosted(AgentSidebarView(model: m), CGSize(width: AgentWindowModel.fullSidebarWidth - sz(16), height: 900))
        defer { win.close() }
        func pass() { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let deadline = Date().addingTimeInterval(5)
        repeat { pass() } while want.contains { box.seen[$0] == nil } && Date() < deadline
        pass(); pass()
        XCTAssertFalse(win.isVisible, "never on screen")
        return box.seen
    }

    /// #1654 (operator 2026-11-19: "why is the layout shortcut not in the same style like the other shortcut buttons? to
    /// the right and with border etc like cmd + 1"), at 1.0, 0.85 and 0.7: each Layouts row's ⌃N is a keycap chip of a
    /// session chip's height (the border and padding, not plain text) whose right edge is the session row's ⌘N chip's
    /// of the same digit, to the pixel; the active row's Edit ends one sz(8) before its chip and after its name; an
    /// inactive row's name ends before its chip; the long names keep their room (the active one loses only the Edit and
    /// its gap, and in proportion to 1.0 at the smaller scales). VoiceOver: the rows read the name and "Control N", and no
    /// element reads the chip. GUARD layout-chip-in-the-session-chip-column.
    @MainActor
    func testAgentWindowLayoutChipSharesTheSessionChipColumnAtThreeScales() throws {
        _ = ThemeStore.shared   // seeds ThemeRuntime.scale from the prefs before it is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let pixel = AXTreeSupport.devicePixel
        var ratio1: CGFloat?   // the active name's width over the other name's at 1.0: the floor at 0.85 and 0.7
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            gate(true)
            let a = named(paneLayout([paneTarget("api")]), String(repeating: "review ", count: 12))
            let b = named(paneLayout([paneTarget("api"), paneTarget("docs")]), String(repeating: "layout ", count: 12))
            let (m, _) = try sectionModel([a, b], active: b.id, sessions: ["api", "docs", "ops"])
            defer { m.close() }
            m.setLayoutEditing(false)
            XCTAssertGreaterThanOrEqual(m.numberedIDs.count, 2, "two numbered session rows (\(scale))")
            let want = ["layoutChip 1", "layoutChip 2", "layoutName 1", "layoutName 2", "layoutSlot 1", "layoutSlot 2", "layoutEdit Edit",
                        "layoutEditRoom Edit", "digitChip 1", "digitChip 2"]
            let f = sidebarProbes(m, want)
            XCTAssertTrue(want.allSatisfy { f[$0] != nil }, "every part drawn (\(scale)): \(f.keys.sorted())")
            for n in 1...2 {
                let chip = try XCTUnwrap(f["layoutChip \(n)"]), session = try XCTUnwrap(f["digitChip \(n)"])
                XCTAssertEqual(chip.maxX, session.maxX, accuracy: pixel,
                               "⌃\(n)'s right edge is ⌘\(n)'s (\(scale)): \(chip) \(session)")
                XCTAssertEqual(chip.height, session.height, accuracy: pixel, "a keycap chip, not plain text (\(scale)): \(chip) \(session)")
                XCTAssertGreaterThan(chip.width, session.width / 2, "\(scale): \(chip) \(session)")
            }
            let chip1 = try XCTUnwrap(f["layoutChip 1"]), chip2 = try XCTUnwrap(f["layoutChip 2"])
            let other = try XCTUnwrap(f["layoutName 1"]), active = try XCTUnwrap(f["layoutName 2"]), edit = try XCTUnwrap(f["layoutEdit Edit"])
            XCTAssertEqual(edit.midY, chip2.midY, accuracy: 2 * pixel, "Edit on the chip's line (\(scale))")
            XCTAssertLessThanOrEqual(edit.maxX, chip2.minX - sz(8) + pixel, "Edit before the chip, never over it (\(scale)): \(edit) \(chip2)")
            XCTAssertLessThanOrEqual(active.maxX, edit.minX + pixel, "the name before the Edit (\(scale)): \(active) \(edit)")
            XCTAssertLessThanOrEqual(other.maxX, chip1.minX + pixel, "the name before the chip (\(scale)): \(other) \(chip1)")
            XCTAssertEqual(active.minX, other.minX, accuracy: pixel, "the names start at one x (\(scale))")
            // the row's room for Edit is the button's own width, at its place
            let room = try XCTUnwrap(f["layoutEditRoom Edit"])
            XCTAssertEqual(room.width, edit.width, accuracy: pixel, "the Edit room is the button's width (\(scale)): \(room) \(edit)")
            XCTAssertEqual(room.minX, edit.minX, accuracy: pixel, "the button lies over its room (\(scale)): \(room) \(edit)")
            // the name keeps all the room the button leaves: the active name's slot + the Edit + its sz(8) gap fill the
            // other's. The slots, not the Texts: a middle-truncated Text ends at a glyph edge, up to a glyph short of its
            // slot, and the two names cut at different glyphs (CI at 0.7, 1x: Texts 118 and 93 against 94.4).
            let otherSlot = try XCTUnwrap(f["layoutSlot 1"]), activeSlot = try XCTUnwrap(f["layoutSlot 2"])
            XCTAssertTrue(active.maxX <= activeSlot.maxX + pixel && other.maxX <= otherSlot.maxX + pixel,
                          "each name inside its slot (\(scale)): \(active) \(activeSlot) \(other) \(otherSlot)")
            XCTAssertLessThanOrEqual(activeSlot.maxX, edit.minX + pixel, "the slot before the Edit (\(scale)): \(activeSlot) \(edit)")
            // and reaches the trailing parts: past the attention slot and its gaps (one sz(8) spare for the Spacer's)
            XCTAssertGreaterThanOrEqual(activeSlot.maxX, edit.minX - AgentLayoutsSection.attentionWidth - 3 * sz(8) - pixel,
                                        "the slot reaches the attention slot (\(scale)): \(activeSlot) \(edit)")
            XCTAssertGreaterThanOrEqual(activeSlot.width, otherSlot.width - edit.width - sz(8) - 2 * pixel,
                                        "the name is not pushed out (\(scale)): \(otherSlot) \(activeSlot) \(edit)")
            let ratio = activeSlot.width / max(otherSlot.width, 1)
            if let r1 = ratio1 { XCTAssertGreaterThanOrEqual(ratio, r1 - 0.02, "name width in proportion to 1.0 (\(scale))") } else { ratio1 = ratio }
            let tree = sidebarTree(m) { t in t.contains { $0.label == "Edit layout" } }
            let labels = unique(tree) { $0.label.contains("Control ") && $0.role == "AXButton" }.map(\.label)
            XCTAssertEqual(labels.count, 2, "the two rows read their name and key (\(scale)): \(labels)")
            XCTAssertTrue(labels.last?.hasSuffix(", Control 2") == true, "\(scale): \(labels)")
            XCTAssertFalse(tree.contains { !$0.ignored && ($0.reads("\u{2303}1") || $0.reads("\u{2303}2")) }, "no element reads the chip (\(scale))")
        }
    }

    /// #1657 (QA R1654 n3): Row details > Shortcut off drops the Layouts rows' ⌃N chip and its column like the session rows' ⌘N
    /// (the store's in-memory details, the same the session rows read; no preference is written), at 1.0: no layoutChip
    /// and no session chipColumn is drawn, the names' slots end one trailing column (chip column + one sz(8) gap) further
    /// right than with Shortcut on, and the active row's Edit button stays over its room at the trailing edge. GUARD
    /// layout-chip-follows-row-details-shortcut.
    @MainActor
    func testAgentWindowLayoutChipFollowsTheRowDetailsShortcutToggle() throws {
        _ = ThemeStore.shared   // seeds ThemeRuntime.scale from the prefs before it is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        gate(true)
        let pixel = AXTreeSupport.devicePixel
        let a = named(paneLayout([paneTarget("api")]), String(repeating: "review ", count: 12))
        let b = named(paneLayout([paneTarget("api"), paneTarget("docs")]), String(repeating: "layout ", count: 12))
        let (m, _) = try sectionModel([a, b], active: b.id, sessions: ["api", "docs", "ops"])
        defer { m.close() }
        m.setLayoutEditing(false)
        let parts = ["layoutName 1", "layoutName 2", "layoutSlot 1", "layoutSlot 2", "layoutEdit Edit", "layoutEditRoom Edit"]
        let on = sidebarProbes(m, parts + ["layoutChip 1", "layoutChip 2", "digitChip 1"])
        XCTAssertTrue((parts + ["layoutChip 1", "layoutChip 2"]).allSatisfy { on[$0] != nil }, "on: every part drawn: \(on.keys.sorted())")
        let column = try XCTUnwrap(on.first { $0.key.hasPrefix("chipColumn ") }?.value, "on: the session rows' chip column")
        let saveDetails = m.store?.details
        defer { if let saveDetails { m.store?.details = saveDetails } }
        var off = AgentIslandRowDetails.all
        off.shortcut = false
        m.store?.details = off
        let f = sidebarProbes(m, parts)
        XCTAssertTrue(parts.allSatisfy { f[$0] != nil }, "off: every part drawn: \(f.keys.sorted())")
        XCTAssertTrue(f.keys.allSatisfy { !$0.hasPrefix("layoutChip ") && !$0.hasPrefix("chipColumn ") && !$0.hasPrefix("digitChip ") },
                      "off: no chip, no chip column: \(f.keys.sorted())")
        for n in 1...2 {
            let was = try XCTUnwrap(on["layoutSlot \(n)"]), now = try XCTUnwrap(f["layoutSlot \(n)"])
            XCTAssertEqual(now.maxX - was.maxX, column.width + sz(8), accuracy: pixel,
                           "slot \(n) takes the chip column and its gap: \(was) \(now) \(column)")
        }
        let edit = try XCTUnwrap(f["layoutEdit Edit"]), room = try XCTUnwrap(f["layoutEditRoom Edit"]), slot = try XCTUnwrap(f["layoutSlot 2"])
        XCTAssertEqual(edit.minX, room.minX, accuracy: pixel, "off: Edit stays over its room: \(edit) \(room)")
        XCTAssertLessThanOrEqual(slot.maxX, edit.minX + pixel, "off: the name before the Edit: \(slot) \(edit)")
    }

    /// #1648: the button itself is pressed (the hosted tree's accessibilityPerformPress, what VoiceOver does; never a posted
    /// event): the label flips Edit layout -> Done editing layout and `layoutEditing` with it, then back.
    @MainActor
    func testAgentWindowLayoutSectionEditButtonPressToggles() throws {
        gate(true)
        let a = named(paneLayout([paneTarget("api")]), "Review"), b = paneLayout([paneTarget("api"), paneTarget("docs")])
        let (m, _) = try sectionModel([a, b], active: b.id)
        defer { m.close() }
        m.setLayoutEditing(false)
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let size = CGSize(width: (AgentWindowModel.fullSidebarWidth - sz(16)), height: 900)
        let (win, host) = AXTreeSupport.hosted(AgentSidebarView(model: m), size)
        defer { win.close() }
        func settle(_ label: String) -> NSObject? {
            _ = AXTreeSupport.poll(host) { t in t.contains { $0.label == label } }
            return pressable(host, label: label)
        }
        XCTAssertFalse(m.layoutEditing)
        let edit = try XCTUnwrap(settle("Edit layout"), "an Edit button that takes a press")
        XCTAssertTrue(press(edit))
        let done = try XCTUnwrap(settle("Done editing layout"), "the label flips to Done editing layout")
        XCTAssertTrue(m.layoutEditing, "the press toggled the model on")
        XCTAssertTrue(press(done))
        XCTAssertNotNil(settle("Edit layout"), "and back to Edit layout")
        XCTAssertFalse(m.layoutEditing, "the second press toggled it off")
    }

    private func pressable(_ e: Any, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 60, let o = e as? NSObject else { return nil }
        let sel = NSSelectorFromString("accessibilityPerformPress")
        if o.responds(to: Selector(("accessibilityLabel"))), (o.value(forKey: "accessibilityLabel") as? String) == label,
           o.responds(to: sel) { return o }
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
            if let found = pressable(k, label: label, depth: depth + 1) { return found }
        }
        return nil
    }

    private func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard o.responds(to: sel) else { return false }
        if let p = o as? NSAccessibilityProtocol { return p.accessibilityPerformPress() }
        _ = o.perform(sel)
        return true
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
