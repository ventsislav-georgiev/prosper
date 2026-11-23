import XCTest
@testable import ProsperApp

/// #831 B1 step 3 (spec 8.1, 15.0, riders R899-2, R899-3, R1193-3, R1193-6): the window model loads the layout store
/// when it opens and saves every change. Every row uses a private in-memory suite (`XCTestDefaults`), never the app's
/// or the operator's defaults; the split gate is saved, set and restored by the row; no dch, no window, no event.
extension AgentWindowD1Tests {
    /// A private suite per row: an `XCTestDefaults` keeps its values in the object, so nothing outlives the row.
    func layoutSuite() -> UserDefaults { XCTestDefaults(suiteName: "prosper-window-layouts-\(UUID().uuidString)")! }

    func savedLayouts(_ d: UserDefaults) -> PaneLayoutStore { Preferences.agentWindowLayouts(in: d) }

    /// 15.0: the gate at `on` for this row; the saved value comes back after it (never a reset to false).
    @MainActor
    func gate(_ on: Bool) {
        let saved = AgentPaneLayout.splitsEnabled
        AgentPaneLayout.splitsEnabled = on
        addTeardownBlock { @MainActor in AgentPaneLayout.splitsEnabled = saved }
    }

    func slot(_ l: UUID, _ p: UUID) -> AgentPaneLayout.PaneSlot { AgentPaneLayout.PaneSlot(layout: l, pane: p) }

    /// Item 7, the relaunch row (4.5): a model of the same owner and the same suite restores the focused pane's session
    /// from the blob, writes nothing to do it, and runs that session's transcript; a model with no suite ignores it.
    @MainActor
    func testAgentWindowRelaunchRestoresTheFocusedPanesSessionFromTheBlob() throws {
        let d = layoutSuite(), home = AgentLastLiveHome()
        let a = try transcriptFile("a")
        let st = store([session("a", .idle, path: a.path), session("b", .idle)])
        let first = windowModel(st, lastLive: home, layouts: d)
        first.setVisible(true)
        first.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
        XCTAssertGreaterThan(first.layoutWrites, 0, "a pick is a change: saved")
        let blob = try XCTUnwrap(d.data(forKey: "agentWindowLayouts"))
        XCTAssertEqual(savedLayouts(d).active, first.layout.id)
        XCTAssertEqual(savedLayouts(d).activeLayout?.panes.map(\.target), [paneTarget("a")])
        first.close()

        let again = windowModel(st, lastLive: home, layouts: d)
        defer { again.close() }
        XCTAssertEqual(again.layout, first.layout, "the same layout id, tree and focus")
        XCTAssertEqual(again.focusedTarget, paneTarget("a"))
        again.setVisible(true)
        st.sessions = st.sessions
        XCTAssertEqual(again.selection, .live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")), "never the first-row pick")
        XCTAssertTrue(again.transcript.running, "the restored pane's transcript runs")
        XCTAssertEqual(again.layoutWrites, 0, "a restore writes nothing")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), blob)

