import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ProsperApp

/// #1492 part c (QA m1): a sidebar row dragged over a pane that shows a live terminal. The terminal (libghostty's
/// AppTerminalView) registers text for drops and is the deepest view under the pointer, so a row's drag must be Prosper's
/// own type, which the terminal hands to the model for its pane; every other drag pastes as before. Fakes only: a fake
/// NSDraggingInfo on a uniquely named scratch pasteboard (released at the end) handed to the view's own methods; no drag
/// session, no posted event, no window shown.
extension AgentWindowD1Tests {
    /// A drag as AppKit hands it to a destination: its pasteboard and its point in window coordinates (AppKit's y up).
    @MainActor
    final class PaneDropRoutingDrag: NSObject, @preconcurrency NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint
        init(_ pb: NSPasteboard, at p: NSPoint) { draggingPasteboard = pb; draggingLocation = p }

        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// A terminal host view of 1000 x 800 in pane `pane` of `m` (no window, no surface), the drops it handed on to
    /// libghostty's paste counted, and a scratch pasteboard released after `body`.
    @MainActor
    func paneDropRoutingHost(_ m: AgentWindowModel, pane: UUID,
                             _ body: (AgentTerminalHostView, NSPasteboard, () -> Int) throws -> Void) rethrows {
        let host = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        host.dropModel = m
        host.dropPane = pane
        var pasted = 0
        host.pastedDrop = { _ in pasted += 1 }
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.panedrop.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        try body(host, pb, { pasted })
    }

    /// Red at base: the row drag was text (.string), which the terminal pasted; AgentTerminalHostView had no dropModel,
    /// dropPane or pastedDrop and no .agentRow type existed (compile error). Mutant terminal-drop-not-forwarded (super for
    /// the row type) fails every "copy" and indicator line: libghostty finds no payload and refuses.
    @MainActor
    func testPaneDropRoutingRowTypeReachesTheModelForItsPaneAndPastesNothing() throws {
        try paneSwitcherModel(["api", "web", "db"], targets: ["api", "web"]) { m, panes in
            let a = try XCTUnwrap(panes.first), b = try XCTUnwrap(panes.last)
            try paneDropRoutingHost(m, pane: b) { host, pb, pasted in
                XCTAssertTrue(host.registeredDraggedTypes.contains(.agentRow), "the terminal takes a row's type")
                XCTAssertTrue(host.registeredDraggedTypes.contains(.string), "and still libghostty's own")
                XCTAssertTrue(host.registeredDraggedTypes.contains(.fileURL), "files too")
                XCTAssertTrue(pb.setData(Data(try dropToken("db").utf8), forType: .agentRow))
                let top = PaneDropRoutingDrag(pb, at: NSPoint(x: 500, y: 790))   // AppKit's y up: the pane's top band
                XCTAssertEqual(host.draggingEntered(top), .copy, "entered: a copy")
                XCTAssertEqual(m.dropHover?.pane, b, "the indicator on this terminal's pane")
                XCTAssertEqual(m.dropHover?.zone, .edge(.up), "in the pane's top-left space")
                let centre = PaneDropRoutingDrag(pb, at: NSPoint(x: 500, y: 400))
                XCTAssertEqual(host.draggingUpdated(centre), .copy, "updated: a copy")
                XCTAssertEqual(m.dropHover?.zone, .centre, "the indicator follows")
                host.draggingExited(centre)
                XCTAssertTrue(m.dropHover == nil, "cleared on exit")
                XCTAssertEqual(host.draggingEntered(centre), .copy)
                XCTAssertTrue(host.performDragOperation(centre), "the model took it")
                XCTAssertEqual(paneSwitcherName(m, b), "db", "the centre replaces this pane's session")
                XCTAssertEqual(paneSwitcherName(m, a), "api", "the other pane keeps its own")
                XCTAssertEqual(m.layout.order.count, 2, "no split")
                XCTAssertTrue(m.dropHover == nil, "no indicator after the drop")
                XCTAssertEqual(pasted(), 0, "nothing handed on to the terminal's paste")
            }
        }
    }

    /// Red at base: no pastedDrop (compile error). Mutant other-types-forwarded (a .string drag routed to the model) fails
    /// the indicator and pane lines: the very token as text is still only text.
    @MainActor
    func testPaneDropRoutingPlainTextStillPastesAndLeavesTheModel() throws {
        try paneSwitcherModel(["api", "web", "db"], targets: ["api", "web"]) { m, panes in
            let b = try XCTUnwrap(panes.last)
            try paneDropRoutingHost(m, pane: b) { host, pb, pasted in
                XCTAssertTrue(pb.setString(try dropToken("db"), forType: .string))
                let d = PaneDropRoutingDrag(pb, at: NSPoint(x: 500, y: 400))
                XCTAssertEqual(host.draggingEntered(d), .copy, "libghostty takes text, as before")
                XCTAssertEqual(host.draggingUpdated(d), .copy)
                XCTAssertTrue(m.dropHover == nil, "no indicator for text")
                _ = host.performDragOperation(d)   // no surface here: libghostty has nowhere to paste
                XCTAssertEqual(pasted(), 1, "handed on to the terminal's paste")
                XCTAssertEqual(paneSwitcherName(m, b), "web", "the pane keeps its session")
                XCTAssertTrue(m.dropHover == nil)
            }
        }
    }

