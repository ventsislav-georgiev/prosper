import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1492: a sidebar row dragged onto a pane: the centre replaces that pane's session (PaneLayout.put, as the title
/// switcher), an edge band splits that pane on that side. Fakes only: no drag session, no posted event, no window shown;
/// the drop is handed to the model's own methods with the text a row's drag carries.
extension AgentWindowD1Tests {
    func dropKey(_ name: String) -> AgentSidebar.RowID { .live(AgentSessionKey(dir: "/tmp/dch-test", name: name)) }

    /// The text a row's drag carries.
    @MainActor
    func dropToken(_ name: String) throws -> String { try XCTUnwrap(AgentWindowModel.dragToken(dropKey(name))) }

    /// A pane's size for the drop calls (its band is a quarter of each side, at most sz(100)).
    static let dropPane = CGSize(width: 1000, height: 800)

    /// Red at base: no PaneLayout.dropZone. Mutant zone-unscaled (the band is 100, not sz(100)) fails the "just past the
    /// band" lines at 0.7 and 0.85. Corners: the edge the point is deeper into (relative to its band); a tie goes left/right.
    @MainActor
    func testPaneDropZoneMathAtEveryScale() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let s = Self.dropPane
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let b = 100 * scale
            let at = { (x: CGFloat, y: CGFloat) in PaneLayout.dropZone(at: CGPoint(x: x, y: y), in: s) }
            XCTAssertEqual(at(500, 400), .centre, "the middle at \(scale)")
            XCTAssertEqual(at(0.9 * b, 400), .edge(.left), "inside the left band at \(scale)")
            XCTAssertEqual(at(s.width - 0.9 * b, 400), .edge(.right), "right at \(scale)")
            XCTAssertEqual(at(500, 0.9 * b), .edge(.up), "top at \(scale)")
            XCTAssertEqual(at(500, s.height - 0.9 * b), .edge(.down), "bottom at \(scale)")
            XCTAssertEqual(at(1.1 * b, 400), .centre, "just past the left band at \(scale)")
            XCTAssertEqual(at(500, s.height - 1.1 * b), .centre, "just past the bottom band at \(scale)")
            XCTAssertEqual(at(0.5 * b, 0.8 * b), .edge(.left), "a corner deeper into the left band at \(scale)")
            XCTAssertEqual(at(s.width - 0.8 * b, 0.5 * b), .edge(.up), "a corner deeper into the top band at \(scale)")
            let square = CGSize(width: 1000, height: 1000)   // equal bands, so the two depths are the same number
            XCTAssertEqual(PaneLayout.dropZone(at: CGPoint(x: 0.5 * b, y: 0.5 * b), in: square), .edge(.left),
                           "an exact tie goes left or right at \(scale)")
            XCTAssertEqual(PaneLayout.dropRect(.edge(.left), in: s), CGRect(x: 0, y: 0, width: b, height: s.height))
            XCTAssertEqual(PaneLayout.dropRect(.centre, in: s), CGRect(x: b, y: b, width: s.width - 2 * b, height: s.height - 2 * b))
            // A small pane: the band is a quarter of its side (50 x 30), whatever the scale.
            let small = CGSize(width: 200, height: 120)
            XCTAssertEqual(PaneLayout.dropZone(at: CGPoint(x: 45, y: 60), in: small), .edge(.left))
            XCTAssertEqual(PaneLayout.dropZone(at: CGPoint(x: 55, y: 60), in: small), .centre)
            XCTAssertEqual(PaneLayout.dropZone(at: CGPoint(x: 100, y: 95), in: small), .edge(.down))
        }
        XCTAssertEqual(PaneLayout.dropZone(at: CGPoint(x: 1, y: 1), in: .zero), .centre, "no size: the centre")
    }

    /// Red at base: no AgentWindowModel.drop. Mutant drop-into-focused (the drop goes into the focused pane) fails the
    /// "into pane 2" lines: pane 1 is focused when the row lands on pane 2.
    @MainActor
    func testPaneDropCentreIntoAnUnfocusedPaneReplacesItsSessionAndFocusesIt() throws {
        try paneSwitcherModel(["api", "web", "db"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            XCTAssertEqual(m.layout.focused, a, "control: pane 1 focused")
            XCTAssertTrue(m.drop(try dropToken("db"), into: b, at: CGPoint(x: 500, y: 400), in: Self.dropPane))
            XCTAssertEqual(paneSwitcherName(m, b), "db", "into pane 2, the one under the drop")
            XCTAssertEqual(paneSwitcherName(m, a), "api", "pane 1 keeps its session")
            XCTAssertEqual(m.layout.focused, b, "the pane under the drop takes the focus")
            XCTAssertEqual(m.selectedRow?.title, "db", "the selection follows, as a sidebar click")
            XCTAssertEqual(m.layout.order.count, 2, "no split")
        }
    }

    /// Red at base: no AgentWindowModel.drop. A centre drop of a session shown in another pane swaps (PaneLayout.put).
    @MainActor
    func testPaneDropCentreOfASessionShownInAnotherPaneSwaps() throws {
        try paneSwitcherModel(["api", "web"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            XCTAssertTrue(m.drop(dropKey("api"), into: b, zone: .centre))
            XCTAssertEqual(paneSwitcherName(m, b), "api", "pane 2 shows the dropped session")
            XCTAssertEqual(paneSwitcherName(m, a), "web", "pane 1 takes pane 2's session (a swap)")
            XCTAssertEqual(m.layout.focused, b)
        }
    }

    /// Red at base: no PaneLayout.split(_:side:). Mutant edge-as-centre (an edge drop replaces) fails the count and the
    /// "new pane" lines.
    @MainActor
    func testPaneDropEdgeSplitsOnThatSideWithTheSessionInTheNewPane() throws {
        try paneSwitcherModel(["api", "web", "db", "log"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            m.paneArea = Self.wideArea
            // At (10, 400): the left band of pane 2.
            XCTAssertTrue(m.drop(try dropToken("db"), into: b, at: CGPoint(x: 10, y: 400), in: Self.dropPane))
            XCTAssertEqual(m.layout.order.count, 3, "pane 2 split")
            let new = m.layout.focused
            XCTAssertFalse([a, b].contains(new), "the new pane takes the focus")
            XCTAssertEqual(paneSwitcherName(m, new), "db", "the dropped session is in the new pane")
            XCTAssertEqual(paneSwitcherName(m, b), "web", "pane 2 keeps its session")
            XCTAssertEqual(m.layout.order, [a, new, b], "left of pane 2")
            XCTAssertEqual(m.selectedRow?.title, "db")
            // The bottom edge of pane 1: below it, in a rows split.
            XCTAssertTrue(m.drop(dropKey("log"), into: a, zone: .edge(.down)))
            let low = m.layout.focused
            guard case let .tiled(f) = m.layout.frames(in: Self.wideArea, minimum: .zero, splitsEnabled: true) else {
                return XCTFail("tiled")
            }
            let fa = try XCTUnwrap(f[a]), fl = try XCTUnwrap(f[low])
            XCTAssertEqual(paneSwitcherName(m, low), "log")
            XCTAssertEqual(fl.minY, fa.maxY, accuracy: 0.5, "under pane 1")
            XCTAssertEqual(fl.minX, fa.minX, accuracy: 0.5, "in pane 1's column")
        }
    }

    /// Red at the part a line (an already-shown session on an edge only focused its pane, no move): pane 1's session
    /// dropped on the left edge of pane 2 closes pane 1 and splits pane 2 with it. Mutants edge-no-move, move-leaves-old-pane.
    @MainActor
    func testPaneDropEdgeOfASessionShownElsewhereMovesIt() throws {
        try paneSwitcherModel(["api", "web", "db"], targets: ["api", "web", "db"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.dropFirst().first), c = try XCTUnwrap(panes.last)
            m.paneArea = Self.wideArea
            XCTAssertTrue(m.drop(dropKey("api"), into: b, zone: .edge(.left)))
            let new = m.layout.focused
            XCTAssertFalse(m.layout.order.contains(a), "the old pane is gone")
            XCTAssertEqual(m.layout.order, [new, b, c], "order: the moved session left of pane 2")
            XCTAssertEqual(paneSwitcherName(m, new), "api", "in the new pane, which has the focus")
            XCTAssertEqual(m.layout.panes.compactMap { paneSwitcherName(m, $0.id) }, ["api", "web", "db"])
            XCTAssertEqual(m.selectedRow?.title, "api")
        }
    }

    /// At the cap the close frees the slot: the move succeeds, the count stays. Mutant move-leaves-old-pane (no close) is refused at the cap.
    @MainActor
    func testPaneDropMoveAtTheCapSucceedsWithTheCountUnchanged() throws {
        try paneSwitcherModel(["a1", "a2", "a3", "a4", "a5", "a6"], targets: ["a1", "a2", "a3", "a4", "a5", "a6"]) { m, panes in
            let last = try XCTUnwrap(panes.last)
            m.paneArea = Self.wideArea
            XCTAssertEqual(m.layout.order.count, PaneLayout.maxPanes, "control: at the cap")
            XCTAssertTrue(m.drop(dropKey("a1"), into: last, zone: .edge(.right)))
            XCTAssertTrue(m.paneRefusal == nil, "no refusal")
            XCTAssertEqual(m.layout.order.count, PaneLayout.maxPanes, "the count is unchanged")
            XCTAssertFalse(m.layout.order.contains(try XCTUnwrap(panes.first)), "pane 1 closed")
            XCTAssertEqual(paneSwitcherName(m, m.layout.focused), "a1")
            XCTAssertEqual(m.layout.order.last, m.layout.focused, "right of the last pane")
        }
    }

    /// An edge drop on the session's own pane changes nothing but the focus.
    @MainActor
    func testPaneDropOnAnEdgeOfTheSessionsOwnPaneOnlyFocusesIt() throws {
        try paneSwitcherModel(["api", "web"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            m.paneArea = Self.wideArea
            m.adopt(try m.layout.focus(b).get())
            XCTAssertEqual(m.layout.focused, b, "control: pane 2 focused")
            XCTAssertTrue(m.drop(dropKey("api"), into: a, zone: .edge(.right)))
            XCTAssertEqual(m.layout.order, [a, b], "no split, no close")
            XCTAssertEqual(m.layout.focused, a)
            XCTAssertTrue(m.paneRefusal == nil)
        }
    }

    /// A move whose split is refused (no room) is refused whole: the old pane stays, the layout is unchanged, the notice shows.
    /// Mutant move-not-atomic (the close kept when the split is refused) fails the layout line.
    @MainActor
    func testPaneDropMoveRefusedAtTheMinimumChangesNothing() throws {
        try paneSwitcherModel(["api", "web", "db"], targets: ["api", "web", "db"]) { m, panes in
            let b = try XCTUnwrap(panes.dropFirst().first)
            m.paneArea = CGRect(x: 0, y: 0, width: 100, height: 100)
            let before = m.layout
            XCTAssertTrue(m.drop(dropKey("api"), into: b, zone: .edge(.left)))
            XCTAssertEqual(m.paneRefusal, .noRoom, "the split verbs' notice")
            XCTAssertEqual(m.layout, before, "nothing changes: the old pane is still there")
        }
    }

    /// Open to the Side keeps its rule 1: a session already shown only focuses its pane (nothing moves). Mutant side-also-moves.
    @MainActor
    func testOpenToTheSideOfAShownSessionStillOnlyFocuses() throws {
        try paneSwitcherModel(["api", "web"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            m.paneArea = Self.wideArea
            XCTAssertEqual(m.layout.focused, a, "control")
            m.openToTheSide(dropKey("web"))
            XCTAssertEqual(m.layout.order, [a, b], "nothing moves")
            XCTAssertEqual(m.layout.focused, b, "the pane showing it takes the focus")
        }
    }

    /// Red at base: no AgentWindowModel.drop. Mutant no-refusal-at-cap (split's cap skipped) fails every line: the
    /// seventh pane is made.
    @MainActor
    func testPaneDropEdgeAtTheCapShowsTheRefusalAndChangesNothing() throws {
        try paneSwitcherModel(["a1", "a2", "a3", "a4", "a5", "a6", "a7"], targets: ["a1", "a2", "a3", "a4", "a5", "a6"]) { m, panes in
            let second = try XCTUnwrap(panes.dropFirst().first)
            m.paneArea = Self.wideArea
            let before = m.layout
            XCTAssertEqual(before.order.count, PaneLayout.maxPanes, "control: at the cap")
            XCTAssertTrue(m.drop(dropKey("a7"), into: second, zone: .edge(.right)))
            XCTAssertEqual(m.paneRefusal, .cap, "the split verbs' notice")
            XCTAssertEqual(m.layout, before, "nothing changes")
            XCTAssertEqual(m.layout.focused, before.focused, "the focus stays")
        }
    }

    /// Red at base: no AgentWindowModel.dragToken. A History row carries no drag; its id dropped anyway is refused, and
    /// a text that names no row of this window changes nothing.
    @MainActor
    func testPaneDropHistoryRowIsNotDraggableAndIsRefused() throws {
        try paneSwitcherModel(["api", "web"], records: ["old"], targets: ["api", "web"]) { m, panes in
            let b = try XCTUnwrap(panes.last)
            let old = try XCTUnwrap(m.rows.first { $0.title == "old" }?.id, "control: the History row")
            XCTAssertTrue(AgentWindowModel.dragToken(old) == nil, "not draggable")
            let before = m.layout
            XCTAssertFalse(m.drop(old, into: b, zone: .centre))
            XCTAssertFalse(m.drop(String(describing: old), into: b, at: CGPoint(x: 500, y: 400), in: Self.dropPane))
            XCTAssertFalse(m.drop("not a row", into: b, at: CGPoint(x: 500, y: 400), in: Self.dropPane))
            XCTAssertEqual(m.layout, before, "nothing changes")
        }
    }

    /// Red at base: no AgentWindowModel.dropHover. Mutant indicator-sticks (dropExit keeps it) fails the "exit" line.
    @MainActor
    func testPaneDropIndicatorIsSetWhileOverAndClearedOnExitAndOnDrop() throws {
        try paneSwitcherModel(["api", "web", "db"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            XCTAssertTrue(m.dropHover == nil, "control: none")
            m.dropOver(b, at: CGPoint(x: 500, y: 400), in: Self.dropPane)
            XCTAssertEqual(m.dropHover?.pane, b)
            XCTAssertEqual(m.dropHover?.zone, .centre)
            m.dropOver(b, at: CGPoint(x: 990, y: 400), in: Self.dropPane)
            XCTAssertEqual(m.dropHover?.zone, .edge(.right), "the zone follows the drag")
            m.dropExit(a)
            XCTAssertEqual(m.dropHover?.pane, b, "another pane's exit leaves it")
            m.dropExit(b)
            XCTAssertTrue(m.dropHover == nil, "cleared on exit")
            m.dropOver(b, at: CGPoint(x: 500, y: 400), in: Self.dropPane)
            XCTAssertNotNil(m.dropHover?.pane)
            m.drop(try dropToken("db"), into: b, at: CGPoint(x: 500, y: 400), in: Self.dropPane)
            XCTAssertTrue(m.dropHover == nil, "cleared on drop")
        }
    }

    /// Red at base: no AgentWindowModel.drop. The split gate off: every point is the centre and an edge drop replaces.
    @MainActor
    func testPaneDropGateOffOnlyTheCentre() throws {
        try paneSwitcherModel(["api", "web"], targets: ["api"]) { m, panes in
            let only = try XCTUnwrap(panes.first)
            m.paneArea = Self.wideArea
            AgentPaneLayout.splitsEnabled = false   // the helper's defer restores the gate
            XCTAssertEqual(m.dropZone(at: CGPoint(x: 5, y: 400), in: Self.dropPane), .centre)
            m.dropOver(only, at: CGPoint(x: 5, y: 400), in: Self.dropPane)
            XCTAssertEqual(m.dropHover?.zone, .centre, "the indicator is the centre's")
            XCTAssertTrue(m.drop(try dropToken("web"), into: only, at: CGPoint(x: 5, y: 400), in: Self.dropPane))
            XCTAssertEqual(m.layout.order, [only], "no split")
            XCTAssertEqual(paneSwitcherName(m, only), "web", "the one pane's session is replaced")
            XCTAssertTrue(m.drop(dropKey("api"), into: only, zone: .edge(.left)))
            XCTAssertEqual(m.layout.order, [only], "an edge zone handed in still splits nothing")
            XCTAssertEqual(paneSwitcherName(m, only), "api")
        }
    }
}
