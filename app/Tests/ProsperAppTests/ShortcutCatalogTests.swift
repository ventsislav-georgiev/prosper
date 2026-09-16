import Carbon
import XCTest
@testable import ProsperApp

/// The one searchable Actions catalog behind Settings › Shortcuts.
///
/// `ShortcutCatalog.build` is deliberately pure — plain arrays in, `[BindableAction]`
/// out, no SwiftUI and no MainActor store — precisely so the merge that replaced five
/// row views and nine sections can be proven here without a window. The write side is
/// checked at the store level rather than through `SettingsModel`: the pane's guarantee
/// is ZERO migration, i.e. that a row carries back exactly the identifier the old row
/// wrote under, so `UserDefaults` ends up holding the same value under the same key.
final class ShortcutCatalogTests: XCTestCase {

    private func combo(_ key: Int, _ mods: Int, _ display: String = "test") -> KeyCombo {
        KeyCombo(keyCode: UInt32(key), carbonModifiers: UInt32(mods), display: display)
    }

    private func catalog(
        prosper: [ShortcutAction] = ShortcutAction.allCases,
        combos: [ShortcutAction: KeyCombo] = [:],
        manifest: [ExtensionShortcuts.ManifestKeybinding] = [],
        overrides: [String: KeyCombo] = [:],
        extensionActions: [BindableExtensionAction] = [],
        extensionShortcuts: [ExtensionShortcut] = [],
        targets: [ActivationTarget] = [],
        custom: [CustomShortcut] = [],
        apps: [AppShortcut] = [],
        spotlightChords: Set<KeyCombo> = []
    ) -> [BindableAction] {
        ShortcutCatalog.build(
            prosperActions: prosper, combos: combos,
            manifestKeybindings: manifest, keybindingOverrides: overrides,
            extensionActions: extensionActions, extensionShortcuts: extensionShortcuts,
            activationTargets: targets, customShortcuts: custom, appShortcuts: apps,
            spotlightChords: spotlightChords)
    }

    private func action(_ commandID: String, _ item: String = "",
                        ext: String = "System Settings",
                        title: String = "Open Pane") -> BindableExtensionAction {
        BindableExtensionAction(commandID: commandID, item: item, extensionTitle: ext,
                                commandTitle: title, icon: "gearshape")
    }

    // MARK: - Coverage

