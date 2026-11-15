import Combine
import XCTest
@testable import ProsperApp

/// #901 B3 step 2 (spec 8.1, 11.2, 15.0; R3.4, R4.4, R901-s1-a, R901-s1-q1): switching between layouts as model
/// functions, nothing drawn, routed or read aloud. Every row uses a private in-memory suite (`layoutSuite`,
/// XCTestDefaults), never the app's or the operator's defaults; the split gate is saved, set and restored through
/// `gate(_:)`; no window, no event, no dch, no timer. Sessions are fakes; transcripts are files under tempDir(); the
/// session verbs are recording fakes (`Calls`, the `opened` counter), never run. Closures: the publish sinks, the
/// `onNewRuntime` seam and the transcripts' `offMain` seam all run on the main actor (the model calls them from its
/// main-actor code; the rows run each read inline).
extension AgentWindowD1Tests {
    /// What a switch did, in order: a runtime made (and whether every old pane had stopped by then), a page read.
    final class SwitchLog {
        var made: [UUID] = []
        var oldRunningAtMake: [Bool] = []
        var reads: [UUID] = []
        var old: [AgentTranscriptModel] = []
    }

    private func switchSuite(_ layouts: [PaneLayout], active: UUID) throws -> (UserDefaults, Data?) {
        let d = layoutSuite()
        d.set(try PaneLayoutStore(layouts: layouts, active: active, mru: [active]).encode(), forKey: "agentWindowLayouts")
        return (d, d.data(forKey: "agentWindowLayouts"))
    }

    private func onePane(_ name: String) -> PaneLayout { paneLayout([paneTarget(name)]) }

    /// 15.0 GATE-OFF GUARD (items 1 to 4): with the gate off every switch is refused (.layoutsOff) before anything is read
    /// or written: the same layout, the same store, the blob's bytes, 0 writes, 0 publishes. An in-layout change while
    /// the island is off is skipped as before (no write) and the island's return re-adopts the saved layout as before.
    @MainActor
    func testAgentWindowLayoutSwitchGateOffChangesNothing() throws {
        gate(false)
        let a = paneLayout([paneTarget("a"), paneTarget("b")]), b = onePane("b")
        let (d, bytes) = try switchSuite([a, b], active: a.id)
        let st = store([session("a", .idle), session("b", .idle)])
        let m = windowModel(st, layouts: d)
        defer { m.close() }
        m.setVisible(true)
        XCTAssertEqual(m.layoutWrites, 0, "opening writes nothing")
        let before = m.layout, stored = m.layouts
        var sends = 0
        let sink = m.objectWillChange.sink { _ in sends += 1 }
        XCTAssertEqual(m.switchLayout(b.id), .layoutsOff)
        XCTAssertEqual(m.switchLayout(a.id), .layoutsOff)
        XCTAssertEqual(m.switchLayout(number: 2), .layoutsOff)
        XCTAssertEqual(m.switchLayout(number: 7), .layoutsOff)
        XCTAssertEqual(m.previousLayout(), .layoutsOff)
        sink.cancel()
        XCTAssertEqual(sends, 0, "no publish")
        XCTAssertEqual(m.layoutWrites, 0, "no write")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes, "the blob as stored")
        XCTAssertEqual(m.layout, before)
        XCTAssertEqual(m.layouts, stored)
        XCTAssertEqual(m.shownPanes, [before.focused])

