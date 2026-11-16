import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1076 (OQ-105): Prosper follows the system "Increase contrast" setting through the theme store.
/// Every row injects the accessibility reader and a private notification center: none reads the
/// Mac's own setting or listens on the real NSWorkspace center, and no window is shown.
@MainActor
final class IncreaseContrastTests: XCTestCase {
    // Static, so setUp/tearDown (nonisolated overrides) never send `self` to the main actor.
    private static var savedPalette = ThemePalette.default
    private static var savedOpacity: CGFloat = 1
    private static var savedFrost = false
    private static var savedPrefOpacity = 1.0
    private static var savedPrefFrost = false

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            IncreaseContrastTests.savedPalette = ThemeRuntime.palette
            IncreaseContrastTests.savedOpacity = ThemeRuntime.opacity
            IncreaseContrastTests.savedFrost = ThemeRuntime.frost
            IncreaseContrastTests.savedPrefOpacity = Preferences.uiOpacity
            IncreaseContrastTests.savedPrefFrost = Preferences.uiFrost
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ThemeRuntime.increaseContrast = false
            ThemeRuntime.palette = IncreaseContrastTests.savedPalette
            ThemeRuntime.opacity = IncreaseContrastTests.savedOpacity
            ThemeRuntime.frost = IncreaseContrastTests.savedFrost
            Preferences.uiOpacity = IncreaseContrastTests.savedPrefOpacity
            Preferences.uiFrost = IncreaseContrastTests.savedPrefFrost
        }
        super.tearDown()
    }

    private static func post(_ center: NotificationCenter) {
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    private static func comps(_ c: Color) -> [CGFloat] {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent]
    }

    private static func same(_ a: Color, _ b: Color) -> Bool {
        zip(comps(a), comps(b)).allSatisfy { abs($0 - $1) < 0.001 }
    }

    /// The state is the injected reader's value at init, and follows it on each accessibility
    /// display notification of the injected center, without a relaunch; the chosen theme stays.
    func testStateFollowsTheInjectedReaderAndNotification() {
        var on = false
        let center = NotificationCenter()
        let store = ThemeStore(defaults: scratchDefaults("ic1076"), cacheDir: tempDir("ic1076"),
                               increaseContrastReader: { on }, reduceTransparencyReader: { false },
                               workspaceCenter: center)
        var fired = 0
        store.onChange = { fired += 1 }
        let theme = store.activeID
        XCTAssertFalse(store.increaseContrast)
        XCTAssertFalse(ThemeRuntime.increaseContrast)

        on = true
        XCTAssertFalse(store.increaseContrast, "no notification yet")
        let g0 = store.generation
        Self.post(center)
        XCTAssertTrue(store.increaseContrast, "the notification re-reads the reader")
        XCTAssertTrue(ThemeRuntime.increaseContrast, "mirrored for the Neon tokens")
        XCTAssertGreaterThan(store.generation, g0, "tokens are re-read on a rebuild")
        XCTAssertEqual(fired, 1, "AppKit surfaces re-apply once")
        XCTAssertEqual(store.activeID, theme, "the chosen theme stays")

        Self.post(center)
        XCTAssertEqual(fired, 1, "an unchanged state is a no-op")

        on = false
        Self.post(center)
        XCTAssertFalse(store.increaseContrast)
        XCTAssertFalse(ThemeRuntime.increaseContrast)
        XCTAssertEqual(fired, 2)

        on = true
        let seeded = ThemeStore(defaults: scratchDefaults("ic1076"), cacheDir: tempDir("ic1076"),
                                increaseContrastReader: { on }, reduceTransparencyReader: { false },
                                workspaceCenter: NotificationCenter())
        XCTAssertTrue(seeded.increaseContrast, "seeded from the reader at init")
        XCTAssertTrue(ThemeRuntime.increaseContrast)
    }

    /// With the state on, the divider (Neon.stroke), the border (both ends of Neon.cardStroke)
    /// and secondary text differ from off and clear the floor on the six rule surfaces of every
    /// built-in theme: 3:1 for the lines (WCAG 1.4.11), 4.5:1 for text. Token level, so no pixel
    /// render is needed: Neon.* is what every view paints.
    func testOnTokensDifferAndClearTheFloorOnEveryBuiltInTheme() throws {
        let expected = ["Default", "theme-amber", "theme-blossom", "theme-contrast-dark", "theme-contrast-light",
                        "theme-crimson", "theme-daylight", "theme-default", "theme-ember", "theme-emerald",
                        "theme-fern", "theme-gold", "theme-graphite", "theme-indigo", "theme-lavender",
                        "theme-lime", "theme-mint", "theme-rose", "theme-silver", "theme-solar",
                        "theme-teal", "theme-violet"]
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { d -> (String, ThemePalette) in
                let spec = try ThemeSpec.decode(Data(contentsOf: d.appendingPathComponent("theme.json")))
                return (d.lastPathComponent, ThemePalette.resolve(spec))
            }
        let themes = [("Default", ThemePalette.default)] + bundled
        XCTAssertEqual(expected.count, 22)
        XCTAssertEqual(Set(themes.map(\.0)), Set(expected), "the literal list is every built-in theme")
        XCTAssertEqual(themes.count, expected.count)

        var pairs = 0
        for (name, p) in themes {
            ThemeRuntime.palette = p
            ThemeRuntime.increaseContrast = false
            let off = (stroke: Neon.stroke, border: Neon.cardStrokeColors, text: Neon.textSecondary)
            ThemeRuntime.increaseContrast = true
            let on = (stroke: Neon.stroke, border: Neon.cardStrokeColors, text: Neon.textSecondary)
            XCTAssertEqual(on.border.count, 2, name)
            XCTAssertEqual(off.border.count, on.border.count, name)
            XCTAssertFalse(Self.same(on.stroke, off.stroke), "\(name): divider unchanged")
            XCTAssertFalse(zip(on.border, off.border).contains { Self.same($0, $1) }, "\(name): a border end unchanged")
            XCTAssertFalse(Self.same(on.text, off.text), "\(name): secondary text unchanged")
            XCTAssertTrue(Self.same(on.text, p.textPrimary), "\(name): secondary text is not the full text colour")
            let lines = [("divider", on.stroke)] + on.border.enumerated().map { ("border end \($0.offset)", $0.element) }
            for (sn, s) in ThemeContrastTests.ruleSurfaces(p) {
                for (ln, c) in lines {
                    let r = ThemeContrastTests.contrast(NSColor(c), on: s)
                    XCTAssertGreaterThanOrEqual(r, 3, "\(name): \(ln) on \(sn) is \(r):1")
                    pairs += 1
                }
                let r = ThemeContrastTests.contrast(NSColor(on.text), on: s)
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(name): secondary text on \(sn) is \(r):1")
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 22 * 6 * 4, "divider, two border ends and secondary text on six surfaces per theme")
    }

    /// The Reduce Transparency rule follows the injected reader (never the Mac's flag) and the
    /// handler re-reads it; Increase Contrast off, so only the reduce reader decides.
    func testReduceTransparencyFollowsItsInjectedReader() {
        var reduce = true
        let center = NotificationCenter()
        let store = ThemeStore(defaults: scratchDefaults("ic1076"), cacheDir: tempDir("ic1076"),
                               increaseContrastReader: { false }, reduceTransparencyReader: { reduce },
                               workspaceCenter: center)
        store.setOpacity(0.7)
        store.setFrost(true)
        XCTAssertEqual(ThemeRuntime.opacity, 1, "reduce reader on: opaque")
        XCTAssertFalse(ThemeRuntime.frost, "reduce reader on: frost off")
        XCTAssertFalse(store.increaseContrast)
        reduce = false
        Self.post(center)
        XCTAssertEqual(ThemeRuntime.opacity, 0.7, accuracy: 0.0001, "the notification re-reads the reduce reader")
        XCTAssertTrue(ThemeRuntime.frost)
    }

    /// With the state on, the window opacity reads opaque and frost is off whatever the user
    /// stored (the stored values are kept), and a window skinned by applyWindowOpacity reports
    /// opaque. The window is built offscreen and never ordered in.
    func testOnForcesOpaqueWindowsAndKeepsTheStoredChoice() {
        var on = false
        let center = NotificationCenter()
        let store = ThemeStore(defaults: scratchDefaults("ic1076"), cacheDir: tempDir("ic1076"),
                               increaseContrastReader: { on }, reduceTransparencyReader: { false },
                               workspaceCenter: center)
        store.setOpacity(0.7)
        store.setFrost(true)
        on = true
        Self.post(center)
        XCTAssertEqual(ThemeRuntime.opacity, 1, "opacity is forced opaque")
        XCTAssertFalse(ThemeRuntime.frost, "frost needs a non-opaque window, so it is off")
        XCTAssertEqual(store.opacity, 0.7, accuracy: 0.0001, "the stored choice is kept")
        XCTAssertTrue(store.frost, "the stored choice is kept")

        // A change made while it is on stays forced.
        store.setOpacity(0.8)
        XCTAssertEqual(ThemeRuntime.opacity, 1)
        store.setFrost(false)
        store.setFrost(true)
        XCTAssertFalse(ThemeRuntime.frost)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        SettingsWindow.applyWindowOpacity(win)
        XCTAssertTrue(win.isOpaque, "the window reports opaque")
        XCTAssertFalse(win.isVisible)
    }
}
