import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1308 (#1076 follow-up): with Increase Contrast on, a custom or Marketplace theme's line token
/// (divider, either card border end) under 3:1 on its card falls back to the full text colour,
/// and secondary text reads 4.5:1. The themes are fakes written to a temp dir; every store injects
/// both accessibility readers and a private notification center; no window is made.
@MainActor
final class IncreaseContrastCustomThemeTests: XCTestCase {
    private static var savedPalette = ThemePalette.default
    private static var savedIC = false
    private static var savedOpacity: CGFloat = 1
    private static var savedFrost = false

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            Self.savedPalette = ThemeRuntime.palette
            Self.savedIC = ThemeRuntime.increaseContrast
            Self.savedOpacity = ThemeRuntime.opacity
            Self.savedFrost = ThemeRuntime.frost
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ThemeRuntime.increaseContrast = Self.savedIC
            ThemeRuntime.palette = Self.savedPalette
            ThemeRuntime.opacity = Self.savedOpacity
            ThemeRuntime.frost = Self.savedFrost
        }
        super.tearDown()
    }

    private static let lowJSON = """
    {"appearance":"dark","colors":{"card":"#101820","cardHi":"#18222C","blue":"#1A2430","indigo":"#20303C",
    "textSecondary":"#2A3A48","textPrimary":"#E8F2FC"}}
    """
    private static let goodJSON = """
    {"appearance":"dark","colors":{"card":"#101820","cardHi":"#18222C","blue":"#3FD0FF","indigo":"#8FA8FF",
    "textSecondary":"#9FB0C4","textPrimary":"#E8F2FC"}}
    """

    private static func comps(_ c: Color) -> [CGFloat] {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent]
    }

    private static func same(_ a: Color, _ b: Color) -> Bool {
        zip(comps(a), comps(b)).allSatisfy { abs($0 - $1) < 0.001 }
    }

    /// Writes `json` as a custom theme in a temp themes dir, applies it through a scratch store whose
    /// readers are injected, and returns the store, the centre and the flag the readers return.
    private func applied(_ json: String, ic: Bool, label: String) throws -> (ThemeStore, NotificationCenter, Box) {
        let dir = tempDir(label)
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        let box = Box(ic)
        let center = NotificationCenter()
        let store = ThemeStore(defaults: scratchDefaults(label), cacheDir: tempDir(label + "cache"),
                               increaseContrastReader: { box.on }, reduceTransparencyReader: { false },
                               workspaceCenter: center)
        let d = ThemeDescriptor(id: "test.1308.\(label)", title: label, appearance: .dark,
                                extensionID: "test.1308", jsonPath: file)
        store.setAvailable([d])
        store.select(id: d.id)
        XCTAssertEqual(store.activeID, d.id)
        return (store, center, box)
    }

    final class Box { var on: Bool; init(_ on: Bool) { self.on = on } }

    private static func flip(_ box: Box, _ on: Bool, _ center: NotificationCenter) {
        box.on = on
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    /// Low-contrast custom theme: on, the divider, both border ends and secondary text reach 3:1 / 4.5:1
    /// on the card and cardHi (they fall back to the text colour); off, the tokens are the theme's own.
    func testLowContrastCustomThemeFallsBackOnlyUnderIncreaseContrast() throws {
        let (store, center, box) = try applied(Self.lowJSON, ic: true, label: "low")
        defer { withExtendedLifetime(store) {} }  // the store owns the notification observer
        let p = ThemeRuntime.palette
        let lines = [("divider", Neon.stroke)] + Neon.cardStrokeColors.enumerated().map { ("border end \($0.offset)", $0.element) }
        XCTAssertEqual(Neon.cardStrokeColors.count, 2)
        for (name, c) in lines {
            XCTAssertTrue(Self.same(c, p.textPrimary), "\(name) did not fall back")
            for s in [p.card, p.cardHi] {
                let r = ThemeContrastTests.contrast(NSColor(c), on: NSColor(s))
                XCTAssertGreaterThanOrEqual(r, 3, "\(name) is \(r):1")
            }
        }
        for s in [p.card, p.cardHi] {
            let r = ThemeContrastTests.contrast(NSColor(Neon.textSecondary), on: NSColor(s))
            XCTAssertGreaterThanOrEqual(r, 4.5, "secondary text is \(r):1")
        }
        XCTAssertTrue(Self.same(Neon.textSecondary, p.textPrimary))

        Self.flip(box, false, center)
        XCTAssertFalse(ThemeRuntime.increaseContrast)
        XCTAssertTrue(Self.same(Neon.stroke, p.blue.opacity(0.16)), "off: the theme's own faint divider")
        let ends = Neon.cardStrokeColors
        XCTAssertEqual(ends.count, 2)
        XCTAssertTrue(ends.first.map { Self.same($0, p.blue.opacity(0.38)) } ?? false, "off: own border start")
        XCTAssertTrue(ends.last.map { Self.same($0, p.indigo.opacity(0.10)) } ?? false, "off: own border end")
        XCTAssertTrue(Self.same(Neon.textSecondary, p.textSecondary), "off: own secondary text")

        Self.flip(box, true, center)
        XCTAssertTrue(Self.same(Neon.stroke, p.textPrimary), "on again: the fallback is recomputed")
    }

    /// A well-contrasted custom theme keeps its own opaque line tokens under Increase Contrast.
    func testWellContrastedCustomThemeKeepsItsOwnTokens() throws {
        _ = try applied(Self.goodJSON, ic: true, label: "good")
        let p = ThemeRuntime.palette
        for s in [p.card, p.cardHi] {
            XCTAssertGreaterThanOrEqual(ThemeContrastTests.contrast(NSColor(p.blue), on: NSColor(s)), 3)
            XCTAssertGreaterThanOrEqual(ThemeContrastTests.contrast(NSColor(p.indigo), on: NSColor(s)), 3)
        }
        XCTAssertTrue(Self.same(Neon.stroke, p.blue), "divider keeps the accent, opaque")
        XCTAssertTrue(Neon.cardStrokeColors.first.map { Self.same($0, p.blue) } ?? false)
        XCTAssertTrue(Neon.cardStrokeColors.last.map { Self.same($0, p.indigo) } ?? false)
    }

    /// The fallback follows the palette swap, not just the flag: a low theme applied while the flag
    /// is already on resolves at that apply (once, not per draw: Neon reads the stored value).
    func testFallbackIsResolvedAtApplyWhileTheFlagIsOn() throws {
        let (store, _, _) = try applied(Self.goodJSON, ic: true, label: "swap")
        XCTAssertTrue(Self.same(Neon.stroke, ThemeRuntime.palette.blue))
        let dir = tempDir("swap2")
        let file = dir.appendingPathComponent("theme.json")
        try Self.lowJSON.write(to: file, atomically: true, encoding: .utf8)
        let d = ThemeDescriptor(id: "test.1308.swap2", title: "swap2", appearance: .dark,
                                extensionID: "test.1308", jsonPath: file)
        store.setAvailable([d])
        store.select(id: d.id)
        XCTAssertEqual(store.activeID, d.id)
        XCTAssertTrue(Self.same(Neon.stroke, ThemeRuntime.palette.textPrimary))
    }

    /// The 22 built-in themes are unchanged: on, the divider is the opaque accent and the border ends
    /// are the opaque accent and indigo (the phase 1 tokens); secondary text is the text colour; the
    /// existing floor row (IncreaseContrastTests) proves their 3:1 / 4.5:1.
    func testBuiltInThemesKeepTheirOwnLineTokens() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { try ThemePalette.resolve(ThemeSpec.decode(Data(contentsOf: $0.appendingPathComponent("theme.json")))) }
        let themes = [ThemePalette.default] + bundled
        XCTAssertEqual(themes.count, 22)
        for p in themes {
            for on in [false, true] {
                ThemeRuntime.palette = p
                ThemeRuntime.increaseContrast = on
                if on {
                    XCTAssertTrue(Self.same(Neon.stroke, p.blue), "on: divider")
                    XCTAssertTrue(Neon.cardStrokeColors.first.map { Self.same($0, p.blue) } ?? false, "on: border start")
                    XCTAssertTrue(Neon.cardStrokeColors.last.map { Self.same($0, p.indigo) } ?? false, "on: border end")
                    XCTAssertTrue(Self.same(Neon.textSecondary, p.textPrimary), "on: secondary")
                } else {
                    XCTAssertTrue(Self.same(Neon.stroke, p.blue.opacity(0.16)), "off: divider")
                    XCTAssertTrue(Self.same(Neon.textSecondary, p.textSecondary), "off: secondary")
                }
            }
        }
    }

    private static func source(_ rel: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent("Sources/ProsperApp/" + rel), encoding: .utf8)
    }

    /// R1303-n1: the two vertical dividers draw the theme's line token, not a system Divider with the
    /// stroke laid over its grey.
    func testVerticalDividersDrawNoSystemGrey() throws {
        func count(_ needle: String, in hay: String) -> Int { hay.components(separatedBy: needle).count - 1 }
        let runner = try Self.source("RunnerPanel.swift")
        let clip = try Self.source("Clipboard/ClipboardPanel.swift")
        XCTAssertEqual(count("Rectangle().fill(Neon.stroke).frame(width: 1, height: sz(14))", in: runner), 1)
        XCTAssertEqual(count("Rectangle().fill(Neon.stroke).frame(width: 1)", in: clip), 1)
        XCTAssertEqual(count("Divider().overlay(Neon.stroke)", in: runner), 0)
        XCTAssertEqual(count("Divider().overlay(Neon.stroke)", in: clip), 0)
    }
}
