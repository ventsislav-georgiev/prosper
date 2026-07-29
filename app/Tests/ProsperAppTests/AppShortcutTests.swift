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
        let list = (0..<(AppShortcut.maxRegistered + 25)).map {
            shortcut("com.example.app\($0)", combo(kVK_ANSI_D, cmdKey | shiftKey))
        }
        let regs = AppShortcut.registrations(list)
        XCTAssertEqual(regs.count, AppShortcut.maxRegistered)
        for reg in regs {
            XCTAssertGreaterThanOrEqual(reg.id, AppShortcut.hotKeyIdBase)
            XCTAssertLessThan(reg.id, 300, "app-shortcut id leaked into the extension range")
        }
    }

    /// The base must also stay clear of the fixed (1-16) and custom (100+) ranges.
    func testBaseIsClearOfLowerRanges() {
        XCTAssertGreaterThan(AppShortcut.hotKeyIdBase, 100 + 99)
        for action in ShortcutAction.allCases {
            XCTAssertNotEqual(action.hotKeyId, AppShortcut.hotKeyIdBase)
        }
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
        let key = "shortcut.apps"
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
        let key = "shortcut.apps"
        XCTAssertTrue(SyncedKeys.prefixes.contains { key.hasPrefix($0) },
                      "shortcut.apps must be matched by a SyncedKeys prefix")
        XCTAssertFalse(SyncedKeys.excluded.contains(key))
    }

    // MARK: - "Prosper Settings" as a searchable row

    /// The synonym haystack behind the native "Prosper Settings" entry. Typing any
    /// of these has to surface it, since the runner is the only always-reachable
    /// surface for opening Settings.
    private let settingsHaystack = "prosper settings preferences prefs config options"

    private func score(_ query: String, _ haystack: String, tieLen: Int) -> Int? {
        let q = query.lowercased()
        return SearchScore.score(q: q, tokens: q.split(separator: " ").map(String.init),
                                 matchText: haystack, tieLen: tieLen)
    }

    func testSettingsSynonymsAllMatch() {
        for q in ["settings", "preferences", "prefs", "prosper", "config", "options",
                  "prosper settings"] {
            XCTAssertNotNil(score(q, settingsHaystack, tieLen: 17),
                            "\u{201C}\(q)\u{201D} should surface Prosper Settings")
        }
    }

    /// System Settings.app is an `AppIndex` alias for "settings" (score 1000), so it
    /// must still win that query — the new row appears below it, never displaces it.
    func testSystemSettingsAppStillOutranksProsperSettings() {
        let appAlias = SearchScore.score(q: "settings", tokens: ["settings"],
                                         matchText: "system settings",
                                         tieLen: 15, isAlias: true)
        let prosper = score("settings", settingsHaystack, tieLen: 17)
        XCTAssertNotNil(appAlias)
        XCTAssertNotNil(prosper)
        XCTAssertGreaterThan(appAlias!, prosper!)
    }

    /// An unrelated query must not drag the entry in — it would show up under
    /// everything if the haystack were matched too loosely.
    func testUnrelatedQueryDoesNotMatchSettings() {
        XCTAssertNil(score("dbeaver", settingsHaystack, tieLen: 17))
    }
}
