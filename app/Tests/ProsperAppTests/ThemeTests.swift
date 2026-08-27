import AppKit
import XCTest
import SwiftUI
@testable import ProsperApp

/// Theme system: hex parsing, spec decode + partial-theme fallback, descriptor
/// discovery from a manifest, and ThemeStore selection/persistence/ordering.
final class ThemeTests: XCTestCase {

    // MARK: hex

    func testHexParsing() {
        XCTAssertNotNil(Color(hex: "#21CCFF"))
        XCTAssertNotNil(Color(hex: "21CCFF"))     // no leading #
        XCTAssertNotNil(Color(hex: "#0af"))        // short form
        XCTAssertNotNil(Color(hex: "#21CCFF80"))   // with alpha
        XCTAssertNil(Color(hex: "#21CC"))          // wrong length
        XCTAssertNil(Color(hex: "#GGGGGG"))        // non-hex
        XCTAssertNil(Color(hex: ""))
        XCTAssertNil(Color(hex: "   "))            // whitespace only
        // Fullwidth 'F' passes Character.isHexDigit but isn't ASCII hex — must
        // reject, not silently parse to black.
        XCTAssertNil(Color(hex: "ＦＦＦＦＦＦ"))
    }

    // MARK: change detection

    func testChannelsEqual() {
        XCTAssertTrue(ThemePalette.default.channelsEqual(.default))
        var spec = ThemeSpec.empty
        spec.colors = ["blue": Color(hex: "#FFB000")!]
        XCTAssertFalse(ThemePalette.resolve(spec).channelsEqual(.default))
        // A spec that re-states the default hex resolves channel-equal to default
        // even though the Colors were built via different inits.
        var same = ThemeSpec.empty
        same.colors = ["blue": Color(hex: "#21CCFF")!]
        XCTAssertTrue(ThemePalette.resolve(same).channelsEqual(.default))
    }