    /// Red at base: the item was an NSString (plain text) and the proposal a move. Mutants row-drag-plain-text and
    /// proposal-move fail their lines.
    @MainActor
    func testPaneDropRoutingRowItemIsTheRowTypeOnlyAndTheProposalIsACopy() throws {
        let item = AgentRowDrag.item(try dropToken("api"))
        XCTAssertEqual(item.registeredTypeIdentifiers, [UTType.agentRow.identifier], "Prosper's own type only")
        XCTAssertFalse(item.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), "no text: no text field takes it")
        XCTAssertFalse(item.canLoadObject(ofClass: NSString.self), "nothing another app reads as text")
        XCTAssertEqual(AgentPaneDropDelegate.proposal.operation, .copy, "a copy, never a move (QA s1)")
        XCTAssertNotEqual(UTType.agentRow, .plainText)
        XCTAssertFalse(UTType.agentRow.conforms(to: .text), "not a kind of text")
    }

    /// QA's owed check: a plain press on a sidebar row (its button's own action, no event posted) still selects it with
    /// the row's .onDrag attached. Green at base too (the drag never took the click); kept so a drag change cannot.
    @MainActor
    func testPaneDropRoutingAPlainRowClickStillSelects() throws {
        let g = AgentSidebarGroupRowTests()
        try g.withRow {
            let (m, _) = g.model([session("api", .idle), session("web", .idle)])
            defer { m.close() }
            XCTAssertTrue(AgentWindowModel.dragToken(g.key("api")) != nil, "control: a live row carries a drag")
            let restore = AXTreeSupport.axOn()
            defer { restore() }
            let width = AgentWindowModel.fullSidebarWidth
            let (win, host) = AXTreeSupport.hosted(AgentSidebarView(model: m).frame(width: width, height: 900),
                                                   CGSize(width: width, height: 900))
            defer { win.close() }
            let names = ["api", "web"]
            _ = AXTreeSupport.poll(host) { t in names.allSatisfy { n in t.contains { $0.label == g.words(m, n) } } }
            let name = try XCTUnwrap(names.first { g.key($0) != m.selection }, "control: a row not selected yet")
            let line = try XCTUnwrap(paneDropRoutingPressable(host, label: g.words(m, name)), "no button for \(name)")
            if let p = line as? NSAccessibilityProtocol { XCTAssertTrue(p.accessibilityPerformPress(), "pressed") } else {
                _ = line.perform(NSSelectorFromString("accessibilityPerformPress"))
            }
            XCTAssertEqual(m.selection, g.key(name), "the press selects the row")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// The element labelled `label` that takes a press, depth first through the accessibility children.
    @MainActor
    func paneDropRoutingPressable(_ e: Any, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 60, let o = e as? NSObject else { return nil }
        if o.responds(to: Selector(("accessibilityLabel"))), (o.value(forKey: "accessibilityLabel") as? String) == label,
           o.responds(to: NSSelectorFromString("accessibilityPerformPress")) { return o }
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
            if let found = paneDropRoutingPressable(k, label: label, depth: depth + 1) { return found }
        }
        return nil
    }

    /// #1914: the view AppKit hands a mouse-down at `p` (the header's midline at `x`) in `view` hosted offscreen (never
    /// shown) at `size`, once SwiftUI has mounted its AgentWindowDragView.
    @MainActor
    func paneHeaderHit<V: View>(_ view: V, _ size: CGSize, x: CGFloat) -> NSView? {
        let (win, host) = AXTreeSupport.hosted(view, size)
        defer { win.close() }
        func drag(_ v: NSView) -> Bool { v is AgentWindowDragView || v.subviews.contains(where: drag) }
        for _ in 0..<50 where !drag(host) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(drag(host), "control: the drag area is mounted")
        XCTAssertFalse(win.isVisible, "never shown")
        return host.hitTest(CGPoint(x: x, y: size.height / 2))
    }

    /// #1914 (operator: a pane dragged only from its state label): a layout pane's compact header, over a window-move
    /// area as the #1378 one, takes the press in the gap between the title and the "⋯" itself (its .onDrag starts there),
    /// where it fell through to what lay behind. Red at base: AgentCompactHeader had no contentShape, the gap went to the
    /// AgentWindowDragView. Mutant compact-header-no-content-shape.
    @MainActor
    func testPaneDropRoutingHeaderGapIsTheLayoutPanesDragSource() throws {
        let s = session("api", .idle)
        let m = windowModel(store([s]))
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(s.key))
        let row = try XCTUnwrap(m.selectedRow)
        let header = AgentCompactHeader.of(row, s, cwd: nil, ended: false, store: nil, ask: { _ in }, open: {},
                                           xrayPane: m.layout.focused)
            .modifier(AgentRowDrag(token: "api"))
        let hit = paneHeaderHit(ZStack { AgentWindowDragArea(); header }, CGSize(width: 500, height: AgentCompactHeader.height), x: 300)
        XCTAssertTrue(hit != nil, "the gap takes the press")
        XCTAssertFalse(hit is AgentWindowDragView, "the gap is the pane's drag, not the window's move: \(String(describing: hit))")
    }

    /// #1914, the single-pane split: AgentSessionHeader (one pane, no layout) keeps #1378's window move on its empty
    /// parts (a double-click there follows AppleActionOnDoubleClick, AgentWindowDragView.mouseDown). Green at base;
    /// mutant session-header-content-shape turns it red.
    @MainActor
    func testPaneDropRoutingSinglePaneHeaderGapStillMovesTheWindow() throws {
        let s = session("api", .idle)
        let m = windowModel(store([s]))
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(s.key))
        let row = try XCTUnwrap(m.selectedRow)
        let header = AgentSessionHeader(row: row, session: s, cwd: nil, open: {}, xrayPane: m.layout.focused)
            .modifier(AgentRowDrag(token: "api"))
        let hit = paneHeaderHit(header, CGSize(width: 900, height: AgentSessionHeader.height), x: 450)
        XCTAssertTrue(hit is AgentWindowDragView, "the gap moves the window: \(String(describing: hit))")
    }
}
