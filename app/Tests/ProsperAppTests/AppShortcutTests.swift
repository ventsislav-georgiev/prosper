import XCTest
import Carbon
@testable import ProsperApp

/// App shortcuts: a global hotkey that launches/focuses one app (⌘⇧D → DBeaver).
/// The load-bearing logic is the pure `AppShortcut.registrations` rule, which decides
/// what claims a Carbon hotkey and under which id — extracted precisely so it can be
/// proven here without Carbon, AppKit or a live `AppDelegate` (same rationale as
/// `AppDelegate.needKeyTap`). The `RegisterEventHotKey` call itself has no branching
/// worth modelling.
final class AppShortcutTests: XCTestCase {

    private func combo(_ key: Int, _ mods: Int) -> KeyCombo {
        KeyCombo(keyCode: UInt32(key), carbonModifiers: UInt32(mods), display: "test")
    }

    private func shortcut(_ target: String = "com.example.app",
                          _ c: KeyCombo? = nil,
                          name: String = "Example") -> AppShortcut {
        AppShortcut(target: target,
                    combo: c ?? combo(kVK_ANSI_D, cmdKey | shiftKey),
                    name: name)
    }

    // MARK: - Skip rules

    /// An unset / half-recorded combo has no modifier. Registering it would claim a
    /// BARE key and swallow ordinary typing, so it must never reach Carbon.
    func testUnsetComboIsSkipped() {
        let list = [shortcut("com.example.app", unsetKeyCombo)]
        XCTAssertTrue(AppShortcut.registrations(list).isEmpty)
    }

    /// Same guard, stated directly: any zero-modifier combo is skipped even with a
    /// real keycode (the recorder rejects these, but a synced/hand-edited blob could).
    func testBareKeyWithoutModifierIsSkipped() {
        let list = [shortcut("com.example.app", combo(kVK_ANSI_D, 0))]
        XCTAssertTrue(AppShortcut.registrations(list).isEmpty)
    }

    /// A row added in Settings before an app was picked has no target — nothing to
    /// launch, so it shouldn't hold a hotkey either.
    func testEmptyTargetIsSkipped() {
        let list = [shortcut("")]
        XCTAssertTrue(AppShortcut.registrations(list).isEmpty)
    }

    func testValidShortcutIsRegistered() {
        let list = [shortcut()]
        let regs = AppShortcut.registrations(list)
        XCTAssertEqual(regs.count, 1)
        XCTAssertEqual(regs[0].shortcut.target, "com.example.app")
    }

    // MARK: - Hot-key id range

    /// Ids must start at the app-shortcut base and increment per REGISTERED entry.
    /// Skipped entries must not burn an id (a gap would still be safe, but the
    /// contract is a dense range).
    func testIdsAreDenseFromBaseSkippingInvalid() {
        let list = [
            shortcut("com.a"),
            shortcut("", combo(kVK_ANSI_E, cmdKey)),          // skipped: no target
            shortcut("com.b", unsetKeyCombo),                  // skipped: unset combo
            shortcut("com.c", combo(kVK_ANSI_F, cmdKey)),
        ]
        let regs = AppShortcut.registrations(list)
        XCTAssertEqual(regs.map(\.id), [AppShortcut.hotKeyIdBase, AppShortcut.hotKeyIdBase + 1])
        XCTAssertEqual(regs.map(\.shortcut.target), ["com.a", "com.c"])
    }

    /// The collision that would silently hijack an extension's keybinding: extension
    /// hotkeys start at 300 in `AppDelegate.registerHotKeys`, so no app-shortcut id
    /// may ever reach it, however many the user adds.
    func testIdsNeverReachExtensionRange() {
        // Distinct chords per row: identical ones now collapse to a single
        // registration, which would make the cap trivially unreachable here.
        let list = (0..<(AppShortcut.maxRegistered + 25)).map {
            shortcut("com.example.app\($0)", combo($0, cmdKey | shiftKey))
        }
        let regs = AppShortcut.registrations(list)
        XCTAssertEqual(regs.count, AppShortcut.maxRegistered)
        for reg in regs {
            XCTAssertGreaterThanOrEqual(reg.id, AppShortcut.hotKeyIdBase)
            XCTAssertLessThan(reg.id, GlobalHotKey.extensionIdBase,
                              "app-shortcut id leaked into the extension range")
        }
    }

