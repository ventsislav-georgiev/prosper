import AppKit
import XCTest
@testable import ProsperApp

/// #831 B1 step 3b (#1217, riders R1194-1, R1194-2): the window loads and saves the layout store, and the island going
/// off and on keeps the saved target. The model rows use a private in-memory suite (`XCTestDefaults`) each; the one
/// show() row uses Preferences.defaults, which under XCTest is the process's scratch XCTestDefaults (never the app's
/// or the operator's defaults), and removes its key in setUp and after the row. No dch, no window on screen, no event.
@MainActor
final class AgentWindowIslandReturnTests: XCTestCase {

    /// 8.2: the rows that show the window remove the shared key first: a blob left by an earlier row would make this
    /// row's window start on that row's layout.
    nonisolated override func setUp() {
        super.setUp()
        Preferences.defaults.removeObject(forKey: "agentWindowLayouts")
    }

    /// R1194-1: AgentsWindow.show() builds its model on Preferences.defaults, so a blob there is the layout the window
    /// opens on (its id, tree and focused target), and opening writes nothing. The window is built by a fake and never
    /// shown (fakeAgentsForToggle); its occlusion is not visible, so no fill and no pick run.
    func testAgentWindowShowStartsOnTheSavedActiveLayout() throws {
        let l = UUID(), p = UUID()
        let blob = Data("""
            {"v": 1, "unknown": "kept", "layouts": [{"id": "\(l)", "focused": "\(p)",
              "tree": {"pane": "\(p)", "session": {"dir": "/tmp/dch-test", "name": "api"}}}], "active": "\(l)"}
            """.utf8)
        Preferences.defaults.set(blob, forKey: "agentWindowLayouts")
        addTeardownBlock { @MainActor in Preferences.defaults.removeObject(forKey: "agentWindowLayouts") }
        let (f, _) = fakeAgentsForToggle()
        let w = AgentsWindow.shared
        XCTAssertFalse(w.isOpen)
        w.show()
        let m = try XCTUnwrap(w.model)
        XCTAssertEqual(m.layout.id, l, "the blob's active layout")
        XCTAssertEqual(m.layout.order, [p])
        XCTAssertEqual(m.focusedTarget, .session(dir: "/tmp/dch-test", name: "api"))
        XCTAssertEqual(m.layouts?.active, l)
        XCTAssertEqual(m.layoutWrites, 0, "opening writes nothing")
        XCTAssertEqual(Preferences.defaults.data(forKey: "agentWindowLayouts"), blob, "the blob as stored")
        XCTAssertEqual(f.presents, 1)
        w.window?.close()
        XCTAssertFalse(w.isOpen)
        XCTAssertFalse(f.built.last?.isVisible ?? true, "never on screen")
    }
}

/// R1194-2 (QA 935 cases A and B). bind(nil) (the island off) empties the focused pane in memory and saves nothing;
/// bind(store) (the island back) must bring the saved layout back before the first refresh: never the first-row pick
/// over it (A), never an empty pane while the blob keeps the target (B). Writes are counted by the model's autosave
/// (`layoutWrites`, one per Preferences.setAgentWindowLayouts call) and by the stored bytes; no timer, no wait.
extension AgentWindowD1Tests {
    /// A hand-written blob (unsorted keys, an unknown field: any rewrite shows in the bytes) of one layout `l` whose
    /// tree is `panes` (one leaf, or two in columns), each a live session target; the first pane is focused.
    func islandBlob(_ l: UUID, _ panes: [(id: UUID, name: String)]) -> Data {
        let leaves = panes.map { #"{"pane": "\#($0.id)", "session": {"dir": "/tmp/dch-test", "name": "\#($0.name)"}}"# }
        let tree = leaves.count == 1 ? leaves[0]
            : #"{"split": "columns", "ratio": 0.5, "first": \#(leaves[0]), "second": \#(leaves[leaves.count - 1])}"#
        let focused = panes.first?.id ?? l
        return Data(#"{"v": 1, "unknown": "kept", "layouts": [{"id": "\#(l)", "focused": "\#(focused)", "tree": \#(tree)}], "active": "\#(l)"}"#.utf8)
    }

    /// The first-row pick on `st` (a model with no suite: nothing saved), and the other of two rows: the target a row
    /// saves, so a first-row pick over it shows.
    @MainActor
    func firstAndOther(_ st: AgentIslandStore) throws -> (first: String, other: String) {
        let probe = windowModel(st)
        defer { probe.close() }
        probe.setVisible(true)
        let first = probe.selection == .live(paneKey("a")) ? "a" : "b"
        XCTAssertEqual(probe.selection, .live(paneKey(first)), "the first fill picks one of the two")
        return first == "a" ? ("a", "b") : ("b", "a")
    }

    /// Case A: the window opened while the island is off (show() binds nil right after init). init restores the saved
    /// target T, bind(nil) empties it in memory; the island back brings T back with no write (the bytes as stored), and
    /// no first-row pick runs. A later pick is the person's change: one write. Rows: one pane; the gate off (15.0) with a
    /// two-pane blob (the whole tree comes back, the focused pane alone shown, the blob never rewritten).
    @MainActor
    func testAgentWindowIslandOffAtOpenThenBackRestoresTheSavedTargetWithNoWrite() throws {
        let st = store([session("a", .idle), session("b", .idle)])
        let names = try firstAndOther(st)
        let l = UUID(), pa = UUID(), pb = UUID()
        let rows: [(why: String, panes: [(id: UUID, name: String)])] = [
            ("one pane", [(pa, names.other)]),
            ("gate off, two panes (15.0)", [(pa, names.other), (pb, names.first)]),
        ]
        gate(false)
        for row in rows {
            let d = layoutSuite()
            let blob = islandBlob(l, row.panes)
            d.set(blob, forKey: "agentWindowLayouts")
            let m = windowModel(nil, layouts: d)   // as show() with the island off: init, then bind(nil)
            m.paneArea = Self.wideArea
            m.setVisible(true)
            XCTAssertTrue(m.focusedTarget == nil, "island off: the pane empties in memory (\(row.why))")
            XCTAssertEqual(m.layoutWrites, 0, row.why)
            m.bind(st)   // the island back
            XCTAssertEqual(m.focusedTarget, paneTarget(names.other), "the saved target comes back: \(row.why)")
            XCTAssertEqual(m.selection, .live(paneKey(names.other)), "never the first-row pick: \(row.why)")
            XCTAssertEqual(m.layout.order, row.panes.map(\.id), "the whole tree: \(row.why)")
            XCTAssertEqual(m.shownPanes, [pa], "the focused pane alone: \(row.why)")
            XCTAssertEqual(m.layoutWrites, 0, "the return alone writes nothing: \(row.why)")
            XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), blob, "the blob as stored: \(row.why)")
            for _ in 0..<3 { st.sessions = st.sessions }
            XCTAssertEqual(m.layoutWrites, 0, "publishes: \(row.why)")
            m.select(.live(paneKey(names.first)))
            XCTAssertEqual(m.layoutWrites, 1, "a real change after it: one write (\(row.why))")
            // 7.1: in the two-pane row the pick is the session pane pb already shows, so the focus moves there.
            let after = savedLayouts(d).activeLayout
            XCTAssertEqual(after?.panes.first(where: { $0.id == after?.focused })?.target, paneTarget(names.first), row.why)
            XCTAssertEqual(after?.order, row.panes.map(\.id), row.why)
            XCTAssertEqual(after, m.layout, "the saved layout is the window's: \(row.why)")
            m.close()
        }
    }

