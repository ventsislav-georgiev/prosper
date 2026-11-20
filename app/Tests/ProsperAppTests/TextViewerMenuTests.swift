import AppKit
import XCTest
@testable import ProsperApp

/// #1726: the Text Viewer's File / View / Find menus and the app's Window menu. Offscreen only: the menus are read as values
/// or as never-shown NSMenus, the main menu is a built NSMenu (NSApp.mainMenu is never read or set: the seam is nil under
/// XCTest), the window is built and never shown, ordered or made key, key events are built and handed to the pure route,
/// never posted, and the file is never read (the read seam answers missing).
@MainActor
final class TextViewerMenuTests: XCTestCase {
    private var revealed: [URL] = []
    private var opened: [URL] = []

    private func window(defaultApp: URL? = URL(fileURLWithPath: "/Applications/Example.app")) -> TextViewerNSWindow {
        let url = URL(fileURLWithPath: "/Users/example/Notes.md")
        let actions = TextViewerActions(defaultApp: { _ in defaultApp }, openWith: { [unowned self] u, _ in self.opened.append(u) },
                                        reveal: { [unowned self] in self.revealed.append($0) }, openURL: { _ in }, view: { _ in })
        let model = TextViewerModel(url: url, resolved: url, actions: actions, imageLoader: { _, _, _ in nil },
                                    read: { _ in .failure(.missing) })
        let win = TextViewerWindows.makeWindow(model, autosave: nil)
        retained = model
        return win
    }
    /// The window holds its model weakly (the registry owns it in the app).
    private var retained: TextViewerModel?

