import Carbon
import XCTest
@testable import ProsperApp

/// #1177: "Open Agent Sessions" ships on ⇧⌥S. Values only: no hotkey is registered, no window opens.
/// The store rows read and write `Preferences.defaults`, which under XCTest is the in-memory
/// `XCTestDefaults` scratch store (Preferences.swift: `guard NSClassFromString("XCTestCase") != nil
/// else { return .standard }; return XCTestDefaults(...)`), asserted at the top of each row.
final class ShortcutDefaultsTests: XCTestCase {

    private let shiftOption = UInt32(optionKey | shiftKey)
    private let storeKey = "shortcut.agentSessions"

    /// Runs `body` on the scratch store with nothing saved for Agent Sessions, and removes what it saved.
    private func withScratchStore(_ body: () throws -> Void) rethrows {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "never the app's or the operator's defaults")
        guard Preferences.defaults is XCTestDefaults else { return }
        XCTAssertTrue(Preferences.defaults.object(forKey: storeKey) == nil, "no leftover saved choice")
        defer { ShortcutStore.reset(.agentSessions) }
        try body()
    }

    func testAgentSessionsDefaultIsShiftOptionS() {
        let d = ShortcutAction.agentSessions.defaultCombo
        XCTAssertEqual(d.keyCode, UInt32(kVK_ANSI_S))
        XCTAssertEqual(d.carbonModifiers, shiftOption)
        XCTAssertEqual(d.display, "⇧⌥S", "the same shape as Clipboard History's ⇧⌥A")
        XCTAssertEqual(d.label, "⌥⇧S", "label renders in macOS modifier order")
        XCTAssertEqual(d.spokenLabel, "Option Shift S")
        XCTAssertEqual(d.specString, "alt+shift+s")
        XCTAssertEqual(KeyCombo.parse("shift+alt+s")?.chord, d.chord)
    }

    private struct Default: Hashable {
        let action: String
        let keyCode: Int
        let modifiers: Int
    }

    /// The bound defaults, written out: a change to any default has to change this list too.
    /// Set equality with the code, then no two entries of the list share a chord.
    func testNoTwoBuiltInDefaultsShareACombo() {
        let ctrlOpt = controlKey | optionKey
        let expected: [Default] = [
            Default(action: "runner", keyCode: kVK_Space, modifiers: cmdKey),
            Default(action: "runnerSpace", keyCode: kVK_Space, modifiers: optionKey),
            Default(action: "translate", keyCode: kVK_ANSI_L, modifiers: optionKey),
            Default(action: "settings", keyCode: kVK_ANSI_Backslash, modifiers: optionKey),
            Default(action: "clipboard", keyCode: kVK_ANSI_A, modifiers: optionKey | shiftKey),
            Default(action: "agent", keyCode: kVK_ANSI_G, modifiers: optionKey),
            Default(action: "windowLeftHalf", keyCode: kVK_LeftArrow, modifiers: ctrlOpt),
            Default(action: "windowRightHalf", keyCode: kVK_RightArrow, modifiers: ctrlOpt),
            Default(action: "windowTopHalf", keyCode: kVK_UpArrow, modifiers: ctrlOpt),
            Default(action: "windowBottomHalf", keyCode: kVK_DownArrow, modifiers: ctrlOpt),
            Default(action: "windowMaximize", keyCode: kVK_Return, modifiers: ctrlOpt),
            Default(action: "windowCenter", keyCode: kVK_ANSI_C, modifiers: ctrlOpt),
            Default(action: "agentSessions", keyCode: kVK_ANSI_S, modifiers: optionKey | shiftKey),
        ]
        let expectedUnset: Set<String> = ["runnerBackslash", "toggleAutocomplete", "menuBarToggleHidden",
                                          "calendarTogglePopup", "mixerCycleOutput", "mixerToggleMicMute",
                                          "copyScreenText", "pickColor"]

        let code = ShortcutAction.allCases.map { a in
            Default(action: a.rawValue, keyCode: Int(a.defaultCombo.keyCode), modifiers: Int(a.defaultCombo.carbonModifiers))
        }
        XCTAssertEqual(Set(code.filter { $0.modifiers != 0 }), Set(expected))
        XCTAssertEqual(Set(ShortcutAction.allCases.filter { $0.defaultCombo == unsetKeyCombo }.map(\.rawValue)),
                       expectedUnset)
        XCTAssertEqual(expected.count + expectedUnset.count, ShortcutAction.allCases.count)

        struct Chord: Hashable { let keyCode: Int; let modifiers: Int }
        XCTAssertEqual(Set(expected.map { Chord(keyCode: $0.keyCode, modifiers: $0.modifiers) }).count, expected.count,
                       "two built-in defaults on one chord: only the first registered would fire")
    }

    /// No saved choice (a fresh install, or an update from a build where this was unset and never touched).
    func testNoSavedChoiceGetsTheDefault() {
        withScratchStore {
            XCTAssertEqual(ShortcutStore.combo(for: .agentSessions), ShortcutAction.agentSessions.defaultCombo)
        }
    }

    func testASavedComboWinsOverTheDefault() {
        withScratchStore {
            let mine = KeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | cmdKey), display: "⌃⌘J")
            ShortcutStore.setCombo(mine, for: .agentSessions)
            XCTAssertEqual(ShortcutStore.combo(for: .agentSessions), mine)
        }
    }

    /// Clearing in Settings (`SettingsModel.clearShortcut`) saves `unsetKeyCombo`, a value, not a removal,
    /// so the new default never comes back for a person who cleared it; registration skips a combo with
    /// no modifier (AppDelegate.registerHotKeys `add`).
    func testAClearedAgentSessionsShortcutStaysCleared() throws {
        try withScratchStore {
            ShortcutStore.setCombo(unsetKeyCombo, for: .agentSessions)
            let data = try XCTUnwrap(Preferences.defaults.data(forKey: storeKey), "a clear is stored")
            XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: data), unsetKeyCombo)
            let loaded = ShortcutStore.combo(for: .agentSessions)
            XCTAssertEqual(loaded, unsetKeyCombo)
            XCTAssertEqual(loaded.carbonModifiers, 0, "registration skips it")
            let row = ShortcutCatalog.build(prosperActions: [.agentSessions], combos: [.agentSessions: loaded]).first
            XCTAssertEqual(row?.isBound, false)
            XCTAssertEqual(row?.combo.label, "Unset")
        }
    }

    /// A person who already has ⇧⌥S on their own binding sees the conflict note on both rows in Settings.
    /// (Which one fires is registration order, read from AppDelegate.registerHotKeys: see the report.)
    func testSettingsFlagsTheDefaultAgainstTheirOwnBindings() {
        let s = KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: shiftOption, display: "⇧⌥S")
        let rows = ShortcutCatalog.build(
            prosperActions: ShortcutAction.allCases, combos: [:],
            extensionShortcuts: [ExtensionShortcut(commandID: "example.run", item: "deploy", combo: s,
                                                   label: "Example \u{203A} deploy")],
            customShortcuts: [CustomShortcut(combo: s, prefix: "ex ", label: "Example Prefix")],
            appShortcuts: [AppShortcut(target: "com.example.fake", combo: s, name: "Fake App")])
        let mine = rows.first { $0.key == ShortcutAction.agentSessions.rawValue }
        let note = mine?.conflictNote ?? ""
        for other in ["Fake App", "Example Prefix", "deploy"] {
            XCTAssertTrue(note.contains(other), "note names \(other): \(note)")
        }
        let app = rows.first { $0.kind == .app }
        XCTAssertTrue(app?.conflictNote?.contains("Open Agent Sessions") ?? false)

        let clearedRows = ShortcutCatalog.build(
            prosperActions: ShortcutAction.allCases, combos: [.agentSessions: unsetKeyCombo],
            appShortcuts: [AppShortcut(target: "com.example.fake", combo: s, name: "Fake App")])
        XCTAssertTrue(clearedRows.allSatisfy { $0.conflictNote == nil }, "cleared: nothing to flag")
    }
}
