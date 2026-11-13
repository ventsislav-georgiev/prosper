import AppKit
import XCTest
@testable import ProsperApp

/// #1102: every global shortcut that opens a Prosper window or panel follows one rule. Closed:
/// open and focus. Open but not focused: focus, never close. Focused: close, through the close
/// path. Offscreen only: windows are built and never shown, the shown/focused read is the
/// WindowToggle.state seam, and every on-screen effect (activate, order front, make key) and the
/// Dock policy sit behind each surface's seams, swapped here for recorders.
@MainActor
final class WindowShortcutToggleTests: XCTestCase {

    /// Windows the stubbed state read calls shown / focused.
    private var shown = Set<ObjectIdentifier>()
    private var focused = Set<ObjectIdentifier>()

    /// Swaps the state read for the sets above; returns the live one for the caller's defer.
    private func stubState() -> (NSWindow) -> (shown: Bool, focused: Bool) {
        let saved = WindowToggle.state
        WindowToggle.state = { [unowned self] w in
            (shown: self.shown.contains(ObjectIdentifier(w)), focused: self.focused.contains(ObjectIdentifier(w)))
        }
        return saved
    }

    private func set(_ w: NSWindow, shown s: Bool, focused f: Bool) {
        if s { shown.insert(ObjectIdentifier(w)) } else { shown.remove(ObjectIdentifier(w)) }
        if f { focused.insert(ObjectIdentifier(w)) } else { focused.remove(ObjectIdentifier(w)) }
    }

    // MARK: - The rule

    func testDecisionTable() {
        let rows: [(shown: Bool, focused: Bool, effect: WindowToggle.Effect)] = [
            (false, false, .open),
            (false, true, .open),
            (true, false, .focus),
            (true, true, .close),
        ]
        XCTAssertEqual(rows.count, 4)
        for r in rows {
            XCTAssertEqual(WindowToggle.effect(shown: r.shown, focused: r.focused), r.effect, "\(r)")
        }
    }

    /// The live read: a window never put on screen is neither shown nor focused (it opens).
    func testLiveStateReadsAWindowNeverShownAsClosed() {
        let w = ToggleWindowFake.window()
        let s = WindowToggle.state(w)
        XCTAssertTrue(s.shown == false && s.focused == false)
        var ran: [String] = []
        WindowToggle.apply(w, open: { ran.append("open") }, focus: { ran.append("focus") }, close: { ran.append("close") })
        WindowToggle.apply(nil, open: { ran.append("open") }, focus: { ran.append("focus") }, close: { ran.append("close") })
        XCTAssertEqual(ran, ["open", "open"])
    }

    // MARK: - Settings (⌥\)

