import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1927 (operator: "empty pane cannot be dragged, and another session pane cannot be dragged on the other side of an
/// empty pane"): an empty pane takes a pane's drop on every zone as a session pane does, and drags itself by its header.
/// Fakes only: the drops go to the model's own methods (and once to the terminal view's AppKit drop with a fake
/// NSDraggingInfo); the views are built values or hosted in a never-shown window; no drag session, no posted event.
extension AgentWindowD1Tests {
    /// The panes of `m` by name ("" the empty one) to their frames in the wide area.
    @MainActor
    func emptyDropShape(_ m: AgentWindowModel, renaming from: String = "") -> [String: CGRect] {
        guard case let .tiled(f) = m.layout.frames(in: Self.wideArea, minimum: .zero, splitsEnabled: true) else { return [:] }
        var out: [String: CGRect] = [:]
        for (id, r) in f { out[paneSwitcherName(m, id).map { $0 == from ? "" : $0 } ?? "?"] = r }
        return out
    }

    /// Red at base for no line (the model took an empty target already: the refusal was the view's, see the hit row);
    /// kept so the drop on an empty pane stays the drop on a session pane. "api"'s pane header dragged onto each zone of
    /// pane 2: pane 2 empty lands exactly as pane 2 showing "web" (same panes, same frames, same focus), "web" read as empty.
    @MainActor
    func testPaneDropEmptyTargetEveryZoneLandsAsOnASessionPane() throws {
        let zones: [(String, CGPoint, PaneDropZone)] = [("centre", CGPoint(x: 500, y: 400), .centre),
                                                        ("left", CGPoint(x: 10, y: 400), .edge(.left)),
                                                        ("right", CGPoint(x: 990, y: 400), .edge(.right)),
                                                        ("up", CGPoint(x: 500, y: 10), .edge(.up)),
                                                        ("down", CGPoint(x: 500, y: 790), .edge(.down))]
        for (name, at, zone) in zones {
            XCTAssertEqual(PaneLayout.dropZone(at: at, in: Self.dropPane), zone, "control: \(name) is that zone")
            var landed: [[String: CGRect]] = []
            for second in ["web", nil] as [String?] {
                try paneSwitcherModel(["api", "web"], targets: ["api", second]) { m, panes in
                    let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
                    m.paneArea = Self.wideArea
                    let token = try XCTUnwrap(m.paneDragToken(a), "control: api's header drags")
                    m.dropOver(b, at: at, in: Self.dropPane)
                    XCTAssertTrue(m.dropHover?.pane == b && m.dropHover?.zone == zone, "\(name): the indicator on pane 2")
                    XCTAssertTrue(m.drop(token, into: b, at: at, in: Self.dropPane), "\(name): taken")
                    XCTAssertTrue(m.dropHover == nil && m.paneRefusal == nil, "\(name): no indicator, no refusal")
                    XCTAssertEqual(m.layout.order.count, 2, "\(name): moved or swapped, never copied")
                    XCTAssertEqual(paneSwitcherName(m, m.layout.focused), "api", "\(name): the dropped session has the focus")
                    landed.append(emptyDropShape(m, renaming: "web"))
                }
            }
            XCTAssertEqual(landed.count, 2)
            XCTAssertEqual(landed.first, landed.last, "\(name): an empty pane 2 takes the drop as one showing a session")
            XCTAssertEqual(landed.last.map { Set($0.keys) }, ["api", ""], "\(name): both panes kept")
        }
        // The operator's case: api dropped on the right edge of the empty pane goes to its right.
        try paneSwitcherModel(["api"], targets: ["api", nil]) { m, panes in
            let b = try XCTUnwrap(panes.last)
            m.paneArea = Self.wideArea
            XCTAssertTrue(m.drop(try dropToken("api"), into: b, at: CGPoint(x: 990, y: 400), in: Self.dropPane))
            XCTAssertEqual(m.layout.panes.map { paneSwitcherName(m, $0.id) }, ["", "api"], "api right of the empty pane")
            XCTAssertEqual(m.layout.order.first, b, "the empty pane kept, the old one closed")
        }
    }

    /// Red at base: paneDragToken was nil for an empty pane and drop(_:into:at:in:) matched sidebar rows only (no
    /// emptyPaneToken, no move: compile error). Mutants empty-pane-no-token, empty-drop-any-pane, empty-move-centre-no-swap,
    /// empty-move-edge-no-close.
    @MainActor
    func testPaneDropEmptyPaneDragsAndMoves() throws {
        try paneSwitcherModel(["api", "web"], targets: ["api", nil, "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), e = try XCTUnwrap(panes.dropFirst().first), w = try XCTUnwrap(panes.last)
            m.paneArea = Self.wideArea
            let token = try XCTUnwrap(m.paneDragToken(e), "an empty pane of several drags")
            XCTAssertEqual(token, AgentWindowModel.emptyPaneToken(e))
            XCTAssertFalse(m.rows.contains { AgentWindowModel.dragToken($0.id) == token }, "never a row's token")
            XCTAssertEqual(m.paneDragToken(a), try dropToken("api"), "a session pane keeps its row's token")
            // A pane that shows a session is never moved by an empty pane's token (stale or forged).
            let before = m.layout
            XCTAssertFalse(m.drop(AgentWindowModel.emptyPaneToken(a), into: w, at: CGPoint(x: 990, y: 400), in: Self.dropPane))
            XCTAssertTrue(m.layout == before, "a session pane's id as an empty pane's token: nothing")
            // Its own edge: only the focus.
            XCTAssertTrue(m.drop(token, into: e, at: CGPoint(x: 990, y: 400), in: Self.dropPane))
            XCTAssertEqual(m.layout.order, [a, e, w], "its own edge: no move")
            XCTAssertEqual(m.layout.focused, e)
            // The right edge of web's pane: the empty pane moves there (the old one closes, a new empty one splits).
            XCTAssertTrue(m.drop(token, into: w, at: CGPoint(x: 990, y: 400), in: Self.dropPane))
            XCTAssertEqual(m.layout.panes.map { paneSwitcherName(m, $0.id) }, ["api", "web", ""], "moved right of web")
            XCTAssertFalse(m.layout.order.contains(e), "the old empty pane closed")
            let moved = try XCTUnwrap(m.layout.order.last)
            XCTAssertEqual(m.layout.focused, moved, "the moved pane has the focus")
            // The centre of api's pane: the two swap (api into the empty pane's place, api's pane left empty).
            let next = try XCTUnwrap(m.paneDragToken(moved))
            XCTAssertTrue(m.drop(next, into: a, at: CGPoint(x: 500, y: 400), in: Self.dropPane))
            XCTAssertEqual(m.layout.order, [a, w, moved], "no pane added or closed")
            XCTAssertEqual(m.layout.panes.map { paneSwitcherName(m, $0.id) }, ["", "web", "api"], "the centre swaps")
            XCTAssertEqual(m.layout.focused, a, "the pane under the drop has the focus")
            // The bottom edge of web's pane: a rows split under it.
            XCTAssertTrue(m.drop(try XCTUnwrap(m.paneDragToken(a)), into: w, at: CGPoint(x: 500, y: 790), in: Self.dropPane))
            let low = m.layout.focused
            XCTAssertEqual(paneSwitcherName(m, low), "", "the empty pane, below web")
            guard case let .tiled(f) = m.layout.frames(in: Self.wideArea, minimum: .zero, splitsEnabled: true) else {
                return XCTFail("tiled")
            }
            let fw = try XCTUnwrap(f[w]), fl = try XCTUnwrap(f[low])
            XCTAssertEqual(fl.minY, fw.maxY, accuracy: 0.5, "under web")
            XCTAssertEqual(fl.minX, fw.minX, accuracy: 0.5, "in web's column")
        }
        // One pane: nothing to move, no drag.
        try paneSwitcherModel([], targets: [nil]) { m, panes in
            XCTAssertTrue(m.paneDragToken(try XCTUnwrap(panes.first)) == nil, "a lone empty pane does not drag")
        }
    }

    /// Red at base: no emptyPaneToken (compile error); with it, the terminal's AppKit drop handed the token to the model,
    /// which matched rows only and refused. The empty pane's header dropped on a session pane's terminal moves it.
    @MainActor
    func testPaneDropEmptyPaneTokenOverATerminalMovesThePane() throws {
        try paneSwitcherModel(["api"], targets: [nil, "api"]) { m, panes in
            let e = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            m.paneArea = Self.wideArea
            try paneDropRoutingHost(m, pane: b) { host, pb, pasted in
                XCTAssertTrue(pb.setData(Data(try XCTUnwrap(m.paneDragToken(e)).utf8), forType: .agentRow))
                let right = PaneDropRoutingDrag(pb, at: NSPoint(x: 990, y: 400))
                XCTAssertEqual(host.draggingEntered(right), .copy)
                XCTAssertEqual(m.dropHover?.zone, .edge(.right))
                XCTAssertTrue(host.performDragOperation(right), "the model took it")
                XCTAssertEqual(m.layout.panes.map { paneSwitcherName(m, $0.id) }, ["api", ""], "the empty pane right of api")
                XCTAssertFalse(m.layout.order.contains(e))
                XCTAssertEqual(pasted(), 0, "nothing pasted")
            }
        }
    }

    /// Red at base: the empty panes' headers had no AgentRowDrag (AgentDetailView.titled and AgentUnfocusedPane's
    /// placeholder header). Mutants empty-focused-header-no-drag, empty-unfocused-header-no-drag.
    @MainActor
    func testPaneDropEmptyPaneHeadersAreItsDragSource() throws {
        try paneSwitcherModel(["api"], targets: [nil, nil, "api"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.dropFirst().first), c = try XCTUnwrap(panes.last)
            XCTAssertEqual(m.layout.focused, a, "control: the first empty pane focused")
            let area = AgentPaneArea(model: m, scrolls: false)
            let focused = try XCTUnwrap(paneRiderFind(area.pane(a, compact: true), AgentDetailView.self))
            XCTAssertEqual(paneRiderFind(focused.body, AgentRowDrag.self)?.token, AgentWindowModel.emptyPaneToken(a),
                           "the focused empty pane's header drags it")
            let other = try XCTUnwrap(paneRiderFind(area.pane(b, compact: true), AgentUnfocusedPane.self))
            XCTAssertEqual(paneRiderFind(other.body, AgentRowDrag.self)?.token, AgentWindowModel.emptyPaneToken(b),
                           "an unfocused empty pane's header drags it")
            XCTAssertEqual(m.paneDragToken(c), try dropToken("api"), "a session pane keeps its row token")
        }
    }

    /// Red at base: the pane wrapper had no contentShape, so a point in an empty pane's blank edge band hit nothing of the
    /// pane (here: the window-move view laid behind, as #1914's row does) and SwiftUI's .onDrop never saw the drag.
    /// Mutant pane-no-content-shape. Hosted offscreen, never shown; the hit is AppKit's hitTest, no event.
    @MainActor
    func testPaneDropEmptyPaneBlankBandsTakeTheDrop() throws {
        /// The view AppKit's hitTest gives at `p` (top-left space) in `view` over a window-move view, hosted at `size`.
        func hit<V: View>(_ view: V, _ size: CGSize, _ p: CGPoint, ready: () -> Bool = { true }) -> NSView? {
            let (win, host) = AXTreeSupport.hosted(ZStack { AgentWindowDragArea(); view }, size)
            defer { win.close() }
            func drag(_ v: NSView) -> Bool { v is AgentWindowDragView || v.subviews.contains(where: drag) }
            for _ in 0..<50 where !drag(host) || !ready() {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(drag(host), "control: the window-move view is mounted behind")
            XCTAssertFalse(win.isVisible, "never shown")
            return host.hitTest(CGPoint(x: p.x, y: size.height - p.y))
        }
        // Control (the base bug): an empty pane's card alone, no contentShape: its blank band is not the card's.
        let card = AgentEmptyState(icon: "sidebar.left", title: "Select a session", detail: AgentPanePlaceholder.detail)
        let square = CGSize(width: 600, height: 600)
        XCTAssertTrue(hit(card.frame(width: 600, height: 600), square, CGPoint(x: 10, y: 300)) is AgentWindowDragView,
                      "control: a blank part of the card falls through")
        XCTAssertFalse(hit(card.frame(width: 600, height: 600).contentShape(Rectangle()), square, CGPoint(x: 10, y: 300))
                       is AgentWindowDragView, "control: with a contentShape the card takes it")
        try paneSwitcherModel([], targets: [nil, nil]) { m, _ in
            let size = CGSize(width: 1200, height: 600)
            // Pane 1 (focused) is x 0..600, pane 2 x 600..1200; bands are 100 deep, the header the top 26.
            for (name, x, y) in [("pane 2 right band", 1190.0, 300.0), ("pane 2 left band", 615.0, 300.0),
                                 ("pane 2 bottom band", 900.0, 560.0), ("pane 2 top band", 900.0, 60.0),
                                 ("pane 1 left band", 10.0, 300.0)] as [(String, CGFloat, CGFloat)] {
                let v = hit(AgentPaneArea(model: m, scrolls: false), size, CGPoint(x: x, y: y), ready: { m.paneArea.width > 0 })
                XCTAssertTrue(v != nil, "\(name): hit")
                XCTAssertFalse(v is AgentWindowDragView, "\(name): the pane takes it: \(String(describing: v))")
            }
        }
    }
}
