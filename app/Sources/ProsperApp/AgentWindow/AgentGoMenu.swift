import AppKit

/// #1359: the main menu's "Go" menu, put right after Edit while the Agent Sessions window is key, so its keyboard
/// shortcuts can be found. Each item runs the window's own `perform` (the function its key runs). The items only show
/// their shortcuts: `menuHasKeyEquivalent` answers false, so a key never matches here and stays the window's route
/// alone (no double fire; a key the route passes, Command-Up in a text view, keeps its text meaning).
@MainActor
final class AgentGoMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let title = "Go"

    enum Action: Equatable {
        case key(AgentsNSWindow.KeyRoute)
        case pane(PaneAction)
    }

    struct Entry: Equatable {
        let title: String
        let key: String
        let mods: NSEvent.ModifierFlags
        let action: Action
        init(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ action: Action) {
            (self.title, self.key, self.mods, self.action) = (title, key, mods, action)
        }
    }

    /// The menu as values: nil is a separator. Pane items only with the split gate on.
    static func entries(splits: Bool) -> [Entry?] {
        let c: NSEvent.ModifierFlags = .command, sc: NSEvent.ModifierFlags = [.command, .shift]
        let oc: NSEvent.ModifierFlags = [.command, .option]
        var e: [Entry?] = [
            Entry("Previous Session", "\u{F700}", c, .key(.session(-1))),
            Entry("Next Session", "\u{F701}", c, .key(.session(1))),
        ]
        e += (1...9).map { Entry("Jump to Session \($0)", "\($0)", c, .key(.jump($0))) }
        e += [
            nil,
            Entry("Terminal or Transcript", "t", c, .key(.toggleMode)),
            Entry("Jump to Chapter\u{2026}", "l", c, .key(.chapters)),
            Entry("Focused Transcript", "1", oc, .key(.verbosity(.focused))),
            Entry("Default Transcript", "2", oc, .key(.verbosity(.default))),
            Entry("Verbose Transcript", "3", oc, .key(.verbosity(.verbose))),
            nil,
            Entry("Find\u{2026}", "f", c, .key(.find)),
            Entry("Find Next", "g", c, .key(.findNext(true))),
            Entry("Find Previous", "g", sc, .key(.findNext(false))),
            Entry("Bigger Text", "=", c, .key(.font(1))),
            Entry("Smaller Text", "-", c, .key(.font(-1))),
            Entry("Actual Size", "0", c, .key(.font(0))),
            nil,
            Entry("New Session", "n", c, .key(.newSession)),
            Entry("New Shell", "n", sc, .key(.newShell)),
            Entry("Stop or Remove", "\u{8}", c, .key(.stopOrRemove)),
            Entry("Close Window", "w", c, .key(.close)),
        ]
        guard splits else { return e }
        return e + [
            nil,
            Entry("Next Needs You", "j", c, .pane(.nextNeedsYou)),
            Entry("Toggle Sidebar", "s", [.control, .command], .pane(.toggleSidebar)),
            Entry("Split Right", "d", c, .pane(.split(.columns))),
            Entry("Split Down", "d", sc, .pane(.split(.rows))),
            Entry("Next Pane", "]", c, .pane(.cycle(1))),
            Entry("Previous Pane", "[", c, .pane(.cycle(-1))),
            Entry("Zoom Pane", "\r", sc, .pane(.zoom)),
        ]
    }

    /// The main menu, read only outside XCTest (as `AgentsNSWindow.inputSourceID`): no row ever changes the app's.
    static var mainMenu: @MainActor () -> NSMenu? = { NSClassFromString("XCTestCase") == nil ? NSApp.mainMenu : nil }

    /// Right after the menu titled Edit; no Edit: last.
    static func insertionIndex(_ titles: [String]) -> Int {
        titles.firstIndex(of: "Edit").map { $0 + 1 } ?? titles.count
    }

    weak var window: AgentsNSWindow?
    let item = NSMenuItem(title: AgentGoMenu.title, action: nil, keyEquivalent: "")
    /// The entries behind the built items, by tag.
    private(set) var shown: [Entry] = []

    init(window: AgentsNSWindow) {
        self.window = window
        super.init()
        let menu = NSMenu(title: Self.title)
        menu.delegate = self
        item.submenu = menu
    }

    func install(in main: NSMenu?) {
        guard let main, main.index(of: item) < 0 else { return }
        main.insertItem(item, at: Self.insertionIndex(main.items.map { $0.submenu?.title ?? $0.title }))
    }

    func remove(from main: NSMenu?) {
        guard let main, main.index(of: item) >= 0 else { return }
        main.removeItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let list = Self.entries(splits: AgentPaneLayout.splitsEnabled)
        shown = list.compactMap { $0 }
        var tag = 0
        menu.items = list.map { e in
            guard let e else { return .separator() }
            let i = NSMenuItem(title: e.title, action: #selector(pick(_:)), keyEquivalent: e.key)
            i.keyEquivalentModifierMask = e.mods
            i.target = self
            i.tag = tag
            tag += 1
            return i
        }
    }

    /// The window's route keeps every key: the items only show theirs.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool { false }

    @objc func pick(_ sender: NSMenuItem) {
        guard shown.indices.contains(sender.tag), let window else { return }
        switch shown[sender.tag].action {
        case .key(let r): window.perform(r)
        case .pane(let a): window.perform(pane: a)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard shown.indices.contains(menuItem.tag), let window else { return false }
        return window.enabled(shown[menuItem.tag].action)
    }
}

extension AgentsNSWindow {
    /// #1359: a Go menu item is on when its key would act now: the route itself decides (a click is not typing, so the
    /// responder reads as .other). Pane items: the split gate on, no rename field, no New session form.
    func enabled(_ a: AgentGoMenu.Action) -> Bool {
        guard let model else { return false }
        let renaming = model.renaming != nil || model.layoutRenaming != nil, form = model.newSession != nil
        switch a {
        case .pane: return AgentPaneLayout.splitsEnabled && !renaming && !form
        case .key(let r):
            guard let c = Self.keyTable.first(where: { $0.route == r }), let e = Self.keyEvent(c.key, c.mods, c.keyCode) else {
                return false
            }
            return Self.route(e, responder: .other, sidebarFocused: sidebarFocused, terminalMode: model.paneMode == .terminal,
                              renaming: renaming, form: form) == r
        }
    }
}