    func testSettingsShortcutToggles() throws {
        let saved = stubState()
        defer { WindowToggle.state = saved }
        let s = SettingsWindow()
        var built: [NSWindow] = []
        var presented = 0, dismissed = 0
        s.build = { let w = ToggleWindowFake.window(); built.append(w); return w }
        s.present = { _ in presented += 1 }
        s.dismissed = { _ in dismissed += 1 }

        s.toggleFromShortcut()
        XCTAssertEqual(built.count, 1, "closed: the press opens")
        XCTAssertEqual(presented, 1)
        let win = try XCTUnwrap(built.last)

        set(win, shown: true, focused: false)
        s.toggleFromShortcut()
        XCTAssertEqual(presented, 2, "open, not focused: the press focuses")
        XCTAssertEqual(dismissed, 0, "and does not close")
        XCTAssertEqual(built.count, 1)

        set(win, shown: true, focused: true)
        s.show()
        XCTAssertEqual(presented, 3, "the menu's show never closes, focused or not")
        XCTAssertEqual(dismissed, 0)

        s.toggleFromShortcut()
        XCTAssertEqual(presented, 3, "focused: the press closes")
        XCTAssertEqual(dismissed, 1, "through the willClose teardown")
        s.toggleFromShortcut()
        XCTAssertEqual(built.count, 2, "the teardown let go of the window: the next press builds a new one")
        XCTAssertEqual(presented, 4)
        built.last?.close()
        XCTAssertEqual(dismissed, 2)
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    // MARK: - Coding Agent

    func testCodingAgentShortcutToggles() throws {
        let saved = stubState()
        defer { WindowToggle.state = saved }
        let c = ChatWindow.shared
        XCTAssertFalse(c.isOpen)
        let f = fakeChatForToggle()

        c.toggleFromShortcut()
        XCTAssertTrue(c.isOpen, "closed: the press opens")
        XCTAssertEqual(f.presents, 1)
        let win = try XCTUnwrap(f.built.last)

        set(win, shown: true, focused: false)
        c.toggleFromShortcut()
        XCTAssertEqual(f.presents, 2, "open, not focused: the press focuses")
        XCTAssertTrue(c.isOpen, "and does not close")

        set(win, shown: true, focused: true)
        c.show()
        XCTAssertEqual(f.presents, 3, "the menu's show never closes")
        c.toggleFromShortcut()
        XCTAssertFalse(c.isOpen, "focused: the press closes")
        XCTAssertEqual(f.closes, 1, "through the willClose teardown (Dock, model release)")
        XCTAssertEqual(f.presents, 3)
        XCTAssertEqual(f.built.count, 1)
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    // MARK: - Agent Sessions

    func testAgentSessionsShortcutToggles() throws {
        let saved = stubState()
        defer { WindowToggle.state = saved }
        let w = AgentsWindow.shared
        XCTAssertFalse(w.isOpen)
        let (f, c) = fakeAgentsForToggle()

        AgentsWindow.toggleFromShortcut()
        XCTAssertEqual(f.presents, 1, "closed: the press opens")
        let win = try XCTUnwrap(w.window)

        set(win, shown: true, focused: false)
        AgentsWindow.toggleFromShortcut()
        XCTAssertEqual(f.presents, 2, "open, not focused: the press focuses")
        XCTAssertTrue(w.window === win, "and does not close")

        set(win, shown: true, focused: true)
        AgentsWindow.toggleFromShortcut()
        XCTAssertFalse(w.isOpen, "focused: the press closes")
        XCTAssertEqual(f.closes, 1, "through the teardown")
        XCTAssertNil(c.onStoreChanged, "the teardown let go of the island")
        XCTAssertEqual(f.presents, 2)

        // The island's store gone: closed, the press does nothing (#858); an open window still
        // follows the rule, so a focused one closes and an unfocused one comes forward.
        let store = c.store
        c.store = nil
        AgentsWindow.toggleFromShortcut()
        XCTAssertEqual(f.built.count, 1, "no store, closed: a no-op")
        XCTAssertFalse(w.isOpen)
        c.store = store
        AgentsWindow.toggleFromShortcut()
        let win2 = try XCTUnwrap(w.window)
        XCTAssertEqual(f.built.count, 2)
        c.store = nil
        set(win2, shown: true, focused: false)
        AgentsWindow.toggleFromShortcut()
        XCTAssertEqual(f.presents, 4, "no store, open and not focused: it comes forward")
        set(win2, shown: true, focused: true)
        AgentsWindow.toggleFromShortcut()
        XCTAssertFalse(w.isOpen, "no store, focused: it closes")
        XCTAssertEqual(f.closes, 2)
        XCTAssertFalse(win.isVisible || win2.isVisible, "never on screen")
    }

    // MARK: - Clipboard History (⇧⌥A)

    func testClipboardShortcutToggles() throws {
        let saved = stubState()
        defer { WindowToggle.state = saved }
        let cp = ClipboardPanel(store: ClipboardStore(dir: tempDir()))
        let p = cp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        var on = 0, off = 0
        cp.onScreen = { _ in on += 1 }
        cp.offScreen = { _ in off += 1 }

        cp.model.query = "stale"
        cp.toggle()
        XCTAssertEqual(on, 1, "closed: the press opens")
        XCTAssertEqual(cp.model.query, "", "through present (a fresh search)")

        // The operator's report: open but not focused, the press closed it. It focuses now.
        cp.model.query = "kept"
        set(p, shown: true, focused: false)
        cp.toggle()
        XCTAssertEqual(on, 2, "open, not focused: the press focuses")
        XCTAssertEqual(off, 0, "and does not close")
        XCTAssertEqual(cp.model.query, "kept", "the search survives a refocus")

        set(p, shown: true, focused: true)
        cp.toggle(closing: false)
        XCTAssertEqual(on, 3, "the status menu never closes")
        XCTAssertEqual(off, 0)
        cp.toggle()
        XCTAssertEqual(off, 1, "focused: the press closes through dismiss")
        XCTAssertEqual(on, 3)
        XCTAssertFalse(p.isVisible, "never on screen")
    }

    // MARK: - Runner and Translate

    func testRunnerShortcutToggles() throws {
        let saved = stubState()
        defer { WindowToggle.state = saved }
        let rp = RunnerPanel()
        let p = rp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        var on = 0, off = 0
        rp.onScreen = { _ in on += 1 }
        rp.offScreen = { _ in off += 1 }

        rp.model.input = "stale"
        rp.toggle()
        XCTAssertEqual(on, 1, "closed: the press opens")
        XCTAssertEqual(rp.model.input, "", "through present (a fresh query)")

        // A Translate press on the plain runner left open with a query: it comes back as it was.
        rp.model.input = "typed"
        set(p, shown: true, focused: false)
        rp.toggle(prefill: "l ")
        XCTAssertEqual(on, 2, "open, not focused: the press focuses")
        XCTAssertEqual(off, 0, "and does not close")
        XCTAssertEqual(rp.model.input, "typed", "the query survives a refocus")
        XCTAssertEqual(rp.model.mode, .universal)

        set(p, shown: true, focused: true)
        rp.toggle(closing: false)
        XCTAssertEqual(on, 3, "the status menu never closes")
        XCTAssertEqual(off, 0)
        rp.toggle(prefill: "l ")
        XCTAssertEqual(off, 1, "focused: a press closes, Translate's too, through dismiss")
        XCTAssertEqual(on, 3)
        XCTAssertFalse(p.isVisible, "never on screen")
    }

    // MARK: - Teardown (#1113, QA 839)

    /// A row that stops part-way (here on purpose, as a red row would) leaves both shared windows
    /// open; the fakes' teardown closes them. Registered first, this check runs after that teardown.
    func testSharedWindowsCloseAtTeardownWhenARowStopsPartWay() {
        addTeardownBlock { @MainActor in
            XCTAssertFalse(ChatWindow.shared.isOpen, "the teardown closed the Coding Agent window")
            XCTAssertFalse(AgentsWindow.shared.isOpen, "the teardown closed the Agent Sessions window")
        }
        let chat = fakeChatForToggle()
        let (agents, _) = fakeAgentsForToggle()
        ChatWindow.shared.toggleFromShortcut()
        AgentsWindow.toggleFromShortcut()
        XCTAssertTrue(ChatWindow.shared.isOpen && AgentsWindow.shared.isOpen, "both open, and the row ends here")
        XCTAssertEqual(chat.presents + agents.presents, 2)
    }
}

/// Recorders behind a shared window's seams (#1113).
@MainActor
final class ToggleWindowFake {
    var built: [NSWindow] = []
    var presents = 0, closes = 0

    static func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }
}

/// #1113 (QA 839): ChatWindow.shared and AgentsWindow.shared outlive a row. These fakes close a window
/// the row left open and then restore the live seams in a teardown block, not as the row's last step,
/// so a row that fails part-way leaves nothing open for the rows after it. The close runs while the
/// fake `dismissed` is still in place (no Dock policy, no model release).
@MainActor
extension XCTestCase {
    func fakeChatForToggle() -> ToggleWindowFake {
        let c = ChatWindow.shared
        let f = ToggleWindowFake()
        nonisolated(unsafe) let live = (c.build, c.present, c.dismissed)
        c.build = { let w = ToggleWindowFake.window(); f.built.append(w); return w }
        c.present = { _ in f.presents += 1 }
        c.dismissed = { _ in f.closes += 1 }
        addTeardownBlock { @MainActor in
            if c.isOpen { f.built.last?.close() }
            (c.build, c.present, c.dismissed) = live
        }
        return f
    }

    func fakeAgentsForToggle() -> (ToggleWindowFake, AgentIslandController) {
        let w = AgentsWindow.shared
        let f = ToggleWindowFake()
        nonisolated(unsafe) let live = (w.island, w.build, w.present, w.dismissed)
        let c = AgentIslandController()
        c.io = AgentWindowInteractionTests.FormSim(.plain("")).io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        c.autoAllowOn = { false }
        c.after = { _, _ in }
        c.onSessions = { _ in }
        w.island = { c }
        w.present = { _ in f.presents += 1 }
        w.dismissed = { _ in f.closes += 1 }
        w.build = { m in
            let win = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.model = m
            f.built.append(win)
            return win
        }
        addTeardownBlock { @MainActor in
            w.window?.close()
            (w.island, w.build, w.present, w.dismissed) = live
        }
        return (f, c)
    }
}
