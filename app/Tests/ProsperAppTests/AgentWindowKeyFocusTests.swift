import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #831 B1 step 5 (spec 7.2, 7.6, 13; 14.2 R6.1, R6.5, R6.13): key focus from the model's geometry, the first click on
/// an unfocused pane only focuses it, the dim, the pane containers. Offscreen only: the click rule and its state machine
/// are called as functions with built values (no event is posted, sendEvent is not driven here); views are hosted in
/// windows never ordered in; the split gate is saved, set and restored by the rows that need two panes (15.0).
extension AgentWindowD1Tests {

    /// R6.1 (7.2): a mouse-down in the sidebar's frame gives it the keys, one in the pane frame gives them to the panes;
    /// the 1 pt line, the title strip above the content and a point that is not finite change nothing; with the island
    /// off no sidebar is drawn, so x < 290·s is not the sidebar. Then the plain-key rule: ↓ reaches the sidebar only with
    /// keyFocus .sidebar and a responder that neither types nor is a terminal.
    @MainActor
    func testAgentWindowKeyFocusComesFromTheModelsFrames() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let size = CGSize(width: 1000, height: 680)
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let m = windowModel(store([session("api", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            XCTAssertEqual(m.keyFocus, .sidebar, "the window starts with the sidebar's keys (\(scale))")
            let line = sz(290) + 0.5, inPane = sz(290) + 1 + 100
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: inPane, y: 300), in: size), "one pane: the click passes (\(scale))")
            XCTAssertEqual(m.keyFocus, .pane, "a pane click (\(scale))")
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: 100, y: -10), in: size))
            XCTAssertEqual(m.keyFocus, .pane, "the title strip above the content is not the sidebar (\(scale))")
            for p in [CGPoint(x: CGFloat.nan, y: 300), CGPoint(x: 100, y: CGFloat.infinity), CGPoint(x: -CGFloat.infinity, y: 0)] {
                XCTAssertFalse(m.mouseDown(at: p, in: size))
            }
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: 100, y: 300), in: CGSize(width: CGFloat.nan, height: 680)))
            XCTAssertEqual(m.keyFocus, .pane, "outside data that is not finite changes nothing (\(scale))")
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: 100, y: 300), in: size))
            XCTAssertEqual(m.keyFocus, .sidebar, "a sidebar click (\(scale))")
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: line, y: 300), in: size))
            XCTAssertEqual(m.keyFocus, .sidebar, "the line between the sidebar and the panes changes nothing (\(scale))")
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: size.width - 1, y: size.height - 1), in: size))
            XCTAssertEqual(m.keyFocus, .pane, "the pane area's far corner (\(scale))")
        }
        ThemeRuntime.scale = 1.0
        // The island off: one message, no sidebar frame, so a click at x = 100 leaves the keys where they were.
        let off = AgentWindowModel()
        XCTAssertFalse(off.hasStore)
        XCTAssertTrue(off.sidebarFrame(in: size) == nil)
        off.keyFocus = .pane
        XCTAssertFalse(off.mouseDown(at: CGPoint(x: 100, y: 300), in: size))
        XCTAssertEqual(off.keyFocus, .pane, "no sidebar drawn: x < 290·s is not the sidebar")
        // The window's Bool is the model's keyFocus.
        let m = windowModel(store([session("api", .idle)]))
        defer { m.close() }
        let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        m.keyFocus = .pane
        XCTAssertFalse(win.sidebarFocused)
        win.sidebarFocused = true
        XCTAssertEqual(m.keyFocus, .sidebar)
        // The plain-key rule (7.2) with the Bool the window passes.
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
        func route(_ f: PaneKeys.KeyFocus, _ r: AgentsNSWindow.ResponderKind) -> AgentsNSWindow.KeyRoute {
            AgentsNSWindow.route(down, responder: r, sidebarFocused: f == .sidebar, terminalMode: r == .terminal)
        }
        XCTAssertEqual(route(.sidebar, .other), .sidebar)
        XCTAssertEqual(route(.pane, .other), .pass, "a click in a pane: ↓ is not the sidebar's")
        XCTAssertEqual(route(.pane, .terminal), .pass, "R6.1: a click in a pane with a terminal: ↓ reaches the terminal")
        XCTAssertEqual(route(.sidebar, .terminal), .pass)
        XCTAssertEqual(route(.sidebar, .text), .pass)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// R6.5 (7.6) as functions: a mouse-down on an unfocused pane focuses it and is swallowed with its drags and its up;
    /// on the focused pane, outside every frame or at a point that is not finite it passes. One pane: every click passes.
    @MainActor
    func testAgentWindowFirstClickOnAnUnfocusedPaneOnlyFocusesIt() {
        let a = UUID(), b = UUID()
        let two = [a: CGRect(x: 0, y: 0, width: 500, height: 600), b: CGRect(x: 500, y: 0, width: 500, height: 600)]
        XCTAssertTrue(AgentsNSWindow.firstClick(at: CGPoint(x: 100, y: 100), frames: two, focused: a) == nil, "the focused pane")
        XCTAssertEqual(AgentsNSWindow.firstClick(at: CGPoint(x: 600, y: 100), frames: two, focused: a), b)
        XCTAssertEqual(AgentsNSWindow.firstClick(at: CGPoint(x: 500, y: 0), frames: two, focused: a), b, "a shared edge: b's")
        XCTAssertEqual(AgentsNSWindow.firstClick(at: CGPoint(x: 100, y: 599), frames: two, focused: b), a)
        for p in [CGPoint(x: 1000, y: 10), CGPoint(x: -1, y: 10), CGPoint(x: 600, y: 600), CGPoint(x: CGFloat.nan, y: 10),
                  CGPoint(x: 600, y: CGFloat.infinity)] {
            XCTAssertTrue(AgentsNSWindow.firstClick(at: p, frames: two, focused: a) == nil, "\(p) passes")
        }
        let one = [a: CGRect(x: 0, y: 0, width: 1000, height: 600)]
        for x in stride(from: CGFloat(0), through: 1000, by: 125) {
            for y in stride(from: CGFloat(0), through: 600, by: 150) {
                XCTAssertTrue(AgentsNSWindow.firstClick(at: CGPoint(x: x, y: y), frames: one, focused: a) == nil, "one pane: passes")
            }
        }
        XCTAssertTrue(AgentsNSWindow.firstClick(at: CGPoint(x: 10, y: 10), frames: [:], focused: a) == nil, "no frame: passes")

        // The state machine: a focusing down swallows its drags and its up; the next click passes whole.
        var c = AgentsNSWindow.FocusClick()
        XCTAssertTrue(c.take(.leftMouseDown, focusing: true))
        XCTAssertFalse(c.take(.keyDown, focusing: false), "a key between passes")
        XCTAssertFalse(c.take(.rightMouseDown, focusing: false))
        for _ in 0..<3 { XCTAssertTrue(c.take(.leftMouseDragged, focusing: false), "its drag") }
        XCTAssertTrue(c.take(.leftMouseUp, focusing: false), "its up")
        XCTAssertFalse(c.swallowing)
        XCTAssertFalse(c.take(.leftMouseDragged, focusing: false), "a stray drag after the up passes")
        XCTAssertFalse(c.take(.leftMouseDown, focusing: false), "the second click reaches the pane")
        XCTAssertFalse(c.take(.leftMouseDragged, focusing: false))
        XCTAssertFalse(c.take(.leftMouseUp, focusing: false))
        XCTAssertTrue(c.take(.leftMouseDown, focusing: true))
        XCTAssertFalse(c.take(.leftMouseDown, focusing: false), "a new down ends the swallow")
        XCTAssertFalse(c.take(.leftMouseUp, focusing: false))
    }

    /// R6.5 / R6.13 on the model: with the gate set and two panes, a click in the unfocused pane focuses it (the panes
    /// take the keys) and says "swallow"; the second click passes. With the gate off the same decoded two-pane layout
    /// shows its focused pane alone: every click passes and nothing is refocused.
    @MainActor
    func testAgentWindowFirstClickFocusesThePaneOnlyWithTwoPanesShown() throws {
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            AgentPaneLayout.splitsEnabled = true
            let m = windowModel(store([session("api", .idle), session("web", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
            let first = try XCTUnwrap(m.layout.order.first), second = try XCTUnwrap(m.layout.order.last)
            XCTAssertEqual(m.layout.focused, first)
            let size = CGSize(width: 1600, height: 900)
            let area = try XCTUnwrap(m.paneAreaFrame(in: size))
            let f = try XCTUnwrap(m.paneFrames(in: CGRect(origin: .zero, size: area.size))[second])
            let inSecond = CGPoint(x: area.minX + f.midX, y: area.minY + f.midY)
            m.keyFocus = .sidebar
            XCTAssertTrue(m.mouseDown(at: inSecond, in: size), "the first click only focuses (\(scale))")
            XCTAssertEqual(m.layout.focused, second)
            XCTAssertEqual(m.keyFocus, .pane)
            XCTAssertFalse(m.mouseDown(at: inSecond, in: size), "the second click reaches the pane (\(scale))")
            XCTAssertEqual(m.layout.focused, second)

            AgentPaneLayout.splitsEnabled = false
            m.adopt(try m.layout.focus(first).get())
            for x in stride(from: area.minX, to: area.maxX, by: 97) {
                XCTAssertFalse(m.mouseDown(at: CGPoint(x: x, y: area.midY), in: size), "gate off: one pane shown, passes")
            }
            XCTAssertEqual(m.layout.focused, first, "gate off: nothing refocused (\(scale))")
            XCTAssertEqual(m.layout.panes.count, 2, "the decoded layout keeps its tree (15.0)")
        }
    }

    /// 7.6 through the window's sendEvent, with built events handed to it (never posted; the window is never shown): a
    /// down on the unfocused pane focuses it and starts the swallow, its up ends it; a sidebar down gives the sidebar
    /// the keys. Window coordinates (bottom-left origin) reach the model's top-left frames.
    @MainActor
    func testAgentWindowSendEventSwallowsTheFocusingClick() throws {
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let m = windowModel(store([session("api", .idle), session("web", .idle)]))
        m.setVisible(true)
        defer { m.close() }
        m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
        let second = try XCTUnwrap(m.layout.order.last)
        let size = CGSize(width: 1600, height: 900)
        let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        var raised = 0
        win.raise = { _ in raised += 1 }   // #900 B2 step 6b2b (R1196-1): a recorder first, never the real key and front
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ yFromTop: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: size.height - yFromTop), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let area = try XCTUnwrap(m.paneAreaFrame(in: size))
        let f = try XCTUnwrap(m.paneFrames(in: CGRect(origin: .zero, size: area.size))[second])
        m.keyFocus = .sidebar
        win.sendEvent(mouse(.leftMouseDown, area.minX + f.midX, 40))
        XCTAssertEqual(m.layout.focused, second, "the first click focused the pane")
        XCTAssertTrue(win.focusClick.swallowing, "its down was swallowed")
        XCTAssertEqual(raised, 1, "R1196-1: the swallowed down asked for key and front once (the window is not key)")
        XCTAssertFalse(win.sidebarFocused)
        win.sendEvent(mouse(.leftMouseUp, area.minX + f.midX, 40))
        XCTAssertFalse(win.focusClick.swallowing, "its up ended the swallow")
        win.sendEvent(mouse(.leftMouseDown, sz(100), 40))
        XCTAssertTrue(win.sidebarFocused, "a sidebar down")
        XCTAssertFalse(win.focusClick.swallowing)
        XCTAssertEqual(m.layout.focused, second)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// 7.6: the dim takes no hits: a hit test over it finds the AppKit view under it (a recorder), in a never-shown window.
    @MainActor
    func testAgentWindowPaneDimTakesNoHits() throws {
        final class Under: NSView {}
        struct UnderView: NSViewRepresentable {
            func makeNSView(context: Context) -> Under { Under() }
            func updateNSView(_ v: Under, context: Context) {}
        }
        let size = CGSize(width: 200, height: 200)
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: ZStack { UnderView(); AgentPaneDim() }.frame(width: 200, height: 200))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        settle(host)
        let hit = host.hitTest(NSPoint(x: 100, y: 100))
        var v: NSView? = hit
        while let x = v, !(x is Under) { v = x.superview }
        XCTAssertTrue(v is Under, "the click goes through the dim, got \(String(describing: hit))")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// 13: with two panes shown each pane is a container "<title>, pane i of n" in tree order, read from the real
    /// accessibility tree of the root view in a never-shown window (the tree is built once this process asks, as an AX
    /// client's attribute write would; both attributes are put back as read, the R1137-1 rule). One pane: no such name.
    @MainActor
    func testAgentWindowPanesAreNamedContainersOnlyWithMoreThanOnePane() throws {
        let gate = AgentPaneLayout.splitsEnabled
        let restoreModes = transcriptMode(["api", "web"])
        defer { AgentPaneLayout.splitsEnabled = gate; restoreModes() }
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }

        let st = store([session("api", .idle), session("web", .idle)])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        let size = CGSize(width: 1600, height: 900)
        func labels(until done: ([String]) -> Bool) -> [String] {
            let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            defer { win.contentView = nil; win.close() }
            let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
            host.frame = CGRect(origin: .zero, size: size)
            win.contentView = host
            var out: [String] = []
            let ceiling = Date().addingTimeInterval(5)
            repeat {
                settle(host)
                out = []
                var nodes: [AXTreeNode] = []
                AXTreeSupport.walk(host, &nodes)   // every node's label, depth first, as before (main actor)
                out = nodes.map(\.label).filter { !$0.isEmpty }
            } while !done(out) && Date() < ceiling
            XCTAssertFalse(win.isVisible, "never shown")
            return out
        }
        let apiTitle = try XCTUnwrap(m.row(.live(paneKey("api")))?.title)
        let webTitle = try XCTUnwrap(m.row(.live(paneKey("web")))?.title)
        AgentPaneLayout.splitsEnabled = false
        m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))
        // Read until the sidebar's rows are in the tree, so "no pane name" is not an empty read.
        let one = labels { $0.contains { $0.contains(webTitle) } }
        XCTAssertTrue(one.contains { $0.contains(webTitle) }, "the tree was read: \(one.prefix(20))")
        XCTAssertFalse(one.contains { $0.contains(", pane ") }, "gate off, one pane shown: no pane container")

        AgentPaneLayout.splitsEnabled = true
        let two = labels { $0.contains("\(webTitle), pane 2 of 2") }
        let i1 = two.firstIndex(of: "\(apiTitle), pane 1 of 2"), i2 = two.firstIndex(of: "\(webTitle), pane 2 of 2")
        XCTAssertTrue(i1 != nil && i2 != nil, "both panes are named containers: \(two.filter { $0.contains(", pane ") })")
        if let i1, let i2 { XCTAssertLessThan(i1, i2, "tree order is the layout's order") }
    }
}
