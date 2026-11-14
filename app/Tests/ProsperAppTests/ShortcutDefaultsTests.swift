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

    // MARK: - #1177 round 2: the default stands down on a chord the person's own binding holds

    private var shiftOptS: KeyCombo { KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: shiftOption, display: "⇧⌥S") }

    private struct Case {
        let name: String
        let action: ShortcutAction
        let saved: Bool
        let combo: KeyCombo
        let held: Set<KeyCombo>
        let standsDown: Bool
    }

    /// The decision, as a literal table. Only an unsaved Open Agent Sessions on a held chord stands down.
    func testDefaultStandsDownTable() {
        let s = shiftOptS
        let a = KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: shiftOption, display: "⇧⌥A")
        let j = KeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | cmdKey), display: "⌃⌘J")
        let left = KeyCombo(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥←")
        let space = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey), display: "⌘Space")
        let sOtherLabel = KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: shiftOption, display: "recorded elsewhere")
        let cases: [Case] = [
            Case(name: "nothing saved, held chord", action: .agentSessions, saved: false, combo: s, held: [s], standsDown: true),
            Case(name: "nothing saved, held, combo under another label", action: .agentSessions, saved: false,
                 combo: sOtherLabel, held: [s], standsDown: true),
            Case(name: "nothing saved, free chord", action: .agentSessions, saved: false, combo: s, held: [], standsDown: false),
            Case(name: "nothing saved, other chords held", action: .agentSessions, saved: false, combo: s, held: [a, j],
                 standsDown: false),
            Case(name: "saved ⇧⌥S on a held chord", action: .agentSessions, saved: true, combo: s, held: [s], standsDown: false),
            Case(name: "saved other combo on a held chord", action: .agentSessions, saved: true, combo: j, held: [j],
                 standsDown: false),
            Case(name: "cleared (saved unset)", action: .agentSessions, saved: true, combo: unsetKeyCombo, held: [s],
                 standsDown: false),
            Case(name: "clipboard default on a held chord", action: .clipboard, saved: false, combo: a, held: [a],
                 standsDown: false),
            Case(name: "window default on a held chord", action: .windowLeftHalf, saved: false, combo: left, held: [left],
                 standsDown: false),
            Case(name: "runner default on a held chord", action: .runner, saved: false, combo: space, held: [space],
                 standsDown: false),
            Case(name: "another action unsaved on ⇧⌥S held", action: .settings, saved: false, combo: s, held: [s],
                 standsDown: false),
        ]
        XCTAssertEqual(cases.count, 11)
        for c in cases {
            // heldChords returns chords (display stripped), so the table's held sets go in as chords too.
            XCTAssertEqual(ShortcutAction.defaultStandsDown(c.action, saved: c.saved, combo: c.combo,
                                                            held: Set(c.held.map(\.chord))),
                           c.standsDown, c.name)
        }
        // A cleared choice is not registered as today: registerHotKeys' `add` skips a combo with no modifier.
        XCTAssertEqual(unsetKeyCombo.carbonModifiers, 0)
    }

    private let touchedKeys = ["shortcut.agentSessions", "shortcut.windowLeftHalf", "shortcut.custom", "shortcut.apps",
                               "shortcut.runner", "shortcut.runnerBackslash", "shortcut.clipboard"]

    /// Runs `body` on the scratch store with none of the keys these rows touch set, and removes them after.
    private func withCleanKeys(_ body: () throws -> Void) rethrows {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "never the app's or the operator's defaults")
        guard Preferences.defaults is XCTestDefaults else { return }
        for k in touchedKeys { XCTAssertTrue(Preferences.defaults.object(forKey: k) == nil, "leftover \(k)") }
        defer { for k in touchedKeys { Preferences.defaults.removeObject(forKey: k) } }
        try body()
    }

    private func held(available: (ShortcutAction) -> Bool = { _ in true }, appResolves: (String) -> Bool = { _ in true },
                      extensionCombos: [KeyCombo] = [], ruleTriggers: [String] = [],
                      extensionRuleChords: Set<KeyCombo> = []) -> Set<KeyCombo> {
        ShortcutStore.heldChords(isAvailable: available, appResolves: appResolves,
                                 extensionCombos: extensionCombos, ruleTriggers: ruleTriggers,
                                 extensionRuleChords: extensionRuleChords)
    }

    /// Each kind of the person's own binding, read from the scratch store; defaults nobody chose hold nothing.
    func testHeldChordsReadEachKindOfBinding() {
        withCleanKeys {
            let s = shiftOptS.chord
            XCTAssertEqual(held(), [], "nothing saved: built-in defaults (⇧⌥S included) hold nothing")

            // A saved built-in choice (a window action), only while its action is available.
            ShortcutStore.setCombo(shiftOptS, for: .windowLeftHalf)
            XCTAssertEqual(held(), [s])
            XCTAssertEqual(held(available: { $0 != .windowLeftHalf }), [], "an unavailable action registers nothing")
            ShortcutStore.setCombo(unsetKeyCombo, for: .windowLeftHalf)
            XCTAssertEqual(held(), [], "a cleared built-in holds nothing")
            ShortcutStore.reset(.windowLeftHalf)

            // A recorded custom shortcut holds its chord; an unrecorded one (no modifier) holds nothing.
            let unrecorded = KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: 0, display: "S")
            ShortcutStore.setCustomShortcuts([CustomShortcut(combo: unrecorded, prefix: "ex ", label: "Example Prefix")])
            XCTAssertEqual(held(), [], "an unrecorded custom shortcut holds nothing")
            ShortcutStore.setCustomShortcuts([CustomShortcut(combo: shiftOptS, prefix: "ex ", label: "Example Prefix")])
            XCTAssertEqual(held(), [s])
            Preferences.defaults.removeObject(forKey: "shortcut.custom")

            // An app shortcut holds its chord only when it would register (its app is on this Mac).
            ShortcutStore.setAppShortcuts([AppShortcut(target: "com.example.fake", combo: shiftOptS, name: "Fake App")])
            XCTAssertEqual(held(), [s])
            XCTAssertEqual(held(appResolves: { _ in false }), [], "no app on this Mac: not registered, holds nothing")
            Preferences.defaults.removeObject(forKey: ShortcutStore.appsKey)

            // Extension registrations (manifest keybindings and the person's extension shortcuts).
            XCTAssertEqual(held(extensionCombos: [shiftOptS]), [s])
            // Native key rules: a parseable trigger with a modifier; a bare key or a media key holds no hotkey chord.
            XCTAssertEqual(held(ruleTriggers: ["shift+alt+s"]), [s])
            XCTAssertEqual(held(ruleTriggers: ["f7", "media:PLAY", ""]), [])
        }
    }

    /// The registerHotKeys inputs end to end on the scratch store: nothing saved + a held chord stands down;
    /// the person saving ⇧⌥S for Open Agent Sessions themselves makes it register (first claim wins, as today).
    func testUnsavedDefaultStandsDownAndASavedChoiceDoesNot() {
        withCleanKeys {
            ShortcutStore.setAppShortcuts([AppShortcut(target: "com.example.fake", combo: shiftOptS, name: "Fake App")])
            func standsDown() -> Bool {
                ShortcutAction.defaultStandsDown(.agentSessions,
                                                 saved: ShortcutStore.savedCombo(for: .agentSessions) != nil,
                                                 combo: ShortcutStore.combo(for: .agentSessions), held: held())
            }
            XCTAssertTrue(ShortcutStore.savedCombo(for: .agentSessions) == nil)
            XCTAssertTrue(standsDown())
            ShortcutStore.setCombo(shiftOptS, for: .agentSessions)
            XCTAssertFalse(standsDown(), "a saved ⇧⌥S is the person's choice")
            // A blob that does not decode reads as nothing saved, as combo(for:) already treats it.
            Preferences.defaults.set(Data("not json".utf8), forKey: storeKey)
            XCTAssertTrue(ShortcutStore.savedCombo(for: .agentSessions) == nil)
            XCTAssertEqual(ShortcutStore.combo(for: .agentSessions), ShortcutAction.agentSessions.defaultCombo)
            XCTAssertTrue(standsDown())
            Preferences.defaults.removeObject(forKey: ShortcutStore.appsKey)
            XCTAssertFalse(standsDown(), "the binding gone: the default registers again at the next run")
        }
    }

    // MARK: - #1189: the registration seam, extension key rules, the Settings note, the custom cap

    private struct Registration {
        let name: String
        let saved: KeyCombo?
        let available: Bool
        let held: Set<KeyCombo>
        let registered: [ShortcutAction]
    }

    /// The list registerHotKeys registers its built-ins from, read without making a GlobalHotKey. Literal table;
    /// `wanted` is a fixed four, the payload rides along.
    func testBuiltInRegistrationsSeamTable() {
        let s = shiftOptS.chord
        let wanted: [(action: ShortcutAction, payload: String)] =
            [(.runner, "r"), (.runnerBackslash, "b"), (.agentSessions, "s"), (.clipboard, "c")]
        let rows: [Registration] = [
            Registration(name: "nothing saved, chord free", saved: nil, available: true, held: [],
                         registered: [.runner, .agentSessions, .clipboard]),
            Registration(name: "nothing saved, chord held: stands down", saved: nil, available: true, held: [s],
                         registered: [.runner, .clipboard]),
            Registration(name: "saved ⇧⌥S, chord held: the person's choice", saved: shiftOptS, available: true, held: [s],
                         registered: [.runner, .agentSessions, .clipboard]),
            Registration(name: "cleared", saved: unsetKeyCombo, available: true, held: [],
                         registered: [.runner, .clipboard]),
            Registration(name: "not available (island off)", saved: nil, available: false, held: [],
                         registered: [.runner, .clipboard]),
        ]
        XCTAssertEqual(rows.count, 5)
        withCleanKeys {
            for row in rows {
                if let saved = row.saved { ShortcutStore.setCombo(saved, for: .agentSessions) } else { ShortcutStore.reset(.agentSessions) }
                let list = ShortcutStore.builtInRegistrations(
                    wanted, isAvailable: { $0 != .agentSessions || row.available }, held: row.held)
                XCTAssertEqual(list.map(\.action), row.registered, row.name)
                XCTAssertEqual(list.first?.payload, "r", row.name)
                XCTAssertEqual(list.last?.payload, "c", row.name)
                XCTAssertEqual(list.last?.combo, ShortcutAction.clipboard.defaultCombo, row.name)
            }
        }
    }

    /// Gap 1 end to end on values: a Compat rule on ⇧⌥S, loaded into a fresh engine (never `shared`, no file),
    /// is held, so the seam leaves Open Agent Sessions out; the rule gone, it is back.
    @MainActor
    func testExtensionKeyRuleMakesTheDefaultStandDown() {
        withCleanKeys {
            let engine = ExtensionKeyRules()
            engine.setRules(extensionID: "com.example.compat", json: #"[ { "from": "alt+shift+s", "swallow": true } ]"#)
            let wanted: [(action: ShortcutAction, payload: Int)] = [(.agentSessions, 1)]
            func registered(_ chords: Set<KeyCombo>) -> [ShortcutAction] {
                ShortcutStore.builtInRegistrations(wanted, isAvailable: { _ in true },
                                                   held: held(extensionRuleChords: chords)).map(\.action)
            }
            XCTAssertEqual(held(extensionRuleChords: engine.extensionKeyboardChords), [shiftOptS.chord])
            XCTAssertEqual(registered(engine.extensionKeyboardChords), [])
            engine.removeRules(extensionID: "com.example.compat")
            XCTAssertEqual(registered(engine.extensionKeyboardChords), [.agentSessions])
            // A native rule held in the engine is not counted twice or instead of the store's: heldChords reads it
            // from ShortcutRulesStore (ruleTriggers).
            engine.setRules(extensionID: ShortcutRulesStore.ownerID, json: #"[ { "from": "alt+shift+s", "swallow": true } ]"#)
            XCTAssertEqual(registered(engine.extensionKeyboardChords), [.agentSessions])
        }
    }

    /// Rider (batch 5, held-custom-uncapped survived): a custom shortcut past the registered cap is never
    /// registered, so on ⇧⌥S it holds nothing and the default does not stand down. One under the cap, it does.
    func testCustomShortcutPastTheCapHoldsNothing() {
        XCTAssertEqual(GlobalHotKey.customMaxRegistered, 100)
        withCleanKeys {
            let j = KeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | cmdKey), display: "⌃⌘J")
            let filler = (0..<100).map { _ in CustomShortcut(combo: j, prefix: "ex ", label: "Example Prefix") }
            let mine = CustomShortcut(combo: shiftOptS, prefix: "api ", label: "Example API")
            ShortcutStore.setCustomShortcuts(filler + [mine])
            XCTAssertEqual(ShortcutStore.customShortcuts().count, 101)
            XCTAssertEqual(held(), [j.chord], "the 101st is past the cap: not registered, holds nothing")
            XCTAssertFalse(ShortcutAction.defaultStandsDown(.agentSessions, saved: false,
                                                            combo: ShortcutStore.combo(for: .agentSessions), held: held()))
            ShortcutStore.setCustomShortcuts(Array(filler.dropLast()) + [mine])
            XCTAssertEqual(held(), [j.chord, shiftOptS.chord], "the 100th is registered and holds ⇧⌥S")
        }
    }

    /// Gap 2: a key mapping edit in Settings re-runs registration at once (the hook is a counter here; registerHotKeys
    /// is never called). Scratch store only; the native rules and their key are put back after.
    @MainActor
    func testAKeyMappingEditRerunsRegistration() {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "never the app's or the operator's defaults")
        guard Preferences.defaults is XCTestDefaults else { return }
        let rulesKey = "nativeShortcutRules"
        let hadKey = Preferences.defaults.object(forKey: rulesKey) != nil
        let rulesBefore = ShortcutRulesStore.shared.rules
        defer {
            ShortcutRulesStore.shared.setRules(rulesBefore)
            if !hadKey { Preferences.defaults.removeObject(forKey: rulesKey) }
        }
        let model = SettingsModel()
        var reruns = 0
        model.onShortcutsChanged = { reruns += 1 }
        model.addKeyMapping()
        XCTAssertEqual(reruns, 1, "add")
        guard var rule = model.keyMappings.last else { return XCTFail("added rule missing") }
        rule.trigger = "shift+alt+s"
        model.updateKeyMapping(rule)
        XCTAssertEqual(reruns, 2, "a trigger recorded")
        XCTAssertEqual(ShortcutRulesStore.shared.rules.last?.trigger, "shift+alt+s", "stored before the re-run reads it")
        model.removeKeyMapping(id: rule.id)
        XCTAssertEqual(reruns, 3, "remove")
    }

    private let keyRuleNoteText = "Off while a key rule uses this key \u{2014} record another shortcut for this action."

    /// Gap 3: the one sentence, as a function and on the Settings row (ShortcutCatalog.build, no window).
    func testKeyRuleNoteOnTheAgentSessionsRow() {
        let s = shiftOptS
        let a = ShortcutAction.clipboard.defaultCombo
        XCTAssertEqual(ShortcutCatalog.keyRuleNote(.agentSessions, saved: false, combo: s, keyRuleChords: [s.chord]),
                       keyRuleNoteText)
        XCTAssertTrue(ShortcutCatalog.keyRuleNote(.agentSessions, saved: true, combo: s, keyRuleChords: [s.chord]) == nil)
        XCTAssertTrue(ShortcutCatalog.keyRuleNote(.agentSessions, saved: false, combo: s, keyRuleChords: []) == nil)
        XCTAssertTrue(ShortcutCatalog.keyRuleNote(.clipboard, saved: false, combo: a, keyRuleChords: [a.chord]) == nil)

        let rules = ShortcutStore.keyRuleChords(ruleTriggers: ["shift+alt+s"], extensionRuleChords: [])
        func note(saved: Set<ShortcutAction> = [], apps: [AppShortcut] = []) -> String? {
            ShortcutCatalog.build(prosperActions: ShortcutAction.allCases, combos: [:], appShortcuts: apps,
                                  keyRuleChords: rules, savedActions: saved)
                .first { $0.key == ShortcutAction.agentSessions.rawValue }?.conflictNote
        }
        XCTAssertEqual(note(), keyRuleNoteText)
        XCTAssertTrue(note(saved: [.agentSessions]) == nil, "a saved ⇧⌥S registers: no note")
        XCTAssertEqual(note(apps: [AppShortcut(target: "com.example.fake", combo: s, name: "Fake App")]),
                       keyRuleNoteText + " Also used by Fake App \u{2014} only one will fire.")
        let clipboardRow = ShortcutCatalog.build(prosperActions: [.clipboard], combos: [:],
                                                 keyRuleChords: [a.chord]).first
        XCTAssertTrue(clipboardRow?.conflictNote == nil, "every other row: no note")
    }
}
