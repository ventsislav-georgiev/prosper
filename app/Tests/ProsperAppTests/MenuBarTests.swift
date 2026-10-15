import XCTest
import CoreGraphics
import AppKit
@testable import ProsperApp

/// Menu-bar manager math. All load-bearing logic (divider lengths, spacing key
/// mapping) lives in the AX-free `MenuBarLogic` / `MenuBarStore` so it can be
/// proven here without touching CGS/AppKit. The hot path itself (a single
/// `NSStatusItem.length` write on reveal/hide) has no branching to test.
final class MenuBarTests: XCTestCase {

    @MainActor
    func testStatusMenuOmitsGlobalAutocompleteAndRefreshesClipboardVisibility() throws {
        let originalClipboardHistoryEnabled = Preferences.clipboardHistoryEnabled
        defer { Preferences.clipboardHistoryEnabled = originalClipboardHistoryEnabled }

        let controller = MenuBarController(
            onOpenRunner: {}, onOpenClipboard: {}, onOpenSettings: {},
            onCheckForUpdates: {}, onRerunSetup: {}, onRestart: {}, onQuit: {}, statusBar: NSStatusBar())
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
            onCheckForUpdates: {}, onRerunSetup: {}, onRestart: {}, onQuit: {}, statusBar: NSStatusBar())
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