    /// The base must also stay clear of the fixed (1-19) and custom (100+) ranges.
    func testBaseIsClearOfLowerRanges() {
        XCTAssertGreaterThanOrEqual(AppShortcut.hotKeyIdBase,
                                    GlobalHotKey.customIdBase + UInt32(GlobalHotKey.customMaxRegistered))
        for action in ShortcutAction.allCases {
            XCTAssertNotEqual(action.hotKeyId, AppShortcut.hotKeyIdBase)
        }
    }

    /// Every fixed action needs its own hotkey id, or the later registration
    /// silently replaces the earlier one.
    func testFixedActionHotKeyIdsAreUnique() {
        let ids = ShortcutAction.allCases.map(\.hotKeyId)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    @MainActor
    func testSpotlightGuideIsForDefaultCommandSpaceRunnerRegardlessOfRegistration() {
        XCTAssertTrue(SpotlightShortcutConflict.shouldPresent(
            isDefaultRunner: true, spotlightUsesCommandSpace: true))
        XCTAssertFalse(SpotlightShortcutConflict.shouldPresent(
            isDefaultRunner: false, spotlightUsesCommandSpace: true))
        XCTAssertFalse(SpotlightShortcutConflict.shouldPresent(
            isDefaultRunner: true, spotlightUsesCommandSpace: false))

        let shortcut: [String: Any] = [
            "64": ["enabled": true, "value": ["parameters": [65535, 49,
                NSNumber(value: NSEvent.ModifierFlags.command.rawValue)]]]
        ]
        XCTAssertTrue(SpotlightShortcutConflict.spotlightUsesCommandSpace(shortcut))
        XCTAssertFalse(SpotlightShortcutConflict.spotlightUsesCommandSpace([:]))
    }

    /// The mic-mute toggle ships unbound: silencing every microphone from a key
    /// nobody chose is a surprise, and the pane toggle is the visible trigger.
    func testMicMuteShortcutHasNoDefaultCombo() {
        XCTAssertEqual(ShortcutAction.mixerToggleMicMute.defaultCombo, unsetKeyCombo)
        XCTAssertFalse(ShortcutAction.mixerToggleMicMute.isWindowManagement)
    }

    // MARK: - Duplicate combos

    /// macOS gives a combo to whoever registers first, so a duplicate silently never
    /// fires. Settings marks both rows rather than letting one look bound.
    func testDuplicateCombosAreBothReported() {
        let dup = combo(kVK_ANSI_D, cmdKey | shiftKey)
        let a = shortcut("com.a", dup)
        let b = shortcut("com.b", dup)
        let c = shortcut("com.c", combo(kVK_ANSI_W, cmdKey | shiftKey))
        let flagged = AppShortcut.duplicateComboIDs([a, b, c])
        XCTAssertEqual(flagged, Set([a.id, b.id]))
    }

    /// Two rows differing only in modifiers are distinct combos, not duplicates.
    func testDifferentModifiersAreNotDuplicates() {
        let a = shortcut("com.a", combo(kVK_ANSI_D, cmdKey | shiftKey))
        let b = shortcut("com.b", combo(kVK_ANSI_D, cmdKey | optionKey))
        XCTAssertTrue(AppShortcut.duplicateComboIDs([a, b]).isEmpty)
    }

    /// Only the FIRST claim of a chord ever fires, so a later row sharing it must
    /// not be handed a hotkey id: registering it would burn an id on something dead
    /// and make Settings' duplicate warning a lie about what is bound.
    func testDuplicateCombosOnlyRegisterOnce() {
        let dup = combo(kVK_ANSI_D, cmdKey | shiftKey)
        let regs = AppShortcut.registrations([
            shortcut("com.a", dup),
            shortcut("com.b", dup),
            shortcut("com.c", combo(kVK_ANSI_W, cmdKey | shiftKey)),
        ])
        XCTAssertEqual(regs.map(\.shortcut.target), ["com.a", "com.c"])
        XCTAssertEqual(regs.map(\.id), [AppShortcut.hotKeyIdBase, AppShortcut.hotKeyIdBase + 1])
    }

    /// The same chord recorded on two Macs can carry different display strings
    /// (layout, or a synced row). Arbitration is keycode + modifiers only.
    func testDuplicateDetectionIgnoresDisplayString() {
        let a = shortcut("com.a", KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                                           carbonModifiers: UInt32(cmdKey | shiftKey),
                                           display: "\u{2318}\u{21E7}D"))
        let b = shortcut("com.b", KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                                           carbonModifiers: UInt32(cmdKey | shiftKey),
                                           display: "other"))
        XCTAssertEqual(AppShortcut.duplicateComboIDs([a, b]), Set([a.id, b.id]))
        XCTAssertEqual(AppShortcut.registrations([a, b]).count, 1)
    }

    /// Unset rows share keyCode 0 / modifier 0 but aren't bound to anything, so
    /// several of them must not light up the duplicate warning.
    func testMultipleUnsetRowsAreNotDuplicates() {
        let a = shortcut("com.a", unsetKeyCombo)
        let b = shortcut("com.b", unsetKeyCombo)
        XCTAssertTrue(AppShortcut.duplicateComboIDs([a, b]).isEmpty)
    }

    // MARK: - Store round-trip

    /// `ShortcutStore` writes to `UserDefaults.standard`, so save and restore the key
    /// around the assertions rather than polluting the dev machine's prefs.
    func testStoreRoundTrip() {
        let key = ShortcutStore.appsKey
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(ShortcutStore.appShortcuts(), [], "missing key should decode to empty")

        let list = [shortcut("com.a", combo(kVK_ANSI_D, cmdKey | shiftKey), name: "DBeaver"),
                    shortcut("com.b", combo(kVK_ANSI_W, cmdKey | shiftKey), name: "Warp")]
        ShortcutStore.setAppShortcuts(list)
        XCTAssertEqual(ShortcutStore.appShortcuts(), list, "order and fields must survive a round-trip")
    }

    // MARK: - Settings sync

    /// The `shortcut.` prefix is why app shortcuts sync across devices with no
    /// per-key allowlist entry. A future edit to `SyncedKeys` must not silently
    /// strand them (they'd stop reaching other Macs with no compile error).
    func testAppShortcutsAreCoveredBySettingsSync() {
        let key = ShortcutStore.appsKey
        XCTAssertTrue(SyncedKeys.prefixes.contains { key.hasPrefix($0) },
                      "\(key) must be matched by a SyncedKeys prefix")
        XCTAssertFalse(SyncedKeys.excluded.contains(key))
    }

    // MARK: - "Prosper Settings" as a searchable row

    /// Goes through the real router rather than re-scoring a copy of the haystack:
    /// a literal-based score test stays green even if the entry is deleted from
    /// `nativeEntries`, which is the only failure that matters here. The runner is
    /// the one always-reachable way into Settings (⌥\\ is rebindable, the menu-bar
    /// icon can be hidden), so every synonym has to actually surface the row.
    func testSettingsSynonymsSurfaceTheRow() async {
        for q in ["settings", "preferences", "prefs", "prosper", "config", "options",
                  "prosper settings"] {
            guard case .search(let hits) = await CommandRouter.run(q) else {
                XCTFail("\u{201C}\(q)\u{201D} produced no search outcome")
                continue
            }
            XCTAssertTrue(hits.contains { $0.metaCommand == .openSettings },
                          "\u{201C}\(q)\u{201D} should surface Prosper Settings")
        }
    }

    /// The row is additive: it must not push System Settings.app off the top of
    /// "settings" (an AppIndex alias, score 1000).
    @MainActor
    func testSystemSettingsAppStillOutranksProsperSettings() async throws {
        let apps = AppIndex.shared.ensureBuilt()
        try XCTSkipUnless(apps.contains { $0.name.localizedCaseInsensitiveContains("System Settings") },
                          "no System Settings.app in this environment")
        guard case .search(let hits) = await CommandRouter.run("settings") else {
            return XCTFail("no search outcome for \u{201C}settings\u{201D}")
        }
        let prosper = hits.firstIndex { $0.metaCommand == .openSettings }
        let system = hits.firstIndex { $0.kind == .app }
        XCTAssertNotNil(prosper)
        XCTAssertNotNil(system)
        if let prosper, let system {
            XCTAssertLessThan(system, prosper, "an app row must still win \u{201C}settings\u{201D}")
        }
    }

    /// An unrelated query must not drag the entry in — a haystack matched too
    /// loosely would show it under everything.
    func testUnrelatedQueryDoesNotSurfaceSettings() async {
        guard case .search(let hits) = await CommandRouter.run("dbeaver") else { return }
        XCTAssertFalse(hits.contains { $0.metaCommand == .openSettings })
    }
}
