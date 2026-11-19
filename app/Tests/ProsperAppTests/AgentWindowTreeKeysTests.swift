import AppKit
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 1, spec 7.3, 7.4, 12.1, 15.0; R900-1): the tree keys routed through PaneKeys in the window's own
/// performKeyEquivalent. Offscreen only: every event is built with NSEvent.keyEvent and handed to the pure function or
/// to a never-shown window's performKeyEquivalent (nothing is posted, no window is ordered in or made key, the input
/// source is never read); a close is recorded by the window's delegate, which refuses it. Sessions are fakes; the split
/// gate is saved, set and restored in a defer by every row.
extension AgentWindowD1Tests {
    /// Counts the window's close asks (performClose asks its delegate) and refuses them, so nothing really closes.
    @MainActor
    final class TreeKeysCloseRecorder: NSObject, NSWindowDelegate {
        var asks = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            asks += 1
            return false
        }
    }

    @MainActor
    func treeKey(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String, _ ign: String? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: ign ?? chars, isARepeat: false, keyCode: code)!
    }

    @MainActor
    func withTreeGate(_ on: Bool, _ body: () throws -> Void) rethrows {
        let saved = AgentPaneLayout.splitsEnabled
        AgentPaneLayout.splitsEnabled = on
        defer { AgentPaneLayout.splitsEnabled = saved }
        try body()
    }

    /// A never-shown window on a fresh model with one idle fake session; the pane area `area` (the view's job).
    @MainActor
    func treeWindow(area: CGSize = CGSize(width: 1000, height: 600)) -> (AgentsNSWindow, AgentWindowModel, TreeKeysCloseRecorder) {
        let m = windowModel(store([session("api", .idle)]))
        m.paneArea = CGRect(origin: .zero, size: area)
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        let rec = TreeKeysCloseRecorder()
        win.delegate = rec
        win.model = m
        return (win, m, rec)
    }

    /// The chords this step routes, with the key code, modifiers, characters and characters ignoring modifiers.
    static var treeChords: [(name: String, code: UInt16, mods: NSEvent.ModifierFlags, chars: String, ign: String)] { [
        ("⌘D", 2, [.command], "d", "d"),
        ("⇧⌘D", 2, [.command, .shift], "D", "d"),
        ("⌘W", 13, [.command], "w", "w"),
        ("⌘]", 30, [.command], "]", "]"),
        ("⌘[", 33, [.command], "[", "["),
        ("⌥⌘←", 123, [.command, .option], "\u{F702}", "\u{F702}"),
        ("⌥⌘→", 124, [.command, .option], "\u{F703}", "\u{F703}"),
        ("⌥⌘↓", 125, [.command, .option], "\u{F701}", "\u{F701}"),
        ("⌥⌘↑", 126, [.command, .option], "\u{F700}", "\u{F700}"),
        ("⇧⌘Return", 36, [.command, .shift], "\r", "\r"),
        ("⇧⌘Enter", 76, [.command, .shift], "\u{3}", "\u{3}"),
        ("⌃⌘S", 1, [.control, .command], "\u{13}", "s"),
    ] }

    // MARK: The pure routing function

    /// 15.0: with the gate off the routing function is nil for every chord, every responder, focus and pane count.
    @MainActor
    func testTreeKeysPureRouteIsNilWithTheGateOff() {
        for c in Self.treeChords {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                for f: PaneKeys.KeyFocus in [.sidebar, .pane] {
                    for n in [1, 2, 6] {
                        let ctx = PaneKeys.Context(responder: r, keyFocus: f, panes: n, splitsEnabled: false)
                        XCTAssertTrue(PaneKeys.treeAction(for: treeKey(c.code, c.mods, c.chars, c.ign), context: ctx,
                                                          renaming: false, form: false) == nil, "\(c.name) \(n) panes")
                    }
                }
            }
        }
    }

    /// Gate on: the tree keys and ⌃⌘S (step 4) map; everything else is nil (⌘1, ⌃Tab, ⌘J, ⇧⌘T); the rename field keeps
    /// every chord on today's route, the New session form every chord but ⌘W (#1658); one pane routes only the splits and ⌃⌘S.
    @MainActor
    func testTreeKeysPureRouteMapsOnlyTheTreeKeys() {
        let two = PaneKeys.Context(responder: .terminal, keyFocus: .pane, panes: 2, splitsEnabled: true)
        let want: [String: PaneAction] = [
            "⌘D": .split(.columns), "⇧⌘D": .split(.rows), "⌘W": .closePane, "⌘]": .cycle(1), "⌘[": .cycle(-1),
            "⌥⌘←": .focus(.left), "⌥⌘→": .focus(.right), "⌥⌘↓": .focus(.down), "⌥⌘↑": .focus(.up),
            "⇧⌘Return": .zoom, "⇧⌘Enter": .zoom, "⌃⌘S": .toggleSidebar,
        ]
        for c in Self.treeChords {
            let e = treeKey(c.code, c.mods, c.chars, c.ign)
            XCTAssertEqual(PaneKeys.treeAction(for: e, context: two, renaming: false, form: false), want[c.name], c.name)
            XCTAssertTrue(PaneKeys.treeAction(for: e, context: two, renaming: true, form: false) == nil, "renaming: \(c.name)")
            // #1658: under the form ⌘W closes the pane (the form with it); every other chord keeps today's route.
            XCTAssertTrue(PaneKeys.treeAction(for: e, context: two, renaming: false, form: true) == (c.name == "⌘W" ? .closePane : nil),
                          "the form: \(c.name)")
            let one = PaneKeys.Context(responder: .other, keyFocus: .pane, panes: 1, splitsEnabled: true)
            let alone = PaneKeys.treeAction(for: e, context: one, renaming: false, form: false)
            XCTAssertTrue(alone == (c.name.hasSuffix("D") || c.name == "⌃⌘S" ? want[c.name] : nil), "one pane: \(c.name)")
        }
        let others: [(UInt16, NSEvent.ModifierFlags, String)] = [(18, [.command], "1"), (48, [.control], "\t"),
                                                                 (38, [.command], "j"), (17, [.command, .shift], "T")]
        for (code, mods, chars) in others {
            XCTAssertTrue(PaneKeys.treeAction(for: treeKey(code, mods, chars), context: two, renaming: false, form: false) == nil,
                          "\(code): not routed by this step")
        }
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                  context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)!
        XCTAssertTrue(PaneKeys.treeAction(for: up, context: two, renaming: false, form: false) == nil, "a key up")
    }

    /// R900-1: ⌃⌘S on a Cyrillic or Greek layout (the control character, then the layout's own letter) is the toggle by
    /// the S key's code; a Latin letter still wins, so Dvorak's O on that key is not, and Dvorak's own S is.
    @MainActor
    func testTreeKeysControlCommandSMapsOnACyrillicLayout() {
        let c = PaneKeys.Context(responder: .other, keyFocus: .pane, panes: 1, splitsEnabled: true)
        let cc: NSEvent.ModifierFlags = [.control, .command]
        XCTAssertEqual(PaneKeys.action(for: treeKey(1, cc, "\u{13}", "ы"), context: c), .toggleSidebar, "Russian")
        XCTAssertEqual(PaneKeys.action(for: treeKey(1, cc, "\u{13}", "с"), context: c), .toggleSidebar, "Bulgarian Phonetic")
        XCTAssertEqual(PaneKeys.action(for: treeKey(1, cc, "\u{13}", "σ"), context: c), .toggleSidebar, "Greek")
        XCTAssertEqual(PaneKeys.action(for: treeKey(1, cc, "\u{13}", "s"), context: c), .toggleSidebar, "Latin")
        XCTAssertTrue(PaneKeys.action(for: treeKey(1, cc, "\u{f}", "o"), context: c) == nil, "Dvorak: O sits on that key")
        XCTAssertEqual(PaneKeys.action(for: treeKey(41, cc, "\u{13}", "s"), context: c), .toggleSidebar, "Dvorak's S key")
        XCTAssertTrue(PaneKeys.action(for: treeKey(13, cc, "\u{17}", "ц"), context: c) == nil, "another Cyrillic key")
        XCTAssertTrue(PaneKeys.action(for: treeKey(1, [.command], "s", "ы"), context: c) == nil, "⌘S alone is nothing")
    }

    // MARK: Gate off: every chord through the window as today (one row per chord)

    /// The chord through the never-shown window with the gate off on a 2-pane layout: the same return and the same
    /// route as before #831, the layout and the keys' side unchanged; ⌘W asks the window to close once.
    @MainActor
    func assertTreeChordAsToday(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let c = try XCTUnwrap(Self.treeChords.first { $0.name == name }, file: file, line: line)
        try withTreeGate(false) {
            let (win, m, rec) = treeWindow()
            defer { win.close(); m.close() }
            var two = m.layout
            if case let .success(l) = two.split(axis: .columns, minimum: .zero, in: CGRect(x: 0, y: 0, width: 1000, height: 600)) {
                two = l
            }
            m.adopt(two)
            m.keyFocus = .sidebar
            let before = m.layout
            XCTAssertEqual(before.panes.count, 2, file: file, line: line)
            let e = treeKey(c.code, c.mods, c.chars, c.ign)
            let today = AgentsNSWindow.route(e, responder: win.responderKind, sidebarFocused: true, terminalMode: m.paneHasTerminal)
            let closes = name == "⌘W"
            XCTAssertEqual(today, closes ? .close : .pass, "\(name): today's route", file: file, line: line)
            XCTAssertEqual(win.performKeyEquivalent(with: e), closes, "\(name): handled only where it was", file: file, line: line)
            XCTAssertEqual(rec.asks, closes ? 1 : 0, "\(name): the window's close", file: file, line: line)
            XCTAssertTrue(m.layout == before, "\(name): the layout unchanged", file: file, line: line)
            XCTAssertEqual(m.keyFocus, .sidebar, "\(name): the keys stay", file: file, line: line)
            XCTAssertFalse(win.isVisible, "never shown", file: file, line: line)
        }
    }

    @MainActor func testTreeKeysGateOffCommandDAsToday() throws { try assertTreeChordAsToday("⌘D") }
    @MainActor func testTreeKeysGateOffShiftCommandDAsToday() throws { try assertTreeChordAsToday("⇧⌘D") }
    @MainActor func testTreeKeysGateOffCommandWClosesTheWindow() throws { try assertTreeChordAsToday("⌘W") }
    @MainActor func testTreeKeysGateOffCommandRightBracketAsToday() throws { try assertTreeChordAsToday("⌘]") }
    @MainActor func testTreeKeysGateOffCommandLeftBracketAsToday() throws { try assertTreeChordAsToday("⌘[") }
    @MainActor func testTreeKeysGateOffOptionCommandLeftAsToday() throws { try assertTreeChordAsToday("⌥⌘←") }
    @MainActor func testTreeKeysGateOffOptionCommandRightAsToday() throws { try assertTreeChordAsToday("⌥⌘→") }
    @MainActor func testTreeKeysGateOffOptionCommandDownAsToday() throws { try assertTreeChordAsToday("⌥⌘↓") }
    @MainActor func testTreeKeysGateOffOptionCommandUpAsToday() throws { try assertTreeChordAsToday("⌥⌘↑") }
    @MainActor func testTreeKeysGateOffShiftCommandReturnAsToday() throws { try assertTreeChordAsToday("⇧⌘Return") }
    @MainActor func testTreeKeysGateOffShiftCommandEnterAsToday() throws { try assertTreeChordAsToday("⇧⌘Enter") }
    @MainActor func testTreeKeysGateOffControlCommandSAsToday() throws { try assertTreeChordAsToday("⌃⌘S") }

    // MARK: Gate on: end to end through performKeyEquivalent

    @MainActor
    func press(_ win: AgentsNSWindow, _ name: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let c = Self.treeChords.first(where: { $0.name == name }) else {
            XCTFail("no chord \(name)", file: file, line: line)
            return false
        }
        return win.performKeyEquivalent(with: treeKey(c.code, c.mods, c.chars, c.ign))
    }

    /// 7.3: ⌘D splits the focused pane right, ⇧⌘D down; the new pane is empty, focused, and the panes take the keys.
    @MainActor
    func testTreeKeysSplitRightAndDown() throws {
        try withTreeGate(true) {
            let (win, m, rec) = treeWindow()
            defer { win.close(); m.close() }
            let first = m.layout.focused
            m.keyFocus = .sidebar
            XCTAssertTrue(press(win, "⌘D"))
            guard case let .split(axis, _, .leaf(a), .leaf(b)) = m.layout.tree else { return XCTFail("\(m.layout.tree)") }
            XCTAssertEqual(axis, .columns, "⌘D: the new pane to the right")
            XCTAssertEqual(a.id, first)
            XCTAssertEqual(m.layout.focused, b.id, "the new pane takes focus")
            XCTAssertTrue(b.target == nil, "and is empty")
            XCTAssertEqual(m.keyFocus, .pane)
            XCTAssertTrue(press(win, "⇧⌘D"))
            guard case let .split(.columns, _, .leaf, .split(down, _, .leaf(b2), .leaf(c))) = m.layout.tree else {
                return XCTFail("\(m.layout.tree)")
            }
            XCTAssertEqual(down, .rows, "⇧⌘D: the new pane below")
            XCTAssertEqual(b2.id, b.id)
            XCTAssertEqual(m.layout.focused, c.id)
            XCTAssertEqual(m.paneFrames(in: m.paneArea).count, 3, "three panes tile the area")
            XCTAssertEqual(rec.asks, 0)
        }
    }

    /// 3.3 / 12.1: six panes by keys; the seventh is refused at the cap, and a split with no room is refused: both
    /// swallowed with the refusal in the notice line, the layout unchanged; the next split that lands drops it.
    @MainActor
    func testTreeKeysBuildSixPanesAndRefuseTheSeventhAndNoRoom() throws {
        try withTreeGate(true) {
            let (win, m, _) = treeWindow(area: CGSize(width: 3000, height: 2000))
            defer { win.close(); m.close() }
            for (i, k) in ["⌘D", "⇧⌘D", "⌘D", "⇧⌘D", "⌘D"].enumerated() {
                XCTAssertTrue(press(win, k), "\(k) \(i)")
                XCTAssertEqual(m.layout.panes.count, i + 2)
            }
            XCTAssertEqual(m.paneFrames(in: m.paneArea).count, 6, "six tiled panes")
            let six = m.layout
            XCTAssertTrue(press(win, "⇧⌘D"), "refused, and shown: swallowed")
            XCTAssertEqual(m.paneRefusal, .cap)
            XCTAssertTrue(m.layout == six)

            let (w2, small, _) = treeWindow(area: CGSize(width: 500, height: 600))
            defer { w2.close(); small.close() }
            XCTAssertTrue(press(w2, "⌘D"))
            XCTAssertEqual(small.paneRefusal, .noRoom, "two columns of 250 are under the 300 minimum")
            XCTAssertEqual(small.layout.panes.count, 1)
            XCTAssertTrue(press(w2, "⇧⌘D"), "two rows of 300 fit")
            XCTAssertTrue(small.paneRefusal == nil, "a split that lands drops the refusal")
            XCTAssertEqual(small.layout.panes.count, 2)
        }
    }

    /// 7.3: ⌘W with two panes closes the focused pane, never the window; the sibling takes focus. With one pane ⌘W
    /// closes the window, as today. ⇧⌘W stays the window's close whatever the pane count (today's route).
    @MainActor
    func testTreeKeysCommandWClosesThePaneWithTwoAndTheWindowWithOne() throws {
        try withTreeGate(true) {
            let (win, m, rec) = treeWindow()
            defer { win.close(); m.close() }
            let first = m.layout.focused
            XCTAssertTrue(press(win, "⌘D"))
            XCTAssertTrue(win.performKeyEquivalent(with: treeKey(13, [.command, .shift], "W", "w")))
            XCTAssertEqual(rec.asks, 1, "⇧⌘W: the window")
            XCTAssertEqual(m.layout.panes.count, 2, "and no pane")
            m.keyFocus = .sidebar
            XCTAssertTrue(press(win, "⌘W"))
            XCTAssertEqual(rec.asks, 1, "⌘W with two panes never asks the window to close")
            XCTAssertEqual(m.layout.order, [first], "the focused (new) pane closed")
            XCTAssertEqual(m.layout.focused, first, "the sibling takes focus")
            XCTAssertEqual(m.keyFocus, .pane)
            XCTAssertTrue(press(win, "⌘W"))
            XCTAssertEqual(rec.asks, 2, "one pane: ⌘W closes the window, as today")
            XCTAssertEqual(m.layout.order, [first])
        }
    }

    /// 12.1: ⌥⌘arrows go to the nearest pane that way and stop at an edge (not handled there: the key goes on as
    /// today); ⌘] / ⌘[ go by tree order and wrap. Layout: A | (B over C).
    @MainActor
    func testTreeKeysMoveFocusByDirectionAndByOrder() throws {
        try withTreeGate(true) {
            let (win, m, _) = treeWindow()
            defer { win.close(); m.close() }
            let a = m.layout.focused
            XCTAssertTrue(press(win, "⌘D"))
            let b = m.layout.focused
            XCTAssertTrue(press(win, "⇧⌘D"))
            let c = m.layout.focused
            XCTAssertEqual(m.layout.order, [a, b, c])
            m.keyFocus = .sidebar
            XCTAssertTrue(press(win, "⌥⌘←"))
            XCTAssertEqual(m.layout.focused, a)
            XCTAssertEqual(m.keyFocus, .pane)
            XCTAssertFalse(press(win, "⌥⌘←"), "the left edge: no wrap, not swallowed")
            XCTAssertFalse(press(win, "⌥⌘↑"), "nothing above A")
            XCTAssertEqual(m.layout.focused, a)
            XCTAssertTrue(press(win, "⌥⌘→"))
            XCTAssertEqual(m.layout.focused, c, "the tie goes to the most recently focused")
            XCTAssertTrue(press(win, "⌥⌘↑"))
            XCTAssertEqual(m.layout.focused, b)
            XCTAssertFalse(press(win, "⌥⌘→"), "the right edge")
            XCTAssertTrue(press(win, "⌥⌘↓"))
            XCTAssertEqual(m.layout.focused, c)
            XCTAssertFalse(press(win, "⌥⌘↓"), "the bottom edge")
            XCTAssertTrue(press(win, "⌘]"))
            XCTAssertEqual(m.layout.focused, a, "⌘] wraps from the last pane to the first")
            XCTAssertTrue(press(win, "⌘["))
            XCTAssertEqual(m.layout.focused, c, "⌘[ wraps from the first to the last")
            XCTAssertTrue(press(win, "⌘["))
            XCTAssertEqual(m.layout.focused, b)
        }
    }

    /// 7.4 as model state (this step draws nothing new): ⇧⌘Return zooms the focused pane and the keypad Enter unzooms;
    /// a focus key while zoomed moves the zoom; a split or a close while zoomed unzooms first (7.3). A zoomed model
    /// still draws its tiling today (frames ignore zoom).
    @MainActor
    func testTreeKeysZoomIsModelStateAndASplitOrCloseUnzooms() throws {
        try withTreeGate(true) {
            // Wide enough that the left half (1000) still splits into two columns over the 300 minimum.
            let (win, m, _) = treeWindow(area: CGSize(width: 2000, height: 600))
            defer { win.close(); m.close() }
            XCTAssertFalse(press(win, "⇧⌘Return"), "one pane: nothing to zoom, the key goes on")
            XCTAssertTrue(press(win, "⌘D"))
            let b = m.layout.focused
            XCTAssertTrue(press(win, "⇧⌘Return"))
            XCTAssertEqual(m.layout.zoomed, b)
            XCTAssertEqual(m.paneFrames(in: m.paneArea).count, 2, "drawn as the tiling until zoom is drawn (a later step)")
            XCTAssertTrue(press(win, "⌘["))
            XCTAssertEqual(m.layout.zoomed, m.layout.focused, "the zoom moves with the focus")
            XCTAssertNotEqual(m.layout.zoomed, b)
            XCTAssertTrue(press(win, "⇧⌘Enter"))
            XCTAssertTrue(m.layout.zoomed == nil, "the keypad Enter unzooms")
            XCTAssertTrue(press(win, "⇧⌘Return"))
            XCTAssertTrue(press(win, "⌘D"))
            XCTAssertTrue(m.layout.zoomed == nil, "a split while zoomed unzooms first")
            XCTAssertEqual(m.layout.panes.count, 3)
            XCTAssertTrue(press(win, "⇧⌘Return"))
            XCTAssertTrue(press(win, "⌘W"))
            XCTAssertTrue(m.layout.zoomed == nil, "a close while zoomed unzooms first")
            XCTAssertEqual(m.layout.panes.count, 2)
        }
    }

    /// With the gate on, ⌃⌘S toggles the sidebar (step 4): each press is handled, the layout is unchanged, the window is
    /// never asked to close, and after two presses the sidebar is shown again. The preference is saved and restored.
    @MainActor
    func testTreeKeysControlCommandSTogglesTheSidebarWithTheGateOn() throws {
        try withSidebarRow(gate: true) {
            let (win, m, rec) = treeWindow()
            defer { win.close(); m.close() }
            XCTAssertTrue(press(win, "⌘D"))
            let before = m.layout
            XCTAssertTrue(win.performKeyEquivalent(with: treeKey(1, [.control, .command], "\u{13}", "ы")))
            XCTAssertTrue(m.sidebarHidden, "the first press hides it")
            XCTAssertTrue(press(win, "⌃⌘S"))
            XCTAssertFalse(m.sidebarHidden, "two presses: shown again")
            XCTAssertTrue(m.layout == before)
            XCTAssertEqual(rec.asks, 0)
        }
    }
}
