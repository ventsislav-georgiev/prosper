import XCTest
@testable import ProsperApp

/// Settings › Shortcuts › Extension Commands. Three contracts live entirely
/// outside Lua and none of them fail loudly on their own: what the pane offers to
/// bind, what survives a relaunch, and what stops registering when an extension is
/// turned off. A regression in any of them looks like a shortcut that is simply
/// missing or simply dead, so they are pinned here against the SHIPPED manifests
/// and a real registry.
final class ExtensionShortcutsTests: XCTestCase {

    /// …/app/Sources/ProsperApp/Resources/extensions
    private var extensionsDir: URL {
        URL(fileURLWithPath: #filePath)        // …/app/Tests/ProsperAppTests/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    /// A registry over COPIES of the named shipped extensions, so the fixture is
    /// the real thing (real manifests, real Lua) without loading all fifty.
    @MainActor
    private func makeRegistry(_ names: [String]) throws -> (ExtensionRegistry, URL) {
        let src = extensionsDir
        try XCTSkipIf(!FileManager.default.fileExists(atPath: src.path),
                      "in-repo extensions dir not found at \(src.path)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let system = root.appendingPathComponent("system")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(at: src.appendingPathComponent(name),
                                             to: system.appendingPathComponent(name))
        }
        let registry = ExtensionRegistry(
            systemDir: system, userDir: root.appendingPathComponent("user"),
            hostVersion: "2.0.0",
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        registry.discover()
        return (registry, root)
    }

    private func loadManifest(_ name: String) throws -> ExtensionManifest {
        let dir = extensionsDir.appendingPathComponent(name, isDirectory: true)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path),
                      "in-repo extensions dir not found at \(dir.path)")
        return try ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: "0.0.0").manifest
    }

    // MARK: - Which listings expand into bindable items

    /// `bindable_items` is opt-in on purpose: it promises the listed rows are
    /// stable, individually addressable targets. sysprefs (fixed panes) and
    /// scripts (user-named commands) qualify; killproc lists live processes,
    /// Bookmarks lists thousands of entries, and Snippets' row titles are the
    /// snippet BODIES — binding any of those hands the user a dead or unusable
    /// shortcut, so they must stay opted out even though they all list on empty.
    func testOnlyStableListingsOptIntoBindableItems() throws {
        for name in ["sysprefs", "scripts"] {
            let command = try XCTUnwrap(loadManifest(name).contributes?.allCommands
                .first { $0.bindableItems }, "\(name) should expand into bindable items")
            XCTAssertTrue(command.listsOnEmpty,
                          "bindable_items without list_on_empty has nothing to enumerate")
            XCTAssertFalse(command.allPrefixes.isEmpty,
                           "a bound item is fired as prefix + title — \(name) needs a prefix")
        }
        for name in ["killproc", "bookmarks", "snippets"] {
            XCTAssertFalse(
                try loadManifest(name).contributes?.allCommands.contains { $0.bindableItems } == true,
                "\(name) lists rows that are not stable binding targets")
        }
    }

    // MARK: - Enumeration

    /// The pane's whole offer, end to end against real extensions: the eight Quick
    /// Toggles arrive as parameterless commands (`runs_on_select`), and the System
    /// Settings panes arrive individually — enumerated by asking the extension for
    /// its own listing, not from a second table in the manifest.
    @MainActor
    func testBindableActionsCoverTogglesAndEverySystemSettingsPane() async throws {
        let (registry, root) = try makeRegistry(["toggles", "sysprefs"])
        defer { try? FileManager.default.removeItem(at: root) }

        let actions = await ExtensionShortcuts.bindableActions(registry: registry)
        let labels = Set(actions.map(\.label))

        XCTAssertTrue(labels.contains("Quick Toggles \u{203A} Toggle Dark Mode"), "\(labels)")
        XCTAssertTrue(labels.contains("Quick Toggles \u{203A} Empty Trash"), "\(labels)")
        XCTAssertEqual(actions.filter { $0.commandID.hasPrefix("toggles.") }.count, 8)
        XCTAssertTrue(actions.allSatisfy { $0.commandID.hasPrefix("toggles.") ? $0.item.isEmpty : true },
                      "a parameterless toggle must not carry an item argument")

        let panes = actions.filter { $0.commandID == "sysprefs.open" }
        XCTAssertGreaterThan(panes.count, 30, "the pane listing did not expand")
        XCTAssertTrue(labels.contains("System Settings \u{203A} Displays"), "\(labels)")
        XCTAssertTrue(labels.contains("System Settings \u{203A} Full Disk Access"), "\(labels)")
        // The argument is what makes the binding specific — without it every pane
        // shortcut would open whatever the listing happens to return first.
        XCTAssertEqual(panes.first { $0.label.hasSuffix("Displays") }?.item, "Displays")
        XCTAssertEqual(
            ExtensionShortcuts.query(commandID: "sysprefs.open", item: "Displays", registry: registry),
            "ss Displays")
        // A parameterless binding keeps the empty query the manifest keybindings
        // have always been invoked with.
        XCTAssertEqual(
            ExtensionShortcuts.query(commandID: "toggles.dark", item: "", registry: registry), "")
    }

    /// Disabling an extension has to take its actions out of the picker AND its
    /// hotkeys off the keyboard. The registration list is the input to
    /// `AppDelegate.registerHotKeys`, which re-runs from `onEnabledChanged`.
    @MainActor
    func testDisablingAnExtensionDropsItsActionsAndRegistrations() async throws {
        let (registry, root) = try makeRegistry(["toggles", "sysprefs", "openlid"])
        defer { try? FileManager.default.removeItem(at: root) }

        let bound = [ExtensionShortcut(commandID: "sysprefs.open", item: "Displays",
                                       combo: KeyCombo.parse("cmd+alt+ctrl+d")!,
                                       label: "System Settings \u{203A} Displays")]

        var actions = await ExtensionShortcuts.bindableActions(registry: registry)
        XCTAssertFalse(actions.filter { $0.commandID == "sysprefs.open" }.isEmpty)
        XCTAssertTrue(ExtensionShortcuts.registrations(
            registry: registry, overrides: [:], userShortcuts: bound)
            .contains { $0.commandID == "sysprefs.open" })
        // openlid's three manifest keybindings register while it is live.
        XCTAssertEqual(ExtensionShortcuts.registrations(
            registry: registry, overrides: [:], userShortcuts: [])
            .filter { $0.commandID.hasPrefix("openlid.") }.count, 3)

        try registry.setEnabled(false, id: "com.prosper.sysprefs")
        try registry.setEnabled(false, id: "com.prosper.openlid")

        actions = await ExtensionShortcuts.bindableActions(registry: registry)
        XCTAssertTrue(actions.filter { $0.commandID == "sysprefs.open" }.isEmpty,
                      "a disabled extension must not offer actions")
        XCTAssertTrue(ExtensionShortcuts.registrations(
            registry: registry, overrides: [:], userShortcuts: bound).isEmpty,
            "a disabled extension must claim no hotkey — neither its own nor a user binding to it")
    }

    /// Registration skips anything that would claim a bare key: an unrecorded
    /// binding and a user-cleared manifest default both land on `unsetKeyCombo`.
    @MainActor
    func testUnsetCombosNeverRegister() throws {
        let (registry, root) = try makeRegistry(["toggles", "openlid"])
        defer { try? FileManager.default.removeItem(at: root) }

        let unrecorded = [ExtensionShortcut(commandID: "toggles.dark", combo: unsetKeyCombo,
                                            label: "Quick Toggles \u{203A} Toggle Dark Mode")]
        XCTAssertTrue(ExtensionShortcuts.registrations(
            registry: registry, overrides: [:], userShortcuts: unrecorded)
            .filter { $0.commandID == "toggles.dark" }.isEmpty)

        XCTAssertTrue(ExtensionShortcuts.registrations(
            registry: registry, overrides: ["openlid.toggle": unsetKeyCombo], userShortcuts: [])
            .filter { $0.commandID == "openlid.toggle" }.isEmpty,
            "a cleared manifest default must stay cleared")
    }

    // MARK: - Persistence

    /// `ShortcutStore` writes to `UserDefaults.standard`, so save and restore both
    /// keys around the round-trip (same shape as `AppShortcutTests`).
    private func withCleanStore(_ body: () -> Void) {
        let keys = [ShortcutStore.extensionsKey, ShortcutStore.extensionKeybindingsKey]
        let saved = keys.map { UserDefaults.standard.data(forKey: $0) }
        defer {
            for (key, data) in zip(keys, saved) {
                if let data { UserDefaults.standard.set(data, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        body()
    }

    func testUserBindingsRoundTrip() {
        withCleanStore {
            XCTAssertEqual(ShortcutStore.extensionShortcuts(), [])
            let list = [
                ExtensionShortcut(commandID: "sysprefs.open", item: "Displays",
                                  combo: KeyCombo.parse("cmd+alt+ctrl+d")!,
                                  label: "System Settings \u{203A} Displays"),
                ExtensionShortcut(commandID: "toggles.dark", combo: KeyCombo.parse("cmd+alt+ctrl+n")!,
                                  label: "Quick Toggles \u{203A} Toggle Dark Mode"),
            ]
            ShortcutStore.setExtensionShortcuts(list)
            XCTAssertEqual(ShortcutStore.extensionShortcuts(), list,
                           "the stored ARGUMENT is what makes the binding specific")
        }
    }

    /// The manifest default is the fallback, never the winner: an override
    /// survives a relaunch and is what actually registers, and clearing one is a
    /// stored value of its own (removing the entry restores the default instead).
    @MainActor
    func testManifestKeybindingOverrideWinsAndSurvivesReload() throws {
        let (registry, root) = try makeRegistry(["openlid"])
        defer { try? FileManager.default.removeItem(at: root) }

        let declared = ExtensionShortcuts.manifestKeybindings(registry: registry)
        let toggle = try XCTUnwrap(declared.first { $0.commandID == "openlid.toggle" })
        XCTAssertEqual(toggle.label, "OpenLid \u{203A} \(toggle.commandTitle)")
        XCTAssertEqual(toggle.defaultCombo.chord, KeyCombo.parse("cmd+alt+ctrl+l")!.chord)

        withCleanStore {
            let mine = KeyCombo.parse("cmd+alt+ctrl+shift+o")!
            ShortcutStore.setExtensionKeybinding(mine, for: "openlid.toggle")

            // Reloaded from defaults, exactly as a relaunch would.
            let reloaded = ShortcutStore.extensionKeybindings()
            XCTAssertEqual(reloaded["openlid.toggle"]?.chord, mine.chord)

            let registered = ExtensionShortcuts.registrations(
                registry: registry, overrides: reloaded, userShortcuts: [])
            XCTAssertEqual(registered.first { $0.commandID == "openlid.toggle" }?.combo.chord,
                           mine.chord, "the manifest default beat the user's override")
            // The extension's other defaults are untouched by one override.
            XCTAssertEqual(registered.first { $0.commandID == "openlid.caffeine" }?.combo.chord,
                           KeyCombo.parse("cmd+alt+ctrl+k")!.chord)

            ShortcutStore.setExtensionKeybinding(nil, for: "openlid.toggle")
            XCTAssertNil(ShortcutStore.extensionKeybindings()["openlid.toggle"],
                         "restoring the default removes the override")
        }
    }

    // MARK: - Label dedupe

    /// pasteplain's extension title and its one command's title are both "Paste
    /// as Plain Text" — both label builders must collapse the doubled
    /// "X › X" down to a single "X" rather than showing the same words twice.
    @MainActor
    func testDoubledExtensionAndCommandTitleCollapsesToOne() async throws {
        let (registry, root) = try makeRegistry(["pasteplain"])
        defer { try? FileManager.default.removeItem(at: root) }

        let actions = await ExtensionShortcuts.bindableActions(registry: registry)
        let paste = try XCTUnwrap(actions.first { $0.commandID == "pasteplain.paste" })
        XCTAssertEqual(paste.label, "Paste as Plain Text")

        let declared = ExtensionShortcuts.manifestKeybindings(registry: registry)
        let kb = try XCTUnwrap(declared.first { $0.commandID == "pasteplain.paste" })
        XCTAssertEqual(kb.label, "Paste as Plain Text")
    }
}