    /// #342/#344: Sparkle's SUHost writes SU* keys into Bundle.main's standard defaults, which
    /// under XCTest is the real `com.apple.dt.xctest.tool` domain. Write-free: snapshot the SU*
    /// keys visible through `.standard` (incl. NSGlobalDomain), build the menu and a fresh
    /// `AppUpdater()`, and require names and values unchanged.
    @MainActor
    func testStatusMenuLeavesNoSparkleKeysInTheXCTestDomain() {
        let suKeys = { NSDictionary(dictionary: UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("SU") }) }
        let before = suKeys()
        let controller = MenuBarController(
            onOpenRunner: {}, onOpenClipboard: {}, onOpenSettings: {},
            onCheckForUpdates: {}, onRerunSetup: {}, onRestart: {}, onQuit: {}, statusBar: NSStatusBar())
        _ = controller.buildMenu()
        let updater = AppUpdater()
        XCTAssertFalse(updater.isConfigured, "SPUUpdater must not be built under XCTest")
        XCTAssertEqual(suKeys(), before, "Sparkle wrote the xctest defaults domain (names or values)")
    }

    /// QA OQ-6: a controller built on a private bar owns its item there, never on the system bar.
    @MainActor
    func testControllerOnPrivateBarKeepsItsItemOffTheSystemBar() {
        let bar = NSStatusBar()
        let controller = MenuBarController(
            onOpenRunner: {}, onOpenClipboard: {}, onOpenSettings: {},
            onCheckForUpdates: {}, onRerunSetup: {}, onRestart: {}, onQuit: {}, statusBar: bar)
        defer { bar.removeStatusItem(controller.statusItem) }
        XCTAssertTrue(controller.statusItem.statusBar === bar, "item not on the injected bar")
        XCTAssertFalse(controller.statusItem.statusBar === NSStatusBar.system, "item landed on the system bar")
    }

    /// #344: a Sparkle updater is constructed in exactly one place, on the XCTestCase-gated line.
    /// #385 (QA #155): `SPUUpdater(`, `SPUUpdater.init(` and `SPUStandardUpdaterController(` all count.
    func testSPUUpdaterIsOnlyBuiltBehindTheXCTestGate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            where line.contains(/SPU(Updater|StandardUpdaterController)\s*(\.\s*init\s*)?\(/) {
                hits.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(hits, ["AppUpdater.swift: updater = NSClassFromString(\"XCTestCase\") != nil ? nil : SPUUpdater("])
    }

    /// #385 (QA #153): with no SPUUpdater under XCTest, `automaticChecks` lives in
    /// `Preferences.automaticUpdateChecks` (the scratch suite): the setter writes it, the getter reads it.
    @MainActor
    func testAutomaticChecksPersistsToPreferencesWithoutAnUpdater() {
        let key = "automaticUpdateChecks", saved = Preferences.defaults.object(forKey: key)
        let updater = AppUpdater()
        defer {
            updater.automaticChecks = false   // stops the poll timer the `true` write started
            Preferences.defaults.set(saved, forKey: key)
        }
        XCTAssertFalse(updater.isConfigured)
        updater.automaticChecks = false
        XCTAssertFalse(Preferences.automaticUpdateChecks)
        XCTAssertFalse(updater.automaticChecks)
        updater.automaticChecks = true
        XCTAssertTrue(Preferences.automaticUpdateChecks)
        XCTAssertTrue(updater.automaticChecks)
    }

    // MARK: - Divider length state machine (the show/hide hot path's source of truth)

    // Sentinel widths so the mapping is unambiguous (real code passes
    // NSStatusItem.variableLength for standard and a screen-derived expanded width).
    private let std: CGFloat = -1     // variableLength sentinel
    private let exp: CGFloat = 2120   // screen-derived "push off-screen" width

    func testDividerLengthHiddenState() {
        // Collapsed: the divider is expanded (everything left of it pushed off).
        XCTAssertEqual(MenuBarLogic.dividerLength(revealed: false, standard: std, expanded: exp), exp)
    }

    func testDividerLengthRevealed() {
        // Revealed: the divider shrinks back to a normal item.
        XCTAssertEqual(MenuBarLogic.dividerLength(revealed: true, standard: std, expanded: exp), std)
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

    // #398: a blob written while the always-hidden section existed still carries its
    // gate key; the store no longer has that field, so the key is ignored, not fatal.
    func testStoreIgnoresRemovedSecondDividerKey() throws {
        let json = Data(#"{"schemaVersion":1,"spacing":7,"alwaysHiddenEnabled":true,"chevronStyle":"circle"}"#.utf8)
        let s = try JSONDecoder().decode(MenuBarStore.self, from: json)
        XCTAssertEqual(s.spacing, 7)
        XCTAssertEqual(s.chevronStyle, .circle)
        XCTAssertEqual(s, { var e = MenuBarStore.default; e.spacing = 7; e.chevronStyle = .circle; return e }())
    }

    // MARK: - #132 / #398: leftover menu-bar state is deleted once

    /// QA #217: the cleanup's only key source is this list, so over-deletion of a live
    /// item's position or visibility memory fails here, whatever the autosave name.
    func testMenuBarCleanupRemovesExactlyTheFourDeadKeys() {
        XCTAssertEqual(Preferences.menuBarCleanupKeys, [
            "menuBarOrderStoreJSON", "menuBarOrderStoreBackupJSON",
            "NSStatusItem Preferred Position ProsperMenuBarAlwaysHiddenSeparator",
            "NSStatusItem Visible ProsperMenuBarAlwaysHiddenSeparator",
        ], "the migration runs every launch: any new key here must be dead state and must be added to this list on purpose")
    }

    /// #154: both ordering-engine blobs are deleted (also with a corrupt primary), and
    /// #398: so is macOS's position memory for the removed second divider.
    func testOrderStoreMigrationReadsAndDeletesTheBackup() {
        let d = Preferences.defaults
        let position = "NSStatusItem Preferred Position ProsperMenuBarAlwaysHiddenSeparator"
        let visible = "NSStatusItem Visible ProsperMenuBarAlwaysHiddenSeparator"
        // QA #217: keys AppKit keeps for the status items that still exist must survive.
        let survivors: [(String, Any)] = [
            ("NSStatusItem Preferred Position ProsperMenuBarHiddenSeparator", 321.5),
            ("NSStatusItem Visible ProsperMenuBarChevron", false),
            ("NSStatusItem Preferred Position ProsperLauncher", 654.25),
        ]
        let keys = ["menuBarStoreJSON", "menuBarOrderStoreJSON", "menuBarOrderStoreBackupJSON", position, visible]
            + survivors.map { $0.0 }
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        let blob = Data(#"{"schemaVersion":1,"desiredOrder":[]}"#.utf8)

        for primary in [nil, Data("corrupt".utf8)] {
            d.set(primary, forKey: "menuBarOrderStoreJSON")
            d.set(blob, forKey: "menuBarOrderStoreBackupJSON")
            d.set(1234.0, forKey: position)
            d.set(false, forKey: visible)
            for (k, v) in survivors { d.set(v, forKey: k) }
            // QA #215: the user's live store must survive the cleanup.
            let live = { var e = MenuBarStore.default; e.spacing = 9; e.chevronStyle = .circle; return e }()
            Preferences.menuBarStore = live
            let liveData = d.data(forKey: "menuBarStoreJSON")
            XCTAssertNotNil(liveData)
            Preferences.migrateMenuBarOrderStore()
            XCTAssertEqual(Preferences.menuBarStore, live, "live store must survive")
            XCTAssertEqual(d.data(forKey: "menuBarStoreJSON"), liveData, "live store bytes must be unchanged")
            XCTAssertNil(d.object(forKey: "menuBarOrderStoreJSON"))
            XCTAssertNil(d.object(forKey: "menuBarOrderStoreBackupJSON"), "backup must go too (primary \(String(describing: primary)))")
            XCTAssertNil(d.object(forKey: position), "removed divider's position memory must go")
            XCTAssertNil(d.object(forKey: visible), "removed divider's visibility memory must go")
            for (k, v) in survivors {
                XCTAssertEqual(d.object(forKey: k) as? NSObject, v as? NSObject, "\(k) must survive")
            }
        }
    }

    /// #154 / QA #5 (3): the manager feeds its own `revealed` into the length math.
    /// No status items: a bare manager, never `reconcile()`d.
    @MainActor
    func testManagerPassesRevealedToDividerLengths() {
        let m = MenuBarManager()
        m.revealed = true
        XCTAssertEqual(m.dividerLengths(room: 1000), NSStatusItem.variableLength)
        m.revealed = false
        // Hosted (macOS 27+): just under the 1000 pt room; windowed: past the screen edge.
        let want = MenuBarHost.isHosted ? MenuBarLogic.dropLength(room: 1000) : (NSScreen.main?.frame.width ?? 2000) + 200
        XCTAssertEqual(m.dividerLengths(room: 1000), want, "hidden band must follow `revealed`")
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

    // MARK: - Hosted (macOS 27+) fit math

    func testDropLengthStaysInsideTheRoomButAboveAppleItems() {
        let room: CGFloat = 771.5   // 16" notched display, measured on macOS 27.0
        let len = MenuBarLogic.dropLength(room: room)
        XCTAssertLessThan(len, room, "wider than the room drops the divider alone and leaves the band visible")
        XCTAssertGreaterThan(len, room - 136, "narrower than room minus Apple's items parks the band behind the OS « button")
        XCTAssertEqual(MenuBarLogic.dropLength(room: 10), 0, "never negative")
    }

    /// #198: an app switch re-sizes the expanded divider only when it can matter.
    func testActivationReappliesDividerOnlyWhenTheHostedRoomMoved() {
        func decide(hosted: Bool = true, expanded: Bool = true, own: Bool = false,
                    last: CGFloat? = 900, new: CGFloat = 1100) -> Bool {
            MenuBarHost.shouldReapplyDivider(hosted: hosted, anyDividerExpanded: expanded,
                                             activatedOwnApp: own, lastRoom: last, newRoom: new)
        }
        XCTAssertTrue(decide(), "narrower menus, wider room: re-size")
        XCTAssertTrue(decide(last: nil), "never sized yet: size it")
        XCTAssertFalse(decide(hosted: false), "windowed bar (macOS 26 and older) is not room-bound")
        XCTAssertFalse(decide(expanded: false), "everything revealed: nothing to re-size")
        XCTAssertFalse(decide(own: true), "Prosper's own activation is ignored")
        XCTAssertFalse(decide(new: 900), "same room (notched display, same-width menus): no-op")
        XCTAssertFalse(decide(new: 900.4), "sub-point jitter is not a change")
        XCTAssertTrue(decide(new: 901), "exactly one point is a change")
    }

    /// #198 QA F1: the menu edge is a global x, so the room is measured from the
    /// screen's maxX; displays beside the primary have origin.x != 0.
    func testHostedRoomUsesTheScreensGlobalRightEdge() {
        let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let right = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
        let left = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(MenuBarAX.room(screen: primary, menuRight: 500), 1228)
        XCTAssertEqual(MenuBarAX.room(screen: right, menuRight: 1728 + 500), 2060, "right of the primary")
        XCTAssertEqual(MenuBarAX.room(screen: left, menuRight: -2560 + 500), 2060, "left of the primary")
        // The 400 pt guess only when there is no usable measurement for this screen.
        XCTAssertEqual(MenuBarAX.room(screen: right, menuRight: nil), 2160)
        XCTAssertEqual(MenuBarAX.room(screen: right, menuRight: 300), 2160, "an edge on another display is not ours")
        XCTAssertEqual(MenuBarAX.room(screen: left, menuRight: -2560), 2160, "no menu titles laid out")
    }

    /// #154 / #198 QA M6: the cached menu edge is only reused on the display it was
    /// measured on. A display stacked above shares the x range, so `room` alone can't tell.
    func testCachedMenuEdgeIsKeyedByScreen() {
        let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let above = CGRect(x: 0, y: 1117, width: 2560, height: 1440)
        XCTAssertEqual(MenuBarAX.cachedEdge((primary, 500), for: primary), 500)
        XCTAssertNil(MenuBarAX.cachedEdge((primary, 500), for: above))
        XCTAssertNil(MenuBarAX.cachedEdge(nil, for: primary))
    }

    /// #202: each display's bar sits at that display's own top in the global top-left
    /// space. Two synthetic screens: the primary, and a taller external beside it whose
    /// top is 323 pt higher (or, second layout, one stacked below the primary).
    func testHostedBarSlotsMatchEachDisplaysOwnTop() {
        let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let beside = CGRect(x: 1728, y: -323, width: 2560, height: 1440)
        let below = CGRect(x: 0, y: 1117, width: 2560, height: 1440)
        let two = [primary, beside]
        func slot(_ x: CGFloat, _ y: CGFloat, w: CGFloat = 30, h: CGFloat = 24) -> CGRect {
            CGRect(x: x, y: y, width: w, height: h)
        }
        XCTAssertTrue(MenuBarAX.isBarItem(slot(1200, 0), displays: two), "primary bar")
        XCTAssertTrue(MenuBarAX.isBarItem(slot(3000, -323), displays: two), "external bar, its own top")
        XCTAssertFalse(MenuBarAX.isBarItem(slot(3000, 0), displays: two), "y 0 is inside the external, not its bar")
        XCTAssertTrue(MenuBarAX.isBarItem(slot(500, 1117), displays: [primary, below]), "bar of a display below the primary")
        XCTAssertFalse(MenuBarAX.isBarItem(slot(500, 1117), displays: two), "no display has its top there")
        XCTAssertFalse(MenuBarAX.isBarItem(slot(5000, -323), displays: two), "right of every display")
        XCTAssertFalse(MenuBarAX.isBarItem(slot(1200, 0, h: 12), displays: two), "too short for a bar slot")
        XCTAssertFalse(MenuBarAX.isBarItem(slot(1800, -323, w: 1280), displays: two), "half the external wide: a container")
        XCTAssertTrue(MenuBarAX.isBarItem(slot(1800, -323, w: 1000), displays: two), "the width bound is the external's, not the primary's")
    }

    /// #202: an item is enumerated only for the display it is on — the host's frame
    /// when laid out, the app's stale frame when not. Unmatched items used to skip the
    /// check and showed up on every display.
    func testHostedItemsStayOnTheirOwnDisplay() {
        let primary: CGDirectDisplayID = 1, external: CGDirectDisplayID = 2
        let displayOf: (CGRect) -> CGDirectDisplayID = { $0.midX < 1728 ? primary : external }
        let laid = [MenuBarAX.Laid(frame: CGRect(x: 3000, y: -323, width: 30, height: 24), pid: 42)]
        func place(_ x: CGFloat, pid: pid_t = 42, on display: CGDirectDisplayID) -> (frame: CGRect, laidOut: Bool)? {
            MenuBarAX.place(CGRect(x: x, y: 0, width: 30, height: 24), pid: pid, laid: laid, on: display, displayOf: displayOf)
        }
        let hit = place(3001, on: external)
        XCTAssertEqual(hit?.frame.minY, -323, "laid out: the host's frame")
        XCTAssertEqual(hit?.laidOut, true)
        XCTAssertNil(place(3001, on: primary), "laid out on the external only")
        XCTAssertEqual(place(3001, pid: 7, on: external)?.laidOut, false, "another app's slot is not a match")
        XCTAssertNil(place(2500, on: primary), "unmatched, stale frame on the external: not on the primary")
        XCTAssertEqual(place(2500, on: external)?.laidOut, false, "unmatched stays on its own display, overflowed")
        XCTAssertEqual(place(900, on: primary)?.frame.minX, 900, "unmatched on the primary: the app's frame")
    }

    /// #203: own content extras are named by AX identifier; the client minX (stale on
    /// macOS 27) is the fallback only for an extra that carries none.
    func testOwnContentPrefersIdentifierOverStaleMinX() {
        let p = ProsperStatusItems.contentPrefix
        let items = [(id: p + "CPU", x: CGFloat(100)), (id: p + "Volume", x: CGFloat(200))]
        func pick(_ id: String?, _ x: CGFloat) -> String? {
            ProsperStatusItems.pick(items, identifier: id, minX: x, id: \.id, x: \.x)?.id
        }
        XCTAssertEqual(pick(p + "Volume", 100), p + "Volume", "identifier wins over a stale minX")
        XCTAssertNil(pick(p + "Gone", 100), "an unknown own identifier does not fall back to minX")
        XCTAssertEqual(pick(nil, 101), p + "CPU", "no identifier: minX")
        XCTAssertEqual(pick("other.id", 201), p + "Volume", "a foreign identifier is no identifier")
        XCTAssertNil(pick(nil, 150), "no identifier, no minX match")
    }

    /// #192: beta polls every 10 minutes, stable every 4 hours.
    @MainActor
    func testPollIntervalFollowsTheChannel() {
        let saved = Preferences.allowBetaUpdates
        defer { Preferences.allowBetaUpdates = saved }
        Preferences.allowBetaUpdates = true
        XCTAssertEqual(AppUpdater.pollInterval, 600)
        Preferences.allowBetaUpdates = false
        XCTAssertEqual(AppUpdater.pollInterval, 4 * 3600)
    }

    /// #192 QA U2 + LOW: toggling the channel, or re-enabling checks after a toggle, re-arms the Timer.
    @MainActor
    func testChannelToggleRestartsPolling() {
        let savedBeta = Preferences.allowBetaUpdates
        let savedAuto = Preferences.automaticUpdateChecks
        defer {
            Preferences.allowBetaUpdates = savedBeta
            Preferences.automaticUpdateChecks = savedAuto
        }
        let updater = AppUpdater()
        defer { updater.automaticChecks = false }
        func distance() -> TimeInterval? { updater.nextCheckDate?.timeIntervalSinceNow }
        updater.automaticChecks = true
        updater.allowBetaUpdates = true
        XCTAssertEqual(distance() ?? -1, 600, accuracy: 5)
        updater.allowBetaUpdates = false
        XCTAssertEqual(distance() ?? -1, 4 * 3600, accuracy: 5, "channel toggle must restart polling")
        updater.automaticChecks = false
        XCTAssertNil(distance())
        updater.allowBetaUpdates = true
        updater.automaticChecks = true
        XCTAssertEqual(distance() ?? -1, 600, accuracy: 5, "re-enabling checks must use the current channel")
    }
}
