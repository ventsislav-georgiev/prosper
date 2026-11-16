import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1303 (#1076 phase 2A): Increase Contrast reaches the chrome that draws its own alpha (launcher,
/// Clipboard panel, Settings chrome, the stats battery glyph) and greys Transparency and Frost.
/// Every store here injects both accessibility readers and a private notification center: no row
/// reads the Mac's own setting, and no window is made (the pane sections are hosted windowless).
@MainActor
final class IncreaseContrastChromeTests: XCTestCase {
    private static var savedPalette = ThemePalette.default
    private static var savedOpacity: CGFloat = 1
    private static var savedFrost = false
    private static var savedScale: CGFloat = 1

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            IncreaseContrastChromeTests.savedPalette = ThemeRuntime.palette
            IncreaseContrastChromeTests.savedOpacity = ThemeRuntime.opacity
            IncreaseContrastChromeTests.savedFrost = ThemeRuntime.frost
            IncreaseContrastChromeTests.savedScale = ThemeRuntime.scale
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ThemeRuntime.increaseContrast = false
            ThemeRuntime.palette = IncreaseContrastChromeTests.savedPalette
            ThemeRuntime.opacity = IncreaseContrastChromeTests.savedOpacity
            ThemeRuntime.frost = IncreaseContrastChromeTests.savedFrost
            ThemeRuntime.scale = IncreaseContrastChromeTests.savedScale
        }
        super.tearDown()
    }

    private static func comps(_ c: Color) -> [CGFloat] {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent]
    }

    private static func source(_ rel: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent("Sources/ProsperApp/" + rel), encoding: .utf8)
    }

    private static func count(_ needle: String, in hay: String) -> Int {
        hay.components(separatedBy: needle).count - 1
    }

    /// The shared helper: off, the site's own alpha; on, opaque in the same colour; an alpha of 0
    /// (the unselected row edge) stays 0 either way.
    func testFadedKeepsTheAlphaOffAndIsOpaqueUnderIncreaseContrast() {
        ThemeRuntime.palette = .default
        let blue = Self.comps(Neon.blue)
        XCTAssertEqual(blue.last ?? 0, 1, accuracy: 0.001, "the default accent is opaque")
        for a in [0.15, 0.2, 0.45, 0.5, 0.55, 0.6, 0.7] {
            ThemeRuntime.increaseContrast = false
            let off = Self.comps(Neon.faded(Neon.blue, a))
            ThemeRuntime.increaseContrast = true
            let on = Self.comps(Neon.faded(Neon.blue, a))
            XCTAssertEqual(off.last ?? 0, CGFloat(a), accuracy: 0.001, "off keeps the site's alpha \(a)")
            XCTAssertEqual(on.last ?? 0, 1, accuracy: 0.001, "on is opaque for alpha \(a)")
            XCTAssertTrue(zip(on.prefix(3), blue.prefix(3)).allSatisfy { abs($0 - $1) < 0.001 }, "same hue on, alpha \(a)")
        }
        ThemeRuntime.increaseContrast = true
        XCTAssertEqual(Self.comps(Neon.faded(Neon.blue, 0)).last ?? 1, 0, accuracy: 0.001, "an edge that is off stays off")
        // The faded secondary-text sites (sidebar group label, battery glyph) take the full text colour.
        let text = Self.comps(Neon.faded(Neon.textSecondary, 0.7))
        let primary = Self.comps(ThemePalette.default.textPrimary)
        XCTAssertEqual(text.count, primary.count)
        XCTAssertTrue(zip(text, primary).allSatisfy { abs($0 - $1) < 0.001 }, "\(text) vs \(primary)")
    }

    /// Each changed site goes through `Neon.faded`, `NeonDivider` or `Neon.stroke` (so through
    /// ThemeRuntime.increaseContrast); the only bare `Divider()` left are menu separators.
    func testChromeSitesGoThroughTheContrastTokens() throws {
        let runner = try Self.source("RunnerPanel.swift")
        let clip = try Self.source("Clipboard/ClipboardPanel.swift")
        let settings = try Self.source("SettingsTheme.swift")
        let stats = try Self.source("SystemStats/StatsPopupView.swift")

        // #1308: the vertical hairlines are plain Rectangles of the stroke token, no system Divider.
        let vRunner = "Rectangle().fill(Neon.stroke).frame(width: 1, height: sz(14))"
        let vClip = "Rectangle().fill(Neon.stroke).frame(width: 1)"
        func system(_ s: String) -> Int { Self.count("Divider()", in: s) - Self.count("NeonDivider()", in: s) }
        XCTAssertEqual(Self.count("NeonDivider()", in: runner), 5, "launcher horizontal dividers")
        XCTAssertEqual(Self.count(vRunner, in: runner), 1, "launcher action bar divider")
        XCTAssertEqual(system(runner), 3, "only the three Actions menu separators stay system")
        XCTAssertEqual(Self.count("NeonDivider()", in: clip), 4, "Clipboard horizontal dividers")
        XCTAssertEqual(Self.count(vClip, in: clip), 1, "Clipboard list/preview divider")
        XCTAssertEqual(system(clip), 2, "only the type-filter and row menu separators stay system")
        XCTAssertEqual(Self.count("Rectangle().fill(Neon.stroke).frame(height: 1)", in: settings), 1,
                       "NeonDivider paints the divider token")

        let sites: [(String, String, String)] = [
            ("launcher border", runner, ".strokeBorder(Neon.faded(Neon.blue, 0.5), lineWidth: 1))"),
            ("type filter border", clip, ".strokeBorder(Neon.faded(Neon.blue, model.typeFilter != nil ? 0.5 : 0.15), lineWidth: 1))"),
            ("colour swatch border", clip, ".strokeBorder(Neon.stroke))"),
            ("button border", settings, ".strokeBorder(Neon.faded(accent, 0.55), lineWidth: 1))"),
            ("sidebar group label", settings, ".foregroundStyle(Neon.faded(Neon.textSecondary, 0.7))"),
            ("search field border", settings, ".strokeBorder(Neon.faded(Neon.blue, searchFocused ? 0.55 : 0.2), lineWidth: 1)))"),
            ("selected row border", settings, ".strokeBorder(Neon.faded(Neon.blue, selected ? 0.45 : 0), lineWidth: 1))"),
            ("battery outline", stats, ".stroke(Neon.faded(Neon.textSecondary, 0.6), lineWidth: h * 0.07)"),
            ("battery nub", stats, ".fill(Neon.faded(Neon.textSecondary, 0.6))"),
        ]
        for (name, file, line) in sites {
            XCTAssertEqual(Self.count(line, in: file), 1, "\(name): \(line)")
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
        v as? T ?? v.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    /// Transparency and Frost are disabled, with a footer naming the system setting, under
    /// Increase Contrast or Reduce Transparency (each from the store's injected reader), and
    /// enabled with the usual footers when both are off. Hosted windowless on a scratch store.
    func testBackdropControlsFollowTheInjectedReaders() throws {
        let cases: [(ic: Bool, rt: Bool, transparency: String?, frost: String?)] = [
            (true, false,
             "System \u{201C}Increase contrast\u{201D} is on, so windows stay opaque.",
             "System \u{201C}Increase contrast\u{201D} is on, so Frost is unavailable."),
            (false, true,
             "System \u{201C}Reduce transparency\u{201D} is on, so windows stay opaque.",
             "System \u{201C}Reduce transparency\u{201D} is on, so Frost is unavailable."),
            (false, false, nil, nil),
        ]
        var hosted = 0
        for c in cases {
            let store = ThemeStore(defaults: scratchDefaults("ic1303"), cacheDir: tempDir("ic1303"),
                                   increaseContrastReader: { c.ic }, reduceTransparencyReader: { c.rt },
                                   workspaceCenter: NotificationCenter())
            let lock = BackdropSections.lock(reduceTransparency: store.reduceTransparencyReader(),
                                             increaseContrast: store.increaseContrast)
            let tf = BackdropSections.transparencyFooter(lock: lock, frost: false)
            let ff = BackdropSections.frostFooter(lock: lock)
            if let want = c.transparency { XCTAssertEqual(tf, want) } else {
                XCTAssertEqual(tf, "Lets the desktop show through Prosper\u{2019}s windows.")
            }
            if let want = c.frost { XCTAssertEqual(ff, want) } else {
                XCTAssertEqual(ff, "Frosted glass: blurs the desktop behind Prosper\u{2019}s windows. Use Transparency to tune the glass.")
            }

            let host = NSHostingView(rootView: VStack { BackdropSections(theme: store) })
            host.frame.size = NSSize(width: 600, height: 400)
            host.layoutSubtreeIfNeeded()
            let enabled = c.transparency == nil
            let seg = try XCTUnwrap(Self.find(NSSegmentedControl.self, in: host), "no Transparency picker, ic \(c.ic) rt \(c.rt)")
            let sw = try XCTUnwrap(Self.find(NSSwitch.self, in: host), "no Frost switch, ic \(c.ic) rt \(c.rt)")
            XCTAssertEqual(seg.isEnabled, enabled, "Transparency enabled, ic \(c.ic) rt \(c.rt)")
            XCTAssertEqual(sw.isEnabled, enabled, "Frost enabled, ic \(c.ic) rt \(c.rt)")
            hosted += 1
        }
        XCTAssertEqual(hosted, 3)
    }

    /// The pane decides on the store's readers, never a system read of its own.
    func testAppearancePaneDoesNotReadTheSystemFlags() throws {
        let pane = try Self.source("Theme/AppearanceSettingsPane.swift")
        XCTAssertEqual(Self.count("accessibilityDisplayShould", in: pane), 0)
        XCTAssertEqual(Self.count("BackdropSections(theme: theme)", in: pane), 1, "the pane shows the sections")
    }
}
