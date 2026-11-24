import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1916: the pane "⋯" items show their keys as menu shortcuts, read from the Go menu's table. Menus are built as entry
/// lists and never popped; the Window menu is a built NSMenu never shown; events are built, never posted.
@MainActor
final class AgentMenuKeyHintTests: XCTestCase {
    /// The gate-on pane items of a two-pane layout, no refusal.
    private var two: [AgentWindowMenuEntry] { AgentWindowControls.paneMenu(splits: true, panes: 2, right: nil, down: nil) }

    private func hint(_ title: String, _ e: [AgentWindowMenuEntry], keyPanes: Int?) -> AgentGoMenu.Entry? {
        e.first { if case let .pane(t, _, _) = $0 { t == title } else { false } }
            .flatMap { AgentWindowControls.keyHint($0, keyPanes: keyPanes) }
    }

    private func chord(_ h: AgentGoMenu.Entry?) -> String? { h.map { "\($0.key)|\($0.mods.rawValue)" } }

    /// The focused pane's menu: Split Right ⌘D, Split Down ⇧⌘D, Zoom Pane ⇧⌘Return, Close Pane ⌘W; Equalize has no key.
    func testFocusedPaneItemsShowTheirKeys() {
        let sc: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(chord(hint("Split Right", two, keyPanes: 2)), "d|\(NSEvent.ModifierFlags.command.rawValue)")
        XCTAssertEqual(chord(hint("Split Down", two, keyPanes: 2)), "d|\(sc.rawValue)")
        XCTAssertEqual(chord(hint(AgentWindowControls.zoomLabel, two, keyPanes: 2)), "\r|\(sc.rawValue)")
        XCTAssertEqual(chord(hint(AgentWindowControls.closePaneLabel, two, keyPanes: 2)),
                       "w|\(NSEvent.ModifierFlags.command.rawValue)")
        XCTAssertTrue(hint("Equalize", two, keyPanes: 2) == nil, "no key equalizes")
        let s = hint("Split Down", two, keyPanes: 2)?.shortcut
        XCTAssertEqual(s?.key, KeyEquivalent("d"))
        XCTAssertEqual(s?.modifiers, [.command, .shift], "the shown modifiers are the table's")
        XCTAssertEqual(hint(AgentWindowControls.zoomLabel, two, keyPanes: 2)?.shortcut?.key, .return)
    }

    /// Close Pane's ⌘W only with more than one pane (the table's rule: one pane, ⌘W closes the window); the splits keep
    /// theirs with one pane.
    func testCloseHintOnlyWithTwoOrMorePanes() {
        let close = AgentWindowMenuEntry.pane(AgentWindowControls.closePaneLabel, enabled: true, verb: .action(.closePane))
        XCTAssertTrue(AgentWindowControls.keyHint(close, keyPanes: 1) == nil, "one pane: ⌘W is Close Window")
        XCTAssertEqual(AgentWindowControls.keyHint(close, keyPanes: 2)?.key, "w")
        XCTAssertEqual(AgentWindowControls.keyHint(close, keyPanes: 3)?.key, "w")
        let one = AgentWindowControls.paneMenu(splits: true, panes: 1, right: nil, down: nil)
        XCTAssertEqual(hint("Split Right", one, keyPanes: 1)?.key, "d")
    }

    /// Another pane's menu: its items run on that pane, the keys on the focused one: no pane hint. X-Ray's item (only in
    /// the focused pane's menu) keeps ⇧⌘X.
    func testUnfocusedPaneShowsNoPaneHint() {
        for e in two { XCTAssertTrue(AgentWindowControls.keyHint(e, keyPanes: nil) == nil, "\(e)") }
        XCTAssertEqual(chord(AgentWindowControls.keyHint(.xray(pane: UUID()), keyPanes: nil)),
                       "x|\(NSEvent.ModifierFlags([.command, .shift]).rawValue)")
    }

    /// The tie: every hint is the Go menu's own entry for the same action (one table, so a key change moves both), and
    /// every pane item whose action has a Go entry shows it.
    func testHintsAreTheGoMenuEntries() {
        let table = AgentGoMenu.entries(splits: true, panes: 2).compactMap { $0 }
        for e in two + [.xray(pane: UUID())] {
            let want: AgentGoMenu.Action?
            switch e {
            case .xray: want = .key(.xray)
            case .pane(_, _, .action(let a)): want = .pane(a)
            default: want = nil
            }
            let entry = want.flatMap { w in table.first { $0.action == w } }
            XCTAssertEqual(AgentWindowControls.keyHint(e, keyPanes: 2), entry, "\(e)")
        }
        XCTAssertEqual(two.compactMap { AgentWindowControls.keyHint($0, keyPanes: 2) }.count, 4, "split x2, zoom, close")
        for h in table {
            guard let s = h.shortcut else { continue }
            XCTAssertEqual(s.modifiers.contains(.shift), h.mods.contains(.shift), h.title)
            XCTAssertEqual(s.modifiers.contains(.command), h.mods.contains(.command), h.title)
            XCTAssertEqual(s.modifiers.contains(.option), h.mods.contains(.option), h.title)
            XCTAssertEqual(s.modifiers.contains(.control), h.mods.contains(.control), h.title)
        }
    }