        // Item 4 with the gate off: an in-layout change while the island is off saves nothing, as before.
        m.bind(nil)
        let other = try XCTUnwrap(m.layout.order.last)
        m.adopt(try m.layout.focus(other).get())
        XCTAssertEqual(m.layoutWrites, 0, "island off, gate off: skipped as before")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes)
        m.bind(st)
        XCTAssertEqual(m.layout, before, "the island back: the saved layout, as before")
        XCTAssertEqual(m.layoutWrites, 0)
    }

    /// Items 1 and 3: by id, by number (1 to 9 in the list's order) and the MRU pair. The active layout, a number or id
    /// with no layout and a lone MRU: a value, nothing written. Each switch: ONE write, the MRU updated, the saved focus
    /// and zoom restored. With the island off a switch is saved and the island's return keeps it. Gate on.
    @MainActor
    func testAgentWindowLayoutSwitchWritesOnceAndUpdatesTheMRU() throws {
        gate(true)
        let a = onePane("a"), c = onePane("c")
        let pb = UUID(), pc = UUID()
        let b = PaneLayout(id: UUID(), name: "Review",
                           tree: .split(.columns, ratio: 0.5, .leaf(Pane(id: pb, target: paneTarget("b"))),
                                        .leaf(Pane(id: pc, target: paneTarget("c")))),
                           focused: pc, zoomed: pc)
        let (d, bytes) = try switchSuite([a, b, c], active: a.id)
        let st = store([session("a", .idle), session("b", .idle), session("c", .idle)])
        let m = windowModel(st, layouts: d)
        defer { m.close() }
        m.paneArea = Self.wideArea
        m.setVisible(true)
        XCTAssertEqual(m.layoutWrites, 0, "opening writes nothing")

        XCTAssertTrue(m.switchLayout(a.id) == nil, "the active layout: a no-op")
        XCTAssertEqual(m.previousLayout(), .noSuchLayout, "one layout in the MRU: a no-op")
        for n in [0, 4, 9, -1, Int.max, Int.min] {
            XCTAssertEqual(m.switchLayout(number: n), .noSuchLayout, "\(n)")
        }
        XCTAssertEqual(m.switchLayout(UUID()), .noSuchLayout)
        XCTAssertEqual(m.layoutWrites, 0, "nothing written")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes)
        XCTAssertEqual(m.layouts?.layouts.map(\.id), [a.id, b.id, c.id], "nothing made")
        XCTAssertEqual(m.layout.id, a.id)

        XCTAssertTrue(m.switchLayout(number: 2) == nil)
        XCTAssertEqual(m.layoutWrites, 1, "a switch: one write")
        XCTAssertEqual(m.layout, b, "focus and zoom as saved")
        XCTAssertEqual(savedLayouts(d).active, b.id)
        XCTAssertEqual(savedLayouts(d).mru, [b.id, a.id])
        XCTAssertEqual(m.layouts, savedLayouts(d))

        XCTAssertTrue(m.previousLayout() == nil)
        XCTAssertEqual(m.layoutWrites, 2)
        XCTAssertEqual(m.layout.id, a.id)
        XCTAssertEqual(savedLayouts(d).mru, [a.id, b.id])
        XCTAssertTrue(m.previousLayout() == nil)
        XCTAssertEqual(m.layoutWrites, 3)
        XCTAssertEqual(m.layout.focused, pc)
        XCTAssertEqual(m.layout.zoomed, pc)
        XCTAssertEqual(savedLayouts(d).mru, [b.id, a.id])
        XCTAssertTrue(m.switchLayout(c.id) == nil)
        XCTAssertEqual(m.layoutWrites, 4)
        XCTAssertEqual(savedLayouts(d).mru, [c.id, b.id, a.id])
        XCTAssertTrue(m.previousLayout() == nil)
        XCTAssertEqual(m.layoutWrites, 5)
        XCTAssertEqual(m.layout.id, b.id)
        XCTAssertEqual(savedLayouts(d).mru, [b.id, c.id, a.id])
        XCTAssertTrue(m.switchLayout(b.id) == nil)
        XCTAssertEqual(m.layoutWrites, 5, "the active layout again: nothing written")

        // The island off: the switch is saved once, and the island's return keeps it.
        m.bind(nil)
        XCTAssertEqual(m.layoutWrites, 5, "island off: nothing written")
        XCTAssertTrue(m.switchLayout(number: 1) == nil)
        XCTAssertEqual(m.layoutWrites, 6, "a switch while off: one write")
        XCTAssertEqual(m.layout, a)
        m.bind(st)
        XCTAssertEqual(m.layout.id, a.id, "the island back: not reverted")
        XCTAssertEqual(m.layoutWrites, 6, "the island back writes nothing")
        let saved = savedLayouts(d)
        XCTAssertEqual(saved.active, a.id)
        XCTAssertEqual(saved.mru, [a.id, b.id, c.id])
        XCTAssertEqual(saved.layouts.first { $0.id == b.id }, b, "the layout left while off keeps its target")
        let decoded = PaneLayoutStore.decode(d.data(forKey: "agentWindowLayouts"))
        XCTAssertEqual(decoded.repairs, [], "the blob the switches wrote needs no repair")
        XCTAssertEqual(decoded.store, m.layouts)
    }

    /// Item 2 (11.2, R4.4): a switch from two running panes to six transcript panes: every old pane stopped before a new
    /// runtime is made; 6 page reads, the focused pane's first, none repeated; one write. Gate on, a visible model.
    @MainActor
    func testAgentWindowLayoutSwitchStopsTheOldPanesBeforeAndStartsTheFocusedFirst() throws {
        gate(true)
        let oldNames = ["x1", "x2"], newNames = ["s1", "s2", "s3", "s4", "s5", "s6"]
        var files: [String: URL] = [:]
        for n in oldNames + newNames { files[n] = try transcriptFile(n) }
        let st = store((oldNames + newNames).map { session($0, .idle, path: files[$0]?.path) })
        let from = paneLayout(oldNames.map { paneTarget($0) })
        var to = paneLayout(newNames.map { paneTarget($0) })
        let fourth = try XCTUnwrap(to.order.dropFirst(3).first)
        to = try to.focus(fourth).get()
        let (d, _) = try switchSuite([from, to], active: from.id)
        let m = windowModel(st, layouts: d)
        defer { m.close() }
        m.paneArea = Self.wideArea
        let log = SwitchLog()
        let base = m.onNewRuntime
        m.onNewRuntime = { r in
            base(r)
            let pane = r.pane
            log.made.append(pane)
            log.oldRunningAtMake.append(log.old.contains { $0.running })
            r.transcript.offMain = { job in log.reads.append(pane); job() }   // on main, where poll() calls it
            r.transcript.taskStoreDirectory = { _ in nil }   // never a real task store
        }
        m.runtimes.values.forEach { $0.transcript.taskStoreDirectory = { _ in nil } }
        m.setVisible(true)
        log.old = from.order.compactMap { m.runtimes[$0]?.transcript }
        XCTAssertEqual(log.old.count, 2)
        XCTAssertTrue(log.old.allSatisfy(\.running), "the old layout's panes run")
        let writes = m.layoutWrites

        XCTAssertTrue(m.switchLayout(to.id) == nil)
        XCTAssertEqual(log.made.count, 6, "a runtime per new pane")
        XCTAssertEqual(log.oldRunningAtMake, Array(repeating: false, count: 6), "every old pane stopped before any new one")
        XCTAssertTrue(log.old.allSatisfy { !$0.running && !$0.suspended }, "stopped, not suspended")
        XCTAssertEqual(log.reads.first, fourth, "the focused pane is read first")
        XCTAssertEqual(log.reads.count, 6, "6 page reads")
        XCTAssertEqual(Set(log.reads), Set(to.order), "one per pane, none repeated")
        XCTAssertEqual(m.layout.focused, fourth)
        XCTAssertTrue(to.order.allSatisfy { m.runtimes[$0]?.transcript.running == true })
        XCTAssertEqual(m.layoutWrites, writes + 1, "one write per switch, never one per runtime")
    }

    /// R3.4 (8.1 :619-621): ten switches there and back, with and without a record of the gone session: 0 spawns: no
    /// open, no restart, stop, kill, resume or History verb, no New session form, no attach on the gone pane.
    @MainActor
    func testAgentWindowLayoutSwitchTenTimesSpawnsNothing() throws {
        gate(true)
        for withRecord in [false, true] {
            var opened = 0
            let gone = onePane("a"), live = onePane("b")
            let (d, _) = try switchSuite([gone, live], active: live.id)
            let st = store([session("b", .idle)], history: withRecord ? [record("a", ago: 30)] : [])
            let m = windowModel(st, opened: { _ in opened += 1 }, layouts: d)
            let calls = Calls()
            calls.wire(m)
            m.setVisible(true)
            for _ in 0..<10 {
                XCTAssertTrue(m.switchLayout(number: 1) == nil)
                XCTAssertEqual(m.layout.id, gone.id)
                XCTAssertTrue(m.terminal.key == nil, "no attach")
                XCTAssertTrue(m.interaction.session == nil, "the input follows nothing")
                XCTAssertTrue(m.previousLayout() == nil)
                XCTAssertEqual(m.layout.id, live.id)
            }
            XCTAssertEqual(opened, 0, "no open, record \(withRecord)")
            XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no restart, stop, kill, resume or History verb")
            XCTAssertTrue(m.newSession == nil, "no New session form")
            XCTAssertEqual(m.layoutWrites, 20, "one write per switch")
            m.close()
        }
    }

    /// Item 4 (decision c): a split and a focus move made while the island is off are saved (the pane bind(nil) emptied
    /// keeps its target in the blob), and the island's return keeps them. Gate on.
    @MainActor
    func testAgentWindowLayoutSwitchIslandOffSplitIsKept() throws {
        gate(true)
        let d = layoutSuite()
        let st = store([session("a", .idle), session("b", .idle)])
        let m = windowModel(st, layouts: d)
        defer { m.close() }
        m.paneArea = Self.wideArea
        m.setVisible(true)
        XCTAssertEqual(m.layoutWrites, 1, "the first fill")
        let first = try XCTUnwrap(m.focusedTarget)
        let firstPane = m.layout.focused
        m.bind(nil)
        XCTAssertTrue(m.focusedTarget == nil, "island off: the pane empties in memory")
        XCTAssertEqual(m.layoutWrites, 1, "island off: nothing written")

        m.adopt(try m.layout.split(axis: .columns, minimum: CGSize(width: 100, height: 100), in: Self.wideArea).get())
        XCTAssertEqual(m.layoutWrites, 2, "the split while off: one write")
        var saved = try XCTUnwrap(savedLayouts(d).activeLayout)
        XCTAssertEqual(saved.order.count, 2)
        XCTAssertEqual(saved.panes.first?.target, first, "the emptied pane keeps its target in the blob")
        XCTAssertTrue(saved.panes.last?.target == nil, "the new pane is empty")
        m.adopt(try m.layout.focus(firstPane).get())
        XCTAssertEqual(m.layoutWrites, 3, "the focus move while off: one write")
        saved = try XCTUnwrap(savedLayouts(d).activeLayout)
        XCTAssertEqual(saved.focused, firstPane)

        m.bind(st)
        XCTAssertEqual(m.layout.order.count, 2, "the island back: the split kept")
        XCTAssertEqual(m.layout.focused, firstPane, "and the focus")
        XCTAssertEqual(m.focusedTarget, first, "the target back")
        XCTAssertEqual(m.layout, saved)
        XCTAssertEqual(m.layoutWrites, 3, "the island back writes nothing")
    }

    /// R901-s1-a: a name read from the blob is cleaned like a Rename and counted as a repair: a long name and a name
    /// holding a control character are repaired, a clean name is not. The blob is written by the row.
    func testAgentWindowLayoutSwitchDecodeCleansEachStoredName() throws {
        func named(_ n: String) -> PaneLayout {
            var l = PaneLayout.single(paneTarget("a"))
            l.name = n
            return l
        }
        let long = named(String(repeating: "x", count: 100)), control = named("Do\u{7}cs"), clean = named("Review")
        let blob = try PaneLayoutStore(layouts: [long, control, clean], active: long.id, mru: [long.id]).encode()
        let out = PaneLayoutStore.decode(blob)
        XCTAssertEqual(out.repairs, [.layoutName, .layoutName], "only the first two")
        XCTAssertEqual(out.store.layouts.map(\.name), [String(repeating: "x", count: 64), "Docs", "Review"])
        XCTAssertEqual(out.store.layouts.map(\.id), [long.id, control.id, clean.id])
        XCTAssertEqual(PaneLayoutStore.decode(try out.store.encode()).repairs, [], "the cleaned store reads back clean")
    }

    /// R901-s1-q1: cleanName on the tree's outside-text rules: unseen fillers go (a name of them is automatic), a ZWJ
    /// between letters goes, combining marks are capped by OutsideText's own rule, an emoji family stays whole.
    func testAgentWindowLayoutSwitchCleanNameUsesTheOutsideTextRules() {
        for filler in ["\u{3164}", "\u{115F}", "\u{1160}", "\u{2800}", "\u{3164}\u{3164}"] {
            XCTAssertTrue(PaneLayoutStore.cleanName(filler) == nil, String(describing: filler.unicodeScalars.first?.value))
        }
        XCTAssertEqual(PaneLayoutStore.cleanName("\u{57}\u{6F}\u{200D}\u{72}\u{6B}"), "\u{57}\u{6F}\u{72}\u{6B}")
        let marked = "\u{61}" + String(repeating: "\u{301}", count: 50)
        let capped = PaneLayoutStore.cleanName(marked)
        XCTAssertEqual(capped, OutsideText.capMarks(marked), "OutsideText's own cap")
        XCTAssertLessThan(capped?.unicodeScalars.count ?? 51, 51)
        let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(PaneLayoutStore.cleanName(family), family)
    }
}
