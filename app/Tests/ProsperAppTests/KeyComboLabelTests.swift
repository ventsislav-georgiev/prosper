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

    func testSpaceReturnAndDeleteGlyphs() {
        XCTAssertEqual(combo(kVK_Space, cmdKey).label, "⌘Space")
        XCTAssertEqual(combo(kVK_Return, controlKey | optionKey).label, "⌃⌥↩")
        XCTAssertEqual(combo(kVK_Delete, shiftKey | cmdKey).label, "⇧⌘⌫")
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
