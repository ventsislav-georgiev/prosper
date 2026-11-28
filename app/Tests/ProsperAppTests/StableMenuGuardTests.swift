import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1540: a SwiftUI Menu whose parent redraws on a periodic publish closes its open submenu about a second after it
/// opens (#1466 fixed it for the sidebar "..." only). Every Menu under a ticking parent is a StableMenu; this guard
/// fails on any other Menu in app/Sources that is not on the literal allow-list below, and the rows after it tick
/// each fixed menu's parent with equal content and count the menu's body. Offscreen: hosted trees, no window, no menu.
final class StableMenuGuardTests: XCTestCase {
    /// Every SwiftUI Menu left outside StableMenu, by file under app/Sources: how many, and why it is safe.
    static let allowed: [String: (count: Int, why: String)] = [
        "ProsperApp/StableMenu.swift": (1, "the shared piece's own Menu"),
        "ProsperApp/AgentWindow/AgentWindowControls.swift":
            (2, "Model/Effort (AgentSwitchMenus) and the sidebar's submenus (AgentSidebarMenuEntries): submenus drawn inside a StableMenu's content"),
        "ProsperApp/Clipboard/ClipboardPanel.swift":
            (2, "type filter and Actions: the clipboard store and panel model publish on a copy or on input, no timer"),
        "ProsperApp/RunnerPanel.swift": (1, "Actions (Cmd-K): the runner model publishes on typing and its results, no timer"),
        "ProsperApp/SettingsWindow.swift":
            (1, "a key mapping's media-key menu: the settings model publishes on an edit; the 1 s TimelineViews are other panes"),
        "ProsperApp/Kit/KitPaneView.swift": (1, "a kit piece's menu: the kit pane model publishes on an action and its result"),
        "ProsperApp/AgentIsland/AgentIslandPane.swift": (1, "Model aliases: the Settings pane's own @State, no store"),
        "ProsperApp/TextViewer/TextViewerWindow.swift":
            (2, "Copy and Open With: the viewer model publishes on a load, a file change or a notice, no timer"),
    ]

    /// #2104: every right-click menu left outside stableContextMenu, by file: how many, and why it is safe.
    static let allowedContext: [String: (count: Int, why: String)] = [
        "ProsperApp/StableMenu.swift": (1, "the shared piece's own contextMenu (stableContextMenu)"),
        "ProsperApp/LayoutEditorView.swift":
            (2, "the layout editor sheet's layout and group menus: its LayoutStore binding changes only on an edit, no timer"),
    ]