    /// Case B: the island goes off after the first fill (`filled` stays set, so no pick runs on its return). The saved
    /// target T comes back with no write; a re-bind with the same store changes nothing; a real change writes once.
    @MainActor
    func testAgentWindowIslandOffAfterTheFillThenBackRestoresTheSavedTargetWithNoWrite() throws {
        let st = store([session("a", .idle), session("b", .idle)])
        let names = try firstAndOther(st)
        let d = layoutSuite()
        let m = windowModel(st, layouts: d)
        defer { m.close() }
        m.setVisible(true)
        XCTAssertEqual(m.selection, .live(paneKey(names.first)), "the first fill")
        XCTAssertEqual(m.layoutWrites, 1)
        m.select(.live(paneKey(names.other)))
        XCTAssertEqual(m.layoutWrites, 2, "the person's target T: saved")
        let saved = try XCTUnwrap(d.data(forKey: "agentWindowLayouts"))
        let layout = m.layout
        m.bind(nil)
        XCTAssertTrue(m.focusedTarget == nil, "island off: the pane empties in memory")
        XCTAssertEqual(m.layoutWrites, 2)
        m.bind(st)
        XCTAssertEqual(m.focusedTarget, paneTarget(names.other), "the saved target comes back, not an empty pane")
        XCTAssertEqual(m.selection, .live(paneKey(names.other)))
        XCTAssertEqual(m.layout, layout, "the same layout id, tree and focus")
        XCTAssertEqual(m.layoutWrites, 2, "the return alone writes nothing")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), saved)
        m.bind(st)
        for _ in 0..<3 { st.sessions = st.sessions }
        XCTAssertEqual(m.layoutWrites, 2, "a re-bind with the same store and publishes: nothing")
        XCTAssertEqual(m.focusedTarget, paneTarget(names.other))
        m.select(.live(paneKey(names.first)))
        XCTAssertEqual(m.layoutWrites, 3, "a real change after it: one write")
        XCTAssertEqual(savedLayouts(d).activeLayout?.panes.first?.target, paneTarget(names.first))
    }

    /// The causes that do NOT reach the re-adopt (the loaded layout equals the current one): no blob, a corrupt blob.
    /// Their pane was empty before the island went off, so the return makes the first fill's pick and saves it once,
    /// as before step 3b; a corrupt blob's bytes are kept first (8.2).
    @MainActor
    func testAgentWindowIslandBackWithNoSavedTargetMakesTheFirstPickOnce() throws {
        let st = store([session("a", .idle), session("b", .idle)])
        let names = try firstAndOther(st)
        let bad = Data("{".utf8)
        for blob in [nil, bad] {
            let d = layoutSuite()
            if let blob { d.set(blob, forKey: "agentWindowLayouts") }
            let m = windowModel(nil, layouts: d)
            m.setVisible(true)
            m.bind(st)
            XCTAssertEqual(m.selection, .live(paneKey(names.first)), "the first fill: \(blob == nil ? "none" : "corrupt")")
            XCTAssertEqual(m.layoutWrites, 1, "one write")
            XCTAssertEqual(savedLayouts(d).activeLayout?.panes.first?.target, paneTarget(names.first))
            XCTAssertEqual(d.data(forKey: "agentWindowLayoutsCorrupt"), blob, "a corrupt blob is kept before the write")
            m.close()
        }
    }
}
