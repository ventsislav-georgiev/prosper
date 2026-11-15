import Combine
import XCTest
@testable import ProsperApp

/// #901 B3 step 1 (spec 8.1, 15.0; N1217-b, R1194-3): the layout list operations as model functions, nothing drawn or
/// routed. Every row uses a private in-memory suite (`layoutSuite`, XCTestDefaults), never the app's or the operator's
/// defaults; the split gate is saved, set and restored through `gate(_:)`; no window, no event, no dch, no timer.
/// Closures: the publish counters' sinks run on the main actor (the model publishes from main-actor code).
extension AgentWindowD1Tests {
    private func listSuiteBlob(_ d: UserDefaults) -> Data? { d.data(forKey: "agentWindowLayouts") }

    /// The name is outside data: literal inputs and the stored names they become. Never a format string, never a path.
    func testAgentWindowLayoutListNameIsCleanedAndBounded() {
        let long = String(repeating: "x", count: 100)
        let rows: [(raw: String?, name: String?)] = [
            (nil, nil),
            ("", nil),
            ("   \n\t ", nil),
            ("  Review  ", "Review"),
            ("api\n\tfix", "api fix"),
            ("a \u{2028}  b", "a b"),
            ("a\u{0}b\u{7}c", "abc"),
            ("safe\u{202E}txt", "safetxt"),
            ("%@ %n %s", "%@ %n %s"),
            ("/Users/example/dch", "/Users/example/dch"),
            ("👩\u{200D}👩\u{200D}👧", "👩\u{200D}👩\u{200D}👧"),
            (long, String(repeating: "x", count: 64)),
            (String(repeating: "a ", count: 40), String(repeating: "a ", count: 32).trimmingCharacters(in: .whitespaces)),
        ]
        for row in rows {
            XCTAssertEqual(PaneLayoutStore.cleanName(row.raw), row.name, String(describing: row.raw?.unicodeScalars.count))
        }
        // One character carrying a million combining marks: bounded work, a bounded result.
        let heavy = "e" + String(repeating: "\u{301}", count: 1_000_000)
        let cleaned = PaneLayoutStore.cleanName(heavy)
        XCTAssertLessThanOrEqual(cleaned?.unicodeScalars.count ?? 0, PaneLayoutStore.maxNameLength * 16)
        XCTAssertEqual(cleaned?.count, 1)
    }

    /// 8.1: automatic = the pane titles joined with " + ", middle-truncated to 64 characters.
    func testAgentWindowLayoutListAutomaticNameJoinsAndMiddleTruncates() {
        XCTAssertEqual(PaneLayoutStore.automaticName([]), "")
        XCTAssertEqual(PaneLayoutStore.automaticName(["api-fix", "docs"]), "api-fix + docs")
        XCTAssertEqual(PaneLayoutStore.automaticName(["api\nfix", " ", "docs"]), "api fix + docs")
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let cut = PaneLayoutStore.automaticName([a, b])
        XCTAssertEqual(cut, String(repeating: "a", count: 31) + "…" + String(repeating: "b", count: 32))
        XCTAssertEqual(cut.count, 64)
    }

    /// Duplicate's name: automatic stays automatic; a set name takes the first free number; never a set name twice.
    func testAgentWindowLayoutListDuplicateNameNeverCollides() {
        func named(_ n: String?) -> PaneLayout { PaneLayout(id: UUID(), name: n, tree: .leaf(Pane(id: UUID(), target: nil)),
                                                             focused: UUID(), zoomed: nil) }
        let s = PaneLayoutStore(layouts: [named("Review"), named("Review 2"), named(nil)], active: UUID(), mru: [])
        XCTAssertEqual(s.duplicateName(of: "Review"), "Review 3")
        XCTAssertEqual(s.duplicateName(of: "Review 2"), "Review 2 2")
        XCTAssertEqual(s.duplicateName(of: "Main"), "Main 2")
        XCTAssertTrue(s.duplicateName(of: nil) == nil, "automatic stays automatic")
        let long = String(repeating: "x", count: 64)
        XCTAssertEqual(s.duplicateName(of: long), String(repeating: "x", count: 62) + " 2", "bounded with its number")
    }

