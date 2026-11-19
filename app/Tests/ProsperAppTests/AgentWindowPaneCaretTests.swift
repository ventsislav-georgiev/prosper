import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1656 (operator 2026-11-19): in a split only the focused pane's surface has libghostty focus (the solid, blinking
/// cursor); every other pane's draws Ghostty's hollow, steady box. The rule: the window is key, the pane is the focused
/// one and its terminal view is the first responder. Every focus the wrapper hands libghostty is recorded through the
/// terminal's `focusSent` (core.setFocus tells the view, its delegate), installed when the model makes the terminal, so
/// a surface's first focus is in the log too. The window is never shown, ordered in or made key: its key state is a
/// stored flag (`CaretWindow.key`), and a key change is the window's own notification posted for that offscreen window
/// object only. Sessions are fakes (splitTerminals); layouts save to a private suite; the split gate is restored
/// (withPaneMenu). Every row runs on the main actor.
extension AgentWindowD1Tests {
    /// A window whose key state a row sets (AppKit never makes it key).
    final class CaretWindow: NSWindow {
        var key = false
        override var isKeyWindow: Bool { key }
    }

    /// Every focus each terminal's surface was handed, in order.
    final class CaretLog {
        var sent: [ObjectIdentifier: [Bool]] = [:]
        func clear() { sent = [:] }
    }

    struct CaretRig {
        let m: AgentWindowModel
        let win: CaretWindow
        let host: NSHostingView<AgentWindowRootView>
        let log: CaretLog
        let panes: [UUID]

        @MainActor func view(_ p: UUID) -> AgentTerminalHostView? { m.runtimes[p]?.terminal?.view }
        @MainActor func sent(_ p: UUID) -> [Bool] {
            m.runtimes[p]?.terminal.map { log.sent[ObjectIdentifier($0)] ?? [] } ?? []
        }
        /// How many panes' surfaces hold libghostty focus now (their last focus true).
        @MainActor var focusedCount: Int { panes.filter { sent($0).last == true }.count }
    }

    /// `targets` (nil: an empty pane) in a never-shown CaretWindow with key state `key`, every pane terminal on a fake
    /// client and recorded from its making; the first pane focused, the keys in its terminal once it is live.
    @MainActor
    func caretSplit(_ targets: [String?], key: Bool) throws -> CaretRig {
        let m = windowModel(store(targets.compactMap { $0 }.map { session($0, .idle) }), layouts: layoutSuite())
        let rests = splitTerminals(m)
        let log = CaretLog()
        let make = m.makeTerminal
        m.makeTerminal = {
            let t = make()
            let id = ObjectIdentifier(t)
            t.focusSent = { log.sent[id, default: []].append($0) }
            return t
        }
        m.setVisible(true)
        m.adopt(paneLayout(targets.map { $0.map(paneTarget) }))
        let size = CGSize(width: 1000, height: 680)
        let win = CaretWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.key = key
        let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        let rig = CaretRig(m: m, win: win, host: host, log: log, panes: m.layout.order)
        let live = rig.panes.filter { m.runtimes[$0]?.terminal != nil }
        paneFocusSettle(host) { live.allSatisfy { rig.view($0)?.window === win } }
        endRests(rests)
        paneFocusSettle(host) { live.allSatisfy { m.runtimes[$0]?.terminal?.phase == .live } }
        XCTAssertTrue(m.focusSelection())
        paneFocusSettle(host) { paneFocusBox(m).map { win.firstResponder === $0 } ?? false }
        XCTAssertTrue(win.firstResponder === rig.view(m.layout.focused), "the keys in the focused pane's terminal")
        return rig
    }

    /// A key window, two live panes: only the focused pane's surface holds libghostty focus; the other's new surface was
    /// handed false (libghostty starts a surface focused). A focus switch, there and back: the old pane gets false once,
    /// the new one true once, nothing else, and both views are kept (no new surface).
    /// Red at base: terminalDidAttachSurface only stored the surface, so web's log was empty (its surface kept
    /// libghostty's initial focus: the solid cursor in both panes).
    @MainActor
    func testPaneCaretOnlyTheFocusedPaneHasLibghosttyFocus() throws {
        try withPaneMenu(true) {
            let r = try caretSplit(["api", "web"], key: true)
            defer { r.m.close(); r.win.close() }
            let api = try XCTUnwrap(r.panes.first), web = try XCTUnwrap(r.panes.last)
            XCTAssertEqual(r.sent(api).last, true, "api: key window, focused pane, first responder")
            XCTAssertEqual(r.sent(web).last, false, "web's surface told it is unfocused (the hollow box)")
            XCTAssertEqual(r.focusedCount, 1)
            let views = [r.view(api), r.view(web)]
            for (to, from, why) in [(web, api, "focus to web"), (api, web, "focus back to api")] {
                r.log.clear()
                r.m.focusPane(to)
                paneFocusSettle(r.host) { r.win.firstResponder === r.view(to) }
                XCTAssertTrue(r.win.firstResponder === r.view(to), why)
                XCTAssertEqual(r.sent(from), [false], "\(why): the old pane's surface loses focus once")
                XCTAssertEqual(r.sent(to), [true], "\(why): the new pane's surface takes it once")
                XCTAssertTrue(r.view(api) === views.first ?? nil, "\(why): api's view kept")
                XCTAssertTrue(r.view(web) === views.last ?? nil, "\(why): web's view kept")
            }
            XCTAssertFalse(r.win.isVisible, "never shown")
        }
    }

