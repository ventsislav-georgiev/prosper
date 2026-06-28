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
        s.reorderEnabled = true
        s.hoverReveal = true
        s.autoRehideSeconds = 12
        s.observedOrder = [MenuBarItemInfo(bundleID: "com.a", slot: 0),
                           MenuBarItemInfo(bundleID: "com.a", slot: 1),
                           MenuBarItemInfo(bundleID: "com.b", slot: 0)]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(MenuBarStore.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testStoreDecodesFromMinimalJSON() throws {
        // A future/old build that wrote only schemaVersion must decode with every
        // other field defaulted (downgrade-safe, mirrors layoutStore behavior).
        let json = #"{"schemaVersion":1}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(MenuBarStore.self, from: json)
        XCTAssertEqual(s.spacing, MenuBarSpacing.defaultSpacing)
        XCTAssertFalse(s.alwaysHiddenEnabled)
        XCTAssertFalse(s.reorderEnabled)
        XCTAssertEqual(s.autoRehideSeconds, 5)
        XCTAssertTrue(s.observedOrder.isEmpty)
    }

    // MARK: - Reorder destination + apply math (the planner; executor is gated off)

    private let order = [MenuBarItemInfo(bundleID: "a"),
                         MenuBarItemInfo(bundleID: "b"),
                         MenuBarItemInfo(bundleID: "c"),
                         MenuBarItemInfo(bundleID: "d")]

    func testInsertionIndexLeftOf() {
        let i = MenuBarLogic.reorderInsertionIndex(
            moving: order[3], toLeftOf: order[1], in: order)   // d to left of b
        XCTAssertEqual(i, 1)
    }

    func testInsertionIndexRightOf() {
        let i = MenuBarLogic.reorderInsertionIndex(
            moving: order[0], toRightOf: order[2], in: order)   // a to right of c
        XCTAssertEqual(i, 3)
    }

    func testInsertionIndexMissingItemReturnsNil() {
        let ghost = MenuBarItemInfo(bundleID: "zzz")
        XCTAssertNil(MenuBarLogic.reorderInsertionIndex(moving: ghost, toLeftOf: order[0], in: order))
        XCTAssertNil(MenuBarLogic.reorderInsertionIndex(moving: order[0], toLeftOf: ghost, in: order))
    }

    func testApplyMoveForward() {
        // Move "a" to index 3 (right of c). Removing a first shifts the index down.
        let out = MenuBarLogic.applyMove(order[0], toIndex: 3, in: order)
        XCTAssertEqual(out.map(\.bundleID), ["b", "c", "a", "d"])
    }

    func testApplyMoveBackward() {
        // Move "d" to index 1 (left of b). Index is before the removed item → no shift.
        let out = MenuBarLogic.applyMove(order[3], toIndex: 1, in: order)
        XCTAssertEqual(out.map(\.bundleID), ["a", "d", "b", "c"])
    }

    func testApplyMoveClampsOutOfRange() {
        let out = MenuBarLogic.applyMove(order[0], toIndex: 999, in: order)
        XCTAssertEqual(out.map(\.bundleID), ["b", "c", "d", "a"])
    }

    func testApplyMoveMissingItemIsIdentity() {
        let ghost = MenuBarItemInfo(bundleID: "zzz")
        XCTAssertEqual(MenuBarLogic.applyMove(ghost, toIndex: 0, in: order), order)
    }

    // MARK: - Manifest wiring (the declarative section + reveal shortcut)

    /// Load the shipped extension.toml exactly as the host does. Proves the
    /// manifest parses, identifies as a system extension, and contributes the
    /// "menubar" section with the rebindable reveal shortcut — the part of the
    /// wiring PROSPER_VERIFY can only check inside a packaged .app (where the
    /// bundled-resources dir classifies the folder as system).
    func testManifestParsesWithSectionAndShortcut() throws {
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

        let shortcut = section?.allControls.first { $0.kind == .shortcut }
        XCTAssertEqual(shortcut?.name, "menuBarToggleHidden",
                       "reveal shortcut must bind to the menuBarToggleHidden action")
    }

    /// The manifest's shortcut `name` must resolve to a real ShortcutAction owned
    /// by this extension — otherwise the recorder renders but binds nothing.
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
}
