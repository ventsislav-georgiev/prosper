import AppKit

/// #1726: the Text Viewer's File, View and Find menus, in the main menu while its window is key (as AgentGoMenu for
/// Agent Sessions). Each item runs the window's own `perform` (what its key runs) or the header's Open With item; the items
/// only show their shortcuts: `menuHasKeyEquivalent` answers false, so a key stays the window's route alone.
@MainActor
final class TextViewerMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    enum Kind: String, CaseIterable {
        case file = "File", view = "View", find = "Find"
        /// As AgentGoMenu.Kind.after: File right after the app menu, View after Edit, Find after View.
        var after: [String]? {
            switch self {
            case .file: nil
            case .view: ["Edit"]
            case .find: ["Edit", "View"]
            }
        }
    }

    enum Action: Equatable { case key(TextViewerNSWindow.KeyRoute), reveal, openWith }

    typealias Entry = (title: String, key: String, mods: NSEvent.ModifierFlags, action: Action)

    /// The menu as values: nil is a separator. `openWith` is the default app's name (the header's Open With item), nil: none.
    static func entries(_ kind: Kind, openWith: String?) -> [Entry?] {
        let c: NSEvent.ModifierFlags = .command
        switch kind {
        case .file:
            var e: [Entry?] = [("Save", "s", c, .key(.save)), ("Close", "w", c, .key(.close)), nil,
                               ("Reveal in Finder", "", [], .reveal)]
            if let openWith { e.append(("Open in \(openWith)", "", [], .openWith)) }
            return e
        case .view:
            return [("Read or Edit", "t", c, .key(.toggleMode))]
        case .find:
            return [("Find\u{2026}", "f", c, .key(.find(.showFindInterface))), ("Find Next", "g", c, .key(.find(.nextMatch))),
                    ("Find Previous", "g", [.command, .shift], .key(.find(.previousMatch))),
                    ("Use Selection for Find", "e", c, .key(.useSelectionForFind))]
        }
    }

    weak var window: TextViewerNSWindow?
    let kind: Kind
    let item: NSMenuItem
    /// The entries behind the built items, by tag.
    private(set) var shown: [Entry] = []

    init(window: TextViewerNSWindow, kind: Kind) {
        self.window = window
        self.kind = kind
        item = NSMenuItem(title: kind.rawValue, action: nil, keyEquivalent: "")
        super.init()
        let menu = NSMenu(title: kind.rawValue)
        menu.delegate = self
        item.submenu = menu
    }

    func install(in main: NSMenu?) {
        guard let main, main.index(of: item) < 0 else { return }
        main.insertItem(item, at: AgentGoMenu.insertionIndex(main.items.map { $0.submenu?.title ?? $0.title }, after: kind.after))
    }

    func remove(from main: NSMenu?) {
        guard let main, main.index(of: item) >= 0 else { return }
        main.removeItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = window?.model?.defaultApp.map { FileManager.default.displayName(atPath: $0.path) }
        let list = Self.entries(kind, openWith: app)
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
        window.perform(shown[sender.tag].action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard shown.indices.contains(menuItem.tag), let window else { return false }
        return window.enabled(shown[menuItem.tag].action)
    }
}