    private func event(_ e: TextViewerMenu.Entry) -> NSEvent? {
        let chars = e.mods.contains(.shift) ? e.key.uppercased() : e.key
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: e.mods, timestamp: 0, windowNumber: 0, context: nil,
                                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)
    }

    /// Every shown chord is what the window's route gives its item's action, and the keyed items are exactly the routes the
    /// window handles (no new chord, none left out); the titles literal.
    func testShownShortcutsAreTheHandledKeys() {
        typealias R = TextViewerNSWindow.KeyRoute
        var routes: [R] = []
        for kind in TextViewerMenu.Kind.allCases {
            for e in TextViewerMenu.entries(kind, openWith: "Example").compactMap({ $0 }) {
                guard case .key(let r) = e.action else {
                    XCTAssertTrue(e.key.isEmpty && e.mods.isEmpty, "\(e.title): no key, none shown")
                    continue
                }
                guard let ev = event(e) else { return XCTFail(e.title) }
                XCTAssertEqual(TextViewerNSWindow.route(ev), r, "\(e.title): the shown chord is the handled key")
                routes.append(r)
            }
        }
        XCTAssertEqual(routes, [.save, .close, .toggleMode, .find(.showFindInterface), .find(.nextMatch), .find(.previousMatch),
                                .useSelectionForFind], "every handled route once")
        XCTAssertEqual(TextViewerMenu.entries(.file, openWith: "Example").map { $0?.title },
                       ["Save", "Close", nil, "Reveal in Finder", "Open in Example"])
        XCTAssertEqual(TextViewerMenu.entries(.file, openWith: nil).compactMap { $0?.title }, ["Save", "Close", "Reveal in Finder"],
                       "no default app: no Open With item")
        XCTAssertEqual(TextViewerMenu.entries(.view, openWith: nil).compactMap { $0?.title }, ["Read or Edit"])
        XCTAssertEqual(TextViewerMenu.entries(.find, openWith: nil).compactMap { $0?.title },
                       ["Find\u{2026}", "Find Next", "Find Previous", "Use Selection for Find"])
    }

    /// Each built item targets its menu and runs the window's own perform; validation is the key's own condition; no item
    /// ever matches a key (the window's route keeps them). Close is checked as on, never picked (it would close the window).
    func testEachItemTargetsAnExistingActionAndMatchesNoKey() {
        let win = window()
        defer { win.close() }
        XCTAssertEqual(win.menus.map(\.kind), [.file, .view, .find])
        var titles: [String] = []
        for m in win.menus {
            guard let menu = m.item.submenu else { return XCTFail("a submenu") }
            XCTAssertEqual(menu.title, m.kind.rawValue)
            m.menuNeedsUpdate(menu)
            let items = menu.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(items.count, m.shown.count)
            for (item, entry) in zip(items, m.shown) {
                titles.append(item.title)
                XCTAssertTrue(item.target === m, item.title)
                XCTAssertEqual(item.action, #selector(TextViewerMenu.pick(_:)), item.title)
                XCTAssertTrue(m.responds(to: #selector(TextViewerMenu.pick(_:))))
                XCTAssertEqual(item.keyEquivalent, entry.key, item.title)
                XCTAssertEqual(item.keyEquivalentModifierMask, entry.mods, item.title)
                // not loaded, no text view: only Close, Reveal and Open With act
                let on = [TextViewerMenu.Action.key(.close), .reveal, .openWith].contains(entry.action)
                XCTAssertEqual(m.validateMenuItem(item), on, item.title)
                var target: AnyObject?, action: Selector?
                if let e = event(entry), !entry.key.isEmpty {
                    XCTAssertFalse(m.menuHasKeyEquivalent(menu, for: e, target: &target, action: &action), item.title)
                }
                if entry.action != .key(.close) { m.pick(item) }
            }
        }
        XCTAssertEqual(titles, ["Save", "Close", "Reveal in Finder", "Open in Example", "Read or Edit", "Find\u{2026}", "Find Next",
                                "Find Previous", "Use Selection for Find"])
        XCTAssertEqual(revealed.map(\.path), ["/Users/example/Notes.md"], "Reveal in Finder: the model's reveal, once")
        XCTAssertEqual(opened.map(\.path), ["/Users/example/Notes.md"], "Open in: the model's openInDefaultApp, once")
        XCTAssertTrue(win.isVisible == false, "never shown")
    }

    /// The key path through `perform`: a route that cannot act now answers false (super then gets the key), as before #1726.
    func testPerformAnswersFalseWhereTheKeyWentOn() {
        let win = window(defaultApp: nil)
        defer { win.close() }
        for r in [TextViewerNSWindow.KeyRoute.find(.showFindInterface), .find(.nextMatch), .useSelectionForFind, .toggleMode, .save, .pass] {
            XCTAssertFalse(win.perform(r), "\(r): no text view, not editable, not dirty")
            XCTAssertFalse(win.enabled(.key(r)), "\(r)")
        }
        XCTAssertTrue(win.enabled(.key(.close)))
        XCTAssertFalse(win.enabled(.openWith), "no default app")
    }

    /// File right after the app menu, View after Edit, Find after View, before the Window menu; once; all out on remove.
    func testMenusGoInTheStandardOrder() {
        XCTAssertTrue(AgentGoMenu.mainMenu() == nil, "under XCTest the app's main menu is never touched")
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
        XCTAssertEqual(titles(), ["Prosper", "File", "Edit", "View", "Find", "Window"])
        for m in win.menus { m.remove(from: main) }
        XCTAssertEqual(titles(), ["Prosper", "Edit", "Window"])
    }

    /// The app's Window menu: the standard items through the responder chain (nil target), no key equivalent added.
    func testWindowMenuIsTheStandardOneWithNoNewChord() {
        let menu = AppDelegate.makeWindowMenu()
        XCTAssertEqual(menu.title, "Window")
        XCTAssertEqual(menu.items.map(\.title), ["Minimize", "Zoom", "", "Bring All to Front"])
        XCTAssertEqual(menu.items.map(\.action), [#selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.performZoom(_:)), nil,
                                                  #selector(NSApplication.arrangeInFront(_:))])
        XCTAssertTrue(menu.items.allSatisfy { $0.target == nil && $0.keyEquivalent.isEmpty }, "first responder; no chord")
        XCTAssertTrue(NSWindow.instancesRespond(to: #selector(NSWindow.performMiniaturize(_:))))
        XCTAssertTrue(NSWindow.instancesRespond(to: #selector(NSWindow.performZoom(_:))))
        XCTAssertTrue(NSApplication.instancesRespond(to: #selector(NSApplication.arrangeInFront(_:))))
    }
}