    /// A window that is not key: the first responder's surface is handed false too (the wrapper's own first-responder
    /// hook sent true), so no pane draws the focused cursor. Red at base: becomeFirstResponder left the wrapper's true.
    @MainActor
    func testPaneCaretWindowNotKeyLeavesEveryPaneUnfocused() throws {
        try withPaneMenu(true) {
            let r = try caretSplit(["api", "web"], key: false)
            defer { r.m.close(); r.win.close() }
            let api = try XCTUnwrap(r.panes.first), web = try XCTUnwrap(r.panes.last)
            XCTAssertEqual(r.sent(api).last, false, "api holds the keys in a window that is not key")
            XCTAssertEqual(r.sent(web).last, false)
            XCTAssertEqual(r.focusedCount, 0)
        }
    }

    /// The window resigns key: every pane false; it becomes key again: only the focused pane true. The window's own
    /// notifications, posted for this offscreen window object only (the wrapper observes them per window).
    @MainActor
    func testPaneCaretWindowKeyChangeFollowsTheRule() throws {
        try withPaneMenu(true) {
            let r = try caretSplit(["api", "web"], key: true)
            defer { r.m.close(); r.win.close() }
            let api = try XCTUnwrap(r.panes.first), web = try XCTUnwrap(r.panes.last)
            r.log.clear()
            r.win.key = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: r.win)
            XCTAssertEqual(r.sent(api), [false], "resign key: api's surface loses focus once")
            XCTAssertFalse(r.sent(web).contains(true), "web never takes focus")
            XCTAssertEqual(r.focusedCount, 0)
            r.log.clear()
            r.win.key = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: r.win)
            XCTAssertEqual(r.sent(api), [true], "become key: the focused pane's surface takes focus once")
            XCTAssertFalse(r.sent(web).contains(true), "web stays unfocused")
            XCTAssertEqual(r.focusedCount, 1)
        }
    }

    /// The focused pane closed: the next one takes focus once; the closed one's last focus is false.
    @MainActor
    func testPaneCaretClosedPaneHandsFocusToTheNextOnce() throws {
        try withPaneMenu(true) {
            let r = try caretSplit(["api", "web"], key: true)
            defer { r.m.close(); r.win.close() }
            let api = try XCTUnwrap(r.panes.first), web = try XCTUnwrap(r.panes.last)
            let apiTerminal = try XCTUnwrap(r.m.runtimes[api]?.terminal)
            r.log.clear()
            r.m.closePane(api)
            XCTAssertEqual(r.m.layout.focused, web)
            paneFocusSettle(r.host) { r.win.firstResponder === r.view(web) }
            XCTAssertEqual(r.sent(web), [true], "web takes focus once")
            XCTAssertEqual(r.log.sent[ObjectIdentifier(apiTerminal)]?.last, false, "the closed pane's surface lost it")
            XCTAssertEqual(r.log.sent[ObjectIdentifier(apiTerminal)]?.contains(true), false)
        }
    }

    /// Focus to a pane that takes no keys (empty): the old pane's kept view gives up libghostty focus at once (#1645's
    /// first-responder hand-off in the layout's didSet), and nothing holds it.
    @MainActor
    func testPaneCaretFocusToAnEmptyPaneTakesFocusFromTheOld() throws {
        try withPaneMenu(true) {
            let r = try caretSplit(["api", nil], key: true)
            defer { r.m.close(); r.win.close() }
            let api = try XCTUnwrap(r.panes.first), empty = try XCTUnwrap(r.panes.last)
            XCTAssertEqual(r.sent(api).last, true)
            r.log.clear()
            r.m.focusPane(empty)
            XCTAssertEqual(r.sent(api), [false], "api's surface loses focus once, at the switch")
            paneFocusSettle(r.host) { false }
            XCTAssertEqual(r.sent(api), [false], "and never takes it back")
            XCTAssertEqual(r.focusedCount, 0)
        }
    }
}
