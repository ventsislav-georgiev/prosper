import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #862: theme tint variants. Parsing and refusal, the merge, per-theme memory, the one-step
/// live apply and the tint dots on a theme's row. Every store is a scratch store over scratch
/// defaults; views are hosted in windows that are never shown, ordered or made key, and a dot
/// is pressed through its own accessibility element (no event is posted).
@MainActor
final class ThemeVariantTests: XCTestCase {
    private var saved: (ThemePalette, CGFloat, NSAppearance?)!

    override func setUp() async throws {
        saved = (ThemeRuntime.palette, ThemeRuntime.scale, NSApp?.appearance)
    }

    override func tearDown() async throws {
        // The scratch stores write the runtime globals; put them back.
        (ThemeRuntime.palette, ThemeRuntime.scale) = (saved.0, saved.1)
        NSApp?.appearance = saved.2
    }

    // MARK: fixtures

    static let extensionsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)

    static let hcDarkID = "com.prosper.theme.contrast-dark"
    static let hcLightID = "com.prosper.theme.contrast-light"

    static func bundled(_ dir: String, id: String, title: String, _ appearance: ThemeAppearance) -> ThemeDescriptor {
        ThemeDescriptor(id: id, title: title, appearance: appearance, extensionID: id,
                        jsonPath: extensionsDir.appendingPathComponent("\(dir)/theme.json"))
    }

    static var hcDark: ThemeDescriptor { bundled("theme-contrast-dark", id: hcDarkID, title: "High Contrast Dark", .dark) }
    static var hcLight: ThemeDescriptor { bundled("theme-contrast-light", id: hcLightID, title: "High Contrast Light", .light) }

    static let baseColors = ##""colors": { "blue": "#E0FF00", "blueBright": "#F0FF80", "indigo": "#66C2FF", "magenta": "#FF3DC8", "bgTop": "#000000", "card": "#101010" }"##

    private func writeJSON(_ json: String, _ label: String = "th") -> URL {
        let url = tempDir(label).appendingPathComponent("theme.json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func descriptor(_ id: String, _ json: String, title: String? = nil) -> ThemeDescriptor {
        ThemeDescriptor(id: id, title: title ?? id, appearance: .dark, extensionID: "e", jsonPath: writeJSON(json))
    }

    private func store(_ defaults: UserDefaults? = nil) -> ThemeStore {
        ThemeStore(defaults: defaults ?? scratchDefaults("t862"), cacheDir: tempDir("tc"))
    }

    private static func srgb(_ c: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }

    static func same(_ a: Color, _ b: Color) -> Bool {
        let l = srgb(a), r = srgb(b)
        return abs(l.0 - r.0) < 0.001 && abs(l.1 - r.1) < 0.001 && abs(l.2 - r.2) < 0.001 && abs(l.3 - r.3) < 0.001
    }

    // MARK: parsing

    func testValidVariantListDecodesInFileOrder() throws {
        let spec = try ThemeSpec.decode(Data(##"""
        { \##(Self.baseColors), "tintLabel": "Lime",
          "variants": [
            { "key": "cyan", "label": "Cyan", "colors": { "blue": "#00E5FF", "blueBright": "#8CF4FF", "indigo": "#A98BFF" } },
            { "key": "amber-2", "label": "Amber", "colors": { "blue": "#FFB000" } } ] }
        """##.utf8))
        XCTAssertNil(spec.variantError)
        XCTAssertEqual(spec.tintLabel, "Lime")
        XCTAssertEqual(spec.variants.map(\.key), ["cyan", "amber-2"])
        XCTAssertEqual(spec.variants.map(\.label), ["Cyan", "Amber"])
        XCTAssertEqual(Set(spec.variants[0].colors.keys), ["blue", "blueBright", "indigo"])
        XCTAssertTrue(Self.same(try XCTUnwrap(spec.variants[1].colors["blue"]), Color(hex: "#FFB000")!))
        let options = try XCTUnwrap(ThemeTint.options(spec))
        XCTAssertEqual(options.map(\.key), [nil, "cyan", "amber-2"], "base first, then file order")
        XCTAssertEqual(options.map(\.label), ["Lime", "Cyan", "Amber"])
    }

    /// Every refusal keeps the theme, with its base palette, and names the error.
    func testRefusedVariantListKeepsTheThemeWithItsBasePalette() throws {
        let six = (1...6).map { ##"{ "key": "t\##($0)", "label": "T", "colors": { "blue": "#00E5FF" } }"## }.joined(separator: ",")
        let cases: [(String, String, ThemeVariantError)] = [
            ("non-accent key", ##"[{ "key": "a", "label": "A", "colors": { "blue": "#00E5FF", "bgTop": "#FFFFFF" } }]"##,
             .notAnAccentKey(variant: "a", token: "bgTop")),
            ("magenta is not an accent", ##"[{ "key": "a", "label": "A", "colors": { "magenta": "#00E5FF" } }]"##,
             .notAnAccentKey(variant: "a", token: "magenta")),
            ("bad hex", ##"[{ "key": "a", "label": "A", "colors": { "blue": "#00E5FG" } }]"##,
             .badHex(variant: "a", token: "blue")),
            ("duplicate key", ##"[{ "key": "a", "colors": { "blue": "#00E5FF" } }, { "key": "a", "colors": { "blue": "#FFB000" } }]"##,
             .duplicateKey("a")),
            ("upper-case key", ##"[{ "key": "Cyan", "colors": { "blue": "#00E5FF" } }]"##, .malformedKey("Cyan")),
            ("empty key", ##"[{ "key": "", "colors": { "blue": "#00E5FF" } }]"##, .malformedKey("")),
            ("25-byte key", ##"[{ "key": "abcdefghijklmnopqrstuvwxy", "colors": { "blue": "#00E5FF" } }]"##,
             .malformedKey("abcdefghijklmnopqrstuvwxy")),
            ("underscore key", ##"[{ "key": "a_b", "colors": { "blue": "#00E5FF" } }]"##, .malformedKey("a_b")),
            ("six variants", "[\(six)]", .tooMany(6)),
            ("not a list", ##"{ "key": "a" }"##, .notAList),
            ("entry without colors", ##"[{ "key": "a" }]"##, .malformedEntry(0)),
        ]
        let base = try ThemeSpec.decode(Data("{ \(Self.baseColors) }".utf8))
        for (name, list, expected) in cases {
            let json = "{ \(Self.baseColors), \"tintLabel\": \"Lime\", \"variants\": \(list) }"
            let spec = try ThemeSpec.decode(Data(json.utf8))
            XCTAssertEqual(spec.variantError, expected, name)
            XCTAssertTrue(spec.variants.isEmpty, "\(name): a refused list is refused whole")
            XCTAssertNil(ThemeTint.options(spec), "\(name): no dots for a refused list")
            XCTAssertEqual(spec.colors.count, base.colors.count, name)
            XCTAssertTrue(ThemePalette.resolve(spec).channelsEqual(ThemePalette.resolve(base)), "\(name): base palette changed")
            XCTAssertFalse(expected.description.isEmpty)

            // Through the store: the theme is still offered, selectable, at its base palette.
            let s = store()
            let d = descriptor("t.refused", json)
            s.setAvailable([d])
            XCTAssertTrue(s.available.contains { $0.id == "t.refused" }, "\(name): the theme went away")
            XCTAssertNil(s.tints["t.refused"], name)
            s.select(id: "t.refused", tint: "a")
            XCTAssertEqual(s.activeID, "t.refused", name)
            XCTAssertNil(s.activeTint, name)
            XCTAssertTrue(ThemeRuntime.palette.channelsEqual(ThemePalette.resolve(base)), "\(name): applied palette is not the base")
        }
    }

    /// No "variants": the spec is the one decoded before #862, field for field.
    func testNoVariantsDecodesExactlyAsBefore() throws {
        let json = ##"{ "appearance": "light", "colors": { "blue": "#0000C2", "card": "#F2F2F2" }, "assets": { "appIcon": "x.png" } }"##
        let spec = try ThemeSpec.decode(Data(json.utf8))
        let before = ThemeSpec(appearance: .light, colors: ["blue": Color(hex: "#0000C2")!, "card": Color(hex: "#F2F2F2")!],
                               assets: ["appIcon": "x.png"])
        XCTAssertEqual(spec, before)
        XCTAssertTrue(spec.variants.isEmpty)
        XCTAssertNil(spec.tintLabel)
        XCTAssertNil(spec.variantError)
        XCTAssertNil(ThemeTint.options(spec))
        XCTAssertEqual(ThemePalette.resolve(spec, tint: "anything"), ThemePalette.resolve(spec))
    }

    // MARK: merge

    /// Each bundled variant's palette is its theme's base with exactly the keys it sets replaced.
    func testVariantPaletteReplacesExactlyTheAccentFamily() throws {
        let tokens: [(String, KeyPath<ThemePalette, Color>)] = [
            ("blue", \.blue), ("blueBright", \.blueBright), ("indigo", \.indigo), ("magenta", \.magenta),
            ("terminal", \.terminal), ("bgTop", \.bgTop), ("bgBottom", \.bgBottom), ("sidebar", \.sidebar),
            ("card", \.card), ("cardHi", \.cardHi), ("textPrimary", \.textPrimary), ("textSecondary", \.textSecondary),
        ]
        var checked = 0
        for d in [Self.hcDark, Self.hcLight] {
            let spec = ThemeSpec.load(for: d)
            XCTAssertNil(spec.variantError, d.title)
            XCTAssertFalse(spec.variants.isEmpty, d.title)
            let base = ThemePalette.resolve(spec)
            for v in spec.variants {
                let p = ThemePalette.resolve(spec, tint: v.key)
                XCTAssertEqual(Set(v.colors.keys), ThemeVariant.accentKeys, "\(d.title) \(v.key): sets all three")
                for (name, kp) in tokens {
                    if let c = v.colors[name] {
                        XCTAssertTrue(Self.same(p[keyPath: kp], c), "\(d.title) \(v.key): \(name) not the variant's")
                    } else {
                        XCTAssertTrue(Self.same(p[keyPath: kp], base[keyPath: kp]), "\(d.title) \(v.key): \(name) left the base")
                    }
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 9, "4 tints on High Contrast Dark, 5 on High Contrast Light")
    }

    // MARK: persistence

    private static func twoTints(_ a: String, _ b: String) -> String {
        """
        { \(baseColors), "tintLabel": "Base", "variants": [
          { "key": "\(a)", "label": "\(a.capitalized)", "colors": { "blue": "#00E5FF" } },
          { "key": "\(b)", "label": "\(b.capitalized)", "colors": { "blue": "#FFB000" } } ] }
        """
    }

    func testTintIsRememberedPerTheme() throws {
        let defaults = scratchDefaults("t862")
        let a = descriptor("t.a", Self.twoTints("cyan", "amber"))
        let b = descriptor("t.b", Self.twoTints("b1", "b2"))
        let c = descriptor("t.c", "{ \(Self.baseColors) }")
        let s = store(defaults)
        s.setAvailable([a, b, c])
        s.select(id: "t.a", tint: "cyan")
        XCTAssertEqual(s.activeTint, "cyan")
        s.select(id: "t.b", tint: "b2")
        s.select(id: "t.c")
        XCTAssertNil(s.activeTint)
        s.select(id: "t.a")
        XCTAssertEqual(s.activeID, "t.a")
        XCTAssertEqual(s.activeTint, "cyan", "back on A: A's own tint")
        XCTAssertTrue(Self.same(ThemeRuntime.palette.blue, Color(hex: "#00E5FF")!))
        s.select(id: "t.b")
        XCTAssertEqual(s.activeTint, "b2", "back on B: B's own tint")
        XCTAssertEqual(s.rememberedTint(for: "t.a"), "cyan")
        XCTAssertEqual(s.rememberedTint(for: "t.b"), "b2")

        // A fresh store on the same defaults (a relaunch) restores both.
        let s2 = store(defaults)
        s2.setAvailable([a, b, c])
        XCTAssertEqual(s2.activeID, "t.b")
        XCTAssertEqual(s2.activeTint, "b2")
        XCTAssertEqual(s2.rememberedTint(for: "t.a"), "cyan")

        // The base dot forgets the tint.
        s2.select(id: "t.a", tint: nil)
        XCTAssertNil(s2.activeTint)
        XCTAssertNil(s2.rememberedTint(for: "t.a"))
        XCTAssertTrue(Self.same(ThemeRuntime.palette.blue, Color(hex: "#E0FF00")!))
    }

    func testUnknownOrRemovedStoredTintFallsBackToTheBase() throws {
        let defaults = scratchDefaults("t862")
        let url = writeJSON(Self.twoTints("cyan", "amber"))
        let a = ThemeDescriptor(id: "t.a", title: "A", appearance: .dark, extensionID: "e", jsonPath: url)
        defaults.set("t.a", forKey: "prosper.activeThemeID")
        defaults.set(["t.a": "gone"], forKey: "prosper.themeTints")
        let s = store(defaults)
        s.setAvailable([a])
        XCTAssertEqual(s.activeID, "t.a")
        XCTAssertNil(s.activeTint, "an unknown key is the base, not applied as-is")
        XCTAssertNil(s.rememberedTint(for: "t.a"))
        XCTAssertTrue(Self.same(ThemeRuntime.palette.blue, Color(hex: "#E0FF00")!))

        // A known key, then the theme loses its variants (an update): the base, no error.
        s.select(id: "t.a", tint: "amber")
        XCTAssertEqual(s.activeTint, "amber")
        try "{ \(Self.baseColors) }".write(to: url, atomically: true, encoding: .utf8)
        s.setAvailable([a])
        XCTAssertEqual(s.activeID, "t.a")
        XCTAssertNil(s.activeTint)
        XCTAssertNil(s.tints["t.a"])
        XCTAssertTrue(Self.same(ThemeRuntime.palette.blue, Color(hex: "#E0FF00")!))
    }

    func testThemeWithoutVariantsIgnoresAStoredKey() {
        let defaults = scratchDefaults("t862")
        let c = descriptor("t.c", "{ \(Self.baseColors) }")
        defaults.set("t.c", forKey: "prosper.activeThemeID")
        defaults.set(["t.c": "cyan"], forKey: "prosper.themeTints")
        let s = store(defaults)
        s.setAvailable([c])
        XCTAssertEqual(s.activeID, "t.c")
        XCTAssertNil(s.activeTint)
        XCTAssertNil(s.tints["t.c"])
        s.select(id: "t.c", tint: "cyan")
        XCTAssertNil(s.activeTint)
        XCTAssertTrue(Self.same(ThemeRuntime.palette.blue, Color(hex: "#E0FF00")!))
    }

    // MARK: live apply

    /// A tint pick from another theme is one apply: one onChange, one generation, and the
    /// palette it publishes is already the tinted one (never the base in between).
    func testTintPickPublishesOnePaletteChange() {
        let a = descriptor("t.a", Self.twoTints("cyan", "amber"))
        let c = descriptor("t.c", "{ \(Self.baseColors.replacingOccurrences(of: "#E0FF00", with: "#123456")) }")
        let s = store()
        s.setAvailable([a, c])
        s.select(id: "t.c")
        var seen: [Color] = []
        s.onChange = { seen.append(ThemeRuntime.palette.blue) }
        let g0 = s.generation
        s.select(id: "t.a", tint: "cyan")
        XCTAssertEqual(seen.count, 1, "one palette change")
        XCTAssertEqual(s.generation, g0 + 1)
        XCTAssertTrue(seen.allSatisfy { Self.same($0, Color(hex: "#00E5FF")!) }, "no base palette published on the way")
        s.select(id: "t.a", tint: "amber")
        XCTAssertEqual(seen.count, 2, "tint to tint: one change")
        XCTAssertTrue(Self.same(seen[1], Color(hex: "#FFB000")!))
        s.select(id: "t.a", tint: "amber")
        XCTAssertEqual(seen.count, 2, "re-picking the applied tint is a no-op")
    }

    // MARK: UI — the tint dots on a theme's row
    // SwiftUI builds no accessibility tree for a window that was never shown (the first run of
    // these tests found every element list empty), so the dots are checked through the store the
    // row reads, the row's own press handler, and the hosted list's laid-out size.

    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
    }

    /// The list on `s` in a never-shown window at `backing`: its laid-out size and the backing
    /// scale it was laid out at. `width` nil = the list's own ideal width.
    private func listSize(_ s: ThemeStore, backing: CGFloat?, width: CGFloat? = 620) -> (CGSize, CGFloat) {
        let h = NSHostingView(rootView: ThemeList(theme: s, paneID: "appearance").padding(16).frame(width: width))
        h.frame = CGRect(origin: .zero, size: CGSize(width: width ?? 900, height: 600))
        let win = FixedBacking862Window(contentRect: h.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.fixedBacking = backing
        win.isReleasedWhenClosed = false
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.contentView = h
        defer { win.contentView = NSView(); win.close() }
        flush(h)
        return (h.fittingSize, win.backingScaleFactor)
    }

    private func listStore(variants: Bool = true) throws -> ThemeStore {
        let s = store()
        let plain = descriptor("t.plain", "{ \(Self.baseColors) }", title: "Plain")
        var dark = Self.hcDark, light = Self.hcLight
        if !variants {
            // The same two themes with no "variants": the rows as they were before #862.
            for d in [Self.hcDark, Self.hcLight] {
                let path = try XCTUnwrap(d.jsonPath)
                var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                obj["variants"] = nil
                obj["tintLabel"] = nil
                let url = tempDir("plain").appendingPathComponent("theme.json")
                try JSONSerialization.data(withJSONObject: obj).write(to: url)
                let copy = ThemeDescriptor(id: d.id, title: d.title, appearance: d.appearance, extensionID: d.extensionID, jsonPath: url)
                if d.id == Self.hcDarkID { dark = copy } else { light = copy }
            }
        }
        s.setAvailable([.builtIn, dark, plain, light])
        return s
    }

    /// The row reads `tints[id]`: 1 + N options (base first) for a theme with variants, none
    /// for the others. The dots take room on the row: the list grows by at least the six
    /// High Contrast Light dot slots.
    func testRowShowsOnePlusNDotsOnlyForThemesWithVariants() throws {
        ThemeRuntime.scale = 1
        let s = try listStore()
        XCTAssertEqual(s.tints[Self.hcDarkID]?.map(\.label), ["Lime", "Cyan", "Amber", "Violet", "White"])
        XCTAssertEqual(s.tints[Self.hcDarkID]?.map(\.key), [nil, "cyan", "amber", "violet", "white"])
        XCTAssertEqual(s.tints[Self.hcLightID]?.map(\.label), ["Blue", "Lime", "Cyan", "Amber", "Violet", "Black"])
        XCTAssertEqual(s.tints[Self.hcLightID]?.map(\.key), [nil, "lime", "cyan", "amber", "violet", "black"])
        XCTAssertNil(s.tints[ThemeDescriptor.builtInID])
        XCTAssertNil(s.tints["t.plain"])
        // Nothing remembered yet: each tinted row rings its base dot.
        XCTAssertNil(s.rememberedTint(for: Self.hcDarkID))
        XCTAssertNil(s.rememberedTint(for: Self.hcLightID))

        for backing in [1, 2] as [CGFloat] {
            let (dots, b) = listSize(s, backing: backing, width: nil)
            ThemeRuntime.scale = 1
            let (none, _) = listSize(try listStore(variants: false), backing: backing, width: nil)
            ThemeRuntime.scale = 1
            XCTAssertGreaterThanOrEqual(dots.width - none.width, 6 * 18 + 5 * 4 - 1 / b,
                                        "backing \(b): the six Light dots widen the list")
        }
    }

    /// One press on a dot of an inactive theme: that theme, with that tint, in one apply. The
    /// press goes through the row's own handler (the closure every dot calls).
    func testDotPressSelectsThemeAndTintInOneStep() throws {
        ThemeRuntime.scale = 1
        let s = try listStore()
        XCTAssertEqual(s.activeID, ThemeDescriptor.builtInID)
        let list = ThemeList(theme: s, paneID: "appearance")
        let dark = try XCTUnwrap(s.available.first { $0.id == Self.hcDarkID })
        var changes = 0
        s.onChange = { changes += 1 }
        list.pickTint(dark, "cyan")
        XCTAssertEqual(s.activeID, Self.hcDarkID, "the dot selects its theme")
        XCTAssertEqual(s.activeTint, "cyan", "with its tint")
        XCTAssertEqual(changes, 1, "in one apply")
        XCTAssertTrue(Self.same(ThemeRuntime.palette.blue, Color(hex: "#00E5FF")!))
        XCTAssertEqual(s.rememberedTint(for: Self.hcDarkID), "cyan", "the row rings the cyan dot")

        // The row itself: the theme with its remembered tint.
        s.select(id: Self.hcLightID)
        s.select(id: Self.hcDarkID)
        XCTAssertEqual(s.activeTint, "cyan")

        // The base dot: back to the base palette, nothing remembered.
        list.pickTint(dark, nil)
        XCTAssertNil(s.activeTint)
        XCTAssertNil(s.rememberedTint(for: Self.hcDarkID))
        XCTAssertTrue(Self.same(ThemeRuntime.palette.blue, Color(hex: "#E0FF00")!))
    }

    /// Fixed slots: the list is as tall with dots as without, and stays that tall with the
    /// selection on another theme, another tint, the base or a theme without dots, at UI scale
    /// 1.0, 0.85 and 0.7 on the 1x and 2x pixel grids (one backing pixel of slack). The rows
    /// stack, so an equal height means no row moved.
    func testDotsAndSelectionNeverMoveTheRows() throws {
        for backing in [1, 2] as [CGFloat] {
            for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                ThemeRuntime.scale = scale
                let plain = try listStore(variants: false)
                ThemeRuntime.scale = scale
                let (before, b) = listSize(plain, backing: backing)
                let s = try listStore()
                ThemeRuntime.scale = scale
                let (first, _) = listSize(s, backing: backing)
                let tag = "scale \(scale), backing \(b)"
                let pixel = 1 / b
                XCTAssertEqual(first.height, before.height, accuracy: pixel, "\(tag): the dots changed the list height")
                for (id, tint) in [(Self.hcDarkID, "cyan"), (Self.hcDarkID, "white"), (Self.hcLightID, "black"),
                                   (Self.hcDarkID, nil), ("t.plain", nil)] as [(String, String?)] {
                    s.select(id: id, tint: tint)
                    ThemeRuntime.scale = scale
                    let (now, _) = listSize(s, backing: backing)
                    XCTAssertEqual(now.height, first.height, accuracy: pixel,
                                   "\(tag): a row moved after selecting \(id) \(tint ?? "base")")
                }
            }
        }
    }

    // MARK: QA #744 follow-ups (#862 A2)

    /// INFO-6: a tint pick refreshes the picked theme's swatch strip (`previews`), so the row
    /// never shows the palette it had before the pick.
    func testTintPickRefreshesTheSwatchPreview() throws {
        let a = descriptor("t.a", Self.twoTints("cyan", "amber"))
        let s = store()
        s.setAvailable([a])
        XCTAssertTrue(Self.same(try XCTUnwrap(s.previews["t.a"]).blue, Color(hex: "#E0FF00")!), "nothing picked: the base")
        s.select(id: "t.a", tint: "cyan")
        XCTAssertTrue(Self.same(try XCTUnwrap(s.previews["t.a"]).blue, Color(hex: "#00E5FF")!), "the strip shows the picked tint")
        s.select(id: "t.a", tint: "amber")
        XCTAssertTrue(Self.same(try XCTUnwrap(s.previews["t.a"]).blue, Color(hex: "#FFB000")!), "and the next one")
        s.select(id: "t.a", tint: nil)
        XCTAssertTrue(Self.same(try XCTUnwrap(s.previews["t.a"]).blue, Color(hex: "#E0FF00")!), "and back to the base")
    }

    /// INFO-6: the no-op guard compares the tint too. A variant whose colours equal the base
    /// palette still becomes the active tint (the palette alone would call the pick a no-op).
    func testTintWithTheBaseColoursStillBecomesTheActiveTint() {
        let json = """
        { \(Self.baseColors), "variants": [ { "key": "same", "label": "Same", "colors": { "blue": "#E0FF00" } } ] }
        """
        let a = descriptor("t.a", json)
        let s = store()
        s.setAvailable([a])
        s.select(id: "t.a")
        XCTAssertNil(s.activeTint)
        s.select(id: "t.a", tint: "same")
        XCTAssertEqual(s.activeTint, "same", "the palette is unchanged, the tint is not")
        s.select(id: "t.a", tint: nil)
        XCTAssertNil(s.activeTint, "and back")
    }

    /// INFO-6: the key cap is exactly 24 bytes: 24 decodes, 25 refuses the list.
    func testVariantKeyCapIsExactly24Bytes() throws {
        func list(_ key: String) -> String {
            "{ \(Self.baseColors), \"variants\": [ { \"key\": \"\(key)\", \"colors\": { \"blue\": \"#00E5FF\" } } ] }"
        }
        let k24 = String(repeating: "a", count: 23) + "-", k25 = String(repeating: "a", count: 25)
        XCTAssertTrue(ThemeVariant.isValidKey(k24))
        XCTAssertFalse(ThemeVariant.isValidKey(k25))
        let ok = try ThemeSpec.decode(Data(list(k24).utf8))
        XCTAssertNil(ok.variantError)
        XCTAssertEqual(ok.variants.map(\.key), [k24], "24 bytes: kept")
        let refused = try ThemeSpec.decode(Data(list(k25).utf8))
        XCTAssertEqual(refused.variantError, .malformedKey(k25), "25 bytes: refused")
        XCTAssertTrue(refused.variants.isEmpty)
    }

    /// INFO-6: dot N picks tint N. Each dot's press runs the closure its button holds
    /// (`ThemeTintDots.action`), on the dots the row builds (`ThemeList.dots`).
    func testEachDotPicksItsOwnTint() throws {
        ThemeRuntime.scale = 1
        let s = try listStore()
        let list = ThemeList(theme: s, paneID: "appearance")
        for id in [Self.hcDarkID, Self.hcLightID] {
            let d = try XCTUnwrap(s.available.first { $0.id == id })
            let options = try XCTUnwrap(s.tints[id])
            // Last to first, so every press moves off the tint before it.
            for i in options.indices.reversed() {
                list.dots(d, options: options, selected: s.activeID == id).action(i)()
                XCTAssertEqual(s.activeID, id, "\(id) dot \(i)")
                XCTAssertEqual(s.activeTint, options[i].key, "\(id) dot \(i) picks its own tint")
                XCTAssertEqual(s.rememberedTint(for: id), options[i].key)
            }
        }
    }

    /// INFO-6 and INFO-4: the label defaults. A variant without a usable label is named by its
    /// key; a base without a usable `tintLabel` is "Default". Empty, blank and invisible-only
    /// labels are not usable; a non-string is ignored.
    func testTintLabelDefaults() throws {
        for (name, raw) in [("absent", nil), ("empty", "\"\""), ("blank", "\"   \""), ("invisible", "\"\\u200B\\u2028\\u202E\""),
                            ("control", "\"\\u0007\\t\\n\""), ("number", "42")] as [(String, String?)] {
            let label = raw.map { ", \"label\": \($0)" } ?? ""
            let tintLabel = raw.map { "\"tintLabel\": \($0), " } ?? ""
            let json = "{ \(Self.baseColors), \(tintLabel)\"variants\": [ { \"key\": \"cyan\"\(label), \"colors\": { \"blue\": \"#00E5FF\" } } ] }"
            let spec = try ThemeSpec.decode(Data(json.utf8))
            XCTAssertNil(spec.variantError, name)
            XCTAssertNil(spec.tintLabel, "\(name): no usable tintLabel")
            XCTAssertEqual(try XCTUnwrap(ThemeTint.options(spec), name).map(\.label), ["Default", "cyan"], name)
        }
    }

    /// INFO-4: a label loses control, format and invisible characters, is trimmed, and is cut
    /// at 32 Unicode scalars: 32 kept whole, 33 cut to 32. Combining marks count one each.
    func testTintLabelIsCleanedAndCappedAt32Scalars() throws {
        func labels(_ base: String, _ variant: String) throws -> [String] {
            let enc = { (v: String) in String(data: try JSONSerialization.data(withJSONObject: [v], options: [.fragmentsAllowed]), encoding: .utf8)!.dropFirst().dropLast() }
            let b = try enc(base), v = try enc(variant)
            let json = "{ \(Self.baseColors), \"tintLabel\": \(b), \"variants\": [ { \"key\": \"cyan\", \"label\": \(v), \"colors\": { \"blue\": \"#00E5FF\" } } ] }"
            return try XCTUnwrap(ThemeTint.options(try ThemeSpec.decode(Data(json.utf8)))).map(\.label)
        }
        XCTAssertEqual(try labels(" Li\u{200B}me\n", "\u{202E}Cy\u{0000}an\u{2028}"), ["Lime", "Cyan"], "invisible characters dropped, ends trimmed")
        let x32 = String(repeating: "x", count: 32), x33 = x32 + "y"
        XCTAssertEqual(try labels(x32, x32), [x32, x32], "32 scalars: kept whole")
        XCTAssertEqual(try labels(x33, x33), [x32, x32], "33 scalars: cut to 32")
        let marks = "a" + String(repeating: "\u{0301}", count: 200)
        XCTAssertEqual(try labels(marks, "Amber")[0].unicodeScalars.count, 32, "one Character of 201 scalars is cut by scalars")
        XCTAssertEqual(try labels("Two words", "  Amber  "), ["Two words", "Amber"], "inner spaces stay")
        XCTAssertEqual(ThemeVariant.cleanLabel(String(repeating: "\u{200B}", count: 40) + "Lime"), "Lime", "the cap counts what is kept")
    }

    /// INFO-4: a refused list is not logged again by a rescan that finds the same refusal, and
    /// the refused key reaches the log as printable ASCII, cut at 32.
    func testRefusedVariantListIsNotRepeatedOnRescanAndShownSafely() {
        let badKey = "Bad\\u0007\\u202E" + String(repeating: "x", count: 200)   // JSON escapes: BEL, RLO
        let bad = descriptor("t.bad", "{ \(Self.baseColors), \"variants\": [ { \"key\": \"\(badKey)\", \"colors\": { \"blue\": \"#00E5FF\" } } ] }")
        let six = descriptor("t.six", "{ \(Self.baseColors), \"variants\": [\((1...6).map { _ in "{}" }.joined(separator: ","))] }")
        let ok = descriptor("t.ok", Self.twoTints("cyan", "amber"))
        let s = store()
        var lines: [String] = []
        s.onVariantRefusalLogged = { lines.append($0) }
        s.setAvailable([bad, ok])
        s.setAvailable([bad, ok])
        XCTAssertEqual(lines.count, 1, "a rescan does not log the same theme again")
        s.setAvailable([bad, six, ok])
        s.setAvailable([bad, six, ok])
        XCTAssertEqual(lines.count, 2, "another theme's refusal is logged once")
        XCTAssertTrue(lines.allSatisfy { $0.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) || $0 == "…" } },
                      "printable ASCII only: \(lines)")
        XCTAssertTrue(lines[0].contains("\"Bad??" + String(repeating: "x", count: 27) + "…\""), lines[0])
        XCTAssertLessThan(lines[0].count, 200, lines[0])
        XCTAssertTrue(lines[1].contains("t.six") && lines[1].contains("6 variants"), lines[1])
        // Both sides of the shown bound.
        let k32 = String(repeating: "k", count: 32)
        XCTAssertEqual(ThemeVariantError.shown(k32), k32)
        XCTAssertEqual(ThemeVariantError.shown(k32 + "k"), k32 + "…")
        XCTAssertEqual(ThemeVariantError.notAnAccentKey(variant: "a", token: "bg\u{0000}Top").description,
                       "variant \"a\" sets bg?Top; only blue, blueBright, indigo")
    }

    /// #862 A2 review r2: the log dedupe remembers the LAST line per theme. The same refusal
    /// over rescans is one line; a new reason, a fix then the same refusal again, and a removal
    /// then the same refusal again each log again.
    func testRefusalLogRepeatsOnlyForANewReasonAFixOrARemoval() throws {
        let url = writeJSON("{}")
        let d = ThemeDescriptor(id: "t.x", title: "X", appearance: .dark, extensionID: "e", jsonPath: url)
        let other = descriptor("t.six", "{ \(Self.baseColors), \"variants\": [\((1...6).map { _ in "{}" }.joined(separator: ","))] }")
        func write(_ variants: String) throws {
            try "{ \(Self.baseColors), \"variants\": \(variants) }".write(to: url, atomically: true, encoding: .utf8)
        }
        let badHex = ##"[{ "key": "a", "colors": { "blue": "#00E5FG" } }]"##
        let dup = ##"[{ "key": "a", "colors": { "blue": "#00E5FF" } }, { "key": "a", "colors": { "blue": "#FFB000" } }]"##
        let fixed = ##"[{ "key": "a", "colors": { "blue": "#00E5FF" } }]"##
        let s = store()
        var lines: [String] = []
        s.onVariantRefusalLogged = { lines.append($0) }

        try write(badHex)
        s.setAvailable([d, other])
        s.setAvailable([d, other])
        XCTAssertEqual(lines.count, 2, "the same refusals over two rescans: one line each")
        try write(dup)
        s.setAvailable([d, other])
        XCTAssertEqual(lines.count, 3, "the reason changed: logged")
        XCTAssertTrue(lines.last?.contains("appears twice") == true, "\(lines)")   // never index: a red row must not trap
        s.setAvailable([d, other])
        XCTAssertEqual(lines.count, 3, "and not again")
        try write(fixed)
        s.setAvailable([d, other])
        XCTAssertEqual(lines.count, 3, "a fixed list logs nothing")
        try write(dup)
        s.setAvailable([d, other])
        XCTAssertEqual(lines.count, 4, "fixed, then broken the same way: logged again")
        s.setAvailable([other])
        XCTAssertEqual(lines.count, 4, "the theme left: nothing to log")
        s.setAvailable([d, other])
        XCTAssertEqual(lines.count, 5, "back with the same refusal: logged again")
        XCTAssertEqual(lines.filter { $0.contains("t.six") }.count, 1, "the other theme's unchanged refusal: once")
    }

    /// The dump of `v`'s outermost modifier: the lines from its top-level "modifier" child on.
    /// SwiftUI builds no accessibility tree for a never-shown window, so the accessibility
    /// attachment is read off the view value, as AgentWindowRenameTests does.
    private static func outerModifier<V: View>(_ v: V) -> String {
        var out = ""
        dump(v, to: &out)
        let lines = out.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { $0.hasPrefix("  ▿ modifier:") || $0.hasPrefix("  - modifier:") }) else { return "" }
        // Class instances are numbered per dump ("#3"): the same attachment sits at another number.
        return lines[i...].joined(separator: "\n")
            .replacingOccurrences(of: "#[0-9]+", with: "#", options: .regularExpression)
            .replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0x", options: .regularExpression)
    }

    private static func dumped<V: View>(_ v: V) -> String {
        var out = ""
        dump(v, to: &out)
        return out
    }

    /// INFO-3: on the dots, only the active theme's ringed dot carries the selected trait; an
    /// inactive theme's ringed dot says "remembered"; every dot has its label as a tooltip.
    /// Each dot's accessibility attachment is compared with the one the same modifiers build
    /// with and without the trait.
    func testOnlyTheActiveThemesDotIsSelectedAndEachDotHasAHelpTag() throws {
        ThemeRuntime.scale = 1
        let s = try listStore()
        s.select(id: Self.hcLightID, tint: "amber")
        s.select(id: Self.hcDarkID, tint: "cyan")
        XCTAssertEqual(s.activeID, Self.hcDarkID)
        let list = ThemeList(theme: s, paneID: "appearance")
        func expected(_ title: String, _ label: String, remembered: Bool, selected: Bool) -> String {
            let themeTitle = title, t = (label: label, x: 0)
            return Self.outerModifier(Color.clear
                .accessibilityLabel("\(themeTitle), \(t.label)")
                .accessibilityValue(remembered ? "remembered" : "")
                .accessibilityAddTraits(selected ? .isSelected : []))
        }
        XCTAssertNotEqual(expected("T", "L", remembered: false, selected: true), expected("T", "L", remembered: false, selected: false),
                          "the trait shows in the attachment")
        var selectedDots = 0
        for (id, remembered) in [(Self.hcDarkID, "cyan"), (Self.hcLightID, "amber")] {
            let d = try XCTUnwrap(s.available.first { $0.id == id })
            let options = try XCTUnwrap(s.tints[id])
            let active = s.activeID == id
            let dots = list.dots(d, options: options, selected: active)
            for (i, t) in options.enumerated() {
                let on = t.key == remembered
                let got = Self.outerModifier(dots.dot(i))
                let want = expected(d.title, t.label, remembered: on && !active, selected: on && active)
                XCTAssertEqual(got, want, "\(d.title) \(t.label): selected only on the active theme, remembered on another")
                if got == expected(d.title, t.label, remembered: false, selected: true) { selectedDots += 1 }
                // The label also rides in the accessibility label; the help tag is one more copy.
                func copies(_ x: String) -> Int { x.components(separatedBy: "\"\(t.label)\"").count - 1 }
                XCTAssertGreaterThan(copies(Self.dumped(dots.dot(i))), copies(want), "\(d.title) \(t.label): a help tag with the label")
            }
        }
        XCTAssertEqual(selectedDots, 1, "one selected tint in the whole list")
    }

    /// INFO-3: a theme row says it is the active theme (the checkmark beside it is hidden from
    /// VoiceOver): the selected trait on the active row's button, on a tinted and a plain row.
    func testTheActiveThemeRowCarriesTheSelectedTrait() throws {
        ThemeRuntime.scale = 1
        let s = try listStore()
        let list = ThemeList(theme: s, paneID: "appearance")
        func expected(_ id: String, _ selected: Bool) -> String {
            Self.outerModifier(Color.clear.accessibilityIdentifier("theme-row:\(id)").accessibilityAddTraits(selected ? .isSelected : []))
        }
        XCTAssertNotEqual(expected("x", true), expected("x", false), "the trait shows in the attachment")
        let dark = try XCTUnwrap(s.available.first { $0.id == Self.hcDarkID })
        let plain = try XCTUnwrap(s.available.first { $0.id == "t.plain" })
        for selected in [true, false] {
            XCTAssertEqual(Self.outerModifier(list.tintedRowButton(dark, selected: selected, palette: .default)),
                           expected(dark.id, selected), "tinted row, selected \(selected)")
            XCTAssertEqual(Self.outerModifier(list.plainRow(plain, selected: selected, palette: .default)),
                           expected(plain.id, selected), "plain row, selected \(selected)")
        }
    }

    /// INFO-2: the list at the real room. The Settings window's minimum width
    /// (`SettingsWindow.contentMinSize`, floored at the 85% row) less the sidebar (218), the
    /// pane's (2 x 26) and the card's (2 x 16) insets: 518 pt at 1.0, 440 at 0.85, 486 at 0.7.
    /// Nothing overflows that width (a dot slot or the checkmark pushed past the card edge would),
    /// and the High Contrast captions wrap by the pinned number of lines, on 1x and 2x.
    func testHighContrastRowsFitTheMinimumSettingsWidth() throws {
        // Extra caption lines across the two High Contrast rows at the minimum width. Measured
        // (#862 A2): none at any scale; QA #744's estimate of a wrapped caption did not hold.
        let wraps: [CGFloat: Int] = [1.0: 0, 0.85: 0, 0.7: 0]
        for backing in [1, 2] as [CGFloat] {
            for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                let s = try listStore()
                s.select(id: Self.hcLightID, tint: "amber")
                ThemeRuntime.scale = scale
                let room = SettingsWindow.contentMinSize(scale: scale).width - sz(218 + 2 * 26 + 2 * 16)
                let hc = NSHostingController(rootView: ThemeList(theme: s, paneID: "appearance"))
                let win = FixedBacking862Window(contentRect: CGRect(x: 0, y: 0, width: room, height: 600), styleMask: [.titled],
                                                backing: .buffered, defer: false)
                win.fixedBacking = backing
                win.isReleasedWhenClosed = false
                win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
                win.contentView = hc.view
                defer { win.contentView = NSView(); win.close() }
                flush(hc.view)
                let fit = hc.sizeThatFits(in: CGSize(width: room, height: 10_000))
                let wide = hc.sizeThatFits(in: CGSize(width: 4_000, height: 10_000))
                let line = NSHostingView(rootView: Text("Ag").font(Neon.font(.caption))).fittingSize.height
                let pixel = 1 / win.backingScaleFactor, n = CGFloat(wraps[scale] ?? 0)
                let tag = "scale \(scale), backing \(win.backingScaleFactor), room \(room)"
                print("#862a2 layout \(tag): fit \(fit), wide \(wide), caption line \(line)")
                XCTAssertLessThanOrEqual(fit.width, room + pixel, "\(tag): something overflows the card")
                XCTAssertGreaterThan(hc.sizeThatFits(in: CGSize(width: 150, height: 10_000)).width, 150 + pixel,
                                     "\(tag): the measure reports an overflow (fixed dot slots do not shrink)")
                XCTAssertEqual(fit.height - wide.height, n * line, accuracy: (n + 1) * pixel, "\(tag): caption lines added")
            }
        }
        ThemeRuntime.scale = 1
    }

    // MARK: evidence renders (operator review; skipped in the normal suite)

    static var renderDir: URL? {
        ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func render<V: View>(_ view: V, width: CGFloat, appearance: ThemeAppearance, name: String) throws {
        let root = view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, appearance.colorScheme)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: CGSize(width: width, height: max(1, h.fittingSize.height)))
        let win = NSWindow(contentRect: h.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: appearance.nsAppearanceName)
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.contentView = h
        defer { win.contentView = NSView(); win.close() }
        flush(h)
        let backing: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((h.bounds.width * backing).rounded()),
            pixelsHigh: Int((h.bounds.height * backing).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = h.bounds.size
        h.cacheDisplay(in: h.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: try XCTUnwrap(Self.renderDir).appendingPathComponent("\(name).png"))
    }

    /// (a) the theme list (every bundled theme, the two High Contrast rows with their dots)
    /// at UI scale 1.0, 0.85, 0.7 under a dark and a light theme; (b) one sample sheet per
    /// High Contrast tint.
    func testTintEvidenceRenders() throws {
        guard Self.renderDir != nil else { throw XCTSkip("#862 evidence renders: set PROSPER_RENDER_DIR to write them") }
        let all = try FileManager.default.contentsOfDirectory(at: Self.extensionsDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { dir -> ThemeDescriptor in
                // The real manifests: the ids and titles the user sees.
                let loaded = try ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: "2.0.0")
                let t = try XCTUnwrap(loaded.manifest.contributes?.allThemes.first)
                return ThemeDescriptor(id: t.id, title: t.title, appearance: ThemeAppearance(rawValue: t.appearance ?? "dark") ?? .dark,
                                       extensionID: loaded.id, jsonPath: dir.appendingPathComponent(t.path))
            }
        let s = store()
        s.setAvailable(all)
        for (appearance, id, tint) in [(ThemeAppearance.dark, Self.hcDarkID, "cyan"), (.light, Self.hcLightID, "amber")] {
            s.select(id: id, tint: tint)
            for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                ThemeRuntime.scale = scale
                try render(ZStack { SettingsBackground(); ThemeList(theme: s, paneID: "appearance").padding(sz(16)).neonCard().padding(sz(16)) },
                           width: 620 * scale, appearance: appearance, name: "list-\(appearance.rawValue)-s\(scale)")
            }
        }
        ThemeRuntime.scale = 1
        for d in [Self.hcDark, Self.hcLight] {
            for t in try XCTUnwrap(s.tints[d.id]) {
                s.select(id: d.id, tint: t.key)
                try render(TintSampleSheet(title: "\(d.title) · \(t.label)"), width: 520, appearance: d.appearance,
                           name: "sheet-\(d.appearance.rawValue)-\(t.label.lowercased())")
            }
        }
    }
}

/// The accent the ways the app uses it: a section label, accent text and a link on bgTop
/// and on card, a selected row (bar + fill), a switch, a primary button, next to the alert
/// and success roles it must stay apart from.
private struct TintSampleSheet: View {
    let title: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            SettingsBackground()
            VStack(alignment: .leading, spacing: sz(12)) {
                Text(title).font(Neon.font(18, weight: .bold, design: .rounded)).foregroundStyle(Neon.textPrimary)
                HStack(spacing: sz(12)) {
                    Text("Accent text on bgTop").foregroundStyle(Neon.blue)
                    Text("A link").underline().foregroundStyle(Neon.blueBright)
                }
                NeonSectionLabel(title: "Section label", accent: "Section")
                NeonSection("General", accent: "Gen", footer: "Footer text in textSecondary.") {
                    VStack(alignment: .leading, spacing: sz(10)) {
                        HStack(spacing: sz(8)) {
                            NeonSelectionBar()
                            Text("Selected row").foregroundStyle(Neon.textPrimary)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Neon.blueBright)
                        }
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(6))
                        .background(NeonSelectedRowFill(selected: true))
                        NeonRow("A switch", subtitle: "The window is never key, so AppKit draws it inactive") {
                            Toggle("", isOn: .constant(true)).toggleStyle(.switch).tint(Neon.blue).labelsHidden()
                        }
                        HStack(spacing: sz(12)) {
                            Text("Accent text on card").foregroundStyle(Neon.blue)
                            Text("A link").underline().foregroundStyle(Neon.blueBright)
                        }
                        HStack(spacing: sz(10)) {
                            Button("Primary") {}.buttonStyle(.neon)
                            Button("Delete") {}.buttonStyle(.neonDestructive)
                            Text("Error").foregroundStyle(Neon.magenta)
                            Text("Connected").foregroundStyle(Neon.terminal)
                        }
                        RoundedRectangle(cornerRadius: sz(3)).fill(Neon.barFill).frame(height: sz(6))
                    }
                }
            }
            .padding(sz(20))
        }
    }
}

/// A window whose backing scale can be pinned (see KeyMappingRowLayoutTests).
private final class FixedBacking862Window: NSWindow {
    var fixedBacking: CGFloat?
    override var backingScaleFactor: CGFloat { fixedBacking ?? super.backingScaleFactor }
}
