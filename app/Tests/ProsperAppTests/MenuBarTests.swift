import XCTest
import CoreGraphics
@testable import ProsperApp

/// Menu-bar manager math. All load-bearing logic (section assignment, spacing key
/// mapping, reorder destination/apply) lives in the AX-free `MenuBarLogic` /
/// `MenuBarStore` so it can be proven here without touching CGS/AppKit. The hot
/// path itself (a single `NSStatusItem.length` write on reveal/hide) is not
/// modelled here — it has no branching to test — but the classification that feeds
/// the Settings list runs over every item and gets a perf budget below.
final class MenuBarTests: XCTestCase {

    @MainActor
    func testStatusMenuOmitsGlobalAutocompleteAndRefreshesClipboardVisibility() throws {
        let originalClipboardHistoryEnabled = Preferences.clipboardHistoryEnabled
        defer { Preferences.clipboardHistoryEnabled = originalClipboardHistoryEnabled }

        let controller = MenuBarController(
            onOpenRunner: {}, onOpenClipboard: {}, onOpenSettings: {},
            onCheckForUpdates: {}, onRerunSetup: {}, onRestart: {}, onQuit: {})
        let menu = controller.buildMenu()

        XCTAssertFalse(menu.items.contains { $0.title == "Inline Autocomplete" })
        let clipboard = try XCTUnwrap(menu.items.first { $0.title == "Clipboard History\u{2026}" })

        Preferences.clipboardHistoryEnabled = false
        controller.menuWillOpen(menu)
        XCTAssertTrue(clipboard.isHidden)

        Preferences.clipboardHistoryEnabled = true
        controller.menuWillOpen(menu)
        XCTAssertFalse(clipboard.isHidden)
    }

    /// #104: `buildMenu()` reuses controller-owned NSMenuItem instances
    /// (versionItem, clipboardOpenItem, etc.) that `menuWillOpen`/actions
    /// mutate afterwards, rather than allocating fresh ones per call. An
    /// NSMenuItem can only live in one NSMenu at a time, so rebuilding
    /// without detaching those items from their previous menu throws
    /// NSInternalInconsistencyException on the second build. Repeated builds
    /// against the same controller must not throw.
    @MainActor
    func testRepeatedBuildMenuDoesNotThrow() {
        let controller = MenuBarController(
            onOpenRunner: {}, onOpenClipboard: {}, onOpenSettings: {},
            onCheckForUpdates: {}, onRerunSetup: {}, onRestart: {}, onQuit: {})
        // Each call detaches the reused rows from whichever menu currently
        // holds them, so only the LAST built menu is a live, complete menu —
        // earlier ones are expected to end up with holes where those rows
        // used to be. The regression this guards is the throw itself.
        _ = controller.buildMenu()
        _ = controller.buildMenu()
        let latest = controller.buildMenu()
        XCTAssertTrue(latest.items.contains { $0.title == "Restart" })
        XCTAssertTrue(latest.items.contains { $0.title == "Quit" })
        XCTAssertTrue(latest.items.contains { $0.title.hasPrefix("Prosper v") })
    }

    // MARK: - Section assignment (positional, the core of hide/reveal)