    /// The headline of the rework: the six window-management cases used to be
    /// filtered OUT of the Shortcuts pane and reachable only from the Window
    /// extension pane. Every case now has exactly one row.
    func testEveryShortcutActionAppearsExactlyOnce() {
        let rows = catalog().filter { $0.kind == .prosper }
        XCTAssertEqual(rows.count, ShortcutAction.allCases.count)
        let keys = rows.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "a duplicated row would double-register")
        for action in ShortcutAction.allCases {
            XCTAssertTrue(keys.contains(action.rawValue), "\(action.rawValue) has no row")
        }
        for action in ShortcutAction.allCases where action.isWindowManagement {
            XCTAssertTrue(keys.contains(action.rawValue),
                          "window management must no longer be filtered out")
        }
    }

    /// Ids are what `ForEach` tracks. Two rows sharing one would make the table
    /// flicker and hand a recorder's output to the wrong action.
    func testRowIDsAreUniqueAcrossKinds() {
        let sc = ExtensionShortcut(commandID: "toggles.run", item: "Dark Mode",
                                   combo: combo(kVK_ANSI_D, optionKey), label: "Toggles \u{203A} Dark Mode")
        let rows = catalog(
            manifest: [ExtensionShortcuts.ManifestKeybinding(
                commandID: "toggles.run", extensionTitle: "Quick Toggles",
                commandTitle: "Toggle", defaultCombo: combo(kVK_ANSI_T, optionKey))],
            extensionActions: [action("toggles.run", "Dark Mode", ext: "Quick Toggles")],
            extensionShortcuts: [sc],
            targets: [ActivationTarget(label: "Quicklinks", prefix: "ql ")],
            custom: [CustomShortcut(combo: combo(kVK_ANSI_Q, optionKey), prefix: "ql ", label: "Quicklinks")],
            apps: [AppShortcut(target: "com.example.a", combo: combo(kVK_ANSI_A, cmdKey), name: "A")])
        let ids = rows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        // A manifest keybinding and a user binding for the SAME command id are
        // different stores and must stay two rows.
        XCTAssertEqual(rows.filter { $0.key.hasPrefix("toggles.run") }.count, 2)
    }

    // MARK: - Merge rules

    /// A saved binding whose extension is disabled (so the registry offers nothing)
    /// still gets a row. Dropping it would hide a live hotkey.
    func testSavedExtensionBindingSurvivesAnEmptyListing() {
        let sc = ExtensionShortcut(commandID: "scripts.run", item: "deploy",
                                   combo: combo(kVK_ANSI_S, optionKey), label: "Scripts \u{203A} deploy")
        let rows = catalog(extensionShortcuts: [sc]).filter { $0.kind == .extensionItem }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recordID, sc.id)
        XCTAssertEqual(rows[0].title, "deploy")
        XCTAssertEqual(rows[0].category, "Scripts")
        XCTAssertTrue(rows[0].isBound)
    }

    /// An offered action the user has not bound is one row with no record behind it
    /// — recording on it is what creates the record.
    func testOfferedExtensionActionIsUnboundAndRecordless() {
        let rows = catalog(extensionActions: [action("sysprefs.run", "Displays")])
            .filter { $0.kind == .extensionItem }
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].recordID)
        XCTAssertFalse(rows[0].isBound)
        XCTAssertEqual(rows[0].title, "Displays")
    }

    /// The saved combo has to land on the offered row, not add a second one.
    func testSavedBindingMergesOntoItsOfferedAction() {
        let sc = ExtensionShortcut(commandID: "sysprefs.run", item: "Displays",
                                   combo: combo(kVK_ANSI_P, optionKey), label: "System Settings \u{203A} Displays")
        let rows = catalog(extensionActions: [action("sysprefs.run", "Displays")],
                           extensionShortcuts: [sc]).filter { $0.kind == .extensionItem }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recordID, sc.id)
        XCTAssertEqual(rows[0].combo, sc.combo)
    }

    /// Every activation prefix is a row whether or not it is bound — that is what
    /// replaced both the "Add Shortcut" + dropdown dance and the read-only
    /// "Extension Activators" guide.
    func testActivationTargetsAreRowsAndMergeSavedCustomShortcuts() {
        let saved = CustomShortcut(combo: combo(kVK_ANSI_G, optionKey), prefix: "ql ", label: "Quicklinks")
        let rows = catalog(
            targets: [ActivationTarget(label: "Quicklinks", prefix: "ql "),
                      ActivationTarget(label: "Bookmarks", prefix: "bm ")],
            custom: [saved]).filter { $0.kind == .runnerPrefix }
        XCTAssertEqual(rows.count, 2)
        let ql = rows.first { $0.key == "ql " }
        XCTAssertEqual(ql?.recordID, saved.id)
        XCTAssertEqual(ql?.combo, saved.combo)
        XCTAssertFalse(rows.first { $0.key == "bm " }?.isBound ?? true)
    }

    /// A binding for a prefix no live target offers any more (a renamed quickdir)
    /// keeps its own row under its stored label.
    func testOrphanedCustomShortcutKeepsARow() {
        let saved = CustomShortcut(combo: combo(kVK_ANSI_K, optionKey), prefix: "old ", label: "Old Quickdir")
        let rows = catalog(targets: [ActivationTarget(label: "Quicklinks", prefix: "ql ")],
                           custom: [saved]).filter { $0.kind == .runnerPrefix }
        XCTAssertEqual(Set(rows.map(\.key)), ["ql ", "old "])
        XCTAssertEqual(rows.first { $0.key == "old " }?.title, "Old Quickdir")
    }

    /// Two app shortcuts on the same chord flag each other, naming who else uses it.
    func testDuplicateAppCombosAreFlagged() {
        let c = combo(kVK_ANSI_D, cmdKey | shiftKey)
        let a = AppShortcut(target: "com.a", combo: c, name: "A")
        let b = AppShortcut(target: "com.b", combo: c, name: "B")
        let lone = AppShortcut(target: "com.c", combo: combo(kVK_ANSI_C, cmdKey), name: "C")
        let rows = catalog(apps: [a, b, lone]).filter { $0.kind == .app }
        XCTAssertEqual(rows.filter { $0.conflictNote != nil }.count, 2)
        XCTAssertEqual(rows.first { $0.title == "A" }?.conflictNote, "Also used by B \u{2014} only one will fire.")
        XCTAssertNil(rows.first { $0.title == "C" }?.conflictNote)
    }

    /// The whole point of #120: a conflict is no longer app-vs-app only. An app
    /// shortcut and a runner prefix sharing a chord flag each other too.
    func testConflictsAreFlaggedAcrossDifferentKinds() {
        let c = combo(kVK_ANSI_K, cmdKey | shiftKey)
        let app = AppShortcut(target: "com.a", combo: c, name: "A")
        let custom = CustomShortcut(combo: c, prefix: "ql ", label: "Quicklinks")
        let rows = catalog(targets: [ActivationTarget(label: "Quicklinks", prefix: "ql ")],
                           custom: [custom], apps: [app])
        let appRow = rows.first { $0.kind == .app }
        let prefixRow = rows.first { $0.kind == .runnerPrefix }
        XCTAssertEqual(appRow?.conflictNote, "Also used by Quicklinks \u{2014} only one will fire.")
        XCTAssertEqual(prefixRow?.conflictNote, "Also used by A \u{2014} only one will fire.")
    }

    /// Same key, different modifiers — not a conflict.
    func testDifferentModifiersAreNotFlagged() {
        let a = AppShortcut(target: "com.a", combo: combo(kVK_ANSI_D, cmdKey), name: "A")
        let b = AppShortcut(target: "com.b", combo: combo(kVK_ANSI_D, cmdKey | shiftKey), name: "B")
        let rows = catalog(apps: [a, b]).filter { $0.kind == .app }
        XCTAssertTrue(rows.allSatisfy { $0.conflictNote == nil })
    }

    /// Two never-bound rows both happen to carry `unsetKeyCombo` — that must never
    /// read as "the same chord".
    func testUnsetRowsAreNeverFlagged() {
        let rows = catalog(targets: [ActivationTarget(label: "Quicklinks", prefix: "ql "),
                                     ActivationTarget(label: "Bookmarks", prefix: "bm ")])
            .filter { $0.kind == .runnerPrefix }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { !$0.isBound })
        XCTAssertTrue(ShortcutCatalog.conflicts(in: rows).isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.conflictNote == nil })
    }

    /// The universal launcher's default chords (⌘Space, ⌥Space) get the Spotlight
    /// guide even with nothing else on the chord.
    /// `spotlightChords` is what the CALLER decides, per #111's own live check — the
    /// catalog itself stays pure and only ever asks "is this row's chord in the set
    /// I was handed?".
    func testSpotlightNoteAppearsOnlyWhenChordIsInTheSet() {
        let flagged = catalog(spotlightChords: [ShortcutAction.runner.defaultCombo.chord])
            .filter { $0.kind == .prosper }
        let runner = flagged.first { $0.key == ShortcutAction.runner.rawValue }
        let runnerSpace = flagged.first { $0.key == ShortcutAction.runnerSpace.rawValue }
        XCTAssertEqual(runner?.conflictNote, SpotlightShortcutConflict.catalogHint,
                       "⌘Space is in the set, so the runner row gets the hint")
        XCTAssertNil(runnerSpace?.conflictNote,
                     "⌥Space is NOT in the set — passing only what the caller vouched for")
    }

    /// The default, empty set (Spotlight moved off ⌘Space, or #111's check couldn't
    /// read the live preference) must never leave a permanent ⚠ on a default install.
    func testSpotlightNoteAbsentWhenSetIsEmpty() {
        let rows = catalog().filter { $0.kind == .prosper } // spotlightChords defaults to []
        XCTAssertTrue(rows.allSatisfy { $0.conflictNote == nil })
    }

    /// A row that is both a duplicate AND on a Spotlight-class chord (per the set it
    /// was handed) gets one line carrying both notes, not a second sub-row.
    func testDuplicateAndSpotlightNotesJoinOnOneLine() {
        let app = AppShortcut(target: "com.a", combo: ShortcutAction.runner.defaultCombo, name: "A")
        let rows = catalog(apps: [app], spotlightChords: [ShortcutAction.runner.defaultCombo.chord])
        let runner = rows.first { $0.key == ShortcutAction.runner.rawValue }
        XCTAssertEqual(runner?.conflictNote,
                       "Also used by A \u{2014} only one will fire. \(SpotlightShortcutConflict.catalogHint)")
    }

    /// An app that is not installed on this machine still renders — under the name
    /// captured when it was bound, which is what the old `AppShortcutRow` did.
    func testUninstalledAppStillRenders() {
        let sc = AppShortcut(target: "com.not.installed", combo: combo(kVK_ANSI_X, cmdKey), name: "Ghost")
        let row = catalog(apps: [sc]).first { $0.kind == .app }
        XCTAssertEqual(row?.title, "Ghost")
        XCTAssertEqual(row?.target, "com.not.installed")
    }

    /// The manifest default shows through until the user overrides it, and ↩ is only
    /// offered where a default actually exists.
    func testManifestOverrideWinsAndResetIsOffered() {
        let kb = ExtensionShortcuts.ManifestKeybinding(
            commandID: "translate.run", extensionTitle: "Translate",
            commandTitle: "Translate", defaultCombo: combo(kVK_ANSI_L, optionKey, "\u{2325}L"))
        let plain = catalog(manifest: [kb]).first { $0.kind == .manifest }
        XCTAssertEqual(plain?.combo, kb.defaultCombo)
        XCTAssertNotNil(plain?.defaultCombo)

        let override = combo(kVK_ANSI_M, optionKey)
        let bound = catalog(manifest: [kb], overrides: ["translate.run": override])
            .first { $0.kind == .manifest }
        XCTAssertEqual(bound?.combo, override)

        // Extension items, prefixes and apps have no default to go back to.
        for row in catalog(extensionActions: [action("sysprefs.run", "Displays")],
                           targets: [ActivationTarget(label: "Quicklinks", prefix: "ql ")],
                           apps: [AppShortcut(target: "com.a", combo: combo(kVK_ANSI_A, cmdKey), name: "A")])
        where row.kind != .prosper {
            XCTAssertNil(row.defaultCombo, "\(row.id) must offer no reset")
        }
    }

    /// `unsetKeyCombo` is how a cleared binding persists; registration skips it, so
    /// the catalog must not call it bound.
    func testUnsetComboIsNotBound() {
        let rows = catalog(combos: [.runner: unsetKeyCombo])
        XCTAssertFalse(rows.first { $0.key == "runner" }?.isBound ?? true)
        XCTAssertTrue(rows.first { $0.key == "clipboard" }?.isBound ?? false)
    }

    // MARK: - Filtering

    func testFilterMatchesTitleCategoryAndComboDisplay() {
        let rows = catalog(apps: [AppShortcut(target: "com.dbeaver",
                                              combo: combo(kVK_ANSI_D, cmdKey | shiftKey, "\u{2318}\u{21E7}D"),
                                              name: "DBeaver")])
        XCTAssertEqual(ShortcutCatalog.filter(rows, query: "dbeaver").count, 1)
        XCTAssertEqual(ShortcutCatalog.filter(rows, query: "\u{2318}\u{21E7}D").count, 1)
        XCTAssertTrue(ShortcutCatalog.filter(rows, query: "clipboard").contains { $0.key == "clipboard" })
        // Case- and accent-folded, same as the settings search field.
        XCTAssertEqual(ShortcutCatalog.filter(rows, query: "DBEAVER").count, 1)
        XCTAssertTrue(ShortcutCatalog.filter(rows, query: "no such action").isEmpty)
        XCTAssertEqual(ShortcutCatalog.filter(rows, query: "   ").count, rows.count)
    }

    func testBoundOnlyKeepsOnlyBoundRows() {
        let rows = catalog(targets: [ActivationTarget(label: "Quicklinks", prefix: "ql ")])
        let bound = ShortcutCatalog.filter(rows, query: "", boundOnly: true)
        XCTAssertFalse(bound.isEmpty)
        XCTAssertTrue(bound.allSatisfy(\.isBound))
        XCTAssertFalse(bound.contains { $0.kind == .runnerPrefix })
    }

    // MARK: - Write-back identifiers (zero migration)

    /// `SettingsModel.bind` is a switch that hands a row's `key` / `recordID` to the
    /// same store method the old row view used. This proves the identifiers survive
    /// the trip: writing through what the row carries leaves `UserDefaults` holding
    /// exactly what the old pane's write left there.
    ///
    /// Compared as DECODED VALUES, not raw bytes. `JSONEncoder` buffers into a
    /// dictionary before serializing, so the key order of the same value can differ
    /// between encodes (and between processes) — a byte comparison here failed
    /// intermittently with "53 bytes != 53 bytes", which is a property of the
    /// encoder, not of the thing under test.
    ///
    /// `ShortcutStore` writes to `UserDefaults.standard`, so save and restore the
    /// real keys around it — same guard as `AppShortcutTests`.
    func testRowIdentifiersWriteTheSameDefaultsAsTheOldPane() throws {
        let keys = ["shortcut.clipboard", ShortcutStore.appsKey,
                    ShortcutStore.extensionsKey, ShortcutStore.extensionKeybindingsKey]
        let saved = keys.map { UserDefaults.standard.data(forKey: $0) }
        defer {
            for (key, data) in zip(keys, saved) {
                if let data { UserDefaults.standard.set(data, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        /// What the store actually holds under `key`, decoded. Nil is a real answer
        /// (nothing written) and must not be confused with "decoded to empty".
        func stored<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        }

        // A fixed action: the old row called setShortcut(_:for:) with the action.
        let c = combo(kVK_ANSI_V, optionKey, "\u{2325}V")
        ShortcutStore.setCombo(c, for: .clipboard)
        let expectedFixed = try stored("shortcut.clipboard", as: KeyCombo.self)
        XCTAssertEqual(expectedFixed, c, "the old pane's own write must round-trip")
        ShortcutStore.reset(.clipboard)
        XCTAssertNil(try stored("shortcut.clipboard", as: KeyCombo.self))
        let fixedRow = catalog().first { $0.kind == .prosper && $0.key == "clipboard" }!
        ShortcutStore.setCombo(c, for: ShortcutAction(rawValue: fixedRow.key)!)
        XCTAssertEqual(try stored("shortcut.clipboard", as: KeyCombo.self), expectedFixed)

        // A manifest override: keyed by command id, which is what the row carries.
        let kb = ExtensionShortcuts.ManifestKeybinding(
            commandID: "translate.run", extensionTitle: "Translate",
            commandTitle: "Translate", defaultCombo: combo(kVK_ANSI_L, optionKey))
        UserDefaults.standard.removeObject(forKey: ShortcutStore.extensionKeybindingsKey)
        ShortcutStore.setExtensionKeybinding(c, for: "translate.run")
        let expectedOverride = try stored(ShortcutStore.extensionKeybindingsKey,
                                          as: [String: KeyCombo].self)
        XCTAssertEqual(expectedOverride, ["translate.run": c])
        UserDefaults.standard.removeObject(forKey: ShortcutStore.extensionKeybindingsKey)
        let manifestRow = catalog(manifest: [kb]).first { $0.kind == .manifest }!
        ShortcutStore.setExtensionKeybinding(c, for: manifestRow.key)
        XCTAssertEqual(try stored(ShortcutStore.extensionKeybindingsKey,
                                  as: [String: KeyCombo].self), expectedOverride)

        // An app shortcut: the row carries the record's UUID, so mutating "the row's
        // record" and "the shortcut the old row held" are the same array element.
        // Order matters here and `[AppShortcut]` equality preserves it.
        var apps = [AppShortcut(target: "com.a", combo: unsetKeyCombo, name: "A"),
                    AppShortcut(target: "com.b", combo: unsetKeyCombo, name: "B")]
        var old = apps
        old[1].combo = c
        ShortcutStore.setAppShortcuts(old)
        let expectedApps = try stored(ShortcutStore.appsKey, as: [AppShortcut].self)
        XCTAssertEqual(expectedApps, old)
        let appRow = catalog(apps: apps).first { $0.kind == .app && $0.title == "B" }!
        XCTAssertEqual(appRow.recordID, apps[1].id)
        apps[apps.firstIndex { $0.id == appRow.recordID }!].combo = c
        ShortcutStore.setAppShortcuts(apps)
        XCTAssertEqual(try stored(ShortcutStore.appsKey, as: [AppShortcut].self), expectedApps)

        // An extension binding the catalog merely OFFERED has no record yet: the
        // row's key is what a new record is built from.
        let offered = catalog(extensionActions: [action("sysprefs.run", "Displays")])
            .first { $0.kind == .extensionItem }!
        XCTAssertNil(offered.recordID)
        let (commandID, item) = ShortcutCatalog.splitExtensionKey(offered.key)
        XCTAssertEqual(commandID, "sysprefs.run")
        XCTAssertEqual(item, "Displays")
        XCTAssertEqual(offered.storageLabel, "System Settings \u{203A} Displays")
    }

    // MARK: - Performance

    /// The pane must open instantly and filter without lag. Bounds are generous so a
    /// loaded CI box cannot go red on noise; the printed numbers are what matters —
    /// a regression shows as a 10x, not a 1.2x.
    func testCatalogBuildAndFilterStayFastAt500Rows() {
        let offered = (0..<500).map {
            action("ext\($0 % 20).run", "Item \($0)", ext: "Extension \($0 % 20)")
        }
        let bound = (0..<50).map { i in
            ExtensionShortcut(commandID: "ext\(i % 20).run", item: "Item \(i)",
                              combo: combo(kVK_ANSI_A + (i % 5), optionKey),
                              label: "Extension \(i % 20) \u{203A} Item \(i)")
        }
        // 50 app shortcuts already share one chord (kept from before this pass);
        // add a few more deliberate collisions across OTHER sources so the second,
        // conflict-detecting pass over `build`'s output has cross-kind work to do
        // too, not just one giant same-kind group.
        let apps = (0..<50).map { AppShortcut(target: "com.app\($0)", combo: combo(kVK_ANSI_B, cmdKey), name: "App \($0)") }
        let targets = (0..<30).map { ActivationTarget(label: "Target \($0)", prefix: "t\($0) ") }
        let customDuplicates = (0..<5).map {
            CustomShortcut(combo: combo(kVK_ANSI_C, cmdKey | shiftKey), prefix: "dup\($0) ", label: "Dup \($0)")
        }

        // Exercise the Spotlight side of the second pass too, same as a default
        // install where #111's check finds Spotlight on ⌘Space.
        let spotlightChords: Set<KeyCombo> = [ShortcutAction.runner.defaultCombo.chord]

        let clock = ContinuousClock()
        var rows: [BindableAction] = []
        var build = Duration.seconds(60)
        for _ in 0..<5 {
            let took = clock.measure {
                rows = self.catalog(extensionActions: offered, extensionShortcuts: bound,
                                    targets: targets, custom: customDuplicates, apps: apps,
                                    spotlightChords: spotlightChords)
            }
            build = min(build, took)
        }
        XCTAssertGreaterThan(rows.count, 500)
        let conflicted = rows.filter { $0.conflictNote != nil }.count
        // Both deliberate groups above must be flagged (the extension shortcuts'
        // own `i % 5` combos coincidentally collide too, so this checks the two
        // groups this test controls rather than the grand total).
        XCTAssertTrue(rows.filter { $0.kind == .app }.allSatisfy { $0.conflictNote != nil },
                      "all 50 same-chord app shortcuts must be flagged")
        let dupPrefixRows = rows.filter { $0.kind == .runnerPrefix && $0.key.hasPrefix("dup") }
        XCTAssertEqual(dupPrefixRows.count, 5)
        XCTAssertTrue(dupPrefixRows.allSatisfy { $0.conflictNote != nil },
                      "all 5 same-chord custom prefixes must be flagged")
        XCTAssertEqual(rows.first { $0.key == ShortcutAction.runner.rawValue }?.conflictNote,
                      SpotlightShortcutConflict.catalogHint,
                      "the ⌘Space row must carry the Spotlight hint the set vouched for")

        var filter = Duration.seconds(60)
        for _ in 0..<5 {
            let took = clock.measure { _ = ShortcutCatalog.filter(rows, query: "item 4") }
            filter = min(filter, took)
        }

        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        let buildMS = ms(build)
        let filterMS = ms(filter)
        print("ShortcutCatalog perf: \(rows.count) rows (\(conflicted) conflicted) — build \(buildMS) ms, filter \(filterMS) ms")
        XCTAssertLessThan(buildMS, 50, "catalog build for \(rows.count) rows")
        XCTAssertLessThan(filterMS, 10, "filter over \(rows.count) rows")
    }
}
