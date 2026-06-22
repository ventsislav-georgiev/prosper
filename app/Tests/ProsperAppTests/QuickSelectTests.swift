import XCTest
@testable import ProsperApp

/// Unit + performance tests for the numbered quick-select shortcuts shared by the
/// clipboard history panel (⌘1…⌘0) and the runner (⌘1…⌘5): the pure keycode→slot
/// mapping and the user-configurable modifier preference.
///
/// Hot-path contract: `QuickSelect.slot` runs once per keyDown while a panel is
/// open (including every character typed into the search field), so it must be a
/// branch-only switch with no allocation and a sub-microsecond cost. The perf
/// tests below pin that budget.
final class QuickSelectTests: XCTestCase {

    private static let key = "quickSelectModifier"
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: Self.key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: Self.key) }
        else { UserDefaults.standard.removeObject(forKey: Self.key) }
        super.tearDown()
    }

    // MARK: - Mapping correctness

    /// ANSI US top-row digit key codes, in the 1,2,…,9,0 order the slots map to.
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    func testSlotMapsEveryDigitInVisualOrder() {
        for (expectedSlot, keyCode) in Self.digitKeyCodes.enumerated() {
            XCTAssertEqual(QuickSelect.slot(forKeyCode: keyCode), expectedSlot,
                           "keyCode \(keyCode) should map to slot \(expectedSlot)")
        }
    }

    func testSlotIsNilForNonDigitKeys() {
        // Letters, Return, Esc, arrows, modifiers, keypad — none are quick-select.
        for keyCode: UInt16 in [0, 8, 36, 53, 125, 126, 49, 48, 51, 76, 82, 100] {
            XCTAssertNil(QuickSelect.slot(forKeyCode: keyCode),
                         "keyCode \(keyCode) must not map to a slot")
        }
    }

    func testSlotCoversExactlyTenKeyCodes() {
        let mapped = (UInt16(0)...255).compactMap { QuickSelect.slot(forKeyCode: $0) }
        XCTAssertEqual(mapped.count, 10, "exactly the ten digit keys map")
        XCTAssertEqual(Set(mapped), Set(0...9), "slots are 0…9 with no gaps or dupes")
    }

    /// The runner only honours the top five (it guards `slot < 5`); verify the
    /// first five digit keys land in 0…4 so that guard selects 1…5 as intended.
    func testRunnerTopFiveAreTheFirstFiveDigits() {
        let topFive = Self.digitKeyCodes.prefix(5).compactMap { QuickSelect.slot(forKeyCode: $0) }
        XCTAssertEqual(topFive, [0, 1, 2, 3, 4])
    }

    // MARK: - Modifier matching (capsLock-tolerant, exact among real modifiers)

    func testModifierMatchesExactSingleModifier() {
        XCTAssertTrue(QuickSelect.modifierMatches(.command, expected: .command))
        XCTAssertTrue(QuickSelect.modifierMatches(.control, expected: .control))
        XCTAssertFalse(QuickSelect.modifierMatches(.command, expected: .control))
    }

    func testModifierMatchIgnoresCapsLockAndFn() {
        // Caps Lock or fn held alongside the shortcut must NOT block it.
        XCTAssertTrue(QuickSelect.modifierMatches([.command, .capsLock], expected: .command))
        XCTAssertTrue(QuickSelect.modifierMatches([.command, .function], expected: .command))
        XCTAssertTrue(QuickSelect.modifierMatches([.control, .capsLock, .function],
                                                  expected: .control))
    }

    func testModifierMatchRejectsExtraRealModifiers() {
        // ⌘⌥1 / ⌃⇧1 must fall through to normal editing, not trigger quick-select.
        XCTAssertFalse(QuickSelect.modifierMatches([.command, .option], expected: .command))
        XCTAssertFalse(QuickSelect.modifierMatches([.control, .shift], expected: .control))
        XCTAssertFalse(QuickSelect.modifierMatches([], expected: .command))
    }

    // MARK: - Modifier preference

    func testModifierGlyphsAndTitles() {
        XCTAssertEqual(QuickSelectModifier.command.glyph, "\u{2318}")  // ⌘
        XCTAssertEqual(QuickSelectModifier.control.glyph, "\u{2303}")  // ⌃
        XCTAssertTrue(QuickSelectModifier.command.title.contains("⌘"))
        XCTAssertTrue(QuickSelectModifier.control.title.contains("⌃"))
    }

    func testPreferenceDefaultsToCommand() {
        UserDefaults.standard.removeObject(forKey: "quickSelectModifier")
        XCTAssertEqual(Preferences.quickSelectModifier, .command,
                       "default modifier must be Command")
    }

    func testPreferenceRoundTrips() {
        Preferences.quickSelectModifier = .control
        XCTAssertEqual(Preferences.quickSelectModifier, .control)
        Preferences.quickSelectModifier = .command
        XCTAssertEqual(Preferences.quickSelectModifier, .command)
    }

    func testPreferenceHealsCorruptValue() {
        UserDefaults.standard.set("bogus", forKey: "quickSelectModifier")
        XCTAssertEqual(Preferences.quickSelectModifier, .command,
                       "unknown stored value falls back to the default")
    }

    // MARK: - Performance (hot path)

    /// `slot` is on the per-keystroke path. Budget: < 250 ns/call. This runs in an
    /// unoptimized `swift test` build (a release switch is single-digit ns), so the
    /// ceiling is set above the ~90 ns debug cost — loose enough to be stable on a
    /// slow CI box, tight enough that an allocation or hashing regression trips it.
    func testSlotLookupMeetsHotPathBudget() {
        let codes = Self.digitKeyCodes
        let iterations = 1_000_000
        var sink = 0
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            if let s = QuickSelect.slot(forKeyCode: codes[i % codes.count]) { sink &+= s }
        }
        let nsPerCall = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1e9
        XCTAssertGreaterThan(sink, 0)  // defeat dead-code elimination
        XCTAssertLessThan(nsPerCall, 250, "slot() took \(nsPerCall) ns/call (budget 250 ns)")
    }

    /// The full per-keystroke decision = read the modifier pref + map the keycode.
    /// Budget: < 1 µs/keystroke. Reads UserDefaults each call (its in-memory cache
    /// keeps this cheap); the test proves we don't need to add our own cache.
    func testPerKeystrokeDecisionMeetsBudget() {
        Preferences.quickSelectModifier = .command
        let codes = Self.digitKeyCodes
        let iterations = 100_000
        var sink = 0
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            let flagIsCommand = Preferences.quickSelectModifier == .command
            if flagIsCommand, let s = QuickSelect.slot(forKeyCode: codes[i % codes.count]) {
                sink &+= s
            }
        }
        let nsPerCall = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1e9
        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(nsPerCall, 1_000, "decision took \(nsPerCall) ns (budget 1000 ns)")
    }
}
