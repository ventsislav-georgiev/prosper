import AppKit
import XCTest
@testable import ProsperApp

/// #1123: an extension window shortcut toggles only the view it opened itself: same extension, same command
/// and the same text its handler got, compared whole. Another text or another command of that extension opens
/// its own view. Offscreen like the 1113 rows (ExtensionWindowToggleTests): the panel's on-screen calls are a
/// recorder, the shown/focused read is stubbed, the Dock policy never changes, no handler runs (a press's fire
/// is a counter, and the handler's host.window.open is played by a present on the main actor afterwards).
@MainActor
final class ExtensionWindowIdentityTests: XCTestCase {

    private var shown = Set<ObjectIdentifier>()
    private var focused = Set<ObjectIdentifier>()
    private var shows = 0

    private let quicklinks = "com.prosper.quicklinks", base64 = "com.prosper.base64", twowin = "com.example.twowin"

    private func stub() {
        nonisolated(unsafe) let live = WindowToggle.state
        WindowToggle.state = { [unowned self] w in
            (shown: self.shown.contains(ObjectIdentifier(w)), focused: self.focused.contains(ObjectIdentifier(w)))
        }
        DockPolicy.resetForTesting(setPolicy: { _ in })
        addTeardownBlock { @MainActor in
            WindowToggle.state = live
            DockPolicy.resetForTesting()
        }
    }

    private func set(_ w: NSWindow?, shown s: Bool, focused f: Bool) {
        guard let w else { return XCTFail("no window") }
        if s { shown.insert(ObjectIdentifier(w)) } else { shown.remove(ObjectIdentifier(w)) }
        if f { focused.insert(ObjectIdentifier(w)) } else { focused.remove(ObjectIdentifier(w)) }
    }

    private static let twowinManifest = """
        [extension]
        id          = "com.example.twowin"
        name        = "twowin"
        title       = "Two Windows"
        description = "Two window commands."
        version     = "1.0.0"
        author      = "example"
        license     = "MIT"
        system      = true

        [extension.host]
        min_version = "2.0.0"
        api_level   = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.commands]]
        id              = "twowin.a"
        title           = "Window A"
        description     = "Open window A"
        mode            = "no-view"
        match           = "^tw a( |$)"
        prefix          = "tw a "
        launches_window = true

        [[contributes.commands]]
        id              = "twowin.b"
        title           = "Window B"
        description     = "Open window B"
        mode            = "no-view"
        match           = "^tw b( |$)"
        launches_window = true
        """

