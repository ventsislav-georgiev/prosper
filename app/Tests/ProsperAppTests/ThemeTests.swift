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
