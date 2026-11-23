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
            "Jump to Session 9", "Jump to Session 10", "Jump to Session 11", "Jump to Session 12", "Jump to Session 13",
            "Jump to Session 14", "Jump to Session 15", "Jump to Session 16", "Jump to Session 17", "Jump to Session 18",
            // #1471: "Terminal or Transcript" and "Jump to Chapter\u{2026}" went with Transcript mode.
            "X-Ray\u{2026}", "Find\u{2026}", "Find Next", "Find Previous", "Bigger Text",
            "Smaller Text", "Actual Size", "New Session", "New Shell", "Stop or Remove", "Close Window",
        ])
        XCTAssertEqual(AgentGoMenu.title, "Go")
    }

    /// Every table chord, built as a key-down, is what `route` returns (a terminal pane or none; the sidebar focused).
    func testKeyTableIsWhatRouteReturns() {
        XCTAssertEqual(AgentsNSWindow.keyTable.count, 31)   // #1470: the 3 level keys out, Option-Command-1...9 in; #1471: Command-T, L out; #1820: #1111's Control-Tab, Control-Shift-Tab out
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
    /// #1726: the items are spread over Session, View, Go and Layout (each in one menu, none lost, none twice).
    func testEachItemRunsTheWindowsPerformAndMatchesNoKey() {
        let win = window()
        defer { win.close() }
        XCTAssertEqual(win.menus.map(\.kind), [.session, .view, .go, .layout])
        XCTAssertTrue(win.menus.contains { $0 === win.goMenu })
        var all: [String] = []
        for go in win.menus {
        guard let menu = go.item.submenu else { return XCTFail("a submenu") }
        XCTAssertEqual(menu.title, go.kind.rawValue)
        go.menuNeedsUpdate(menu)
        XCTAssertFalse(menu.items.first?.isSeparatorItem ?? true, "\(go.kind): no separator first")
        XCTAssertFalse(menu.items.last?.isSeparatorItem ?? true, "\(go.kind): no separator last")
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.count, go.shown.count)
        all += items.map(\.title)
        XCTAssertEqual(items.map(\.title), [
            AgentGoMenu.Kind.session: ["New Session", "New Shell", "Stop or Remove", "Close Window"],
            .view: ["Bigger Text", "Smaller Text", "Actual Size", "Toggle Sidebar", "Zoom Pane", "Full Sidebar", "Mini Sidebar",
                    "Slide-In Sidebar"],
            .go: ["Previous Session", "Next Session", "Jump to Session 1", "Jump to Session 2",
                  "Jump to Session 3", "Jump to Session 4", "Jump to Session 5", "Jump to Session 6", "Jump to Session 7",
                  "Jump to Session 8", "Jump to Session 9", "Jump to Session 10", "Jump to Session 11", "Jump to Session 12",
                  "Jump to Session 13", "Jump to Session 14", "Jump to Session 15", "Jump to Session 16", "Jump to Session 17",
                  "Jump to Session 18", "X-Ray\u{2026}", "Find\u{2026}", "Find Next", "Find Previous", "Next Needs You"],
            .layout: ["Split Right", "Split Down", "Next Pane", "Previous Pane", "Edit Layout"],
        ][go.kind], "\(go.kind)")
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
        XCTAssertEqual(all.count, 42, "#1379: the 31 keyed items (#1471; #1820: #1111's two out) and the three sidebar modes; #1477: the 7 pane items, splits on; #1538: Edit Layout")
        // #1586: the list itself, literal (no model: one pane, so #1367's Command-W item reads Close Window); #1726: as a set
        XCTAssertEqual(all.count, Set(all).count, "no item in two menus")
        XCTAssertEqual(Set(all), Set([
            "Previous Session", "Next Session", "Jump to Session 1", "Jump to Session 2", "Jump to Session 3",
            "Jump to Session 4", "Jump to Session 5", "Jump to Session 6", "Jump to Session 7", "Jump to Session 8",
            "Jump to Session 9", "Jump to Session 10", "Jump to Session 11", "Jump to Session 12", "Jump to Session 13",
            "Jump to Session 14", "Jump to Session 15", "Jump to Session 16", "Jump to Session 17", "Jump to Session 18",
            "X-Ray\u{2026}", "Find\u{2026}", "Find Next", "Find Previous", "Bigger Text",
            "Smaller Text", "Actual Size", "New Session", "New Shell", "Stop or Remove", "Close Window",
            "Next Needs You", "Toggle Sidebar", "Split Right", "Split Down", "Next Pane", "Previous Pane", "Zoom Pane",
            "Edit Layout", "Full Sidebar", "Mini Sidebar", "Slide-In Sidebar",
        ]))
    }

    /// #1726: the Layout menu's list: one item per Layouts row, its Control-N what PaneKeys gives `.layout(n)` for, the
    /// active row checked by menuNeedsUpdate; no rows: nothing (no separator either).
    func testLayoutListItemsAreTheControlDigitKeys() {
        XCTAssertTrue(AgentGoMenu.layoutListEntries(nil).isEmpty)
        XCTAssertTrue(AgentGoMenu.layoutListEntries([]).isEmpty)
        let rows = (1...9).map { AgentWindowModel.LayoutRow(id: UUID(), number: $0, name: "api \($0)", active: $0 == 2) }
        let list = AgentGoMenu.layoutListEntries(rows)
        XCTAssertTrue(list.first == .some(nil), "a separator first")
        let entries = list.compactMap { $0 }
        XCTAssertEqual(entries.map(\.title), rows.map(\.name))
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // kVK_ANSI_1...9 (as keyTable)
        let c = PaneKeys.Context(responder: .other, keyFocus: .pane, panes: 2, splitsEnabled: true)
        for (e, code) in zip(entries, codes) {
            XCTAssertEqual(AgentGoMenu.kind(of: e.action), .layout, e.title)
            guard case .pane(let a) = e.action, let ev = AgentsNSWindow.keyEvent(e.key, e.mods, code) else { return XCTFail(e.title) }
            XCTAssertEqual(PaneKeys.action(for: ev, context: c), a, "\(e.title): the shown chord is the handled key")
        }
        XCTAssertEqual(entries.count, codes.count)
        // the list lands in Layout only, after the pane items (#1895: no Edit Layout)
        let all = AgentGoMenu.entries(splits: true) + list
        XCTAssertEqual(AgentGoMenu.entries(all, in: .layout).compactMap { $0 }.map(\.title),
                       ["Split Right", "Split Down", "Next Pane", "Previous Pane"] + rows.map(\.name))
        for k in [AgentGoMenu.Kind.session, .view, .go] {
            XCTAssertFalse(AgentGoMenu.entries(all, in: k).contains { $0.map { rows.map(\.name).contains($0.title) } ?? false }, "\(k)")
        }
    }

    /// #1726: a Layout list item runs the window's perform with `.layout(n)` (the ⌃N action); no model: nothing, off.
    func testLayoutListItemRunsTheWindowsPerform() {
        let win = window()
        defer { win.close() }
        XCTAssertFalse(win.perform(pane: .layout(1)), "no model: false")
        XCTAssertEqual(win.lastPerformed, .pane(.layout(1)))
        XCTAssertFalse(win.enabled(.pane(.layout(1))), "no model: off")
    }

    /// #1726: the menus go in the macOS order: Session in the File place, then Edit, View, Go, Layout, then Window; each
    /// once; resignKey's remove takes all four out.
    func testWindowMenusGoInTheStandardOrder() {
        XCTAssertEqual(AgentGoMenu.insertionIndex(["Prosper", "Edit", "Window"], after: nil), 1)
        XCTAssertEqual(AgentGoMenu.insertionIndex([], after: nil), 0)
        XCTAssertEqual(AgentGoMenu.insertionIndex(["Prosper", "Session", "Edit", "View", "Window"], after: ["Edit", "View"]), 4)
        let main = NSMenu()
        for t in ["Prosper", "Edit", "Window"] {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.submenu = NSMenu(title: t)
            main.addItem(i)
        }
        let win = window()
        defer { win.close() }
        let titles = { main.items.map { $0.submenu?.title ?? $0.title } }
        for _ in 0..<2 { for m in win.menus { m.install(in: main) } }
        XCTAssertEqual(titles(), ["Prosper", "Session", "Edit", "View", "Go", "Layout", "Window"])
        for m in win.menus { m.remove(from: main) }
        XCTAssertEqual(titles(), ["Prosper", "Edit", "Window"])
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

    /// #1367: the Command-W item is "Close Pane" (the pane close) only with splits on and more than one pane; else "Close Window".
    func testCloseItemFollowsTheRoute() {
        func close(_ splits: Bool, _ panes: Int) -> AgentGoMenu.Entry? {
            AgentGoMenu.entries(splits: splits, panes: panes).compactMap { $0 }.first { $0.key == "w" }
        }
        for (splits, panes) in [(true, 2), (true, 3)] {
            XCTAssertTrue(close(splits, panes)?.title == "Close Pane" && close(splits, panes)?.action == .pane(.closePane), "\(splits) \(panes)")
        }
        for (splits, panes) in [(true, 1), (true, 0), (false, 2), (false, 1)] {
            XCTAssertTrue(close(splits, panes)?.title == "Close Window" && close(splits, panes)?.action == .key(.close), "\(splits) \(panes)")
        }
        let c = PaneKeys.Context(responder: .other, keyFocus: .pane, panes: 2, splitsEnabled: true)
        if let e = AgentsNSWindow.keyEvent("w", .command, 13) {
            XCTAssertEqual(PaneKeys.action(for: e, context: c), .closePane, "the key does what the item says")
        } else { XCTFail("event") }
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
