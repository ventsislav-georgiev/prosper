import AppKit
import XCTest
@testable import ProsperApp

/// #1359: the Agent Sessions window's Go menu. Offscreen only: the menu is read as values or as a never-shown NSMenu,
/// the main menu is a built NSMenu (NSApp.mainMenu is never read or set), the window is never shown, ordered or made
/// key, and key events are built and handed to the pure routes, never posted.
@MainActor
final class AgentGoMenuTests: XCTestCase {

    private func row(_ key: String, _ mods: NSEvent.ModifierFlags, _ route: String) -> String {
        "\(key.unicodeScalars.map { String($0.value, radix: 16) }.joined())|\(mods.rawValue)|\(route)"
    }

    private func window() -> AgentsNSWindow {
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        return win
    }

    /// The menu's keys, modifiers and routes are the route's own table, as a set and one for one; its titles literal.
    func testGoMenuListMatchesTheRoutesKeyTable() {
        let entries = AgentGoMenu.entries(splits: false).compactMap { $0 }
        let keyed = entries.compactMap { e -> String? in
            guard case .key(let r) = e.action else { return nil }
            return row(e.key, e.mods, "\(r)")
        }
        let table = AgentsNSWindow.keyTable.map { row($0.key, $0.mods, "\($0.route)") }
        XCTAssertEqual(Set(keyed), Set(table), "the menu's chords are the route's table")
        XCTAssertEqual(keyed.count, table.count, "one item per table chord")
        XCTAssertEqual(entries.count, keyed.count, "splits off: no pane item")
        XCTAssertEqual(entries.map(\.title), [
            "Previous Session", "Next Session", "Jump to Session 1", "Jump to Session 2", "Jump to Session 3",
            "Jump to Session 4", "Jump to Session 5", "Jump to Session 6", "Jump to Session 7", "Jump to Session 8",
            "Jump to Session 9", "Terminal or Transcript", "Jump to Chapter\u{2026}", "X-Ray\u{2026}", "Focused Transcript",
            "Default Transcript", "Verbose Transcript", "Find\u{2026}", "Find Next", "Find Previous", "Bigger Text",
            "Smaller Text", "Actual Size", "New Session", "New Shell", "Stop or Remove", "Close Window",
        ])
        XCTAssertEqual(AgentGoMenu.title, "Go")
    }

    /// Every table chord, built as a key-down, is what `route` returns (Terminal mode or Transcript; the sidebar focused).
    func testKeyTableIsWhatRouteReturns() {
        XCTAssertEqual(AgentsNSWindow.keyTable.count, 27)
        for c in AgentsNSWindow.keyTable {
            guard let e = AgentsNSWindow.keyEvent(c.key, c.mods, c.keyCode) else { return XCTFail("event \(c.route)") }
            let routes = [true, false].map {
                AgentsNSWindow.route(e, responder: .other, sidebarFocused: true, terminalMode: $0)
            }
            XCTAssertTrue(routes.contains(c.route), "\(c.route): route gave \(routes)")
        }
    }

    /// Each built item targets the menu, runs the window's own `perform` with its entry's action, and never matches a
    /// key (the window's route keeps every key, so nothing fires twice).
    func testEachItemRunsTheWindowsPerformAndMatchesNoKey() {
        let win = window(), go = win.goMenu
        defer { win.close() }
        guard let menu = go.item.submenu else { return XCTFail("a submenu") }
        go.menuNeedsUpdate(menu)
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.count, go.shown.count)
        XCTAssertEqual(items.count, 27)
        for (item, entry) in zip(items, go.shown) {
            XCTAssertTrue(item.target === go, item.title)
            XCTAssertEqual(item.action, #selector(AgentGoMenu.pick(_:)), item.title)
            XCTAssertEqual(item.keyEquivalent, entry.key, item.title)
            XCTAssertEqual(item.keyEquivalentModifierMask, entry.mods, item.title)
            go.pick(item)
            XCTAssertEqual(win.lastPerformed, entry.action, "\(item.title) runs the window's perform")
            XCTAssertFalse(go.validateMenuItem(item), "no model: off")
        }
        var target: AnyObject?, action: Selector?
        for c in AgentsNSWindow.keyTable {
            guard let e = AgentsNSWindow.keyEvent(c.key, c.mods, c.keyCode) else { return XCTFail("event") }
            XCTAssertFalse(go.menuHasKeyEquivalent(menu, for: e, target: &target, action: &action), "\(c.route)")
        }
    }

    /// Splits off (today): no pane item. On: each pane item's chord is PaneKeys' own action for it.
    func testPaneItemsOnlyWithSplitsOn() {
        let off = AgentGoMenu.entries(splits: false).compactMap { $0 }
        XCTAssertFalse(off.contains { if case .pane = $0.action { return true } else { return false } })
        XCTAssertFalse(off.contains { ["Next Needs You", "Toggle Sidebar", "Split Right"].contains($0.title) })
        let panes = AgentGoMenu.entries(splits: true).compactMap { $0 }.filter {
            if case .pane = $0.action { return true } else { return false }
        }
        XCTAssertEqual(panes.map(\.title), ["Next Needs You", "Toggle Sidebar", "Split Right", "Split Down", "Next Pane",
                                            "Previous Pane", "Zoom Pane"])
        let c = PaneKeys.Context(responder: .other, keyFocus: .pane, panes: 2, splitsEnabled: true)
        for p in panes {
            guard case .pane(let a) = p.action,
                  let e = AgentsNSWindow.keyEvent(p.key, p.mods, p.key == "\r" ? 36 : 0) else { return XCTFail(p.title) }
            XCTAssertEqual(PaneKeys.action(for: e, context: c), a, p.title)
        }
    }

    /// The menu goes right after Edit in a built main menu (never the app's), once, and comes out again.
    func testGoMenuGoesRightAfterEdit() {
        XCTAssertEqual(AgentGoMenu.insertionIndex(["Prosper", "Edit"]), 2)
        XCTAssertEqual(AgentGoMenu.insertionIndex(["Prosper", "Edit", "Window"]), 2)
        XCTAssertEqual(AgentGoMenu.insertionIndex(["Prosper"]), 1, "no Edit: last")
        XCTAssertTrue(AgentGoMenu.mainMenu() == nil, "under XCTest the app's main menu is never touched")

        let main = NSMenu()
        for t in ["Prosper", "Edit", "Window"] {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.submenu = NSMenu(title: t)
            main.addItem(i)
        }
        let win = window(), go = win.goMenu
        defer { win.close() }
        let titles = { main.items.map { $0.submenu?.title ?? $0.title } }
        go.install(in: main)
        XCTAssertEqual(titles(), ["Prosper", "Edit", "Go", "Window"])
        go.install(in: main)
        XCTAssertEqual(titles(), ["Prosper", "Edit", "Go", "Window"], "once")
        go.remove(from: main)
        XCTAssertEqual(titles(), ["Prosper", "Edit", "Window"])
        go.remove(from: main)
        XCTAssertEqual(titles(), ["Prosper", "Edit", "Window"])
    }
}
