import AppKit
import XCTest
@testable import ProsperApp

/// #1113 point 2: a hotkey (or a custom shortcut's prefix) on an extension command that opens a window
/// (`launches_window`) follows WindowToggle's rule when the shared extension panel holds that same
/// extension's view; anything else fires as before. Offscreen: the panel's on-screen calls are a
/// recorder, the shown/focused read is stubbed, the Dock policy never changes, and the registry holds
/// copies of two shipped extensions: base64 (one window command) and quicklinks (a window command and
/// a plain one).
@MainActor
final class ExtensionWindowToggleTests: XCTestCase {

    private var shown = Set<ObjectIdentifier>()
    private var focused = Set<ObjectIdentifier>()

    /// Swaps the state read for the sets above, and the Dock policy's setter for a no-op, until teardown.
    private func stub() {
        nonisolated(unsafe) let live = WindowToggle.state
        WindowToggle.state = { [unowned self] w in
            (shown: self.shown.contains(ObjectIdentifier(w)), focused: self.focused.contains(ObjectIdentifier(w)))
        }
        // A closed panel window reports its hide to the Dock policy; the test process's policy stays put.
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

    private var extensionsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    /// Every row starts here: the stubs, then a registry over copies of the two extensions.
    private func makeRegistry() throws -> ExtensionRegistry {
        let src = extensionsDir
        try XCTSkipIf(!FileManager.default.fileExists(atPath: src.path), "no in-repo extensions dir")
        stub()
        let root = tempDir()
        let system = root.appendingPathComponent("system")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        for name in ["base64", "quicklinks"] {
            try FileManager.default.copyItem(at: src.appendingPathComponent(name),
                                             to: system.appendingPathComponent(name))
        }
        let registry = ExtensionRegistry(systemDir: system, userDir: root.appendingPathComponent("user"),
                                         hostVersion: "2.0.0", defaults: scratchDefaults("test"))
        registry.discover()
        return registry
    }

    private let base64 = "com.prosper.base64", quicklinks = "com.prosper.quicklinks"

    /// The panel with `owner`'s view in it, never on screen; `shows` counts its on-screen calls.
    private var shows = 0
    private func panel(owner: String) -> ExtensionViewPanel {
        let panel = ExtensionViewPanel()
        panel.onScreen = { [unowned self] _ in self.shows += 1 }
        panel.present(owner: owner, node: .spinner("View"), onAction: { _, _, _ in nil })
        let win = panel.window
        addTeardownBlock { @MainActor in
            win?.close()
            win?.contentViewController = nil
        }
        return panel
    }

    /// The close observer runs on the main queue; let it.
    private func drainMain() {
        let e = expectation(description: "main queue")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    private func press(_ commandID: String, _ registry: ExtensionRegistry, _ panel: ExtensionViewPanel) -> Int {
        var fired = 0
        ExtensionShortcuts.toggleWindow(commandID: commandID, registry: registry, panel: panel) { fired += 1 }
        return fired
    }

    // MARK: - Rows

    func testWindowCommandTogglesItsOwnWindow() throws {
        let registry = try makeRegistry()
        let p = panel(owner: base64)
        XCTAssertEqual(p.owner, base64)
        XCTAssertEqual(shows, 1, "present puts it on screen through the seam")

        set(p.window, shown: true, focused: false)
        XCTAssertEqual(press("base64.open", registry, p), 0, "shown, not focused: no fire (the view is kept)")
        XCTAssertEqual(shows, 2, "it comes back in front")
        XCTAssertEqual(p.owner, base64)

        set(p.window, shown: true, focused: true)
        XCTAssertEqual(press("base64.open", registry, p), 0, "focused: no fire")
        XCTAssertEqual(shows, 2, "and no refocus")
        drainMain()
        XCTAssertNil(p.owner, "focused: the press closed it")

        set(p.window, shown: false, focused: false)
        XCTAssertEqual(press("base64.open", registry, p), 1, "closed: the press fires (the handler opens it)")
        XCTAssertFalse(p.window?.isVisible ?? true, "never on screen")
    }

    func testAnotherExtensionsViewIsReplacedNeverClosed() throws {
        let registry = try makeRegistry()
        let p = panel(owner: base64)
        p.present(owner: quicklinks, node: .spinner("Add"), onAction: { _, _, _ in nil })
        XCTAssertEqual(p.owner, quicklinks, "the latest view's extension owns the panel")

        set(p.window, shown: true, focused: true)
        XCTAssertEqual(press("base64.open", registry, p), 1, "another extension's view, focused: fires (replaces)")
        set(p.window, shown: true, focused: false)
        XCTAssertEqual(press("base64.open", registry, p), 1, "not focused: fires too, never a focus")
        XCTAssertEqual(shows, 2, "only the two presents")
        drainMain()
        XCTAssertEqual(p.owner, quicklinks, "never closed")
    }

    func testPlainCommandFiresEvenWhenItsExtensionOwnsThePanel() throws {
        let registry = try makeRegistry()
        XCTAssertEqual(registry.command(id: "quicklinks.run")?.command.launchesWindow, false)
        XCTAssertEqual(registry.command(id: "quicklinks.add")?.command.launchesWindow, true)
        let p = panel(owner: quicklinks)
        set(p.window, shown: true, focused: true)
        XCTAssertEqual(press("quicklinks.run", registry, p), 1, "not a window command: fires as before")
        XCTAssertEqual(press("no.such.command", registry, p), 1, "an unknown command fires (and finds nothing)")
        drainMain()
        XCTAssertEqual(p.owner, quicklinks, "never closed")
        XCTAssertEqual(press("quicklinks.add", registry, p), 0, "its window command toggles: closes")
    }

    /// host.window.close (a form submitted): the owner goes with the window, so a later press fires
    /// and never brings back a stale window, even if the read still called it shown.
    func testOwnerClearsWhenThePanelCloses() throws {
        let registry = try makeRegistry()
        let p = panel(owner: base64)
        p.close()
        drainMain()
        XCTAssertNil(p.owner, "closed: no owner")

        set(p.window, shown: true, focused: false)
        XCTAssertEqual(press("quicklinks.add", registry, p), 1, "another extension's hotkey fires")
        XCTAssertEqual(press("base64.open", registry, p), 1, "the closed view's own hotkey fires too")
        XCTAssertEqual(shows, 1, "no stale window focused")
    }

    /// The window's own close button ends in NSWindow.close: no owner is left behind.
    func testCloseButtonLeavesNoOwner() throws {
        let registry = try makeRegistry()
        let p = panel(owner: base64)
        p.window?.close()
        drainMain()
        XCTAssertNil(p.owner, "closed by the window itself: no owner")
        set(p.window, shown: true, focused: false)
        XCTAssertEqual(press("base64.open", registry, p), 1, "the next press fires")
        XCTAssertEqual(shows, 1)
    }
}