        let none = windowModel(st)
        defer { none.close() }
        XCTAssertNotEqual(none.layout.id, first.layout.id, "no suite: nothing loaded")
        none.setVisible(true)
        none.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "b")))
        XCTAssertEqual(none.layoutWrites, 0, "no suite: nothing saved")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), blob)
    }

    /// 8.1 autosave: a change writes once; a publish, or a pick that changes nothing, writes nothing. Counted per write,
    /// no timer. The island off empties the pane in memory but not the blob (not the user's change).
    @MainActor
    func testAgentWindowAutosaveWritesOncePerChangeAndNeverOnAPublish() throws {
        let d = layoutSuite()
        let st = store([session("a", .idle), session("b", .idle)])
        let m = windowModel(st, layouts: d)
        defer { m.close() }
        XCTAssertEqual(m.layoutWrites, 0, "opening writes nothing")
        XCTAssertTrue(d.object(forKey: "agentWindowLayouts") == nil)
        m.setVisible(true)
        XCTAssertEqual(m.layoutWrites, 1, "the first fill is a change")
        let picked = try XCTUnwrap(m.selection)
        for _ in 0..<5 { st.sessions = st.sessions }
        XCTAssertEqual(m.layoutWrites, 1, "5 publishes that change nothing: 0 writes")
        m.select(picked)
        m.adopt(m.layout)
        XCTAssertEqual(m.layoutWrites, 1, "the same pick and the same layout again: 0 writes")
        let other: AgentSidebar.RowID = picked == .live(AgentSessionKey(dir: "/tmp/dch-test", name: "a"))
            ? .live(AgentSessionKey(dir: "/tmp/dch-test", name: "b")) : .live(AgentSessionKey(dir: "/tmp/dch-test", name: "a"))
        m.select(other)
        XCTAssertEqual(m.layoutWrites, 2, "another row: one write")
        XCTAssertEqual(savedLayouts(d), m.layouts)
        XCTAssertEqual(savedLayouts(d).activeLayout, m.layout)
        for _ in 0..<5 { st.sessions = st.sessions }
        XCTAssertEqual(m.layoutWrites, 2)
        let kept = d.data(forKey: "agentWindowLayouts")
        m.bind(nil)
        XCTAssertTrue(m.focusedTarget == nil, "island off: the pane empties in memory")
        XCTAssertEqual(m.layoutWrites, 2, "island off: nothing written")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), kept, "the blob keeps the user's target")
    }

    /// 15.0: with the gate off a saved two-pane blob renders its focused pane alone (only its transcript runs), the tree
    /// is kept, and the blob is not rewritten: the bytes as stored (hand-written: unsorted keys, an unknown field, so any
    /// rewrite shows). A later pick saves the whole tree with the focused pane retargeted. Control: gate on, both run;
    /// #1895: there the pick of a session outside the layout parks it (rule 1) and writes nothing.
    @MainActor
    func testAgentWindowGateOffRestoreShowsTheFocusedPaneAloneAndNeverRewritesTheBlob() throws {
        let a = try transcriptFile("a"), b = try transcriptFile("b")
        let l = UUID(), pa = UUID(), pb = UUID()
        let text = """
            {"v": 1, "unknown": "kept", "layouts": [{"id": "\(l)", "focused": "\(pa)", "tree": {"split": "columns",
              "ratio": 0.5, "first": {"pane": "\(pa)", "session": {"dir": "/tmp/dch-test", "name": "a"}},
              "second": {"pane": "\(pb)", "session": {"dir": "/tmp/dch-test", "name": "b"}}}}], "active": "\(l)"}
            """
        let rows: [(why: String, gate: Bool, running: [String: Bool])] = [
            ("gate off (15.0): the focused pane alone", false, ["a": true, "b": false]),
            ("gate on (control): both panes tiled", true, ["a": true, "b": true]),
        ]
        for row in rows {
            gate(row.gate)
            let d = layoutSuite()
            d.set(Data(text.utf8), forKey: "agentWindowLayouts")
            let st = store([session("a", .idle, path: a.path), session("b", .idle, path: b.path), session("c", .idle)])
            let m = windowModel(st, layouts: d)
            m.paneArea = Self.wideArea
            m.setVisible(true)
            for _ in 0..<3 { st.sessions = st.sessions }
            XCTAssertEqual(m.layout.id, l, row.why)
            XCTAssertEqual(m.layout.order, [pa, pb], "the tree is kept: \(row.why)")
            XCTAssertEqual(m.shownPanes, row.gate ? [pa, pb] : [pa], row.why)
            for (name, run) in row.running.sorted(by: { $0.key < $1.key }) {
                XCTAssertEqual(try runtime(m, name).transcript.running, run, "\(name): \(row.why)")
            }
            XCTAssertEqual(m.layoutWrites, 0, "the reduction is never saved: \(row.why)")
            XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), Data(text.utf8), "the blob as stored: \(row.why)")
            m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "c")))
            if row.gate {
                // #1895 rule 1: gate on, the two-pane layout is a made one: a pick outside it parks it (the single-pane
                // view), nothing written, the blob as stored
                XCTAssertEqual(m.parked?.id, l, row.why)
                XCTAssertEqual(m.layout.panes.map(\.target), [paneTarget("c")], row.why)
                XCTAssertEqual(m.layoutWrites, 0, row.why)
                XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), Data(text.utf8), "parked, the blob as stored: \(row.why)")
                m.close()
                continue
            }
            XCTAssertEqual(m.layoutWrites, 1, row.why)
            let saved = try XCTUnwrap(savedLayouts(d).activeLayout)
            XCTAssertEqual(saved.order, [pa, pb], "a pick saves the whole tree: \(row.why)")
            XCTAssertEqual(saved.panes.map(\.target), [paneTarget("c"), paneTarget("b")], row.why)
            m.close()
        }
    }

    /// R899-3 second half, R1193-3: the owner's map is pruned on load (a pane in no stored layout loses its sight; a
    /// pane of an inactive stored layout keeps it) and on a layout delete; after N opens of a window it holds one entry
    /// per shown pane, not one more per open. Literal key sets.
    @MainActor
    func testAgentWindowLoadAndDeletePruneTheOwnersMapButKeepInactiveSights() throws {
        let l1 = UUID(), l2 = UUID(), stale = UUID(), p1 = UUID(), p2 = UUID(), p9 = UUID()
        let one = PaneLayout(id: l1, name: nil, tree: .leaf(Pane(id: p1, target: paneTarget("a"))), focused: p1, zoomed: nil)
        let two = PaneLayout(id: l2, name: "Review", tree: .leaf(Pane(id: p2, target: paneTarget("b"))), focused: p2,
                             zoomed: nil)
        let sight = LastLive(at: Self.now - 60, claudeSessionID: "")
        let st = store([session("a", .idle), session("b", .idle)])
        for activeFirst in [true, false] {
            let d = layoutSuite()
            let stored = PaneLayoutStore(layouts: [one, two], active: activeFirst ? l1 : l2, mru: activeFirst ? [l1, l2] : [l2, l1])
            d.set(try stored.encode(), forKey: "agentWindowLayouts")
            let home = AgentLastLiveHome()
            home.map = [slot(l1, p1): sight, slot(l2, p2): sight, slot(stale, p9): sight]
            let m = windowModel(st, lastLive: home, layouts: d)
            XCTAssertEqual(Set(home.map.keys), [slot(l1, p1), slot(l2, p2)], "load: the stale layout's sight goes, the inactive one's stays")
            XCTAssertEqual(m.layout.id, activeFirst ? l1 : l2)
            m.setVisible(true)
            // Delete the active layout when it is l2 (hand-over to l1), else the inactive l2.
            XCTAssertNil(m.deleteLayout(l2))
            XCTAssertEqual(Set(home.map.keys), [slot(l1, p1)], "delete: its sights go")
            XCTAssertEqual(m.layout.id, l1, "the MRU's next is active")
            XCTAssertEqual(savedLayouts(d).layouts.map(\.id), [l1])
            XCTAssertEqual(savedLayouts(d).active, l1)
            XCTAssertEqual(m.deleteLayout(l1), .lastLayout, "the last layout stays")
            XCTAssertEqual(Set(home.map.keys), [slot(l1, p1)])
            m.close()
        }
        // N opens with the same owner and suite: one entry for the one shown pane, every time.
        let d = layoutSuite(), home = AgentLastLiveHome()
        let only = store([session("a", .idle)])
        var counts: [Int] = []
        for _ in 0..<5 {
            let m = windowModel(only, lastLive: home, layouts: d)
            m.setVisible(true)
            only.sessions = only.sessions   // a publish: stamps the shown pane
            counts.append(home.map.count)
            m.close()
        }
        XCTAssertEqual(counts, [1, 1, 1, 1, 1], "never one more entry per open")
    }

    /// R899-2: select()'s browse rule (show, `.focused`) is refused only for a layout whose focus is not in its tree
    /// (`.noSuchPane`; decode() repairs that, so only a built fixture reaches it): the refusal is kept on the model for
    /// the pane notice line and the layout stays; the next pick that lands drops it. On a restored three-pane layout
    /// every pick lands, gate off and on (literal table), and nothing is refused.
    @MainActor
    func testAgentWindowRefusedPickKeepsTheRefusalAndEveryRestoredPickLands() throws {
        let k = { (n: String) in AgentSessionKey(dir: "/tmp/dch-test", name: n) }
        let picks: [(why: String, row: AgentSidebar.RowID?, focused: String?)] = [
            ("a row another pane shows: focus moves there", .live(k("b")), "b"),
            ("a new row: into the focused pane", .live(k("c")), "c"),
            ("nothing: the focused pane empties", nil, nil),
        ]
        for on in [false, true] {
            gate(on)
            let st = store([session("a", .idle), session("b", .idle), session("c", .idle)])
            let m = windowModel(st)
            m.paneArea = Self.wideArea
            m.setVisible(true)
            for p in picks {
                m.adopt(paneLayout([paneTarget("a"), paneTarget("b"), nil]))
                m.select(p.row)
                XCTAssertTrue(m.paneRefusal == nil, "\(p.why), gate \(on)")
                XCTAssertEqual(m.layout.panes.count, 3, "\(p.why), gate \(on)")
                XCTAssertEqual(m.focusedTarget, p.focused.map { paneTarget($0) }, "\(p.why), gate \(on)")
            }
            let fixture = paneLayout([paneTarget("a"), paneTarget("b")])
            let dangling = PaneLayout(id: fixture.id, name: nil, tree: fixture.tree, focused: UUID(), zoomed: nil)
            m.adopt(dangling)
            m.select(.live(k("c")))
            XCTAssertEqual(m.paneRefusal, .noSuchPane, "refused: kept, never dropped (gate \(on))")
            XCTAssertEqual(m.layout, dangling, "the layout stays as it was")
            m.adopt(fixture)
            m.select(.live(k("c")))
            XCTAssertTrue(m.paneRefusal == nil, "a pick that lands drops it (gate \(on))")
            m.close()
        }
    }

    /// R3.4 with a record: a layout whose session is gone, switched to 10 times while a record of the name exists:
    /// without a last live sight the placeholder, with one the record (4.1a); either way 0 spawns: no open, no resume,
    /// no restart, no attach, the input follows nothing.
    @MainActor
    func testAgentWindowLayoutWithAGoneSessionAndARecordSpawnsNothing() throws {
        let r = record("a", ago: 30)
        for sighted in [false, true] {
            var opened = 0
            let home = AgentLastLiveHome()
            let st = store([session("b", .idle)], history: [r])
            let m = windowModel(st, opened: { _ in opened += 1 }, lastLive: home)
            let calls = Calls()
            calls.wire(m)
            m.setVisible(true)
            let gone = paneLayout([paneTarget("a")]), other = paneLayout([paneTarget("b")])
            if sighted, let p = gone.panes.first?.id { home.map[slot(gone.id, p)] = LastLive(at: Self.now - 60, claudeSessionID: "") }
            for _ in 0..<10 {
                m.adopt(gone)
                XCTAssertEqual(m.content, sighted ? .history(r) : .notRunning(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
                XCTAssertEqual(m.selection, sighted ? .history(r.id) : nil)
                XCTAssertFalse(m.focusedEnded)
                XCTAssertFalse(m.transcript.running)
                XCTAssertFalse(m.openSelected())
                XCTAssertTrue(m.terminal.key == nil, "no attach")
                XCTAssertTrue(m.interaction.session == nil, "the input follows nothing")
                m.adopt(other)
            }
            XCTAssertEqual(opened, 0, "no open (no `dch -n a`), sighted \(sighted)")
            XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no restart, stop, kill, resume or History verb")
            m.close()
        }
    }

    /// R1193-6: a switch to another layout with the same pane ids, the same row and the same Ended state frees the old
    /// models before it makes the new one; the ask sink must follow the NEW focused model (by identity, never by an
    /// address a freed model may hand on). A question that lands after the switch reaches the input.
    @MainActor
    func testAgentWindowSwitchToALayoutWithTheSamePaneIdsRebindsTheAsk() throws {
        let a = try transcriptFile("a")
        let st = store([session("a", .blocked, path: a.path)])
        let m = windowModel(st)
        defer { m.close() }
        let fixture = paneLayout([paneTarget("a")])
        m.adopt(fixture)
        m.setVisible(true)
        let before = m.transcript
        XCTAssertTrue(before.running)
        let dup = PaneLayout(id: UUID(), name: nil, tree: fixture.tree, focused: fixture.focused, zoomed: nil)
        m.adopt(dup)
        XCTAssertTrue(m.transcript !== before, "a switch: a new model")
        XCTAssertTrue(m.transcript.running)
        XCTAssertTrue(m.interaction.ask == nil)
        let ask: [String: Any] = ["questions": [["question": "Which colors?", "header": "Colors", "multiSelect": false,
                                                 "options": [["label": "Red", "description": "Red"],
                                                             ["label": "Blue", "description": "Blue"]]]]]
        try append(a, line(toolUse("ask_a", "AskUserQuestion", ask)))
        m.transcript.tick()
        XCTAssertEqual(m.transcript.pendingAsk?.id, "ask_a")
        XCTAssertEqual(m.interaction.ask?.id, "ask_a", "the new model's question reaches the input")
    }
}