    /// Duplicate's value: fresh layout and pane ids, the same targets, axis, ratio, and the focus and zoom on the copies.
    func testAgentWindowLayoutListDuplicatedHasFreshIdsAndTheSameShape() {
        let pa = UUID(), pb = UUID()
        let source = PaneLayout(id: UUID(), name: "Review",
                                tree: .split(.columns, ratio: 0.3, .leaf(Pane(id: pa, target: paneTarget("a"))),
                                             .leaf(Pane(id: pb, target: paneTarget("b")))),
                                focused: pb, zoomed: pb)
        let copy = source.duplicated(name: "Review 2")
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.name, "Review 2")
        XCTAssertEqual(copy.order.count, 2)
        XCTAssertTrue(Set(copy.order).isDisjoint(with: [pa, pb]), "no pane id shared with the source")
        XCTAssertEqual(copy.panes.map(\.target), [paneTarget("a"), paneTarget("b")])
        XCTAssertEqual(copy.focused, copy.order.last, "the focus stays on the second pane")
        XCTAssertEqual(copy.zoomed, copy.order.last, "the zoom too")
        if case let .split(axis, ratio, _, _) = copy.tree {
            XCTAssertEqual(axis, .columns)
            XCTAssertEqual(ratio, 0.3)
        } else {
            XCTFail("the split is kept")
        }
    }

    /// New, Rename, Duplicate, Delete on the model, gate on: literal lists and names, ONE write per action that changes
    /// the store and none for one that does not (R1194-3: deleting the active layout writes exactly once), the last
    /// layout kept, the active layout always a stored one; the island off: every op still saved once and the island's
    /// return keeps it (the re-adopt does not revert it). The saved blob decodes with no repair to the model's store.
    @MainActor
    func testAgentWindowLayoutListOpsWriteOncePerAction() throws {
        gate(true)
        let d = layoutSuite()
        let st = store([session("a", .idle), session("b", .idle)])
        let m = windowModel(st, layouts: d)
        defer { m.close() }
        m.setVisible(true)
        XCTAssertEqual(m.layoutWrites, 1, "the first fill")
        let first = m.layout.id
        let firstTargets = m.layout.panes.map(\.target)

        XCTAssertTrue(m.newLayout() == nil)
        XCTAssertEqual(m.layoutWrites, 2, "New: one write")
        var saved = savedLayouts(d)
        let made = try XCTUnwrap(saved.layouts.last?.id)
        XCTAssertEqual(saved.layouts.map(\.id), [first, made])
        XCTAssertEqual(saved.active, made)
        XCTAssertEqual(saved.mru, [made, first])
        XCTAssertEqual(m.layout.id, made, "New is the active layout")
        XCTAssertTrue(m.layout.name == nil, "automatic")
        XCTAssertEqual(m.layout.panes.map(\.target), [nil], "one empty pane")
        XCTAssertEqual(m.layouts, saved)

        XCTAssertTrue(m.renameLayout(made, to: "  Review\n") == nil)
        XCTAssertEqual(m.layoutWrites, 3, "Rename: one write")
        XCTAssertEqual(savedLayouts(d).layouts.map(\.name), [nil, "Review"])
        XCTAssertEqual(m.layout.name, "Review")
        XCTAssertTrue(m.renameLayout(made, to: "Review") == nil)
        XCTAssertEqual(m.layoutWrites, 3, "the same cleaned name: no write")
        XCTAssertTrue(m.renameLayout(made, to: "  ") == nil)
        XCTAssertEqual(m.layoutWrites, 4)
        XCTAssertTrue(m.layout.name == nil, "an empty rename returns to automatic")
        XCTAssertTrue(m.renameLayout(first, to: "Main") == nil)
        XCTAssertEqual(m.layoutWrites, 5, "renaming the inactive layout: one write")
        XCTAssertEqual(m.layout.id, made, "and no switch")
        XCTAssertEqual(savedLayouts(d).layouts.map(\.name), ["Main", nil])
        XCTAssertEqual(m.renameLayout(UUID(), to: "x"), .noSuchLayout)

        XCTAssertTrue(m.duplicateLayout(first) == nil)
        XCTAssertEqual(m.layoutWrites, 6, "Duplicate: one write")
        saved = savedLayouts(d)
        let dup = try XCTUnwrap(saved.layouts.last)
        XCTAssertEqual(saved.layouts.map(\.id), [first, made, dup.id])
        XCTAssertEqual(saved.layouts.map(\.name), ["Main", nil, "Main 2"])
        XCTAssertEqual(saved.mru, [dup.id, made, first])
        XCTAssertEqual(m.layout.id, dup.id, "the copy is active")
        XCTAssertEqual(dup.panes.map(\.target), firstTargets)
        let firstPanes = try XCTUnwrap(saved.layouts.first).order
        XCTAssertTrue(Set(dup.order).isDisjoint(with: firstPanes), "no shared pane id")
        XCTAssertEqual(m.duplicateLayout(UUID()), .noSuchLayout)
        XCTAssertEqual(m.layoutWrites, 6)

        // R1194-3: the active layout deleted: exactly one write, the MRU's next active, in memory and stored.
        XCTAssertTrue(m.deleteLayout(dup.id) == nil)
        XCTAssertEqual(m.layoutWrites, 7, "Delete of the active layout: exactly one write")
        saved = savedLayouts(d)
        XCTAssertEqual(saved.layouts.map(\.id), [first, made])
        XCTAssertEqual(saved.active, made)
        XCTAssertEqual(saved.mru, [made, first])
        XCTAssertEqual(m.layout.id, made)
        let decoded = PaneLayoutStore.decode(listSuiteBlob(d))
        XCTAssertEqual(decoded.repairs, [], "the blob the ops wrote needs no repair")
        XCTAssertEqual(decoded.store, m.layouts)

        // The island off: each op is saved once, and the island's return keeps it.
        m.bind(nil)
        XCTAssertEqual(m.layoutWrites, 7, "island off: nothing written")
        XCTAssertTrue(m.newLayout() == nil)
        XCTAssertEqual(m.layoutWrites, 8, "New while off: one write")
        let offMade = m.layout.id
        XCTAssertTrue(m.deleteLayout(offMade) == nil)
        XCTAssertEqual(m.layoutWrites, 9, "Delete of the active layout while off: exactly one write")
        XCTAssertEqual(m.layout.id, made)
        XCTAssertTrue(m.renameLayout(made, to: "Docs") == nil)
        XCTAssertEqual(m.layoutWrites, 10, "Rename while off: one write")
        m.bind(st)
        XCTAssertEqual(m.layout.id, made, "the island back: not reverted")
        XCTAssertEqual(m.layout.name, "Docs")
        XCTAssertEqual(m.layoutWrites, 10, "the island back writes nothing")
        XCTAssertEqual(savedLayouts(d).layouts.map(\.name), ["Main", "Docs"])

        // Down to one: the last layout stays.
        XCTAssertTrue(m.deleteLayout(first) == nil)
        XCTAssertEqual(m.layoutWrites, 11, "Delete of an inactive layout: one write")
        XCTAssertEqual(m.deleteLayout(made), .lastLayout)
        XCTAssertEqual(m.layoutWrites, 11)
        XCTAssertEqual(savedLayouts(d).layouts.map(\.id), [made])
        XCTAssertEqual(savedLayouts(d).active, made)
    }

    /// N1217-b: at 9 layouts New and Duplicate are refused as a value (.layoutCap, the "(9 layouts max)" suffix), and
    /// nothing is made, switched, written or dropped; a rebind keeps the 9. At 8 the ninth is made. Gate on.
    @MainActor
    func testAgentWindowLayoutListTenthLayoutIsRefusedNotDropped() throws {
        gate(true)
        let st = store([session("a", .idle)])
        for count in [8, 9] {
            let d = layoutSuite()
            let nine = (0..<count).map { _ in PaneLayout.single(paneTarget("a")) }
            let ids = nine.map(\.id)
            let firstID = try XCTUnwrap(ids.first)
            d.set(try PaneLayoutStore(layouts: nine, active: firstID, mru: [firstID]).encode(), forKey: "agentWindowLayouts")
            let bytes = listSuiteBlob(d)
            let m = windowModel(st, layouts: d)
            m.setVisible(true)
            XCTAssertEqual(m.layoutWrites, 0, "\(count): opening writes nothing")
            if count == 8 {
                XCTAssertTrue(m.newLayout() == nil, "the ninth is made")
                XCTAssertEqual(m.layoutWrites, 1)
                XCTAssertEqual(savedLayouts(d).layouts.count, 9)
                XCTAssertEqual(m.layouts?.layouts.count, 9)
            } else {
                XCTAssertEqual(m.newLayout(), .layoutCap, "New at 9: refused visibly")
                XCTAssertEqual(m.duplicateLayout(firstID), .layoutCap, "Duplicate at 9: refused visibly")
                XCTAssertEqual(PaneRefusal.layoutCap.menuSuffix, "(9 layouts max)")
                XCTAssertEqual(m.layoutWrites, 0, "nothing written")
                XCTAssertEqual(listSuiteBlob(d), bytes, "the blob as stored")
                XCTAssertEqual(m.layout.id, firstID, "no switch")
                XCTAssertEqual(m.layouts?.layouts.map(\.id), ids, "the 9, in order; nothing made to be dropped later")
                m.bind(st)
                XCTAssertEqual(m.layout.id, firstID, "a rebind keeps the active layout")
                XCTAssertEqual(m.layouts?.layouts.map(\.id), ids)
                XCTAssertEqual(m.layoutWrites, 0)
            }
            m.close()
        }
    }

    /// 15.0 GATE-OFF GUARD: with the gate off New, Rename and Duplicate are refused (.layoutsOff) before anything is read
    /// or written: one layout, the same layout value, the blob's bytes, the write count and 0 publishes, as today.
    @MainActor
    func testAgentWindowLayoutListGateOffChangesNothing() throws {
        gate(false)
        let d = layoutSuite()
        let st = store([session("a", .idle), session("b", .idle)])
        let m = windowModel(st, layouts: d)
        defer { m.close() }
        m.setVisible(true)
        XCTAssertEqual(m.layoutWrites, 1, "the first fill, as today")
        let before = m.layout, writes = m.layoutWrites, bytes = listSuiteBlob(d)
        var sends = 0
        let sink = m.objectWillChange.sink { _ in sends += 1 }
        defer { sink.cancel() }
        XCTAssertEqual(m.newLayout(), .layoutsOff)
        XCTAssertEqual(m.duplicateLayout(before.id), .layoutsOff)
        XCTAssertEqual(m.renameLayout(before.id, to: "Review"), .layoutsOff)
        XCTAssertEqual(sends, 0, "no publish")
        XCTAssertEqual(m.layoutWrites, writes, "no write")
        XCTAssertEqual(listSuiteBlob(d), bytes, "the blob as stored")
        XCTAssertEqual(m.layout, before)
        XCTAssertEqual(m.layouts?.layouts.count, 1, "the single layout")
        XCTAssertEqual(m.shownPanes, [before.focused])
    }
}
