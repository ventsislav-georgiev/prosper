import XCTest
@testable import ProsperApp

/// Pure halves of `MenuCommandIndex`: the shortcut glyph decode, the cache
/// policy, and the generation-tagged row ids. The AX walk itself needs a live
/// menu bar and an Accessibility grant, so it's manual QA, not CI.
final class MenuCommandIndexTests: XCTestCase {

    // MARK: - MenuShortcut.format

    /// bit3 *set* means the item has no ⌘ — the inversion is the one piece of
    /// copied logic a refactor is most likely to get backwards.
    func testShortcutGlyphs() {
        let cases: [(String?, Int, String?)] = [
            ("s", 0x00, "⌘S"),          // plain command
            ("e", 0x01, "⇧⌘E"),         // shift
            ("f", 0x03, "⌥⇧⌘F"),        // option + shift
            ("f", 0x07, "⌃⌥⇧⌘F"),       // all three plus command
            ("f", 0x08, "F"),           // bit3 set → no command at all
            ("x", 0x09, "⇧X"),          // shift, still no command
            ("s", 0x04, "⌃⌘S"),         // control
            (nil, 0x00, nil),           // no key equivalent
            ("", 0x00, nil),            // empty char is not a shortcut
        ]
        for (char, mods, expected) in cases {
            XCTAssertEqual(MenuShortcut.format(char: char, modifiers: mods), expected,
                           "char=\(char ?? "nil") mods=\(mods)")
        }
    }

    func testShortcutUppercasesCharacter() {
        XCTAssertEqual(MenuShortcut.format(char: "z", modifiers: 0), "⌘Z")
    }

    // MARK: - Cache policy

    func testWarmSkippedInsideTTL() {
        let now = Date()
        XCTAssertFalse(MenuCommandIndex.needsWalk(requested: 42, cached: 42,
                                                  loadedAt: now.addingTimeInterval(-1),
                                                  loading: false, now: now))
    }

    func testWarmRunsAfterTTL() {
        let now = Date()
        let stale = now.addingTimeInterval(-(MenuCommandIndex.ttl + 0.1))
        XCTAssertTrue(MenuCommandIndex.needsWalk(requested: 42, cached: 42,
                                                 loadedAt: stale,
                                                 loading: false, now: now))
    }

    func testWarmRunsOnPidChangeEvenInsideTTL() {
        let now = Date()
        XCTAssertTrue(MenuCommandIndex.needsWalk(requested: 43, cached: 42,
                                                 loadedAt: now, loading: false, now: now))
    }

    func testWarmRunsWhenNothingCached() {
        let now = Date()
        XCTAssertTrue(MenuCommandIndex.needsWalk(requested: 42, cached: nil,
                                                 loadedAt: .distantPast,
                                                 loading: false, now: now))
    }

    func testWarmSkippedWhileLoading() {
        let now = Date()
        XCTAssertFalse(MenuCommandIndex.needsWalk(requested: 43, cached: 42,
                                                  loadedAt: .distantPast,
                                                  loading: true, now: now))
    }

    // MARK: - Row ids

    func testDecodeIndexAcceptsCurrentGeneration() {
        XCTAssertEqual(MenuCommandIndex.decodeIndex("3:17", generation: 3), 17)
        XCTAssertEqual(MenuCommandIndex.decodeIndex("0:0", generation: 0), 0)
    }

    func testDecodeIndexRejectsStaleGeneration() {
        XCTAssertNil(MenuCommandIndex.decodeIndex("2:17", generation: 3))
        XCTAssertNil(MenuCommandIndex.decodeIndex("4:17", generation: 3))
    }

    func testDecodeIndexRejectsMalformedIDs() {
        for bad in ["", "17", "3:", ":17", "3:x", "x:17", "3:-1", "3:17:0"] {
            XCTAssertNil(MenuCommandIndex.decodeIndex(bad, generation: 3), bad)
        }
    }

    @MainActor
    func testPressRejectsUnknownID() {
        // Nothing walked yet: generation 0, no elements — every id is unpressable,
        // so a stale row can never fire an AX action into the wrong app.
        let index = MenuCommandIndex()
        XCTAssertFalse(index.press(id: "0:0"))
        XCTAssertFalse(index.press(id: "9:0"))
        XCTAssertFalse(index.press(id: "nonsense"))
    }

    // MARK: - Row shape

    func testBreadcrumbJoinsPathAndTitle() {
        let row = MenuCommand(id: "1:4", path: ["Format", "Font"], title: "Bold", shortcut: "⌘B")
        XCTAssertEqual(row.breadcrumb, "Format › Font › Bold")
        XCTAssertEqual(MenuCommand(id: "1:0", path: ["File"], title: "Open…", shortcut: nil)
                        .breadcrumb, "File › Open…")
    }

    @MainActor
    func testCachedJSONIsAnArrayWhenEmpty() {
        XCTAssertEqual(MenuCommandIndex().cachedJSON(), "[]")
        XCTAssertTrue(MenuCommandIndex().cached().isEmpty)
    }

    func testMenuCommandRoundTripsThroughJSON() throws {
        let row = MenuCommand(id: "2:7", path: ["File"], title: "Export as PDF…", shortcut: "⇧⌘E")
        let data = try JSONEncoder().encode([row])
        XCTAssertEqual(try JSONDecoder().decode([MenuCommand].self, from: data), [row])
    }
}
