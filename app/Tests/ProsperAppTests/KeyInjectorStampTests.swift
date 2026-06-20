import XCTest
@testable import ProsperApp

/// Guards the ⌘/⌃ ASCII-stamp gate. Stamping a unicode string onto a synthetic
/// command chord fixes native menu matching under a non-Latin layout but breaks
/// Chromium/WebKit accelerators (⌘W stopped closing Slack/Telegram/Safari tabs) —
/// so the stamp must fire ONLY when the live layout is genuinely non-Latin.
final class KeyInjectorStampTests: XCTestCase {
    func testLatinLayoutSkipsStamp() {
        // Layout already produces the ASCII char → bare keycode is correct everywhere.
        XCTAssertFalse(KeyInjector.needsASCIIStamp(asciiChar: "w", layoutChar: "w"))
        XCTAssertFalse(KeyInjector.needsASCIIStamp(asciiChar: "w", layoutChar: "W")) // case-insensitive
    }

    func testNonLatinLayoutStamps() {
        // Bulgarian/Cyrillic W key yields "в" → must override so the menu matches "w".
        XCTAssertTrue(KeyInjector.needsASCIIStamp(asciiChar: "w", layoutChar: "в"))
    }

    func testUnknownLayoutSkipsStamp() {
        // Can't resolve the layout char → don't risk breaking the common (Latin) case.
        XCTAssertFalse(KeyInjector.needsASCIIStamp(asciiChar: "w", layoutChar: nil))
    }
}