    /// X-Ray's title loses the typed "⇧⌘X": it is the Go menu's title; the chord is the hint.
    func testXrayTitleHasNoTypedKeys() {
        XCTAssertEqual(AgentWindowControls.xrayLabel, "X-Ray\u{2026}")
        XCTAssertEqual(AgentWindowControls.xrayLabel, AgentWindowControls.keyHint(.xray(pane: UUID()), keyPanes: 2)?.title)
        XCTAssertFalse(AgentWindowControls.xrayLabel.contains("\u{2318}"))
    }

    /// No ⌘M on Zoom: no pane item shares a title with a Window menu item (a bare "Zoom" drew Minimize's Command-M), and
    /// no hint is M.
    func testNoPaneItemTakesAWindowMenuTitle() {
        let window = Set(AppDelegate.makeWindowMenu().items.map(\.title))
        let titles = two.compactMap { (e: AgentWindowMenuEntry) -> String? in
            if case let .pane(t, _, _) = e { return t }
            return nil
        }
        XCTAssertTrue(window.isDisjoint(with: titles), "\(titles)")
        XCTAssertEqual(AgentWindowControls.zoomLabel, "Zoom Pane")
        XCTAssertFalse(two.compactMap { AgentWindowControls.keyHint($0, keyPanes: 2)?.key }.contains("m"))
    }

    /// The chords the window keeps from the view tree are the hinted ones and no other.
    func testMenuHintKeysAreTheHintedChords() {
        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags, _ c: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                             characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
        }
        let sc: NSEvent.ModifierFlags = [.command, .shift]
        for (e, name) in [(key(2, .command, "d"), "⌘D"), (key(2, sc, "d"), "⇧⌘D"), (key(36, sc, "\r"), "⇧⌘Return"),
                          (key(13, .command, "w"), "⌘W"), (key(7, sc, "x"), "⇧⌘X")] {
            XCTAssertTrue(AgentsNSWindow.menuHintKey(e), name)
        }
        for (e, name) in [(key(40, .command, "k"), "⌘K"), (key(36, .command, "\r"), "⌘Return"), (key(3, .command, "f"), "⌘F"),
                          (key(38, .command, "j"), "⌘J"), (key(2, [.command, .option], "d"), "⌥⌘D")] {
            XCTAssertFalse(AgentsNSWindow.menuHintKey(e), name)
        }
    }
}

/// #1916: a hinted chord the route passes never reaches the view tree (where a SwiftUI menu could match it); the first
/// responder still gets it, and any other passed chord still travels the tree as before. A never-shown window.
extension AgentWindowD1Tests {
    @MainActor
    final class HintKeyRecorder: NSView {
        var seen: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            seen.append(event.charactersIgnoringModifiers ?? "")
            return false
        }
    }

    @MainActor
    func testMenuHintKeyPassedByTheRouteSkipsTheViewTree() throws {
        try withTreeGate(false) {   // gate off: ⌘D and ⇧⌘D pass the route (nothing to split)
            let (win, m, _) = treeWindow()
            defer { win.close(); m.close() }
            let tree = HintKeyRecorder(), responder = HintKeyRecorder()
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            root.addSubview(tree)
            win.contentView = root
            XCTAssertFalse(win.performKeyEquivalent(with: treeKey(2, .command, "d")))
            XCTAssertEqual(tree.seen, [], "⌘D: no view in the tree performs it")
            XCTAssertFalse(win.performKeyEquivalent(with: treeKey(40, .command, "k")))
            XCTAssertEqual(tree.seen, ["k"], "⌘K: the tree as before")
            root.addSubview(responder)
            XCTAssertTrue(win.makeFirstResponder(responder))
            XCTAssertFalse(win.performKeyEquivalent(with: treeKey(2, [.command, .shift], "D", "d")))
            XCTAssertEqual(responder.seen, ["d"], "⇧⌘D: the first responder gets it once")
            XCTAssertEqual(tree.seen, ["k"], "and nothing else in the tree")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }
}