    @MainActor
    func testRedundantApplyDoesNotBumpGeneration() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: "t-\(UUID())")!, cacheDir: tmpCache())
        store.setAvailable([])                 // default active, no change from initial
        let g1 = store.generation
        store.setAvailable([])                 // identical rescan
        XCTAssertEqual(store.generation, g1, "no-op rescan must not rebuild windows")
        store.select(id: ThemeDescriptor.builtInID)  // re-select the already-active theme
        XCTAssertEqual(store.generation, g1, "re-selecting the active theme must not bump")
    }

    @MainActor
    func testPreviewsPopulatedForSelector() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: "t-\(UUID())")!, cacheDir: tmpCache())
        store.setAvailable([])
        XCTAssertNotNil(store.previews[ThemeDescriptor.builtInID], "selector reads previews, not disk")
    }

    @MainActor
    func testLightThemeFlipsAppearance() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: "t-\(UUID())")!, cacheDir: tmpCache())
        let dir = writeThemeJSON(##"{ "appearance": "light", "colors": { "bgTop": "#FFFFFF" } }"##)
        let light = ThemeDescriptor(id: "t.light", title: "Light", appearance: .light,
                                    extensionID: "e", jsonPath: dir)
        store.setAvailable([light])
        store.select(id: "t.light")
        XCTAssertEqual(store.appearance, .light)
    }

    @MainActor
    func testDuplicateThemeIDsDoNotCrash() {
        // Two extensions declaring the same theme id must not trap the previews
        // dictionary build; the list dedups, first wins.
        let store = ThemeStore(defaults: UserDefaults(suiteName: "t-\(UUID())")!, cacheDir: tmpCache())
        let a = ThemeDescriptor(id: "dup", title: "A", appearance: .dark, extensionID: "e1", jsonPath: nil)
        let b = ThemeDescriptor(id: "dup", title: "B", appearance: .dark, extensionID: "e2", jsonPath: nil)
        store.setAvailable([a, b])
        XCTAssertEqual(store.available.filter { $0.id == "dup" }.count, 1)
        XCTAssertNotNil(store.previews["dup"])
    }

    // MARK: spec decode

    func testSpecDecodeReadsColorsAppearanceAssets() throws {
        let json = """
        { "appearance": "light",
          "colors": { "blue": "#FFB000", "bogusKey": "#123456", "card": "notacolor" },
          "assets": { "appIcon": "https://x/y.png", "n": 1 } }
        """
        let spec = try ThemeSpec.decode(Data(json.utf8))
        XCTAssertEqual(spec.appearance, .light)
        XCTAssertNotNil(spec.colors["blue"])
        XCTAssertNotNil(spec.colors["bogusKey"])     // unknown key kept (ignored at resolve)
        XCTAssertNil(spec.colors["card"], "bad color string must be skipped, not fatal")
        XCTAssertEqual(spec.assets["appIcon"], "https://x/y.png")
        XCTAssertNil(spec.assets["n"], "non-string asset values dropped")
    }

    func testSpecDecodeDefaultsAppearanceToDark() throws {
        let spec = try ThemeSpec.decode(Data("{}".utf8))
        XCTAssertEqual(spec.appearance, .dark)
        XCTAssertTrue(spec.colors.isEmpty)
    }

    func testMalformedSpecThrows() {
        XCTAssertThrowsError(try ThemeSpec.decode(Data("[1,2,3]".utf8)))
    }

    // MARK: partial-theme fallback

    func testResolveOverridesOnlyProvidedTokens() {
        var spec = ThemeSpec.empty
        spec.colors = ["blue": Color(hex: "#FFB000")!]
        let p = ThemePalette.resolve(spec)
        XCTAssertEqual(p.blue, Color(hex: "#FFB000")!)
        // Everything not provided stays the default.
        XCTAssertEqual(p.bgTop, ThemePalette.default.bgTop)
        XCTAssertEqual(p.textPrimary, ThemePalette.default.textPrimary)
    }

    func testResolveEmptySpecEqualsDefault() {
        XCTAssertEqual(ThemePalette.resolve(.empty), .default)
    }

    // MARK: descriptor discovery from a manifest

    func testContributedThemesDiscoveredFromManifest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("themetest-\(UUID().uuidString)", isDirectory: true)
        let extDir = dir.appendingPathComponent("mytheme", isDirectory: true)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "com.test.theme"
        name = "mytheme"
        title = "My Theme"
        description = "x"
        version = "1.0.0"
        author = "me"
        system = true

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.themes]]
        id = "com.test.theme.dark"
        title = "Test Dark"
        path = "theme.json"
        appearance = "dark"
        """.write(to: extDir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- noop".write(to: extDir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        try ##"{ "colors": { "blue": "#FFB000" } }"##
            .write(to: extDir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)

        let loaded = try ExtensionLoader.load(directory: extDir, isSystem: true, hostVersion: "2.0.0")
        let themes = loaded.manifest.contributes?.allThemes ?? []
        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes.first?.id, "com.test.theme.dark")
        XCTAssertEqual(themes.first?.path, "theme.json")

        // The descriptor's jsonPath resolves a palette that overrides only blue.
        let d = ThemeDescriptor(id: themes[0].id, title: themes[0].title, appearance: .dark,
                                extensionID: loaded.id,
                                jsonPath: extDir.appendingPathComponent("theme.json"))
        XCTAssertEqual(ThemePalette.load(for: d).blue, Color(hex: "#FFB000")!)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: bundled theme extensions

    /// Every bundled theme-* extension is pure data — one typo in a hex string or
    /// token name silently falls back to the default palette, so lint them here:
    /// theme.json decodes, every token is a recognized name, manifest appearance
    /// matches the JSON, and the full 12-token palette is provided.
    func testBundledThemeExtensionsAreValid() throws {
        let themeDirs = try bundledThemeDirs()
        XCTAssertGreaterThanOrEqual(themeDirs.count, 21, "bundled theme set went missing")

        for dir in themeDirs {
            let loaded = try ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: "2.0.0")
            let themes = loaded.manifest.contributes?.allThemes ?? []
            XCTAssertEqual(themes.count, 1, "\(dir.lastPathComponent): expected one contributed theme")
            guard let t = themes.first else { continue }

            let data = try Data(contentsOf: dir.appendingPathComponent(t.path))
            let spec = try ThemeSpec.decode(data)
            XCTAssertEqual(spec.appearance.rawValue, t.appearance ?? "dark",
                           "\(dir.lastPathComponent): manifest/json appearance mismatch")
            // decode drops unparseable hex and resolve ignores unknown tokens —
            // both silent, so assert the exact full token set survived.
            XCTAssertEqual(Set(spec.colors.keys), Set(ThemePalette.tokenNames),
                           "\(dir.lastPathComponent): token set incomplete or misspelled")
        }
    }

    /// The catalog's two colour invariants, both of which silently rotted once
    /// before (themes shipped as monochrome ramps of one hue):
    ///
    /// 1. No two themes of the same appearance may share a look. A theme's
    ///    identity is its `blue` accent — the widest stripe in the picker's
    ///    preview strip — so two accents that match on hue AND saturation AND
    ///    brightness make two rows the user cannot tell apart.
    /// 2. `magenta` is the alert/destructive role (errors, muted, "delete") and
    ///    `blue` is the everyday accent. When those two are the same colour, an
    ///    error message is invisible — which is exactly what Graphite and Silver
    ///    shipped (a 2-3° hue gap between the two).
    func testBundledThemeAccentsAreDistinguishable() throws {
        var byAppearance: [String: [(name: String, accent: NSColor, alert: NSColor)]] = [:]
        for dir in try bundledThemeDirs() {
            let loaded = try ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: "2.0.0")
            guard let t = loaded.manifest.contributes?.allThemes.first else { continue }
            let spec = try ThemeSpec.decode(Data(contentsOf: dir.appendingPathComponent(t.path)))
            guard let blue = spec.colors["blue"], let magenta = spec.colors["magenta"] else {
                return XCTFail("\(dir.lastPathComponent): missing blue/magenta")
            }
            byAppearance[spec.appearance.rawValue, default: []]
                .append((dir.lastPathComponent, Self.srgb(blue), Self.srgb(magenta)))
        }
        XCTAssertEqual(byAppearance.keys.sorted(), ["dark", "light"])

        for (_, themes) in byAppearance {
            for t in themes {
                // (2) alert must not read as the everyday accent.
                XCTAssertGreaterThanOrEqual(
                    Self.hueDistance(t.accent, t.alert), 30,
                    "\(t.name): magenta (alert) is the same hue as blue (accent) — errors would be invisible")
            }
            // (1) pairwise distinctness within an appearance mode.
            for (a, b) in Self.pairs(themes) {
                let sameHue = Self.hueDistance(a.accent, b.accent) < 22
                let sameSat = abs(a.accent.saturationComponent - b.accent.saturationComponent) < 0.30
                let sameBri = abs(a.accent.brightnessComponent - b.accent.brightnessComponent) < 0.22
                XCTAssertFalse(sameHue && sameSat && sameBri,
                               "\(a.name) and \(b.name) have look-alike accents")
            }
        }
    }

    private func bundledThemeDirs() throws -> [URL] {
        let extensionsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()           // …/app/Tests/ProsperAppTests
            .deletingLastPathComponent()           // …/app/Tests
            .deletingLastPathComponent()           // …/app
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: extensionsDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
    }

    private static func srgb(_ c: Color) -> NSColor {
        let n = NSColor(c)
        return n.usingColorSpace(.sRGB) ?? n
    }

    /// Shortest arc between two hues, in degrees.
    private static func hueDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let d = abs(a.hueComponent - b.hueComponent).truncatingRemainder(dividingBy: 1) * 360
        return min(d, 360 - d)
    }

    private static func pairs<T>(_ xs: [T]) -> [(T, T)] {
        xs.indices.dropLast().flatMap { i in xs[(i + 1)...].map { (xs[i], $0) } }
    }

    // MARK: ThemeStore

    @MainActor
    func testStoreSelectionAppliesAndPersists() {
        let suite = "themetest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ThemeStore(defaults: defaults, cacheDir: tmpCache())

        let dir = writeThemeJSON(##"{ "appearance": "dark", "colors": { "blue": "#FFB000" } }"##)
        let amber = ThemeDescriptor(id: "t.amber", title: "Amber", appearance: .dark,
                                    extensionID: "ext", jsonPath: dir)
        store.setAvailable([amber])
        let gen0 = store.generation
        store.select(id: "t.amber")
        XCTAssertEqual(store.activeID, "t.amber")
        XCTAssertGreaterThan(store.generation, gen0, "switch must bump generation for redraw")
        XCTAssertEqual(ThemeRuntime.palette.blue, Color(hex: "#FFB000")!)
        XCTAssertEqual(defaults.string(forKey: "prosper.activeThemeID"), "t.amber")

        // A fresh store reading the same defaults restores the selection.
        let store2 = ThemeStore(defaults: defaults, cacheDir: tmpCache())
        store2.setAvailable([amber])
        XCTAssertEqual(store2.activeID, "t.amber")
    }

    @MainActor
    func testStoreDefaultAlwaysPresentAndFirst() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: "t-\(UUID())")!, cacheDir: tmpCache())
        store.setAvailable([])   // no contributed themes
        XCTAssertEqual(store.available.first?.id, ThemeDescriptor.builtInID)

        // When the default IS contributed, it still sorts to the front.
        let other = ThemeDescriptor(id: "z.other", title: "Z", appearance: .dark, extensionID: "e", jsonPath: nil)
        let def = ThemeDescriptor(id: ThemeDescriptor.builtInID, title: "Default", appearance: .dark,
                                  extensionID: "e", jsonPath: nil)
        store.setAvailable([other, def])
        XCTAssertEqual(store.available.first?.id, ThemeDescriptor.builtInID)
    }

    @MainActor
    func testStoreFallsBackWhenActiveThemeDisappears() {
        let defaults = UserDefaults(suiteName: "t-\(UUID())")!
        let store = ThemeStore(defaults: defaults, cacheDir: tmpCache())
        let amber = ThemeDescriptor(id: "t.amber", title: "Amber", appearance: .dark, extensionID: "e", jsonPath: nil)
        store.setAvailable([amber])
        store.select(id: "t.amber")
        XCTAssertEqual(store.activeID, "t.amber")
        // Amber's extension removed → list no longer has it → revert to Default.
        store.setAvailable([])
        XCTAssertEqual(store.activeID, ThemeDescriptor.builtInID)
        XCTAssertEqual(ThemeRuntime.palette, .default, "reverting to Default restores the default palette")
    }

    // MARK: appearance pane — arrow-key theme selection (#078)

    func testNextThemeIndexMovesWithinBounds() {
        XCTAssertEqual(AppearanceSettingsPane.nextThemeIndex(current: 1, delta: 1, count: 5), 2)
        XCTAssertEqual(AppearanceSettingsPane.nextThemeIndex(current: 1, delta: -1, count: 5), 0)
    }

    func testNextThemeIndexStopsAtEndsWithoutWrapping() {
        XCTAssertNil(AppearanceSettingsPane.nextThemeIndex(current: 0, delta: -1, count: 5), "up at the top must not wrap to the bottom")
        XCTAssertNil(AppearanceSettingsPane.nextThemeIndex(current: 4, delta: 1, count: 5), "down at the bottom must not wrap to the top")
    }

    func testNextThemeIndexOnEmptyListReturnsNil() {
        XCTAssertNil(AppearanceSettingsPane.nextThemeIndex(current: 0, delta: 1, count: 0))
        XCTAssertNil(AppearanceSettingsPane.nextThemeIndex(current: 0, delta: -1, count: 0))
    }

    // MARK: appearance pane — arrow-key monitor swallow predicate (#078 round 3)

    func testShouldSwallowArrowKeyOnlyForUpDownWhenPaneVisibleAndNotEditingText() {
        XCTAssertTrue(AppearanceSettingsPane.shouldSwallowArrowKey(
            paneVisible: true, firstResponderIsTextInput: false, keyCode: 126), "up arrow")
        XCTAssertTrue(AppearanceSettingsPane.shouldSwallowArrowKey(
            paneVisible: true, firstResponderIsTextInput: false, keyCode: 125), "down arrow")
    }

    func testShouldSwallowArrowKeyIgnoresNonArrowKeys() {
        XCTAssertFalse(AppearanceSettingsPane.shouldSwallowArrowKey(
            paneVisible: true, firstResponderIsTextInput: false, keyCode: 36), "return key")
        XCTAssertFalse(AppearanceSettingsPane.shouldSwallowArrowKey(
            paneVisible: true, firstResponderIsTextInput: false, keyCode: 123), "left arrow")
    }

    func testShouldSwallowArrowKeyLetsTextInputKeepItsOwnArrows() {
        // The sidebar search field editing arrows for cursor movement — must
        // never be intercepted, even while the Appearance pane is visible.
        XCTAssertFalse(AppearanceSettingsPane.shouldSwallowArrowKey(
            paneVisible: true, firstResponderIsTextInput: true, keyCode: 126))
        XCTAssertFalse(AppearanceSettingsPane.shouldSwallowArrowKey(
            paneVisible: true, firstResponderIsTextInput: true, keyCode: 125))
    }

    func testShouldSwallowArrowKeyRequiresPaneVisible() {
        XCTAssertFalse(AppearanceSettingsPane.shouldSwallowArrowKey(
            paneVisible: false, firstResponderIsTextInput: false, keyCode: 126))
    }

    // MARK: appearance pane — arrow-select auto-scroll anchor (#078 round 4)

    // #100: the anchor is deliberately STABLE across a select now — `moveSelection`
    // builds its `SettingsFocusRouter` request and the row builds its own `.id()`
    // from two separate calls, and they have to agree or `ScrollViewReader` has
    // nothing matching to scroll to. #082's generation fold (and the "read
    // `theme.generation` strictly after `select`" dance it forced on
    // `moveSelection`) is gone; `ThemeCardRepaintTests.testStableRowIDsRepaintOnSelect`
    // is the pixel evidence that nothing goes stale without it.
    func testRowAnchorIsStableAcrossSelects() {
        let a1 = AppearanceSettingsPane.rowAnchor(pane: "appearance", themeID: "t.amber")
        let a2 = AppearanceSettingsPane.rowAnchor(pane: "appearance", themeID: "t.amber")
        XCTAssertEqual(a1, a2)
    }

    func testRowAnchorsAreDistinctPerThemeID() {
        let amber = AppearanceSettingsPane.rowAnchor(pane: "appearance", themeID: "t.amber")
        let dflt = AppearanceSettingsPane.rowAnchor(pane: "appearance", themeID: ThemeDescriptor.builtInID)
        XCTAssertNotEqual(amber, dflt)
    }

    func testRowAnchorNeverCollidesWithASectionTitleAnchor() {
        // NeonSection anchors this pane's own sections with a bare title (e.g.
        // "Theme"). A row anchor must never equal one of those, or an
        // arrow-driven auto-scroll would also light up SettingsFocusRouter's
        // section-glow highlight, which no requirement asked for.
        for title in ["Menu Bar Icon", "Theme", "UI Size", "Transparency", "Frost"] {
            let sectionAnchor = SettingsAnchor(pane: "appearance", section: title)
            let rowAnchor = AppearanceSettingsPane.rowAnchor(pane: "appearance", themeID: title)
            XCTAssertNotEqual(sectionAnchor, rowAnchor, "row id must not collide with the \"\(title)\" section anchor")
        }
    }

    // MARK: menu-bar icon (#084)

    func testMenuBarIconChoiceStoredRoundTrip() {
        for choice: MenuBarIconChoice in [.prosper, .sfSymbol("bolt.fill"), .emoji("🖖"), .emoji("")] {
            XCTAssertEqual(MenuBarIconChoice(stored: choice.stored), choice)
        }
    }

    func testMenuBarIconChoiceDefaultsToVulcanForUnknownOrEmptyStoredValue() {
        // #102: absent (`""`) and garbage stored values both fall back to
        // `.vulcan` now — the same value `.stored`/`init(stored:)` round-trip
        // for an EXPLICIT Vulcan-swatch pick, so default-by-fallback and
        // default-by-selection are indistinguishable.
        XCTAssertEqual(MenuBarIconChoice(stored: ""), .vulcan)
        XCTAssertEqual(MenuBarIconChoice(stored: "garbage"), .vulcan)
        // An explicit `.prosper` choice must still round-trip, not collapse
        // into the new fallback (see testMenuBarIconChoiceStoredRoundTrip).
        XCTAssertEqual(MenuBarIconChoice(stored: "prosper"), .prosper)
    }

    func testMenuBarIconChoiceIsValidEmojiAcceptsRealEmoji() {
        XCTAssertTrue(MenuBarIconChoice.isValidEmoji("🖖"))
        XCTAssertTrue(MenuBarIconChoice.isValidEmoji("😀"))
        XCTAssertTrue(MenuBarIconChoice.isValidEmoji("👨‍👩‍👧‍👦"))   // ZWJ family sequence, one grapheme cluster
        XCTAssertTrue(MenuBarIconChoice.isValidEmoji("  🚀  "))     // surrounding whitespace trimmed
    }

    func testMenuBarIconChoiceIsValidEmojiRejectsGarbage() {
        XCTAssertFalse(MenuBarIconChoice.isValidEmoji(""))
        XCTAssertFalse(MenuBarIconChoice.isValidEmoji("   "))
        XCTAssertFalse(MenuBarIconChoice.isValidEmoji("abc"))
        // Bare digits/`#`/`*` satisfy Unicode's `isEmoji` scalar property (they're
        // valid in keycap sequences) but typed alone are just characters, not a
        // picture — must be rejected, not accepted as "an emoji".
        XCTAssertFalse(MenuBarIconChoice.isValidEmoji("5"))
        XCTAssertFalse(MenuBarIconChoice.isValidEmoji("#"))
        XCTAssertFalse(MenuBarIconChoice.isValidEmoji("ab"))   // more than one grapheme cluster
    }

    @MainActor
    func testMenuBarIconChoiceTemplateImageResolution() {
        // `.prosper` is nil — the caller falls through to the existing
        // theme/bundled-icon path (see MenuBarController.setMenuBarImage).
        XCTAssertNil(MenuBarIconChoice.prosper.templateImage())

        let sf = MenuBarIconChoice.sfSymbol("bolt.fill").templateImage()
        XCTAssertNotNil(sf)
        XCTAssertEqual(sf?.isTemplate, true)

        // #088: the Vulcan PRESET keeps native black/white tinting — the user
        // explicitly asked for that.
        let vulcan = MenuBarIconChoice.vulcan.templateImage()
        XCTAssertNotNil(vulcan)
        XCTAssertEqual(vulcan?.isTemplate, true)

        // #088: any OTHER custom emoji renders FULL COLOR. Template tinting
        // keeps only the alpha channel, collapsing a colored glyph into a
        // solid silhouette (a round face reads as a blank egg) — this is the
        // exact bug report ("the custom emoji ... always shows an egg").
        let custom = MenuBarIconChoice.emoji("🎉").templateImage()
        XCTAssertNotNil(custom)
        XCTAssertEqual(custom?.isTemplate, false)

        // Graceful fallback: invalid custom-emoji text resolves to nil (never a
        // blank status item), same as `.prosper` — MenuBarController's caller
        // can't tell the two apart, and doesn't need to.
        XCTAssertNil(MenuBarIconChoice.emoji("not an emoji").templateImage())
        XCTAssertNil(MenuBarIconChoice.emoji("").templateImage())
    }

    /// #102: integration-level pin, through `Preferences`/real `UserDefaults`
    /// (not just the pure `init(stored:)` fallback above) — a fresh install,
    /// or an existing one that never touched these keys (or has a corrupted
    /// value), must come up as Vulcan @ medium, and it must render exactly
    /// like the picker's own Vulcan swatch: a TEMPLATE image (`isTemplate ==
    /// true`), never the bundled/theme full-color icon. Also pins that this
    /// is a pure fallback, not a stored write: explicit choices made
    /// afterwards still win and still round-trip.
    @MainActor
    func testMenuBarDefaultsThroughPreferencesAreVulcanAtMediumForAbsentOrGarbageStoredValue() {
        let choiceKey = "menuBarIconChoice"
        let sizeKey = "menuBarIconSize"
        let savedChoice = UserDefaults.standard.object(forKey: choiceKey)
        let savedSize = UserDefaults.standard.object(forKey: sizeKey)
        defer {
            if let savedChoice { UserDefaults.standard.set(savedChoice, forKey: choiceKey) }
            else { UserDefaults.standard.removeObject(forKey: choiceKey) }
            if let savedSize { UserDefaults.standard.set(savedSize, forKey: sizeKey) }
            else { UserDefaults.standard.removeObject(forKey: sizeKey) }
        }

        for storedChoice in [nil, "garbage"] {
            if let storedChoice { UserDefaults.standard.set(storedChoice, forKey: choiceKey) }
            else { UserDefaults.standard.removeObject(forKey: choiceKey) }
            for storedSize in [nil, "garbage"] {
                if let storedSize { UserDefaults.standard.set(storedSize, forKey: sizeKey) }
                else { UserDefaults.standard.removeObject(forKey: sizeKey) }

                XCTAssertEqual(Preferences.menuBarIconChoice, .vulcan)
                XCTAssertEqual(Preferences.menuBarIconSize, .medium)
                let image = Preferences.menuBarIconChoice.templateImage()
                XCTAssertNotNil(image)
                XCTAssertEqual(image?.isTemplate, true)
            }
        }

        // No regression: explicit stored choices still win and still
        // round-trip through the very same getters.
        Preferences.menuBarIconChoice = .prosper
        Preferences.menuBarIconSize = .large
        XCTAssertEqual(Preferences.menuBarIconChoice, .prosper)
        XCTAssertEqual(Preferences.menuBarIconSize, .large)
        XCTAssertNil(Preferences.menuBarIconChoice.templateImage())

        Preferences.menuBarIconChoice = .sfSymbol("bolt.fill")
        Preferences.menuBarIconSize = .small
        XCTAssertEqual(Preferences.menuBarIconChoice, .sfSymbol("bolt.fill"))
        XCTAssertEqual(Preferences.menuBarIconSize, .small)
    }

    // MARK: menu-bar swatch tint (#093)

    /// `AppleInterfaceStyle` is nil/anything-but-"Dark" in light mode — never
    /// literally "Light" — and "Dark" (macOS's own casing) in dark mode.
    /// Case-insensitive on the "Dark" match as a light defensive touch, not
    /// because macOS is known to vary it.
    func testMenuBarTintIsSystemDarkReadsAppleInterfaceStyle() {
        XCTAssertTrue(MenuBarTint.isSystemDark(interfaceStyle: "Dark"))
        XCTAssertTrue(MenuBarTint.isSystemDark(interfaceStyle: "dark"))
        XCTAssertFalse(MenuBarTint.isSystemDark(interfaceStyle: nil))
        XCTAssertFalse(MenuBarTint.isSystemDark(interfaceStyle: "Light"))
        XCTAssertFalse(MenuBarTint.isSystemDark(interfaceStyle: ""))
        XCTAssertFalse(MenuBarTint.isSystemDark(interfaceStyle: "garbage"))
    }

    // MARK: theme ordering (#090)

    @MainActor
    func testOrderedByAppearanceGroupsDarkBeforeLightStably() {
        let d1 = ThemeDescriptor(id: "d1", title: "D1", appearance: .dark, extensionID: "e", jsonPath: nil)
        let l1 = ThemeDescriptor(id: "l1", title: "L1", appearance: .light, extensionID: "e", jsonPath: nil)
        let d2 = ThemeDescriptor(id: "d2", title: "D2", appearance: .dark, extensionID: "e", jsonPath: nil)
        let l2 = ThemeDescriptor(id: "l2", title: "L2", appearance: .light, extensionID: "e", jsonPath: nil)

        let ordered = AppearanceSettingsPane.orderedByAppearance([l1, d1, l2, d2])

        XCTAssertEqual(ordered.map(\.id), ["d1", "d2", "l1", "l2"])
    }

    @MainActor
    func testOrderedByAppearanceKeepsBuiltInDefaultFirst() {
        // `ThemeStore.setAvailable` guarantees Default is already first among
        // `theme.available` (see `testStoreDefaultAlwaysPresentAndFirst`).
        // Stability means grouping by appearance must never displace it from
        // the front of its (dark) group.
        let other = ThemeDescriptor(id: "z.other", title: "Z", appearance: .dark, extensionID: "e", jsonPath: nil)
        let light = ThemeDescriptor(id: "l1", title: "L1", appearance: .light, extensionID: "e", jsonPath: nil)

        let ordered = AppearanceSettingsPane.orderedByAppearance([ThemeDescriptor.builtIn, other, light])

        XCTAssertEqual(ordered.first?.id, ThemeDescriptor.builtInID)
    }

    // MARK: menu-bar icon size (#092)

    func testMenuBarIconSizeStoredRoundTrip() {
        let saved = Preferences.menuBarIconSize
        defer { Preferences.menuBarIconSize = saved }

        for size: MenuBarIconSize in [.small, .medium, .large] {
            Preferences.menuBarIconSize = size
            XCTAssertEqual(Preferences.menuBarIconSize, size)
        }
    }

    func testMenuBarIconSizeDefaultsToMediumForUnknownOrAbsentStoredValue() {
        // #102: `.medium` is now the fallback for an existing install with no
        // stored value — or a corrupted one. `.large` (the pre-#102 default,
        // still today's exact pre-#092 sizing) remains explicitly selectable.
        XCTAssertEqual(MenuBarIconSize(rawValue: "garbage") ?? .medium, .medium)
        XCTAssertEqual(MenuBarIconSize(rawValue: "") ?? .medium, .medium)
    }

    func testMenuBarIconSizeScaleOrderingSmallLessThanMediumLessThanLarge() {
        // Pure comparison of the mapping constants — no live status bar
        // needed. `.large` is exactly 1.0 (today's shipped, pre-#092 sizing;
        // #102 made `.medium`, not `.large`, the default — see the redo note
        // below).
        XCTAssertLessThan(MenuBarIconSize.small.scale, MenuBarIconSize.medium.scale)
        XCTAssertLessThan(MenuBarIconSize.medium.scale, MenuBarIconSize.large.scale)
        XCTAssertEqual(MenuBarIconSize.large.scale, 1.0)
    }

    func testMenuBarIconSizePointSizeNeverExceedsThicknessAndLargeMatchesItExactly() {
        // Confirmed headlessly safe: `NSStatusBar.system.thickness` does not
        // require a running NSApplication.
        let thickness = NSStatusBar.system.thickness
        for size: MenuBarIconSize in [.small, .medium, .large] {
            XCTAssertLessThanOrEqual(size.pointSize(thickness: thickness), thickness)
        }
        // `.large` must still be byte-identical to the pre-#092 hardcoded
        // sizing when explicitly selected — #102 changed only the default
        // (now `.medium`, see testMenuBarIconSizeDefaultsToMediumForUnknownOrAbsentStoredValue),
        // not this mapping.
        XCTAssertEqual(MenuBarIconSize.large.pointSize(thickness: thickness), thickness)
        // Redo regression guard: all three steps must be visually distinct at
        // the real bar height (the bug this redo exists to fix was
        // large == medium on today's 22pt bar).
        XCTAssertLessThan(MenuBarIconSize.small.pointSize(thickness: thickness), MenuBarIconSize.medium.pointSize(thickness: thickness))
        XCTAssertLessThan(MenuBarIconSize.medium.pointSize(thickness: thickness), MenuBarIconSize.large.pointSize(thickness: thickness))
    }

    // MARK: assets

    func testInlineDataAssetDecodes() async {
        // 1x1 transparent PNG.
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
        let img = await ThemeStore.loadAsset(ref: png, baseDir: nil, cacheDir: tmpCache())
        XCTAssertNotNil(img)
    }

    func testBundleRelativeAssetLoads() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==")!
        try pngData.write(to: dir.appendingPathComponent("icon.png"))
        let img = await ThemeStore.loadAsset(ref: "icon.png", baseDir: dir, cacheDir: tmpCache())
        XCTAssertNotNil(img)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: perf — switching is not a keystroke path, but resolve must stay cheap

    func testResolveHotPathBudget() {
        var spec = ThemeSpec.empty
        spec.colors = Dictionary(uniqueKeysWithValues: ThemePalette.tokenNames.map { ($0, Color(hex: "#FFB000")!) })
        let iters = 100_000
        let start = Date()
        var sink = 0
        for _ in 0..<iters {
            let p = ThemePalette.resolve(spec)
            if p.blue == p.indigo { sink += 1 }
        }
        let ns = Date().timeIntervalSince(start) / Double(iters) * 1_000_000_000
        print("theme resolve: \(Int(ns)) ns/call over \(iters) iters (sink=\(sink))")
        XCTAssertLessThan(ns, 50_000, "palette resolve should be well under 50µs")
    }

    /// `Neon.*` flipped from `static let` to computed `var` (so themes re-skin
    /// live). Gradients now rebuild per access; this guards that a UI body reading
    /// the derived tokens stays cheap (no per-render disk/lock work).
    func testNeonTokenAccessHotPath() {
        let iters = 100_000
        let start = Date()
        var sink = 0
        for _ in 0..<iters {
            withExtendedLifetime(Neon.cardStroke) { sink += 1 }
            withExtendedLifetime(Neon.barFill) { sink += 1 }
            withExtendedLifetime(Neon.blue) { sink += 1 }
        }
        let ns = Date().timeIntervalSince(start) / Double(iters) * 1_000_000_000
        print("Neon token bundle: \(Int(ns)) ns/iter over \(iters) (sink=\(sink))")
        XCTAssertLessThan(ns, 20_000, "Neon derived-token access should be well under 20µs/iter")
    }

    // MARK: helpers

    private func tmpCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeThemeJSON(_ json: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("th-\(UUID().uuidString).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
