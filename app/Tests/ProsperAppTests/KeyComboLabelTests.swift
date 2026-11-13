import XCTest
import Carbon
@testable import ProsperApp

/// `KeyCombo.label` is the one formatter every user-visible combo display routes
/// through — it must never trust the stored `display` string (see its doc comment:
/// a manifest default parsed via `KeyCombo.parse` keeps raw source text like
/// "cmd+alt+ctrl+k" there instead of glyphs). Pure, so it's provable with no
/// Carbon/AppKit event needed.
final class KeyComboLabelTests: XCTestCase {

    private func combo(_ key: Int, _ mods: Int, display: String = "ignored") -> KeyCombo {
        KeyCombo(keyCode: UInt32(key), carbonModifiers: UInt32(mods), display: display)
    }

    func testUnsetCombo() {
        XCTAssertEqual(unsetKeyCombo.label, "Unset")
    }

    func testBareKeyNoModifierIsNotUnset() {
        // No modifier but a real key isn't the sentinel unset combo — it renders
        // as just the key (registration elsewhere still refuses to claim it).
        XCTAssertEqual(combo(kVK_F5, 0).label, "F5")
    }

    func testSingleModifier() {
        XCTAssertEqual(combo(kVK_ANSI_L, optionKey).label, "⌥L")
    }

    func testModifiersRenderInMacOSOrder() {
        // ⌃⌥⇧⌘ regardless of the order the bits were combined in.
        let mods = shiftKey | cmdKey | controlKey | optionKey
        XCTAssertEqual(combo(kVK_ANSI_K, mods).label, "⌃⌥⇧⌘K")
    }

    func testAllFiveModifiersChord() {
        // "All five": every modifier plus the key itself.
        let mods = controlKey | optionKey | shiftKey | cmdKey
        XCTAssertEqual(combo(kVK_ANSI_A, mods).label, "⌃⌥⇧⌘A")
    }

    func testArrowGlyphs() {
        XCTAssertEqual(combo(kVK_LeftArrow, controlKey | optionKey).label, "⌃⌥←")
        XCTAssertEqual(combo(kVK_RightArrow, controlKey | optionKey).label, "⌃⌥→")
        XCTAssertEqual(combo(kVK_UpArrow, controlKey | optionKey).label, "⌃⌥↑")
        XCTAssertEqual(combo(kVK_DownArrow, controlKey | optionKey).label, "⌃⌥↓")
    }

    /// #876: the names were too wide for the key-rule field; the glyphs macOS menus use.
    func testPageUpAndPageDownGlyphs() {
        XCTAssertEqual(combo(kVK_PageUp, cmdKey).label, "⌘⇞")
        XCTAssertEqual(combo(kVK_PageDown, controlKey | optionKey | shiftKey | cmdKey).label, "⌃⌥⇧⌘⇟")
    }

    func testSpaceReturnAndDeleteGlyphs() {
        XCTAssertEqual(combo(kVK_Space, cmdKey).label, "⌘Space")
        XCTAssertEqual(combo(kVK_Return, controlKey | optionKey).label, "⌃⌥↩")
        XCTAssertEqual(combo(kVK_Delete, shiftKey | cmdKey).label, "⇧⌘⌫")
    }

    /// #890: the glyphs macOS menus draw for Home, End, keypad Enter and Clear; Help and
    /// the keypad keys by name or key cap, never "Key<n>".
    func testHomeEndKeypadAndHelpGlyphs() {
        XCTAssertEqual(combo(kVK_Home, cmdKey).label, "⌘\u{2196}")
        XCTAssertEqual(combo(kVK_End, cmdKey).label, "⌘\u{2198}")
        XCTAssertEqual(combo(kVK_ANSI_KeypadEnter, controlKey | optionKey | shiftKey | cmdKey).label, "⌃⌥⇧⌘\u{2324}")
        XCTAssertEqual(combo(kVK_ANSI_KeypadClear, cmdKey).label, "⌘\u{2327}")
        XCTAssertEqual(combo(kVK_Help, cmdKey).label, "⌘Help")
        XCTAssertEqual(combo(kVK_ANSI_Keypad1, cmdKey).label, "⌘Pad1")
        XCTAssertEqual(combo(kVK_ANSI_KeypadEquals, cmdKey).label, "⌘Pad=")
        XCTAssertEqual(combo(kVK_JIS_KeypadComma, cmdKey).label, "⌘Pad,")
        XCTAssertEqual(combo(kVK_JIS_Kana, cmdKey).label, "⌘かな")
    }