    /// Copies of the shipped base64 and quicklinks extensions plus a fake one with two window commands.
    private func makeRegistry() throws -> ExtensionRegistry {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: src.path), "no in-repo extensions dir")
        stub()
        let root = tempDir()
        let system = root.appendingPathComponent("system")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        for name in ["base64", "quicklinks"] {
            try FileManager.default.copyItem(at: src.appendingPathComponent(name),
                                             to: system.appendingPathComponent(name))
        }
        let fake = system.appendingPathComponent("twowin")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try Self.twowinManifest.write(to: fake.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- never run\n".write(to: fake.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let registry = ExtensionRegistry(systemDir: system, userDir: root.appendingPathComponent("user"),
                                         hostVersion: "2.0.0", defaults: scratchDefaults("test"))
        registry.discover()
        XCTAssertEqual(registry.command(id: "twowin.a")?.command.launchesWindow, true, "fake extension loaded")
        XCTAssertEqual(registry.command(id: "twowin.b")?.command.launchesWindow, true)
        return registry
    }

    /// An empty panel whose on-screen calls are counted in `shows`.
    private func makePanel() -> ExtensionViewPanel {
        let panel = ExtensionViewPanel()
        panel.onScreen = { [unowned self] _ in self.shows += 1 }
        addTeardownBlock { @MainActor in
            panel.window?.close()
            panel.window?.contentViewController = nil
        }
        return panel
    }

    /// What the handler's host.window.open does once a press fired: the view goes in under its extension.
    private func handlerPresents(_ ext: String, _ panel: ExtensionViewPanel) {
        panel.present(owner: ext, node: .spinner("View"), onAction: { _, _, _ in nil })
    }

    /// One press through toggleWindow; the count of fires (1: it opens its own view, 0: focus or close).
    private func press(_ commandID: String, _ text: String, _ registry: ExtensionRegistry,
                       _ panel: ExtensionViewPanel) -> Int {
        var fired = 0
        ExtensionShortcuts.toggleWindow(commandID: commandID, text: text, registry: registry, panel: panel) { fired += 1 }
        return fired
    }

    private func drainMain() {
        let e = expectation(description: "main queue")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    private func ident(_ ext: String, _ cmd: String, _ text: String) -> ExtensionViewPanel.Identity {
        ExtensionViewPanel.Identity(extensionID: ext, commandID: cmd, text: text)
    }

    // MARK: - The rule

    func testSameCommandAndTextNotKeyFocuses() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        XCTAssertEqual(press("quicklinks.add", "ql add GitHub", registry, p), 1, "nothing up: it fires")
        handlerPresents(quicklinks, p)
        XCTAssertTrue(p.identity == ident(quicklinks, "quicklinks.add", "ql add GitHub"))
        XCTAssertEqual(shows, 1)

        set(p.window, shown: true, focused: false)
        XCTAssertEqual(press("quicklinks.add", "ql add GitHub", registry, p), 0, "same identity, not key: no fire")
        XCTAssertEqual(shows, 2, "it comes back in front with its view")
        XCTAssertTrue(p.identity == ident(quicklinks, "quicklinks.add", "ql add GitHub"))
    }

    func testSameCommandAndTextKeyCloses() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        _ = press("quicklinks.add", "ql add GitHub", registry, p)
        handlerPresents(quicklinks, p)
        set(p.window, shown: true, focused: true)
        XCTAssertEqual(press("quicklinks.add", "ql add GitHub", registry, p), 0, "same identity, key: no fire")
        XCTAssertEqual(shows, 1, "no refocus")
        drainMain()
        XCTAssertTrue(p.owner == nil, "the press closed it")
        XCTAssertTrue(p.identity == nil)
    }

    func testSameCommandOtherTextOpensItsOwn() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        _ = press("quicklinks.add", "ql add GitHub", registry, p)
        handlerPresents(quicklinks, p)
        for f in [false, true] {
            set(p.window, shown: true, focused: f)
            XCTAssertEqual(press("quicklinks.add", "ql add Jira", registry, p), 1, "other text, focused \(f): fires")
        }
        // Compared whole: a text that only extends the first one is another identity too.
        XCTAssertEqual(press("quicklinks.add", "ql add GitHub Enterprise", registry, p), 1)
        XCTAssertEqual(shows, 1, "never the GitHub view focused")
        drainMain()
        XCTAssertEqual(p.owner, quicklinks, "never closed")
        handlerPresents(quicklinks, p)
        XCTAssertTrue(p.identity == ident(quicklinks, "quicklinks.add", "ql add GitHub Enterprise"),
                      "the view now holds the last press's identity")
        set(p.window, shown: true, focused: true)
        XCTAssertEqual(press("quicklinks.add", "ql add GitHub", registry, p), 1, "the first shortcut opens its own again")
    }

    func testOtherCommandOfTheSameExtensionOpensItsOwn() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        _ = press("twowin.a", "", registry, p)
        handlerPresents(twowin, p)
        XCTAssertTrue(p.identity == ident(twowin, "twowin.a", ""))
        for f in [false, true] {
            set(p.window, shown: true, focused: f)
            XCTAssertEqual(press("twowin.b", "", registry, p), 1, "same extension and text, other command, focused \(f): fires")
        }
        XCTAssertEqual(shows, 1)
        drainMain()
        XCTAssertEqual(p.owner, twowin, "never closed")
        handlerPresents(twowin, p)
        XCTAssertTrue(p.identity == ident(twowin, "twowin.b", ""))
        XCTAssertEqual(press("twowin.b", "", registry, p), 0, "its own view, focused: closes")
    }

    /// Kept from 1113: the owner, and now the identity, go with every close; the next press fires. A fresh
    /// panel per close: a window that never went on screen posts willClose on its first close only.
    func testOwnerAndIdentityClearOnEveryClose() throws {
        let registry = try makeRegistry()
        let closes: [(String, (ExtensionViewPanel) -> Void)] = [
            ("panel.close (host.window.close)", { $0.close() }),
            ("the window's own close", { $0.window?.close() }),
            ("the toggle's close", { [unowned self] p in
                self.set(p.window, shown: true, focused: true)
                XCTAssertEqual(self.press("quicklinks.add", "ql add GitHub", registry, p), 0)
            }),
        ]
        for (name, close) in closes {
            let p = makePanel()
            _ = press("quicklinks.add", "ql add GitHub", registry, p)
            handlerPresents(quicklinks, p)
            XCTAssertTrue(p.identity != nil, name)
            close(p)
            drainMain()
            XCTAssertTrue(p.owner == nil, "\(name): no owner")
            XCTAssertTrue(p.identity == nil, "\(name): no identity")
            set(p.window, shown: true, focused: false)
            let before = shows
            XCTAssertEqual(press("quicklinks.add", "ql add GitHub", registry, p), 1, "\(name): the next press fires")
            XCTAssertEqual(shows, before, "\(name): no stale window focused")
        }
    }

    /// The panel's own bookkeeping: a re-present by the same extension keeps the press's identity (a form that
    /// opens its next step), another extension's view or a view after a close gets none, and a pending identity
    /// lasts one present only.
    func testRePresentKeepsIdentityOnlyForTheSameExtension() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        _ = press("quicklinks.add", "ql add GitHub", registry, p)
        handlerPresents(quicklinks, p)
        handlerPresents(quicklinks, p)
        XCTAssertTrue(p.identity == ident(quicklinks, "quicklinks.add", "ql add GitHub"), "same extension: kept")

        _ = press("quicklinks.add", "ql add Jira", registry, p)
        handlerPresents(base64, p)
        XCTAssertEqual(p.owner, base64)
        XCTAssertTrue(p.identity == nil, "another extension presented: no identity")
        XCTAssertTrue(p.pending == nil, "the pending press is dropped by that present")
        handlerPresents(quicklinks, p)
        XCTAssertTrue(p.identity == nil, "not taken by a later present")
    }

    // MARK: - The AppDelegate hookups

    /// The extension hotkey block: its text is the query `fire` hands the handler (prefix + item).
    func testHotkeyHookupPassesTheHandlersQuery() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        var fired = 0
        AppDelegate.extensionHotkeyPressed(commandID: "twowin.a", item: "one", registry: registry, panel: p) { _ in fired += 1 }
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(p.pending == ident(twowin, "twowin.a", "tw a one"), "the text as the handler gets it")
        handlerPresents(twowin, p)

        set(p.window, shown: true, focused: true)
        AppDelegate.extensionHotkeyPressed(commandID: "twowin.a", item: "two", registry: registry, panel: p) { _ in fired += 1 }
        XCTAssertEqual(fired, 2, "another item on the same command opens its own")
        p.pending = nil
        AppDelegate.extensionHotkeyPressed(commandID: "twowin.a", item: "one", registry: registry, panel: p) { _ in fired += 1 }
        XCTAssertEqual(fired, 2, "the same item, key: closes")
        drainMain()
        XCTAssertTrue(p.owner == nil)
    }

    /// openRunner's launches_window branch: the custom shortcut's prefill, whole, is the text.
    func testCustomShortcutHookupPassesThePrefill() throws {
        let registry = try makeRegistry()
        XCTAssertEqual(registry.route(query: "ql add GitHub")?.command.id, "quicklinks.add")
        let p = makePanel()
        var invoked: [String] = []
        func shortcut(_ prefill: String) -> Bool {
            AppDelegate.openWindowCommand(prefill: prefill, registry: registry, panel: p) { id, _ in invoked.append(id) }
        }
        XCTAssertFalse(shortcut("ql gh"), "not a window command: the runner's path")
        XCTAssertEqual(invoked, [])

        XCTAssertTrue(shortcut("ql add GitHub"))
        XCTAssertEqual(invoked, ["quicklinks.add"])
        XCTAssertTrue(p.pending == ident(quicklinks, "quicklinks.add", "ql add GitHub"))
        handlerPresents(quicklinks, p)

        set(p.window, shown: true, focused: false)
        XCTAssertTrue(shortcut("ql add Jira"))
        XCTAssertEqual(invoked, ["quicklinks.add", "quicklinks.add"], "other text: opens its own")
        p.pending = nil
        XCTAssertTrue(shortcut("ql add GitHub"))
        XCTAssertEqual(invoked.count, 2, "same prefill, not key: focus, no invoke")
        XCTAssertEqual(shows, 2)
    }

    /// The presenter: the view goes in under its extension and takes the identity the press left pending.
    func testPresenterHookupTakesThePendingIdentity() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        _ = press("quicklinks.add", "ql add GitHub", registry, p)
        AppDelegate.presentExtensionView(extID: quicklinks, node: .spinner("Add"), registry: registry, panel: p)
        XCTAssertEqual(p.owner, quicklinks)
        XCTAssertTrue(p.identity == ident(quicklinks, "quicklinks.add", "ql add GitHub"))
        XCTAssertTrue(p.pending == nil)
        XCTAssertEqual(shows, 1, "on screen through the seam only")

        AppDelegate.presentExtensionView(extID: base64, node: .spinner("Base64"), registry: registry, panel: p)
        XCTAssertEqual(p.owner, base64)
        XCTAssertTrue(p.identity == nil, "presented by no press")
        XCTAssertFalse(p.window?.isVisible ?? true, "never on screen")
    }

    // MARK: - A press that ends (round 2)

    /// The handler presented nothing (an error, it declined, its budget ran out): once its invoke has ended nothing
    /// is left pending, and a view the extension opens later by itself is named after no press.
    func testPressThatOpenedNothingLeavesNothingPending() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        var pressed: ExtensionViewPanel.Identity?
        AppDelegate.extensionHotkeyPressed(commandID: "twowin.a", item: "one", registry: registry, panel: p) { pressed = $0 }
        XCTAssertTrue(pressed == ident(twowin, "twowin.a", "tw a one"), "the fire gets the press's identity")
        XCTAssertTrue(p.pending == pressed)
        p.pressEnded(pressed)
        XCTAssertTrue(p.pending == nil, "the invoke ended with no present: nothing left pending")
        handlerPresents(twowin, p)
        XCTAssertEqual(p.owner, twowin)
        XCTAssertTrue(p.identity == nil, "opened by the extension itself: named after no press")
    }

    /// An earlier press whose invoke ends after a later press left its own pending does not clear the later one;
    /// a press on a command that opens no window stands for nothing and its end clears nothing.
    func testEarlierPressEndingKeepsALaterPressesPending() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        var first: ExtensionViewPanel.Identity?, second: ExtensionViewPanel.Identity?
        let firstFired = AppDelegate.openWindowCommand(prefill: "ql add GitHub", registry: registry, panel: p) { first = $1 }
        let secondFired = AppDelegate.openWindowCommand(prefill: "ql add Jira", registry: registry, panel: p) { second = $1 }
        XCTAssertTrue(firstFired && secondFired)
        XCTAssertTrue(first == ident(quicklinks, "quicklinks.add", "ql add GitHub"))
        XCTAssertTrue(second == ident(quicklinks, "quicklinks.add", "ql add Jira"))
        XCTAssertTrue(p.pending == second)
        p.pressEnded(first)
        XCTAssertTrue(p.pending == second, "the first press ending leaves the second press's pending")

        var plain: ExtensionViewPanel.Identity? = ident(base64, "base64.open", "")
        AppDelegate.extensionHotkeyPressed(commandID: "quicklinks.run", item: "gh", registry: registry, panel: p) { plain = $0 }
        XCTAssertTrue(plain == nil, "not a window command: no identity")
        p.pressEnded(plain)
        XCTAssertTrue(p.pending == second)

        handlerPresents(quicklinks, p)
        XCTAssertTrue(p.identity == second, "the second press's handler presents: its view")
    }

    /// A press whose handler presented during its invoke: the end of the invoke leaves the view's identity, and
    /// the same shortcut still toggles that view.
    func testPressWhoseHandlerPresentedKeepsItsIdentityWhenItEnds() throws {
        let registry = try makeRegistry()
        let p = makePanel()
        var pressed: ExtensionViewPanel.Identity?
        AppDelegate.extensionHotkeyPressed(commandID: "twowin.a", item: "one", registry: registry, panel: p) { pressed = $0 }
        handlerPresents(twowin, p)
        p.pressEnded(pressed)
        XCTAssertTrue(p.identity == ident(twowin, "twowin.a", "tw a one"))
        XCTAssertTrue(p.pending == nil)
        set(p.window, shown: true, focused: false)
        var fired = 0
        AppDelegate.extensionHotkeyPressed(commandID: "twowin.a", item: "one", registry: registry, panel: p) { _ in fired += 1 }
        XCTAssertEqual(fired, 0, "its own view, not key: focus, no fire")
        XCTAssertEqual(shows, 2)
    }
}