    /// A SwiftUI Menu: `Menu {`, `Menu(title) {`, `SwiftUI.Menu {`; never StableMenu, NSMenu or a lower-case `menu(`.
    static let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])Menu\s*[{(]"#)
    /// #2104: a right-click menu: `.contextMenu {`, `.contextMenu(forSelectionType:`; never `.stableContextMenu(`.
    static let contextPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])\.contextMenu\s*[{(]"#)

    static func menus(in line: Substring, _ p: NSRegularExpression = pattern) -> Int {
        let code = String(line.components(separatedBy: "//").first ?? "")   // a comment that names a Menu is not one
        return p.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// Every match of `p` in app/Sources, by file under it.
    func found(_ p: NSRegularExpression) throws -> [String: Int] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let urls = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        var found: [String: Int] = [:], scanned = 0
        for url in urls where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + Self.menus(in: $1, p) }
            if n > 0 { found[url.path.components(separatedBy: "/Sources/").last ?? url.path, default: 0] += n }
        }
        XCTAssertGreaterThan(scanned, 100, "precondition: the walk reached app/Sources")
        return found
    }

    func testEverySwiftUIMenuIsAStableMenuOrOnTheAllowList() throws {
        for (text, n) in [("Menu {", 1), ("SwiftUI.Menu {", 1), ("Menu(title) {", 1), ("Menu (c.title) {", 1),
                          ("StableMenu(id, entries: e", 0), ("NSMenu(title: \"x\")", 0), ("menu(snap)", 0),
                          ("let x = 1 // a Menu { here", 0)] {
            XCTAssertEqual(Self.menus(in: Substring(text)), n, "the pattern on \(text)")
        }
        let found = try found(Self.pattern)
        let allowed = Self.allowed.mapValues(\.count)
        for (file, n) in found.sorted(by: { $0.key < $1.key }) where allowed[file] != n {
            XCTFail("\(file): \(n) SwiftUI Menu(s), allowed \(allowed[file] ?? 0). A Menu under a parent that redraws "
                    + "on a timer or a periodic publish closes its open submenu (#1540): build it with StableMenu, or "
                    + "add it to StableMenuGuardTests.allowed with the reason its parent never ticks")
        }
        for (file, n) in allowed where found[file] == nil {
            XCTFail("\(file): allowed \(n) Menu(s), found none: drop it from the allow-list")
        }
        XCTAssertTrue(Self.allowed.values.allSatisfy { !$0.why.isEmpty }, "every allowed Menu says why")
    }

    /// #2104 (the 3rd report): a right-click menu under a ticking parent hid and showed again on each tick. Every
    /// `.contextMenu` in app/Sources is a stableContextMenu or on allowedContext with its reason.
    func testEveryContextMenuIsAStableContextMenuOrOnTheAllowList() throws {
        for (text, n) in [(".contextMenu {", 1), ("Text(x).contextMenu {", 1), (".contextMenu(forSelectionType: Int.self) {", 1),
                          (".stableContextMenu(id, entries: e", 0), ("x.contextMenu = menu", 0),
                          ("let x = 1 // a .contextMenu { here", 0)] {
            XCTAssertEqual(Self.menus(in: Substring(text), Self.contextPattern), n, "the pattern on \(text)")
        }
        let found = try found(Self.contextPattern)
        let allowed = Self.allowedContext.mapValues(\.count)
        for (file, n) in found.sorted(by: { $0.key < $1.key }) where allowed[file] != n {
            XCTFail("\(file): \(n) .contextMenu(s), allowed \(allowed[file] ?? 0). A right-click menu under a parent that "
                    + "redraws on a timer or a periodic publish hides and shows again while open (#2104): build it with "
                    + "stableContextMenu, or add it to StableMenuGuardTests.allowedContext with the reason its parent never ticks")
        }
        for (file, n) in allowed where found[file] == nil {
            XCTFail("\(file): allowed \(n) .contextMenu(s), found none: drop it from the allow-list")
        }
        XCTAssertTrue(Self.allowedContext.values.allSatisfy { !$0.why.isEmpty }, "every allowed contextMenu says why")
    }

    // MARK: per fixed menu: its parent ticks with equal content, the menu body runs once

    /// #2104: the shared piece: a right-click menu's items are re-declared only when its entries change.
    @MainActor
    func testAStableContextMenuIsNotRebuiltByAnEqualTick() {
        assertStable("test.context") { v in
            Text("api").stableContextMenu("test.context", entries: v, run: { (_: Int) in }) { v, run in
                Button("\(v)") { run(v) }
            }
        }
    }

    /// #2104: the Agent Island row's right-click menu under its 1 s TimelineView: equal lines, no rebuild.
    @MainActor
    func testIslandRowMenuIsNotRebuiltByAnEqualTick() {
        let s = AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: "api"), alias: "", activity: 0, state: .idle,
                             agents: 0)
        assertStable(AgentIslandView.rowMenuID) { v in
            let d = AgentIslandView.Drawn(session: s, card: nil, open: {}, answer: { _, _ in },
                                          refused: v == 0 ? nil : "need dch 1.38", canStop: true, needs: nil)
            return Text("api").stableContextMenu(AgentIslandView.rowMenuID, entries: AgentIslandView.rowMenu(d),
                                                 run: { (_: Int) in }, items: { AgentIslandView.menuLines($0, $1) })
        }
    }

    @MainActor
    final class Ticker: ObservableObject {
        @Published var tick = 0
        @Published var value = 0
        var bodies = 0
    }

    /// The fixed menu's parent: redraws on every tick and builds the menu from `value` only.
    struct Parent<V: View>: View {
        @ObservedObject var ticker: Ticker
        let make: (Int) -> V
        var body: some View {
            let _ = ticker.bodies += 1
            let _ = ticker.tick
            make(ticker.value)
        }
    }

    @MainActor
    func settle(_ until: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !until() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Three equal ticks leave the menu's body alone; a changed value rebuilds it once.
    @MainActor
    func assertStable<V: View>(_ id: String, file: StaticString = #filePath, line: UInt = #line,
                               _ make: @escaping (Int) -> V) {
        let t = Ticker()
        let host = NSHostingView(rootView: Parent(ticker: t, make: make).frame(width: 200, height: 40))
        func bodies() -> Int { StableMenuProbe.bodies[id, default: 0] }
        func pump(_ moved: () -> Bool) { settle { host.layoutSubtreeIfNeeded(); _ = host.fittingSize; return moved() } }
        let start = bodies()
        pump { bodies() > start }
        let menu0 = bodies()
        XCTAssertGreaterThan(menu0, start, "precondition: the menu is drawn", file: file, line: line)
        for _ in 0..<3 {
            let parent = t.bodies
            t.tick += 1
            pump { t.bodies > parent }
            XCTAssertGreaterThan(t.bodies, parent, "precondition: the tick redrew the parent", file: file, line: line)
        }
        XCTAssertEqual(bodies(), menu0, "equal ticks: the menu is not rebuilt", file: file, line: line)
        t.value = 1
        pump { bodies() > menu0 }
        XCTAssertEqual(bodies(), menu0 + 1, "a changed menu rebuilds once", file: file, line: line)
    }

    @MainActor
    func testStatsHeadlineMenuIsNotRebuiltByASample() {
        assertStable(StatsChoiceMenu.headlineID) { v in
            StatsChoiceMenu(id: StatsChoiceMenu.headlineID,
                            choices: StatsPopupView.headlineChoices([], v == 0 ? nil : "CPU Die"), choose: { _ in })
        }
    }

    @MainActor
    func testStatsOrderMenuIsNotRebuiltByASample() {
        assertStable(StatsChoiceMenu.orderID) { v in
            StatsChoiceMenu(id: StatsChoiceMenu.orderID, choices: StatsPopupView.orderChoices(v == 1), choose: { _ in })
        }
    }

    @MainActor
    func testStatsChoicesKeepTheOldLabels() {
        XCTAssertEqual(StatsPopupView.headlineChoices([], nil).label, "Auto (hottest)")
        XCTAssertEqual(StatsPopupView.headlineChoices([], "Gone").label, "Gone", "a pinned sensor that left keeps its name")
        XCTAssertEqual(StatsPopupView.headlineChoices([], "Gone").selected, "Gone")
        XCTAssertEqual(StatsPopupView.orderChoices(true).label, "By name")
        XCTAssertEqual(StatsPopupView.orderChoices(false).selected, "hottest")
    }

    @MainActor
    func testAIModelRowMenuIsNotRebuiltByADownloadTick() {
        assertStable(AIModelMenu.menuID) { v in
            AIModelMenu(items: [.init(title: "Use for inline", enabled: v == 0), .init(title: "Reveal in Finder")],
                        act: { _ in })
        }
    }

    @MainActor
    func testNewSessionRecentFoldersMenuIsNotRebuiltByAStoreTick() {
        assertStable(AgentNewSession.recentsMenuID) { v in
            AgentRecentFoldersMenu(recents: AgentNewSession.recents(["/Users/example/api"] + (v == 0 ? [] : ["/srv/api-qa"]),
                                                                    remote: false, home: "/Users/example"),
                                   choose: { _ in })
        }
    }

    func testRecentFoldersShowAndSetAsBefore() {
        XCTAssertEqual(AgentNewSession.recents(["/Users/example/api"], remote: false, home: "/Users/example"),
                       [.init(shown: "~/api", set: "~/api")], "this Mac: shown and set abbreviated")
        XCTAssertEqual(AgentNewSession.recents(["/Users/example/api"], remote: true, home: "/Users/example"),
                       [.init(shown: OutsideText.shown("/Users/example/api"), set: "/Users/example/api")],
                       "another Mac: shown through OutsideText, set raw")
    }

    /// The newest `run` is what an item calls, never one kept from the draw that built the menu.
    @MainActor
    func testAnItemRunsTheNewestRun() {
        var got: [String] = []
        let m = StableMenuModel<[Int], Int, EmptyView, EmptyView>("t", [1], content: { _, _ in EmptyView() },
                                                                 label: { _ in EmptyView() })
        m.take(run: { got.append("old \($0)") }, content: { _, _ in EmptyView() }, label: { _ in EmptyView() })
        m.take(run: { got.append("new \($0)") }, content: { _, _ in EmptyView() }, label: { _ in EmptyView() })
        m.send(7)
        XCTAssertEqual(got, ["new 7"])
        var published = 0
        let sub = m.objectWillChange.sink { published += 1 }
        m.show([1])
        XCTAssertEqual(published, 0, "equal entries: no publish")
        m.show([2])
        XCTAssertEqual(published, 1, "changed entries: one publish")
        XCTAssertEqual(m.entries, [2])
        sub.cancel()
    }
}