    /// Every key with a name (a glyph entry or a `codeToName` name) draws it, not "Key<n>".
    func testNoNamedKeyFallsBackToKeyNumber() {
        for code in Set(KeyCombo.keyNames.keys).union(KeyCombo.codeToName.keys) {
            XCTAssertFalse(combo(code, cmdKey).label.contains("Key"), "\(code): \(combo(code, cmdKey).label)")
        }
    }

    /// #890 r2: no two key codes draw the same key, or the Settings field and the conflict
    /// notice name a key the user did not bind (a bare "1" for keypad 1 read as the top row).
    func testNoTwoKeyCodesDrawTheSameLabel() {
        var codesByLabel: [String: [Int]] = [:]
        for code in 0..<128 { codesByLabel[combo(code, cmdKey).label, default: []].append(code) }
        let duplicates = codesByLabel.filter { $0.value.count > 1 }.map { "\($0.key): \($0.value.sorted())" }.sorted()
        XCTAssertEqual(duplicates, [])
    }

    /// The drawn label changed; the stored form did not: parse and the spec string still
    /// say "home" / "end".
    func testHomeAndEndStoredFormUnchanged() throws {
        for (name, code) in [("home", kVK_Home), ("end", kVK_End)] {
            let parsed = try XCTUnwrap(KeyCombo.parse("cmd+\(name)"))
            XCTAssertEqual(parsed.keyCode, UInt32(code))
            XCTAssertEqual(parsed.specString, "cmd+\(name)")
        }
    }

    /// #890: the words VoiceOver reads for the recorder. Modifiers in the order macOS
    /// speaks them (Control Option Shift Command), letters and digits as themselves.
    func testSpokenLabelTable() {
        let all = controlKey | optionKey | shiftKey | cmdKey
        let rows: [(KeyCombo, String)] = [
            (unsetKeyCombo, "Unset"),
            (combo(kVK_PageUp, all), "Control Option Shift Command Page Up"),
            (combo(kVK_ANSI_K, cmdKey | shiftKey), "Shift Command K"),
            (combo(kVK_ANSI_K, optionKey | controlKey), "Control Option K"),
            (combo(kVK_ANSI_5, controlKey), "Control 5"),
            (combo(kVK_F5, optionKey), "Option F5"),
            (combo(kVK_Space, cmdKey), "Command Space"),
            (combo(kVK_Return, controlKey | optionKey), "Control Option Return"),
            (combo(kVK_Home, cmdKey), "Command Home"),
            (combo(kVK_End, shiftKey | cmdKey), "Shift Command End"),
            (combo(kVK_ANSI_KeypadEnter, cmdKey), "Command Keypad Enter"),
            (combo(kVK_ANSI_Keypad1, cmdKey), "Command Keypad 1"),
            (combo(kVK_LeftArrow, controlKey | optionKey), "Control Option Left Arrow"),
        ]
        for (c, words) in rows { XCTAssertEqual(c.spokenLabel, words, c.label) }
    }

    /// Every glyph key has English words: the spoken label carries no glyph.
    func testEveryGlyphKeyHasWords() {
        let plain = CharacterSet.alphanumerics.union(.whitespaces)
        for (code, names) in KeyCombo.keyNames {
            let spoken = combo(code, cmdKey).spokenLabel
            XCTAssertEqual(spoken, "Command \(names.words)")
            XCTAssertTrue(spoken.unicodeScalars.allSatisfy { $0.isASCII && plain.contains($0) }, "\(code): \(spoken)")
        }
        // Letters and digits read as themselves.
        XCTAssertEqual(combo(kVK_ANSI_Z, cmdKey).spokenLabel, "Command Z")
        XCTAssertEqual(combo(kVK_ANSI_0, cmdKey).spokenLabel, "Command 0")
    }

    func testManifestSourcedComboIgnoresStoredDisplay() {
        // The exact on-device symptom: a manifest default parsed from TOML source
        // text, e.g. "cmd+alt+ctrl+k". `display` keeps that raw string, but
        // `label` must derive glyphs from keyCode + carbonModifiers instead.
        guard let parsed = KeyCombo.parse("cmd+alt+ctrl+k") else {
            XCTFail("expected \"cmd+alt+ctrl+k\" to parse")
            return
        }
        XCTAssertEqual(parsed.display, "cmd+alt+ctrl+k")
        XCTAssertEqual(parsed.label, "⌃⌥⌘K")
    }
}
