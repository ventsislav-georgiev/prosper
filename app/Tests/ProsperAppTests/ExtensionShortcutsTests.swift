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
        // killproc/bookmarks list rows that are not stable binding targets (a live
        // process, an arbitrary bookmark) — no manifest opt-in, no other source either.
        for name in ["killproc", "bookmarks"] {
            XCTAssertFalse(
                try loadManifest(name).contributes?.allCommands.contains { $0.bindableItems } == true,
                "\(name) lists rows that are not stable binding targets")
        }
        // quicklinks/quickdirs/snippets also skip the manifest flag — enumerating
        // them through the generic Lua-listing path would mean firing a live query
        // (and, for quickdirs, walking the filesystem) just to recover names
        // ExtensionShortcuts already has from QuicklinkStore/QuickdirStore/
        // SnippetStore directly. They opt in instead through ExtensionShortcuts'
        // native source (see ExtensionShortcutsNativeSourceTests below) — so unlike
        // killproc/bookmarks, which stay fully excluded, snippets (and quicklinks/
        // quickdirs) move from "excluded" to "bound by name via the store", not to
        // "still excluded".
        for name in ["quicklinks", "quickdirs", "snippets"] {
            XCTAssertFalse(
                try loadManifest(name).contributes?.allCommands.contains { $0.bindableItems } == true,
                "\(name) is bound natively (store-backed), not via manifest bindable_items")
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
    /// as Plain Text" — the bindableActions label builder must collapse the
    /// doubled "X › X" down to a single "X" rather than showing the same words
    /// twice. Beta.6 QA also pulled pasteplain's default chord (it globally
    /// swallowed the native Paste-and-Match-Style chord many apps use, and the
    /// mode picker + Extension Commands already cover the day-to-day binding
    /// case), so this is also where that contract is pinned: pasteplain must
    /// declare NO manifest keybinding at all.
    @MainActor
    func testDoubledExtensionAndCommandTitleCollapsesToOne() async throws {
        let (registry, root) = try makeRegistry(["pasteplain"])
        defer { try? FileManager.default.removeItem(at: root) }

        let actions = await ExtensionShortcuts.bindableActions(registry: registry)
        let paste = try XCTUnwrap(actions.first { $0.commandID == "pasteplain.paste" })
        XCTAssertEqual(paste.label, "Paste as Plain Text")

        let declared = ExtensionShortcuts.manifestKeybindings(registry: registry)
        XCTAssertTrue(declared.isEmpty, "pasteplain must not ship a default keybinding")
    }

    // MARK: - Native bindable sources (quicklinks / quickdirs / snippets)

    // Key formulas mirror each store's own private UserDefaults key (see the doc
    // comments on QuicklinkStore/QuickdirStore/SnippetStore) — duplicated here
    // rather than exposed, so a test can seed/restore them directly.
    private let quicklinksLinksKey = "ext.com.prosper.quicklinks.links"
    private let quickdirsKey = "ext.com.prosper.quickdirs.dirs"
    private let snippetsItemsKey = "ext.com.prosper.snippets.items"

    /// Backs up + restores the raw `UserDefaults.standard` entries the three
    /// native stores read, and seeds them directly with the given maps/arrays.
    /// Deliberately bypasses `.save`/`.replaceAll` on those stores: those also
    /// mirror to `~/.config/prosper/*.json` on the real machine, which a test
    /// must never touch.
    @MainActor
    private func withCleanNativeStores(
        quicklinks: [String: String] = [:],
        quickdirs: [QuickdirConfig] = [],
        snippets: [SnippetStore.Entry] = [],
        _ body: () async throws -> Void
    ) async rethrows {
        let keys = [quicklinksLinksKey, quickdirsKey, snippetsItemsKey]
        let saved = keys.map { UserDefaults.standard.string(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        func json<T: Encodable>(_ value: T) -> String {
            String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "{}"
        }
        UserDefaults.standard.set(json(quicklinks), forKey: quicklinksLinksKey)
        UserDefaults.standard.set(json(quickdirs), forKey: quickdirsKey)
        UserDefaults.standard.set(json(snippets), forKey: snippetsItemsKey)
        try await body()
    }

    @MainActor
    func testBindableActionsIncludeOneRowPerQuicklinkQuickdirAndSnippet() async throws {
        let (registry, root) = try makeRegistry(
            ["toggles", "sysprefs", "quicklinks", "quickdirs", "snippets"])
        defer { try? FileManager.default.removeItem(at: root) }

        await withCleanNativeStores(
            quicklinks: ["gh": "https://github.com/{query}", "docs": "https://docs.example.com"],
            quickdirs: [
                QuickdirConfig(name: "projects", path: "~/projects", prefix: "p",
                               action: "open {path}", actionLabel: "Open"),
                // No prefix, and a path that doesn't exist — proves the row is bound
                // to the CONFIG NAME, not derived by listing its subdirectories.
                QuickdirConfig(name: "scratch", path: "~/__prosper_native_source_test__",
                               prefix: "", action: "open {path}", actionLabel: "Open"),
            ],
            snippets: [SnippetStore.Entry(name: "Sig", keyword: ";;sig", text: "Best regards",
                                          collection: nil, description: nil,
                                          autoExpand: nil, richText: nil)]
        ) {
            let actions = await ExtensionShortcuts.bindableActions(registry: registry)
            let labels = Set(actions.map(\.label))

            // Still there: every quick toggle and every sysprefs pane.
            XCTAssertEqual(actions.filter { $0.commandID.hasPrefix("toggles.") }.count, 8)
            XCTAssertGreaterThan(actions.filter { $0.commandID == "sysprefs.open" }.count, 30)

            // One row per saved quicklink.
            let quicklinkRows = actions.filter { $0.commandID == "quicklinks.run" }
            XCTAssertEqual(quicklinkRows.count, 2)
            XCTAssertTrue(labels.contains("Quicklinks \u{203A} gh"), "\(labels)")
            XCTAssertTrue(labels.contains("Quicklinks \u{203A} docs"), "\(labels)")

            // One row per saved quickdir, prefix or no prefix.
            let quickdirRows = actions.filter { $0.commandID == "quickdirs.run" }
            XCTAssertEqual(quickdirRows.count, 2)
            XCTAssertTrue(labels.contains("Quickdirs \u{203A} projects"), "\(labels)")
            XCTAssertTrue(labels.contains("Quickdirs \u{203A} scratch"), "\(labels)")

            // One row per saved snippet, bound by name.
            let snippetRows = actions.filter { $0.commandID == "snippets.run" }
            XCTAssertEqual(snippetRows.count, 1)
            XCTAssertTrue(labels.contains("Snippets \u{203A} Sig"), "\(labels)")
        }
    }

    @MainActor
    func testNativeQuicklinkShortcutRegistersOnceAndDropsWhenDisabled() async throws {
        let (registry, root) = try makeRegistry(["toggles", "quicklinks"])
        defer { try? FileManager.default.removeItem(at: root) }

        try await withCleanNativeStores(quicklinks: ["gh": "https://github.com/{query}"]) {
            let bound = [ExtensionShortcut(commandID: "quicklinks.run", item: "gh",
                                           combo: KeyCombo.parse("cmd+alt+ctrl+g")!,
                                           label: "Quicklinks \u{203A} gh")]

            // Exactly one registration — the id AppDelegate assigns it starts at
            // `GlobalHotKey.extensionIdBase` (300); `registrations` only needs to
            // hand back the one row for AppDelegate to place there.
            let registered = ExtensionShortcuts.registrations(
                registry: registry, overrides: [:], userShortcuts: bound)
            XCTAssertEqual(registered.filter { $0.commandID == "quicklinks.run" && $0.item == "gh" }.count, 1)

            try registry.setEnabled(false, id: "com.prosper.quicklinks")

            XCTAssertTrue(ExtensionShortcuts.registrations(
                registry: registry, overrides: [:], userShortcuts: bound).isEmpty,
                "a disabled extension must claim no hotkey for a bound quicklink")
            let actions = await ExtensionShortcuts.bindableActions(registry: registry)
            XCTAssertTrue(actions.filter { $0.commandID == "quicklinks.run" }.isEmpty,
                          "a disabled extension must not offer its quicklinks as bindable")
        }
    }

    @MainActor
    func testNativeFireActionForQuicklinkQuickdirAndSnippet() async throws {
        await withCleanNativeStores(
            quicklinks: ["gh": "https://github.com/{query}"],
            quickdirs: [QuickdirConfig(name: "projects", path: "~/projects", prefix: "",
                                       action: "open {path}", actionLabel: "Open")],
            snippets: [SnippetStore.Entry(name: "Sig", keyword: ";;sig", text: "Best regards",
                                          collection: nil, description: nil,
                                          autoExpand: nil, richText: nil)]
        ) {
            // Quicklink: resolves through the exact same two calls the runner's own
            // `openQuicklink` makes (`QuicklinkStore.resolve` + `RunnerPanel.quicklinkURL`)
            // — asserted directly on the pure function, no NSWorkspace involved.
            guard case .openURL(let url)? =
                ExtensionShortcuts.nativeFireAction(commandID: "quicklinks.run", item: "gh")
            else { return XCTFail("expected an openURL action") }
            let expected = RunnerPanel.quicklinkURL(
                QuicklinkStore.resolve(target: "https://github.com/{query}", query: ""))
            XCTAssertEqual(url, expected)

            // Quickdir: opens the runner pre-filled with the GENERIC "qd " prefix +
            // the config's own name — works even though this config has no prefix
            // of its own (CommandRouter resolves "qd <name>" by exact name/prefix
            // match regardless).
            XCTAssertEqual(
                ExtensionShortcuts.nativeFireAction(commandID: "quickdirs.run", item: "projects"),
                .openRunnerPrefill("qd projects"))

            // Snippet: bound by name, body inserted (not a manifest listing).
            XCTAssertEqual(
                ExtensionShortcuts.nativeFireAction(commandID: "snippets.run", item: "Sig"),
                .insertSnippet(name: "Sig"))

            // Unknown item name for any of the three → no action (nothing to fire).
            XCTAssertNil(ExtensionShortcuts.nativeFireAction(commandID: "quicklinks.run", item: "nope"))
            XCTAssertNil(ExtensionShortcuts.nativeFireAction(commandID: "quickdirs.run", item: "nope"))
            XCTAssertNil(ExtensionShortcuts.nativeFireAction(commandID: "snippets.run", item: "nope"))
        }
    }

    // MARK: - AssignableRunnerTarget (⌘⇧K row → store write, #117)

    /// A blank `ResultRow` fixture — only the fields a test sets are non-default.
    private func row(appURL: URL? = nil, quicklink: QuicklinkHit? = nil,
                      quickdirMenu: QuickdirConfig? = nil, secondary: String = "") -> ResultRow {
        ResultRow(id: 0, icon: "star", primary: "x", secondary: secondary, category: "",
                  copyValue: "", isMeta: false, appURL: appURL, quicklink: quicklink,
                  quickdirMenu: quickdirMenu)
    }

    @MainActor
    func testAssignableRunnerTargetFromRow() {
        let appURL = URL(fileURLWithPath: "/Applications/Safari.app")
        XCTAssertEqual(AssignableRunnerTarget.from(row: row(appURL: appURL), mode: .universal),
                        .app(appURL))

        let link = QuicklinkHit(name: "gh", target: "https://github.com/{query}", description: "")
        XCTAssertEqual(AssignableRunnerTarget.from(row: row(quicklink: link), mode: .universal),
                        .quicklink(name: "gh"))

        // Binds by the CONFIG (quickdirMenu), not a browsed hit (no `quickdir` field
        // set here) — matches how ExtensionShortcuts.nativeItemTitles binds quickdirs.
        let cfg = QuickdirConfig(name: "projects", path: "~/projects", prefix: "",
                                  action: "open {path}", actionLabel: "Open")
        XCTAssertEqual(AssignableRunnerTarget.from(row: row(quickdirMenu: cfg), mode: .universal),
                        .quickdir(name: "projects"))

        // Snippet: no dedicated ResultRow field — recovered from the subtitle, and
        // only while the runner is locked into the snippets.run extension mode.
        let snippetMode = RunnerMode.ext(id: "snippets.run", title: "Snippets", icon: "text.quote")
        XCTAssertEqual(
            AssignableRunnerTarget.from(row: row(secondary: "Sig  \u{00B7}  ;;sig"), mode: snippetMode),
            .snippet(name: "Sig"))
        XCTAssertEqual(
            AssignableRunnerTarget.from(row: row(secondary: "Sig"), mode: snippetMode),
            .snippet(name: "Sig"))

        // Same subtitle shape, but not in snippets mode → no target (a plain
        // universal-mode row never offers to bind, even if it happens to have text
        // in `secondary`).
        XCTAssertNil(AssignableRunnerTarget.from(row: row(secondary: "Sig"), mode: .universal))

        // Nothing distinguishing at all → no target.
        XCTAssertNil(AssignableRunnerTarget.from(row: row(), mode: .universal))
    }

    @MainActor
    func testAssignableRunnerTargetShortcutWrite() {
        let appURL = URL(fileURLWithPath: "/Applications/Safari.app")
        XCTAssertEqual(AssignableRunnerTarget.app(appURL).shortcutWrite, .app)

        XCTAssertEqual(
            AssignableRunnerTarget.quicklink(name: "gh").shortcutWrite,
            .extensionShortcut(commandID: "quicklinks.run", item: "gh",
                               label: "Quicklinks \u{203A} gh"))
        XCTAssertEqual(
            AssignableRunnerTarget.quickdir(name: "projects").shortcutWrite,
            .extensionShortcut(commandID: "quickdirs.run", item: "projects",
                               label: "Quickdirs \u{203A} projects"))
        XCTAssertEqual(
            AssignableRunnerTarget.snippet(name: "Sig").shortcutWrite,
            .extensionShortcut(commandID: "snippets.run", item: "Sig",
                               label: "Snippets \u{203A} Sig"))
    }

    func testSnippetNameFromSubtitle() {
        XCTAssertEqual(snippetName(fromSubtitle: "Sig  \u{00B7}  ;;sig"), "Sig")
        XCTAssertEqual(snippetName(fromSubtitle: "Sig"), "Sig")
        XCTAssertEqual(snippetName(fromSubtitle: ""), "")
    }
}