    // Items lay out right→left from the screen's right edge: visible band sits at
    // the HIGHEST x, always-hidden at the lowest. Dividers split the bands.
    func testSectionRightOfHiddenIsVisible() {
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 1400, hiddenDividerX: 1000, alwaysHiddenDividerX: 500),
            .visible)
    }

    func testSectionBetweenDividersIsHidden() {
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 750, hiddenDividerX: 1000, alwaysHiddenDividerX: 500),
            .hidden)
    }

    func testSectionLeftOfAlwaysHiddenIsAlwaysHidden() {
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 300, hiddenDividerX: 1000, alwaysHiddenDividerX: 500),
            .alwaysHidden)
    }

    func testSectionWithoutAlwaysHiddenDividerCollapsesToTwoBands() {
        // Two-tier disabled: everything left of the hidden divider is just .hidden.
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 300, hiddenDividerX: 1000, alwaysHiddenDividerX: nil),
            .hidden)
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 1400, hiddenDividerX: 1000, alwaysHiddenDividerX: nil),
            .visible)
    }

    func testSectionBoundaryIsExclusiveOnTheDivider() {
        // Exactly on the divider x → not strictly greater → falls into hidden band.
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 1000, hiddenDividerX: 1000, alwaysHiddenDividerX: nil),
            .hidden)
    }

    // MARK: - Divider length state machine (the show/hide hot path's source of truth)

    // Sentinel widths so the mapping is unambiguous (real code passes
    // NSStatusItem.variableLength for standard and a screen-derived expanded width).
    private let std: CGFloat = -1     // variableLength sentinel
    private let exp: CGFloat = 2120   // screen-derived "push off-screen" width

    func testDividerLengthsHiddenState() {
        // Nothing revealed: both dividers expanded (everything left of them pushed off).
        let l = MenuBarLogic.dividerLengths(revealed: false, revealedAlwaysHidden: false,
                                            standard: std, expanded: exp)
        XCTAssertEqual(l.hidden, exp)
        XCTAssertEqual(l.alwaysHidden, exp)
    }

    func testDividerLengthsHiddenRevealed() {
        // Hidden section revealed, always-hidden still tucked away.
        let l = MenuBarLogic.dividerLengths(revealed: true, revealedAlwaysHidden: false,
                                            standard: std, expanded: exp)
        XCTAssertEqual(l.hidden, std)
        XCTAssertEqual(l.alwaysHidden, exp)
    }

    func testDividerLengthsBothRevealed() {
        // Revealing always-hidden implies the hidden section is shown too → both collapse.
        let l = MenuBarLogic.dividerLengths(revealed: true, revealedAlwaysHidden: true,
                                            standard: std, expanded: exp)
        XCTAssertEqual(l.hidden, std)
        XCTAssertEqual(l.alwaysHidden, std)
    }

    func testDividerLengthsAlwaysHiddenRevealedAloneStillCollapsesIt() {
        // Degenerate combo (revealed=false but revealedAlwaysHidden=true) shouldn't
        // strand the always-hidden divider expanded — its band is driven by its own flag.
        let l = MenuBarLogic.dividerLengths(revealed: false, revealedAlwaysHidden: true,
                                            standard: std, expanded: exp)
        XCTAssertEqual(l.alwaysHidden, std)
    }

    // MARK: - Spacing key mapping

    func testSpacingDefaultClearsOverride() {
        // Writing the macOS default (16) must signal "delete the keys", not pin 16.
        XCTAssertNil(MenuBarLogic.spacingDefaultsValue(forSpacing: MenuBarSpacing.defaultSpacing))
    }

    func testSpacingNonDefaultReturnsValue() {
        XCTAssertEqual(MenuBarLogic.spacingDefaultsValue(forSpacing: 4), 4)
        XCTAssertEqual(MenuBarLogic.spacingDefaultsValue(forSpacing: 0), 0)
    }

    func testSpacingClampsToBounds() {
        XCTAssertEqual(MenuBarLogic.spacingDefaultsValue(forSpacing: -10), MenuBarSpacing.minSpacing)
        XCTAssertEqual(MenuBarLogic.spacingDefaultsValue(forSpacing: 999), MenuBarSpacing.maxSpacing)
    }

    // MARK: - Store: clamping + Codable round-trip + schema downgrade-safety

    func testStoreClamps() {
        var s = MenuBarStore.default
        s.spacing = 500
        s.autoRehideSeconds = 9000
        XCTAssertEqual(s.clampedSpacing, MenuBarSpacing.maxSpacing)
        XCTAssertEqual(s.clampedAutoRehide, 30)
        s.spacing = -5
        s.autoRehideSeconds = 0
        XCTAssertEqual(s.clampedSpacing, MenuBarSpacing.minSpacing)
        XCTAssertEqual(s.clampedAutoRehide, 1)
    }

    func testStoreRoundTrips() throws {
        var s = MenuBarStore.default
        s.spacing = 8
        s.alwaysHiddenEnabled = true
        s.autoRehideEnabled = false
        s.autoRehideSeconds = 12
        s.chevronStyle = .circle
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(MenuBarStore.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testStoreDecodesFromMinimalJSON() throws {
        // A future/old build that wrote only schemaVersion must decode with every
        // other field defaulted (downgrade-safe, mirrors layoutStore behavior).
        let json = #"{"schemaVersion":1}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(MenuBarStore.self, from: json)
        XCTAssertEqual(s.spacing, 3)   // model default (denser than macOS stock 16)
        XCTAssertFalse(s.alwaysHiddenEnabled)
        XCTAssertTrue(s.autoRehideEnabled)
        XCTAssertEqual(s.autoRehideSeconds, 5)
        XCTAssertEqual(s.chevronStyle, .ellipsis)
    }

    // A blob from the old build that still carries the removed reorder/order keys
    // must decode (ignoring them), not fail — the tolerant init drops unknown keys.
    func testStoreIgnoresRemovedReorderKeys() throws {
        let json = #"{"schemaVersion":1,"reorderEnabled":true,"observedOrder":[{"bundleID":"x","slot":0}],"chevronStyle":"arrow"}"#
            .data(using: .utf8)!
        let s = try JSONDecoder().decode(MenuBarStore.self, from: json)
        XCTAssertEqual(s.chevronStyle, .arrow)
    }

    // MARK: - Chevron style (cosmetic glyph mapping)

    func testChevronSymbolsDifferPerStyle() {
        // Every style maps to a distinct collapsed glyph (no two share one), so the
        // picker actually changes the bar.
        let collapsed = ChevronStyle.allCases.map(\.collapsedSymbol)
        XCTAssertEqual(Set(collapsed).count, ChevronStyle.allCases.count)
    }

    // MARK: - Manifest wiring (the declarative section)

    /// Load the shipped extension.toml exactly as the host does. Proves the
    /// manifest parses, identifies as a system extension, and contributes the
    /// "menubar" section — the part of the wiring PROSPER_VERIFY can only check
    /// inside a packaged .app (where the bundled-resources dir classifies the
    /// folder as system). #119: the reveal shortcut is no longer a manifest
    /// control — it only lives in Settings › Shortcuts — so this section has no
    /// declarative controls of its own; the rich UI is the native MenuBarPane
    /// footer merged in by SettingsRootView.
    func testManifestParsesWithSection() throws {
        let dir = URL(fileURLWithPath: #filePath)        // .../Tests/ProsperAppTests/MenuBarTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions/menubar")
        let loaded = try ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: "0.0.0")
        XCTAssertEqual(loaded.manifest.extension.id, "com.prosper.menubar")
        XCTAssertEqual(loaded.manifest.extension.isSystem, true)

        let sections = loaded.manifest.contributes?.allSettingsSections ?? []
        let section = sections.first { $0.id == "menubar" }
        XCTAssertNotNil(section, "menubar settings section missing")
        XCTAssertEqual(section?.accent, "Menu Bar")
        XCTAssertEqual(section?.allControls ?? [], [],
                       "reveal shortcut must stay out of the manifest (#119)")
    }

    /// The reveal shortcut's action name must still resolve to a real
    /// ShortcutAction owned by this extension, even with no manifest control
    /// naming it — otherwise the Shortcuts catalog row binds nothing.
    func testRevealShortcutActionBinding() {
        let action = ShortcutAction(rawValue: "menuBarToggleHidden")
        XCTAssertNotNil(action, "menuBarToggleHidden is not a ShortcutAction rawValue")
        XCTAssertEqual(action?.owningExtensionID, "com.prosper.menubar")
    }

    // MARK: - Perf budget (cold path: reveal + Settings render)

    /// Section classification feeds the Settings list and runs once per reveal over
    /// every menu-bar item. Even an absurd 200-item bar must classify in well under
    /// the ≤ 2 ms warm-enumeration budget, leaving headroom for the CGS calls.
    func testSectionClassificationIsCheap() {
        let xs = (0..<200).map { CGFloat($0 * 7) }
        measure {
            for _ in 0..<1000 {
                for x in xs {
                    _ = MenuBarLogic.section(forItemX: x, hiddenDividerX: 700, alwaysHiddenDividerX: 350)
                }
            }
        }
    }

    // MARK: - Hosted (macOS 27+) fit math

    func testDropLengthStaysInsideTheRoomButAboveAppleItems() {
        let room: CGFloat = 771.5   // 16" notched display, measured on macOS 27.0
        let len = MenuBarLogic.dropLength(room: room)
        XCTAssertLessThan(len, room, "wider than the room drops the divider alone and leaves the band visible")
        XCTAssertGreaterThan(len, room - 136, "narrower than room minus Apple's items parks the band behind the OS « button")
        XCTAssertEqual(MenuBarLogic.dropLength(room: 10), 0, "never negative")
    }
}
